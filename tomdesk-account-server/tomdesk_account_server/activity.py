"""Device activity and durable paired-account history."""

OFFLINE_AFTER = 90
_CONTACT_GRANULARITY = 5


def initialize_activity(db):
    db.execute(
        """CREATE TABLE IF NOT EXISTS pair_presence (
            user_pk INTEGER PRIMARY KEY REFERENCES users(pk) ON DELETE CASCADE,
            device_pk INTEGER NOT NULL,
            device_id TEXT NOT NULL,
            last_seen INTEGER NOT NULL,
            state TEXT NOT NULL
        )"""
    )
    db.execute(
        """CREATE TABLE IF NOT EXISTS pair_events (
            pk INTEGER PRIMARY KEY,
            event TEXT NOT NULL,
            at INTEGER NOT NULL,
            pair_id TEXT,
            side TEXT,
            username TEXT,
            device_id TEXT,
            actor TEXT,
            detail TEXT
        )"""
    )
    db.execute("CREATE INDEX IF NOT EXISTS pair_events_pair_pk ON pair_events(pair_id, pk)")


def record_event(db, *, event, at, pair_id, side=None, username=None,
                 device_id=None, actor=None, detail=None):
    db.execute(
        """INSERT INTO pair_events(event, at, pair_id, side, username, device_id, actor, detail)
           VALUES (?, ?, ?, ?, ?, ?, ?, ?)""",
        (event, at, pair_id, side, username, device_id, actor, detail),
    )


def end_presence(db, user_pk, state):
    db.execute("UPDATE pair_presence SET state = ? WHERE user_pk = ?", (state, user_pk))


def _user_event(db, user_pk, event, at, device_id):
    user = db.execute(
        """SELECT u.username, u.role, p.pair_id
           FROM users u JOIN pairs p ON p.pk = u.pair_pk WHERE u.pk = ?""",
        (user_pk,),
    ).fetchone()
    if user is not None:
        record_event(
            db, event=event, at=at, pair_id=user["pair_id"],
            side="a" if user["role"] == "controller" else "b",
            username=user["username"], device_id=device_id,
        )


def _set_presence(db, user_pk, device_pk, device_id, now, state="online"):
    db.execute(
        """INSERT INTO pair_presence(user_pk, device_pk, device_id, last_seen, state)
           VALUES (?, ?, ?, ?, ?)
           ON CONFLICT(user_pk) DO UPDATE SET device_pk = excluded.device_pk,
               device_id = excluded.device_id, last_seen = excluded.last_seen, state = excluded.state""",
        (user_pk, device_pk, device_id, now, state),
    )


def record_login(db, user_pk, device_pk, device_id, now):
    _set_presence(db, user_pk, device_pk, device_id, now)
    _user_event(db, user_pk, "login", now, device_id)


def record_logout(db, user_pk, device_pk, device_id, now):
    _set_presence(db, user_pk, device_pk, device_id, now, "logout")
    _user_event(db, user_pk, "logout", now, device_id)


def record_replacement(db, user_pk, device_id, device_uuid, now):
    previous = db.execute(
        """SELECT client_id FROM devices
           WHERE user_pk = ? AND (client_id <> ? OR device_uuid <> ?)""",
        (user_pk, device_id, device_uuid),
    )
    for device in previous:
        _user_event(db, user_pk, "device_replaced", now, device["client_id"])


def _presence(db, user_pk):
    return db.execute(
        "SELECT device_pk, device_id, last_seen, state FROM pair_presence WHERE user_pk = ?",
        (user_pk,),
    ).fetchone()


def _same_device(previous, session):
    return (previous is not None and previous["device_pk"] == session["device_pk"]
            and previous["device_id"] == session["client_id"])


def _contact_due(previous, session, now):
    return (not _same_device(previous, session) or previous["state"] != "online"
            or previous["last_seen"] <= now - _CONTACT_GRANULARITY)


def contact_due(db, session, now):
    return _contact_due(_presence(db, session["user_pk"]), session, now)


def touch_contact(db, session, now):
    user_pk = session["user_pk"]
    device_id = session["client_id"]
    previous = _presence(db, user_pk)
    if not _contact_due(previous, session, now):
        return
    if _same_device(previous, session):
        state = previous["state"]
        offline_at = previous["last_seen"] + OFFLINE_AFTER
        if state == "online" and offline_at <= now:
            _user_event(db, user_pk, "offline", offline_at, device_id)
            state = "offline"
        if state == "offline":
            _user_event(db, user_pk, "reconnected", now, device_id)
    _set_presence(db, user_pk, session["device_pk"], device_id, now)


def sweep_presence(db, now):
    rows = db.execute(
        """SELECT pp.user_pk, pp.device_id, pp.last_seen, pp.state,
                  MAX(s.expires_at) AS last_expiry
           FROM pair_presence pp
           JOIN users u ON u.pk = pp.user_pk
           JOIN pairs p ON p.pk = u.pair_pk
           LEFT JOIN devices d ON d.pk = pp.device_pk AND d.user_pk = u.pk AND d.client_id = pp.device_id
           LEFT JOIN sessions s ON s.device_pk = d.pk
           WHERE pp.state IN ('online','offline') AND u.enabled = 1 AND p.enabled = 1
           GROUP BY pp.user_pk
           HAVING last_expiry IS NULL OR last_expiry <= ?
                  OR (pp.state = 'online' AND pp.last_seen <= ?)""",
        (now, now - OFFLINE_AFTER),
    ).fetchall()
    for row in rows:
        user_pk = row["user_pk"]
        device_id = row["device_id"]
        last_expiry = row["last_expiry"]
        offline_at = row["last_seen"] + OFFLINE_AFTER
        if last_expiry is None:
            # Other code may revoke sessions without observing a client disconnect.
            end_presence(db, user_pk, "revoked")
            continue
        if row["state"] == "online" and offline_at <= now and offline_at < last_expiry:
            _user_event(db, user_pk, "offline", offline_at, device_id)
            end_presence(db, user_pk, "offline")
        if last_expiry <= now:
            _user_event(db, user_pk, "expired", last_expiry, device_id)
            end_presence(db, user_pk, "expired")
