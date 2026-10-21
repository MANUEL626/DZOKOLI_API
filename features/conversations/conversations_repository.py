from datetime import datetime
from typing import Any

from config.supabase_client import get_supabase_admin_client
from features.conversations.conversations_models import AttachmentInput, SendMessageData


CONVERSATION_COLUMNS = (
    "id,type,direct_key,created_by_user_id,status,last_message_at,closed_at,"
    "created_at,updated_at"
)
MESSAGE_COLUMNS = (
    "id,conversation_id,sender_user_id,reply_to_message_id,client_message_id,type,content,"
    "created_at,edited_at,deleted_at"
)


class ConversationsRepository:
    def create_conversation(
        self,
        conversation_type: str,
        creator_user_id: str,
        participants: list[dict[str, str]],
    ) -> str:
        response = get_supabase_admin_client().rpc(
            "create_conversation_with_participants",
            {
                "target_type": conversation_type,
                "creator_user_id": creator_user_id,
                "participants": participants,
            },
        ).execute()
        if not response.data:
            raise RuntimeError("Conversation creation returned no identifier")
        return str(response.data)

    def find_conversation(self, conversation_id: str) -> dict[str, Any] | None:
        response = (
            get_supabase_admin_client()
            .table("conversations")
            .select(CONVERSATION_COLUMNS)
            .eq("id", conversation_id)
            .limit(1)
            .execute()
        )
        return response.data[0] if response.data else None

    def conversation_exists(self, conversation_id: str) -> bool:
        return self.find_conversation(conversation_id) is not None

    def is_active_participant(self, conversation_id: str, user_id: str) -> bool:
        response = (
            get_supabase_admin_client()
            .table("conversation_participants")
            .select("conversation_id")
            .eq("conversation_id", conversation_id)
            .eq("user_id", user_id)
            .is_("left_at", "null")
            .limit(1)
            .execute()
        )
        return bool(response.data)

    def list_for_user(
        self, user_id: str, *, limit: int, offset: int
    ) -> tuple[list[dict[str, Any]], bool]:
        memberships = (
            get_supabase_admin_client()
            .table("conversation_participants")
            .select("conversation_id")
            .eq("user_id", user_id)
            .is_("left_at", "null")
            .execute()
        ).data or []
        conversation_ids = [row["conversation_id"] for row in memberships]
        if not conversation_ids:
            return [], False
        response = (
            get_supabase_admin_client()
            .table("conversations")
            .select(CONVERSATION_COLUMNS)
            .in_("id", conversation_ids)
            .order("last_message_at", desc=True, nullsfirst=False)
            .range(offset, offset + limit)
            .execute()
        )
        rows = response.data or []
        return rows[:limit], len(rows) > limit

    def list_participants(self, conversation_ids: list[str]) -> list[dict[str, Any]]:
        if not conversation_ids:
            return []
        response = (
            get_supabase_admin_client()
            .table("conversation_participants")
            .select("conversation_id,user_id,role,joined_at,left_at,last_read_at")
            .in_("conversation_id", conversation_ids)
            .order("joined_at")
            .execute()
        )
        return response.data or []

    def list_user_profiles(self, user_ids: list[str]) -> list[dict[str, Any]]:
        if not user_ids:
            return []
        response = (
            get_supabase_admin_client()
            .table("users")
            .select("id,first_name,last_name,profile_picture_path")
            .in_("id", list(set(user_ids)))
            .execute()
        )
        return response.data or []

    def count_unread_messages(
        self, conversation_id: str, user_id: str, last_read_at: str | None
    ) -> int:
        query = (
            get_supabase_admin_client()
            .table("messages")
            .select("id", count="exact", head=True)
            .eq("conversation_id", conversation_id)
            .or_(f"sender_user_id.neq.{user_id},sender_user_id.is.null")
            .is_("deleted_at", "null")
        )
        if last_read_at is not None:
            query = query.gt("created_at", last_read_at)
        response = query.execute()
        return int(response.count or 0)

    def find_last_message(self, conversation_id: str) -> dict[str, Any] | None:
        response = (
            get_supabase_admin_client()
            .table("messages")
            .select(MESSAGE_COLUMNS)
            .eq("conversation_id", conversation_id)
            .order("created_at", desc=True)
            .limit(1)
            .execute()
        )
        return response.data[0] if response.data else None

    def list_messages(
        self,
        conversation_id: str,
        *,
        limit: int,
        before: datetime | None,
    ) -> tuple[list[dict[str, Any]], bool]:
        query = (
            get_supabase_admin_client()
            .table("messages")
            .select(MESSAGE_COLUMNS)
            .eq("conversation_id", conversation_id)
        )
        if before is not None:
            query = query.lt("created_at", before.isoformat())
        response = query.order("created_at", desc=True).limit(limit + 1).execute()
        rows = response.data or []
        return rows[:limit], len(rows) > limit

    def create_message(
        self,
        conversation_id: str,
        sender_user_id: str,
        payload: SendMessageData,
    ) -> dict[str, Any]:
        response = get_supabase_admin_client().rpc(
            "create_message_with_attachments",
            {
                "target_conversation_id": conversation_id,
                "target_sender_user_id": sender_user_id,
                "target_client_message_id": str(payload.client_message_id),
                "target_type": payload.type.value,
                "target_content": payload.content,
                "target_reply_to_message_id": payload.reply_to_message_id,
                "target_attachments": [
                    attachment.model_dump(mode="json", by_alias=False)
                    for attachment in payload.attachments
                ],
            },
        ).execute()
        if not response.data:
            raise RuntimeError("Message creation returned no identifier")
        message = self.find_message(str(response.data))
        if message is None:
            raise RuntimeError("Created message could not be loaded")
        return message

    def find_message(self, message_id: str) -> dict[str, Any] | None:
        response = (
            get_supabase_admin_client()
            .table("messages")
            .select(MESSAGE_COLUMNS)
            .eq("id", message_id)
            .limit(1)
            .execute()
        )
        return response.data[0] if response.data else None

    def find_messages(self, message_ids: list[str]) -> list[dict[str, Any]]:
        if not message_ids:
            return []
        response = (
            get_supabase_admin_client()
            .table("messages")
            .select(MESSAGE_COLUMNS)
            .in_("id", list(set(message_ids)))
            .execute()
        )
        return response.data or []

    def find_message_by_client_id(
        self, sender_user_id: str, client_message_id: str
    ) -> dict[str, Any] | None:
        response = (
            get_supabase_admin_client()
            .table("messages")
            .select(MESSAGE_COLUMNS)
            .eq("sender_user_id", sender_user_id)
            .eq("client_message_id", client_message_id)
            .limit(1)
            .execute()
        )
        return response.data[0] if response.data else None

    def create_attachments(
        self,
        message_id: str,
        user_id: str,
        attachments: list[AttachmentInput],
    ) -> list[dict[str, Any]]:
        if not attachments:
            return []
        rows = [
            {
                "message_id": message_id,
                "uploaded_by_user_id": user_id,
                **attachment.model_dump(mode="json", by_alias=False),
            }
            for attachment in attachments
        ]
        response = (
            get_supabase_admin_client()
            .table("message_attachments")
            .insert(rows)
            .execute()
        )
        return response.data or []

    def list_attachments(self, message_ids: list[str]) -> list[dict[str, Any]]:
        if not message_ids:
            return []
        response = (
            get_supabase_admin_client()
            .table("message_attachments")
            .select(
                "id,message_id,uploaded_by_user_id,type,storage_path,original_file_name,"
                "mime_type,size_bytes,duration_seconds,width,height,created_at"
            )
            .in_("message_id", message_ids)
            .order("created_at")
            .execute()
        )
        return response.data or []

    def find_attachment(
        self, conversation_id: str, attachment_id: str
    ) -> dict[str, Any] | None:
        response = (
            get_supabase_admin_client()
            .table("message_attachments")
            .select("id,message_id,storage_path,messages!inner(conversation_id)")
            .eq("id", attachment_id)
            .eq("messages.conversation_id", conversation_id)
            .limit(1)
            .execute()
        )
        return response.data[0] if response.data else None

    def delete_message(self, message_id: str) -> None:
        get_supabase_admin_client().table("messages").delete().eq(
            "id", message_id
        ).execute()

    def mark_read(self, conversation_id: str, user_id: str) -> datetime:
        response = get_supabase_admin_client().rpc(
            "mark_conversation_read_for_user",
            {
                "target_conversation_id": conversation_id,
                "target_user_id": user_id,
            },
        ).execute()
        if not response.data:
            raise RuntimeError("Conversation read state was not updated")
        value = str(response.data).replace("Z", "+00:00")
        return datetime.fromisoformat(value)

    def list_inbox_events(
        self, user_id: str, *, after_sequence_id: int, limit: int
    ) -> tuple[list[dict[str, Any]], bool]:
        response = (
            get_supabase_admin_client()
            .table("user_inbox_events")
            .select(
                "sequence_id,user_id,conversation_id,event_type,actor_user_id,"
                "message_id,payload,created_at,acknowledged_at"
            )
            .eq("user_id", user_id)
            .gt("sequence_id", after_sequence_id)
            .order("sequence_id")
            .limit(limit + 1)
            .execute()
        )
        rows = response.data or []
        return rows[:limit], len(rows) > limit

    def list_inbox_events_for_message(self, message_id: str) -> list[dict[str, Any]]:
        response = (
            get_supabase_admin_client()
            .table("user_inbox_events")
            .select(
                "sequence_id,user_id,conversation_id,event_type,actor_user_id,"
                "message_id,payload,created_at,acknowledged_at"
            )
            .eq("message_id", message_id)
            .order("sequence_id")
            .execute()
        )
        return response.data or []

    def list_conversation_events(
        self,
        conversation_id: str,
        event_type: str,
        *,
        since: str,
        actor_user_id: str | None = None,
    ) -> list[dict[str, Any]]:
        query = (
            get_supabase_admin_client()
            .table("user_inbox_events")
            .select(
                "sequence_id,user_id,conversation_id,event_type,actor_user_id,"
                "message_id,payload,created_at,acknowledged_at"
            )
            .eq("conversation_id", conversation_id)
            .eq("event_type", event_type)
            .gte("created_at", since)
        )
        if actor_user_id is not None:
            query = query.eq("actor_user_id", actor_user_id)
        return query.order("sequence_id").execute().data or []

    def latest_inbox_sequence(self, user_id: str) -> int:
        response = (
            get_supabase_admin_client()
            .table("user_inbox_events")
            .select("sequence_id")
            .eq("user_id", user_id)
            .order("sequence_id", desc=True)
            .limit(1)
            .execute()
        )
        return int(response.data[0]["sequence_id"]) if response.data else 0

    def acknowledge_inbox(self, user_id: str, sequence_id: int) -> int:
        response = get_supabase_admin_client().rpc(
            "acknowledge_inbox_events",
            {
                "target_user_id": user_id,
                "through_sequence_id": sequence_id,
            },
        ).execute()
        return int(response.data or 0)

    def close_conversation(self, conversation_id: str) -> dict[str, Any]:
        closed_at = datetime.now(UTC).isoformat()
        response = (
            get_supabase_admin_client()
            .table("conversations")
            .update({"status": "closed", "closed_at": closed_at})
            .eq("id", conversation_id)
            .execute()
        )
        if not response.data:
            raise RuntimeError("Conversation closure returned no row")
        return response.data[0]
