from pydantic import Field, field_validator

from core.models import APIModel


E164_PATTERN = r"^\+[1-9][0-9]{7,14}$"


class RequestOTPInput(APIModel):
    phone: str = Field(pattern=E164_PATTERN, examples=["+22890123456"])


class VerifyOTPInput(RequestOTPInput):
    code: str = Field(min_length=4, max_length=10)

    @field_validator("code")
    @classmethod
    def code_must_be_numeric(cls, value: str) -> str:
        if not value.isdigit():
            raise ValueError("The OTP code must contain digits only")
        return value


class OTPRequested(APIModel):
    message: str = "OTP sent"


class AuthUser(APIModel):
    id: str
    phone: str | None = None
    email: str | None = None
    first_name: str | None = None
    last_name: str | None = None
    profile_picture_url: str | None = None
    profile_completed: bool


class AuthSession(APIModel):
    access_token: str
    refresh_token: str
    token_type: str
    expires_in: int
    expires_at: int | None = None


class VerifyOTPResult(APIModel):
    user: AuthUser
    session: AuthSession
    is_new: bool


class RefreshTokenInput(APIModel):
    refresh_token: str = Field(min_length=20)


class LogoutInput(RefreshTokenInput):
    pass
