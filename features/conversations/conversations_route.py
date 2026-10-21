import logging
from datetime import datetime
from typing import Annotated

from fastapi import (
    APIRouter,
    HTTPException,
    Query,
    WebSocket,
    WebSocketDisconnect,
    status,
)
from pydantic import ValidationError
from starlette.concurrency import run_in_threadpool

from core.dependencies import CurrentUser, authenticate_access_token
from core.exceptions import AppError
from features.conversations.connection_manager import connection_manager
from features.conversations.conversations_models import (
    AttachmentInput,
    ConfirmedAttachment,
    ConversationOutput,
    ConversationPage,
    CreateConversationInput,
    CreateUploadURLInput,
    IncomingEvent,
    InboxAckData,
    InboxIncomingEvent,
    InboxEventPage,
    InboxSyncData,
    MessagingBootstrap,
    MessagePage,
    OutgoingEvent,
    SendMessageData,
    SignedDownloadURL,
    SignedUploadURL,
)
from features.conversations.conversations_service import ConversationsService


logger = logging.getLogger(__name__)
router = APIRouter(prefix="/conversations", tags=["conversations"])


@router.post("", response_model=ConversationOutput, status_code=status.HTTP_201_CREATED)
async def create_conversation(
    payload: CreateConversationInput,
    current_user: CurrentUser,
) -> ConversationOutput:
    service = ConversationsService()
    conversation = await run_in_threadpool(
        service.create_conversation, current_user.id, payload
    )
    events = await run_in_threadpool(
        service.inbox_events_for_conversation,
        conversation.id,
        "conversation.created",
        since=conversation.created_at,
    )
    for event in events:
        await connection_manager.broadcast_user(
            event.user_id,
            OutgoingEvent(
                event="inbox.event",
                data=event.model_dump(mode="json", by_alias=True),
            ).model_dump(mode="json", by_alias=True),
        )
    return conversation


@router.get("", response_model=ConversationPage)
def list_conversations(
    current_user: CurrentUser,
    limit: Annotated[int, Query(ge=1, le=50)] = 20,
    offset: Annotated[int, Query(ge=0)] = 0,
) -> ConversationPage:
    return ConversationsService().list_conversations(
        current_user.id,
        limit=limit,
        offset=offset,
    )


@router.get("/bootstrap", response_model=MessagingBootstrap)
def bootstrap_messaging(
    current_user: CurrentUser,
    conversation_limit: Annotated[int, Query(ge=1, le=100)] = 50,
) -> MessagingBootstrap:
    return ConversationsService().bootstrap(
        current_user.id, limit=conversation_limit
    )


@router.get("/inbox/events", response_model=InboxEventPage)
def list_inbox_events(
    current_user: CurrentUser,
    after_sequence_id: Annotated[int, Query(ge=0)] = 0,
    limit: Annotated[int, Query(ge=1, le=500)] = 100,
) -> InboxEventPage:
    return ConversationsService().list_inbox_events(
        current_user.id,
        after_sequence_id=after_sequence_id,
        limit=limit,
    )


@router.get("/{conversation_id}", response_model=ConversationOutput)
def get_conversation(
    conversation_id: str,
    current_user: CurrentUser,
) -> ConversationOutput:
    return ConversationsService().get_conversation(conversation_id, current_user.id)


@router.get("/{conversation_id}/messages", response_model=MessagePage)
def list_messages(
    conversation_id: str,
    current_user: CurrentUser,
    limit: Annotated[int, Query(ge=1, le=100)] = 30,
    before: datetime | None = None,
) -> MessagePage:
    return ConversationsService().list_messages(
        conversation_id,
        current_user.id,
        limit=limit,
        before=before,
    )


@router.post("/{conversation_id}/close", response_model=ConversationOutput)
async def close_conversation(
    conversation_id: str,
    current_user: CurrentUser,
) -> ConversationOutput:
    conversation = await run_in_threadpool(
        ConversationsService().close_conversation,
        conversation_id,
        current_user.id,
    )
    await connection_manager.broadcast(
        conversation_id,
        OutgoingEvent(
            event="conversation.closed",
            data={
                "conversationId": conversation_id,
                "closedAt": (
                    conversation.closed_at.isoformat()
                    if conversation.closed_at is not None
                    else None
                ),
            },
        ).model_dump(mode="json", by_alias=True),
    )
    service = ConversationsService()
    if conversation.closed_at is not None:
        events = await run_in_threadpool(
            service.inbox_events_for_conversation,
            conversation.id,
            "conversation.closed",
            since=conversation.closed_at,
        )
        for event in events:
            await connection_manager.broadcast_user(
                event.user_id,
                OutgoingEvent(
                    event="inbox.event",
                    data=event.model_dump(mode="json", by_alias=True),
                ).model_dump(mode="json", by_alias=True),
            )
    return conversation


@router.post(
    "/{conversation_id}/attachments/upload-url",
    response_model=SignedUploadURL,
)
def create_attachment_upload_url(
    conversation_id: str,
    payload: CreateUploadURLInput,
    current_user: CurrentUser,
) -> SignedUploadURL:
    return ConversationsService().create_upload_url(
        conversation_id,
        current_user.id,
        payload,
    )


@router.post(
    "/{conversation_id}/attachments/confirm",
    response_model=ConfirmedAttachment,
)
def confirm_attachment_upload(
    conversation_id: str,
    payload: AttachmentInput,
    current_user: CurrentUser,
) -> ConfirmedAttachment:
    return ConversationsService().confirm_attachment(
        conversation_id, current_user.id, payload
    )


@router.get(
    "/{conversation_id}/attachments/{attachment_id}/download-url",
    response_model=SignedDownloadURL,
)
def create_attachment_download_url(
    conversation_id: str,
    attachment_id: str,
    current_user: CurrentUser,
    expires_in: Annotated[int, Query(ge=60, le=3600)] = 900,
) -> SignedDownloadURL:
    return ConversationsService().create_download_url(
        conversation_id,
        attachment_id,
        current_user.id,
        expires_in=expires_in,
    )


def _bearer_token(websocket: WebSocket) -> str | None:
    authorization = websocket.headers.get("authorization", "")
    scheme, _, token = authorization.partition(" ")
    if scheme.lower() == "bearer" and token:
        return token
    return websocket.query_params.get("accessToken")


async def _send_error(
    websocket: WebSocket,
    code: str,
    message: str,
    details: list | dict | None = None,
) -> None:
    payload = OutgoingEvent(
        event="error",
        data={"code": code, "message": message, "details": details or {}},
    )
    await websocket.send_json(payload.model_dump(mode="json", by_alias=True))


async def _authenticate_websocket(websocket: WebSocket):
    token = _bearer_token(websocket)
    if token is None:
        await websocket.close(code=4401, reason="Authentication required")
        return None
    try:
        return await run_in_threadpool(authenticate_access_token, token)
    except HTTPException as exc:
        await websocket.close(
            code=4403 if exc.status_code == 403 else 4401,
            reason=(
                "User account is not active"
                if exc.status_code == 403
                else "Invalid access token"
            ),
        )
        return None


async def _send_inbox_page(
    websocket: WebSocket,
    user_id: str,
    service: ConversationsService,
    *,
    after_sequence_id: int,
    limit: int,
) -> None:
    page = await run_in_threadpool(
        service.list_inbox_events,
        user_id,
        after_sequence_id=after_sequence_id,
        limit=limit,
    )
    for item in page.items:
        await connection_manager.send_user_socket(
            user_id,
            websocket,
            OutgoingEvent(
                event="inbox.event",
                data=item.model_dump(mode="json", by_alias=True),
            ).model_dump(mode="json", by_alias=True),
        )
    await connection_manager.send_user_socket(
        user_id,
        websocket,
        OutgoingEvent(
            event="inbox.synced",
            data={
                "nextSequenceId": page.next_sequence_id,
                "hasMore": page.has_more,
            },
        ).model_dump(mode="json", by_alias=True),
    )
    if not page.has_more:
        await connection_manager.activate_user_socket(
            user_id, websocket, page.next_sequence_id
        )


@router.websocket("/inbox/ws")
async def inbox_websocket(websocket: WebSocket) -> None:
    current_user = await _authenticate_websocket(websocket)
    if current_user is None:
        return
    try:
        after_sequence_id = int(websocket.query_params.get("afterSequenceId", "0"))
        if after_sequence_id < 0:
            raise ValueError
    except ValueError:
        await websocket.close(code=4400, reason="Invalid inbox sequence")
        return

    service = ConversationsService()
    await connection_manager.connect_user(current_user.id, websocket)
    try:
        await connection_manager.send_user_socket(
            current_user.id,
            websocket,
            OutgoingEvent(
                event="inbox.connected",
                data={"userId": current_user.id},
            ).model_dump(mode="json", by_alias=True),
        )
        await _send_inbox_page(
            websocket,
            current_user.id,
            service,
            after_sequence_id=after_sequence_id,
            limit=100,
        )
        while True:
            try:
                incoming = InboxIncomingEvent.model_validate(
                    await websocket.receive_json()
                )
                if incoming.event == "inbox.sync":
                    sync = InboxSyncData.model_validate(incoming.data)
                    await _send_inbox_page(
                        websocket,
                        current_user.id,
                        service,
                        after_sequence_id=sync.after_sequence_id,
                        limit=sync.limit,
                    )
                elif incoming.event == "inbox.ack":
                    ack = InboxAckData.model_validate(incoming.data)
                    count = await run_in_threadpool(
                        service.acknowledge_inbox,
                        current_user.id,
                        ack.sequence_id,
                    )
                    await connection_manager.send_user_socket(
                        current_user.id,
                        websocket,
                        OutgoingEvent(
                            event="inbox.acknowledged",
                            data={
                                "sequenceId": ack.sequence_id,
                                "acknowledgedCount": count,
                            },
                        ).model_dump(mode="json", by_alias=True),
                    )
                elif incoming.event == "ping":
                    await connection_manager.send_user_socket(
                        current_user.id,
                        websocket,
                        OutgoingEvent(event="pong").model_dump(
                            mode="json", by_alias=True
                        ),
                    )
            except ValidationError as exc:
                await connection_manager.send_user_socket(
                    current_user.id,
                    websocket,
                    OutgoingEvent(
                        event="error",
                        data={
                            "code": "invalid_event",
                            "message": "The inbox event is invalid",
                            "details": exc.errors(include_context=False),
                        },
                    ).model_dump(mode="json", by_alias=True),
                )
            except AppError as exc:
                await connection_manager.send_user_socket(
                    current_user.id,
                    websocket,
                    OutgoingEvent(
                        event="error",
                        data={
                            "code": exc.code,
                            "message": exc.message,
                            "details": exc.details,
                        },
                    ).model_dump(mode="json", by_alias=True),
                )
            except WebSocketDisconnect:
                raise
            except Exception as exc:
                logger.exception("Inbox WebSocket event failed", exc_info=exc)
                await connection_manager.send_user_socket(
                    current_user.id,
                    websocket,
                    OutgoingEvent(
                        event="error",
                        data={
                            "code": "internal_error",
                            "message": "The inbox event could not be processed",
                        },
                    ).model_dump(mode="json", by_alias=True),
                )
    except WebSocketDisconnect:
        pass
    finally:
        connection_manager.disconnect_user(current_user.id, websocket)


@router.websocket("/{conversation_id}/ws")
async def conversation_websocket(websocket: WebSocket, conversation_id: str) -> None:
    current_user = await _authenticate_websocket(websocket)
    if current_user is None:
        return

    service = ConversationsService()
    try:
        await run_in_threadpool(service.ensure_access, conversation_id, current_user.id)
    except AppError as exc:
        await websocket.close(code=4404 if exc.status_code == 404 else 4403, reason=exc.message)
        return

    await connection_manager.connect(conversation_id, current_user.id, websocket)
    await websocket.send_json(
        OutgoingEvent(
            event="connected",
            data={"conversationId": conversation_id, "userId": current_user.id},
        ).model_dump(mode="json", by_alias=True)
    )

    try:
        while True:
            try:
                incoming = IncomingEvent.model_validate(await websocket.receive_json())

                if incoming.event == "message.send":
                    message_input = SendMessageData.model_validate(incoming.data)
                    message = await run_in_threadpool(
                        service.send_message,
                        conversation_id,
                        current_user.id,
                        message_input,
                    )
                    inbox_events = await run_in_threadpool(
                        service.inbox_events_for_message, message.id
                    )
                    for inbox_event in inbox_events:
                        await connection_manager.broadcast_user(
                            inbox_event.user_id,
                            OutgoingEvent(
                                event="inbox.event",
                                data=inbox_event.model_dump(mode="json", by_alias=True),
                            ).model_dump(mode="json", by_alias=True),
                        )
                    await websocket.send_json(
                        OutgoingEvent(
                            event="message.accepted",
                            data={
                                "clientMessageId": str(message.client_message_id),
                                "messageId": message.id,
                            },
                        ).model_dump(mode="json", by_alias=True)
                    )

                elif incoming.event == "conversation.read":
                    read_at = await run_in_threadpool(
                        service.mark_read, conversation_id, current_user.id
                    )
                    event = OutgoingEvent(
                        event="conversation.read",
                        data={
                            "conversationId": conversation_id,
                            "userId": current_user.id,
                            "readAt": read_at.isoformat(),
                        },
                    )
                    await connection_manager.broadcast(
                        conversation_id,
                        event.model_dump(mode="json", by_alias=True),
                    )
                    inbox_events = await run_in_threadpool(
                        service.inbox_events_for_conversation,
                        conversation_id,
                        "conversation.read",
                        since=read_at,
                        actor_user_id=current_user.id,
                    )
                    for inbox_event in inbox_events:
                        await connection_manager.broadcast_user(
                            inbox_event.user_id,
                            OutgoingEvent(
                                event="inbox.event",
                                data=inbox_event.model_dump(
                                    mode="json", by_alias=True
                                ),
                            ).model_dump(mode="json", by_alias=True),
                        )

                elif incoming.event in {"typing.start", "typing.stop"}:
                    event_name = (
                        "typing.started"
                        if incoming.event == "typing.start"
                        else "typing.stopped"
                    )
                    event = OutgoingEvent(
                        event=event_name,
                        data={
                            "conversationId": conversation_id,
                            "userId": current_user.id,
                        },
                    )
                    await connection_manager.broadcast(
                        conversation_id,
                        event.model_dump(mode="json", by_alias=True),
                        exclude=websocket,
                    )

                elif incoming.event == "ping":
                    await websocket.send_json(
                        OutgoingEvent(event="pong").model_dump(
                            mode="json", by_alias=True
                        )
                    )

            except ValidationError as exc:
                await _send_error(
                    websocket,
                    "invalid_event",
                    "The WebSocket event is invalid",
                    exc.errors(include_context=False),
                )
            except AppError as exc:
                await _send_error(websocket, exc.code, exc.message, exc.details)
            except WebSocketDisconnect:
                raise
            except Exception as exc:
                logger.exception("WebSocket conversation event failed", exc_info=exc)
                await _send_error(
                    websocket,
                    "internal_error",
                    "The event could not be processed",
                )
    except WebSocketDisconnect:
        pass
    finally:
        connection_manager.disconnect(conversation_id, websocket)
