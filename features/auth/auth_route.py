from fastapi import APIRouter, Response, status

from core.dependencies import AccessToken
from features.auth.auth_models import (
    AuthSession,
    LogoutInput,
    OTPRequested,
    RefreshTokenInput,
    RequestOTPInput,
    VerifyOTPInput,
    VerifyOTPResult,
)
from features.auth.auth_service import AuthService


router = APIRouter(prefix="/auth", tags=["auth"])


@router.post("/phone/request-otp", response_model=OTPRequested, status_code=status.HTTP_202_ACCEPTED)
def request_otp(payload: RequestOTPInput) -> OTPRequested:
    return AuthService().request_otp(payload)


@router.post("/phone/verify-otp", response_model=VerifyOTPResult)
def verify_otp(payload: VerifyOTPInput) -> VerifyOTPResult:
    return AuthService().verify_otp(payload)


@router.post("/refresh", response_model=AuthSession)
def refresh_session(payload: RefreshTokenInput) -> AuthSession:
    return AuthService().refresh_session(payload)


@router.post("/logout", status_code=status.HTTP_204_NO_CONTENT)
def logout(payload: LogoutInput, access_token: AccessToken) -> Response:
    AuthService().logout(access_token, payload)
    return Response(status_code=status.HTTP_204_NO_CONTENT)
