from datetime import datetime
from enum import StrEnum
from typing import Any, Literal
from uuid import UUID

from pydantic import Field, field_validator

from core.models import APIModel


class MessageType(StrEnum):
    TEXT = "text"
    VOICE = "voice"
    ATTACHMENT = "attachment"


class AttachmentType(StrEnum):
    IMAGE = "image"
    VIDEO = "video"
    AUDIO = "audio"
    FILE = "file"


class ParticipantRole(StrEnum):
    MEMBER = "member"
    BUYER = "buyer"
    TRAVELER = "traveler"
    RECIPIENT = "recipient"
    SUPPORT_AGENT = "support_agent"


class ConversationType(StrEnum):
    DIRECT = "direct"
    DELIVERY_GROUP = "delivery_group"
    SUPPORT = "support"


class ConversationStatus(StrEnum):
    ACTIVE = "active"
    CLOSED = "closed"
    ARCHIVED = "archived"


class ConversationParticipantInput(APIModel):
    user_id: str
    role: ParticipantRole


class CreateConversationInput(APIModel):
    type: ConversationType
    participants: list[ConversationParticipantInput] = Field(min_length=2, max_length=10)

    @field_validator("participants")
    @classmethod
    def participants_must_be_unique(
        cls, value: list[ConversationParticipantInput]
    ) -> list[ConversationParticipantInput]:
        user_ids = [participant.user_id for participant in value]
        if len(user_ids) != len(set(user_ids)):
            raise ValueError("A user can participate only once in a conversation")
        return value


class ConversationParticipantOutput(APIModel):
    user_id: str
    role: ParticipantRole
    first_name: str | None = None
    last_name: str | None = None
    profile_picture_url: str | None = None
    joined_at: datetime
    left_at: datetime | None = None
    last_read_at: datetime | None = None


class AttachmentInput(APIModel):
    type: AttachmentType
    storage_path: str = Field(min_length=3, max_length=1000)
    original_file_name: str | None = Field(default=None, max_length=255)
    mime_type: str = Field(min_length=3, max_length=150)
    size_bytes: int = Field(gt=0, le=52_428_800)
    duration_seconds: float | None = Field(default=None, ge=0)
    width: int | None = Field(default=None, gt=0)
    height: int | None = Field(default=None, gt=0)


class AttachmentOutput(AttachmentInput):
    id: str
    uploaded_by_user_id: str
    created_at: datetime
    download_url: str | None = None
    download_url_expires_in: int | None = None


class SendMessageData(APIModel):
    client_message_id: UUID
    type: MessageType
    content: str | None = Field(default=None, max_length=5000)
    reply_to_message_id: str | None = None
    attachments: list[AttachmentInput] = Field(default_factory=list, max_length=10)

    @field_validator("content")
    @classmethod
    def normalize_content(cls, value: str | None) -> str | None:
        if value is None:
            return None
        normalized = value.strip()
        return normalized or None


class MessageOutput(APIModel):
    id: str
    conversation_id: str
    sender_user_id: str | None
    reply_to_message_id: str | None
    client_message_id: UUID | None
    type: str
    content: str | None
    attachments: list[AttachmentOutput] = Field(default_factory=list)
    created_at: datetime
    edited_at: datetime | None = None
    deleted_at: datetime | None = None


class ConversationOutput(APIModel):
    id: str
    type: ConversationType
    direct_key: str | None = None
    created_by_user_id: str | None
    status: ConversationStatus
    participants: list[ConversationParticipantOutput]
    unread_count: int = 0
    last_message: MessageOutput | None = None
    last_message_at: datetime | None = None
    closed_at: datetime | None = None
    created_at: datetime
    updated_at: datetime


class ConversationPage(APIModel):
    items: list[ConversationOutput]
    limit: int
    offset: int
    has_more: bool


class MessagePage(APIModel):
    items: list[MessageOutput]
    next_cursor: datetime | None = None
    has_more: bool


class InboxEventOutput(APIModel):
    sequence_id: int
    user_id: str
    event: str
    conversation_id: str
    actor_user_id: str | None = None
    payload: dict[str, Any] = Field(default_factory=dict)
    message: MessageOutput | None = None
    created_at: datetime
    acknowledged_at: datetime | None = None


class InboxEventPage(APIModel):
    items: list[InboxEventOutput]
    next_sequence_id: int
    has_more: bool


class MessagingBootstrap(APIModel):
    conversations: ConversationPage
    last_sequence_id: int


class InboxIncomingEvent(APIModel):
    event: Literal["inbox.sync", "inbox.ack", "ping"]
    data: dict[str, Any] = Field(default_factory=dict)


class InboxSyncData(APIModel):
    after_sequence_id: int = Field(default=0, ge=0)
    limit: int = Field(default=100, ge=1, le=500)


class InboxAckData(APIModel):
    sequence_id: int = Field(ge=1)


class CreateUploadURLInput(APIModel):
    type: AttachmentType
    file_name: str = Field(min_length=1, max_length=255)
    mime_type: str = Field(min_length=3, max_length=150)
    size_bytes: int = Field(gt=0, le=52_428_800)


class SignedUploadURL(APIModel):
    storage_path: str
    signed_url: str
    token: str | None = None


class SignedDownloadURL(APIModel):
    attachment_id: str
    signed_url: str
    expires_in: int


class ConfirmedAttachment(AttachmentInput):
    verified: bool = True


class IncomingEvent(APIModel):
    event: Literal[
        "message.send",
        "conversation.read",
        "typing.start",
        "typing.stop",
        "ping",
    ]
    data: dict[str, Any] = Field(default_factory=dict)


class OutgoingEvent(APIModel):
    event: str
    data: dict[str, Any] = Field(default_factory=dict)
