from pathlib import Path
import tempfile
import time
import unittest
from unittest.mock import patch

from fastapi.testclient import TestClient

from tomdesk_account_server.admin_web import create_web_admin, disable_web_admin
from tomdesk_account_server.app import create_app
from tomdesk_account_server.config import Settings


ORIGIN = "https://admin.test"
ADMIN = "test-operator"
ADMIN_PASSWORD = "synthetic admin password only"
A = {"id": "910000001", "uuid": "temporary-admin-a-device"}
B = {"id": "910000002", "uuid": "temporary-admin-b-device"}


class WebAdminIntegrationTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.db = Path(temp.name) / "accounts.sqlite3"
        app = create_app(Settings(db_path=self.db, admin_origin=ORIGIN))
        self.service = app.state.account_service
        create_web_admin(self.service, ADMIN, ADMIN_PASSWORD)
        self.client = TestClient(app, base_url=ORIGIN)
        self.client.__enter__()
        self.addCleanup(self.client.__exit__, None, None, None)

    def login_admin(self):
        response = self.client.post(
            "/admin/api/session", headers={"Origin": ORIGIN},
            json={"username": ADMIN, "password": ADMIN_PASSWORD},
        )
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.json()["admin"]["username"], ADMIN)
        return response, {
            "Origin": ORIGIN, "X-CSRF-Token": response.json()["csrf_token"],
        }

    def test_admin_disabled_by_default_and_frontend_serves_secure_headers(self):
        with tempfile.TemporaryDirectory() as disabled:
            app = create_app(Settings(db_path=Path(disabled) / "accounts.sqlite3"))
            with TestClient(app, base_url=ORIGIN) as client:
                self.assertEqual(client.get("/health").status_code, 200)
                self.assertEqual(client.get("/admin/").status_code, 404)
                self.assertEqual(client.get("/admin/api/pairs").status_code, 404)
        index = self.client.get("/admin/")
        self.assertEqual(index.status_code, 200)
        self.assertIn("frame-ancestors 'none'", index.headers["content-security-policy"])
        self.assertEqual(index.headers["cache-control"], "no-store")
        self.assertEqual(self.client.get("/admin/assets/app.js").status_code, 200)
        self.assertEqual(self.client.get("/admin/assets/not-a-file").status_code, 404)
        with TestClient(self.client.app, base_url="http://admin.test") as client:
            self.assertEqual(client.get("/admin/").status_code, 404)

    def test_admin_requires_https_origin_csrf_and_independent_credentials(self):
        self.assertEqual(self.client.get("/admin/api/pairs").status_code, 401)
        body = {"username": ADMIN, "password": ADMIN_PASSWORD}
        self.assertEqual(self.client.post("/admin/api/session", json=body).status_code, 403)
        self.assertEqual(self.client.post(
            "/admin/api/session", headers={"Origin": "https://other.test"}, json=body,
        ).status_code, 403)
        # The legacy account display flag does not grant management privileges.
        self.service.create_user("fake-operator", ADMIN_PASSWORD, is_admin=True)
        self.assertEqual(self.client.post(
            "/admin/api/session", headers={"Origin": ORIGIN},
            json={"username": "fake-operator", "password": ADMIN_PASSWORD},
        ).status_code, 401)
        response, headers = self.login_admin()
        cookie = response.headers["set-cookie"].lower()
        for attribute in ("secure", "httponly", "samesite=strict", "path=/admin"):
            self.assertIn(attribute, cookie)
        self.assertEqual(response.headers["cache-control"], "no-store")
        self.assertEqual(self.client.get("/admin/api/session").status_code, 200)
        self.assertEqual(self.client.post(
            "/admin/api/pairs", headers={"Origin": ORIGIN}, json={"count": 1},
        ).status_code, 403)
        self.assertEqual(self.client.post(
            "/admin/api/pairs", headers={**headers, "Origin": "https://other.test"},
            json={"count": 1},
        ).status_code, 403)
        disable_web_admin(self.service, ADMIN)
        self.assertEqual(self.client.get("/admin/api/session").status_code, 401)

    def test_pair_actions_revoke_sessions_and_keep_an_admin_audit(self):
        _, headers = self.login_admin()
        response = self.client.post("/admin/api/pairs", headers=headers, json={"count": 2})
        self.assertIn(response.status_code, (200, 201))
        credentials = response.json()["credentials"]
        self.assertEqual(len(credentials), 2)
        self.assertEqual(len({row["pair_id"] for row in credentials}), 2)
        for credential in credentials:
            for value in credential.values():
                self.assertRegex(value, r"^[A-Za-z0-9]{8}$")
        pair = credentials[0]

        def device_login(side, password=None):
            role, identity = ("controller", A) if side == "a" else ("receiver", B)
            return self.client.post("/api/login", json={
                **identity, "type": "account", "autoLogin": False,
                "username": pair[f"{role}_username"],
                "password": password if password is not None else pair[f"{role}_password"],
                "client_role": role,
            })

        def device_post(path, identity, token, **fields):
            return self.client.post(path, headers={"Authorization": f"Bearer {token}"},
                                    json={**identity, **fields})

        def action(name, side):
            result = self.client.post(
                f"/admin/api/pairs/{pair['pair_id']}/action",
                headers=headers, json={"action": name, "side": side},
            )
            self.assertEqual(result.status_code, 200)
            return result.json()

        a_token = device_login("a").json()["access_token"]
        b_token = device_login("b").json()["access_token"]
        listed = self.client.get("/admin/api/pairs", params={"q": pair["pair_id"]})
        self.assertEqual(listed.status_code, 200)
        self.assertEqual(listed.json()["total"], 1)
        row = listed.json()["items"][0]
        self.assertTrue(row["a"]["online"])
        self.assertTrue(row["b"]["online"])
        self.assertEqual(row["b"]["device_id"], B["id"])
        self.assertIsInstance(row["b"]["last_seen"], int)
        self.assertEqual(listed.headers["cache-control"], "no-store")
        self.assertEqual(row["a"]["password"], pair["controller_password"])
        self.assertEqual(row["b"]["password"], pair["receiver_password"])
        normal_response = device_post("/api/currentUser", A, a_token)
        self.assertEqual(normal_response.status_code, 200)
        self.assertNotIn(pair["controller_password"], normal_response.text)
        with TestClient(self.client.app, base_url=ORIGIN) as anonymous:
            self.assertEqual(anonymous.get("/admin/api/pairs").status_code, 401)

        grant = device_post("/api/tomdesk/connection-ticket", A, a_token,
                            target_id=B["id"], conn_type="remote",
                            supports_pair_activation=True).json()
        envelope = {"ticket": grant["ticket"], "source_id": A["id"], "conn_type": "remote"}
        self.assertEqual(device_post("/api/tomdesk/consume-ticket", B, b_token,
                                     **envelope).status_code, 200)
        action("kick", "b")
        self.assertEqual(device_post("/api/currentUser", A, a_token).status_code, 200)
        self.assertEqual(device_post("/api/currentUser", B, b_token).status_code, 401)
        self.assertEqual(device_post("/api/tomdesk/connection-status", B, b_token,
                                     **envelope).status_code, 401)
        b_token = device_login("b").json()["access_token"]

        action("kick", "both")
        self.assertEqual(device_post("/api/currentUser", A, a_token).status_code, 401)
        self.assertEqual(device_post("/api/currentUser", B, b_token).status_code, 401)
        self.assertEqual(device_login("a").status_code, 200)
        self.assertEqual(device_login("b").status_code, 200)
        action("disable", "both")
        self.assertEqual(device_login("a").status_code, 403)
        self.assertEqual(device_login("b").status_code, 403)
        action("enable", "both")
        self.assertEqual(device_login("b").status_code, 200)
        new_password = action("reset_password", "a")["credentials"][0]["password"]
        self.assertRegex(new_password, r"^[A-Za-z0-9]{8}$")
        self.assertNotEqual(new_password, pair["controller_password"])
        listed = self.client.get("/admin/api/pairs", params={"q": pair["pair_id"]})
        self.assertEqual(listed.json()["items"][0]["a"]["password"], new_password)
        self.assertEqual(listed.json()["items"][0]["b"]["password"], pair["receiver_password"])
        self.assertEqual(device_login("a").status_code, 401)
        self.assertEqual(device_login("a", new_password).status_code, 200)

        history = self.client.get("/admin/api/events", params={"pair_id": pair["pair_id"]})
        self.assertEqual(history.status_code, 200)
        self.assertNotIn(new_password, history.text)
        events = history.json()["items"]
        self.assertTrue(any(row["event"] == "login" and row["username"] == pair["receiver_username"]
                            for row in events))
        self.assertGreaterEqual(sum(row["actor"] == ADMIN for row in events), 6)

        self.service.set_password(pair["controller_username"], "synthetic password set by CLI")
        listed = self.client.get("/admin/api/pairs", params={"q": pair["pair_id"]})
        self.assertIsNone(listed.json()["items"][0]["a"]["password"])
        self.assertEqual(device_login("a", "synthetic password set by CLI").status_code, 200)

    def test_paired_device_presence_does_not_change_discovery_of_stale_receiver(self):
        _, headers = self.login_admin()
        credentials = self.client.post("/admin/api/pairs", headers=headers, json={"count": 1}).json()["credentials"][0]
        now = int(time.time())

        def login(role, identity):
            return self.client.post("/api/login", json={
                **identity, "client_role": role,
                "username": credentials[f"{role}_username"],
                "password": credentials[f"{role}_password"],
            }).json()["access_token"]

        def post(path, identity, token):
            return self.client.post(path, json=identity, headers={"Authorization": f"Bearer {token}"})

        def discover():
            result = post("/api/tomdesk/paired-device", A, a_token)
            self.assertEqual(result.status_code, 200)
            return result.json()

        with patch("tomdesk_account_server.service.time.time", return_value=now):
            a_token = login("controller", A)
            self.assertEqual(discover(), {"target_id": None, "online": False})
            b_token = login("receiver", B)
            self.assertEqual(discover(), {"target_id": B["id"], "online": True})
        with patch("tomdesk_account_server.service.time.time", return_value=now + 89):
            self.assertTrue(discover()["online"])
        with patch("tomdesk_account_server.service.time.time", return_value=now + 90):
            self.assertEqual(discover(), {"target_id": B["id"], "online": False})
            self.assertEqual(post("/api/currentUser", B, b_token).status_code, 200)
            self.assertEqual(discover(), {"target_id": B["id"], "online": True})
            self.assertEqual(post("/api/logout", B, b_token).status_code, 200)
            self.assertEqual(discover(), {"target_id": None, "online": False})
            login("receiver", B)
            response = self.client.post(f"/admin/api/pairs/{credentials['pair_id']}/action", headers=headers,
                                        json={"action": "disable", "side": "b"})
            self.assertEqual(response.status_code, 200)
            self.assertEqual(discover(), {"target_id": None, "online": False})

    def test_legacy_pair_keeps_its_identifiers_and_login_without_disclosing_a_password(self):
        original_pair_id = "pair_123456789abcdef012345678"
        original_username = "a_123456789abcdef012345678"
        original_password = "legacy test password"
        self.service.create_user(original_username, original_password, role="controller")
        with self.service.connection() as db:
            pair_pk = db.execute("INSERT INTO pairs(pair_id, created_at) VALUES (?, 1)",
                                 (original_pair_id,)).lastrowid
            db.execute("UPDATE users SET pair_pk = ? WHERE username_key = ?",
                       (pair_pk, original_username))
            db.execute("DROP TABLE pair_credentials")
        migrated = create_app(Settings(db_path=self.db, admin_origin=ORIGIN))
        with TestClient(migrated, base_url=ORIGIN) as client:
            self.assertEqual(client.post("/admin/api/session", headers={"Origin": ORIGIN}, json={
                "username": ADMIN, "password": ADMIN_PASSWORD,
            }).status_code, 200)
            row = client.get("/admin/api/pairs").json()["items"][0]
            self.assertEqual(row["pair_id"], original_pair_id)
            self.assertEqual(row["a"]["username"], original_username)
            self.assertIsNone(row["a"]["password"])
            self.assertEqual(client.post("/api/login", json={
                **A, "type": "account", "autoLogin": False, "username": original_username,
                "password": original_password, "client_role": "controller",
            }).status_code, 200)


if __name__ == "__main__":
    unittest.main()
