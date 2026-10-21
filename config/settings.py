import os
from dataclasses import dataclass
from functools import lru_cache

from dotenv import load_dotenv


load_dotenv()


def _as_bool(value: str | None, default: bool) -> bool:
    if value is None:
        return default
    return value.strip().lower() in {"1", "true", "yes", "on"}


def _as_list(value: str | None, default: list[str]) -> list[str]:
    if not value:
        return default
    return [item.strip() for item in value.split(",") if item.strip()]


@dataclass(frozen=True, slots=True)
class Settings:
    app_name: str
    app_version: str
    environment: str
    api_v1_prefix: str
    docs_enabled: bool
    log_level: str
    cors_origins: list[str]
    supabase_url: str | None
    supabase_anon_key: str | None
    supabase_service_key: str | None
    profile_pictures_bucket: str
    profile_picture_max_bytes: int
    conversation_media_bucket: str
    conversation_media_max_bytes: int
    conversation_signed_url_expires_in: int
    redis_url: str | None
    redis_conversation_channel: str

    def require_supabase(self, *, service_role: bool = False) -> tuple[str, str]:
        key = self.supabase_service_key if service_role else self.supabase_anon_key
        key_name = "SUPABASE_SERVICE_KEY" if service_role else "SUPABASE_ANON_KEY"
        missing = [
            name
            for name, value in (("SUPABASE_URL", self.supabase_url), (key_name, key))
            if not value
        ]
        if missing:
            raise RuntimeError(f"Missing required configuration: {', '.join(missing)}")
        return self.supabase_url, key  # type: ignore[return-value]


@lru_cache
def get_settings() -> Settings:
    return Settings(
        app_name=os.getenv("APP_NAME", "Dzokoli API"),
        app_version=os.getenv("APP_VERSION", "0.1.0"),
        environment=os.getenv("APP_ENV", "development"),
        api_v1_prefix=os.getenv("API_V1_PREFIX", "/api/v1"),
        docs_enabled=_as_bool(os.getenv("DOCS_ENABLED"), True),
        log_level=os.getenv("LOG_LEVEL", "INFO").upper(),
        cors_origins=_as_list(os.getenv("CORS_ORIGINS"), ["http://localhost:3000"]),
        supabase_url=os.getenv("SUPABASE_URL"),
        supabase_anon_key=os.getenv("SUPABASE_ANON_KEY"),
        supabase_service_key=os.getenv("SUPABASE_SERVICE_KEY"),
        profile_pictures_bucket=os.getenv("PROFILE_PICTURES_BUCKET", "profile-pictures"),
        profile_picture_max_bytes=int(os.getenv("PROFILE_PICTURE_MAX_BYTES", "5242880")),
        conversation_media_bucket=os.getenv(
            "CONVERSATION_MEDIA_BUCKET", "conversation-media"
        ),
        conversation_media_max_bytes=int(
            os.getenv("CONVERSATION_MEDIA_MAX_BYTES", "52428800")
        ),
        conversation_signed_url_expires_in=int(
            os.getenv("CONVERSATION_SIGNED_URL_EXPIRES_IN", "900")
        ),
        redis_url=os.getenv("REDIS_URL"),
        redis_conversation_channel=os.getenv(
            "REDIS_CONVERSATION_CHANNEL", "dzokoli:conversations"
        ),
    )
