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


def test_send_to_agterm_uses_stdin_and_newline(monkeypatch):
    run = Mock()
    monkeypatch.setattr(cli.shutil, "which", lambda _name: "/tmp/agtermctl")
    monkeypatch.setattr(cli.subprocess, "run", run)

    cli.send_to_agterm("continue", "session-1")

    run.assert_called_once_with(
        ["/tmp/agtermctl", "session", "type", "--target", "session-1", "--stdin"],
        input="continue\n",
        text=True,
        check=False,
    )


def test_status_requires_api_key(monkeypatch, capsys):
    monkeypatch.setattr(cli, "load_config", lambda: {})
    monkeypatch.delenv("TAX_API_KEY", raising=False)

    assert cli.cmd_status(argparse.Namespace()) == 1
    assert "TAX_API_KEY not set" in capsys.readouterr().err


def test_run_requires_command(monkeypatch, capsys):
    monkeypatch.setattr(cli, "load_config", lambda: {"api_key": "key"})

    assert cli.run_agent([]) == 1
    assert "no command" in capsys.readouterr().err
