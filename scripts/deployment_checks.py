"""Read-only deployment checks and private SQLite backups (stdlib only)."""

import argparse
import json
import os
from pathlib import Path
import shlex
import sqlite3
import urllib.request


def read_environment(path):
    path = Path(path)
    if path.stat().st_mode & 0o077:
        raise ValueError("backend environment file must have mode 0600")
    values = {}
    for number, line in enumerate(path.read_text().splitlines(), 1):
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        key, separator, value = line.partition("=")
        if not separator or not key.replace("_", "").isalnum() or key in values:
            raise ValueError(f"invalid or duplicate backend environment key at line {number}")
        # systemd treats '#' inside a value literally, not as a shell comment.
        parts = shlex.split(value, comments=False)
        if len(parts) > 1:
            raise ValueError(f"quote environment values containing spaces at line {number}")
        values[key] = parts[0] if parts else ""
    return values


def check_environment(path, db_path, key_path):
    values = read_environment(path)
    for key in ("TAX_API_KEY", "TAX_APNS_KEY_ID", "TAX_APNS_TEAM_ID", "TAX_APNS_BUNDLE_ID"):
        if not values.get(key) or values[key].startswith(("replace_with_", "your_", "your.")):
            raise ValueError(f"configure {key} before deployment")
    days = values.get("TAX_TASK_RETENTION_DAYS", "7").strip() or "7"
    if not days.isdecimal() or int(days) < 1:
        raise ValueError("TAX_TASK_RETENTION_DAYS must be a positive integer")
    for key, expected in (("TAX_DB_PATH", db_path), ("TAX_APNS_KEY_PATH", key_path)):
        if key in values and values[key] != expected:
            raise ValueError(f"{key} conflicts with deployment configuration")
    if not Path(key_path).is_file() or Path(key_path).stat().st_mode & 0o077:
        raise ValueError("APNs key must exist and have mode 0600")
    with Path(key_path).open("rb") as key_file:
        if not key_file.read(1):
            raise ValueError("APNs key must be readable and nonempty")


def check_caddy(config, domain, port):
    """Accept only explicit host routes to the configured loopback upstream."""
    upstreams = []

    def visit(value, matched=False):
        if isinstance(value, list):
            for item in value:
                visit(item, matched)
        elif isinstance(value, dict):
            matches = value.get("match")
            if matches is not None:
                matched = any(domain in item.get("host", []) for item in matches)
            if matched and value.get("handler") == "reverse_proxy":
                upstreams.extend(item.get("dial") for item in value.get("upstreams", []))
            for key, item in value.items():
                if key != "match":
                    visit(item, matched)

    visit(config)
    if not upstreams or any(item != f"127.0.0.1:{port}" for item in upstreams):
        raise ValueError("Caddy needs an explicit domain route to the configured loopback port; update it before deployment")


def backup_database(source, destination):
    # Exclusive creation avoids replacing an earlier backup or following a symlink.
    fd = os.open(destination, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    os.close(fd)
    try:
        with sqlite3.connect(Path(source).resolve().as_uri() + "?mode=ro", uri=True) as src:
            with sqlite3.connect(destination) as dst:
                src.backup(dst)
                if dst.execute("PRAGMA integrity_check").fetchone()[0] != "ok":
                    raise ValueError("database backup integrity check failed")
    except Exception:
        Path(destination).unlink(missing_ok=True)
        raise


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("env", "caddy", "backup", "health"))
    parser.add_argument("args", nargs="+")
    args = parser.parse_args()
    try:
        if args.command == "env":
            check_environment(*args.args)
        elif args.command == "caddy":
            path, domain, port = args.args
            check_caddy(json.loads(Path(path).read_text()), domain, port)
        elif args.command == "backup":
            backup_database(*args.args)
        else:
            env_file, port = args.args
            key = read_environment(env_file)["TAX_API_KEY"]
            request = urllib.request.Request(f"http://127.0.0.1:{int(port)}/health",
                                             headers={"Authorization": f"Bearer {key}"})
            opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
            with opener.open(request, timeout=10) as response:
                if not json.load(response).get("ok"):
                    raise ValueError("backend health check failed")
    except Exception as error:
        # Do not print exception details: they can contain environment values.
        parser.exit(1, f"deployment {args.command} check failed ({type(error).__name__}); inspect configuration locally\n")


if __name__ == "__main__":
    main()
