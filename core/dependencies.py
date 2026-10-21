from dataclasses import dataclass
from typing import Annotated

from fastapi import Depends, HTTPException
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer

from config.supabase_client import create_supabase_client, get_supabase_admin_client


bearer_scheme = HTTPBearer(auto_error=False)


@dataclass(frozen=True, slots=True)
class AuthenticatedUser:
    id: str
    phone: str | None = None


def authenticate_access_token(access_token: str) -> AuthenticatedUser:
    try:
        response = create_supabase_client().auth.get_user(access_token)
    except Exception as exc:
        raise HTTPException(status_code=401, detail="Invalid access token") from exc
    user = response.user
    if user is None:
        raise HTTPException(status_code=401, detail="Invalid access token")
    profile = (
        get_supabase_admin_client()
        .table("users")
        .select("status")
        .eq("id", str(user.id))
        .limit(1)
        .execute()
    )
    if not profile.data or profile.data[0].get("status") != "active":
        raise HTTPException(status_code=403, detail="User account is not active")
    return AuthenticatedUser(id=str(user.id), phone=getattr(user, "phone", None))


def get_current_user(
    credentials: Annotated[HTTPAuthorizationCredentials | None, Depends(bearer_scheme)],
) -> AuthenticatedUser:
    if credentials is None:
        raise HTTPException(status_code=401, detail="Authentication required")
    return authenticate_access_token(credentials.credentials)


CurrentUser = Annotated[AuthenticatedUser, Depends(get_current_user)]


def get_access_token(
    credentials: Annotated[HTTPAuthorizationCredentials | None, Depends(bearer_scheme)],
) -> str:
    if credentials is None:
        raise HTTPException(status_code=401, detail="Authentication required")
    return credentials.credentials


AccessToken = Annotated[str, Depends(get_access_token)]
