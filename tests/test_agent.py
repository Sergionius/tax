import json
import subprocess
import threading
from datetime import datetime, timedelta, timezone
from pathlib import Path
from unittest.mock import Mock

from fastapi.testclient import TestClient

from tax.agent import AgentInstanceLock, AgentStore, TaxAgent, WatchedTask, create_app


def make_agent(tmp_path: Path) -> TaxAgent:
    return TaxAgent("https://tax.example", "secret", tmp_path, retry_delay=0.01, status_events=set())


def test_store_closes_every_database_connection(monkeypatch, tmp_path):
    store = AgentStore(tmp_path / "agent.db")
    real_connect = store.connect
    connections = []

    class TrackedConnection:
        def __init__(self):
            self.connection = real_connect()
            self.closed = False
            connections.append(self)

        def __enter__(self):
            self.connection.__enter__()
            return self

        def __exit__(self, *args):
            return self.connection.__exit__(*args)

        def execute(self, *args, **kwargs):
            return self.connection.execute(*args, **kwargs)

        def close(self):
            self.closed = True
            self.connection.close()

    monkeypatch.setattr(store, "connect", TrackedConnection)

    store.init_db()
    assert store.add(WatchedTask(task_id="task-1")) is True
    assert store.get("task-1")["status"] == "pending"
    store.update("task-1", "waiting_reply")
    store.reset()

    assert len(connections) == 6
    assert all(connection.closed for connection in connections)


def test_store_deduplicates_tasks(monkeypatch, tmp_path):
    agent = make_agent(tmp_path)
    watched = []
    monkeypatch.setattr(agent, "watch", watched.append)
    task = WatchedTask(task_id="task-1", agterm_session_id="session-1", app="tax")

    assert agent.register(task) is True
    assert agent.register(task) is False
    assert watched == []
    assert agent.store.get("task-1")["agterm_session_id"] == "session-1"
    agent.stop()


def test_start_preserves_database_and_imports_fallback(monkeypatch, tmp_path):
    agent = make_agent(tmp_path)
    agent.store.add(WatchedTask(task_id="old-db"))
    agent.fallback_path.write_text(json.dumps({"task_id": "old-file"}) + "\n", encoding="utf-8")
    monkeypatch.setattr(agent, "poll_backend_replies", lambda: 0)

    agent.start()

    assert agent.store.get("old-db")["status"] == "pending"
    assert agent.store.get("old-file")["status"] == "pending"
    assert agent.fallback_path.read_bytes() != b""
    assert agent.import_fallback() == 0
    agent.stop()


def test_imports_jsonl_fallback(monkeypatch, tmp_path):
    agent = make_agent(tmp_path)
    monkeypatch.setattr(agent, "watch", lambda _task_id: None)
    agent.fallback_path.write_text(
        json.dumps({"task_id": "task-1", "agterm_session_id": "session-1", "app": "tax"}) + "\n",
        encoding="utf-8",
    )

    assert agent.import_fallback() == 1
    assert agent.import_fallback() == 0
    assert agent.store.get("task-1")["status"] == "pending"
    agent.stop()


def test_fallback_waits_for_complete_line(monkeypatch, tmp_path):
    agent = make_agent(tmp_path)
    watched = []
    monkeypatch.setattr(agent, "watch", watched.append)
    payload = json.dumps({"task_id": "task-partial"})
    agent.fallback_path.write_text(payload, encoding="utf-8")

    assert agent.import_fallback() == 0
    with agent.fallback_path.open("a", encoding="utf-8") as queue:
        queue.write("\n")
    assert agent.import_fallback() == 1
    assert agent.import_fallback() == 0
    assert watched == ["task-partial"]
    agent.stop()


def test_watch_ignores_terminal_tasks(monkeypatch, tmp_path):
    agent = make_agent(tmp_path)
    agent.store.add(WatchedTask(task_id="done"))
    agent.store.update("done", "delivered", reply="already sent")
    submitted = []
    monkeypatch.setattr(agent._executor, "submit", lambda *args: submitted.append(args))

    agent.watch("done")

    assert submitted == []
    agent.stop()


def test_executor_has_bounded_worker_count(tmp_path):
    agent = TaxAgent("https://tax.example", "secret", tmp_path, max_workers=3)
    assert agent._executor._max_workers == 3
    agent.stop()


def test_stop_is_idempotent_across_concurrent_calls(monkeypatch, tmp_path):
    agent = make_agent(tmp_path)
    shutdown = Mock(wraps=agent._executor.shutdown)
    monkeypatch.setattr(agent._executor, "shutdown", shutdown)
    threads = [threading.Thread(target=agent.stop) for _ in range(2)]

    for thread in threads:
        thread.start()
    for thread in threads:
        thread.join()
    agent.stop()

    assert agent.stop_event.is_set()
    shutdown.assert_called_once_with(wait=False, cancel_futures=True)


def test_watch_ignores_tasks_after_stop(monkeypatch, tmp_path):
    agent = make_agent(tmp_path)
    agent.store.add(WatchedTask(task_id="pending"))
    submit = Mock()
    monkeypatch.setattr(agent._executor, "submit", submit)

    agent.stop()
    agent.watch("pending")

    submit.assert_not_called()
    assert agent._watching == set()


def test_import_loop_uses_regular_interval_after_success(monkeypatch, tmp_path):
    agent = make_agent(tmp_path)
    wait = Mock(side_effect=[False, True])
    import_fallback = Mock(return_value=0)
    monkeypatch.setattr(agent.stop_event, "wait", wait)
    monkeypatch.setattr(agent, "import_fallback", import_fallback)

    agent._import_loop()

    assert [item.args[0] for item in wait.call_args_list] == [5.0, 5.0]
    import_fallback.assert_called_once_with()
    agent.stop()


def test_import_loop_retries_after_only_retry_delay(monkeypatch, tmp_path):
    agent = make_agent(tmp_path)
    wait = Mock(side_effect=[False, True])
    import_fallback = Mock(side_effect=RuntimeError("broken import"))
    monkeypatch.setattr(agent.stop_event, "wait", wait)
    monkeypatch.setattr(agent, "import_fallback", import_fallback)

    agent._import_loop()

    assert [item.args[0] for item in wait.call_args_list] == [5.0, agent.retry_delay]
    import_fallback.assert_called_once_with()
    agent.stop()


def test_instance_lock_is_exclusive(tmp_path):
    first = AgentInstanceLock(tmp_path / "agent.lock")
    second = AgentInstanceLock(tmp_path / "agent.lock")

    assert first.acquire() is True
    assert second.acquire() is False
    first.release()
    assert second.acquire() is True
    second.release()


def test_inject_reply_uses_target_stdin_and_newline(monkeypatch, tmp_path):
    agent = make_agent(tmp_path)
    run = Mock()
    monkeypatch.setattr("tax.agent.shutil.which", lambda _name: "/usr/local/bin/agtermctl")
    monkeypatch.setattr("tax.agent.subprocess.run", run)

    agent.inject_reply("continue", "session-123")

    args, kwargs = run.call_args
    assert args[0] == [
        "/usr/local/bin/agtermctl",
        "session",
        "type",
        "--target",
        "session-123",
        "--stdin",
    ]
    assert kwargs["input"] == "continue\n"
    assert kwargs["check"] is True
    agent.stop()


def test_inject_reply_uses_origin_socket(monkeypatch, tmp_path):
    agent = make_agent(tmp_path)
    run = Mock()
    monkeypatch.setattr("tax.agent.shutil.which", lambda _name: "/usr/local/bin/agtermctl")
    monkeypatch.setattr("tax.agent.subprocess.run", run)

    agent.inject_reply("continue", "session-123", "/tmp/agterm.sock")

    assert run.call_args.args[0][-2:] == ["--socket", "/tmp/agterm.sock"]
    agent.stop()


def test_backend_reply_preserves_local_origin_socket(monkeypatch, tmp_path):
    agent = make_agent(tmp_path)
    agent.store.add(WatchedTask(task_id="task-1", agterm_session_id="session-1", agterm_socket="/tmp/a.sock"))
    monkeypatch.setattr(agent, "watch", lambda _task_id: None)

    assert agent._schedule_backend_tasks(
        [{"id": "task-1", "reply": "continue", "agterm_session_id": "session-1"}]
    ) == 1

    assert agent.store.get("task-1")["agterm_socket"] == "/tmp/a.sock"
    agent.stop()


def test_blocked_status_creates_replyable_task_and_deduplicates(monkeypatch, tmp_path):
    agent = TaxAgent(
        "https://tax.example",
        "secret",
        tmp_path,
        status_events={"blocked"},
        agterm_socket="/tmp/agterm.sock",
    )
    response = Mock()
    response.raise_for_status.return_value = None
    response.json.return_value = {"task_id": "status-task"}
    post = Mock(return_value=response)
    monkeypatch.setattr("tax.agent.requests.post", post)
    monkeypatch.setattr(agent, "_session_context", lambda _event: ("Workspace: tax", "pi"))
    event = {
        "kind": "status",
        "session": "session-1",
        "window": "window-1",
        "payload": {"status": "blocked", "name": "pi tax"},
    }

    assert agent.handle_status_event(event) is True
    assert agent.handle_status_event(event) is False
    row = agent.store.get("status-task")
    assert row["agterm_socket"] == "/tmp/agterm.sock"
    assert row["agent"] == "pi"
    assert post.call_args.kwargs["json"]["source"] == "agterm-status"
    agent.stop()


def test_completed_status_is_opt_in(monkeypatch, tmp_path):
    agent = make_agent(tmp_path)
    post = Mock()
    monkeypatch.setattr("tax.agent.requests.post", post)

    assert agent.handle_status_event(
        {"kind": "status", "session": "session-1", "payload": {"status": "completed"}}
    ) is False

    post.assert_not_called()
    agent.stop()


def test_poll_reply_delivers_and_marks_backend(monkeypatch, tmp_path):
    agent = make_agent(tmp_path)
    get_response = Mock()
    get_response.raise_for_status.return_value = None
    get_response.json.return_value = {
        "ok": True,
        "tasks": [
            {
                "id": "task-1",
                "reply": "ship it",
                "agterm_session_id": "session-1",
                "source": "pi-extension",
                "agent": "pi",
                "app": "tax",
            }
        ],
    }
    post_response = Mock()
    post_response.raise_for_status.return_value = None
    post_response.json.return_value = {"ok": True}
    injected = []

    monkeypatch.setattr("tax.agent.requests.get", lambda *args, **kwargs: get_response)
    monkeypatch.setattr("tax.agent.requests.post", lambda *args, **kwargs: post_response)
    monkeypatch.setattr(agent, "inject_reply", lambda reply, target: injected.append((reply, target)))
    monkeypatch.setattr(agent, "watch", agent._watch_task)

    assert agent.poll_backend_replies() == 1

    assert injected == [("ship it", "session-1")]
    row = agent.store.get("task-1")
    assert row["status"] == "delivered"
    assert row["reply"] == "ship it"
    get_response.close.assert_called_once()
    post_response.close.assert_called_once()
    agent.stop()


def test_legacy_backend_fallback_polls_saved_tasks(monkeypatch, tmp_path):
    agent = make_agent(tmp_path)
    agent.store.add(WatchedTask(task_id="task-1", agterm_session_id="session-1"))
    not_found = Mock(status_code=404)
    reply_response = Mock(status_code=200)
    reply_response.raise_for_status.return_value = None
    reply_response.json.return_value = {"ok": True, "reply": "continue"}
    post_response = Mock()
    post_response.raise_for_status.return_value = None
    post_response.json.return_value = {"ok": True}
    responses = iter([not_found, reply_response])
    inject = Mock()
    monkeypatch.setattr("tax.agent.requests.get", lambda *args, **kwargs: next(responses))
    monkeypatch.setattr("tax.agent.requests.post", lambda *args, **kwargs: post_response)
    monkeypatch.setattr(agent, "inject_reply", inject)
    monkeypatch.setattr(agent, "watch", agent._watch_task)

    assert agent.poll_backend_replies() == 1

    assert agent.store.get("task-1")["status"] == "delivered"
    inject.assert_called_once_with("continue", "session-1")
    not_found.close.assert_called_once()
    reply_response.close.assert_called_once()
    agent.stop()


def test_replies_endpoint_is_rechecked_after_legacy_fallback(monkeypatch, tmp_path):
    agent = make_agent(tmp_path)
    agent.store.add(WatchedTask(task_id="legacy-task", agterm_session_id="session-1"))
    not_found = Mock(status_code=404)
    empty_legacy = Mock(status_code=200)
    empty_legacy.raise_for_status.return_value = None
    empty_legacy.json.return_value = {"ok": False, "reply": None}
    modern = Mock(status_code=200)
    modern.raise_for_status.return_value = None
    modern.json.return_value = {
        "tasks": [{"id": "new-task", "reply": "continue", "agterm_session_id": "session-2"}]
    }
    responses = iter([not_found, empty_legacy, modern])
    monkeypatch.setattr("tax.agent.requests.get", lambda *args, **kwargs: next(responses))
    monkeypatch.setattr(agent, "watch", lambda _task_id: None)

    assert agent.poll_backend_replies() == 0
    assert agent.poll_backend_replies() == 1
    assert agent.store.get("new-task")["status"] == "reply_received"
    agent.stop()


def test_stale_backend_reply_is_expired_without_delivery(monkeypatch, tmp_path):
    agent = make_agent(tmp_path)
    old_timestamp = (datetime.now(timezone.utc) - timedelta(minutes=31)).isoformat()
    watch = Mock()
    monkeypatch.setattr(agent, "watch", watch)
    monkeypatch.setattr(agent, "_mark_backend_status", Mock(return_value=True))

    scheduled = agent._schedule_backend_tasks(
        [
            {
                "id": "stale-reply",
                "reply": "too late",
                "agterm_session_id": "session-1",
                "updated_at": old_timestamp,
            }
        ]
    )

    assert scheduled == 0
    assert agent.store.get("stale-reply")["status"] == "expired"
    watch.assert_not_called()
    agent.stop()


def test_missing_session_is_failed_without_using_active(monkeypatch, tmp_path):
    agent = make_agent(tmp_path)
    agent.store.record_reply(WatchedTask(task_id="task-1"), "continue")
    inject = Mock()
    monkeypatch.setattr(agent, "inject_reply", inject)
    monkeypatch.setattr(agent, "_mark_backend_status", Mock(return_value=True))

    agent._watch_task("task-1")

    row = agent.store.get("task-1")
    assert row["status"] == "delivery_failed"
    assert row["attempts"] == 1
    assert row["last_error"] == "agterm session id is missing"
    inject.assert_not_called()
    agent.stop()


def test_pending_tasks_expire_after_poll_ttl(tmp_path):
    agent = TaxAgent("https://tax.example", "secret", tmp_path, poll_ttl=30 * 60)
    agent.store.add(WatchedTask(task_id="stale"))
    agent.store.add(WatchedTask(task_id="fresh"))
    stale_created_at = (datetime.now(timezone.utc) - timedelta(minutes=31)).isoformat()
    with agent.store.connect() as conn:
        conn.execute("UPDATE watched_tasks SET created_at = ? WHERE task_id = 'stale'", (stale_created_at,))
        conn.commit()

    assert agent.store.expire_stale(agent.poll_ttl) == 1
    assert agent.store.get("stale")["status"] == "expired"
    assert agent.store.get("fresh")["status"] == "pending"
    assert [row["task_id"] for row in agent.store.list_by_status({"pending", "waiting_reply"})] == ["fresh"]
    agent.stop()


def test_closed_session_is_marked_failed_without_retry(monkeypatch, tmp_path):
    agent = make_agent(tmp_path)
    task = WatchedTask(task_id="task-1", agterm_session_id="closed-session")
    agent.store.record_reply(task, "continue")
    post_response = Mock()
    post_response.raise_for_status.return_value = None
    post_response.json.return_value = {"ok": True}
    inject = Mock(side_effect=subprocess.CalledProcessError(1, ["agtermctl"]))
    monkeypatch.setattr("tax.agent.requests.post", lambda *args, **kwargs: post_response)
    monkeypatch.setattr(agent, "inject_reply", inject)

    agent._watch_task("task-1")

    row = agent.store.get("task-1")
    assert row["status"] == "delivery_failed"
    assert row["attempts"] == 1
    inject.assert_called_once_with("continue", "closed-session")
    assert post_response.json.call_count == 1
    agent.stop()


def test_backend_sync_failure_never_reinjects_reply(monkeypatch, tmp_path):
    agent = make_agent(tmp_path)
    task = WatchedTask(task_id="task-1", agterm_session_id="session-1")
    agent.store.record_reply(task, "continue")
    inject = Mock()
    monkeypatch.setattr(agent, "inject_reply", inject)
    monkeypatch.setattr(agent, "_mark_backend_status", Mock(side_effect=[False, True]))

    agent._watch_task("task-1")
    assert agent.store.get("task-1")["status"] == "delivered_pending_sync"

    agent._sync_local_terminal_status(agent.store.get("task-1"))

    assert agent.store.get("task-1")["status"] == "delivered"
    inject.assert_called_once_with("continue", "session-1")
    agent.stop()


def test_cleanup_removes_only_old_terminal_tasks(tmp_path):
    agent = make_agent(tmp_path)
    for task_id, status in (("delivered", "delivered"), ("failed", "delivery_failed"), ("pending", "pending")):
        agent.store.add(WatchedTask(task_id=task_id))
        agent.store.update(task_id, status)
    with agent.store.connect() as conn:
        conn.execute("UPDATE watched_tasks SET updated_at = '2000-01-01T00:00:00+00:00'")

    assert agent.store.cleanup_terminal() == 2
    assert agent.store.get("delivered") is None
    assert agent.store.get("failed") is None
    assert agent.store.get("pending") is not None
    agent.stop()


def test_local_api_health_task_and_shutdown(monkeypatch, tmp_path):
    agent = make_agent(tmp_path)
    monkeypatch.setattr(agent, "watch", lambda _task_id: None)
    stopped = []
    app = create_app(agent, lambda: stopped.append(True))

    with TestClient(app) as client:
        assert client.get("/health").json()["ok"] is True
        created = client.post("/task", json={"task_id": "task-1", "agterm_session_id": "session-1"})
        duplicate = client.post("/task", json={"task_id": "task-1", "agterm_session_id": "session-1"})
        assert created.json()["created"] is True
        assert duplicate.json()["created"] is False
        assert client.post("/shutdown").json() == {"ok": True}

    assert stopped == [True]
    assert agent.stop_event.is_set()
