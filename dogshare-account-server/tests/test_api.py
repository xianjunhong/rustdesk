from contextlib import closing
from dataclasses import replace
from pathlib import Path
import csv
import hashlib
import os
import stat
import sqlite3
import tempfile
import time
import unittest
from unittest.mock import patch

from fastapi.testclient import TestClient

from dogshare_account_server.app import create_app
from dogshare_account_server.config import Settings
from dogshare_account_server.provision import CREDENTIAL_COLUMNS, create_pairs
from dogshare_account_server.service import AccountError


PASSWORD = "Test-only password 123!"
REPLACEMENT = "Different test password 456!"
ALICE = {"id": "100000001", "uuid": "alice-device-uuid"}
BOB = {"id": "100000002", "uuid": "bob-device-uuid"}


class AccountApiTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.settings = Settings(db_path=Path(self.temp.name) / "accounts.sqlite3")
        self.app = create_app(self.settings)
        self.service = self.app.state.account_service
        self.service.create_user("alice", PASSWORD, "Alice", role="controller")
        self.service.create_user("bob", PASSWORD, "Bob")
        self.pair("test-pair", "alice", "bob")
        self.client = TestClient(self.app)
        self.client.__enter__()

    def tearDown(self):
        self.client.__exit__(None, None, None)
        self.temp.cleanup()

    def pair(self, pair_id, controller, receiver):
        with self.service.connection() as db:
            db.execute("BEGIN IMMEDIATE")
            pair_pk = db.execute("INSERT INTO pairs(pair_id, created_at) VALUES (?, ?)",
                                 (pair_id, int(time.time()))).lastrowid
            db.execute("UPDATE users SET pair_pk = ? WHERE username IN (?, ?)",
                       (pair_pk, controller, receiver))

    def login(self, username="alice", identity=None, password=PASSWORD, prior=None, **extra):
        headers = {"Authorization": f"Bearer {prior}"} if prior is not None else {}
        return self.client.post("/api/login", headers=headers, json={
            **(identity or ALICE), "username": username, "password": password,
            "type": "account", "autoLogin": False, "deviceInfo": {"platform": "Windows"}, **extra,
        })

    def post(self, path, token, identity=None, **extra):
        return self.client.post(path, headers={"Authorization": f"Bearer {token}"},
                                json={**(identity or ALICE), **extra})

    def ticket(self, token):
        response = self.post("/api/dogshare/connection-ticket", token,
                             target_id=BOB["id"], conn_type="remote")
        self.assertEqual(response.status_code, 200, response.text)
        return response.json()

    def test_login_contract_permissions_and_stored_credentials(self):
        self.assertEqual(self.client.get("/health").json(), {"status": "ok"})
        self.assertEqual(self.client.get("/api/login-options").json(), [])
        response = self.login()
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.headers["Cache-Control"], "no-store")
        payload = response.json()
        self.assertEqual(payload["type"], "access_token")
        self.assertEqual(payload["user"], {
            "name": "alice", "display_name": "Alice", "avatar": "", "status": 1, "is_admin": False,
            "role": "controller",
        })
        self.assertGreater(payload["expires_at"], time.time())
        self.assertLessEqual(payload["expires_at"], time.time() + self.settings.session_ttl)
        token = payload["access_token"]
        self.assertGreaterEqual(len(token), 43)
        current = self.post("/api/currentUser", token)
        self.assertEqual(current.json(), payload["user"])
        for action in ("remote", "subtitles"):
            authorized = self.post("/api/dogshare/authorize", token, action=action)
            self.assertEqual(authorized.status_code, 200)
            self.assertEqual(authorized.json()["permissions"], {"remote": True, "subtitles": True})
        with closing(sqlite3.connect(self.settings.db_path)) as db:
            password_hash = db.execute("SELECT password_hash FROM users WHERE username = ?", ("alice",)).fetchone()[0]
            stored_token = db.execute("SELECT token_hash FROM sessions").fetchone()[0]
        self.assertTrue(password_hash.startswith("$argon2id$"))
        self.assertNotIn(PASSWORD, password_hash)
        self.assertNotEqual(stored_token, token)
        self.assertEqual(len(stored_token), 64)

    def test_invalid_expired_wrong_device_and_logged_out_sessions_are_rejected(self):
        payload = self.login().json()
        token = payload["access_token"]
        self.assertEqual(self.post("/api/currentUser", "x" * 43).status_code, 401)
        self.assertEqual(self.post("/api/currentUser", token, {**ALICE, "uuid": "wrong-uuid"}).status_code, 401)
        self.assertEqual(self.post("/api/currentUser", token, {**ALICE, "id": "wrong-id"}).status_code, 401)
        with patch("dogshare_account_server.service.time.time", return_value=payload["expires_at"]):
            self.assertEqual(self.post("/api/dogshare/authorize", token, action="remote").status_code, 401)
        self.assertEqual(self.post("/api/logout", token).status_code, 200)
        self.assertEqual(self.post("/api/currentUser", token).status_code, 401)

    def test_legacy_binding_conflicts_and_administrator_revocations(self):
        with self.service.connection() as db:
            db.execute("UPDATE users SET pair_pk = NULL")
        first = self.login().json()["access_token"]
        self.assertEqual(self.login("bob", ALICE).status_code, 409)
        self.assertEqual(self.login("bob", {**ALICE, "uuid": "different-uuid"}).status_code, 409)
        self.assertEqual(self.post("/api/currentUser", first).status_code, 200)
        self.service.set_password("alice", REPLACEMENT)
        self.assertEqual(self.post("/api/currentUser", first).status_code, 401)
        self.assertEqual(self.login().status_code, 401)
        second = self.login(password=REPLACEMENT).json()["access_token"]
        self.service.unbind_device(ALICE["id"])
        self.assertEqual(self.post("/api/currentUser", second).status_code, 401)
        third = self.login(password=REPLACEMENT).json()["access_token"]
        self.service.disable_user("alice")
        self.assertEqual(self.post("/api/dogshare/authorize", third, action="subtitles").status_code, 401)
        self.assertEqual(self.login(password=REPLACEMENT).status_code, 401)

    def test_ticket_is_bound_to_source_target_type_and_consumed_once(self):
        alice = self.login().json()["access_token"]
        bob = self.login("bob", BOB).json()["access_token"]
        ticket = self.ticket(alice)
        self.assertLessEqual(ticket["expires_at"], time.time() + self.settings.ticket_ttl)
        endpoint = "/api/dogshare/consume-ticket"
        fields = {"ticket": ticket["ticket"], "source_id": ALICE["id"], "conn_type": "remote"}
        self.assertEqual(self.post(endpoint, alice, **fields).status_code, 403)
        self.assertEqual(self.post(endpoint, bob, BOB, **{**fields, "source_id": "wrong"}).status_code, 403)
        self.assertEqual(self.post(endpoint, bob, BOB, **{**fields, "conn_type": "file_transfer"}).status_code, 403)
        status_path = "/api/dogshare/connection-status"
        self.assertEqual(self.post(status_path, bob, BOB, **fields).status_code, 403)
        accepted = self.post(endpoint, bob, BOB, **fields)
        self.assertEqual(accepted.status_code, 200)
        self.assertEqual(accepted.json(), {
            "authorized": True,
            "source": {"id": ALICE["id"], "user_name": "alice", "role": "controller"},
            "target": {"id": BOB["id"], "user_name": "bob", "role": "receiver"},
        })
        self.assertEqual(self.post(endpoint, bob, BOB, **fields).status_code, 403)
        self.assertEqual(self.post(status_path, bob, BOB, **fields).json(), accepted.json())

    def test_ticket_expiry_unbound_target_and_revoked_source(self):
        alice = self.login().json()["access_token"]
        unavailable = self.post("/api/dogshare/connection-ticket", alice,
                                target_id=BOB["id"], conn_type="remote")
        self.assertEqual(unavailable.status_code, 404)
        bob = self.login("bob", BOB).json()["access_token"]
        ticket = self.ticket(alice)
        fields = {"ticket": ticket["ticket"], "source_id": ALICE["id"], "conn_type": "remote"}
        with patch("dogshare_account_server.service.time.time", return_value=ticket["expires_at"]):
            expired = self.post("/api/dogshare/consume-ticket", bob, BOB, **fields)
            self.assertEqual(expired.status_code, 403)
        self.assertEqual(self.post("/api/logout", alice).status_code, 200)
        revoked = self.post("/api/dogshare/consume-ticket", bob, BOB, **fields)
        self.assertEqual(revoked.status_code, 403)

    def test_consumed_connection_survives_mint_expiry_and_requires_original_target_session(self):
        alice = self.login().json()["access_token"]
        bob = self.login("bob", BOB).json()["access_token"]
        ticket = self.ticket(alice)
        fields = {"ticket": ticket["ticket"], "source_id": ALICE["id"], "conn_type": "remote"}
        self.assertEqual(self.post("/api/dogshare/consume-ticket", bob, BOB, **fields).status_code, 200)
        path = "/api/dogshare/connection-status"
        with patch("dogshare_account_server.service.time.time", return_value=ticket["expires_at"] + 1):
            self.ticket(alice)
            status = self.post(path, bob, BOB, **fields)
            self.assertEqual(status.status_code, 200)
            self.assertTrue(status.json()["authorized"])
            self.assertEqual(self.post("/api/dogshare/consume-ticket", bob, BOB, **fields).status_code, 403)

        pending = self.ticket(alice)
        replacement_bob = self.login("bob", BOB).json()["access_token"]
        self.assertEqual(self.post("/api/currentUser", bob, BOB).status_code, 401)
        self.assertEqual(self.post(path, bob, BOB, **fields).status_code, 401)
        self.assertEqual(self.post(path, replacement_bob, BOB, **fields).status_code, 403)
        for candidate, expected in ((pending, 403), (self.ticket(alice), 200)):
            result = self.post("/api/dogshare/consume-ticket", replacement_bob, BOB,
                               **{**fields, "ticket": candidate["ticket"]})
            self.assertEqual(result.status_code, expected)

    def test_connection_status_rejects_source_and_target_logout(self):
        for side in ("source", "target"):
            with self.subTest(side=side):
                alice = self.login().json()["access_token"]
                bob = self.login("bob", BOB).json()["access_token"]
                ticket = self.ticket(alice)
                fields = {"ticket": ticket["ticket"], "source_id": ALICE["id"], "conn_type": "remote"}
                self.assertEqual(self.post("/api/dogshare/consume-ticket", bob, BOB, **fields).status_code, 200)
                token, identity = (alice, ALICE) if side == "source" else (bob, BOB)
                self.assertEqual(self.post("/api/logout", token, identity).status_code, 200)
                status = self.post("/api/dogshare/connection-status", bob, BOB, **fields)
                self.assertEqual(status.status_code, 403 if side == "source" else 401)
                if side == "target":
                    new_bob = self.login("bob", BOB).json()["access_token"]
                    status = self.post("/api/dogshare/connection-status", new_bob, BOB, **fields)
                    self.assertEqual(status.status_code, 403)

    def test_roles_reject_legacy_receiver_control_and_non_remote_tickets(self):
        alice = self.login(client_role="controller").json()["access_token"]
        for extra in ({}, {"client_role": "receiver"}):
            with self.subTest(client=extra):
                login = self.login("bob", BOB, **extra)
                self.assertEqual(login.status_code, 200)
                self.assertEqual(login.json()["user"]["role"], "receiver")
                bob = login.json()["access_token"]
                allowed = self.post("/api/dogshare/authorize", bob, BOB, action="subtitles")
                self.assertEqual(allowed.json()["permissions"], {"remote": False, "subtitles": True})
                denied = self.post("/api/dogshare/connection-ticket", bob, BOB,
                                   target_id=ALICE["id"], conn_type="remote")
                self.assertEqual(denied.status_code, 403)
        for username, identity, role in (("alice", ALICE, "receiver"), ("bob", BOB, "controller")):
            response = self.login(username, identity, client_role=role)
            self.assertEqual(response.status_code, 403)
            self.assertEqual(response.json()["code"], "role_mismatch")
        wrong_target = self.post("/api/dogshare/connection-ticket", alice,
                                 target_id=ALICE["id"], conn_type="remote")
        self.assertEqual(wrong_target.status_code, 403)
        for conn_type in ("file_transfer", "port_forward", "view_camera", "terminal"):
            denied = self.post("/api/dogshare/connection-ticket", alice,
                               target_id=BOB["id"], conn_type=conn_type)
            self.assertEqual(denied.status_code, 403)
        ticket = self.ticket(alice)
        fields = {"ticket": ticket["ticket"], "source_id": ALICE["id"], "conn_type": "terminal"}
        with self.service.connection() as db:
            db.execute("UPDATE connection_tickets SET conn_type = 'terminal'")
        self.assertEqual(self.post("/api/dogshare/consume-ticket", bob, BOB, **fields).status_code, 403)
        with self.service.connection() as db:
            db.execute("UPDATE connection_tickets SET conn_type = 'remote'")
        fields["conn_type"] = "remote"
        self.assertEqual(self.post("/api/dogshare/consume-ticket", bob, BOB, **fields).status_code, 200)
        with self.service.connection() as db:
            db.execute("UPDATE connection_tickets SET conn_type = 'file_transfer'")
        fields["conn_type"] = "file_transfer"
        self.assertEqual(self.post("/api/dogshare/connection-status", bob, BOB, **fields).status_code, 403)

    def test_paired_roles_are_locked_and_unpaired_role_change_revokes_sessions(self):
        alice = self.login().json()["access_token"]
        for username, role in (("alice", "receiver"), ("bob", "controller")):
            with self.assertRaises(AccountError) as error:
                self.service.set_role(username, role)
            self.assertEqual(error.exception.code, "paired_role_locked")
        self.assertEqual(self.post("/api/currentUser", alice).json()["role"], "controller")
        identity = {"id": "100000003", "uuid": "unpaired-uuid"}
        self.service.create_user("charlie", PASSWORD, role="controller")
        old = self.login("charlie", identity).json()["access_token"]
        self.service.set_role("charlie", "receiver")
        self.assertEqual(self.post("/api/currentUser", old, identity).status_code, 401)
        typed = self.login("charlie", identity, client_role="receiver")
        self.assertEqual(typed.status_code, 403)
        self.assertEqual(typed.json()["code"], "pair_required")
        changed = self.login("charlie", identity)
        self.assertEqual(changed.json()["user"]["role"], "receiver")
        roles = {user["username"]: user["role"] for user in self.service.list_users()}
        self.assertEqual(roles["charlie"], "receiver")

    def test_pair_discovery_and_cross_pair_ticket_rejection(self):
        alice = self.login(client_role="controller").json()["access_token"]
        path = "/api/dogshare/paired-device"
        self.assertEqual(self.post(path, alice).json(), {"target_id": None, "online": None})
        bob = self.login("bob", BOB, client_role="receiver").json()["access_token"]
        self.assertEqual(self.post(path, alice).json(), {"target_id": BOB["id"], "online": None})
        self.assertEqual(self.post(path, bob, BOB).status_code, 403)
        self.service.create_user("carol", PASSWORD, role="controller")
        self.service.create_user("dave", PASSWORD)
        self.pair("other-pair", "carol", "dave")
        carol_id = {"id": "100000003", "uuid": "carol-device-uuid"}
        dave_id = {"id": "100000004", "uuid": "dave-device-uuid"}
        carol = self.login("carol", carol_id).json()["access_token"]
        self.login("dave", dave_id)
        for token, identity, target_id in ((alice, ALICE, dave_id["id"]), (carol, carol_id, BOB["id"])):
            denied = self.post("/api/dogshare/connection-ticket", token, identity,
                               target_id=target_id, conn_type="remote")
            self.assertEqual(denied.status_code, 403)
            self.assertEqual(denied.json()["code"], "pair_forbidden")
        ticket = self.ticket(alice)
        fields = {"ticket": ticket["ticket"], "source_id": ALICE["id"], "conn_type": "remote"}
        # Existing tickets must use the current pair relation, including after an administrative DB migration.
        with self.service.connection() as db:
            db.execute("UPDATE users SET pair_pk = NULL WHERE username = 'bob'")
        self.assertEqual(self.post("/api/dogshare/consume-ticket", bob, BOB, **fields).status_code, 403)
        with self.service.connection() as db:
            db.execute("UPDATE users SET pair_pk = (SELECT pk FROM pairs WHERE pair_id = 'test-pair') WHERE username = 'bob'")
        self.assertEqual(self.post("/api/dogshare/consume-ticket", bob, BOB, **fields).status_code, 200)
        with self.service.connection() as db:
            db.execute("UPDATE users SET pair_pk = NULL WHERE username = 'bob'")
        self.assertEqual(self.post("/api/dogshare/connection-status", bob, BOB, **fields).status_code, 403)
        with self.service.connection() as db:
            db.execute("UPDATE users SET pair_pk = (SELECT pk FROM pairs WHERE pair_id = 'test-pair') WHERE username = 'bob'")
        self.assertEqual(self.post("/api/logout", bob, BOB).status_code, 200)
        self.assertEqual(self.post(path, alice).json(), {"target_id": None, "online": None})

    def test_paired_account_moves_to_new_device_and_retires_old_connection(self):
        alice = self.login().json()["access_token"]
        bob = self.login("bob", BOB, client_role="receiver").json()["access_token"]
        ticket = self.ticket(alice)
        fields = {"ticket": ticket["ticket"], "source_id": ALICE["id"], "conn_type": "remote"}
        self.assertEqual(self.post("/api/dogshare/consume-ticket", bob, BOB, **fields).status_code, 200)
        replacement = {"id": "100000003", "uuid": "replacement-device-uuid"}
        login = self.login("bob", replacement)
        self.assertEqual(login.status_code, 200)
        self.assertEqual(self.post("/api/currentUser", bob, BOB).status_code, 401)
        self.assertEqual(self.post("/api/dogshare/connection-status", bob, BOB, **fields).status_code, 401)
        self.assertEqual(
            self.post("/api/dogshare/connection-status", login.json()["access_token"],
                      replacement, **fields).status_code, 403,
        )
        self.assertEqual(self.post("/api/dogshare/paired-device", alice).json(),
                         {"target_id": replacement["id"], "online": None})
        stale = self.post("/api/dogshare/connection-ticket", alice,
                          target_id=BOB["id"], conn_type="remote")
        self.assertEqual(stale.status_code, 404)
        self.assertEqual(stale.json()["code"], "device_unavailable")

    def test_paired_device_with_only_expired_session_cannot_receive_tickets(self):
        alice = self.login().json()["access_token"]
        self.assertEqual(self.login("bob", BOB).status_code, 200)
        with self.service.connection() as db:
            db.execute("UPDATE sessions SET expires_at = ? WHERE device_pk = "
                       "(SELECT pk FROM devices WHERE client_id = ?)", (int(time.time()) - 1, BOB["id"]))
        discovery = self.post("/api/dogshare/paired-device", alice)
        self.assertIsNone(discovery.json()["target_id"])
        stale = self.post("/api/dogshare/connection-ticket", alice,
                          target_id=BOB["id"], conn_type="remote")
        self.assertEqual(stale.status_code, 404)
        self.assertEqual(stale.json()["code"], "device_unavailable")

    def test_paired_account_switch_on_same_device_without_old_credentials(self):
        self.service.create_user("carol", PASSWORD, role="controller")
        self.service.create_user("dave", PASSWORD)
        self.pair("other-pair", "carol", "dave")
        older_alice = self.login().json()["access_token"]
        alice = self.login(client_role="controller").json()["access_token"]
        self.assertEqual(self.post("/api/currentUser", older_alice).status_code, 401)
        login = self.login("carol", ALICE, client_role="controller")
        self.assertEqual(login.status_code, 200)
        self.assertEqual(self.post("/api/logout", alice).status_code, 401)
        self.assertEqual(self.post("/api/currentUser", older_alice).status_code, 401)
        carol = login.json()["access_token"]
        self.assertEqual(self.post("/api/currentUser", carol).json()["name"], "carol")

    def test_paired_role_switch_with_changed_id_retires_old_login_after_validation(self):
        alice = self.login(client_role="controller").json()["access_token"]
        self.service.create_user("dave", PASSWORD)
        self.service.create_user("carol", PASSWORD, role="controller")
        self.pair("other-pair", "carol", "dave")
        dave = self.login("dave", BOB, client_role="receiver").json()["access_token"]
        copied_id = self.login("bob", {**ALICE, "uuid": "different-machine"}, client_role="receiver")
        self.assertEqual(copied_id.status_code, 409)
        wrong_password = self.login("bob", ALICE, password=REPLACEMENT,
                                    client_role="receiver")
        self.assertEqual(wrong_password.status_code, 401)
        wrong_role = self.login("bob", ALICE, client_role="controller")
        self.assertEqual(wrong_role.status_code, 403)
        self.assertEqual(self.post("/api/currentUser", alice).json()["name"], "alice")
        changed_id = {**ALICE, "id": "100000009"}
        switched = self.login("bob", changed_id, client_role="receiver")
        self.assertEqual(switched.status_code, 200)
        bob = switched.json()["access_token"]
        self.assertEqual(self.post("/api/currentUser", bob, changed_id).json()["name"], "bob")
        self.assertEqual(self.post("/api/currentUser", alice).status_code, 401)
        self.assertEqual(self.post("/api/currentUser", dave, BOB).json()["name"], "dave")
        fresh = self.login("alice", ALICE, client_role="controller")
        self.assertEqual(fresh.status_code, 200)
        self.assertEqual(self.post("/api/currentUser", bob, changed_id).status_code, 401)
        self.assertEqual(self.post("/api/currentUser", fresh.json()["access_token"]).status_code, 200)

    def test_pair_logout_and_disable_revoke_both_sides_and_connections(self):
        for disable in (False, True):
            alice = self.login(client_role="controller").json()["access_token"]
            bob = self.login("bob", BOB, client_role="receiver").json()["access_token"]
            ticket = self.ticket(alice)
            fields = {"ticket": ticket["ticket"], "source_id": ALICE["id"], "conn_type": "remote"}
            self.assertEqual(self.post("/api/dogshare/consume-ticket", bob, BOB, **fields).status_code, 200)
            self.service.revoke_pair("test-pair", disable=disable)
            self.assertEqual(self.post("/api/currentUser", alice).status_code, 401)
            self.assertEqual(self.post("/api/currentUser", bob, BOB).status_code, 401)
            self.assertEqual(self.post("/api/dogshare/connection-status", bob, BOB, **fields).status_code, 401)
        for username, identity, role in (("alice", ALICE, "controller"), ("bob", BOB, "receiver")):
            for extra in ({}, {"client_role": role}):
                denied = self.login(username, identity, **extra)
                self.assertEqual(denied.status_code, 403)
                self.assertEqual(denied.json()["code"], "pair_disabled")
        pairs = self.service.list_pairs()
        self.assertEqual(len(pairs), 1)
        self.assertEqual(pairs[0]["enabled"], 0)
        self.assertNotIn("password", repr(pairs))

    @unittest.skipUnless(os.name == "posix", "Private 0600 credentials export runs in the Linux service container")
    def test_bulk_pair_credentials_are_private_non_overwriting_and_log_in(self):
        output = Path(self.temp.name) / "batch.csv"
        self.assertEqual(create_pairs(self.service, 2, output), 2)
        self.assertEqual(stat.S_IMODE(output.stat().st_mode), 0o600)
        with output.open(encoding="utf-8", newline="") as handle:
            reader = csv.DictReader(handle)
            self.assertEqual(tuple(reader.fieldnames), CREDENTIAL_COLUMNS)
            rows = list(reader)
        self.assertEqual(len(rows), 2)
        usernames = {row[role + "_username"] for row in rows for role in ("controller", "receiver")}
        passwords = {row[role + "_password"] for row in rows for role in ("controller", "receiver")}
        self.assertEqual(len(usernames), 4)
        self.assertEqual(len(passwords), 4)
        original = output.read_bytes()
        with self.assertRaises(FileExistsError):
            create_pairs(self.service, 1, output)
        self.assertEqual(output.read_bytes(), original)
        self.assertEqual(len(self.service.list_pairs()), 3)
        for index, row in enumerate(rows):
            for role in ("controller", "receiver"):
                identity = {"id": f"generated-{index}-{role}", "uuid": f"generated-uuid-{index}-{role}"}
                response = self.login(row[role + "_username"], identity, row[role + "_password"], client_role=role)
                self.assertEqual(response.status_code, 200)
                self.assertEqual(response.json()["user"]["role"], role)

    def test_legacy_database_preserves_controller_account_and_session(self):
        settings = replace(self.settings, db_path=Path(self.temp.name) / "legacy.sqlite3")
        token = "a" * 43
        now = int(time.time())
        with self.service.connection() as db:
            password_hash = db.execute("SELECT password_hash FROM users WHERE username = 'alice'").fetchone()[0]
        with closing(sqlite3.connect(settings.db_path)) as db:
            db.executescript("""
                CREATE TABLE users (
                    pk INTEGER PRIMARY KEY, username_key TEXT NOT NULL UNIQUE,
                    username TEXT NOT NULL, display_name TEXT NOT NULL, password_hash TEXT NOT NULL,
                    enabled INTEGER NOT NULL DEFAULT 1, is_admin INTEGER NOT NULL DEFAULT 0,
                    created_at INTEGER NOT NULL
                );
                CREATE TABLE devices (
                    pk INTEGER PRIMARY KEY, client_id TEXT NOT NULL UNIQUE, device_uuid TEXT NOT NULL UNIQUE,
                    user_pk INTEGER NOT NULL REFERENCES users(pk) ON DELETE CASCADE, created_at INTEGER NOT NULL
                );
                CREATE TABLE sessions (
                    token_hash TEXT PRIMARY KEY, device_pk INTEGER NOT NULL REFERENCES devices(pk) ON DELETE CASCADE,
                    created_at INTEGER NOT NULL, expires_at INTEGER NOT NULL
                );
            """)
            db.execute("INSERT INTO users VALUES (1, 'frank', 'frank', 'Frank', ?, 1, 1, ?)",
                       (password_hash, now))
            db.execute("INSERT INTO devices VALUES (1, ?, ?, 1, ?)", (ALICE["id"], ALICE["uuid"], now))
            db.execute("INSERT INTO sessions VALUES (?, 1, ?, ?)",
                       (hashlib.sha256(token.encode()).hexdigest(), now, now + 43200))
            db.commit()
        legacy_app = create_app(settings)
        with TestClient(legacy_app) as client:
            headers = {"Authorization": f"Bearer {token}"}
            current = client.post("/api/currentUser", headers=headers, json=ALICE)
            self.assertEqual(current.status_code, 200)
            self.assertEqual(current.json()["name"], "frank")
            self.assertEqual(current.json()["role"], "controller")
            authorized = client.post("/api/dogshare/authorize", headers=headers,
                                     json={**ALICE, "action": "remote"})
            self.assertFalse(authorized.json()["permissions"]["remote"])
            self.assertEqual(client.post("/api/dogshare/paired-device", headers=headers, json=ALICE).status_code, 403)
            typed = client.post("/api/login", json={
                **ALICE, "username": "frank", "password": PASSWORD, "client_role": "controller",
            })
            self.assertEqual(typed.status_code, 403)
            self.assertEqual(typed.json()["code"], "pair_required")
            legacy_app.state.account_service.create_user("new-receiver", PASSWORD)
            create_app(settings)
            receiver = client.post("/api/login", json={
                **BOB, "username": "new-receiver", "password": PASSWORD, "client_role": "receiver",
            })
            self.assertEqual(receiver.status_code, 403)
            self.assertEqual(receiver.json()["code"], "pair_required")
            receiver = client.post("/api/login", json={
                **BOB, "username": "new-receiver", "password": PASSWORD,
            })
            self.assertEqual(receiver.status_code, 200)
            self.assertEqual(receiver.json()["user"]["role"], "receiver")
            denied = client.post("/api/dogshare/connection-ticket", headers=headers,
                                 json={**ALICE, "target_id": BOB["id"], "conn_type": "remote"})
            self.assertEqual(denied.status_code, 403)

    def test_error_redaction_body_limit_and_no_public_registration_or_docs(self):
        wrong = self.login(password="Wrong test password").json()
        missing = self.login(username="missing", password="Wrong test password").json()
        self.assertEqual(wrong, missing)
        response = self.client.post("/api/login", json={
            **ALICE, "username": "alice", "password": {"secret": PASSWORD},
        })
        self.assertEqual(response.status_code, 422)
        self.assertNotIn(PASSWORD, response.text)
        oversized = self.client.post("/api/login", content=b"x" * 16385,
                                     headers={"Content-Type": "application/json"})
        self.assertEqual(oversized.status_code, 413)
        for path in ("/docs", "/openapi.json", "/api/register"):
            self.assertEqual(self.client.get(path).status_code, 404)
        self.assertEqual(self.client.post("/api/register", json={}).status_code, 404)

    def test_login_rate_limit_uses_persistent_account_and_ip_buckets(self):
        settings = replace(self.settings, db_path=Path(self.temp.name) / "rate.sqlite3",
                           login_ip_limit=3, login_account_limit=2)
        with TestClient(create_app(settings)) as client:
            request = {**ALICE, "username": "missing", "password": PASSWORD}
            self.assertEqual(client.post("/api/login", json=request).status_code, 401)
            self.assertEqual(client.post("/api/login", json=request).status_code, 401)
            blocked = client.post("/api/login", json=request)
            self.assertEqual(blocked.status_code, 429)
            self.assertGreater(int(blocked.headers["Retry-After"]), 0)
            request["username"] = "another"
            self.assertEqual(client.post("/api/login", json=request).status_code, 401)
            request["username"] = "third"
            self.assertEqual(client.post("/api/login", json=request).status_code, 429)


if __name__ == "__main__":
    unittest.main()
