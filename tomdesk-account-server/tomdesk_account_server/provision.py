import csv
import os
from pathlib import Path
import secrets
import string
import time

from .service import AccountError, AccountService, username_key


CREDENTIAL_COLUMNS = (
    "pair_id", "controller_username", "controller_password",
    "receiver_username", "receiver_password",
)
CODE_LENGTH = 8
IDENTIFIER_ALPHABET = string.ascii_lowercase + string.digits
PASSWORD_ALPHABET = string.ascii_letters + string.digits
GENERATION_ATTEMPTS = 32


def _random_code(alphabet: str, length: int) -> str:
    return "".join(secrets.choice(alphabet) for _ in range(length))


def _new_identifiers() -> dict[str, str]:
    return {
        key: prefix + _random_code(IDENTIFIER_ALPHABET, CODE_LENGTH - 1)
        for key, prefix in (
            ("pair_id", "p"), ("controller_username", "a"), ("receiver_username", "b"),
        )
    }


def generate_paired_password(exclude: str | None = None) -> str:
    for _ in range(GENERATION_ATTEMPTS):
        password = _random_code(PASSWORD_ALPHABET, CODE_LENGTH)
        if password != exclude:
            return password
    raise AccountError(503, "credential_generation_failed", "Could not generate a new password. Try again.")


def prepare_pairs(service: AccountService, count: int):
    if not 1 <= count <= 1000:
        raise ValueError("Count must be between 1 and 1000.")
    prepared = []
    for _ in range(count):
        row = _new_identifiers()
        row["controller_password"] = generate_paired_password()
        row["receiver_password"] = generate_paired_password(exclude=row["controller_password"])
        hashes = (
            service._paired_password_hash(row["controller_password"]),
            service._paired_password_hash(row["receiver_password"]),
        )
        prepared.append((row, hashes))
    return prepared


def insert_prepared_pairs(db, prepared, now: int):
    """Insert credentials and hashes within the caller's immediate write transaction."""
    for row, hashes in prepared:
        # Check under the write lock so concurrent batches cannot reserve the same IDs.
        for attempt in range(GENERATION_ATTEMPTS):
            names = tuple(username_key(row[role + "_username"]) for role in ("controller", "receiver"))
            conflict = db.execute(
                """SELECT EXISTS(SELECT 1 FROM pairs WHERE pair_id = ?)
                        OR EXISTS(SELECT 1 FROM users WHERE username_key IN (?, ?))""",
                (row["pair_id"], *names),
            ).fetchone()[0]
            if not conflict:
                break
            if attempt + 1 < GENERATION_ATTEMPTS:
                row.update(_new_identifiers())
        else:
            raise AccountError(503, "identifier_generation_failed", "Could not generate unique accounts. Try again.")
        pair_pk = db.execute(
            "INSERT INTO pairs(pair_id, created_at) VALUES (?, ?)", (row["pair_id"], now)
        ).lastrowid
        db.execute("INSERT INTO pair_lifetimes(pair_pk) VALUES (?)", (pair_pk,))
        for role, name_key, password_hash in zip(("controller", "receiver"), names, hashes):
            username = row[role + "_username"]
            user_pk = db.execute(
                """INSERT INTO users
                   (username_key, username, display_name, password_hash, role, pair_pk, created_at)
                   VALUES (?, ?, ?, ?, ?, ?, ?)""",
                (name_key, username, username, password_hash, role, pair_pk, now),
            ).lastrowid
            db.execute(
                "INSERT INTO pair_credentials(user_pk, password) VALUES (?, ?)",
                (user_pk, row[role + "_password"]),
            )


def create_pairs(service: AccountService, count: int, output: Path) -> int:
    if not 1 <= count <= 1000:
        raise ValueError("Count must be between 1 and 1000.")
    if not output.is_absolute():
        raise ValueError("The credentials output path must be absolute.")
    if os.name != "posix":
        raise ValueError("Create pairs inside the Linux service container so credentials can be restricted to mode 0600.")
    output = output.resolve()
    descriptor = os.open(output, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    export_complete = False
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8", newline="") as handle:
            os.fchmod(handle.fileno(), 0o600)
            prepared = prepare_pairs(service, count)
            with service.connection() as db:
                db.execute("BEGIN IMMEDIATE")
                insert_prepared_pairs(db, prepared, int(time.time()))
                writer = csv.DictWriter(handle, fieldnames=CREDENTIAL_COLUMNS)
                writer.writeheader()
                writer.writerows(row for row, _ in prepared)
                handle.flush()
                os.fsync(handle.fileno())
            export_complete = True
        return count
    except BaseException:
        if not export_complete:
            output.unlink(missing_ok=True)
        raise
