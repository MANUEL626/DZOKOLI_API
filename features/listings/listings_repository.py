"""Supabase persistence operations for published baggage capacity."""
from typing import Any

from config.supabase_client import get_supabase_admin_client
from features.listings.listings_models import (
    CreateListingInput,
    ListingStatus,
    ParcelType,
    UpdateListingInput,
)


class ListingsRepository:
    def get_details(self, listing_id: str, viewer_user_id: str) -> dict[str, Any] | None:
        response = get_supabase_admin_client().rpc(
            "get_listing_details",
            {
                "target_listing_id": listing_id,
                "viewer_user_id": viewer_user_id,
            },
        ).execute()
        return response.data or None

    def list_for_user(
        self,
        user_id: str,
        *,
        limit: int,
        status: ListingStatus | None = None,
        cursor_created_at: str | None = None,
        cursor_id: str | None = None,
    ) -> list[dict[str, Any]]:
        response = get_supabase_admin_client().rpc(
            "list_user_listings",
            {
                "target_user_id": user_id,
                "filter_status": status.value if status else None,
                "cursor_created_at": cursor_created_at,
                "cursor_listing_id": cursor_id,
                "result_limit": limit + 1,
            },
        ).execute()
        return response.data or []

    def list_available(
        self,
        *,
        limit: int,
        cursor_published_at: str | None = None,
        cursor_id: str | None = None,
        parcel_type: ParcelType | None = None,
        departure_location_id: str | None = None,
        arrival_location_id: str | None = None,
        minimum_kg: str | None = None,
        maximum_price_per_kg: str | None = None,
        currency: str | None = None,
    ) -> list[dict[str, Any]]:
        response = get_supabase_admin_client().rpc(
            "search_available_listings",
            {
                "filter_parcel_type": parcel_type.value if parcel_type else None,
                "filter_departure_location_id": departure_location_id,
                "filter_arrival_location_id": arrival_location_id,
                "filter_minimum_kg": minimum_kg,
                "filter_maximum_price_per_kg": maximum_price_per_kg,
                "filter_currency": currency,
                "cursor_published_at": cursor_published_at,
                "cursor_listing_id": cursor_id,
                "result_limit": limit + 1,
            },
        ).execute()
        return response.data or []

    def create(self, user_id: str, payload: CreateListingInput) -> dict[str, Any]:
        response = get_supabase_admin_client().rpc(
            "create_listing_with_trip",
            {
                "target_traveler_user_id": user_id,
                **self._rpc_values(payload.trip, payload.listing),
            },
        ).execute()
        if not response.data:
            raise RuntimeError("Listing creation returned no data")
        return response.data

    def update(
        self, listing_id: str, user_id: str, payload: UpdateListingInput
    ) -> dict[str, Any]:
        response = get_supabase_admin_client().rpc(
            "update_listing_with_trip",
            {
                "target_listing_id": listing_id,
                "target_traveler_user_id": user_id,
                **self._rpc_values(payload, payload),
            },
        ).execute()
        if not response.data:
            raise RuntimeError("Listing update returned no data")
        return response.data

    def cancel(self, listing_id: str, user_id: str) -> dict[str, Any]:
        response = get_supabase_admin_client().rpc(
            "cancel_listing_with_trip",
            {
                "target_listing_id": listing_id,
                "target_traveler_user_id": user_id,
            },
        ).execute()
        if not response.data:
            raise RuntimeError("Listing cancellation returned no data")
        return response.data

    @staticmethod
    def _rpc_values(trip: Any, listing: Any) -> dict[str, Any]:
        return {
            "target_trip_type": trip.type.value,
            "target_departure_location_id": trip.departure_location_id,
            "target_arrival_location_id": trip.arrival_location_id,
            "target_departure_at": trip.departure_at.isoformat(),
            "target_arrival_at": trip.arrival_at.isoformat(),
            "target_transport_reference": trip.transport_reference,
            "target_total_available_kg": str(listing.total_available_kg),
            "target_price_per_kg": str(listing.price_per_kg),
            "target_currency": listing.currency,
            "target_accepted_parcel_types": [
                item.value for item in listing.accepted_parcel_types
            ],
        }
