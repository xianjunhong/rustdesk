from pathlib import Path
import tempfile
import unittest

from fastapi.testclient import TestClient

from dogshare_account_server.admin_web import create_web_admin
from dogshare_account_server.app import create_app
from dogshare_account_server.config import Settings


ORIGIN = "https://admin.test"
ADMIN = {"username": "web-operator", "password": "Test-only web password 123!"}
CLIENT = {
    "username": "old-admin-flag", "password": "Test-only client password 456!",
    "id": "security-test-device", "uuid": "security-test-uuid",
}


class WebAdminSecurityTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        settings = Settings(
            db_path=Path(self.temp.name) / "accounts.sqlite3",
            admin_origin=ORIGIN, login_ip_limit=2, login_account_limit=2,
        )
        self.app = create_app(settings)
        self.service = self.app.state.account_service
        self.client = TestClient(self.app, base_url=ORIGIN)
        self.client.__enter__()
        self.addCleanup(self.client.__exit__, None, None, None)

    def test_client_admin_flag_and_login_limit_are_separate_from_web_admin(self):
        self.service.create_user(CLIENT["username"], CLIENT["password"], is_admin=True)
        submitted = {key: CLIENT[key] for key in ("username", "password")}
        for expected in (401, 401, 429):
            attempt = self.client.post("/admin/api/session", json=submitted, headers={"Origin": ORIGIN})
            self.assertEqual(attempt.status_code, expected)
        sign_in = self.client.post("/api/login", json=CLIENT)
        self.assertEqual(sign_in.status_code, 200)
        self.assertTrue(sign_in.json()["user"]["is_admin"])
        self.assertEqual(self.client.get("/admin/api/pairs").status_code, 401)

    def test_expired_web_admin_cookie_cannot_authenticate_or_authorize_actions(self):
        create_web_admin(self.service, ADMIN["username"], ADMIN["password"])
        response = self.client.post("/admin/api/session", json=ADMIN, headers={"Origin": ORIGIN})
        self.assertEqual(response.status_code, 200)
        csrf_token = response.json()["csrf_token"]
        self.assertEqual(self.client.get("/admin/api/session").status_code, 200)
        # Simulate server-side expiry while the browser still holds the cookie.
        with self.service.connection() as db:
            db.execute("UPDATE web_admin_sessions SET expires_at = 0")
        self.assertEqual(self.client.get("/admin/api/session").status_code, 401)
        attempt = self.client.post(
            "/admin/api/pairs", json={"count": 1},
            headers={"Origin": ORIGIN, "X-CSRF-Token": csrf_token},
        )
        self.assertEqual(attempt.status_code, 401)


if __name__ == "__main__":
    unittest.main()
