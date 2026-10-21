"""Business rules and use cases for published baggage capacity."""
import base64
import binascii
import json
from datetime import datetime
from decimal import Decimal
from typing import NoReturn

from core.exceptions import AppError, ConflictError, ForbiddenError, NotFoundError
from features.listings.listings_models import (
    CreateListingInput,
    AvailableListing,
    ListingDetails,
    ListingPage,
    ListingStatus,
    ParcelType,
    UpdateListingInput,
    UserListingPage,
)
from features.listings.listings_repository import ListingsRepository


class ListingsService:
    def __init__(self, repository: ListingsRepository | None = None) -> None:
        self.repository = repository or ListingsRepository()

    def create_listing(
        self, user_id: str, payload: CreateListingInput
    ) -> ListingDetails:
        try:
            return ListingDetails.model_validate(self.repository.create(user_id, payload))
        except Exception as exc:
            self._raise_domain_error(exc, operation="create")

    def get_listing(self, listing_id: str, user_id: str) -> ListingDetails:
        try:
            data = self.repository.get_details(listing_id, user_id)
        except Exception as exc:
            raise AppError(
                "Unable to retrieve the listing",
                status_code=502,
                code="listing_retrieval_failed",
            ) from exc
        if data is None:
            raise NotFoundError("Listing")
        return ListingDetails.model_validate(data)

    def list_user_listings(
        self,
        user_id: str,
        *,
        limit: int,
        status: ListingStatus | None = None,
        cursor: str | None = None,
    ) -> UserListingPage:
        cursor_created_at, cursor_id = self._decode_cursor(cursor, key="createdAt")
        try:
            rows = self.repository.list_for_user(
                user_id,
                limit=limit,
                status=status,
                cursor_created_at=cursor_created_at,
                cursor_id=cursor_id,
            )
        except Exception as exc:
            raise AppError(
                "Unable to retrieve your listings",
                status_code=502,
                code="user_listings_retrieval_failed",
            ) from exc

        has_more = len(rows) > limit
        visible_rows = rows[:limit]
        next_cursor = None
        if has_more and visible_rows:
            last = visible_rows[-1]
            next_cursor = self._encode_cursor(
                last["sort_created_at"], last["sort_id"], key="createdAt"
            )
        return UserListingPage(
            items=[ListingDetails.model_validate(row["result"]) for row in visible_rows],
            next_cursor=next_cursor,
            has_more=has_more,
        )

    def list_available(
        self,
        *,
        limit: int,
        cursor: str | None = None,
        parcel_type: ParcelType | None = None,
        departure_location_id: str | None = None,
        arrival_location_id: str | None = None,
        minimum_kg: Decimal | None = None,
        maximum_price_per_kg: Decimal | None = None,
        currency: str | None = None,
    ) -> ListingPage:
        cursor_published_at, cursor_id = self._decode_cursor(cursor, key="publishedAt")
        try:
            rows = self.repository.list_available(
                limit=limit,
                cursor_published_at=cursor_published_at,
                cursor_id=cursor_id,
                parcel_type=parcel_type,
                departure_location_id=departure_location_id,
                arrival_location_id=arrival_location_id,
                minimum_kg=str(minimum_kg) if minimum_kg is not None else None,
                maximum_price_per_kg=(
                    str(maximum_price_per_kg)
                    if maximum_price_per_kg is not None
                    else None
                ),
                currency=currency,
            )
        except Exception as exc:
            raise AppError(
                "Unable to retrieve available listings",
                status_code=502,
                code="listing_search_failed",
            ) from exc

        has_more = len(rows) > limit
        visible_rows = rows[:limit]
        next_cursor = None
        if has_more and visible_rows:
            last = visible_rows[-1]
            next_cursor = self._encode_cursor(
                last["published_at"], last["id"], key="publishedAt"
            )
        return ListingPage(
            items=[AvailableListing.model_validate(row) for row in visible_rows],
            next_cursor=next_cursor,
            has_more=has_more,
        )

    def update_listing(
        self, listing_id: str, user_id: str, payload: UpdateListingInput
    ) -> ListingDetails:
        try:
            return ListingDetails.model_validate(
                self.repository.update(listing_id, user_id, payload)
            )
        except Exception as exc:
            self._raise_domain_error(exc, operation="update")

    def cancel_listing(self, listing_id: str, user_id: str) -> ListingDetails:
        try:
            return ListingDetails.model_validate(
                self.repository.cancel(listing_id, user_id)
            )
        except Exception as exc:
            self._raise_domain_error(exc, operation="cancel")

    @staticmethod
    def _raise_domain_error(exc: Exception, *, operation: str) -> NoReturn:
        message = str(exc).lower()
        if "listing not found" in message:
            raise NotFoundError("Listing") from exc
        if "does not own" in message:
            raise ForbiddenError("You do not own this listing") from exc
        if "delivery has started" in message:
            raise ConflictError("The listing cannot be changed after delivery has started") from exc
        if "already cancelled" in message:
            raise ConflictError("The listing is already cancelled") from exc
        if "cannot be edited" in message:
            raise ConflictError("The listing can no longer be edited") from exc
        if "active" in message or "incompatible" in message:
            raise AppError(
                "The trip or listing data is invalid",
                code="invalid_listing_data",
            ) from exc
        raise AppError(
            f"Unable to {operation} the listing",
            status_code=502,
            code=f"listing_{operation}_failed",
        ) from exc

    @staticmethod
    def _encode_cursor(timestamp: str, listing_id: str, *, key: str) -> str:
        raw = json.dumps({key: timestamp, "id": listing_id}).encode()
        return base64.urlsafe_b64encode(raw).decode().rstrip("=")

    @staticmethod
    def _decode_cursor(
        cursor: str | None, *, key: str
    ) -> tuple[str | None, str | None]:
        if cursor is None:
            return None, None
        try:
            padded = cursor + "=" * (-len(cursor) % 4)
            value = json.loads(base64.urlsafe_b64decode(padded).decode())
            timestamp = datetime.fromisoformat(value[key].replace("Z", "+00:00"))
            return timestamp.isoformat(), str(value["id"])
        except (ValueError, KeyError, TypeError, json.JSONDecodeError, binascii.Error) as exc:
            raise AppError("Invalid pagination cursor", code="invalid_cursor") from exc
