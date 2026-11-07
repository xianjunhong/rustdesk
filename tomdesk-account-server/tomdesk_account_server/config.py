from dataclasses import dataclass
import os
from pathlib import Path
import re
from urllib.parse import urlsplit


def env_int(name: str, default: int, minimum: int, maximum: int) -> int:
    value = int(os.environ.get(name, str(default)))
    if not minimum <= value <= maximum:
        raise ValueError(f"{name} must be between {minimum} and {maximum}")
    return value


def admin_origin_from_env() -> str:
    value = os.environ.get("TOMDESK_ADMIN_ORIGIN", "").strip()
    if not value:
        return ""
    try:
        url = urlsplit(value)
        _ = url.port
    except ValueError:
        raise ValueError("TOMDESK_ADMIN_ORIGIN must be an HTTPS origin.") from None
    if (
        url.scheme != "https" or not url.hostname or url.username is not None
        or url.password is not None or url.path not in ("", "/")
        or url.query or url.fragment or any(c.isspace() for c in value)
    ):
        raise ValueError("TOMDESK_ADMIN_ORIGIN must be an HTTPS origin.")
    return f"https://{url.netloc.lower()}"


def admin_cookie_path_from_env() -> str:
    value = os.environ.get("TOMDESK_ADMIN_PATH", "/admin")
    if len(value) > 128 or not re.fullmatch(r"/(?:[a-zA-Z0-9_-]+/)*admin", value):
        raise ValueError("TOMDESK_ADMIN_PATH must be an absolute path ending in /admin.")
    return value


@dataclass(frozen=True)
class Settings:
    db_path: Path = Path("data/accounts.sqlite3")
    session_ttl: int = 43200
    remember_ttl: int = 604800
    ticket_ttl: int = 300
    login_window: int = 60
    login_ip_limit: int = 30
    login_account_limit: int = 10
    hash_concurrency: int = 2
    public_docs: bool = False
    admin_origin: str = ""
    admin_cookie_path: str = "/admin"
    admin_session_ttl: int = 3600

    @classmethod
    def from_env(cls) -> "Settings":
        docs = os.environ.get("TOMDESK_PUBLIC_DOCS", "0")
        if docs not in ("0", "1"):
            raise ValueError("TOMDESK_PUBLIC_DOCS must be 0 or 1")
        return cls(
            db_path=Path(os.environ.get("TOMDESK_ACCOUNT_DB", "data/accounts.sqlite3")).resolve(),
            session_ttl=env_int("TOMDESK_SESSION_TTL_SECONDS", 43200, 60, 7776000),
            remember_ttl=env_int("TOMDESK_REMEMBER_TTL_SECONDS", 604800, 60, 7776000),
            ticket_ttl=env_int("TOMDESK_TICKET_TTL_SECONDS", 300, 30, 900),
            login_window=env_int("TOMDESK_LOGIN_WINDOW_SECONDS", 60, 1, 3600),
            login_ip_limit=env_int("TOMDESK_LOGIN_IP_LIMIT", 30, 1, 10000),
            login_account_limit=env_int("TOMDESK_LOGIN_ACCOUNT_LIMIT", 10, 1, 1000),
            hash_concurrency=env_int("TOMDESK_HASH_CONCURRENCY", 2, 1, 8),
            public_docs=docs == "1",
            admin_origin=admin_origin_from_env(),
            admin_cookie_path=admin_cookie_path_from_env(),
            admin_session_ttl=env_int("TOMDESK_ADMIN_SESSION_TTL_SECONDS", 3600, 300, 86400),
        )
