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
            "body": "task finished",
            "source": "pi-extension",
            "agent": "pi",
            "app": app_name,
            "orca_terminal_handle": "session-123",
        },
    )


def stub_apns(monkeypatch, sent=None):
    async def fake_send(*args):
        if sent is not None:
            sent.append(args)
        return None

    monkeypatch.setattr(main, "send_apns", fake_send)


def test_migrates_existing_database(monkeypatch, tmp_path):
    db_path = tmp_path / "old.db"
    legacy_row = {
        "id": "legacy-1",
        "device_token": "legacy-secret",
        "title": "old title",
        "body": "old body",
        "status": "replied",
        "context": "old context",
        "logs": "old logs",
        "reply": "old reply",
        "created_at": "2026-01-01T00:00:00+00:00",
        "updated_at": "2026-01-02T00:00:00+00:00",
    }
    conn = sqlite3.connect(db_path)
    conn.execute(
        "CREATE TABLE tasks (id TEXT PRIMARY KEY, device_token TEXT NOT NULL, title TEXT, body TEXT, "
        "status TEXT, context TEXT, logs TEXT, reply TEXT, created_at TEXT, updated_at TEXT)"
    )
    conn.execute("CREATE TABLE device_tokens (token TEXT PRIMARY KEY, created_at TEXT, updated_at TEXT)")
    conn.execute(
        "INSERT INTO tasks (id, device_token, title, body, status, context, logs, reply, created_at, updated_at) "
        "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
        tuple(legacy_row.values()),
    )
    conn.commit()
    conn.close()

    monkeypatch.setattr(main, "DB_PATH", str(db_path))
    monkeypatch.setattr(main, "API_KEY", "test-key")
    main.init_db()
    stub_apns(monkeypatch, sent=[])

    with TestClient(main.app) as client:
        register(client, "new-token", "all")
        created = push(client, "new-token")
        assert created.status_code == 200
        assert created.json()["push_enqueued"] is True

        legacy_task = client.get("/task/legacy-1", headers=AUTH).json()["task"]
        history = client.get("/tasks", headers=AUTH).json()["tasks"]

    for row in [legacy_task] + history:
        assert "status" not in row
        assert "reply" not in row
        assert "device_token" not in row
    assert legacy_task["id"] == "legacy-1"
    assert "legacy-secret" not in json.dumps(legacy_task)
    assert "legacy-secret" not in json.dumps(history)

    conn = sqlite3.connect(db_path)
    conn.row_factory = sqlite3.Row
    stored = conn.execute("SELECT * FROM tasks WHERE id = 'legacy-1'").fetchone()
    new_task = conn.execute("SELECT * FROM tasks WHERE id = ?", (created.json()["task_id"],)).fetchone()
    task_columns = {row[1] for row in conn.execute("PRAGMA table_info(tasks)")}
    token_columns = {row[1] for row in conn.execute("PRAGMA table_info(device_tokens)")}
    conn.close()

    # Additive migration keeps legacy columns and values untouched, even after GET requests.
    assert {key: stored[key] for key in legacy_row} == legacy_row
    assert stored["push_status"] is None
    assert {"source", "agent", "app", "orca_terminal_handle", "orca_worktree_id", "orca_tab_id", "orca_pane_key"} <= task_columns
    assert {"push_status", "push_attempted_at", "push_environment", "apns_status_code", "apns_reason", "apns_id"} <= task_columns
    assert "preferences" in token_columns
    # New pushes work on the migrated database without touching legacy columns.
    assert new_task["status"] is None
    assert new_task["reply"] is None


def test_repeated_initialization_keeps_fresh_schema_without_legacy_columns(monkeypatch, tmp_path):
    db_path = tmp_path / "fresh.db"
    monkeypatch.setattr(main, "DB_PATH", str(db_path))
    main.init_db()
    main.init_db()

    conn = sqlite3.connect(db_path)
    task_columns = [row[1] for row in conn.execute("PRAGMA table_info(tasks)")]
    conn.close()

    assert task_columns == [
        "id",
        "device_token",
        "title",
        "body",
        "context",
        "logs",
        "source",
        "agent",
        "app",
        "orca_terminal_handle",
        "orca_worktree_id",
        "orca_tab_id",
        "orca_pane_key",
        "push_status",
        "push_attempted_at",
        "push_environment",
        "apns_status_code",
        "apns_reason",
        "apns_id",
        "created_at",
        "updated_at",
    ]


def test_openapi_exposes_exact_operation_set():
    operations = {
        f"{method.upper()} {path}"
        for path, methods in main.app.openapi()["paths"].items()
        for method in methods
    }
    assert operations == {
        "POST /push",
        "GET /task/{task_id}",
        "GET /tasks",
        "GET /health",
        "POST /diagnostics/push-test",
        "GET /diagnostics/push/{task_id}",
        "POST /register-device",
    }


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
    stub_apns(monkeypatch, sent)
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


def test_push_enqueues_remote_deep_link_identifiers(monkeypatch, tmp_path):
    sent = []
    stub_apns(monkeypatch, sent)
    with make_client(monkeypatch, tmp_path) as client:
        register(client, "token", "tax")
        response = client.post(
            "/push",
            headers=AUTH,
            json={
                "device_token": "token",
                "title": "done",
                "body": "open terminal",
                "app": "tax",
                "host_id": "mac-custom",
                "orca_worktree_id": "workspace-1",
                "orca_terminal_handle": "terminal-1",
            },
        )
        assert response.status_code == 200

    assert sent[0][-3:] == ("mac-custom", "workspace-1", "terminal-1")


def test_push_falls_back_to_registered_device_token(monkeypatch, tmp_path):
    sent = []
    stub_apns(monkeypatch, sent)
    with make_client(monkeypatch, tmp_path) as client:
        register(client, "registered-token", "all")
        created = client.post(
            "/push",
            headers=AUTH,
            json={"title": "done", "body": "task finished", "source": "tax-cli", "agent": "tax", "app": "tax"},
        ).json()

        conn = main.db_conn()
        try:
            stored_token = conn.execute(
                "SELECT device_token FROM tasks WHERE id = ?", (created["task_id"],)
            ).fetchone()["device_token"]
        finally:
            conn.close()

    assert created["push_enqueued"] is True
    assert stored_token == "registered-token"
    assert len(sent) == 1


def test_push_without_registered_device_is_stored_and_skipped(monkeypatch, tmp_path):
    sent = []
    stub_apns(monkeypatch, sent)
    with make_client(monkeypatch, tmp_path) as client:
        created = client.post("/push", headers=AUTH, json={"title": "done", "body": "task finished"}).json()

    assert created["push_enqueued"] is False
    assert created["push_skip_reason"] == "device_token_missing"
    assert sent == []


def test_push_stores_push_metadata(monkeypatch, tmp_path):
    stub_apns(monkeypatch)
    with make_client(monkeypatch, tmp_path) as client:
        register(client, "token", "tax")
        created = push(client, "token").json()

        task = client.get(f"/task/{created['task_id']}", headers=AUTH).json()["task"]

    assert task["id"] == created["task_id"]
    assert task["title"] == "done"
    assert task["body"] == "task finished"
    assert task["source"] == "pi-extension"
    assert task["agent"] == "pi"
    assert task["app"] == "tax"
    assert task["orca_terminal_handle"] == "session-123"


def test_history_is_read_only_public_projection(monkeypatch, tmp_path):
    stub_apns(monkeypatch)
    with make_client(monkeypatch, tmp_path) as client:
        register(client, "secret-device-token", "all")
        created = push(client, "secret-device-token").json()

        task = client.get(f"/task/{created['task_id']}", headers=AUTH).json()["task"]
        tasks = client.get("/tasks", headers=AUTH).json()["tasks"]

        conn = main.db_conn()
        try:
            stored = conn.execute(
                "SELECT created_at, updated_at FROM tasks WHERE id = ?", (created["task_id"],)
            ).fetchone()
        finally:
            conn.close()

    expected_keys = {
        "id",
        "title",
        "body",
        "context",
        "logs",
        "source",
        "agent",
        "app",
        "orca_terminal_handle",
        "orca_worktree_id",
        "orca_tab_id",
        "orca_pane_key",
        "push_status",
        "push_attempted_at",
        "push_environment",
        "apns_status_code",
        "apns_reason",
        "apns_id",
        "created_at",
        "updated_at",
    }
    assert set(task) == expected_keys
    assert all(set(row) == expected_keys for row in tasks)
    assert "secret-device-token" not in json.dumps({"task": task, "tasks": tasks})
    # GET requests never modify stored rows.
    assert stored["created_at"] == task["created_at"]
    assert stored["updated_at"] == task["updated_at"]


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


def test_task_list_orders_by_created_at_desc(monkeypatch, tmp_path):
    stub_apns(monkeypatch)
    with make_client(monkeypatch, tmp_path) as client:
        first_id = push(client, "").json()["task_id"]
        second_id = push(client, "").json()["task_id"]
        third_id = push(client, "").json()["task_id"]
        conn = main.db_conn()
        conn.execute("UPDATE tasks SET created_at = ? WHERE id = ?", ("2099-01-01T00:00:00+00:00", first_id))
        conn.execute("UPDATE tasks SET created_at = ? WHERE id = ?", ("2099-03-01T00:00:00+00:00", second_id))
        conn.execute("UPDATE tasks SET created_at = ? WHERE id = ?", ("2099-02-01T00:00:00+00:00", third_id))
        conn.commit()
        conn.close()

        tasks = client.get("/tasks", headers=AUTH).json()["tasks"]

    assert [task["id"] for task in tasks[:3]] == [second_id, third_id, first_id]


def test_auth_and_query_validation(monkeypatch, tmp_path):
    with make_client(monkeypatch, tmp_path) as client:
        assert client.get("/tasks").status_code in {401, 403}
        assert client.get("/tasks", headers={"Authorization": "Bearer wrong"}).status_code == 401
        assert client.get("/tasks?limit=0", headers=AUTH).status_code == 422
        assert client.get("/tasks?limit=501", headers=AUTH).status_code == 422
        assert client.get("/tasks?offset=-1", headers=AUTH).status_code == 422


def test_unknown_task_returns_404(monkeypatch, tmp_path):
    with make_client(monkeypatch, tmp_path) as client:
        assert client.get("/task/missing", headers=AUTH).status_code == 404


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
        asyncio.run(
            main.send_apns(
                "device-secret", "title", "body", "task-1", "tax", "pi-extension", "pi", "mac", "workspace", "terminal"
            )
        )

    assert calls[0][0] == "https://api.development.push.apple.com/3/device/device-secret"
    assert calls[0][1]["headers"]["apns-topic"] == "bundle-id"
    assert calls[0][1]["json"]["aps"]["category"] == "REMOTE_WORKSPACE"
    assert "task_id" not in calls[0][1]["json"]
    assert calls[0][1]["json"]["host_id"] == "mac"
    assert calls[0][1]["json"]["workspace_id"] == "workspace"
    assert calls[0][1]["json"]["terminal_id"] == "terminal"
    assert "Unregistered" in caplog.text
    assert "device-secret" not in caplog.text
    assert "provider-token" not in caplog.text
