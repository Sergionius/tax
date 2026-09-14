"""Deployment validation is tested without root, SSH or live services."""

import importlib.util
import os
from pathlib import Path
import sqlite3

import pytest

spec = importlib.util.spec_from_file_location(
    "deployment_checks", Path(__file__).resolve().parents[1] / "scripts/deployment_checks.py"
)
checks = importlib.util.module_from_spec(spec)
spec.loader.exec_module(checks)


def environment(tmp_path):
    key = tmp_path / "AuthKey.p8"
    key.write_text("synthetic fixture")
    key.chmod(0o600)
    path = tmp_path / "custom-runtime.env"
    path.write_text("TAX_API_KEY=synthetic\nTAX_APNS_KEY_ID=demo\nTAX_APNS_TEAM_ID=demo\n"
                    "TAX_APNS_BUNDLE_ID=com.example.tax\n")
    path.chmod(0o600)
    return path, str(tmp_path / "db.sqlite"), str(key)


def test_custom_environment_path(tmp_path):
    args = environment(tmp_path)
    with args[0].open("a") as stream:
        stream.write('SYNTHETIC_VALUE=abc#def\nQUOTED_VALUE="value with spaces"\n')
    checks.check_environment(*args)
    values = checks.read_environment(args[0])
    assert values["SYNTHETIC_VALUE"] == "abc#def"
    assert values["QUOTED_VALUE"] == "value with spaces"
    assert not (tmp_path / "server/.env").exists()


@pytest.mark.parametrize("extra", ["TAX_DB_PATH=/wrong\n", "TAX_APNS_KEY_PATH=/wrong\n",
                                  "TAX_TASK_RETENTION_DAYS=0\n", "TAX_TASK_RETENTION_DAYS=bad\n",
                                  "TAX_API_KEY=duplicate\n"])
def test_invalid_environment_rejected(tmp_path, extra):
    args = environment(tmp_path)
    with args[0].open("a") as stream:
        stream.write(extra)
    with pytest.raises(ValueError):
        checks.check_environment(*args)


def test_environment_requires_private_permissions(tmp_path):
    args = environment(tmp_path)
    args[0].chmod(0o644)
    with pytest.raises(ValueError):
        checks.check_environment(*args)


def caddy(domain, port):
    return {"apps": {"http": {"servers": {"srv0": {"routes": [
        {"match": [{"host": [domain]}], "handle": [{"handler": "subroute", "routes": [
            {"handle": [{"handler": "reverse_proxy", "upstreams": [{"dial": f"127.0.0.1:{port}"}]}]}
        ]}]}
    ]}}}}}


def test_caddy_matches_exact_host_and_upstream():
    checks.check_caddy(caddy("tax.example.com", 8002), "tax.example.com", "8002")


@pytest.mark.parametrize("domain,port", [("other.example.com", 8002), ("tax.example.com", 8000)])
def test_caddy_rejects_mismatch(domain, port):
    with pytest.raises(ValueError):
        checks.check_caddy(caddy(domain, port), "tax.example.com", "8002")


def test_backup_is_private_and_cannot_overwrite(tmp_path):
    src, dst = tmp_path / "source.db", tmp_path / "backup.db"
    with sqlite3.connect(src) as conn:
        conn.execute("CREATE TABLE demo (value TEXT)")
        conn.execute("INSERT INTO demo VALUES ('synthetic')")
    previous = os.umask(0o022)
    try:
        checks.backup_database(src, dst)
    finally:
        os.umask(previous)
    assert dst.stat().st_mode & 0o777 == 0o600
    with sqlite3.connect(dst) as conn:
        assert conn.execute("SELECT value FROM demo").fetchone()[0] == "synthetic"
    with pytest.raises(FileExistsError):
        checks.backup_database(src, dst)


def test_missing_database_does_not_create_empty_source(tmp_path):
    with pytest.raises(sqlite3.OperationalError):
        checks.backup_database(tmp_path / "absent.db", tmp_path / "backup.db")
    assert not (tmp_path / "absent.db").exists()
    assert not (tmp_path / "backup.db").exists()
