import argparse
import json
import os
import shlex
import shutil
import subprocess
import sys
import time
from pathlib import Path
from urllib.parse import urlparse

import requests

CONFIG_PATH = Path.home() / ".config" / "tax" / "config.json"


def load_config() -> dict:
    if not CONFIG_PATH.exists():
        return {}
    try:
        data = json.loads(CONFIG_PATH.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise ValueError(f"invalid tax config: {error}") from error
    if not isinstance(data, dict):
        raise ValueError("invalid tax config: expected a JSON object")
    return data


def save_config(config: dict) -> None:
    CONFIG_PATH.parent.mkdir(parents=True, exist_ok=True)
    CONFIG_PATH.write_text(json.dumps(config, indent=2), encoding="utf-8")
    CONFIG_PATH.chmod(0o600)


def get_server(config: dict) -> str:
    """Resolve the backend URL: non-empty config value, then environment."""
    configured = str(config.get("server") or "").strip()
    return configured or os.environ.get("TAX_SERVER", "").strip()


def require_server(config: dict, override: str = "") -> str:
    """Return a validated backend URL or raise ValueError before any network use."""
    server = (override or get_server(config)).strip()
    if not server:
        raise ValueError(
            "backend URL is not configured. Run: tax config --server https://tax.example.com "
            "or export TAX_SERVER"
        )
    parsed = urlparse(server)
    if parsed.scheme not in ("http", "https") or not parsed.netloc:
        raise ValueError(
            f"invalid backend URL {server!r}: expected http(s)://host. "
            "Fix it with: tax config --server https://tax.example.com"
        )
    return server.rstrip("/")


def get_api_key(config: dict) -> str:
    return config.get("api_key", os.environ.get("TAX_API_KEY", ""))


def get_device_token(config: dict) -> str:
    return config.get("device_token", os.environ.get("TAX_DEVICE_TOKEN", ""))


def get_headers(config: dict) -> dict:
    return {"Authorization": f"Bearer {get_api_key(config)}"}


def send_push(
    server: str,
    api_key: str,
    device_token: str,
    title: str,
    body: str,
    *,
    context: str = "",
    logs: str = "",
    agent: str = "",
    host_id: str = "",
    orca_terminal_handle: str = "",
    orca_worktree_id: str = "",
    orca_tab_id: str = "",
    orca_pane_key: str = "",
) -> dict:
    payload = {
        "device_token": device_token,
        "title": title,
        "body": body,
        "context": context,
        "logs": logs,
        "source": "tax-cli",
        "agent": agent,
        "app": "tax",
        "host_id": host_id,
        "orca_terminal_handle": orca_terminal_handle,
        "orca_worktree_id": orca_worktree_id,
        "orca_tab_id": orca_tab_id,
        "orca_pane_key": orca_pane_key,
    }
    r = requests.post(f"{server}/push", json=payload, headers={"Authorization": f"Bearer {api_key}"}, timeout=30)
    r.raise_for_status()
    return r.json()


def orca_cli_command() -> list[str]:
    override = os.environ.get("TAX_ORCA_CLI", "").strip() or os.environ.get("ORCA_CLI_COMMAND", "").strip()
    if override:
        command = shlex.split(override)
        if command:
            return command
    executable = shutil.which("orca")
    return [executable] if executable else []


def run_command(argv: list[str]) -> int:
    config = load_config()
    api_key = get_api_key(config)
    device_token = get_device_token(config)

    if not api_key:
        print(
            "[tax] error: TAX_API_KEY not set. Add to ~/.zshrc: export TAX_API_KEY=*** then source ~/.zshrc",
            file=sys.stderr,
        )
        return 1

    # Configuration preflight: fail before the child command starts.
    try:
        server = require_server(config)
    except ValueError as error:
        print(f"[tax] error: {error}", file=sys.stderr)
        return 1

    if not argv:
        print("[tax] error: no command to run", file=sys.stderr)
        return 1

    # Run the command without a shell and stream its merged output
    print(f"[tax] running: {' '.join(argv)}")
    proc = subprocess.Popen(argv, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    output_lines: list[str] = []

    try:
        while True:
            line = proc.stdout.readline() if proc.stdout else ""
            if not line:
                if proc.poll() is not None:
                    break
                time.sleep(0.05)
                continue
            line = line.rstrip("\n")
            output_lines.append(line)
            print(line)
    except KeyboardInterrupt:
        proc.terminate()
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            proc.kill()
        proc.wait()

    exit_code = proc.returncode
    logs = "\n".join(output_lines[-500:])  # last 500 lines

    # Send one best-effort completion push; never alter the command's exit code
    status = "completed" if exit_code == 0 else "failed"
    title = f"{Path(argv[0]).name} {status}"
    body = f"exit code {exit_code}"
    context = f"Command: {' '.join(argv)}"
    worktree_id = os.environ.get("ORCA_WORKTREE_ID", "").strip() or os.environ.get("ORCA_WORKSPACE_ID", "").strip()

    try:
        resp = send_push(
            server,
            api_key,
            device_token,
            title,
            body,
            context=context,
            logs=logs,
            agent=Path(argv[0]).name,
            host_id=os.environ.get("TAX_HOST_ID", "").strip() or "mac-main",
            orca_terminal_handle=os.environ.get("ORCA_TERMINAL_HANDLE", "").strip(),
            orca_worktree_id=worktree_id,
            orca_tab_id=os.environ.get("ORCA_TAB_ID", "").strip(),
            orca_pane_key=os.environ.get("ORCA_PANE_KEY", "").strip(),
        )
        if resp.get("task_id"):
            print(f"[tax] push sent, task_id={resp['task_id']}")
        else:
            print("[tax] backend did not return task_id", file=sys.stderr)
    except (requests.RequestException, ValueError) as e:
        print(f"[tax] failed to send push: {e}", file=sys.stderr)

    return exit_code


def cmd_config(args: argparse.Namespace) -> int:
    config = load_config()
    if args.server:
        config["server"] = args.server
    if args.api_key:
        config["api_key"] = args.api_key
    if args.device_token:
        config["device_token"] = args.device_token
    save_config(config)
    safe_config = {**config}
    if safe_config.get("api_key"):
        safe_config["api_key"] = "***"
    if safe_config.get("device_token"):
        safe_config["device_token"] = "***"
    print(json.dumps(safe_config, indent=2))
    return 0


def cmd_run(args: argparse.Namespace) -> int:
    return run_command(args.command)


def cmd_e2ee_key(args: argparse.Namespace) -> int:
    from tax.e2ee import encode_key, generate_key
    from tax.keychain import load_e2ee_key, store_e2ee_key

    try:
        if args.action == "generate":
            value = encode_key(generate_key())
            store_e2ee_key(value)
            print(value)
            print("[tax] E2EE key stored in macOS Keychain; copy it to the iPhone once.", file=sys.stderr)
        else:
            print(load_e2ee_key())
    except (OSError, subprocess.SubprocessError) as error:
        print(f"[tax] Keychain operation failed: {error}", file=sys.stderr)
        return 1
    return 0


def cmd_remote_host(args: argparse.Namespace) -> int:
    from tax.keychain import load_e2ee_key
    from tax.remote_host import run_remote_host

    config = load_config()
    try:
        run_remote_host(
            server=require_server(config, override=args.server),
            api_key=args.api_key or get_api_key(config),
            host_id=args.host_id,
            device_id=args.device_id,
            e2ee_key=load_e2ee_key(),
            orca_pairing_code_file=Path(args.orca_pairing_code_file).expanduser(),
        )
    except (OSError, RuntimeError, subprocess.SubprocessError, ValueError) as error:
        print(f"[tax] remote host failed: {error}", file=sys.stderr)
        return 1
    return 0


def cmd_remote_smoke(args: argparse.Namespace) -> int:
    from tax.keychain import load_e2ee_key
    from tax.remote_test_client import run_remote_smoke

    config = load_config()
    try:
        result = run_remote_smoke(
            server=require_server(config, override=args.server),
            api_key=args.api_key or get_api_key(config),
            host_id=args.host_id,
            device_id=args.device_id,
            e2ee_key=load_e2ee_key(),
            start_pi=args.start_pi,
        )
    except (OSError, RuntimeError, subprocess.SubprocessError, TimeoutError, ValueError) as error:
        print(f"[tax] remote smoke failed: {error}", file=sys.stderr)
        return 1
    print(json.dumps(result, indent=2))
    return 0


def _doctor_check(name: str, ok: bool, detail: str) -> bool:
    print(f"{'✓' if ok else '✗'} {name}: {detail}")
    return ok


def cmd_doctor(args: argparse.Namespace) -> int:
    config = load_config()
    required_ok = True
    orca_command = orca_cli_command()
    required_ok &= _doctor_check("orca CLI", bool(orca_command), " ".join(orca_command) or "not found in PATH")

    if orca_command:
        try:
            result = subprocess.run(
                [*orca_command, "status", "--json"], check=False, capture_output=True, text=True, timeout=10
            )
            payload = json.loads(result.stdout)
            runtime = payload.get("result", {}).get("runtime", {})
            ready = payload.get("ok") is True and runtime.get("reachable") is True and runtime.get("state") == "ready"
            required_ok &= _doctor_check("Orca runtime", ready, runtime.get("state", "unavailable"))
        except (OSError, subprocess.SubprocessError, ValueError) as error:
            required_ok &= _doctor_check("Orca runtime", False, str(error))

    api_key = get_api_key(config)
    required_ok &= _doctor_check("API key", bool(api_key), "configured" if api_key else "missing")
    if api_key:
        try:
            server = require_server(config)
            response = requests.get(f"{server}/health", headers=get_headers(config), timeout=5)
            response.raise_for_status()
            _doctor_check("backend", True, server)
        except (requests.RequestException, ValueError) as error:
            required_ok &= _doctor_check("backend", False, str(error))

    token = get_device_token(config)
    print(f"{'✓' if token else '-'} device token: {'configured' if token else 'backend registration fallback'}")
    return 0 if required_ok else 1


def _message_text(content: object) -> str:
    if isinstance(content, str):
        return content.strip()
    if not isinstance(content, list):
        return ""
    parts = []
    for part in content:
        if not isinstance(part, dict):
            continue
        if part.get("type") == "text" and isinstance(part.get("text"), str):
            parts.append(part["text"])
    return "\n".join(parts).strip()


def cmd_recap(args: argparse.Namespace) -> int:
    raw_path = args.session_file or os.environ.get("PI_SESSION_FILE", "")
    if not raw_path:
        print("[tax] error: pass --session-file or run inside Pi", file=sys.stderr)
        return 1
    path = Path(raw_path).expanduser()
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except OSError as error:
        print(f"[tax] failed to read session: {error}", file=sys.stderr)
        return 1
    messages = []
    for line in lines:
        try:
            entry = json.loads(line)
        except json.JSONDecodeError:
            continue
        message = entry.get("message") if entry.get("type") == "message" else None
        if not isinstance(message, dict) or message.get("role") not in {"user", "assistant"}:
            continue
        text = _message_text(message.get("content"))
        if text:
            messages.append((message["role"], text))
    selected = messages[-max(1, args.turns * 2) :]
    if not selected:
        print("[tax] session has no readable conversation", file=sys.stderr)
        return 1
    print(f"Pi recap — {path.name}")
    for role, text in selected:
        compact = " ".join(text.split())
        if len(compact) > args.max_chars:
            compact = compact[: args.max_chars - 1].rstrip() + "…"
        print(f"{role:9} {compact}")
    return 0


def cmd_push_doctor(args: argparse.Namespace) -> int:
    config = load_config()
    api_key = get_api_key(config)
    if not api_key:
        print("✗ API key: missing", file=sys.stderr)
        return 1
    server = require_server(config)
    headers = {"Authorization": f"Bearer {api_key}"}
    try:
        response = requests.post(f"{server}/diagnostics/push-test", headers=headers, timeout=15)
        response.raise_for_status()
        created = response.json()
        task_id = str(created.get("task_id") or "")
        if not task_id:
            raise ValueError("backend did not return a diagnostic task id")
        print(f"✓ Backend: {server}")
        print(f"{'✓' if created.get('device_registered') else '✗'} Device registration: "
              f"{'present' if created.get('device_registered') else 'missing'}")
        print(f"✓ APNs environment: {created.get('environment', 'unknown')}")
        print(f"✓ Diagnostic task: {task_id}")

        diagnostic = {}
        deadline = time.monotonic() + max(1, args.timeout)
        while time.monotonic() < deadline:
            status_response = requests.get(
                f"{server}/diagnostics/push/{task_id}", headers=headers, timeout=10
            )
            status_response.raise_for_status()
            diagnostic = status_response.json().get("diagnostic", {})
            if diagnostic.get("push_status") not in {None, "", "queued"}:
                break
            time.sleep(0.5)
    except (requests.RequestException, ValueError) as error:
        print(f"✗ Push diagnostic failed: {error}", file=sys.stderr)
        return 1

    push_status = diagnostic.get("push_status", "unknown")
    accepted = push_status == "sent" and diagnostic.get("apns_status_code") == 200
    print(f"{'✓' if accepted else '✗'} APNs result: {push_status}")
    if diagnostic.get("apns_status_code") is not None:
        print(f"  HTTP status: {diagnostic['apns_status_code']}")
    if diagnostic.get("apns_reason"):
        print(f"  Reason: {diagnostic['apns_reason']}")
    if diagnostic.get("apns_id"):
        print(f"  APNs ID: {diagnostic['apns_id']}")
    if accepted:
        print("? Apple accepted the push; banner display cannot be confirmed without iOS telemetry.")
        print("  If it is not visible, check iOS notification permissions, Focus, and Scheduled Summary.")
    return 0 if accepted else 1


def cmd_notify(args: argparse.Namespace) -> int:
    from tax.agent_notifications import run_notification_hook

    return run_notification_hook(args.provider, args.event_json)


def cmd_status(args: argparse.Namespace) -> int:
    config = load_config()
    api_key = get_api_key(config)
    if not api_key:
        print(
            "[tax] error: TAX_API_KEY not set. Add to ~/.zshrc: export TAX_API_KEY=*** then source ~/.zshrc",
            file=sys.stderr,
        )
        return 1
    try:
        server = require_server(config)
        r = requests.get(f"{server}/tasks", headers={"Authorization": f"Bearer {api_key}"}, timeout=10)
        r.raise_for_status()
        data = r.json()
        for task in data.get("tasks", []):
            push_status = task.get("push_status") or "unknown"
            print(f"{task['id']} | {push_status:12} | {task['title']} | {task['updated_at']}")
    except ValueError as e:
        print(f"[tax] error: {e}", file=sys.stderr)
        return 1
    except requests.RequestException as e:
        print(f"[tax] failed to fetch status: {e}", file=sys.stderr)
        return 1
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(
        prog="tax", description="Task Agent eXchange — push notifications and remote Orca workspaces"
    )
    subparsers = parser.add_subparsers(dest="command", required=True)

    # config
    p_config = subparsers.add_parser("config", help="Configure tax CLI")
    p_config.add_argument("--server", help="Backend URL, e.g. https://tax.example.com")
    p_config.add_argument("--api-key", help="Backend API key")
    p_config.add_argument("--device-token", help="iPhone device token for APNs")
    p_config.set_defaults(func=cmd_config)

    # e2ee-key
    p_e2ee_key = subparsers.add_parser("e2ee-key", help="Manage the remote workspace encryption key")
    p_e2ee_key.add_argument("action", choices=("generate", "show"))
    p_e2ee_key.set_defaults(func=cmd_e2ee_key)

    # run
    p_run = subparsers.add_parser("run", help="Run a command and send one completion push")
    p_run.add_argument("command", nargs=argparse.REMAINDER, help="Command to run")
    p_run.set_defaults(func=cmd_run)

    # remote-host
    p_remote_host = subparsers.add_parser("remote-host", help="Connect this Mac's Orca Runtime to the E2EE relay")
    p_remote_host.add_argument("--server", help="Backend URL")
    p_remote_host.add_argument("--api-key", help="Backend API key")
    p_remote_host.add_argument("--host-id", required=True)
    p_remote_host.add_argument("--device-id", required=True)
    p_remote_host.add_argument("--orca-pairing-code-file", required=True)
    p_remote_host.set_defaults(func=cmd_remote_host)

    # remote-smoke
    p_remote_smoke = subparsers.add_parser("remote-smoke", help="Test encrypted remote terminal streaming")
    p_remote_smoke.add_argument("--server", help="Backend URL")
    p_remote_smoke.add_argument("--api-key", help="Backend API key")
    p_remote_smoke.add_argument("--host-id", required=True)
    p_remote_smoke.add_argument("--device-id", required=True)
    p_remote_smoke.add_argument("--start-pi", action="store_true")
    p_remote_smoke.set_defaults(func=cmd_remote_smoke)

    # doctor
    p_doctor = subparsers.add_parser("doctor", help="Check tax, backend, and Orca integration")
    p_doctor.set_defaults(func=cmd_doctor)

    # recap
    p_recap = subparsers.add_parser("recap", help="Show recent user/assistant turns from a Pi session")
    p_recap.add_argument("--session-file", help="Pi JSONL session file (defaults to PI_SESSION_FILE)")
    p_recap.add_argument("--turns", type=int, default=4, help="Number of recent turns")
    p_recap.add_argument("--max-chars", type=int, default=240, help="Maximum characters per message")
    p_recap.set_defaults(func=cmd_recap)

    # push-doctor
    p_push_doctor = subparsers.add_parser("push-doctor", help="Test backend-to-APNs push delivery")
    p_push_doctor.add_argument("--timeout", type=int, default=15, help="Seconds to wait for the APNs result")
    p_push_doctor.set_defaults(func=cmd_push_doctor)

    # notify
    p_notify = subparsers.add_parser("notify", help="Handle a Claude Code or Codex completion event")
    p_notify.add_argument("provider", choices=("claude", "codex"))
    p_notify.add_argument("event_json", nargs="?", help="Hook event JSON (defaults to stdin)")
    p_notify.set_defaults(func=cmd_notify)

    # status
    p_status = subparsers.add_parser("status", help="List recent tasks on backend")
    p_status.set_defaults(func=cmd_status)

    args = parser.parse_args()
    try:
        return args.func(args)
    except ValueError as error:
        print(f"[tax] error: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
