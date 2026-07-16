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
    if CONFIG_PATH.exists():
        return json.loads(CONFIG_PATH.read_text())
    return {}


def save_config(config: dict) -> None:
    CONFIG_PATH.parent.mkdir(parents=True, exist_ok=True)
    CONFIG_PATH.write_text(json.dumps(config, indent=2))


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
    save_config(config)
    print(json.dumps(config, indent=2))
    return 0


def cmd_run(args: argparse.Namespace) -> int:
    return run_agent(args.command, detach=args.detach)


def cmd_agent(args: argparse.Namespace) -> int:
    from tax.agent import run_agent_server

    config = load_config()
    return run_agent_server(
        server=args.server or get_server(config),
        api_key=args.api_key or get_api_key(config),
        port=args.port,
        state_dir=Path(args.state_dir).expanduser() if args.state_dir else None,
        poll_ttl=args.poll_ttl,
    )


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
    p_agent.add_argument("--poll-ttl", type=int, default=86400, help="Reply polling lifetime in seconds")
    p_agent.set_defaults(func=cmd_agent)

    # status
    p_status = subparsers.add_parser("status", help="List recent tasks on backend")
    p_status.set_defaults(func=cmd_status)

    args = parser.parse_args()
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
