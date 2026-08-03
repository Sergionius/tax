import argparse
import json
import os
import shutil
import subprocess
import sys
import time
from pathlib import Path
from typing import Optional

import requests

DEFAULT_SERVER = "https://tax.138-249-127-23.nip.io"
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
    return config.get("server", os.environ.get("TAX_SERVER", DEFAULT_SERVER))


def get_api_key(config: dict) -> str:
    return config.get("api_key", os.environ.get("TAX_API_KEY", ""))


def get_device_token(config: dict) -> str:
    return config.get("device_token", os.environ.get("TAX_DEVICE_TOKEN", ""))


def get_headers(config: dict) -> dict:
    return {"Authorization": f"Bearer {get_api_key(config)}"}


def send_push(
    server: str, api_key: str, device_token: str, title: str, body: str, context: str = "", logs: str = ""
) -> dict:
    payload = {
        "device_token": device_token,
        "title": title,
        "body": body,
        "context": context,
        "logs": logs,
    }
    r = requests.post(f"{server}/push", json=payload, headers={"Authorization": f"Bearer {api_key}"}, timeout=30)
    r.raise_for_status()
    return r.json()


def poll_reply(server: str, api_key: str, task_id: str, timeout: int = 60) -> Optional[str]:
    """Long-poll for reply from iPhone."""
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            r = requests.get(
                f"{server}/task/{task_id}/reply",
                params={"wait": "true"},
                headers={"Authorization": f"Bearer {api_key}"},
                timeout=35,
            )
            r.raise_for_status()
            data = r.json()
            if data.get("ok") and data.get("reply"):
                return data["reply"]
        except requests.exceptions.ReadTimeout:
            continue
        except requests.exceptions.RequestException as e:
            print(f"[tax] poll error: {e}", file=sys.stderr)
            time.sleep(5)
    return None


def send_to_agterm(value: str, target: str = "active") -> None:
    """Insert and submit text in an agterm session."""
    executable = shutil.which("agtermctl")
    if not executable:
        print("[tax] agtermctl not found in PATH", file=sys.stderr)
        return
    subprocess.run(
        [executable, "session", "type", "--target", target, "--stdin"],
        input=f"{value}\n",
        text=True,
        check=False,
    )


def run_agent(argv: list[str], detach: bool = False) -> int:
    config = load_config()
    server = get_server(config)
    api_key = get_api_key(config)
    device_token = get_device_token(config)

    if not api_key:
        print(
            "[tax] error: TAX_API_KEY not set. Add to ~/.zshrc: export TAX_API_KEY=*** then source ~/.zshrc",
            file=sys.stderr,
        )
        return 1

    if not argv:
        print("[tax] error: no command to run", file=sys.stderr)
        return 1

    # device_token is required only when expecting a real push
    if not device_token:
        print("[tax] warning: device_token not configured; task will be stored but no push sent", file=sys.stderr)

    # Run the agent and capture output
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

    exit_code = proc.returncode
    logs = "\n".join(output_lines[-500:])  # last 500 lines

    # Send push
    status = "completed" if exit_code == 0 else "failed"
    title = f"pi {status}"
    body = f"exit code {exit_code}"
    context = f"Command: {' '.join(argv)}"

    try:
        resp = send_push(server, api_key, device_token, title, body, context=context, logs=logs)
        task_id = resp.get("task_id")
        if not task_id:
            print("[tax] backend did not return task_id", file=sys.stderr)
            return exit_code
        print(f"[tax] push sent, task_id={task_id}")
    except requests.RequestException as e:
        print(f"[tax] failed to send push: {e}", file=sys.stderr)
        return exit_code

    if detach:
        print("[tax] detached; reply ignored")
        return exit_code

    # Poll for reply
    print("[tax] waiting for reply from iPhone...")
    reply = poll_reply(server, api_key, task_id, timeout=300)
    if reply:
        print(f"[tax] reply received: {reply}")
        send_to_agterm(reply)
    else:
        print("[tax] no reply received within timeout")

    return exit_code


def cmd_config(args: argparse.Namespace) -> int:
    config = load_config()
    if args.server:
        config["server"] = args.server
    if args.api_key:
        config["api_key"] = args.api_key
    if args.device_token:
        config["device_token"] = args.device_token
    if getattr(args, "status_events", None) is not None:
        config["status_events"] = args.status_events
    save_config(config)
    safe_config = {**config}
    if safe_config.get("api_key"):
        safe_config["api_key"] = "***"
    if safe_config.get("device_token"):
        safe_config["device_token"] = "***"
    print(json.dumps(safe_config, indent=2))
    return 0


def cmd_run(args: argparse.Namespace) -> int:
    return run_agent(args.command, detach=args.detach)


def cmd_agent(args: argparse.Namespace) -> int:
    from tax.agent import run_agent_server

    config = load_config()
    raw_events = args.status_events if args.status_events is not None else config.get("status_events", "blocked")
    status_events = {item.strip().lower() for item in str(raw_events).split(",") if item.strip()}
    unknown = status_events - {"blocked", "completed"}
    if unknown:
        raise ValueError(f"unknown status events: {', '.join(sorted(unknown))}")
    return run_agent_server(
        server=args.server or get_server(config),
        api_key=args.api_key or get_api_key(config),
        port=args.port,
        state_dir=Path(args.state_dir).expanduser() if args.state_dir else None,
        poll_ttl=args.poll_ttl,
        device_token=get_device_token(config),
        status_events=status_events,
        agterm_socket=args.agterm_socket or os.environ.get("AGTERM_SOCKET", ""),
    )


def _doctor_check(name: str, ok: bool, detail: str) -> bool:
    print(f"{'✓' if ok else '✗'} {name}: {detail}")
    return ok


def cmd_doctor(args: argparse.Namespace) -> int:
    config = load_config()
    required_ok = True
    agtermctl = shutil.which("agtermctl")
    required_ok &= _doctor_check("agtermctl", bool(agtermctl), agtermctl or "not found in PATH")

    socket = args.agterm_socket or os.environ.get("AGTERM_SOCKET", "")
    if agtermctl:
        command = [agtermctl, "tree", "--json"]
        if socket:
            command.extend(["--socket", socket])
        try:
            result = subprocess.run(command, check=True, capture_output=True, text=True, timeout=5)
            payload = json.loads(result.stdout)
            workspaces = len(payload.get("result", {}).get("tree", {}).get("workspaces", []))
            required_ok &= _doctor_check("agterm control", True, f"connected, {workspaces} workspace(s)")
        except (OSError, subprocess.SubprocessError, ValueError) as error:
            required_ok &= _doctor_check("agterm control", False, str(error))

    api_key = get_api_key(config)
    required_ok &= _doctor_check("API key", bool(api_key), "configured" if api_key else "missing")
    if api_key:
        try:
            response = requests.get(f"{get_server(config).rstrip('/')}/health", headers=get_headers(config), timeout=5)
            response.raise_for_status()
            _doctor_check("backend", True, get_server(config))
        except requests.RequestException as error:
            required_ok &= _doctor_check("backend", False, str(error))

    try:
        response = requests.get("http://127.0.0.1:17373/health", timeout=2)
        response.raise_for_status()
        health = response.json()
        _doctor_check("tax-agent", True, f"running, watching {health.get('watching', 0)} task(s)")
    except (requests.RequestException, ValueError) as error:
        required_ok &= _doctor_check("tax-agent", False, str(error))

    hook = Path.home() / ".config" / "agterm" / "agent-status" / "agterm-agent-status.sh"
    print(f"{'✓' if hook.is_file() else '-'} agent status hooks: {hook if hook.is_file() else 'not installed (optional)'}")
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


def cmd_status(args: argparse.Namespace) -> int:
    config = load_config()
    server = get_server(config)
    api_key = get_api_key(config)
    if not api_key:
        print(
            "[tax] error: TAX_API_KEY not set. Add to ~/.zshrc: export TAX_API_KEY=*** then source ~/.zshrc",
            file=sys.stderr,
        )
        return 1
    try:
        r = requests.get(f"{server}/tasks", headers={"Authorization": f"Bearer {api_key}"}, timeout=10)
        r.raise_for_status()
        data = r.json()
        for task in data.get("tasks", []):
            print(f"{task['id']} | {task['status']:12} | {task['title']} | {task['updated_at']}")
    except requests.RequestException as e:
        print(f"[tax] failed to fetch status: {e}", file=sys.stderr)
        return 1
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(
        prog="tax", description="Task Agent eXchange — push and remote reply for AI agents"
    )
    subparsers = parser.add_subparsers(dest="command", required=True)

    # config
    p_config = subparsers.add_parser("config", help="Configure tax CLI")
    p_config.add_argument("--server", help="Backend URL, e.g. https://tax.138-249-127-23.nip.io")
    p_config.add_argument("--api-key", help="Backend API key")
    p_config.add_argument("--device-token", help="iPhone device token for APNs")
    p_config.add_argument("--status-events", help="agterm statuses to push: blocked,completed; empty disables")
    p_config.set_defaults(func=cmd_config)

    # run
    p_run = subparsers.add_parser("run", help="Run a command and notify iPhone on completion")
    p_run.add_argument("command", nargs=argparse.REMAINDER, help="Command to run")
    p_run.add_argument("--detach", action="store_true", help="Do not wait for reply")
    p_run.set_defaults(func=cmd_run)

    # agent
    p_agent = subparsers.add_parser("agent", help="Run the background reply bridge for pi and agterm")
    p_agent.add_argument("--server", help="Backend URL (defaults to tax config or TAX_SERVER)")
    p_agent.add_argument("--api-key", help="Backend API key (defaults to tax config or TAX_API_KEY)")
    p_agent.add_argument("--port", type=int, default=17373, help="Loopback HTTP port (default: 17373)")
    p_agent.add_argument("--state-dir", help="Persistent state directory")
    p_agent.add_argument(
        "--poll-ttl",
        type=int,
        default=1800,
        help="Expire unanswered tasks after this many seconds (default: 1800)",
    )
    p_agent.add_argument(
        "--status-events",
        help="Comma-separated agterm statuses to push: blocked,completed; empty disables monitoring",
    )
    p_agent.add_argument("--agterm-socket", help="Control socket for status monitoring")
    p_agent.set_defaults(func=cmd_agent)

    # doctor
    p_doctor = subparsers.add_parser("doctor", help="Check tax, backend, and agterm integration")
    p_doctor.add_argument("--agterm-socket", help="Control socket to check")
    p_doctor.set_defaults(func=cmd_doctor)

    # recap
    p_recap = subparsers.add_parser("recap", help="Show recent user/assistant turns from a Pi session")
    p_recap.add_argument("--session-file", help="Pi JSONL session file (defaults to PI_SESSION_FILE)")
    p_recap.add_argument("--turns", type=int, default=4, help="Number of recent turns")
    p_recap.add_argument("--max-chars", type=int, default=240, help="Maximum characters per message")
    p_recap.set_defaults(func=cmd_recap)

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
