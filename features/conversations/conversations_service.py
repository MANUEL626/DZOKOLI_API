from collections import defaultdict
from datetime import datetime
from uuid import uuid4

from config.settings import get_settings
from config.supabase_client import get_supabase_admin_client
from core.exceptions import AppError, ForbiddenError, NotFoundError
from features.conversations.conversations_models import (
    AttachmentType,
    AttachmentInput,
    ConfirmedAttachment,
    ConversationOutput,
    ConversationPage,
    ConversationParticipantOutput,
    ConversationType,
    CreateConversationInput,
    CreateUploadURLInput,
    MessageOutput,
    MessagePage,
    InboxEventOutput,
    InboxEventPage,
    MessagingBootstrap,
    MessageType,
    ParticipantRole,
    SendMessageData,
    SignedDownloadURL,
    SignedUploadURL,
)
from features.conversations.conversations_repository import ConversationsRepository


class ConversationsService:
    def __init__(self, repository: ConversationsRepository | None = None) -> None:
        self.repository = repository or ConversationsRepository()
        self.settings = get_settings()

    def ensure_access(self, conversation_id: str, user_id: str) -> None:
        if not self.repository.conversation_exists(conversation_id):
            raise NotFoundError("Conversation")
        if not self.repository.is_active_participant(conversation_id, user_id):
            raise ForbiddenError("You are not an active participant in this conversation")

    def create_conversation(
        self, user_id: str, payload: CreateConversationInput
    ) -> ConversationOutput:
        if payload.type != ConversationType.DIRECT:
            raise AppError(
                "Only direct conversations can be created from this endpoint",
                status_code=409,
                code="conversation_type_not_creatable",
            )
        if user_id not in {participant.user_id for participant in payload.participants}:
            raise AppError(
                "The authenticated user must be included in the participants",
                code="creator_not_participant",
            )
        self._validate_conversation_participants(payload)
        conversation_id = self.repository.create_conversation(
            payload.type.value,
            user_id,
            [
                participant.model_dump(mode="json", by_alias=False)
                for participant in payload.participants
            ],
        )
        return self.get_conversation(conversation_id, user_id)

    def get_conversation(self, conversation_id: str, user_id: str) -> ConversationOutput:
        self.ensure_access(conversation_id, user_id)
        conversation = self.repository.find_conversation(conversation_id)
        if conversation is None:
            raise NotFoundError("Conversation")
        participants = self.repository.list_participants([conversation_id])
        profiles = self._profile_map(participants)
        return self._to_conversation(
            conversation,
            participants,
            self.repository.find_last_message(conversation_id),
            user_id=user_id,
            profiles=profiles,
        )

    def list_conversations(
        self, user_id: str, *, limit: int, offset: int
    ) -> ConversationPage:
        conversations, has_more = self.repository.list_for_user(
            user_id, limit=limit, offset=offset
        )
        ids = [row["id"] for row in conversations]
        grouped: dict[str, list[dict]] = defaultdict(list)
        for participant in self.repository.list_participants(ids):
            grouped[participant["conversation_id"]].append(participant)
        profiles = self._profile_map(
            [participant for participants in grouped.values() for participant in participants]
        )
        return ConversationPage(
            items=[
                self._to_conversation(
                    conversation,
                    grouped[conversation["id"]],
                    self.repository.find_last_message(conversation["id"]),
                    user_id=user_id,
                    profiles=profiles,
                )
                for conversation in conversations
            ],
            limit=limit,
            offset=offset,
            has_more=has_more,
        )

    def list_messages(
        self,
        conversation_id: str,
        user_id: str,
        *,
        limit: int,
        before: datetime | None,
    ) -> MessagePage:
        self.ensure_access(conversation_id, user_id)
        messages, has_more = self.repository.list_messages(
            conversation_id, limit=limit, before=before
        )
        grouped: dict[str, list[dict]] = defaultdict(list)
        for attachment in self.repository.list_attachments(
            [message["id"] for message in messages]
        ):
            attachment = dict(attachment)
            attachment["download_url"] = self._signed_download_url(
                attachment["storage_path"],
                self.settings.conversation_signed_url_expires_in,
            )
            attachment["download_url_expires_in"] = (
                self.settings.conversation_signed_url_expires_in
            )
            grouped[attachment["message_id"]].append(attachment)

        items: list[MessageOutput] = []
        for message in messages:
            data = dict(message)
            attachments = grouped[message["id"]]
            if data.get("deleted_at") is not None:
                data["content"] = None
                attachments = []
            items.append(MessageOutput(**data, attachments=attachments))
        return MessagePage(
            items=items,
            next_cursor=items[-1].created_at if has_more and items else None,
            has_more=has_more,
        )

    def send_message(
        self,
        conversation_id: str,
        user_id: str,
        payload: SendMessageData,
    ) -> MessageOutput:
        self.ensure_access(conversation_id, user_id)
        self._ensure_active(conversation_id)
        self._validate_message(payload, conversation_id, user_id)
        self._verify_uploaded_attachments(payload.attachments)
        existing = self.repository.find_message_by_client_id(
            user_id, str(payload.client_message_id)
        )
        if existing is not None:
            if existing["conversation_id"] != conversation_id:
                raise AppError(
                    "The client message identifier is already used in another conversation",
                    status_code=409,
                    code="client_message_id_conflict",
                )
            return self._message_with_attachments(existing)

        try:
            message = self.repository.create_message(conversation_id, user_id, payload)
        except Exception as exc:
            existing = self.repository.find_message_by_client_id(
                user_id, str(payload.client_message_id)
            )
            if existing is None:
                raise AppError(
                    "Unable to persist the message",
                    status_code=502,
                    code="message_creation_failed",
                ) from exc
            if existing["conversation_id"] != conversation_id:
                raise AppError(
                    "The client message identifier is already used in another conversation",
                    status_code=409,
                    code="client_message_id_conflict",
                ) from exc
            message = existing
        return self._message_with_attachments(message)

    def bootstrap(self, user_id: str, *, limit: int) -> MessagingBootstrap:
        # Capture the inbox watermark first. Any concurrent event created after
        # it will be replayed through the global WebSocket, even if the
        # conversation snapshot is being assembled at the same time.
        last_sequence_id = self.repository.latest_inbox_sequence(user_id)
        return MessagingBootstrap(
            conversations=self.list_conversations(user_id, limit=limit, offset=0),
            last_sequence_id=last_sequence_id,
        )

    def list_inbox_events(
        self, user_id: str, *, after_sequence_id: int, limit: int
    ) -> InboxEventPage:
        rows, has_more = self.repository.list_inbox_events(
            user_id, after_sequence_id=after_sequence_id, limit=limit
        )
        items = self._to_inbox_events(rows)
        return InboxEventPage(
            items=items,
            next_sequence_id=(
                items[-1].sequence_id if items else after_sequence_id
            ),
            has_more=has_more,
        )

    def inbox_events_for_message(self, message_id: str) -> list[InboxEventOutput]:
        return self._to_inbox_events(
            self.repository.list_inbox_events_for_message(message_id)
        )

    def inbox_events_for_conversation(
        self,
        conversation_id: str,
        event_type: str,
        *,
        since: datetime,
        actor_user_id: str | None = None,
    ) -> list[InboxEventOutput]:
        return self._to_inbox_events(
            self.repository.list_conversation_events(
                conversation_id,
                event_type,
                since=since.isoformat(),
                actor_user_id=actor_user_id,
            )
        )

    def acknowledge_inbox(self, user_id: str, sequence_id: int) -> int:
        return self.repository.acknowledge_inbox(user_id, sequence_id)

    def confirm_attachment(
        self,
        conversation_id: str,
        user_id: str,
        attachment: AttachmentInput,
    ) -> ConfirmedAttachment:
        self.ensure_access(conversation_id, user_id)
        self._ensure_active(conversation_id)
        self._validate_attachment_path(attachment, conversation_id, user_id)
        self._verify_uploaded_attachments([attachment])
        return ConfirmedAttachment(**attachment.model_dump(), verified=True)

    @staticmethod
    def _validate_conversation_participants(payload: CreateConversationInput) -> None:
        roles = [participant.role for participant in payload.participants]
        if payload.type == ConversationType.DIRECT:
            if len(payload.participants) != 2 or any(
                role != ParticipantRole.MEMBER for role in roles
            ):
                raise AppError(
                    "A direct conversation requires exactly two members",
                    code="invalid_direct_conversation",
                )
        elif payload.type == ConversationType.DELIVERY_GROUP:
            expected = {
                ParticipantRole.BUYER,
                ParticipantRole.TRAVELER,
                ParticipantRole.RECIPIENT,
            }
            if len(payload.participants) != 3 or set(roles) != expected:
                raise AppError(
                    "A delivery group requires one buyer, one traveler, and one recipient",
                    code="invalid_delivery_group",
                )
        elif payload.type == ConversationType.SUPPORT:
            raise AppError(
                "Support conversations are not available yet",
                status_code=501,
                code="support_conversation_not_implemented",
            )

    def mark_read(self, conversation_id: str, user_id: str) -> datetime:
        self.ensure_access(conversation_id, user_id)
        return self.repository.mark_read(conversation_id, user_id)

    def create_upload_url(
        self,
        conversation_id: str,
        user_id: str,
        payload: CreateUploadURLInput,
    ) -> SignedUploadURL:
        self.ensure_access(conversation_id, user_id)
        self._ensure_active(conversation_id)
        if payload.size_bytes > self.settings.conversation_media_max_bytes:
            raise AppError(
                "The attachment is too large",
                status_code=413,
                code="attachment_too_large",
            )
        extension = self._validate_upload(payload)
        storage_path = f"{conversation_id}/{user_id}/{uuid4().hex}{extension}"
        result = (
            get_supabase_admin_client()
            .storage.from_(self.settings.conversation_media_bucket)
            .create_signed_upload_url(storage_path)
        )
        signed_url = self._value(result, "signedURL", "signed_url", "url")
        if not signed_url:
            raise AppError(
                "Unable to generate an upload URL",
                status_code=502,
                code="upload_url_failed",
            )
        return SignedUploadURL(
            storage_path=storage_path,
            signed_url=signed_url,
            token=self._value(result, "token"),
        )

    def create_download_url(
        self,
        conversation_id: str,
        attachment_id: str,
        user_id: str,
        *,
        expires_in: int,
    ) -> SignedDownloadURL:
        self.ensure_access(conversation_id, user_id)
        attachment = self.repository.find_attachment(conversation_id, attachment_id)
        if attachment is None:
            raise NotFoundError("Attachment")
        return SignedDownloadURL(
            attachment_id=attachment_id,
            signed_url=self._signed_download_url(
                attachment["storage_path"], expires_in
            ),
            expires_in=expires_in,
        )

    def close_conversation(
        self, conversation_id: str, user_id: str
    ) -> ConversationOutput:
        self.ensure_access(conversation_id, user_id)
        conversation = self.repository.find_conversation(conversation_id)
        if conversation is None:
            raise NotFoundError("Conversation")
        if conversation["type"] != ConversationType.DELIVERY_GROUP.value:
            raise AppError(
                "Only a temporary delivery group can be closed",
                status_code=409,
                code="conversation_not_temporary",
            )
        if conversation["created_by_user_id"] != user_id:
            raise ForbiddenError("Only the conversation creator can close this group")
        if conversation["status"] != "closed":
            self.repository.close_conversation(conversation_id)
        return self.get_conversation(conversation_id, user_id)

    def _ensure_active(self, conversation_id: str) -> None:
        conversation = self.repository.find_conversation(conversation_id)
        if conversation is None:
            raise NotFoundError("Conversation")
        if conversation["status"] != "active":
            raise AppError(
                "This conversation is read-only",
                status_code=409,
                code="conversation_read_only",
            )

    def _to_conversation(
        self,
        conversation: dict,
        participants: list[dict],
        last_message: dict | None,
        *,
        user_id: str,
        profiles: dict[str, dict],
    ) -> ConversationOutput:
        own_participant = next(
            (participant for participant in participants if participant["user_id"] == user_id),
            None,
        )
        last_read_at = own_participant.get("last_read_at") if own_participant else None
        hydrated_participants = []
        for participant in participants:
            data = dict(participant)
            profile = profiles.get(participant["user_id"], {})
            data.update(
                first_name=profile.get("first_name"),
                last_name=profile.get("last_name"),
                profile_picture_url=self._profile_picture_url(
                    profile.get("profile_picture_path")
                ),
            )
            hydrated_participants.append(
                ConversationParticipantOutput.model_validate(data)
            )
        last_message_output = None
        if last_message is not None:
            last_message_output = self._message_with_attachments(last_message)
        return ConversationOutput(
            **conversation,
            participants=hydrated_participants,
            unread_count=self.repository.count_unread_messages(
                conversation["id"], user_id, last_read_at
            ),
            last_message=last_message_output,
        )

    def _message_with_attachments(self, message: dict) -> MessageOutput:
        attachments = self.repository.list_attachments([message["id"]])
        for attachment in attachments:
            attachment["download_url"] = self._signed_download_url(
                attachment["storage_path"],
                self.settings.conversation_signed_url_expires_in,
            )
            attachment["download_url_expires_in"] = (
                self.settings.conversation_signed_url_expires_in
            )
        return MessageOutput(**message, attachments=attachments)

    def _to_inbox_events(self, events: list[dict]) -> list[InboxEventOutput]:
        message_ids = [event["message_id"] for event in events if event.get("message_id")]
        messages = {
            message["id"]: message
            for message in self.repository.find_messages(message_ids)
        }
        attachments: dict[str, list[dict]] = defaultdict(list)
        for attachment in self.repository.list_attachments(message_ids):
            attachments[attachment["message_id"]].append(attachment)

        output = []
        for event in events:
            message = None
            message_id = event.get("message_id")
            if message_id and message_id in messages:
                message = MessageOutput(
                    **messages[message_id],
                    attachments=attachments[message_id],
                )
            output.append(
                InboxEventOutput(
                    sequence_id=event["sequence_id"],
                    user_id=event["user_id"],
                    event=event["event_type"],
                    conversation_id=event["conversation_id"],
                    actor_user_id=event.get("actor_user_id"),
                    payload=event.get("payload") or {},
                    message=message,
                    created_at=event["created_at"],
                    acknowledged_at=event.get("acknowledged_at"),
                )
            )
        return output

    def _profile_map(self, participants: list[dict]) -> dict[str, dict]:
        return {
            profile["id"]: profile
            for profile in self.repository.list_user_profiles(
                [participant["user_id"] for participant in participants]
            )
        }

    def _profile_picture_url(self, path: str | None) -> str | None:
        if not path:
            return None
        return (
            get_supabase_admin_client()
            .storage.from_(self.settings.profile_pictures_bucket)
            .get_public_url(path)
        )

    def _verify_uploaded_attachments(
        self, attachments: list[AttachmentInput]
    ) -> None:
        if len({item.storage_path for item in attachments}) != len(attachments):
            raise AppError(
                "The same attachment cannot be included twice",
                code="duplicate_attachment",
            )
        bucket = get_supabase_admin_client().storage.from_(
            self.settings.conversation_media_bucket
        )
        for attachment in attachments:
            folder, separator, file_name = attachment.storage_path.rpartition("/")
            if not separator:
                raise AppError("Invalid attachment path", code="invalid_attachment_path")
            try:
                objects = bucket.list(folder, {"search": file_name, "limit": 2})
            except Exception as exc:
                raise AppError(
                    "Unable to verify the uploaded attachment",
                    status_code=502,
                    code="attachment_verification_failed",
                ) from exc
            uploaded = next(
                (item for item in objects if self._object_value(item, "name") == file_name),
                None,
            )
            if uploaded is None:
                raise AppError(
                    "The attachment has not been uploaded",
                    code="attachment_not_uploaded",
                )
            metadata = self._object_value(uploaded, "metadata") or {}
            actual_size = self._object_value(metadata, "size")
            actual_mime = self._object_value(metadata, "mimetype", "contentType")
            if actual_size is None or int(actual_size) != attachment.size_bytes:
                raise AppError(
                    "The uploaded attachment size does not match",
                    code="attachment_size_mismatch",
                )
            if actual_mime is None or str(actual_mime).split(";")[0] != attachment.mime_type:
                raise AppError(
                    "The uploaded attachment MIME type does not match",
                    code="attachment_mime_mismatch",
                )

    @staticmethod
    def _object_value(value: object, *keys: str) -> object | None:
        if isinstance(value, dict):
            for key in keys:
                if key in value:
                    return value[key]
        for key in keys:
            result = getattr(value, key, None)
            if result is not None:
                return result
        return None

    def _signed_download_url(self, storage_path: str, expires_in: int) -> str:
        result = (
            get_supabase_admin_client()
            .storage.from_(self.settings.conversation_media_bucket)
            .create_signed_url(storage_path, expires_in)
        )
        signed_url = self._value(result, "signedURL", "signed_url", "url")
        if not signed_url:
            raise AppError(
                "Unable to generate a download URL",
                status_code=502,
                code="download_url_failed",
            )
        return signed_url

    @staticmethod
    def _value(result: object, *keys: str) -> str | None:
        if isinstance(result, dict):
            for key in keys:
                if result.get(key):
                    return str(result[key])
        for key in keys:
            value = getattr(result, key, None)
            if value:
                return str(value)
        return None

    @staticmethod
    def _validate_upload(payload: CreateUploadURLInput) -> str:
        allowed = {
            "image/jpeg": (AttachmentType.IMAGE, ".jpg"),
            "image/png": (AttachmentType.IMAGE, ".png"),
            "image/webp": (AttachmentType.IMAGE, ".webp"),
            "image/gif": (AttachmentType.IMAGE, ".gif"),
            "video/mp4": (AttachmentType.VIDEO, ".mp4"),
            "video/webm": (AttachmentType.VIDEO, ".webm"),
            "audio/mpeg": (AttachmentType.AUDIO, ".mp3"),
            "audio/mp4": (AttachmentType.AUDIO, ".m4a"),
            "audio/ogg": (AttachmentType.AUDIO, ".ogg"),
            "audio/webm": (AttachmentType.AUDIO, ".webm"),
            "application/pdf": (AttachmentType.FILE, ".pdf"),
        }
        expected = allowed.get(payload.mime_type)
        if expected is None or expected[0] != payload.type:
            raise AppError(
                "The attachment type and MIME type are not allowed",
                status_code=415,
                code="unsupported_attachment",
            )
        return expected[1]

    @staticmethod
    def _validate_message(
        payload: SendMessageData, conversation_id: str, user_id: str
    ) -> None:
        if payload.type == MessageType.TEXT:
            if not payload.content:
                raise AppError("A text message cannot be empty", code="empty_message")
            if payload.attachments:
                raise AppError(
                    "A text message cannot contain attachments",
                    code="invalid_message_attachments",
                )
        elif payload.type == MessageType.VOICE:
            if len(payload.attachments) != 1:
                raise AppError(
                    "A voice message must contain exactly one audio attachment",
                    code="invalid_voice_message",
                )
            if payload.attachments[0].type != AttachmentType.AUDIO:
                raise AppError(
                    "A voice message attachment must be audio",
                    code="invalid_voice_attachment",
                )
        elif payload.type == MessageType.ATTACHMENT and not payload.attachments:
            raise AppError(
                "An attachment message must contain at least one file",
                code="missing_attachment",
            )

        prefix = f"{conversation_id}/{user_id}/"
        if any(not item.storage_path.startswith(prefix) for item in payload.attachments):
            raise AppError(
                "An attachment path does not belong to this conversation and user",
                code="invalid_attachment_path",
            )

        for attachment in payload.attachments:
            ConversationsService._validate_attachment_path(
                attachment, conversation_id, user_id
            )

    @staticmethod
    def _validate_attachment_path(
        attachment: AttachmentInput, conversation_id: str, user_id: str
    ) -> None:
        expected_prefix = f"{conversation_id}/{user_id}/"
        relative_name = attachment.storage_path.removeprefix(expected_prefix)
        if (
            not attachment.storage_path.startswith(expected_prefix)
            or not relative_name
            or "/" in relative_name
            or ".." in relative_name
        ):
            raise AppError(
                "An attachment path does not belong to this conversation and user",
                code="invalid_attachment_path",
            )
        upload_payload = CreateUploadURLInput(
            type=attachment.type,
            file_name=attachment.original_file_name or relative_name,
            mime_type=attachment.mime_type,
            size_bytes=attachment.size_bytes,
        )
        ConversationsService._validate_upload(upload_payload)
