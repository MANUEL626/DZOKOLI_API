from typing import Annotated

from fastapi import APIRouter, Query, status

from core.dependencies import CurrentUser
from features.reviews.reviews_models import CreateReviewInput, ReviewOutput, ReviewPage
from features.reviews.reviews_service import ReviewsService


router = APIRouter(prefix="/reviews", tags=["reviews"])


@router.post("", response_model=ReviewOutput, status_code=status.HTTP_201_CREATED)
def create_review(
    payload: CreateReviewInput,
    current_user: CurrentUser,
) -> ReviewOutput:
    return ReviewsService().create(current_user.id, payload)


@router.get("/me", response_model=ReviewPage)
def list_my_received_reviews(
    current_user: CurrentUser,
    limit: Annotated[int, Query(ge=1, le=50)] = 20,
    offset: Annotated[int, Query(ge=0)] = 0,
) -> ReviewPage:
    return ReviewsService().list_received(
        current_user.id, limit=limit, offset=offset
    )


@router.get("/users/{user_id}", response_model=ReviewPage)
def list_user_received_reviews(
    user_id: str,
    current_user: CurrentUser,
    limit: Annotated[int, Query(ge=1, le=50)] = 20,
    offset: Annotated[int, Query(ge=0)] = 0,
) -> ReviewPage:
    return ReviewsService().list_received(user_id, limit=limit, offset=offset)
