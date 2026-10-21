from datetime import datetime
from decimal import Decimal

from core.models import APIModel


class UserProfile(APIModel):
    id: str
    phone: str | None = None
    email: str | None = None
    email_verified_at: datetime | None = None
    first_name: str | None = None
    last_name: str | None = None
    profile_picture_url: str | None = None
    profile_completed_at: datetime | None = None
    average_rating: Decimal
    review_count: int
    completed_delivery_count: int
    status: str
    created_at: datetime
    updated_at: datetime
