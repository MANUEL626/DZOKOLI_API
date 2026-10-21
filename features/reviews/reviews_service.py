"""Business rules and use cases for traveler reviews."""

from core.exceptions import AppError, ConflictError, ForbiddenError, NotFoundError
from features.reviews.reviews_models import CreateReviewInput, ReviewOutput, ReviewPage
from features.reviews.reviews_repository import ReviewsRepository


class ReviewsService:
    def __init__(self, repository: ReviewsRepository | None = None) -> None:
        self.repository = repository or ReviewsRepository()

    def create(self, user_id: str, payload: CreateReviewInput) -> ReviewOutput:
        try:
            row = self.repository.create(
                booking_id=payload.booking_id,
                reviewer_user_id=user_id,
                rating=payload.rating,
                comment=payload.comment,
            )
            return ReviewOutput.model_validate(row)
        except Exception as exc:
            message = str(exc).lower()
            if "booking not found" in message:
                raise NotFoundError("Booking") from exc
            if "only the booking buyer" in message:
                raise ForbiddenError("Only the sender can review this delivery") from exc
            if "must be completed" in message:
                raise ConflictError("The delivery is not completed") from exc
            if "already been reviewed" in message:
                raise ConflictError("This delivery has already been reviewed") from exc
            raise AppError(
                "Unable to create the review",
                status_code=502,
                code="review_creation_failed",
            ) from exc

    def list_received(
        self, user_id: str, *, limit: int, offset: int
    ) -> ReviewPage:
        try:
            rows = self.repository.list_received(
                user_id, limit=limit, offset=offset
            )
        except Exception as exc:
            raise AppError(
                "Unable to retrieve reviews",
                status_code=502,
                code="review_retrieval_failed",
            ) from exc
        return ReviewPage(
            items=[ReviewOutput.model_validate(row) for row in rows[:limit]],
            limit=limit,
            offset=offset,
            has_more=len(rows) > limit,
        )
