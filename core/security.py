import hashlib
import secrets


def generate_one_time_code(length: int = 6) -> str:
    if length < 4:
        raise ValueError("A one-time code must contain at least four digits")
    return "".join(secrets.choice("0123456789") for _ in range(length))


def generate_secure_token() -> str:
    return secrets.token_urlsafe(32)


def hash_secret(value: str) -> str:
    return hashlib.sha256(value.encode("utf-8")).hexdigest()


def verify_secret(value: str, expected_hash: str) -> bool:
    return secrets.compare_digest(hash_secret(value), expected_hash)
