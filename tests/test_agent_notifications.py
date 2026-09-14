import io
import json
from unittest.mock import Mock

from tax import agent_notifications


def test_parse_claude_stop_event_uses_last_message_without_reading_transcript():
    notification = agent_notifications.parse_event(
        "claude",
        json.dumps(
            {
                "hook_event_name": "Stop",
                "session_id": "session-1",
                "cwd": "/workspace/project",
                "transcript_path": "/tmp/transcript.jsonl",
                "last_assistant_message": "Implemented the requested change.",
            }
        ),
    )

    assert notification.title == "claude completed"
    assert notification.body == "Implemented the requested change."
    assert notification.logs == "Implemented the requested change."
    assert "Session: session-1" in notification.context
    assert "Transcript: /tmp/transcript.jsonl" in notification.context


def test_parse_codex_event_supports_documented_hyphenated_fields():
    notification = agent_notifications.parse_event(
        "codex",
        json.dumps(
            {
                "type": "agent-turn-complete",
                "thread-id": "thread-1",
                "turn-id": "turn-2",
                "cwd": "/workspace/project",
                "input-messages": ["Fix the tests"],
                "last-assistant-message": "All tests now pass.",
            }
        ),
    )

    assert notification.title == "codex completed"
    assert notification.body == "All tests now pass."
    assert "Command: Fix the tests" in notification.context
    assert "Thread: thread-1" in notification.context
    assert "Turn: turn-2" in notification.context


def test_notification_body_is_single_line_and_bounded():
    body = agent_notifications.notification_body("line one\n" + "x" * 300, "fallback")

    assert "\n" not in body
    assert len(body) == agent_notifications.BODY_MAX_LENGTH
    assert body.endswith("…")


def test_hook_posts_routing_metadata_once(monkeypatch, tmp_path):
    response = Mock()
    response.raise_for_status.return_value = None
    response.json.return_value = {"task_id": "task-1"}
    post = Mock(return_value=response)
    monkeypatch.setattr(agent_notifications.requests, "post", post)
    event = json.dumps(
        {
            "type": "agent-turn-complete",
            "thread-id": "thread-1",
            "turn-id": "turn-1",
            "last-assistant-message": "Done",
        }
    )
    environment = {
        "ORCA_TERMINAL_HANDLE": "terminal-1",
        "ORCA_WORKTREE_ID": "worktree-1",
        "ORCA_TAB_ID": "tab-1",
        "ORCA_PANE_KEY": "pane-1",
        "TAX_HOST_ID": "host-1",
    }
    config = {"server": "https://tax.example", "api_key": "secret"}
    dedupe_path = tmp_path / "events.json"

    for _ in range(2):
        assert agent_notifications.run_notification_hook(
            "codex",
            event,
            stdin=io.StringIO(),
            environment=environment,
            config=config,
            dedupe_path=dedupe_path,
        ) == 0

    post.assert_called_once()
    _, kwargs = post.call_args
    assert kwargs["json"] | {
        "orca_terminal_handle": "terminal-1",
        "orca_worktree_id": "worktree-1",
        "orca_tab_id": "tab-1",
        "orca_pane_key": "pane-1",
        "host_id": "host-1",
        "source": "codex-hook",
        "agent": "codex",
        "app": "tax",
    } == kwargs["json"]
    assert kwargs["headers"] == {"Authorization": "Bearer secret"}
    assert dedupe_path.stat().st_mode & 0o777 == 0o600


def test_hook_is_best_effort_when_orca_context_is_missing(monkeypatch, tmp_path):
    post = Mock()
    monkeypatch.setattr(agent_notifications.requests, "post", post)

    result = agent_notifications.run_notification_hook(
        "claude",
        None,
        stdin=io.StringIO(json.dumps({"last_assistant_message": "Done"})),
        environment={},
        config={"server": "https://tax.example", "api_key": "secret"},
        dedupe_path=tmp_path / "events.json",
    )

    assert result == 0
    post.assert_not_called()


def test_hook_is_best_effort_when_server_is_not_configured(monkeypatch, tmp_path):
    post = Mock()
    monkeypatch.setattr(agent_notifications.requests, "post", post)

    result = agent_notifications.run_notification_hook(
        "codex",
        json.dumps({"last-assistant-message": "Done"}),
        stdin=io.StringIO(),
        environment={"ORCA_TERMINAL_HANDLE": "terminal-1"},
        config={},
        dedupe_path=tmp_path / "events.json",
    )

    assert result == 0
    post.assert_not_called()


def test_hook_is_best_effort_with_invalid_server_url(monkeypatch, tmp_path):
    post = Mock()
    monkeypatch.setattr(agent_notifications.requests, "post", post)

    result = agent_notifications.run_notification_hook(
        "codex",
        json.dumps({"last-assistant-message": "Done"}),
        stdin=io.StringIO(),
        environment={"ORCA_TERMINAL_HANDLE": "terminal-1"},
        config={"server": "not a url", "api_key": "secret"},
        dedupe_path=tmp_path / "events.json",
    )

    assert result == 0
    post.assert_not_called()


def test_hook_falls_back_to_environment_server(monkeypatch, tmp_path):
    response = Mock()
    response.raise_for_status.return_value = None
    response.json.return_value = {"task_id": "task-2"}
    post = Mock(return_value=response)
    monkeypatch.setattr(agent_notifications.requests, "post", post)

    result = agent_notifications.run_notification_hook(
        "claude",
        None,
        stdin=io.StringIO(json.dumps({"last_assistant_message": "Done"})),
        environment={"ORCA_TERMINAL_HANDLE": "terminal-1", "TAX_SERVER": "https://env.example"},
        config={"api_key": "secret"},
        dedupe_path=tmp_path / "events.json",
    )

    assert result == 0
    post.assert_called_once()
    assert post.call_args.args[0] == "https://env.example/push"


def test_hook_is_best_effort_for_invalid_json(monkeypatch, tmp_path):
    post = Mock()
    monkeypatch.setattr(agent_notifications.requests, "post", post)

    result = agent_notifications.run_notification_hook(
        "claude",
        None,
        stdin=io.StringIO("not-json"),
        environment={"ORCA_TERMINAL_HANDLE": "terminal-1"},
        config={"server": "https://tax.example", "api_key": "secret"},
        dedupe_path=tmp_path / "events.json",
    )

    assert result == 0
    post.assert_not_called()
