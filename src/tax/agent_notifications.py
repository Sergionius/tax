"""Normalize Claude Code and Codex completion events into TAX push requests."""

from __future__ import annotations

import hashlib
import json
import os
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import IO, Any, Mapping, Optional

import requests

BODY_MAX_LENGTH = 180
CONTEXT_MAX_LENGTH = 100_000
LOGS_MAX_LENGTH = 500_000
TRUNCATION_MARKER = "\n… [truncated] …\n"
DEFAULT_TIMEOUT_SECONDS = 10


@dataclass(frozen=True)
class AgentNotification:
    provider: str
    title: str
    body: str
    context: str
    logs: str
    event_key: str


def truncate_payload_text(value: str, max_length: int) -> str:
    if len(value) <= max_length:
        return value
    if max_length <= len(TRUNCATION_MARKER):
        return value[:max_length]
    content_length = max_length - len(TRUNCATION_MARKER)
    head_length = (content_length + 1) // 2
    tail_length = content_length // 2
    return f"{value[:head_length]}{TRUNCATION_MARKER}{value[-tail_length:]}"


def notification_body(value: str, fallback: str) -> str:
    compact = " ".join(value.split())
    if not compact:
        return fallback
    if len(compact) <= BODY_MAX_LENGTH:
        return compact
    return f"{compact[: BODY_MAX_LENGTH - 1].rstrip()}…"


def _string(value: Any) -> str:
    return value.strip() if isinstance(value, str) else ""


def _string_list(value: Any) -> list[str]:
    if not isinstance(value, list):
        return []
    return [item.strip() for item in value if isinstance(item, str) and item.strip()]


def _event_key(provider: str, identifiers: list[str], message: str) -> str:
    raw = "\0".join([provider, *identifiers, message])
    return hashlib.sha256(raw.encode("utf-8")).hexdigest()


def parse_claude_event(event: Mapping[str, Any]) -> AgentNotification:
    message = _string(event.get("last_assistant_message"))
    session_id = _string(event.get("session_id"))
    cwd = _string(event.get("cwd")) or os.getcwd()
    transcript_path = _string(event.get("transcript_path"))
    outcome = "completed" if message else "stopped"
    context = "\n".join(
        line
        for line in (
            "Agent: claude",
            f"Outcome: {outcome}",
            f"Directory: {cwd}",
            f"Session: {session_id}" if session_id else "",
            f"Transcript: {transcript_path}" if transcript_path else "",
        )
        if line
    )
    return AgentNotification(
        provider="claude",
        title=f"claude {outcome}",
        body=notification_body(message, "Claude stopped without a final response"),
        context=context,
        logs=message or "Claude stopped without a final response.",
        event_key=_event_key("claude", [session_id], message),
    )


def parse_codex_event(event: Mapping[str, Any]) -> AgentNotification:
    message = _string(event.get("last-assistant-message")) or _string(event.get("last_assistant_message"))
    inputs = _string_list(event.get("input-messages")) or _string_list(event.get("input_messages"))
    thread_id = _string(event.get("thread-id")) or _string(event.get("thread_id"))
    turn_id = _string(event.get("turn-id")) or _string(event.get("turn_id"))
    cwd = _string(event.get("cwd")) or os.getcwd()
    outcome = "completed" if message else "stopped"
    context = "\n".join(
        line
        for line in (
            "Agent: codex",
            f"Outcome: {outcome}",
            f"Command: {' '.join(inputs)}" if inputs else "",
            f"Directory: {cwd}",
            f"Thread: {thread_id}" if thread_id else "",
            f"Turn: {turn_id}" if turn_id else "",
        )
        if line
    )
    return AgentNotification(
        provider="codex",
        title=f"codex {outcome}",
        body=notification_body(message, "Codex stopped without a final response"),
        context=context,
        logs=message or "Codex stopped without a final response.",
        event_key=_event_key("codex", [thread_id, turn_id], message),
    )


def parse_event(provider: str, raw_event: str) -> AgentNotification:
    try:
        event = json.loads(raw_event)
    except json.JSONDecodeError as error:
        raise ValueError(f"invalid {provider} hook JSON: {error}") from error
    if not isinstance(event, dict):
        raise ValueError(f"invalid {provider} hook JSON: expected an object")
    if provider == "claude":
        return parse_claude_event(event)
    if provider == "codex":
        return parse_codex_event(event)
    raise ValueError(f"unsupported notification provider: {provider}")


def read_hook_event(provider: str, event_json: Optional[str], stdin: IO[str]) -> AgentNotification:
    raw_event = event_json if event_json is not None else stdin.read()
    if not raw_event.strip():
        raise ValueError(f"{provider} hook did not provide an event")
    return parse_event(provider, raw_event)


def default_dedupe_path() -> Path:
    state_home = os.environ.get("XDG_STATE_HOME", "").strip()
    root = Path(state_home).expanduser() if state_home else Path.home() / ".local" / "state"
    return root / "tax" / "notification-events.json"


def _load_recent_keys(path: Path) -> list[str]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return []
    if not isinstance(value, list):
        return []
    return [item for item in value if isinstance(item, str)]


def event_was_sent(path: Path, event_key: str) -> bool:
    return event_key in _load_recent_keys(path)


def remember_sent_event(path: Path, event_key: str) -> None:
    keys = [item for item in _load_recent_keys(path) if item != event_key]
    keys.append(event_key)
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(".tmp")
    temporary.write_text(json.dumps(keys[-100:]), encoding="utf-8")
    temporary.chmod(0o600)
    temporary.replace(path)


def push_payload(notification: AgentNotification, environment: Mapping[str, str]) -> dict[str, str]:
    terminal_handle = environment.get("ORCA_TERMINAL_HANDLE", "").strip()
    worktree_id = (
        environment.get("ORCA_WORKTREE_ID", "").strip()
        or environment.get("ORCA_WORKSPACE_ID", "").strip()
    )
    return {
        "title": notification.title,
        "body": notification.body,
        "context": truncate_payload_text(notification.context, CONTEXT_MAX_LENGTH),
        "logs": truncate_payload_text(notification.logs, LOGS_MAX_LENGTH),
        "source": f"{notification.provider}-hook",
        "agent": notification.provider,
        "app": "tax",
        "host_id": environment.get("TAX_HOST_ID", "").strip() or "mac-main",
        "orca_terminal_handle": terminal_handle,
        "orca_worktree_id": worktree_id,
        "orca_tab_id": environment.get("ORCA_TAB_ID", "").strip(),
        "orca_pane_key": environment.get("ORCA_PANE_KEY", "").strip(),
    }


def run_notification_hook(
    provider: str,
    event_json: Optional[str],
    *,
    stdin: IO[str] = sys.stdin,
    environment: Optional[Mapping[str, str]] = None,
    config: Optional[Mapping[str, str]] = None,
    dedupe_path: Optional[Path] = None,
) -> int:
    """Send one best-effort notification without ever blocking agent shutdown."""
    env = environment if environment is not None else os.environ
    debug = env.get("TAX_PUSH_DEBUG") == "1"
    try:
        notification = read_hook_event(provider, event_json, stdin)
        terminal_handle = env.get("ORCA_TERMINAL_HANDLE", "").strip()
        if not terminal_handle:
            raise ValueError("ORCA_TERMINAL_HANDLE is not set; notification skipped")

        if config is None:
            from tax.cli import get_api_key, get_server, load_config

            loaded_config = load_config()
            server = get_server(loaded_config)
            api_key = get_api_key(loaded_config)
        else:
            server = (config.get("server") or env.get("TAX_SERVER") or "").strip()
            api_key = config.get("api_key") or env.get("TAX_API_KEY") or ""
        if not server or not api_key:
            raise ValueError("TAX server or API key is not configured; notification skipped")
        if not server.startswith(("http://", "https://")):
            raise ValueError(f"TAX server URL {server!r} is not an http(s) URL; notification skipped")
        server = server.rstrip("/")

        path = dedupe_path or default_dedupe_path()
        if event_was_sent(path, notification.event_key):
            return 0

        response = requests.post(
            f"{server}/push",
            json=push_payload(notification, env),
            headers={"Authorization": f"Bearer {api_key}"},
            timeout=DEFAULT_TIMEOUT_SECONDS,
        )
        response.raise_for_status()
        result = response.json()
        if not isinstance(result, dict) or not result.get("task_id"):
            raise ValueError("backend response does not contain task_id")
        remember_sent_event(path, notification.event_key)
        if debug:
            print(f"[tax] {provider} notification sent", file=sys.stderr)
    except (OSError, ValueError, requests.RequestException) as error:
        if debug:
            print(f"[tax] {error}", file=sys.stderr)
    return 0
