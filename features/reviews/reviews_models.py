"""Pydantic request and response models for traveler reviews."""

from datetime import datetime

from pydantic import Field

from core.models import APIModel


class CreateReviewInput(APIModel):
    booking_id: str
    rating: int = Field(ge=1, le=5)
    comment: str | None = Field(default=None, min_length=1, max_length=1000)


class ReviewOutput(APIModel):
    id: str
    booking_id: str
    reviewer_user_id: str
    reviewed_user_id: str
    rating: int
    comment: str | None = None
    created_at: datetime
    updated_at: datetime


class ReviewPage(APIModel):
    items: list[ReviewOutput]
    limit: int
    offset: int
    has_more: bool
