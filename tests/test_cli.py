import argparse
import json
import stat
from unittest.mock import Mock

from tax import cli


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


def test_invalid_config_is_reported_without_traceback(monkeypatch, tmp_path, capsys):
    path = tmp_path / "config.json"
    path.write_text("not-json")
    monkeypatch.setattr(cli, "CONFIG_PATH", path)
    monkeypatch.setattr("sys.argv", ["tax", "status"])

    assert cli.main() == 1
    assert "invalid tax config" in capsys.readouterr().err


def test_send_to_orca_uses_explicit_handle_and_enter(monkeypatch):
    payload = {"ok": True, "result": {"send": {"accepted": True}}}
    run = Mock(return_value=Mock(stdout=json.dumps(payload), stderr=""))
    monkeypatch.setattr(cli.shutil, "which", lambda _name: "/tmp/orca")
    monkeypatch.setattr(cli.subprocess, "run", run)

    assert cli.send_to_orca("continue", "term-1") is True

    run.assert_called_once_with(
        [
            "/tmp/orca",
            "terminal",
            "send",
            "--terminal",
            "term-1",
            "--text",
            "continue",
            "--enter",
            "--json",
        ],
        text=True,
        check=False,
        capture_output=True,
        timeout=15,
    )


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


def test_run_requires_command(monkeypatch, capsys):
    monkeypatch.setattr(cli, "load_config", lambda: {"api_key": "key"})

    assert cli.run_agent([]) == 1
    assert "no command" in capsys.readouterr().err
