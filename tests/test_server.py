import asyncio
import json
import sqlite3
import time
from datetime import datetime, timedelta, timezone
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from server import main, storage


AUTH = {"Authorization": "Bearer test-key"}


def recent_iso(days_ago: float = 1.0) -> str:
    """Timestamp recent enough to survive the default retention window."""
    return (datetime.now(timezone.utc) - timedelta(days=days_ago)).isoformat()


def make_client(monkeypatch, tmp_path: Path, env: dict[str, str] | None = None) -> TestClient:
    # Pin the default storage policy unless a test explicitly opts in.
    monkeypatch.delenv("TAX_STORE_AGENT_CONTENT", raising=False)
    monkeypatch.delenv("TAX_TASK_RETENTION_DAYS", raising=False)
    monkeypatch.setattr(main, "DB_PATH", str(tmp_path / "tax.db"))
    monkeypatch.setattr(main, "API_KEY", "test-key")
    for key, value in (env or {}).items():
        monkeypatch.setenv(key, value)
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
    # Recent timestamps: retention cleanup must keep the legacy row so the
    # additive-migration path stays observable.
    legacy_timestamp = recent_iso()
    legacy_row = {
        "id": "legacy-1",
        "device_token": "legacy-secret",
        "title": "old title",
        "body": "old body",
        "status": "replied",
        "context": "old context",
        "logs": "old logs",
        "reply": "old reply",
        "created_at": legacy_timestamp,
        "updated_at": legacy_timestamp,
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
    # Coordinated startup cleanup: content storage is off by default, so the
    # legacy context/logs are purged while every other legacy value survives.
    assert {key: stored[key] for key in legacy_row} == {**legacy_row, "context": "", "logs": ""}
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


def insert_task(db_path: Path, **overrides) -> None:
    """Seed one task row with content and a retention-safe recent timestamp."""
    values = {
        "id": "seed-1",
        "device_token": "seed-device-token",
        "title": "seed title",
        "body": "seed body",
        "context": "seed context",
        "logs": "seed logs",
        "source": "seed-source",
        "agent": "seed-agent",
        "app": "tax",
        "orca_terminal_handle": "seed-terminal",
        "orca_worktree_id": "",
        "orca_tab_id": "",
        "orca_pane_key": "",
        "push_status": "skipped",
        "push_environment": "production",
        "apns_reason": "device_token_missing",
        "created_at": recent_iso(),
        "updated_at": recent_iso(),
    }
    values.update(overrides)
    conn = sqlite3.connect(db_path)
    try:
        columns = ", ".join(values)
        placeholders = ", ".join(f":{key}" for key in values)
        conn.execute(f"INSERT INTO tasks ({columns}) VALUES ({placeholders})", values)
        conn.commit()
    finally:
        conn.close()


def table_columns(db_path: Path, table: str) -> list[str]:
    conn = sqlite3.connect(db_path)
    try:
        return [row[1] for row in conn.execute(f"PRAGMA table_info({table})")]
    finally:
        conn.close()


def stored_task(db_path: Path, task_id: str) -> sqlite3.Row:
    conn = sqlite3.connect(db_path)
    conn.row_factory = sqlite3.Row
    try:
        return conn.execute("SELECT * FROM tasks WHERE id = ?", (task_id,)).fetchone()
    finally:
        conn.close()


def test_agent_content_flag_requires_exact_opt_in_value(monkeypatch):
    for value in ["", "0", "false", "true", "yes", "on", " 1", "1 "]:
        monkeypatch.setenv("TAX_STORE_AGENT_CONTENT", value)
        assert main.agent_content_storage_enabled() is False
    monkeypatch.setenv("TAX_STORE_AGENT_CONTENT", "1")
    assert main.agent_content_storage_enabled() is True
    monkeypatch.delenv("TAX_STORE_AGENT_CONTENT")
    assert main.agent_content_storage_enabled() is False


def test_resolve_content_settings_defaults_and_opt_in(monkeypatch):
    monkeypatch.delenv("TAX_STORE_AGENT_CONTENT", raising=False)
    monkeypatch.delenv("TAX_TASK_RETENTION_DAYS", raising=False)
    assert main.resolve_content_settings() == (False, main.DEFAULT_TASK_RETENTION_DAYS)
    assert main.TASK_RETENTION_INTERVAL_SECONDS == 3600
    monkeypatch.setenv("TAX_STORE_AGENT_CONTENT", "1")
    monkeypatch.setenv("TAX_TASK_RETENTION_DAYS", "14")
    assert main.resolve_content_settings() == (True, 14)


def test_content_storage_default_off_stores_empty_strings(monkeypatch, tmp_path):
    stub_apns(monkeypatch)
    with make_client(monkeypatch, tmp_path) as client:
        register(client, "token", "all")
        created = client.post(
            "/push",
            headers=AUTH,
            json={
                "device_token": "token",
                "title": "done",
                "body": "task finished",
                "context": "secret context",
                "logs": "secret logs",
                "source": "pi-extension",
                "agent": "pi",
                "app": "tax",
                "orca_terminal_handle": "session-123",
            },
        ).json()
        task = client.get(f"/task/{created['task_id']}", headers=AUTH).json()["task"]

    # API response shape is unchanged: context/logs keys stay present.
    assert task["context"] == ""
    assert task["logs"] == ""
    assert task["title"] == "done"
    assert task["body"] == "task finished"
    assert task["source"] == "pi-extension"
    assert task["agent"] == "pi"
    assert task["app"] == "tax"
    assert task["orca_terminal_handle"] == "session-123"
    stored = stored_task(tmp_path / "tax.db", created["task_id"])
    assert stored["context"] == ""
    assert stored["logs"] == ""
    assert stored["push_status"] == "queued"


def test_content_storage_opt_in_stores_context_and_logs(monkeypatch, tmp_path):
    stub_apns(monkeypatch)
    with make_client(monkeypatch, tmp_path, env={"TAX_STORE_AGENT_CONTENT": "1"}) as client:
        register(client, "token", "all")
        created = client.post(
            "/push",
            headers=AUTH,
            json={
                "device_token": "token",
                "title": "done",
                "body": "task finished",
                "context": "kept context",
                "logs": "kept logs",
                "app": "tax",
            },
        ).json()
        task = client.get(f"/task/{created['task_id']}", headers=AUTH).json()["task"]

    assert task["context"] == "kept context"
    assert task["logs"] == "kept logs"
    stored = stored_task(tmp_path / "tax.db", created["task_id"])
    assert stored["context"] == "kept context"
    assert stored["logs"] == "kept logs"


def test_startup_clears_existing_content_when_storage_disabled(monkeypatch, tmp_path):
    db_path = tmp_path / "tax.db"
    monkeypatch.setattr(main, "DB_PATH", str(db_path))
    monkeypatch.setattr(main, "API_KEY", "test-key")
    main.init_db()
    insert_task(db_path, id="old-1")
    insert_task(db_path, id="old-2", logs="", context="only-context")

    with TestClient(main.app):
        pass

    conn = sqlite3.connect(db_path)
    try:
        rows = conn.execute("SELECT id, context, logs FROM tasks ORDER BY id").fetchall()
    finally:
        conn.close()
    assert rows == [("old-1", "", ""), ("old-2", "", "")]


def test_startup_with_opt_in_preserves_existing_content(monkeypatch, tmp_path):
    db_path = tmp_path / "tax.db"
    monkeypatch.setattr(main, "DB_PATH", str(db_path))
    monkeypatch.setattr(main, "API_KEY", "test-key")
    monkeypatch.setenv("TAX_STORE_AGENT_CONTENT", "1")
    main.init_db()
    insert_task(db_path, id="kept-1")
    insert_task(db_path, id="kept-2", context="", logs="")

    with TestClient(main.app):
        pass

    conn = sqlite3.connect(db_path)
    try:
        rows = conn.execute("SELECT id, context, logs FROM tasks ORDER BY id").fetchall()
    finally:
        conn.close()
    assert rows == [("kept-1", "seed context", "seed logs"), ("kept-2", "", "")]


def test_retention_deletes_expired_tasks_and_keeps_devices(monkeypatch, tmp_path):
    sent = []
    stub_apns(monkeypatch, sent)
    now = datetime.now(timezone.utc)
    db_path = tmp_path / "tax.db"
    client = make_client(monkeypatch, tmp_path, env={"TAX_TASK_RETENTION_DAYS": "3"})
    main.init_db()
    insert_task(db_path, id="expired", created_at=(now - timedelta(days=4)).isoformat(), updated_at=recent_iso())
    insert_task(db_path, id="recent", created_at=(now - timedelta(days=2)).isoformat(), updated_at=recent_iso())
    columns_before = table_columns(db_path, "tasks")

    with client as active:
        register(active, "device-token", "all")
        created = push(active, "device-token").json()
        tasks = active.get("/tasks", headers=AUTH).json()["tasks"]

    assert {task["id"] for task in tasks} == {"recent", created["task_id"]}
    # App-generated timestamps stay UTC-aware.
    assert tasks[0]["created_at"].endswith("+00:00")
    assert len(sent) == 1

    conn = sqlite3.connect(db_path)
    try:
        tokens = conn.execute("SELECT token FROM device_tokens").fetchall()
    finally:
        conn.close()
    assert tokens == [("device-token",)]
    # Retention deletes rows only; the physical schema is unchanged.
    assert table_columns(db_path, "tasks") == columns_before


def test_retention_boundary_is_strict_and_uses_utc(tmp_path):
    db_path = tmp_path / "boundary.db"
    storage.initialize(db_path)

    def seed(task_id: str, created_at: str):
        insert_task(db_path, id=task_id, created_at=created_at, updated_at=created_at)

    # Retention window: created_at strictly older than 2026-09-06 12:00 UTC.
    seed("utc-expired", "2026-09-05T00:00:00+00:00")
    seed("offset-expired", "2026-09-06T16:30:00+05:00")  # 11:00 UTC
    seed("utc-boundary", "2026-09-06T12:00:00+00:00")  # == cutoff, kept
    seed("offset-boundary", "2026-09-06T18:00:00+05:00")  # 13:00 UTC, kept
    seed("naive-old", "2026-01-01T00:00:00")  # naive treated as UTC

    now = datetime(2026, 9, 13, 12, 0, tzinfo=timezone.utc)
    result = storage.run_startup_cleanup(db_path, store_agent_content=True, retention_days=7, now=now)

    conn = sqlite3.connect(db_path)
    try:
        remaining = {row[0] for row in conn.execute("SELECT id FROM tasks")}
    finally:
        conn.close()
    assert result["deleted_tasks"] == 3
    assert remaining == {"utc-boundary", "offset-boundary"}


@pytest.mark.parametrize("value", ["abc", "0", "-3", "2.5", "7 days", "1e1"])
def test_invalid_retention_days_rejected_at_startup(monkeypatch, tmp_path, value):
    make_client(monkeypatch, tmp_path, env={"TAX_TASK_RETENTION_DAYS": value})
    with pytest.raises(ValueError):
        with TestClient(main.app):
            pass


def test_retention_task_cancels_on_shutdown(monkeypatch, tmp_path):
    with make_client(monkeypatch, tmp_path):
        task = main.app.state.retention_task
        assert not task.done()
    assert task.done()
    assert task.cancelled()


def test_periodic_retention_survives_errors_without_logging_content(monkeypatch, tmp_path, caplog):
    monkeypatch.setattr(main, "TASK_RETENTION_INTERVAL_SECONDS", 0.01)
    calls = []

    def flaky_cleanup(path, *, retention_days, now=None):
        calls.append((path, retention_days))
        if len(calls) == 1:
            raise sqlite3.OperationalError("simulated transient failure")
        return 0

    monkeypatch.setattr(main.storage, "run_retention_cleanup", flaky_cleanup)
    with caplog.at_level("ERROR"):
        with make_client(monkeypatch, tmp_path):
            deadline = time.monotonic() + 5
            while len(calls) < 2 and time.monotonic() < deadline:
                time.sleep(0.01)

    assert calls == [(str(tmp_path / "tax.db"), 7), (str(tmp_path / "tax.db"), 7)]
    assert "simulated transient failure" in caplog.text
    assert "seed context" not in caplog.text
    assert "seed logs" not in caplog.text


def test_content_storage_off_does_not_change_apns_delivery(monkeypatch, tmp_path):
    sent = []
    stub_apns(monkeypatch, sent)
    with make_client(monkeypatch, tmp_path) as client:
        register(client, "token", "all")
        client.post(
            "/push",
            headers=AUTH,
            json={
                "device_token": "token",
                "title": "done",
                "body": "task finished",
                "context": "transmitted context",
                "logs": "transmitted logs",
                "app": "tax",
            },
        )

    # Storage is off, but push transmission keeps the full alert payload.
    assert len(sent) == 1
    assert sent[0][1:3] == ("done", "task finished")
