from typing import Any

from config.supabase_client import create_supabase_client, get_supabase_admin_client


class AuthRepository:
    def request_otp(self, phone: str) -> None:
        client = create_supabase_client()
        client.auth.sign_in_with_otp(
            {
                "phone": phone,
                "options": {"should_create_user": True},
            }
        )

    def verify_otp(self, phone: str, code: str) -> Any:
        client = create_supabase_client()
        return client.auth.verify_otp(
            {
                "phone": phone,
                "token": code,
                "type": "sms",
            }
        )

    def refresh_session(self, refresh_token: str) -> Any:
        return create_supabase_client().auth.refresh_session(refresh_token)

    def logout(self, access_token: str, refresh_token: str) -> None:
        client = create_supabase_client()
        client.auth.set_session(access_token, refresh_token)
        client.auth.sign_out()

    def find_profile(self, user_id: str) -> dict[str, Any] | None:
        response = (
            get_supabase_admin_client()
            .table("users")
            .select(
                "id,phone,email,first_name,last_name,profile_picture_path,"
                "profile_completed_at,status"
            )
            .eq("id", user_id)
            .limit(1)
            .execute()
        )
        return response.data[0] if response.data else None
