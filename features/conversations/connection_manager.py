import asyncio
import json
import logging
from contextlib import suppress
from dataclasses import dataclass, field
from uuid import uuid4

from fastapi import WebSocket
from redis.asyncio import Redis

from config.settings import get_settings


logger = logging.getLogger(__name__)


@dataclass(slots=True)
class ActiveConnection:
    websocket: WebSocket
    user_id: str
    send_lock: asyncio.Lock
    paused: bool = False
    pending: list[dict] = field(default_factory=list)


class ConversationConnectionManager:
    def __init__(self) -> None:
        self._connections: dict[str, list[ActiveConnection]] = {}
        self._user_connections: dict[str, list[ActiveConnection]] = {}
        self._instance_id = uuid4().hex
        self._redis: Redis | None = None
        self._listener_task: asyncio.Task | None = None

    async def start(self) -> None:
        settings = get_settings()
        if not settings.redis_url:
            logger.warning(
                "REDIS_URL is not configured; WebSocket broadcasts are local to this instance"
            )
            return
        self._redis = Redis.from_url(settings.redis_url, decode_responses=True)
        await self._redis.ping()
        self._listener_task = asyncio.create_task(self._listen())

    async def stop(self) -> None:
        if self._listener_task is not None:
            self._listener_task.cancel()
            with suppress(asyncio.CancelledError):
                await self._listener_task
            self._listener_task = None
        if self._redis is not None:
            await self._redis.aclose()
            self._redis = None

    async def connect(
        self,
        conversation_id: str,
        user_id: str,
        websocket: WebSocket,
    ) -> None:
        await websocket.accept()
        self._connections.setdefault(conversation_id, []).append(
            ActiveConnection(
                websocket=websocket,
                user_id=user_id,
                send_lock=asyncio.Lock(),
            )
        )

    async def connect_user(self, user_id: str, websocket: WebSocket) -> None:
        await websocket.accept()
        self._user_connections.setdefault(user_id, []).append(
            ActiveConnection(
                websocket=websocket,
                user_id=user_id,
                send_lock=asyncio.Lock(),
                paused=True,
            )
        )

    def disconnect(self, conversation_id: str, websocket: WebSocket) -> None:
        connections = self._connections.get(conversation_id, [])
        remaining = [
            connection
            for connection in connections
            if connection.websocket is not websocket
        ]
        if remaining:
            self._connections[conversation_id] = remaining
        else:
            self._connections.pop(conversation_id, None)

    def disconnect_user(self, user_id: str, websocket: WebSocket) -> None:
        connections = self._user_connections.get(user_id, [])
        remaining = [item for item in connections if item.websocket is not websocket]
        if remaining:
            self._user_connections[user_id] = remaining
        else:
            self._user_connections.pop(user_id, None)

    async def broadcast(
        self,
        conversation_id: str,
        payload: dict,
        *,
        exclude: WebSocket | None = None,
    ) -> None:
        await self._broadcast_local(conversation_id, payload, exclude=exclude)
        if self._redis is not None:
            envelope = {
                "origin": self._instance_id,
                "scope": "conversation",
                "conversationId": conversation_id,
                "payload": payload,
            }
            await self._redis.publish(
                get_settings().redis_conversation_channel,
                json.dumps(envelope, separators=(",", ":")),
            )

    async def broadcast_user(self, user_id: str, payload: dict) -> None:
        await self._broadcast_user_local(user_id, payload)
        if self._redis is not None:
            envelope = {
                "origin": self._instance_id,
                "scope": "user",
                "userId": user_id,
                "payload": payload,
            }
            await self._redis.publish(
                get_settings().redis_conversation_channel,
                json.dumps(envelope, separators=(",", ":")),
            )

    async def send_user_socket(self, user_id: str, websocket: WebSocket, payload: dict) -> None:
        connection = next(
            (
                item
                for item in self._user_connections.get(user_id, [])
                if item.websocket is websocket
            ),
            None,
        )
        if connection is None:
            return
        async with connection.send_lock:
            await websocket.send_json(payload)

    async def activate_user_socket(
        self, user_id: str, websocket: WebSocket, through_sequence_id: int
    ) -> None:
        connection = next(
            (
                item
                for item in self._user_connections.get(user_id, [])
                if item.websocket is websocket
            ),
            None,
        )
        if connection is None:
            return
        async with connection.send_lock:
            pending = connection.pending
            connection.pending = []
            connection.paused = False
            pending.sort(
                key=lambda payload: int(payload.get("data", {}).get("sequenceId", 0))
            )
            for payload in pending:
                sequence_id = int(payload.get("data", {}).get("sequenceId", 0))
                if sequence_id <= through_sequence_id:
                    continue
                await websocket.send_json(payload)

    async def _broadcast_local(
        self,
        conversation_id: str,
        payload: dict,
        *,
        exclude: WebSocket | None = None,
    ) -> None:
        stale: list[WebSocket] = []
        for connection in list(self._connections.get(conversation_id, [])):
            if connection.websocket is exclude:
                continue
            try:
                async with connection.send_lock:
                    await connection.websocket.send_json(payload)
            except Exception:
                stale.append(connection.websocket)
        for websocket in stale:
            self.disconnect(conversation_id, websocket)

    async def _broadcast_user_local(self, user_id: str, payload: dict) -> None:
        stale: list[WebSocket] = []
        for connection in list(self._user_connections.get(user_id, [])):
            try:
                if connection.paused:
                    connection.pending.append(payload)
                    continue
                async with connection.send_lock:
                    await connection.websocket.send_json(payload)
            except Exception:
                stale.append(connection.websocket)
        for websocket in stale:
            self.disconnect_user(user_id, websocket)

    async def _listen(self) -> None:
        if self._redis is None:
            return
        pubsub = self._redis.pubsub()
        await pubsub.subscribe(get_settings().redis_conversation_channel)
        try:
            async for message in pubsub.listen():
                if message.get("type") != "message":
                    continue
                try:
                    envelope = json.loads(message["data"])
                    if envelope.get("origin") == self._instance_id:
                        continue
                    if envelope.get("scope") == "user":
                        await self._broadcast_user_local(
                            envelope["userId"], envelope["payload"]
                        )
                    else:
                        await self._broadcast_local(
                            envelope["conversationId"], envelope["payload"]
                        )
                except Exception:
                    logger.exception("Invalid Redis conversation event")
        finally:
            await pubsub.aclose()


connection_manager = ConversationConnectionManager()
