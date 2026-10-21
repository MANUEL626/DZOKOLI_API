from datetime import UTC, datetime
from uuid import uuid4

from config.settings import get_settings
from config.supabase_client import get_supabase_admin_client
from core.exceptions import AppError, ConflictError, NotFoundError
from features.users.users_models import UserProfile
from features.users.users_repository import UsersRepository


ALLOWED_PROFILE_PICTURE_TYPES = {
    "image/jpeg": ".jpg",
    "image/png": ".png",
    "image/webp": ".webp",
}


class UsersService:
    def __init__(self, repository: UsersRepository | None = None) -> None:
        self.repository = repository or UsersRepository()
        self.settings = get_settings()

    def get_profile(self, user_id: str) -> UserProfile:
        profile = self.repository.find_by_id(user_id)
        if profile is None:
            raise NotFoundError("User")
        return self._to_profile(profile)

    def complete_profile(
        self,
        user_id: str,
        *,
        first_name: str,
        last_name: str,
        picture_content: bytes | None,
        picture_content_type: str | None,
    ) -> UserProfile:
        current = self.repository.find_by_id(user_id)
        if current is None:
            raise NotFoundError("User")

        first_name = first_name.strip()
        last_name = last_name.strip()
        if not first_name or not last_name:
            raise AppError("First name and last name are required", code="invalid_profile")

        if picture_content is None:
            raise AppError(
                "A profile picture is required to complete the profile",
                code="profile_picture_required",
            )
        new_path = self._upload_picture(
            user_id, picture_content, picture_content_type
        )

        try:
            completed = self.repository.complete_profile(
                user_id,
                first_name=first_name,
                last_name=last_name,
                profile_picture_path=new_path,
                completed_at=datetime.now(UTC).isoformat(),
            )
        except Exception as exc:
            if new_path:
                self._delete_picture(new_path)
            raise AppError(
                "Unable to save the user profile",
                status_code=500,
                code="profile_update_failed",
            ) from exc

        old_path = current.get("profile_picture_path")
        if new_path and old_path and old_path != new_path:
            self._delete_picture(old_path)
        return self._to_profile(completed)

    def update_profile(
        self,
        user_id: str,
        *,
        first_name: str | None,
        last_name: str | None,
        picture_content: bytes | None,
        picture_content_type: str | None,
        remove_profile_picture: bool,
    ) -> UserProfile:
        current = self.repository.find_by_id(user_id)
        if current is None:
            raise NotFoundError("User")
        if picture_content is not None and remove_profile_picture:
            raise AppError(
                "A profile picture cannot be uploaded and removed simultaneously",
                code="invalid_profile_update",
            )

        values: dict[str, str | None] = {}
        for field, value in (("first_name", first_name), ("last_name", last_name)):
            if value is not None:
                cleaned = value.strip()
                if not cleaned:
                    raise AppError(
                        "First name and last name cannot be empty",
                        code="invalid_profile",
                    )
                values[field] = cleaned

        new_path = None
        if picture_content is not None:
            new_path = self._upload_picture(
                user_id, picture_content, picture_content_type
            )
            values["profile_picture_path"] = new_path
        elif remove_profile_picture:
            if current.get("profile_completed_at") is not None:
                raise AppError(
                    "A completed profile must retain a profile picture",
                    code="profile_picture_required",
                )
            values["profile_picture_path"] = None

        if not values:
            raise AppError("No profile change was provided", code="empty_profile_update")
        try:
            updated = self.repository.update_profile(user_id, values)
        except Exception as exc:
            if new_path:
                self._delete_picture(new_path)
            raise AppError(
                "Unable to save the user profile",
                status_code=500,
                code="profile_update_failed",
            ) from exc

        old_path = current.get("profile_picture_path")
        if old_path and old_path != updated.get("profile_picture_path"):
            self._delete_picture(old_path)
        return self._to_profile(updated)

    def delete_account(self, user_id: str) -> None:
        current = self.repository.find_by_id(user_id)
        if current is None:
            raise NotFoundError("User")
        try:
            self.repository.anonymize_account(user_id)
        except Exception as exc:
            if "active operational or financial obligations" in str(exc).lower():
                raise ConflictError(
                    "The account cannot be deleted while it has active deliveries or funds"
                ) from exc
            raise AppError(
                "Unable to delete the account",
                status_code=500,
                code="account_deletion_failed",
            ) from exc

        old_path = current.get("profile_picture_path")
        if old_path:
            self._delete_picture(old_path)
        try:
            self.repository.soft_delete_auth_user(user_id)
        except Exception as exc:
            # The application account is already disabled and all authenticated
            # endpoints reject it; report the Auth cleanup failure for retry/alerting.
            raise AppError(
                "The account was disabled but its authentication identity could not be removed",
                status_code=502,
                code="auth_identity_deletion_failed",
            ) from exc

    def _upload_picture(
        self, user_id: str, content: bytes, content_type: str | None
    ) -> str:
        extension = ALLOWED_PROFILE_PICTURE_TYPES.get(content_type or "")
        if extension is None:
            raise AppError(
                "Profile picture must be a JPEG, PNG, or WebP image",
                status_code=415,
                code="unsupported_profile_picture",
            )
        if len(content) > self.settings.profile_picture_max_bytes:
            raise AppError(
                "Profile picture is too large",
                status_code=413,
                code="profile_picture_too_large",
            )
        if not content or not self._matches_image_signature(content_type or "", content):
            raise AppError(
                "The uploaded file content does not match its image type",
                status_code=415,
                code="invalid_profile_picture",
            )
        path = f"{user_id}/{uuid4().hex}{extension}"
        try:
            get_supabase_admin_client().storage.from_(
                self.settings.profile_pictures_bucket
            ).upload(
                path,
                content,
                {"content-type": content_type, "upsert": "false"},
            )
        except Exception as exc:
            raise AppError(
                "Unable to upload the profile picture",
                status_code=502,
                code="profile_picture_upload_failed",
            ) from exc
        return path

    @staticmethod
    def _matches_image_signature(content_type: str, content: bytes) -> bool:
        if content_type == "image/jpeg":
            return content.startswith(b"\xff\xd8\xff")
        if content_type == "image/png":
            return content.startswith(b"\x89PNG\r\n\x1a\n")
        if content_type == "image/webp":
            return (
                len(content) >= 12
                and content.startswith(b"RIFF")
                and content[8:12] == b"WEBP"
            )
        return False

    def _delete_picture(self, path: str) -> None:
        try:
            get_supabase_admin_client().storage.from_(
                self.settings.profile_pictures_bucket
            ).remove([path])
        except Exception:
            # Storage cleanup can be retried asynchronously without rolling back the profile.
            return

    def _to_profile(self, profile: dict) -> UserProfile:
        picture_url = None
        if profile.get("profile_picture_path"):
            picture_url = (
                get_supabase_admin_client()
                .storage.from_(self.settings.profile_pictures_bucket)
                .get_public_url(profile["profile_picture_path"])
            )
        return UserProfile(
            id=str(profile["id"]),
            phone=profile.get("phone"),
            email=profile.get("email"),
            email_verified_at=profile.get("email_verified_at"),
            first_name=profile.get("first_name"),
            last_name=profile.get("last_name"),
            profile_picture_url=picture_url,
            profile_completed_at=profile.get("profile_completed_at"),
            average_rating=profile["average_rating"],
            review_count=profile["review_count"],
            completed_delivery_count=profile["completed_delivery_count"],
            status=profile["status"],
            created_at=profile["created_at"],
            updated_at=profile["updated_at"],
        )
