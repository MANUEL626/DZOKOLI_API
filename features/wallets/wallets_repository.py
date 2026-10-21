from typing import Any

from config.supabase_client import get_supabase_admin_client


class WalletsRepository:
    def list_for_user(self, user_id: str) -> list[dict[str, Any]]:
        response = (
            get_supabase_admin_client()
            .table("wallets")
            .select(
                "id,user_id,currency,available_balance,reserved_balance,"
                "pending_balance,status,created_at,updated_at"
            )
            .eq("user_id", user_id)
            .order("currency")
            .execute()
        )
        return response.data or []
