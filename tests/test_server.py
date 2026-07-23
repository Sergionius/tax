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
            "agterm_session_id": "session-123",
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
    assert {"source", "agent", "app", "agterm_session_id"} <= task_columns
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
        assert task["agterm_session_id"] == "session-123"

        response = client.post(f"/task/{task_id}/reply", headers=AUTH, json={"text": "continue"})
        assert response.status_code == 200
        reply = client.get(f"/task/{task_id}/reply", headers=AUTH).json()
        assert reply == {"ok": True, "reply": "continue"}

        pending_replies = client.get("/replies", headers=AUTH).json()["tasks"]
        assert pending_replies == [
            {
                "id": task_id,
                "reply": "continue",
                "agterm_session_id": "session-123",
                "source": "pi-extension",
                "agent": "pi",
                "app": "tax",
                "updated_at": pending_replies[0]["updated_at"],
            }
        ]

        delivered = client.post(f"/task/{task_id}/update", headers=AUTH, json={"status": "delivered"})
        assert delivered.json()["ok"] is True
        assert client.get("/replies", headers=AUTH).json()["tasks"] == []


def test_rejects_unknown_push_mode(monkeypatch, tmp_path):
    with make_client(monkeypatch, tmp_path) as client:
        response = client.post(
            "/register-device",
            headers=AUTH,
            json={"device_token": "token", "preferences": {"push_mode": "unknown"}},
        )
    assert response.status_code == 422
