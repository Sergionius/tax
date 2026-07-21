import json
import threading
from pathlib import Path
from unittest.mock import Mock

from fastapi.testclient import TestClient

from tax.agent import AgentInstanceLock, AgentStore, TaxAgent, WatchedTask, create_app


def make_agent(tmp_path: Path) -> TaxAgent:
    return TaxAgent("https://tax.example", "secret", tmp_path, retry_delay=0.01)


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
    assert watched == ["task-1"]
    assert agent.store.get("task-1")["agterm_session_id"] == "session-1"
    agent.stop()


def test_start_discards_old_database_and_fallback(monkeypatch, tmp_path):
    agent = make_agent(tmp_path)
    agent.store.add(WatchedTask(task_id="old-db"))
    agent.fallback_path.write_text(json.dumps({"task_id": "old-file"}) + "\n", encoding="utf-8")
    watched = []
    monkeypatch.setattr(agent, "watch", watched.append)

    agent.start()

    assert agent.store.get("old-db") is None
    assert agent.fallback_path.read_bytes() == b""
    assert agent.import_fallback() == 0
    assert watched == []
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


def test_poll_reply_delivers_and_marks_backend(monkeypatch, tmp_path):
    agent = make_agent(tmp_path)
    task = WatchedTask(task_id="task-1", agterm_session_id="session-1", app="tax")
    agent.store.add(task)

    get_response = Mock()
    get_response.raise_for_status.return_value = None
    get_response.json.return_value = {"ok": True, "reply": "ship it"}
    post_response = Mock()
    post_response.raise_for_status.return_value = None
    injected = []

    monkeypatch.setattr("tax.agent.requests.get", lambda *args, **kwargs: get_response)
    monkeypatch.setattr("tax.agent.requests.post", lambda *args, **kwargs: post_response)
    monkeypatch.setattr(agent, "inject_reply", lambda reply, target: injected.append((reply, target)))

    agent._watch_task("task-1")

    assert injected == [("ship it", "session-1")]
    row = agent.store.get("task-1")
    assert row["status"] == "delivered"
    assert row["reply"] == "ship it"
    get_response.close.assert_called_once()
    post_response.close.assert_called_once()
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
