from contextlib import contextmanager
import hashlib
import os
import secrets
import sqlite3
import threading
import time

from argon2 import PasswordHasher, Type
from argon2.exceptions import InvalidHashError, VerificationError

from . import activity
from .config import Settings


PAIR_LIFETIME_SECONDS = 24 * 60 * 60
PAIR_ACTIVATION_GRACE_SECONDS = 90


class AccountError(Exception):
    def __init__(self, status: int, code: str, message: str, retry_after: int | None = None):
        super().__init__(message)
        self.status = status
        self.code = code
        self.message = message
        self.retry_after = retry_after


def username_key(value: str) -> str:
    value = value.strip()
    if not 3 <= len(value) <= 64 or not all(c.isalnum() or c in "._@-" for c in value):
        raise ValueError("Username must be 3-64 letters, numbers, or . _ @ -")
    return value.casefold()


def token_digest(token: str) -> str:
    return hashlib.sha256(token.encode("utf-8")).hexdigest()


def bearer_token(authorization: str | None) -> str:
    if not authorization:
        raise AccountError(401, "invalid_session", "Session is invalid or expired. Sign in again.")
    parts = authorization.split(" ")
    if (len(parts) != 2 or parts[0].lower() != "bearer"
            or not 32 <= len(parts[1]) <= 128
            or not all(c.isascii() and (c.isalnum() or c in "-_") for c in parts[1])):
        raise AccountError(401, "invalid_session", "Session is invalid or expired. Sign in again.")
    return parts[1]


def user_payload(row: sqlite3.Row) -> dict:
    return {
        "name": row["username"],
        "display_name": row["display_name"],
        "avatar": "",
        "status": 1,
        "is_admin": bool(row["is_admin"]),
        "role": row["role"],
    }


class AccountService:
    def __init__(self, settings: Settings):
        self.settings = settings
        self.hasher = PasswordHasher(
            time_cost=3, memory_cost=65536, parallelism=1,
            hash_len=32, salt_len=16, type=Type.ID,
        )
        self.hash_slots = threading.BoundedSemaphore(settings.hash_concurrency)
        self._dummy_hash = self.hasher.hash(secrets.token_urlsafe(32))
        settings.db_path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        with self.connection() as db:
            db.executescript("""
                CREATE TABLE IF NOT EXISTS pairs (
                    pk INTEGER PRIMARY KEY,
                    pair_id TEXT NOT NULL UNIQUE,
                    enabled INTEGER NOT NULL DEFAULT 1 CHECK(enabled IN (0,1)),
                    created_at INTEGER NOT NULL
                );
                CREATE TABLE IF NOT EXISTS pair_lifetimes (
                    pair_pk INTEGER PRIMARY KEY REFERENCES pairs(pk) ON DELETE CASCADE,
                    activated_at INTEGER,
                    expires_at INTEGER,
                    CHECK((activated_at IS NULL AND expires_at IS NULL)
                          OR (activated_at IS NOT NULL AND expires_at IS NOT NULL AND expires_at > activated_at))
                );
                CREATE TABLE IF NOT EXISTS users (
                    pk INTEGER PRIMARY KEY,
                    username_key TEXT NOT NULL UNIQUE,
                    username TEXT NOT NULL,
                    display_name TEXT NOT NULL,
                    password_hash TEXT NOT NULL,
                    enabled INTEGER NOT NULL DEFAULT 1 CHECK(enabled IN (0,1)),
                    is_admin INTEGER NOT NULL DEFAULT 0 CHECK(is_admin IN (0,1)),
                    role TEXT NOT NULL DEFAULT 'receiver' CHECK(role IN ('controller','receiver')),
                    pair_pk INTEGER REFERENCES pairs(pk) ON DELETE SET NULL,
                    created_at INTEGER NOT NULL
                );
                CREATE TABLE IF NOT EXISTS pair_credentials (
                    user_pk INTEGER PRIMARY KEY REFERENCES users(pk) ON DELETE CASCADE,
                    password TEXT NOT NULL
                );
                CREATE TABLE IF NOT EXISTS devices (
                    pk INTEGER PRIMARY KEY,
                    client_id TEXT NOT NULL UNIQUE,
                    device_uuid TEXT NOT NULL UNIQUE,
                    user_pk INTEGER NOT NULL REFERENCES users(pk) ON DELETE CASCADE,
                    created_at INTEGER NOT NULL
                );
                CREATE TABLE IF NOT EXISTS sessions (
                    token_hash TEXT PRIMARY KEY,
                    device_pk INTEGER NOT NULL REFERENCES devices(pk) ON DELETE CASCADE,
                    created_at INTEGER NOT NULL,
                    expires_at INTEGER NOT NULL
                );
                CREATE INDEX IF NOT EXISTS sessions_device ON sessions(device_pk);
                CREATE INDEX IF NOT EXISTS sessions_expiry ON sessions(expires_at);
                CREATE TABLE IF NOT EXISTS connection_tickets (
                    ticket_hash TEXT PRIMARY KEY,
                    source_session TEXT NOT NULL REFERENCES sessions(token_hash) ON DELETE CASCADE,
                    target_device INTEGER NOT NULL REFERENCES devices(pk) ON DELETE CASCADE,
                    conn_type TEXT NOT NULL,
                    expires_at INTEGER NOT NULL,
                    consumed_at INTEGER,
                    target_session TEXT REFERENCES sessions(token_hash) ON DELETE CASCADE
                );
                CREATE INDEX IF NOT EXISTS tickets_source ON connection_tickets(source_session);
                CREATE INDEX IF NOT EXISTS tickets_target ON connection_tickets(target_device);
                CREATE TABLE IF NOT EXISTS login_limits (
                    key TEXT PRIMARY KEY,
                    attempts INTEGER NOT NULL,
                    resets_at INTEGER NOT NULL
                );
            """)
            db.execute("BEGIN IMMEDIATE")
            user_columns = {row["name"] for row in db.execute("PRAGMA table_info(users)")}
            if "role" not in user_columns:
                db.execute(
                    "ALTER TABLE users ADD COLUMN role TEXT NOT NULL DEFAULT 'receiver' "
                    "CHECK(role IN ('controller','receiver'))"
                )
                db.execute("UPDATE users SET role = 'controller'")
            if "pair_pk" not in user_columns:
                db.execute("ALTER TABLE users ADD COLUMN pair_pk INTEGER REFERENCES pairs(pk) ON DELETE SET NULL")
            db.execute("CREATE UNIQUE INDEX IF NOT EXISTS users_pair_role ON users(pair_pk, role)")
            columns = {row["name"] for row in db.execute("PRAGMA table_info(connection_tickets)")}
            if "target_session" not in columns:
                db.execute(
                    "ALTER TABLE connection_tickets ADD COLUMN target_session TEXT "
                    "REFERENCES sessions(token_hash) ON DELETE CASCADE"
                )
            db.execute("CREATE INDEX IF NOT EXISTS tickets_target_session ON connection_tickets(target_session)")
            activity.initialize_activity(db)
        if os.name == "posix":
            settings.db_path.chmod(0o600)

    @contextmanager
    def connection(self):
        db = sqlite3.connect(self.settings.db_path, timeout=5)
        db.row_factory = sqlite3.Row
        db.execute("PRAGMA foreign_keys = ON")
        try:
            with db:
                yield db
        finally:
            db.close()

    @contextmanager
    def hashing(self):
        if not self.hash_slots.acquire(blocking=False):
            raise AccountError(503, "busy", "Login service is busy. Try again shortly.", 1)
        try:
            yield
        finally:
            self.hash_slots.release()

    def _check_login_rate(self, address: str, key: str, now: int):
        limits = (
            ("ip:" + token_digest(address), self.settings.login_ip_limit),
            ("account:" + token_digest(key), self.settings.login_account_limit),
        )
        retry_after = 0
        with self.connection() as db:
            db.execute("BEGIN IMMEDIATE")
            db.execute("DELETE FROM login_limits WHERE resets_at <= ?", (now,))
            for limit_key, maximum in limits:
                row = db.execute(
                    "SELECT attempts, resets_at FROM login_limits WHERE key = ?", (limit_key,)
                ).fetchone()
                if row and row["attempts"] >= maximum:
                    retry_after = max(retry_after, row["resets_at"] - now)
            if not retry_after:
                for limit_key, _ in limits:
                    db.execute(
                        """INSERT INTO login_limits(key, attempts, resets_at) VALUES (?, 1, ?)
                           ON CONFLICT(key) DO UPDATE SET attempts = attempts + 1""",
                        (limit_key, now + self.settings.login_window),
                    )
        if retry_after:
            raise AccountError(429, "rate_limited", "Too many login attempts. Try again later.", retry_after)

    def login(self, username: str, password: str, client_id: str, device_uuid: str,
              auto_login: bool, address: str, client_role: str | None = None,
              prior_authorization: str | None = None) -> dict:
        key = username_key(username)
        now = int(time.time())
        self._check_login_rate(address, key, now)
        with self.connection() as db:
            user = db.execute("SELECT * FROM users WHERE username_key = ?", (key,)).fetchone()
        stored_hash = user["password_hash"] if user else self._dummy_hash
        with self.hashing():
            try:
                verified = self.hasher.verify(stored_hash, password)
            except (VerificationError, InvalidHashError):
                verified = False
        if not verified or user is None or not user["enabled"]:
            raise AccountError(401, "invalid_credentials", "Invalid username or password.")

        token = secrets.token_urlsafe(32)
        ttl = self.settings.remember_ttl if auto_login else self.settings.session_ttl
        with self.connection() as db:
            db.execute("BEGIN IMMEDIATE")
            now = int(time.time())
            expires_at = now + ttl
            current = db.execute("SELECT * FROM users WHERE pk = ?", (user["pk"],)).fetchone()
            # A password reset or disable during Argon2 verification must not issue a new session.
            if not current or not current["enabled"] or current["password_hash"] != stored_hash:
                raise AccountError(401, "invalid_credentials", "Invalid username or password.")
            if client_role is not None and client_role != current["role"]:
                raise AccountError(403, "role_mismatch", "Use the matching TomDesk client for this account.")
            pair = db.execute(
                """SELECT p.enabled, l.expires_at FROM pairs p
                   LEFT JOIN pair_lifetimes l ON l.pair_pk = p.pk WHERE p.pk = ?""",
                (current["pair_pk"],),
            ).fetchone()
            if current["pair_pk"] is not None and (not pair or not pair["enabled"]):
                raise AccountError(403, "pair_disabled", "This account pair is disabled.")
            if pair:
                self._require_pair_current(pair["expires_at"], now)
            if client_role is not None and not pair:
                raise AccountError(403, "pair_required", "A paired account is required for this client.")
            if self.settings.admin_origin:
                activity.sweep_presence(db, now)
            if current["pair_pk"] is not None:
                if self.settings.admin_origin:
                    activity.record_replacement(db, current["pk"], client_id, device_uuid, now)
                self._transfer_paired_device(db, current["pk"], client_id, device_uuid, now)
            bindings = db.execute(
                "SELECT * FROM devices WHERE client_id = ? OR device_uuid = ?",
                (client_id, device_uuid),
            ).fetchall()
            device = bindings[0] if bindings else None
            if device:
                if len(bindings) != 1 or device["client_id"] != client_id or device["device_uuid"] != device_uuid:
                    raise AccountError(409, "device_bound", "This device identity is already bound. Contact the administrator.")
                if device["user_pk"] != current["pk"]:
                    if current["pair_pk"] is None or not self._release_prior_paired_device(
                            db, device, prior_authorization, now):
                        raise AccountError(409, "device_bound", "This device identity is already bound. Contact the administrator.")
                    device = None
            if device:
                device_pk = device["pk"]
            else:
                device_pk = db.execute(
                    "INSERT INTO devices(client_id, device_uuid, user_pk, created_at) VALUES (?, ?, ?, ?)",
                    (client_id, device_uuid, user["pk"], now),
                ).lastrowid
            if current["pair_pk"] is not None:
                self._revoke_user_sessions(db, current["pk"])
            db.execute("DELETE FROM sessions WHERE expires_at <= ?", (now,))
            db.execute(
                "INSERT INTO sessions(token_hash, device_pk, created_at, expires_at) VALUES (?, ?, ?, ?)",
                (token_digest(token), device_pk, now, expires_at),
            )
            if self.settings.admin_origin and current["pair_pk"] is not None:
                activity.record_login(db, current["pk"], device_pk, client_id, now)
        return {"type": "access_token", "access_token": token, "user": user_payload(current),
                "expires_at": expires_at}

    @staticmethod
    def _transfer_paired_device(db, user_pk: int, client_id: str, device_uuid: str, now: int):
        # Both client-supplied identifiers must match before reusing an inactive device.
        db.execute(
            """DELETE FROM devices WHERE client_id = ? AND device_uuid = ? AND user_pk <> ?
                   AND user_pk IN (SELECT pk FROM users WHERE pair_pk IS NOT NULL)
                   AND NOT EXISTS (
                       SELECT 1 FROM sessions s JOIN users bound ON bound.pk = devices.user_pk
                       LEFT JOIN pair_lifetimes l ON l.pair_pk = bound.pair_pk
                       WHERE s.device_pk = devices.pk AND s.expires_at > ?
                             AND (l.expires_at IS NULL OR l.expires_at > ?)
                   )""",
            (client_id, device_uuid, user_pk, now, now),
        )
        # Moving this account invalidates its old sessions and tickets via foreign keys.
        db.execute(
            "DELETE FROM devices WHERE user_pk = ? AND (client_id <> ? OR device_uuid <> ?)",
            (user_pk, client_id, device_uuid),
        )

    def _release_prior_paired_device(self, db, device, authorization: str | None, now: int) -> bool:
        try:
            prior = self._session(db, bearer_token(authorization), device["client_id"], device["device_uuid"], now)
        except AccountError:
            return False
        if prior["pair_pk"] is None or prior["device_pk"] != device["pk"]:
            return False
        if self.settings.admin_origin:
            activity.record_logout(db, prior["user_pk"], device["pk"], device["client_id"], now)
        db.execute("DELETE FROM devices WHERE pk = ?", (device["pk"],))
        return True

    def _session(self, db, token: str, client_id: str, device_uuid: str, now: int):
        row = db.execute(
            """SELECT s.token_hash, s.expires_at, s.device_pk, d.client_id, d.device_uuid,
                      u.pk AS user_pk, u.username, u.display_name, u.is_admin, u.role, u.pair_pk,
                      l.expires_at AS pair_expires_at
               FROM sessions s JOIN devices d ON d.pk = s.device_pk
               JOIN users u ON u.pk = d.user_pk LEFT JOIN pairs p ON p.pk = u.pair_pk
               LEFT JOIN pair_lifetimes l ON l.pair_pk = p.pk
               WHERE s.token_hash = ? AND s.expires_at > ? AND u.enabled = 1
                     AND d.client_id = ? AND d.device_uuid = ?
                     AND (u.pair_pk IS NULL OR p.enabled = 1)""",
            (token_digest(token), now, client_id, device_uuid),
        ).fetchone()
        if not row:
            raise AccountError(401, "invalid_session", "Session is invalid or expired. Sign in again.")
        self._require_pair_current(row["pair_expires_at"], now)
        return row

    def authorize(self, token: str, client_id: str, device_uuid: str) -> dict:
        with self.connection() as db:
            now = int(time.time())
            row = self._session(db, token, client_id, device_uuid, now)
            if self.settings.admin_origin and row["pair_pk"] is not None and activity.contact_due(db, row, now):
                db.execute("BEGIN IMMEDIATE")
                # Revalidate under the write lock; do not restore presence for a kicked session.
                now = int(time.time())
                row = self._session(db, token, client_id, device_uuid, now)
                activity.touch_contact(db, row, now)
        return {"user": user_payload(row), "expires_at": row["expires_at"],
                "permissions": {"remote": row["role"] == "controller" and row["pair_pk"] is not None,
                                "subtitles": True}}

    def sweep_activity(self):
        if self.settings.admin_origin:
            with self.connection() as db:
                db.execute("BEGIN IMMEDIATE")
                activity.sweep_presence(db, int(time.time()))

    def logout(self, token: str, client_id: str, device_uuid: str):
        with self.connection() as db:
            db.execute("BEGIN IMMEDIATE")
            now = int(time.time())
            row = self._session(db, token, client_id, device_uuid, now)
            if row["pair_pk"] is not None:
                if self.settings.admin_origin:
                    activity.record_logout(db, row["user_pk"], row["device_pk"], client_id, now)
                db.execute("DELETE FROM devices WHERE pk = ?", (row["device_pk"],))
            else:
                db.execute("DELETE FROM sessions WHERE token_hash = ?", (row["token_hash"],))

    @staticmethod
    def _require_pair_current(expires_at: int | None, now: int):
        if expires_at is not None and expires_at <= now:
            raise AccountError(403, "pair_expired", "This account pair has expired. Contact the administrator.")

    @staticmethod
    def _require_activation_grace(pair, consumed_at: int, now: int):
        if pair["timed_pair"] is None:
            return
        # Activation by another connection must not revive an older, already stale grant.
        cutoff = now if pair["activated_at"] is None else pair["activated_at"]
        if consumed_at + PAIR_ACTIVATION_GRACE_SECONDS <= cutoff:
            raise AccountError(403, "pair_activation_timeout", "Pair activation timed out. Connect again.")

    def _require_pair(self, db, source_user: int, target_user: int, conn_type: str, now: int):
        pair = db.execute(
            """SELECT p.pk, p.pair_id, l.pair_pk AS timed_pair, l.activated_at, l.expires_at
               FROM pairs p LEFT JOIN pair_lifetimes l ON l.pair_pk = p.pk
               JOIN users a ON a.pair_pk = p.pk JOIN users b ON b.pair_pk = p.pk
               WHERE p.enabled = 1 AND a.pk = ? AND b.pk = ?
                     AND a.enabled = 1 AND b.enabled = 1
                     AND a.role = 'controller' AND b.role = 'receiver'""",
            (source_user, target_user),
        ).fetchone()
        if conn_type != "remote" or not pair:
            raise AccountError(403, "pair_forbidden", "Only the paired receiver can be controlled.")
        self._require_pair_current(pair["expires_at"], now)
        return pair

    @staticmethod
    def _latest_receiver_session(db, pair_pk: int, now: int):
        return db.execute(
            """SELECT d.pk AS device_pk, d.client_id, s.token_hash, s.expires_at,
                      v.user_pk IS NOT NULL AS online
               FROM users u JOIN devices d ON d.user_pk = u.pk
               JOIN sessions s ON s.device_pk = d.pk
               LEFT JOIN pair_presence v ON v.user_pk = u.pk AND v.device_pk = d.pk
                   AND v.device_id = d.client_id AND v.state = 'online' AND v.last_seen > ?
               WHERE u.pair_pk = ? AND u.role = 'receiver' AND u.enabled = 1 AND s.expires_at > ?
               ORDER BY s.created_at DESC, s.rowid DESC LIMIT 1""",
            (now - activity.OFFLINE_AFTER, pair_pk, now),
        ).fetchone()

    def paired_device(self, token: str, client_id: str, device_uuid: str) -> dict:
        with self.connection() as db:
            db.execute("BEGIN")
            now = int(time.time())
            source = self._session(db, token, client_id, device_uuid, now)
            if source["role"] != "controller" or source["pair_pk"] is None:
                raise AccountError(403, "pair_forbidden", "A paired controller account is required.")
            target = self._latest_receiver_session(db, source["pair_pk"], now)
        return {
            "target_id": target["client_id"] if target else None,
            "online": bool(target and target["online"]) if self.settings.admin_origin else None,
        }

    def connection_ticket(self, token: str, client_id: str, device_uuid: str,
                          target_id: str, conn_type: str, supports_pair_activation: bool = False) -> dict:
        ticket = secrets.token_urlsafe(32)
        with self.connection() as db:
            db.execute("BEGIN IMMEDIATE")
            now = int(time.time())
            source = self._session(db, token, client_id, device_uuid, now)
            if source["role"] != "controller" or conn_type != "remote":
                raise AccountError(403, "connection_forbidden", "Only controller-to-receiver remote connections are allowed.")
            target = db.execute(
                """SELECT d.pk, u.pk AS user_pk, u.role FROM devices d JOIN users u ON u.pk = d.user_pk
                   WHERE d.client_id = ? AND u.enabled = 1""", (target_id,)
            ).fetchone()
            if not target:
                raise AccountError(404, "device_unavailable", "The target device is not bound to an active account.")
            if target["role"] != "receiver":
                raise AccountError(403, "connection_forbidden", "Only controller-to-receiver remote connections are allowed.")
            pair = self._require_pair(db, source["user_pk"], target["user_pk"], conn_type, now)
            receiver = self._latest_receiver_session(db, pair["pk"], now)
            if not receiver or receiver["device_pk"] != target["pk"]:
                raise AccountError(404, "device_unavailable", "The target device does not have the current receiver session.")
            activation_required = pair["timed_pair"] is not None and pair["activated_at"] is None
            if activation_required and not supports_pair_activation:
                raise AccountError(403, "pair_activation_unsupported",
                                   "Update TomDesk Controller to activate this account pair.")
            db.execute(
                "DELETE FROM connection_tickets WHERE expires_at <= ? AND consumed_at IS NULL", (now,)
            )
            count = db.execute(
                "SELECT COUNT(*) FROM connection_tickets WHERE source_session = ? AND consumed_at IS NULL",
                (source["token_hash"],),
            ).fetchone()[0]
            if count >= 64:
                raise AccountError(
                    429, "ticket_limit", "Too many pending connection requests.", self.settings.ticket_ttl
                )
            expires_at = min(now + self.settings.ticket_ttl, source["expires_at"], receiver["expires_at"])
            if pair["expires_at"] is not None:
                expires_at = min(expires_at, pair["expires_at"])
            db.execute(
                """INSERT INTO connection_tickets
                   (ticket_hash, source_session, target_device, conn_type, expires_at, target_session)
                   VALUES (?, ?, ?, ?, ?, ?)""",
                (token_digest(ticket), source["token_hash"], target["pk"], conn_type, expires_at, receiver["token_hash"]),
            )
        result = {"ticket": ticket, "expires_at": expires_at}
        if activation_required:
            result["activation_required"] = True
        return result

    def consume_ticket(self, token: str, client_id: str, device_uuid: str,
                       ticket: str, source_id: str, conn_type: str) -> dict:
        with self.connection() as db:
            db.execute("BEGIN IMMEDIATE")
            now = int(time.time())
            target = self._session(db, token, client_id, device_uuid, now)
            source = db.execute(
                """SELECT t.target_device, t.target_session, t.conn_type, t.expires_at, t.consumed_at,
                          s.expires_at AS session_expires_at, d.client_id, u.pk AS user_pk, u.username, u.enabled, u.role
                   FROM connection_tickets t JOIN sessions s ON s.token_hash = t.source_session
                   JOIN devices d ON d.pk = s.device_pk JOIN users u ON u.pk = d.user_pk
                   WHERE t.ticket_hash = ?""", (token_digest(ticket),)
            ).fetchone()
            if (not source or source["consumed_at"] is not None or source["expires_at"] <= now
                    or source["session_expires_at"] <= now or not source["enabled"]
                    or source["role"] != "controller" or target["role"] != "receiver" or conn_type != "remote"
                    or source["target_device"] != target["device_pk"]
                    or (source["target_session"] is not None and source["target_session"] != target["token_hash"])
                    or source["client_id"] != source_id or source["conn_type"] != conn_type):
                raise AccountError(403, "invalid_ticket", "Connection authorization is invalid or expired.")
            pair = self._require_pair(db, source["user_pk"], target["user_pk"], conn_type, now)
            if source["target_session"] is None:
                # Tickets minted by the previous server have no receiver session until consumed.
                receiver = self._latest_receiver_session(db, pair["pk"], now)
                if not receiver or receiver["token_hash"] != target["token_hash"]:
                    raise AccountError(403, "invalid_ticket", "Connection authorization is invalid or expired.")
            db.execute(
                "UPDATE connection_tickets SET consumed_at = ?, target_session = ? WHERE ticket_hash = ?",
                (now, target["token_hash"], token_digest(ticket)),
            )
        return {"authorized": True,
                "source": {"id": source["client_id"], "user_name": source["username"], "role": source["role"]},
                "target": {"id": target["client_id"], "user_name": target["username"], "role": target["role"]}}

    def connection_status(self, token: str, client_id: str, device_uuid: str,
                          ticket: str, source_id: str, conn_type: str) -> dict:
        with self.connection() as db:
            db.execute("BEGIN IMMEDIATE" if self.settings.admin_origin else "BEGIN")
            now = int(time.time())
            target = self._session(db, token, client_id, device_uuid, now)
            source = db.execute(
                """SELECT d.client_id, u.pk AS user_pk, u.username, u.role, t.consumed_at
                   FROM connection_tickets t JOIN sessions s ON s.token_hash = t.source_session
                   JOIN devices d ON d.pk = s.device_pk JOIN users u ON u.pk = d.user_pk
                   WHERE t.ticket_hash = ? AND t.consumed_at IS NOT NULL
                         AND t.target_session = ? AND t.target_device = ?
                         AND s.expires_at > ? AND u.enabled = 1 AND u.role = 'controller'
                         AND t.conn_type = 'remote' AND d.client_id = ? AND t.conn_type = ?""",
                (token_digest(ticket), target["token_hash"], target["device_pk"], now, source_id, conn_type),
            ).fetchone()
            if not source or target["role"] != "receiver":
                raise AccountError(403, "invalid_ticket", "Connection authorization is invalid or expired.")
            pair = self._require_pair(db, source["user_pk"], target["user_pk"], conn_type, now)
            self._require_activation_grace(pair, source["consumed_at"], now)
            if self.settings.admin_origin:
                activity.touch_contact(db, target, now)
        return {"authorized": True,
                "source": {"id": source["client_id"], "user_name": source["username"], "role": source["role"]},
                "target": {"id": target["client_id"], "user_name": target["username"], "role": target["role"]}}

    def activate_pair(self, token: str, client_id: str, device_uuid: str,
                      ticket: str, target_id: str) -> dict:
        with self.connection() as db:
            db.execute("BEGIN IMMEDIATE")
            now = int(time.time())
            source = self._session(db, token, client_id, device_uuid, now)
            if source["role"] != "controller" or source["pair_pk"] is None:
                raise AccountError(403, "pair_forbidden", "A paired controller account is required.")
            grant = db.execute(
                """SELECT d.user_pk, t.consumed_at FROM connection_tickets t
                   JOIN sessions s ON s.token_hash = t.target_session AND s.device_pk = t.target_device
                   JOIN devices d ON d.pk = s.device_pk
                   WHERE t.ticket_hash = ? AND t.source_session = ? AND t.consumed_at IS NOT NULL
                         AND t.conn_type = 'remote' AND d.client_id = ? AND s.expires_at > ?""",
                (token_digest(ticket), source["token_hash"], target_id, now),
            ).fetchone()
            if not grant:
                raise AccountError(403, "invalid_ticket", "Connection authorization is invalid or expired.")
            pair = self._require_pair(db, source["user_pk"], grant["user_pk"], "remote", now)
            if pair["timed_pair"] is None:
                raise AccountError(409, "pair_activation_unavailable", "This account pair has no time limit.")
            self._require_activation_grace(pair, grant["consumed_at"], now)
            expires_at = pair["expires_at"]
            if expires_at is None:
                expires_at = now + PAIR_LIFETIME_SECONDS
                db.execute(
                    "UPDATE pair_lifetimes SET activated_at = ?, expires_at = ? WHERE pair_pk = ?",
                    (now, expires_at, pair["pk"]),
                )
                activity.record_event(db, event="activate_pair", at=now, pair_id=pair["pair_id"],
                                      side="a", username=source["username"], device_id=client_id)
        return {"activated": True, "expires_at": expires_at}

    def _password_hash(self, password: str) -> str:
        if not 12 <= len(password) <= 1024:
            raise ValueError("Password must contain 12-1024 characters")
        with self.hashing():
            return self.hasher.hash(password)

    def _paired_password_hash(self, password: str) -> str:
        if len(password) != 8 or not password.isascii() or not password.isalnum():
            raise ValueError("Generated pair password must be 8 ASCII letters or digits")
        with self.hashing():
            return self.hasher.hash(password)

    def create_user(self, username: str, password: str, display_name: str = "",
                    is_admin: bool = False, role: str = "receiver"):
        if role not in ("controller", "receiver"):
            raise ValueError("Role must be controller or receiver")
        key = username_key(username)
        display_name = display_name.strip() or username.strip()
        if len(display_name) > 128 or not display_name.isprintable():
            raise ValueError("Display name must be printable and at most 128 characters")
        password_hash = self._password_hash(password)
        try:
            with self.connection() as db:
                db.execute(
                    """INSERT INTO users(username_key, username, display_name, password_hash,
                                         is_admin, role, created_at) VALUES (?, ?, ?, ?, ?, ?, ?)""",
                    (key, username.strip(), display_name, password_hash, int(is_admin), role, int(time.time())),
                )
        except sqlite3.IntegrityError:
            raise AccountError(409, "account_exists", "Account already exists.") from None

    def _revoke_user_sessions(self, db, user_pk: int):
        db.execute(
            "DELETE FROM connection_tickets WHERE target_device IN (SELECT pk FROM devices WHERE user_pk = ?)",
            (user_pk,),
        )
        db.execute("DELETE FROM sessions WHERE device_pk IN (SELECT pk FROM devices WHERE user_pk = ?)", (user_pk,))

    def disable_user(self, username: str):
        with self.connection() as db:
            db.execute("BEGIN IMMEDIATE")
            user = db.execute("SELECT pk FROM users WHERE username_key = ?", (username_key(username),)).fetchone()
            if not user:
                raise AccountError(404, "account_missing", "Account not found.")
            db.execute("UPDATE users SET enabled = 0 WHERE pk = ?", (user["pk"],))
            self._revoke_user_sessions(db, user["pk"])

    def set_password(self, username: str, password: str):
        password_hash = self._password_hash(password)
        with self.connection() as db:
            db.execute("BEGIN IMMEDIATE")
            user = db.execute("SELECT pk FROM users WHERE username_key = ?", (username_key(username),)).fetchone()
            if not user:
                raise AccountError(404, "account_missing", "Account not found.")
            db.execute("UPDATE users SET password_hash = ? WHERE pk = ?", (password_hash, user["pk"]))
            # A manually chosen password is not a generated credential. Remove
            # the old displayed password so the admin page never shows a stale one.
            db.execute("DELETE FROM pair_credentials WHERE user_pk = ?", (user["pk"],))
            self._revoke_user_sessions(db, user["pk"])

    def set_role(self, username: str, role: str):
        if role not in ("controller", "receiver"):
            raise ValueError("Role must be controller or receiver")
        with self.connection() as db:
            db.execute("BEGIN IMMEDIATE")
            user = db.execute(
                "SELECT pk, role, pair_pk FROM users WHERE username_key = ?", (username_key(username),)
            ).fetchone()
            if not user:
                raise AccountError(404, "account_missing", "Account not found.")
            if user["role"] != role:
                if user["pair_pk"] is not None:
                    raise AccountError(409, "paired_role_locked", "Paired account roles cannot be changed.")
                db.execute("UPDATE users SET role = ? WHERE pk = ?", (role, user["pk"]))
                self._revoke_user_sessions(db, user["pk"])

    def list_pairs(self) -> list[dict]:
        with self.connection() as db:
            rows = db.execute(
                """SELECT p.pair_id, p.enabled, a.username AS controller_username,
                          b.username AS receiver_username, p.created_at
                   FROM pairs p JOIN users a ON a.pair_pk = p.pk AND a.role = 'controller'
                   JOIN users b ON b.pair_pk = p.pk AND b.role = 'receiver'
                   ORDER BY p.pk"""
            ).fetchall()
        return [dict(row) for row in rows]

    def revoke_pair(self, pair_id: str, disable: bool = False):
        with self.connection() as db:
            db.execute("BEGIN IMMEDIATE")
            pair = db.execute("SELECT pk FROM pairs WHERE pair_id = ?", (pair_id,)).fetchone()
            if not pair:
                raise AccountError(404, "pair_missing", "Account pair not found.")
            if disable:
                db.execute("UPDATE pairs SET enabled = 0 WHERE pk = ?", (pair["pk"],))
            for user in db.execute("SELECT pk FROM users WHERE pair_pk = ?", (pair["pk"],)).fetchall():
                self._revoke_user_sessions(db, user["pk"])

    def list_users(self) -> list[dict]:
        with self.connection() as db:
            rows = db.execute(
                "SELECT username, display_name, enabled, is_admin, role, created_at FROM users ORDER BY username_key"
            ).fetchall()
        return [dict(row) for row in rows]

    def list_devices(self) -> list[dict]:
        with self.connection() as db:
            rows = db.execute(
                """SELECT d.client_id AS id, d.device_uuid AS uuid, u.username,
                          u.enabled, d.created_at FROM devices d JOIN users u ON u.pk = d.user_pk
                   ORDER BY u.username_key, d.client_id"""
            ).fetchall()
        return [dict(row) for row in rows]

    def unbind_device(self, client_id: str):
        with self.connection() as db:
            db.execute("BEGIN IMMEDIATE")
            result = db.execute("DELETE FROM devices WHERE client_id = ?", (client_id,))
            if result.rowcount != 1:
                raise AccountError(404, "device_missing", "Bound device not found.")
