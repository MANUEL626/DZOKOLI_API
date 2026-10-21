from functools import lru_cache

from supabase import Client, create_client

from config.settings import get_settings


def create_supabase_client() -> Client:
    """Create an isolated anonymous client for an authentication flow."""
    url, key = get_settings().require_supabase()
    return create_client(url, key)


@lru_cache
def get_supabase_client() -> Client:
    url, key = get_settings().require_supabase()
    return create_client(url, key)


@lru_cache
def get_supabase_admin_client() -> Client:
    url, key = get_settings().require_supabase(service_role=True)
    return create_client(url, key)
