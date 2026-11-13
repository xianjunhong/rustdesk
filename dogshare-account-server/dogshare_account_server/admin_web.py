from dataclasses import dataclass
import hashlib
import re
import secrets
import sqlite3
import time
from typing import Annotated, Literal

from argon2.exceptions import InvalidHashError, VerificationError
from fastapi import APIRouter, Depends, Path, Query, Request, Response
from pydantic import BaseModel, ConfigDict, Field, field_validator

from .activity import record_event
from .admin_ops import act_on_pair, create_web_pairs, list_events, list_pairs, update_pair_note
from .config import Settings
from .service import AccountError, AccountService, token_digest, username_key


ADMIN_COOKIE = "__Secure-dogshare-admin"
MAX_WEB_PAIR_BATCH = 25
_TOKEN_PATTERN = re.compile(r"[A-Za-z0-9_-]{43}")
_CSRF_PATTERN = re.compile(r"[0-9a-f]{64}")
_PAIR_PATH = Annotated[str, Path(min_length=1, max_length=128)]


class AdminLogin(BaseModel):
    model_config = ConfigDict(extra="forbid")
    username: str = Field(strict=True, min_length=3, max_length=64)
    password: str = Field(strict=True, min_length=1, max_length=1024)

    @field_validator("username")
    @classmethod
    def valid_username(cls, value: str) -> str:
        username_key(value)
        return value


class PairBatch(BaseModel):
    model_config = ConfigDict(extra="forbid")
    count: int = Field(strict=True, ge=1, le=MAX_WEB_PAIR_BATCH)


class PairAction(BaseModel):
    model_config = ConfigDict(extra="forbid")
    action: Literal["kick", "disable", "enable", "reset_password", "renew"]
    side: Literal["a", "b", "both"]


class PairNote(BaseModel):
    model_config = ConfigDict(extra="forbid")
    note: str = Field(strict=True, max_length=500)


@dataclass(frozen=True)
class AdminSession:
    digest: str
    username: str
    csrf_token: str

    def actor_in_transaction(self, db: sqlite3.Connection, now: int) -> str:
        return _require_session(db, self.digest, now)["username"]

    def response(self) -> dict:
        return {"admin": {"username": self.username}, "csrf_token": self.csrf_token}


def _initialize_web_admin(service: AccountService) -> None:
    with service.connection() as db:
        db.executescript("""
            CREATE TABLE IF NOT EXISTS web_admins (
                pk INTEGER PRIMARY KEY,
                username_key TEXT NOT NULL UNIQUE,
                username TEXT NOT NULL,
                password_hash TEXT NOT NULL,
                enabled INTEGER NOT NULL DEFAULT 1 CHECK(enabled IN (0,1)),
                created_at INTEGER NOT NULL
            );
            CREATE TABLE IF NOT EXISTS web_admin_sessions (
                token_hash TEXT PRIMARY KEY,
                admin_pk INTEGER NOT NULL REFERENCES web_admins(pk) ON DELETE CASCADE,
                expires_at INTEGER NOT NULL
            );
            CREATE INDEX IF NOT EXISTS web_admin_sessions_admin ON web_admin_sessions(admin_pk);
            CREATE INDEX IF NOT EXISTS web_admin_sessions_expiry ON web_admin_sessions(expires_at);
            CREATE TABLE IF NOT EXISTS web_admin_login_limits (
                key TEXT PRIMARY KEY,
                attempts INTEGER NOT NULL,
                resets_at INTEGER NOT NULL
            );
        """)


def create_web_admin(service: AccountService, username: str, password: str) -> None:
    key = username_key(username)
    password_hash = service._password_hash(password)
    _initialize_web_admin(service)
    try:
        with service.connection() as db:
            db.execute("BEGIN IMMEDIATE")
            now = int(time.time())
            db.execute(
                "INSERT INTO web_admins(username_key, username, password_hash, created_at) VALUES (?, ?, ?, ?)",
                (key, username.strip(), password_hash, now),
            )
    except sqlite3.IntegrityError:
        raise AccountError(409, "admin_exists", "Web administrator already exists.") from None


def disable_web_admin(service: AccountService, username: str) -> None:
    key = username_key(username)
    _initialize_web_admin(service)
    with service.connection() as db:
        db.execute("BEGIN IMMEDIATE")
        row = db.execute("SELECT pk FROM web_admins WHERE username_key = ?", (key,)).fetchone()
        if not row:
            raise AccountError(404, "admin_missing", "Web administrator not found.")
        db.execute("UPDATE web_admins SET enabled = 0 WHERE pk = ?", (row["pk"],))
        db.execute("DELETE FROM web_admin_sessions WHERE admin_pk = ?", (row["pk"],))


def _cookie_token(request: Request) -> str | None:
    token = request.cookies.get(ADMIN_COOKIE, "")
    return token if _TOKEN_PATTERN.fullmatch(token) else None


def _csrf(token: str) -> str:
    return hashlib.sha256(b"dogshare-web-admin-csrf\x00" + token.encode("ascii")).hexdigest()


def _require_session(db: sqlite3.Connection, digest: str, now: int) -> sqlite3.Row:
    row = db.execute(
        """SELECT a.username FROM web_admin_sessions s JOIN web_admins a ON a.pk = s.admin_pk
           WHERE s.token_hash = ? AND s.expires_at > ? AND a.enabled = 1""",
        (digest, now),
    ).fetchone()
    if not row:
        raise AccountError(401, "invalid_admin_session", "Sign in as a web administrator.")
    return row


def _reserve_attempt(service: AccountService, address: str, key: str, now: int) -> None:
    limits = (
        ("ip:" + token_digest(address), service.settings.login_ip_limit),
        ("account:" + token_digest(key), service.settings.login_account_limit),
    )
    with service.connection() as db:
        db.execute("BEGIN IMMEDIATE")
        db.execute("DELETE FROM web_admin_login_limits WHERE resets_at <= ?", (now,))
        retry_after = 0
        for limit_key, maximum in limits:
            row = db.execute("SELECT attempts, resets_at FROM web_admin_login_limits WHERE key = ?",
                             (limit_key,)).fetchone()
            if row and row["attempts"] >= maximum:
                retry_after = max(retry_after, row["resets_at"] - now)
        if not retry_after:
            db.executemany(
                """INSERT INTO web_admin_login_limits(key, attempts, resets_at) VALUES (?, 1, ?)
                   ON CONFLICT(key) DO UPDATE SET attempts = attempts + 1""",
                [(limit_key, now + service.settings.login_window) for limit_key, _ in limits],
            )
    if retry_after:
        raise AccountError(429, "rate_limited", "Too many login attempts. Try again later.", retry_after)


def _login(service: AccountService, settings: Settings, body: AdminLogin, request: Request) -> tuple[str, AdminSession]:
    key = username_key(body.username)
    _reserve_attempt(service, request.client.host if request.client else "unknown", key, int(time.time()))
    with service.connection() as db:
        admin = db.execute("SELECT * FROM web_admins WHERE username_key = ?", (key,)).fetchone()
    stored_hash = admin["password_hash"] if admin else service._dummy_hash
    with service.hashing():
        try:
            verified = service.hasher.verify(stored_hash, body.password)
        except (VerificationError, InvalidHashError):
            verified = False
    denied = AccountError(401, "invalid_credentials", "Invalid administrator username or password.")
    if not verified or not admin or not admin["enabled"]:
        raise denied

    token = secrets.token_urlsafe(32)
    digest = token_digest(token)
    previous = _cookie_token(request)
    with service.connection() as db:
        db.execute("BEGIN IMMEDIATE")
        now = int(time.time())
        current = db.execute("SELECT * FROM web_admins WHERE pk = ?", (admin["pk"],)).fetchone()
        if not current or not current["enabled"] or current["password_hash"] != stored_hash:
            raise denied
        db.execute("DELETE FROM web_admin_sessions WHERE expires_at <= ?", (now,))
        if previous:
            db.execute("DELETE FROM web_admin_sessions WHERE token_hash = ?", (token_digest(previous),))
        db.execute(
            "INSERT INTO web_admin_sessions(token_hash, admin_pk, expires_at) VALUES (?, ?, ?)",
            (digest, current["pk"], now + settings.admin_session_ttl),
        )
        record_event(db, event="admin_login", at=now, pair_id=None, actor=current["username"])
    return token, AdminSession(digest, current["username"], _csrf(token))


def build_admin_router(service: AccountService, settings: Settings) -> APIRouter:
    if not settings.admin_origin:
        raise ValueError("Web administration is disabled")
    _initialize_web_admin(service)

    def require_https(request: Request):
        if request.url.scheme != "https":
            raise AccountError(403, "https_required", "Web administration requires HTTPS.")

    def require_origin(request: Request):
        if request.headers.getlist("origin") != [settings.admin_origin]:
            raise AccountError(403, "invalid_origin", "Request origin is not allowed.")

    def authenticated(request: Request) -> AdminSession:
        token = _cookie_token(request)
        if not token:
            raise AccountError(401, "invalid_admin_session", "Sign in as a web administrator.")
        digest = token_digest(token)
        with service.connection() as db:
            admin = _require_session(db, digest, int(time.time()))
        return AdminSession(digest, admin["username"], _csrf(token))

    def mutation(request: Request, actor: AdminSession = Depends(authenticated)) -> AdminSession:
        require_origin(request)
        headers = request.headers.getlist("x-csrf-token")
        if (len(headers) != 1 or not _CSRF_PATTERN.fullmatch(headers[0])
                or not secrets.compare_digest(headers[0], actor.csrf_token)):
            raise AccountError(403, "invalid_csrf", "Request verification failed.")
        return actor

    router = APIRouter(
        prefix="/admin/api", include_in_schema=False, dependencies=[Depends(require_https)],
    )

    @router.post("/session", dependencies=[Depends(require_origin)])
    def login(body: AdminLogin, request: Request, response: Response):
        token, actor = _login(service, settings, body, request)
        response.set_cookie(
            ADMIN_COOKIE, token, max_age=settings.admin_session_ttl,
            path=settings.admin_cookie_path, secure=True, httponly=True, samesite="strict",
        )
        return actor.response()

    @router.get("/session")
    def session(actor: AdminSession = Depends(authenticated)):
        return actor.response()

    @router.delete("/session")
    def logout(response: Response, actor: AdminSession = Depends(mutation)):
        with service.connection() as db:
            db.execute("BEGIN IMMEDIATE")
            now = int(time.time())
            username = actor.actor_in_transaction(db, now)
            db.execute("DELETE FROM web_admin_sessions WHERE token_hash = ?", (actor.digest,))
            record_event(db, event="admin_logout", at=now, pair_id=None, actor=username)
        response.delete_cookie(
            ADMIN_COOKIE, path=settings.admin_cookie_path, secure=True, httponly=True, samesite="strict",
        )
        return {"ok": True}

    @router.get("/pairs", dependencies=[Depends(authenticated)])
    def pairs(limit: Annotated[int, Query(ge=1, le=100)] = 25,
              offset: Annotated[int, Query(ge=0, le=1_000_000)] = 0,
              q: Annotated[str, Query(max_length=128)] = ""):
        return list_pairs(service, limit, offset, q)

    @router.post("/pairs")
    def create_pairs(body: PairBatch, actor: AdminSession = Depends(mutation)):
        return create_web_pairs(service, body.count, actor.actor_in_transaction)

    @router.post("/pairs/{pair_id}/action")
    def pair_action(pair_id: _PAIR_PATH, body: PairAction, actor: AdminSession = Depends(mutation)):
        return act_on_pair(service, pair_id, body.action, body.side, actor.actor_in_transaction)

    @router.put("/pairs/{pair_id}/note")
    def pair_note(pair_id: _PAIR_PATH, body: PairNote, actor: AdminSession = Depends(mutation)):
        return update_pair_note(service, pair_id, body.note, actor.actor_in_transaction)

    @router.get("/events", dependencies=[Depends(authenticated)])
    def events(pair_id: Annotated[str | None, Query(max_length=128)] = None,
               limit: Annotated[int, Query(ge=1, le=100)] = 50,
               offset: Annotated[int, Query(ge=0, le=1_000_000)] = 0):
        return list_events(service, pair_id, limit, offset)

    return router
