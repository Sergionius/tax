import argparse
import io
import json
import stat
import subprocess
from unittest.mock import Mock

import pytest
import requests

from tax import cli


class FakeStdout:
    def __init__(self, output: str):
        self._buffer = io.StringIO(output)
        self.eof = False

    def readline(self) -> str:
        line = self._buffer.readline()
        if line == "":
            self.eof = True
        return line


class InterruptingStdout:
    def __init__(self):
        self.calls = 0

    def readline(self) -> str:
        self.calls += 1
        if self.calls == 1:
            return "starting\n"
        raise KeyboardInterrupt


class FakeProcess:
    def __init__(self, output: str = "", exit_code: int = 0, stdout=None, terminate_times_out: bool = False):
        self.stdout = stdout if stdout is not None else FakeStdout(output)
        self.exit_code = exit_code
        self.returncode = None
        self.terminated = False
        self.killed = False
        self.waits: list = []
        self.terminate_times_out = terminate_times_out

    def poll(self):
        if self.returncode is None and getattr(self.stdout, "eof", False):
            self.returncode = self.exit_code
        return self.returncode

    def terminate(self):
        self.terminated = True

    def kill(self):
        self.killed = True

    def wait(self, timeout=None):
        self.waits.append(timeout)
        if self.terminate_times_out and timeout is not None and not self.killed:
            raise subprocess.TimeoutExpired(cmd="tax run", timeout=timeout)
        self.returncode = self.exit_code
        return self.exit_code


def test_config_precedence(monkeypatch, tmp_path):
    monkeypatch.setattr(cli, "CONFIG_PATH", tmp_path / "config.json")
    monkeypatch.setenv("TAX_SERVER", "https://env.example")
    monkeypatch.setenv("TAX_API_KEY", "env-key")

    assert cli.get_server({}) == "https://env.example"
    assert cli.get_api_key({}) == "env-key"
    assert cli.get_server({"server": "https://config.example"}) == "https://config.example"
    assert cli.get_api_key({"api_key": "config-key"}) == "config-key"


def test_config_output_redacts_secrets_and_file_is_private(monkeypatch, tmp_path, capsys):
    path = tmp_path / "config.json"
    monkeypatch.setattr(cli, "CONFIG_PATH", path)
    args = argparse.Namespace(server="https://tax.example", api_key="super-secret", device_token="device-secret")

    assert cli.cmd_config(args) == 0

    output = capsys.readouterr().out
    assert "super-secret" not in output
    assert "device-secret" not in output
    assert output.count("***") == 2
    assert json.loads(path.read_text())["api_key"] == "super-secret"
    assert stat.S_IMODE(path.stat().st_mode) == 0o600


def test_cli_help_omits_agent_and_detach(monkeypatch, capsys):
    monkeypatch.setattr("sys.argv", ["tax", "--help"])
    with pytest.raises(SystemExit):
        cli.main()
    out = capsys.readouterr().out
    commands = out.split("{", 1)[1].split("}", 1)[0].split(",")
    assert "run" in commands
    assert "agent" not in commands

    monkeypatch.setattr("sys.argv", ["tax", "run", "--help"])
    with pytest.raises(SystemExit):
        cli.main()
    assert "--detach" not in capsys.readouterr().out


def test_doctor_reports_backend_without_local_agent_checks(monkeypatch, capsys):
    monkeypatch.setattr(cli, "load_config", lambda: {"server": "https://tax.example", "api_key": "key"})
    monkeypatch.setattr(cli, "orca_cli_command", lambda: ["/tmp/orca"])
    status = Mock()
    status.stdout = json.dumps({"ok": True, "result": {"runtime": {"reachable": True, "state": "ready"}}})
    monkeypatch.setattr(cli.subprocess, "run", Mock(return_value=status))
    health = Mock()
    health.raise_for_status.return_value = None
    seen_urls = []

    def fake_get(url, **kwargs):
        seen_urls.append(url)
        return health

    monkeypatch.setattr(cli.requests, "get", Mock(side_effect=fake_get))
    monkeypatch.setattr(cli, "get_device_token", lambda _config: "")

    assert cli.cmd_doctor(argparse.Namespace()) == 0

    assert seen_urls == ["https://tax.example/health"]
    out = capsys.readouterr().out
    assert "Orca runtime: ready" in out
    assert "tax-agent" not in out
    assert "backend registration fallback" in out


def test_status_renders_push_status_with_unknown_for_null(monkeypatch, capsys):
    monkeypatch.setattr(cli, "load_config", lambda: {"server": "https://tax.example", "api_key": "key"})
    response = Mock()
    response.raise_for_status.return_value = None
    response.json.return_value = {
        "tasks": [
            {"id": "t1", "push_status": "sent", "title": "one", "updated_at": "2026-01-01T00:00:00+00:00"},
            {"id": "t2", "push_status": "failed", "title": "two", "updated_at": "2026-01-01T00:00:01+00:00"},
            {"id": "t3", "push_status": "skipped", "title": "three", "updated_at": "2026-01-01T00:00:02+00:00"},
            {"id": "t4", "push_status": "queued", "title": "four", "updated_at": "2026-01-01T00:00:03+00:00"},
            {
                "id": "t5",
                "push_status": None,
                "status": "completed",
                "title": "five",
                "updated_at": "2026-01-01T00:00:04+00:00",
            },
            {"id": "t6", "title": "six", "updated_at": "2026-01-01T00:00:05+00:00"},
        ]
    }
    monkeypatch.setattr(cli.requests, "get", Mock(return_value=response))

    assert cli.cmd_status(argparse.Namespace()) == 0

    out = capsys.readouterr().out
    assert "t1 | sent" in out
    assert "t2 | failed" in out
    assert "t3 | skipped" in out
    assert "t4 | queued" in out
    assert "t5 | unknown" in out
    assert "t6 | unknown" in out
    assert "completed" not in out


def test_invalid_config_is_reported_without_traceback(monkeypatch, tmp_path, capsys):
    path = tmp_path / "config.json"
    path.write_text("not-json")
    monkeypatch.setattr(cli, "CONFIG_PATH", path)
    monkeypatch.setattr("sys.argv", ["tax", "status"])

    assert cli.main() == 1
    assert "invalid tax config" in capsys.readouterr().err


def test_e2ee_key_generate_stores_and_prints_copyable_key(monkeypatch, capsys):
    stored = []
    monkeypatch.setattr("tax.keychain.store_e2ee_key", stored.append)

    assert cli.cmd_e2ee_key(argparse.Namespace(action="generate")) == 0

    captured = capsys.readouterr()
    assert stored == [captured.out.strip()]
    assert len(stored[0]) == 43
    assert "Keychain" in captured.err


def test_send_push_posts_payload_with_fixed_source_and_app(monkeypatch):
    response = Mock()
    response.raise_for_status.return_value = None
    response.json.return_value = {"task_id": "task-9"}
    posts = []

    def fake_post(url, json=None, headers=None, timeout=None):
        posts.append({"url": url, "json": json, "headers": headers, "timeout": timeout})
        return response

    monkeypatch.setattr(cli.requests, "post", fake_post)

    result = cli.send_push(
        "https://tax.example",
        "key",
        "device-token",
        "title",
        "body",
        context="ctx",
        logs="logs",
        agent="pytest",
        host_id="host-1",
        orca_terminal_handle="term",
        orca_worktree_id="wt",
        orca_tab_id="tab",
        orca_pane_key="pane",
    )

    assert result == {"task_id": "task-9"}
    assert posts[0]["url"] == "https://tax.example/push"
    assert posts[0]["headers"] == {"Authorization": "Bearer key"}
    assert posts[0]["json"] == {
        "device_token": "device-token",
        "title": "title",
        "body": "body",
        "context": "ctx",
        "logs": "logs",
        "source": "tax-cli",
        "agent": "pytest",
        "app": "tax",
        "host_id": "host-1",
        "orca_terminal_handle": "term",
        "orca_worktree_id": "wt",
        "orca_tab_id": "tab",
        "orca_pane_key": "pane",
    }


def test_send_push_raises_on_invalid_backend_json(monkeypatch):
    response = Mock()
    response.raise_for_status.return_value = None
    response.json.side_effect = ValueError("invalid json")
    monkeypatch.setattr(cli.requests, "post", Mock(return_value=response))

    with pytest.raises(ValueError):
        cli.send_push("https://tax.example", "key", "", "t", "b")


def test_recap_reads_recent_text_messages(tmp_path, capsys):
    session = tmp_path / "session.jsonl"
    entries = [
        {"type": "message", "message": {"role": "user", "content": [{"type": "text", "text": "first task"}]}},
        {"type": "message", "message": {"role": "assistant", "content": [{"type": "toolCall", "name": "read"}, {"type": "text", "text": "done"}]}},
    ]
    session.write_text("\n".join(json.dumps(item) for item in entries), encoding="utf-8")
    args = argparse.Namespace(session_file=str(session), turns=2, max_chars=100)

    assert cli.cmd_recap(args) == 0

    output = capsys.readouterr().out
    assert "first task" in output
    assert "done" in output
    assert "toolCall" not in output


def test_push_doctor_reports_accepted_apns(monkeypatch, capsys):
    monkeypatch.setattr(cli, "load_config", lambda: {"server": "https://tax.example", "api_key": "key"})
    created = Mock()
    created.raise_for_status.return_value = None
    created.json.return_value = {
        "task_id": "task-1",
        "device_registered": True,
        "environment": "production",
    }
    status = Mock()
    status.raise_for_status.return_value = None
    status.json.return_value = {
        "diagnostic": {
            "push_status": "sent",
            "apns_status_code": 200,
            "apns_id": "apns-1",
        }
    }
    monkeypatch.setattr(cli.requests, "post", Mock(return_value=created))
    monkeypatch.setattr(cli.requests, "get", Mock(return_value=status))

    assert cli.cmd_push_doctor(argparse.Namespace(timeout=1)) == 0

    output = capsys.readouterr().out
    assert "Device registration: present" in output
    assert "APNs result: sent" in output
    assert "APNs ID: apns-1" in output
    assert "cannot be confirmed without iOS telemetry" in output


def test_status_requires_api_key(monkeypatch, capsys):
    monkeypatch.setattr(cli, "load_config", lambda: {})
    monkeypatch.delenv("TAX_API_KEY", raising=False)

    assert cli.cmd_status(argparse.Namespace()) == 1
    assert "TAX_API_KEY not set" in capsys.readouterr().err


def test_run_requires_api_key(monkeypatch, capsys):
    monkeypatch.setattr(cli, "load_config", lambda: {})
    monkeypatch.delenv("TAX_API_KEY", raising=False)

    assert cli.run_command(["true"]) == 1
    assert "TAX_API_KEY not set" in capsys.readouterr().err


def test_run_requires_command(monkeypatch, capsys):
    monkeypatch.setattr(cli, "load_config", lambda: {"api_key": "key"})

    assert cli.run_command([]) == 1
    assert "no command" in capsys.readouterr().err


def test_run_command_streams_output_and_returns_nonzero_exit(monkeypatch, capsys):
    monkeypatch.setattr(cli, "load_config", lambda: {"api_key": "key"})
    monkeypatch.setattr(cli, "send_push", Mock(return_value={"task_id": "task-1"}))
    proc = FakeProcess("step 1\nstep 2\n", exit_code=3)
    popen_calls = []

    def fake_popen(argv, **kwargs):
        popen_calls.append((argv, kwargs))
        return proc

    monkeypatch.setattr(cli.subprocess, "Popen", fake_popen)

    assert cli.run_command(["failing-cmd", "--flag", "value"]) == 3

    argv, kwargs = popen_calls[0]
    assert argv == ["failing-cmd", "--flag", "value"]
    assert kwargs["stdout"] == subprocess.PIPE
    assert kwargs["stderr"] == subprocess.STDOUT
    output = capsys.readouterr().out
    assert "step 1" in output
    assert "step 2" in output
    assert proc.terminated is False
    assert proc.waits == []


def test_run_command_sends_completion_payload_with_defaults(monkeypatch, capsys):
    for name in ("TAX_HOST_ID", "ORCA_TERMINAL_HANDLE", "ORCA_WORKTREE_ID", "ORCA_WORKSPACE_ID", "ORCA_TAB_ID", "ORCA_PANE_KEY"):
        monkeypatch.delenv(name, raising=False)
    monkeypatch.setattr(cli, "load_config", lambda: {"server": "https://tax.example", "api_key": "key"})
    send = Mock(return_value={"task_id": "task-77"})
    monkeypatch.setattr(cli, "send_push", send)
    monkeypatch.setattr(cli.subprocess, "Popen", lambda argv, **kwargs: FakeProcess("done\n", exit_code=0))

    assert cli.run_command(["pytest", "-q"]) == 0

    send.assert_called_once_with(
        "https://tax.example",
        "key",
        "",
        "pytest completed",
        "exit code 0",
        context="Command: pytest -q",
        logs="done",
        agent="pytest",
        host_id="mac-main",
        orca_terminal_handle="",
        orca_worktree_id="",
        orca_tab_id="",
        orca_pane_key="",
    )
    assert "task_id=task-77" in capsys.readouterr().out


def test_run_command_sends_trimmed_orca_and_host_metadata(monkeypatch):
    monkeypatch.setattr(cli, "load_config", lambda: {"api_key": "key"})
    send = Mock(return_value={"task_id": "task-8"})
    monkeypatch.setattr(cli, "send_push", send)
    monkeypatch.setattr(cli.subprocess, "Popen", lambda argv, **kwargs: FakeProcess("", exit_code=1))
    monkeypatch.setenv("TAX_HOST_ID", "  build-host  ")
    monkeypatch.setenv("ORCA_TERMINAL_HANDLE", " term-9 ")
    monkeypatch.setenv("ORCA_WORKTREE_ID", "repo::/tmp/wt")
    monkeypatch.setenv("ORCA_TAB_ID", "tab-1")
    monkeypatch.setenv("ORCA_PANE_KEY", "tab-1:leaf-1")

    assert cli.run_command(["false"]) == 1

    kwargs = send.call_args.kwargs
    assert kwargs["agent"] == "false"
    assert kwargs["host_id"] == "build-host"
    assert kwargs["orca_terminal_handle"] == "term-9"
    assert kwargs["orca_worktree_id"] == "repo::/tmp/wt"
    assert kwargs["orca_tab_id"] == "tab-1"
    assert kwargs["orca_pane_key"] == "tab-1:leaf-1"


def test_run_command_falls_back_to_orca_workspace_id(monkeypatch):
    monkeypatch.setattr(cli, "load_config", lambda: {"api_key": "key"})
    send = Mock(return_value={"task_id": "task-8"})
    monkeypatch.setattr(cli, "send_push", send)
    monkeypatch.setattr(cli.subprocess, "Popen", lambda argv, **kwargs: FakeProcess("", exit_code=0))
    monkeypatch.delenv("ORCA_WORKTREE_ID", raising=False)
    monkeypatch.setenv("ORCA_WORKSPACE_ID", "ws-1")

    assert cli.run_command(["true"]) == 0

    assert send.call_args.kwargs["orca_worktree_id"] == "ws-1"


def test_run_command_returns_exit_code_when_push_fails(monkeypatch, capsys):
    monkeypatch.setattr(cli, "load_config", lambda: {"api_key": "key"})
    monkeypatch.setattr(cli, "send_push", Mock(side_effect=requests.ConnectionError("backend down")))
    monkeypatch.setattr(cli.subprocess, "Popen", lambda argv, **kwargs: FakeProcess("out\n", exit_code=2))

    assert cli.run_command(["flaky"]) == 2
    assert "failed to send push" in capsys.readouterr().err


def test_run_command_returns_exit_code_on_missing_task_id(monkeypatch, capsys):
    monkeypatch.setattr(cli, "load_config", lambda: {"api_key": "key"})
    monkeypatch.setattr(cli, "send_push", Mock(return_value={}))
    monkeypatch.setattr(cli.subprocess, "Popen", lambda argv, **kwargs: FakeProcess("out\n", exit_code=5))

    assert cli.run_command(["broken"]) == 5
    assert "did not return task_id" in capsys.readouterr().err


def test_run_command_returns_exit_code_on_invalid_backend_response(monkeypatch, capsys):
    monkeypatch.setattr(cli, "load_config", lambda: {"api_key": "key"})
    monkeypatch.setattr(cli, "send_push", Mock(side_effect=ValueError("invalid json")))
    monkeypatch.setattr(cli.subprocess, "Popen", lambda argv, **kwargs: FakeProcess("out\n", exit_code=7))

    assert cli.run_command(["broken"]) == 7
    assert "failed to send push" in capsys.readouterr().err


def test_run_command_allows_missing_device_token(monkeypatch, capsys):
    monkeypatch.setattr(cli, "load_config", lambda: {"api_key": "key"})
    monkeypatch.setattr(cli, "send_push", Mock(return_value={"task_id": "task-1"}))
    monkeypatch.setattr(cli.subprocess, "Popen", lambda argv, **kwargs: FakeProcess("out\n", exit_code=0))

    assert cli.run_command(["true"]) == 0

    captured = capsys.readouterr()
    assert "warning" not in captured.err
    assert "device_token" not in captured.err


def test_run_command_never_polls_backend_after_completion(monkeypatch):
    monkeypatch.setattr(cli, "load_config", lambda: {"api_key": "key"})
    monkeypatch.setattr(cli, "send_push", Mock(return_value={"task_id": "task-1"}))
    get_mock = Mock(side_effect=AssertionError("no GET is expected after completion"))
    monkeypatch.setattr(cli.requests, "get", get_mock)
    monkeypatch.setattr(cli.subprocess, "Popen", lambda argv, **kwargs: FakeProcess("out\n", exit_code=0))

    assert cli.run_command(["true"]) == 0
    get_mock.assert_not_called()


def test_run_command_terminates_and_waits_after_interrupt(monkeypatch, capsys):
    monkeypatch.setattr(cli, "load_config", lambda: {"api_key": "key"})
    monkeypatch.setattr(cli, "send_push", Mock(return_value={"task_id": "task-1"}))
    proc = FakeProcess(stdout=InterruptingStdout(), exit_code=130)
    monkeypatch.setattr(cli.subprocess, "Popen", lambda argv, **kwargs: proc)

    assert cli.run_command(["sleep", "999"]) == 130

    assert proc.terminated
    assert proc.killed is False
    assert proc.waits == [5, None]


def test_run_command_kills_process_when_terminate_times_out(monkeypatch, capsys):
    monkeypatch.setattr(cli, "load_config", lambda: {"api_key": "key"})
    monkeypatch.setattr(cli, "send_push", Mock(return_value={"task_id": "task-1"}))
    proc = FakeProcess(stdout=InterruptingStdout(), exit_code=137, terminate_times_out=True)
    monkeypatch.setattr(cli.subprocess, "Popen", lambda argv, **kwargs: proc)

    assert cli.run_command(["sleep", "999"]) == 137

    assert proc.terminated
    assert proc.killed
    assert proc.waits == [5, None]
