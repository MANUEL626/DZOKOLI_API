from typing import Any

from config.supabase_client import get_supabase_admin_client


PROFILE_COLUMNS = (
    "id,phone,email,email_verified_at,first_name,last_name,"
    "profile_picture_path,profile_completed_at,"
    "average_rating,review_count,completed_delivery_count,status,created_at,updated_at"
)


class UsersRepository:
    def find_by_id(self, user_id: str) -> dict[str, Any] | None:
        response = (
            get_supabase_admin_client()
            .table("users")
            .select(PROFILE_COLUMNS)
            .eq("id", user_id)
            .limit(1)
            .execute()
        )
        return response.data[0] if response.data else None

    def complete_profile(
        self,
        user_id: str,
        *,
        first_name: str,
        last_name: str,
        profile_picture_path: str | None,
        completed_at: str,
    ) -> dict[str, Any]:
        values: dict[str, Any] = {
            "first_name": first_name,
            "last_name": last_name,
            "profile_completed_at": completed_at,
        }
        if profile_picture_path is not None:
            values["profile_picture_path"] = profile_picture_path

        response = (
            get_supabase_admin_client()
            .table("users")
            .update(values)
            .eq("id", user_id)
            .execute()
        )
        if not response.data:
            raise RuntimeError("User profile update returned no row")
        return response.data[0]

    def update_profile(self, user_id: str, values: dict[str, Any]) -> dict[str, Any]:
        response = (
            get_supabase_admin_client()
            .table("users")
            .update(values)
            .eq("id", user_id)
            .eq("status", "active")
            .execute()
        )
        if not response.data:
            raise RuntimeError("User profile update returned no row")
        return response.data[0]

    def anonymize_account(self, user_id: str) -> None:
        get_supabase_admin_client().rpc(
            "anonymize_user_account", {"target_user_id": user_id}
        ).execute()

    def soft_delete_auth_user(self, user_id: str) -> None:
        get_supabase_admin_client().auth.admin.delete_user(
            user_id, should_soft_delete=True
        )
