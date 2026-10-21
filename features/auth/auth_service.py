from config.settings import get_settings
from config.supabase_client import get_supabase_admin_client
from core.exceptions import AppError
from features.auth.auth_models import (
    AuthSession,
    AuthUser,
    OTPRequested,
    LogoutInput,
    RefreshTokenInput,
    RequestOTPInput,
    VerifyOTPInput,
    VerifyOTPResult,
)
from features.auth.auth_repository import AuthRepository


class AuthService:
    def __init__(self, repository: AuthRepository | None = None) -> None:
        self.repository = repository or AuthRepository()

    def request_otp(self, payload: RequestOTPInput) -> OTPRequested:
        try:
            self.repository.request_otp(payload.phone)
        except Exception as exc:
            raise AppError(
                "Unable to send the OTP",
                status_code=502,
                code="otp_delivery_failed",
            ) from exc
        return OTPRequested()

    def verify_otp(self, payload: VerifyOTPInput) -> VerifyOTPResult:
        try:
            response = self.repository.verify_otp(payload.phone, payload.code)
        except Exception as exc:
            raise AppError(
                "The OTP is invalid or expired",
                status_code=400,
                code="invalid_otp",
            ) from exc

        if response.user is None or response.session is None:
            raise AppError(
                "Supabase did not create an authenticated session",
                status_code=502,
                code="session_creation_failed",
            )

        profile = self.repository.find_profile(str(response.user.id))
        if profile is None:
            raise AppError(
                "The application profile was not created",
                status_code=500,
                code="profile_creation_failed",
            )
        if profile.get("status") != "active":
            raise AppError(
                "The user account is not active",
                status_code=403,
                code="account_not_active",
            )

        picture_url = None
        if profile.get("profile_picture_path"):
            picture_url = (
                get_supabase_admin_client()
                .storage.from_(get_settings().profile_pictures_bucket)
                .get_public_url(profile["profile_picture_path"])
            )

        is_new = profile.get("profile_completed_at") is None
        return VerifyOTPResult(
            user=AuthUser(
                id=str(response.user.id),
                phone=profile.get("phone"),
                email=profile.get("email"),
                first_name=profile.get("first_name"),
                last_name=profile.get("last_name"),
                profile_picture_url=picture_url,
                profile_completed=not is_new,
            ),
            session=AuthSession(
                access_token=response.session.access_token,
                refresh_token=response.session.refresh_token,
                token_type=response.session.token_type,
                expires_in=response.session.expires_in,
                expires_at=response.session.expires_at,
            ),
            is_new=is_new,
        )

    def refresh_session(self, payload: RefreshTokenInput) -> AuthSession:
        try:
            response = self.repository.refresh_session(payload.refresh_token)
        except Exception as exc:
            raise AppError(
                "The refresh token is invalid or expired",
                status_code=401,
                code="invalid_refresh_token",
            ) from exc
        if response.session is None:
            raise AppError(
                "Supabase did not renew the session",
                status_code=502,
                code="session_refresh_failed",
            )
        if response.user is None:
            raise AppError(
                "Supabase did not return the session user",
                status_code=502,
                code="session_refresh_failed",
            )
        profile = self.repository.find_profile(str(response.user.id))
        if profile is None or profile.get("status") != "active":
            try:
                self.repository.logout(
                    response.session.access_token, response.session.refresh_token
                )
            except Exception:
                pass
            raise AppError(
                "The user account is not active",
                status_code=403,
                code="account_not_active",
            )
        return self._to_session(response.session)

    def logout(self, access_token: str, payload: LogoutInput) -> None:
        try:
            self.repository.logout(access_token, payload.refresh_token)
        except Exception as exc:
            raise AppError(
                "Unable to revoke the session",
                status_code=502,
                code="logout_failed",
            ) from exc

    @staticmethod
    def _to_session(session: object) -> AuthSession:
        return AuthSession(
            access_token=session.access_token,  # type: ignore[attr-defined]
            refresh_token=session.refresh_token,  # type: ignore[attr-defined]
            token_type=session.token_type,  # type: ignore[attr-defined]
            expires_in=session.expires_in,  # type: ignore[attr-defined]
            expires_at=session.expires_at,  # type: ignore[attr-defined]
        )
