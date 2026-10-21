from decimal import Decimal
from typing import Annotated

from fastapi import APIRouter, Query, status

from core.dependencies import CurrentUser
from features.listings.listings_models import (
    CreateListingInput,
    ListingDetails,
    ListingPage,
    ListingStatus,
    ParcelType,
    UpdateListingInput,
    UserListingPage,
)
from features.listings.listings_service import ListingsService


router = APIRouter(prefix="/listings", tags=["listings"])


@router.get("", response_model=ListingPage)
def list_available_listings(
    current_user: CurrentUser,
    limit: Annotated[int, Query(ge=1, le=50)] = 20,
    cursor: str | None = None,
) -> ListingPage:
    return ListingsService().list_available(limit=limit, cursor=cursor)


@router.get("/search", response_model=ListingPage)
def search_available_listings(
    current_user: CurrentUser,
    parcel_type: Annotated[ParcelType | None, Query(alias="parcelType")] = None,
    departure_location_id: Annotated[
        str | None, Query(alias="departureLocationId")
    ] = None,
    arrival_location_id: Annotated[
        str | None, Query(alias="arrivalLocationId")
    ] = None,
    minimum_kg: Annotated[Decimal | None, Query(gt=0, alias="minimumKg")] = None,
    maximum_price_per_kg: Annotated[
        Decimal | None, Query(gt=0, alias="maximumPricePerKg")
    ] = None,
    currency: Annotated[str | None, Query(pattern=r"^[A-Z]{3}$")] = None,
    limit: Annotated[int, Query(ge=1, le=50)] = 20,
    cursor: str | None = None,
) -> ListingPage:
    return ListingsService().list_available(
        limit=limit,
        cursor=cursor,
        parcel_type=parcel_type,
        departure_location_id=departure_location_id,
        arrival_location_id=arrival_location_id,
        minimum_kg=minimum_kg,
        maximum_price_per_kg=maximum_price_per_kg,
        currency=currency,
    )


@router.get("/me", response_model=UserListingPage)
def list_my_listings(
    current_user: CurrentUser,
    listing_status: Annotated[ListingStatus | None, Query(alias="status")] = None,
    limit: Annotated[int, Query(ge=1, le=50)] = 20,
    cursor: str | None = None,
) -> UserListingPage:
    return ListingsService().list_user_listings(
        current_user.id,
        status=listing_status,
        limit=limit,
        cursor=cursor,
    )


@router.post("", response_model=ListingDetails, status_code=status.HTTP_201_CREATED)
def create_listing(
    payload: CreateListingInput,
    current_user: CurrentUser,
) -> ListingDetails:
    return ListingsService().create_listing(current_user.id, payload)


@router.put("/{listing_id}", response_model=ListingDetails)
def update_listing(
    listing_id: str,
    payload: UpdateListingInput,
    current_user: CurrentUser,
) -> ListingDetails:
    return ListingsService().update_listing(listing_id, current_user.id, payload)


@router.get("/{listing_id}", response_model=ListingDetails)
def get_listing(
    listing_id: str,
    current_user: CurrentUser,
) -> ListingDetails:
    return ListingsService().get_listing(listing_id, current_user.id)


@router.post("/{listing_id}/cancel", response_model=ListingDetails)
def cancel_listing(
    listing_id: str,
    current_user: CurrentUser,
) -> ListingDetails:
    return ListingsService().cancel_listing(listing_id, current_user.id)
