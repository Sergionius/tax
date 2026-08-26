import asyncio
import json
import sqlite3
from pathlib import Path

from fastapi.testclient import TestClient

from server import main


AUTH = {"Authorization": "Bearer test-key"}


def make_client(monkeypatch, tmp_path: Path) -> TestClient:
    monkeypatch.setattr(main, "DB_PATH", str(tmp_path / "tax.db"))
    monkeypatch.setattr(main, "API_KEY", "test-key")
    return TestClient(main.app)


def register(client: TestClient, token: str, mode: str):
    response = client.post(
        "/register-device",
        headers=AUTH,
        json={"device_token": token, "preferences": {"push_mode": mode}},
    )
    assert response.status_code == 200
    return response


def push(client: TestClient, token: str, app_name: str = "tax"):
    return client.post(
        "/push",
        headers=AUTH,
        json={
            "device_token": token,
            "title": "done",
            "body": "reply requested",
            "source": "pi-extension",
            "agent": "pi",
            "app": app_name,
            "orca_terminal_handle": "session-123",
        },
    )


def test_migrates_existing_database(monkeypatch, tmp_path):
    db_path = tmp_path / "old.db"
    conn = sqlite3.connect(db_path)
    conn.execute(
        "CREATE TABLE tasks (id TEXT PRIMARY KEY, device_token TEXT NOT NULL, title TEXT, body TEXT, "
        "status TEXT, context TEXT, logs TEXT, reply TEXT, created_at TEXT, updated_at TEXT)"
    )
    conn.execute("CREATE TABLE device_tokens (token TEXT PRIMARY KEY, created_at TEXT, updated_at TEXT)")
    conn.commit()
    conn.close()

    monkeypatch.setattr(main, "DB_PATH", str(db_path))
    main.init_db()

    conn = sqlite3.connect(db_path)
    task_columns = {row[1] for row in conn.execute("PRAGMA table_info(tasks)")}
    token_columns = {row[1] for row in conn.execute("PRAGMA table_info(device_tokens)")}
    conn.close()
    assert {
        "source",
        "agent",
        "app",
        "orca_terminal_handle",
        "orca_worktree_id",
        "orca_tab_id",
        "orca_pane_key",
    } <= task_columns
    assert "preferences" in token_columns


def test_register_device_stores_preferences(monkeypatch, tmp_path):
    with make_client(monkeypatch, tmp_path) as client:
        response = register(client, "token-1", "tax")
        assert response.json()["preferences"] == {"push_mode": "tax"}

    conn = sqlite3.connect(tmp_path / "tax.db")
    stored = conn.execute("SELECT preferences FROM device_tokens WHERE token = 'token-1'").fetchone()[0]
    conn.close()
    assert json.loads(stored) == {"push_mode": "tax"}


def test_push_modes_filter_apns_but_always_store_tasks(monkeypatch, tmp_path):
    sent = []

    async def fake_send(*args):
        sent.append(args)

    monkeypatch.setattr(main, "send_apns", fake_send)
    with make_client(monkeypatch, tmp_path) as client:
        register(client, "all-token", "all")
        assert push(client, "all-token", "other").json()["push_enqueued"] is True

        register(client, "tax-token", "tax")
        filtered = push(client, "tax-token", "other").json()
        assert filtered["push_enqueued"] is False
        assert filtered["push_skip_reason"] == "app_filtered"
        assert push(client, "tax-token", "tax").json()["push_enqueued"] is True

        register(client, "off-token", "off")
        disabled = push(client, "off-token", "tax").json()
        assert disabled["push_enqueued"] is False
        assert disabled["push_skip_reason"] == "push_mode_off"

        tasks = client.get("/tasks", headers=AUTH).json()["tasks"]

    assert len(sent) == 2
    assert len(tasks) == 4


def test_push_stores_metadata_and_reply_flow(monkeypatch, tmp_path):
    async def fake_send(*_args):
        return None

    monkeypatch.setattr(main, "send_apns", fake_send)
    with make_client(monkeypatch, tmp_path) as client:
        register(client, "token", "tax")
        created = push(client, "token").json()
        task_id = created["task_id"]

        task = client.get(f"/task/{task_id}", headers=AUTH).json()["task"]
        assert task["source"] == "pi-extension"
        assert task["agent"] == "pi"
        assert task["app"] == "tax"
        assert task["orca_terminal_handle"] == "session-123"

        response = client.post(f"/task/{task_id}/reply", headers=AUTH, json={"text": "continue"})
        assert response.status_code == 200
        reply = client.get(f"/task/{task_id}/reply", headers=AUTH).json()
        assert reply == {"ok": True, "reply": "continue"}

        pending_replies = client.get("/replies", headers=AUTH).json()["tasks"]
        assert pending_replies == [
            {
                "id": task_id,
                "reply": "continue",
                "orca_terminal_handle": "session-123",
                "orca_worktree_id": "",
                "orca_tab_id": "",
                "orca_pane_key": "",
                "source": "pi-extension",
                "agent": "pi",
                "app": "tax",
                "updated_at": pending_replies[0]["updated_at"],
            }
        ]

        delivered = client.post(f"/task/{task_id}/update", headers=AUTH, json={"status": "delivered"})
        assert delivered.json()["ok"] is True
        assert client.get("/replies", headers=AUTH).json()["tasks"] == []


def test_push_diagnostic_records_apns_result_without_exposing_token(monkeypatch, tmp_path):
    async def fake_apns_send(*_args, **_kwargs):
        return main.apns.APNSResult(
            status="sent",
            environment="production",
            status_code=200,
            apns_id="diagnostic-apns-id",
        )

    monkeypatch.setattr(main.apns, "send", fake_apns_send)
    monkeypatch.setattr(main, "APNS_USE_SANDBOX", False)
    with make_client(monkeypatch, tmp_path) as client:
        register(client, "secret-device-token", "all")
        created = client.post("/diagnostics/push-test", headers=AUTH)
        assert created.status_code == 200
        payload = created.json()
        assert payload["device_registered"] is True
        assert payload["environment"] == "production"

        diagnostic = client.get(f"/diagnostics/push/{payload['task_id']}", headers=AUTH).json()["diagnostic"]

    assert diagnostic["push_status"] == "sent"
    assert diagnostic["apns_status_code"] == 200
    assert diagnostic["apns_id"] == "diagnostic-apns-id"
    assert diagnostic["device_registered"] is True
    assert "device_token" not in diagnostic
    assert "secret-device-token" not in json.dumps(diagnostic)


def test_rejects_unknown_push_mode(monkeypatch, tmp_path):
    with make_client(monkeypatch, tmp_path) as client:
        response = client.post(
            "/register-device",
            headers=AUTH,
            json={"device_token": "token", "preferences": {"push_mode": "unknown"}},
        )
    assert response.status_code == 422


def test_auth_and_query_validation(monkeypatch, tmp_path):
    with make_client(monkeypatch, tmp_path) as client:
        assert client.get("/tasks").status_code in {401, 403}
        assert client.get("/tasks", headers={"Authorization": "Bearer wrong"}).status_code == 401
        assert client.get("/tasks?limit=0", headers=AUTH).status_code == 422
        assert client.get("/tasks?limit=501", headers=AUTH).status_code == 422
        assert client.get("/tasks?offset=-1", headers=AUTH).status_code == 422


def test_unknown_tasks_and_reply_validation(monkeypatch, tmp_path):
    with make_client(monkeypatch, tmp_path) as client:
        assert client.get("/task/missing", headers=AUTH).status_code == 404
        assert client.post("/task/missing/update", headers=AUTH, json={"status": "delivered"}).status_code == 404
        assert client.post("/task/missing/reply", headers=AUTH, json={"text": "continue"}).status_code == 404
        assert client.post("/task/missing/reply", headers=AUTH, json={"text": ""}).status_code == 422
        assert client.post("/task/missing/reply", headers=AUTH, json={"text": "x" * 20_001}).status_code == 422


def test_reply_is_rejected_after_task_expires(monkeypatch, tmp_path):
    async def fake_send(*_args):
        return None

    monkeypatch.setattr(main, "send_apns", fake_send)
    with make_client(monkeypatch, tmp_path) as client:
        task_id = push(client, "").json()["task_id"]
        conn = main.db_conn()
        conn.execute("UPDATE tasks SET created_at = ? WHERE id = ?", ("2000-01-01T00:00:00+00:00", task_id))
        conn.commit()
        conn.close()

        response = client.post(f"/task/{task_id}/reply", headers=AUTH, json={"text": "too late"})
        task = client.get(f"/task/{task_id}", headers=AUTH).json()["task"]

    assert response.status_code == 409
    assert response.json()["detail"] == "task expired"
    assert task["status"] == "expired"
    assert task["reply"] is None


def test_undelivered_reply_expires_after_ttl(monkeypatch, tmp_path):
    async def fake_send(*_args):
        return None

    monkeypatch.setattr(main, "send_apns", fake_send)
    with make_client(monkeypatch, tmp_path) as client:
        task_id = push(client, "").json()["task_id"]
        assert client.post(f"/task/{task_id}/reply", headers=AUTH, json={"text": "continue"}).status_code == 200
        conn = main.db_conn()
        conn.execute("UPDATE tasks SET updated_at = ? WHERE id = ?", ("2000-01-01T00:00:00+00:00", task_id))
        conn.commit()
        conn.close()

        assert client.get("/replies", headers=AUTH).json()["tasks"] == []
        task = client.get(f"/task/{task_id}", headers=AUTH).json()["task"]

    assert task["status"] == "expired"


def test_reply_is_first_writer_wins(monkeypatch, tmp_path):
    async def fake_send(*_args):
        return None

    monkeypatch.setattr(main, "send_apns", fake_send)
    with make_client(monkeypatch, tmp_path) as client:
        task_id = push(client, "").json()["task_id"]
        first = client.post(f"/task/{task_id}/reply", headers=AUTH, json={"text": "first"})
        second = client.post(f"/task/{task_id}/reply", headers=AUTH, json={"text": "second"})
        task = client.get(f"/task/{task_id}", headers=AUTH).json()["task"]

    assert first.status_code == 200
    assert second.status_code == 409
    assert task["reply"] == "first"


def test_health_checks_database(monkeypatch, tmp_path):
    with make_client(monkeypatch, tmp_path) as client:
        assert client.get("/health", headers=AUTH).json() == {"ok": True, "database": "ok"}


def test_apns_uses_sandbox_host_and_reports_reason(monkeypatch, tmp_path, caplog):
    key_path = tmp_path / "AuthKey.p8"
    key_path.write_text("fake-key")
    monkeypatch.setattr(main, "APNS_KEY_PATH", str(key_path))
    monkeypatch.setattr(main, "APNS_KEY_ID", "key-id")
    monkeypatch.setattr(main, "APNS_TEAM_ID", "team-id")
    monkeypatch.setattr(main, "APNS_BUNDLE_ID", "bundle-id")
    monkeypatch.setattr(main, "APNS_USE_SANDBOX", True)
    monkeypatch.setattr(main.apns.jwt, "encode", lambda *_args, **_kwargs: "provider-token")
    calls = []

    class Response:
        status_code = 410
        headers = {"apns-id": "apns-request-id"}

        @staticmethod
        def json():
            return {"reason": "Unregistered"}

    class Client:
        async def __aenter__(self):
            return self

        async def __aexit__(self, *_args):
            return None

        async def post(self, url, **kwargs):
            calls.append((url, kwargs))
            return Response()

    monkeypatch.setattr(main.apns.httpx, "AsyncClient", lambda **_kwargs: Client())
    with caplog.at_level("WARNING"):
        asyncio.run(main.send_apns("device-secret", "title", "body", "task-1"))

    assert calls[0][0] == "https://api.development.push.apple.com/3/device/device-secret"
    assert calls[0][1]["headers"]["apns-topic"] == "bundle-id"
    assert "Unregistered" in caplog.text
    assert "device-secret" not in caplog.text
    assert "provider-token" not in caplog.text
