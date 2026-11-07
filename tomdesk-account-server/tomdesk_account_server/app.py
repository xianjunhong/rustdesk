import asyncio
from contextlib import asynccontextmanager, suppress
import logging
from pathlib import Path
from typing import Annotated, Any, Literal
import sqlite3

from fastapi import FastAPI, Header, Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import FileResponse, JSONResponse, RedirectResponse
from pydantic import BaseModel, ConfigDict, Field, StrictBool, field_validator
from starlette.exceptions import HTTPException

from .config import Settings
from .service import AccountError, AccountService, bearer_token, username_key


NO_CACHE = {"Cache-Control": "no-store", "Pragma": "no-cache"}
logger = logging.getLogger(__name__)
ADMIN_HEADERS = {
    "Content-Security-Policy": (
        "default-src 'none'; script-src 'self'; style-src 'self'; "
        "connect-src 'self'; img-src 'self'; base-uri 'none'; "
        "frame-ancestors 'none'; form-action 'self'"
    ),
    "X-Content-Type-Options": "nosniff",
    "X-Frame-Options": "DENY",
    "Referrer-Policy": "no-referrer",
}


def error_response(status: int, code: str, message: str, retry_after: int | None = None):
    headers = dict(NO_CACHE)
    if status == 401:
        headers["WWW-Authenticate"] = "Bearer"
    if retry_after is not None:
        headers["Retry-After"] = str(retry_after)
    return JSONResponse(status_code=status, content={"error": message, "code": code}, headers=headers)


class BodyLimitMiddleware:
    def __init__(self, app, limit: int = 16384):
        self.app = app
        self.limit = limit

    async def __call__(self, scope, receive, send):
        if scope["type"] != "http" or scope["method"] != "POST":
            await self.app(scope, receive, send)
            return
        body = bytearray()
        while True:
            message = await receive()
            if message["type"] == "http.disconnect":
                return
            body.extend(message.get("body", b""))
            if len(body) > self.limit:
                await error_response(413, "body_too_large", "Request body is too large.")(scope, receive, send)
                return
            if not message.get("more_body", False):
                break
        replayed = False

        async def replay():
            nonlocal replayed
            if not replayed:
                replayed = True
                return {"type": "http.request", "body": bytes(body), "more_body": False}
            return await receive()

        await self.app(scope, replay, send)


class IdentityRequest(BaseModel):
    model_config = ConfigDict(extra="ignore")
    id: str = Field(strict=True, min_length=1, max_length=256)
    uuid: str = Field(strict=True, min_length=1, max_length=256)

    @field_validator("id", "uuid")
    @classmethod
    def identity_is_printable(cls, value: str) -> str:
        if value != value.strip() or not value.isprintable():
            raise ValueError("Invalid device identity")
        return value


class LoginRequest(IdentityRequest):
    username: str = Field(strict=True, min_length=3, max_length=64)
    password: str = Field(strict=True, min_length=1, max_length=1024)
    type: Literal["account"] = "account"
    client_role: Literal["controller", "receiver"] | None = None
    autoLogin: StrictBool = False
    deviceInfo: dict[str, Any] | None = None

    @field_validator("username")
    @classmethod
    def valid_username(cls, value: str) -> str:
        username_key(value)
        return value


class AuthorizeRequest(IdentityRequest):
    action: Literal["remote", "subtitles"]


ConnectionType = Literal["remote", "file_transfer", "port_forward", "view_camera", "terminal"]


class TicketRequest(IdentityRequest):
    target_id: str = Field(strict=True, min_length=1, max_length=256)
    conn_type: ConnectionType
    supports_pair_activation: StrictBool = False


class ActivatePairRequest(IdentityRequest):
    ticket: str = Field(strict=True, min_length=32, max_length=128)
    target_id: str = Field(strict=True, min_length=1, max_length=256)


class ConsumeRequest(IdentityRequest):
    ticket: str = Field(strict=True, min_length=32, max_length=128)
    source_id: str = Field(strict=True, min_length=1, max_length=256)
    conn_type: ConnectionType


def create_app(settings: Settings | None = None) -> FastAPI:
    settings = settings or Settings.from_env()
    service = AccountService(settings)

    @asynccontextmanager
    async def lifespan(app):
        if not settings.admin_origin:
            yield
            return

        async def sweep():
            while True:
                await asyncio.sleep(30)
                try:
                    await asyncio.to_thread(service.sweep_activity)
                except sqlite3.Error as exc:
                    logger.warning("Account activity sweep failed (%s)", type(exc).__name__)

        task = asyncio.create_task(sweep())
        try:
            yield
        finally:
            task.cancel()
            with suppress(asyncio.CancelledError):
                await task

    app = FastAPI(
        lifespan=lifespan,
        title="TomDesk account service",
        docs_url="/docs" if settings.public_docs else None,
        redoc_url=None,
        openapi_url="/openapi.json" if settings.public_docs else None,
    )
    app.state.account_service = service
    app.add_middleware(BodyLimitMiddleware)

    @app.middleware("http")
    async def no_cache(request: Request, call_next):
        response = await call_next(request)
        response.headers.update(NO_CACHE)
        if request.url.path == "/admin" or request.url.path.startswith("/admin/"):
            response.headers.update(ADMIN_HEADERS)
        return response

    @app.exception_handler(AccountError)
    async def account_error(request: Request, exc: AccountError):
        return error_response(exc.status, exc.code, exc.message, exc.retry_after)

    @app.exception_handler(RequestValidationError)
    async def validation_error(request: Request, exc: RequestValidationError):
        # Validation details can include the supplied password or bearer payload.
        return error_response(422, "invalid_request", "Invalid request body.")

    @app.exception_handler(HTTPException)
    async def http_error(request: Request, exc: HTTPException):
        return error_response(exc.status_code, "http_error", "Request is not available.")

    @app.exception_handler(sqlite3.Error)
    async def database_error(request: Request, exc: sqlite3.Error):
        logger.error("Account database operation failed (%s)", type(exc).__name__)
        return error_response(503, "unavailable", "Account service is temporarily unavailable.", 1)

    @app.exception_handler(Exception)
    async def unexpected_error(request: Request, exc: Exception):
        logger.error("Account request failed (%s)", type(exc).__name__)
        return error_response(500, "internal_error", "Account service failed to process the request.")

    @app.get("/health")
    def health():
        with service.connection() as db:
            db.execute("SELECT 1").fetchone()
        return {"status": "ok"}

    @app.get("/api/login-options")
    def login_options():
        return []

    @app.post("/api/login")
    def login(body: LoginRequest, request: Request, authorization: Annotated[str | None, Header()] = None):
        address = request.client.host if request.client else "unknown"
        return service.login(
            body.username, body.password, body.id, body.uuid, body.autoLogin, address, body.client_role,
            prior_authorization=authorization,
        )

    @app.post("/api/currentUser")
    def current_user(body: IdentityRequest, authorization: Annotated[str | None, Header()] = None):
        return service.authorize(bearer_token(authorization), body.id, body.uuid)["user"]

    @app.post("/api/logout")
    def logout(body: IdentityRequest, authorization: Annotated[str | None, Header()] = None):
        service.logout(bearer_token(authorization), body.id, body.uuid)
        return {"success": True}

    @app.post("/api/tomdesk/authorize")
    def authorize(body: AuthorizeRequest, authorization: Annotated[str | None, Header()] = None):
        return service.authorize(bearer_token(authorization), body.id, body.uuid)

    @app.post("/api/tomdesk/paired-device")
    def paired_device(body: IdentityRequest, authorization: Annotated[str | None, Header()] = None):
        return service.paired_device(bearer_token(authorization), body.id, body.uuid)

    @app.post("/api/tomdesk/connection-ticket")
    def connection_ticket(body: TicketRequest, authorization: Annotated[str | None, Header()] = None):
        return service.connection_ticket(
            bearer_token(authorization), body.id, body.uuid, body.target_id, body.conn_type,
            body.supports_pair_activation,
        )

    @app.post("/api/tomdesk/activate-pair")
    def activate_pair(body: ActivatePairRequest, authorization: Annotated[str | None, Header()] = None):
        return service.activate_pair(
            bearer_token(authorization), body.id, body.uuid, body.ticket, body.target_id
        )

    @app.post("/api/tomdesk/consume-ticket")
    def consume_ticket(body: ConsumeRequest, authorization: Annotated[str | None, Header()] = None):
        return service.consume_ticket(
            bearer_token(authorization), body.id, body.uuid, body.ticket, body.source_id, body.conn_type
        )

    @app.post("/api/tomdesk/connection-status")
    def connection_status(body: ConsumeRequest, authorization: Annotated[str | None, Header()] = None):
        return service.connection_status(
            bearer_token(authorization), body.id, body.uuid, body.ticket, body.source_id, body.conn_type
        )

    if settings.admin_origin:
        from .admin_web import build_admin_router

        app.include_router(build_admin_router(service, settings))
        admin_static = Path(__file__).with_name("admin_static")

        def require_admin_https(request: Request):
            if request.url.scheme != "https":
                raise HTTPException(status_code=404)

        @app.get("/admin", include_in_schema=False)
        def admin_redirect(request: Request):
            require_admin_https(request)
            return RedirectResponse(settings.admin_cookie_path + "/", status_code=308)

        @app.get("/admin/", include_in_schema=False)
        def admin_index(request: Request):
            require_admin_https(request)
            return FileResponse(admin_static / "index.html", media_type="text/html")

        @app.get("/admin/assets/{name}", include_in_schema=False)
        def admin_asset(name: str, request: Request):
            require_admin_https(request)
            media = {"app.css": "text/css", "app.js": "text/javascript"}.get(name)
            if media is None:
                raise HTTPException(status_code=404)
            return FileResponse(admin_static / name, media_type=media)

    return app
