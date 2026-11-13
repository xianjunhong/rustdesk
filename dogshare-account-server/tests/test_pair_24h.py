from pathlib import Path
from tempfile import TemporaryDirectory
import time
import unittest
from unittest.mock import patch

from fastapi.testclient import TestClient

from dogshare_account_server.admin_web import create_web_admin
from dogshare_account_server.app import create_app
from dogshare_account_server.config import Settings


ORIGIN = "https://pair-lifetime.test"
ADMIN = {"username": "lifetime-operator", "password": "synthetic lifetime administrator"}
A = {"id": "910000031", "uuid": "synthetic-lifetime-a"}
B = {"id": "910000032", "uuid": "synthetic-lifetime-b"}
HOURS_24 = 86_400


class PairLifetimeTests(unittest.TestCase):
    def setUp(self):
        directory = self.enterContext(TemporaryDirectory())
        self.now = int(time.time())
        self.enterContext(patch("time.time", side_effect=lambda: self.now))
        settings = Settings(
            db_path=Path(directory) / "test.sqlite3", admin_origin=ORIGIN,
            session_ttl=HOURS_24 * 2, admin_session_ttl=HOURS_24 * 2,
        )
        app = create_app(settings)
        create_web_admin(app.state.account_service, **ADMIN)
        self.client = self.enterContext(TestClient(app, base_url=ORIGIN))
        self.admin_headers = {"Origin": ORIGIN}
        response = self.client.post("/admin/api/session", headers=self.admin_headers, json=ADMIN)
        self.assertEqual(response.status_code, 200)
        self.admin_headers["X-CSRF-Token"] = response.json()["csrf_token"]
        response = self.client.post("/admin/api/pairs", headers=self.admin_headers, json={"count": 1})
        self.assertIn(response.status_code, (200, 201))
        self.pair = response.json()["credentials"][0]

    def login(self, side):
        identity, role = (A, "controller") if side == "a" else (B, "receiver")
        return self.client.post("/api/login", json={
            **identity, "type": "account", "client_role": role,
            "username": self.pair[role + "_username"], "password": self.pair[role + "_password"],
        })

    def device(self, route, identity, token, **fields):
        return self.client.post("/api/dogshare/" + route, json={**identity, **fields},
                                headers={"Authorization": "Bearer " + token})

    def pair_row(self):
        response = self.client.get("/admin/api/pairs", params={"q": self.pair["pair_id"]})
        self.assertEqual(response.status_code, 200)
        return response.json()["items"][0]

    def mint(self, token, **capability):
        return self.device("connection-ticket", A, token, target_id=B["id"], conn_type="remote", **capability)

    def ticket_envelope(self, token):
        response = self.mint(token, supports_pair_activation=True)
        self.assertEqual(response.status_code, 200)
        self.assertTrue(response.json()["activation_required"])
        return {"source_id": A["id"], "conn_type": "remote", "ticket": response.json()["ticket"]}

    def activate(self, envelope, token, identity=A, target_id=B["id"]):
        return self.device("activate-pair", identity, token, ticket=envelope["ticket"], target_id=target_id)

    def renew(self, side="both"):
        return self.client.post("/admin/api/pairs/" + self.pair["pair_id"] + "/action",
                                headers=self.admin_headers, json={"action": "renew", "side": side})

    def test_latest_receiver_login_moves_target_and_preserves_pair_expiry(self):
        a_token = self.login("a").json()["access_token"]
        b_token = self.login("b").json()["access_token"]
        envelope = self.ticket_envelope(a_token)
        self.assertEqual(self.device("consume-ticket", B, b_token, **envelope).status_code, 200)
        deadline = self.activate(envelope, a_token).json()["expires_at"]
        previous_token, previous_identity = b_token, B
        for index in range(2):
            self.now += 30
            identity = {"id": f"replacement-b-{index}", "uuid": f"replacement-machine-{index}"}
            response = self.client.post("/api/login", json={
                **identity, "type": "account", "client_role": "receiver",
                "username": self.pair["receiver_username"], "password": self.pair["receiver_password"],
            })
            self.assertEqual(response.status_code, 200)
            current_token = response.json()["access_token"]
            self.assertEqual(self.device("authorize", previous_identity, previous_token,
                                         action="subtitles").status_code, 401)
            self.assertEqual(self.device("connection-status", identity, current_token,
                                         **envelope).status_code, 403)
            discovery = self.device("paired-device", A, a_token)
            self.assertEqual(discovery.json()["target_id"], identity["id"])
            self.assertEqual(self.pair_row()["expires_at"], deadline)
            previous_token, previous_identity = current_token, identity
        self.now = deadline
        self.assertEqual(self.device("authorize", previous_identity, previous_token,
                                     action="subtitles").json()["code"], "pair_expired")

    def test_first_frame_starts_once_then_expiry_and_admin_renewal(self):
        self.assertEqual(self.pair_row()["expiry_state"], "pending")
        self.assertIsNone(self.pair_row()["expires_at"])
        b_token = self.login("b").json()["access_token"]
        self.now += 60 * 60
        a_token = self.login("a").json()["access_token"]
        self.assertEqual(self.pair_row()["expiry_state"], "pending")
        self.assertEqual(self.mint(a_token).json()["code"], "pair_activation_unsupported")

        envelope = self.ticket_envelope(a_token)
        self.assertEqual(self.activate(envelope, a_token).status_code, 403)
        self.assertEqual(self.device("consume-ticket", B, b_token, **envelope).status_code, 200)
        self.assertEqual(self.device("connection-status", B, b_token, **envelope).status_code, 200)
        self.assertEqual(self.pair_row()["expiry_state"], "pending")
        self.assertEqual(self.activate(envelope, b_token, identity=B).status_code, 403)
        self.assertEqual(self.activate(envelope, a_token, target_id="incorrect-target").status_code, 403)

        self.now += 91
        expired_grace = self.device("connection-status", B, b_token, **envelope)
        self.assertEqual(expired_grace.json()["code"], "pair_activation_timeout")
        self.assertEqual(self.activate(envelope, a_token).json()["code"], "pair_activation_timeout")
        self.assertEqual(self.pair_row()["expiry_state"], "pending")

        valid = self.ticket_envelope(a_token)
        self.assertEqual(self.device("consume-ticket", B, b_token, **valid).status_code, 200)
        self.now += 5
        activation = self.activate(valid, a_token)
        self.assertEqual(activation.status_code, 200)
        self.assertTrue(activation.json()["activated"])
        deadline = self.now + HOURS_24
        self.assertEqual(activation.json()["expires_at"], deadline)
        row = self.pair_row()
        self.assertEqual(row["expiry_state"], "active")
        self.assertEqual(row["activated_at"], self.now)
        self.assertEqual(row["expires_at"], deadline)
        self.assertEqual(self.renew().status_code, 409)

        self.now += 30
        self.assertEqual(self.activate(valid, a_token).json()["expires_at"], deadline)
        self.assertEqual(self.device("connection-status", B, b_token, **envelope).json()["code"],
                         "pair_activation_timeout")
        self.now = deadline - 1
        self.assertEqual(self.device("connection-status", B, b_token, **valid).status_code, 200)
        self.now = deadline
        self.assertEqual(self.device("connection-status", B, b_token, **valid).json()["code"], "pair_expired")
        self.assertEqual(self.login("a").json()["code"], "pair_expired")
        self.assertEqual(self.login("b").json()["code"], "pair_expired")
        self.assertEqual(self.mint(a_token, supports_pair_activation=True).json()["code"], "pair_expired")
        self.assertEqual(self.device("authorize", B, b_token, action="subtitles").json()["code"], "pair_expired")
        row = self.pair_row()
        self.assertEqual(row["expiry_state"], "expired")
        self.assertFalse(row["a"]["online"])
        self.assertFalse(row["b"]["online"])

        self.assertIn(self.renew(side="a").status_code, (400, 422))
        self.assertEqual(self.renew().status_code, 200)
        row = self.pair_row()
        self.assertEqual(row["expiry_state"], "pending")
        self.assertIsNone(row["activated_at"])
        self.assertIsNone(row["expires_at"])
        self.assertEqual(self.device("authorize", B, b_token, action="subtitles").status_code, 401)
        a2 = self.login("a").json()["access_token"]
        b2 = self.login("b").json()["access_token"]
        self.assertEqual(self.activate(valid, a2).status_code, 403)
        next_ticket = self.ticket_envelope(a2)
        self.assertEqual(self.device("consume-ticket", B, b2, **next_ticket).status_code, 200)
        self.assertEqual(self.activate(next_ticket, a2).json()["expires_at"], self.now + HOURS_24)

        events = self.client.get("/admin/api/events", params={"pair_id": self.pair["pair_id"]}).json()["items"]
        self.assertEqual(sum(item["event"] == "activate_pair" for item in events), 2)
        self.assertTrue(any(item["event"] == "renew" and item["actor"] == ADMIN["username"] for item in events))


if __name__ == "__main__":
    unittest.main()
