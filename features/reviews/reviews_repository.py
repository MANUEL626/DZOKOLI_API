"""Supabase persistence operations for traveler reviews."""

from typing import Any

from config.supabase_client import get_supabase_admin_client


REVIEW_COLUMNS = (
    "id,booking_id,reviewer_user_id,reviewed_user_id,rating,comment,"
    "created_at,updated_at"
)


class ReviewsRepository:
    def create(
        self,
        *,
        booking_id: str,
        reviewer_user_id: str,
        rating: int,
        comment: str | None,
    ) -> dict[str, Any]:
        response = get_supabase_admin_client().rpc(
            "submit_delivery_review",
            {
                "target_booking_id": booking_id,
                "target_reviewer_user_id": reviewer_user_id,
                "target_rating": rating,
                "target_comment": comment,
            },
        ).execute()
        if not response.data:
            raise RuntimeError("Review creation returned no data")
        if isinstance(response.data, list):
            return response.data[0]
        return response.data

    def list_received(
        self, reviewed_user_id: str, *, limit: int, offset: int
    ) -> list[dict[str, Any]]:
        response = (
            get_supabase_admin_client()
            .table("reviews")
            .select(REVIEW_COLUMNS)
            .eq("reviewed_user_id", reviewed_user_id)
            .order("created_at", desc=True)
            .order("id", desc=True)
            .range(offset, offset + limit)
            .execute()
        )
        return response.data or []
