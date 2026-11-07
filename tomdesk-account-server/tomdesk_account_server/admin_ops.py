import time

from .activity import OFFLINE_AFTER, end_presence, record_event
from .provision import generate_paired_password, insert_prepared_pairs, prepare_pairs
from .service import AccountError, AccountService


ROLE_BY_SIDE = {"a": "controller", "b": "receiver"}
SIDE_BY_ROLE = {value: key for key, value in ROLE_BY_SIDE.items()}


def list_pairs(service: AccountService, limit: int, offset: int, q: str) -> dict:
    needle = q.strip().casefold().replace("!", "!!").replace("%", "!%").replace("_", "!_")
    params = {"pattern": "%" + needle + "%" if needle else None, "limit": limit, "offset": offset}
    match = """
        WHERE :pattern IS NULL OR p.pair_id LIKE :pattern ESCAPE '!'
        OR EXISTS (
            SELECT 1 FROM users u LEFT JOIN devices d ON d.user_pk = u.pk
            WHERE u.pair_pk = p.pk AND (
                u.username_key LIKE :pattern ESCAPE '!' OR d.client_id LIKE :pattern ESCAPE '!'
            )
        )
    """
    now = int(time.time())
    with service.connection() as db:
        db.execute("BEGIN")
        total = db.execute("SELECT COUNT(*) FROM pairs p " + match, params).fetchone()[0]
        pairs = db.execute(
            """SELECT p.pk, p.pair_id, p.enabled, p.created_at, l.activated_at, l.expires_at,
                      l.pair_pk AS timed_pair
               FROM pairs p LEFT JOIN pair_lifetimes l ON l.pair_pk = p.pk """
            + match + " ORDER BY p.pk DESC LIMIT :limit OFFSET :offset", params,
        ).fetchall()
        result = {
            row["pk"]: {
                "pair_id": row["pair_id"], "enabled": bool(row["enabled"]),
                "created_at": row["created_at"], "a": None, "b": None,
                "activated_at": row["activated_at"], "expires_at": row["expires_at"],
                "expiry_state": (
                    "unlimited" if row["timed_pair"] is None else
                    "pending" if row["expires_at"] is None else
                    "expired" if row["expires_at"] <= now else "active"
                ),
            }
            for row in pairs
        }
        if result:
            slots = ",".join("?" for _ in result)
            rows = db.execute(
                """
                SELECT u.pair_pk, u.username, u.role, u.enabled,
                       d.client_id AS device_id, v.last_seen, c.password,
                       CASE WHEN u.enabled = 1 AND p.enabled = 1
                                  AND v.state = 'online' AND v.last_seen > ?
                                  AND d.pk = v.device_pk AND d.client_id = v.device_id
                                  AND EXISTS (SELECT 1 FROM sessions s
                                              WHERE s.device_pk = d.pk AND s.expires_at > ?)
                            THEN 1 ELSE 0 END AS online
                FROM users u JOIN pairs p ON p.pk = u.pair_pk
                LEFT JOIN devices d ON d.pk = (
                    SELECT MAX(bound.pk) FROM devices bound WHERE bound.user_pk = u.pk
                )
                LEFT JOIN pair_presence v ON v.user_pk = u.pk
                LEFT JOIN pair_credentials c ON c.user_pk = u.pk
                WHERE u.pair_pk IN (""" + slots + ")",
                (now - OFFLINE_AFTER, now, *result),
            ).fetchall()
            for row in rows:
                result[row["pair_pk"]][SIDE_BY_ROLE[row["role"]]] = {
                    "username": row["username"], "password": row["password"],
                    "enabled": bool(row["enabled"]),
                    "device_id": row["device_id"], "last_seen": row["last_seen"],
                    "online": bool(row["online"]) and result[row["pair_pk"]]["expiry_state"] != "expired",
                }
    return {"items": list(result.values()), "total": total}


def list_events(service: AccountService, pair_id: str | None, limit: int, offset: int) -> dict:
    # Use the pair index when a filter is requested.
    where = " WHERE pair_id = ?" if pair_id is not None else ""
    params = () if pair_id is None else (pair_id,)
    with service.connection() as db:
        db.execute("BEGIN")
        total = db.execute("SELECT COUNT(*) FROM pair_events" + where, params).fetchone()[0]
        rows = db.execute(
            "SELECT event, at, pair_id, side, username, device_id, actor, detail FROM pair_events"
            + where + " ORDER BY pk DESC LIMIT ? OFFSET ?",
            (*params, limit, offset),
        ).fetchall()
    return {"items": [dict(row) for row in rows], "total": total}


def create_web_pairs(service: AccountService, count: int, actor_in_transaction) -> dict:
    prepared = prepare_pairs(service, count)
    with service.connection() as db:
        db.execute("BEGIN IMMEDIATE")
        now = int(time.time())
        actor = actor_in_transaction(db, now)
        insert_prepared_pairs(db, prepared, now)
        for row, _ in prepared:
            record_event(db, event="create_pair", at=now, pair_id=row["pair_id"],
                         side="both", actor=actor)
    return {"credentials": [row for row, _ in prepared]}


def act_on_pair(service: AccountService, pair_id: str, action: str, side: str,
                actor_in_transaction) -> dict:
    if action == "renew" and side != "both":
        raise AccountError(422, "invalid_side", "Select both accounts to renew a pair.")
    new_password = None
    password_hash = None
    if action == "reset_password":
        if side == "both":
            raise AccountError(422, "invalid_side", "Select one account to reset its password.")
        new_password = generate_paired_password()
        password_hash = service._paired_password_hash(new_password)

    credentials = []
    with service.connection() as db:
        db.execute("BEGIN IMMEDIATE")
        now = int(time.time())
        actor = actor_in_transaction(db, now)
        pair = db.execute(
            """SELECT p.pk, l.expires_at FROM pairs p
               LEFT JOIN pair_lifetimes l ON l.pair_pk = p.pk WHERE p.pair_id = ?""",
            (pair_id,),
        ).fetchone()
        if not pair:
            raise AccountError(404, "pair_missing", "Account pair not found.")
        if action == "renew":
            if pair["expires_at"] is None or pair["expires_at"] > now:
                raise AccountError(409, "pair_not_expired", "Only an expired account pair can be renewed.")
            db.execute(
                "UPDATE pair_lifetimes SET activated_at = NULL, expires_at = NULL WHERE pair_pk = ?",
                (pair["pk"],),
            )
        role_filter = "" if side == "both" else " AND u.role = ?"
        users = db.execute(
            """SELECT u.pk, u.username, d.client_id AS device_id, c.password AS saved_password
               FROM users u LEFT JOIN devices d ON d.pk = (
                   SELECT MAX(bound.pk) FROM devices bound WHERE bound.user_pk = u.pk
               )
               LEFT JOIN pair_credentials c ON c.user_pk = u.pk
               WHERE u.pair_pk = ?""" + role_filter,
            (pair["pk"],) if side == "both" else (pair["pk"], ROLE_BY_SIDE[side]),
        ).fetchall()
        if not users and side != "both":
            raise AccountError(404, "account_missing", "Account not found.")

        if action in ("enable", "disable"):
            enabled = int(action == "enable")
            if side == "both":
                # Pair suspension is separate from the enable flag for each end.
                db.execute("UPDATE pairs SET enabled = ? WHERE pk = ?", (enabled, pair["pk"]))
            else:
                db.execute("UPDATE users SET enabled = ? WHERE pk = ?", (enabled, users[0]["pk"]))
        if password_hash is not None:
            account = users[0]
            if new_password == account["saved_password"]:
                new_password = generate_paired_password(exclude=new_password)
                password_hash = service._paired_password_hash(new_password)
            db.execute("UPDATE users SET password_hash = ? WHERE pk = ?",
                       (password_hash, account["pk"]))
            db.execute(
                """INSERT INTO pair_credentials(user_pk, password) VALUES (?, ?)
                   ON CONFLICT(user_pk) DO UPDATE SET password = excluded.password""",
                (account["pk"], new_password),
            )
            credentials.append({"username": account["username"], "password": new_password})

        state = {
            "kick": "kicked", "disable": "disabled", "reset_password": "password_reset", "renew": "renewed",
        }.get(action)
        if state:
            for user in users:
                end_presence(db, user["pk"], state)
                service._revoke_user_sessions(db, user["pk"])

        user = users[0] if side != "both" else None
        record_event(db, event=action, at=now, pair_id=pair_id, side=side,
                     username=user["username"] if user else None,
                     device_id=user["device_id"] if user else None, actor=actor)
    return {"ok": True, "credentials": credentials} if credentials else {"ok": True}
