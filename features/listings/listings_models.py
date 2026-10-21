"""Pydantic request and response models for published baggage capacity."""

from datetime import datetime
from decimal import Decimal
from enum import StrEnum

from pydantic import Field, field_validator, model_validator

from core.models import APIModel


class TripType(StrEnum):
    PLANE = "plane"
    BOAT = "boat"


class ParcelType(StrEnum):
    DOCUMENT = "document"
    CLOTHING = "clothing"
    ELECTRONICS = "electronics"
    FOOD = "food"
    OTHER = "other"


class ListingStatus(StrEnum):
    DRAFT = "draft"
    OPEN = "open"
    CLOSED = "closed"
    EXPIRED = "expired"
    CANCELLED = "cancelled"


class ListingClosedReason(StrEnum):
    MANUAL = "manual"
    CAPACITY_REACHED = "capacity_reached"
    TRIP_STATUS = "trip_status"
    EXPIRED = "expired"


class TripInput(APIModel):
    type: TripType
    departure_location_id: str
    arrival_location_id: str
    departure_at: datetime
    arrival_at: datetime
    transport_reference: str | None = Field(default=None, max_length=80)

    @model_validator(mode="after")
    def validate_trip(self) -> "TripInput":
        if self.departure_location_id == self.arrival_location_id:
            raise ValueError("Departure and arrival locations must differ")
        if self.arrival_at <= self.departure_at:
            raise ValueError("Arrival must be after departure")
        return self


class ListingInput(APIModel):
    total_available_kg: Decimal = Field(gt=0, max_digits=8, decimal_places=2)
    price_per_kg: Decimal = Field(gt=0, max_digits=18, decimal_places=2)
    currency: str = Field(default="XOF", pattern=r"^[A-Z]{3}$")
    accepted_parcel_types: list[ParcelType] = Field(min_length=1)

    @field_validator("accepted_parcel_types")
    @classmethod
    def parcel_types_must_be_unique(cls, value: list[ParcelType]) -> list[ParcelType]:
        if len(value) != len(set(value)):
            raise ValueError("Accepted parcel types must be unique")
        return value


class CreateListingInput(APIModel):
    trip: TripInput
    listing: ListingInput


class UpdateListingInput(TripInput, ListingInput):
    """Complete editable snapshot of a trip and its listing."""


class TripOutput(APIModel):
    id: str
    traveler_user_id: str
    type: TripType
    departure_location_id: str
    arrival_location_id: str
    departure_at: datetime
    arrival_at: datetime
    transport_reference: str | None = None
    status: str
    created_at: datetime
    updated_at: datetime


class ListingOutput(APIModel):
    id: str
    trip_id: str
    total_available_kg: Decimal
    remaining_kg: Decimal
    price_per_kg: Decimal
    currency: str
    status: ListingStatus
    closed_reason: ListingClosedReason | None = None
    published_at: datetime | None = None
    closed_at: datetime | None = None
    accepted_parcel_types: list[ParcelType]
    created_at: datetime
    updated_at: datetime


class ListingDetails(APIModel):
    trip: TripOutput
    listing: ListingOutput
    cancelled_bookings_count: int = 0


class AvailableListing(APIModel):
    id: str
    trip_id: str
    traveler_user_id: str
    trip_type: TripType
    departure_location_id: str
    arrival_location_id: str
    departure_at: datetime
    arrival_at: datetime
    transport_reference: str | None = None
    total_available_kg: Decimal
    remaining_kg: Decimal
    price_per_kg: Decimal
    currency: str
    accepted_parcel_types: list[ParcelType]
    published_at: datetime


class ListingPage(APIModel):
    items: list[AvailableListing]
    next_cursor: str | None = None
    has_more: bool


class UserListingPage(APIModel):
    items: list[ListingDetails]
    next_cursor: str | None = None
    has_more: bool
