from pathlib import Path
import tempfile
import time
import unittest
from unittest.mock import patch

from tomdesk_account_server.config import Settings
from tomdesk_account_server.service import AccountError, AccountService


class PairActivityTests(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.TemporaryDirectory()
        self.addCleanup(self.folder.cleanup)
        self.service = AccountService(Settings(
            db_path=Path(self.folder.name) / "activity.sqlite3",
            admin_origin="https://admin.test",
            session_ttl=120,
        ))
        self.now = int(time.time())
        self.service.create_user("test-receiver", "a test-only password")
        with self.service.connection() as db:
            pair_pk = db.execute(
                "INSERT INTO pairs(pair_id, created_at) VALUES (?, ?)",
                ("test-pair", self.now),
            ).lastrowid
            db.execute("UPDATE users SET pair_pk = ? WHERE username = ?", (pair_pk, "test-receiver"))

    def login(self, seconds=0, device_id="device-a"):
        with patch("tomdesk_account_server.service.time.time", return_value=self.now + seconds):
            return self.service.login(
                "test-receiver", "a test-only password", device_id, f"uuid-{device_id}",
                False, "test-client",
            )["access_token"]

    def authorize(self, token, seconds, device_id="device-a"):
        with patch("tomdesk_account_server.service.time.time", return_value=self.now + seconds):
            return self.service.authorize(token, device_id, f"uuid-{device_id}")

    def sweep(self, seconds):
        with patch("tomdesk_account_server.service.time.time", return_value=self.now + seconds):
            self.service.sweep_activity()

    def history(self):
        with self.service.connection() as db:
            rows = db.execute(
                "SELECT event, at, device_id FROM pair_events WHERE pair_id = 'test-pair' ORDER BY pk"
            ).fetchall()
        return [(event, at - self.now, device) for event, at, device in rows]

    def test_heartbeat_timeout_recovery_and_voluntary_logout(self):
        token = self.login()
        self.sweep(89)
        self.assertEqual(self.history(), [("login", 0, "device-a")])
        self.sweep(95)
        self.sweep(99)
        self.authorize(token, 100)
        with patch("tomdesk_account_server.service.time.time", return_value=self.now + 105):
            self.service.logout(token, "device-a", "uuid-device-a")
        self.sweep(130)
        self.assertEqual(self.history(), [
            ("login", 0, "device-a"),
            ("offline", 90, "device-a"),
            ("reconnected", 100, "device-a"),
            ("logout", 105, "device-a"),
        ])

    def test_only_latest_login_expires_on_the_same_device(self):
        older = self.login()
        newer = self.login(30)
        with self.assertRaises(AccountError):
            self.authorize(older, 31)
        self.authorize(newer, 119)
        self.sweep(120)
        self.assertEqual(self.history(), [("login", 0, "device-a"), ("login", 30, "device-a")])
        self.sweep(150)
        self.sweep(151)
        self.assertEqual(self.history()[-1], ("expired", 150, "device-a"))
        self.assertEqual(len(self.history()), 3)

    def test_device_transfer_logs_old_binding_and_does_not_accept_old_heartbeat(self):
        old = self.login()
        current = self.login(15, "device-b")
        with self.assertRaises(AccountError):
            self.authorize(old, 30)
        self.authorize(current, 31, "device-b")
        self.assertEqual(self.history(), [
            ("login", 0, "device-a"),
            ("device_replaced", 15, "device-a"),
            ("login", 15, "device-b"),
        ])
