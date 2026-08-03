"""Persistent macOS reply agent for tax."""

from __future__ import annotations

import fcntl
import json
import logging
import os
import shutil
import sqlite3
import subprocess
import threading
import time
from collections.abc import Callable
from concurrent.futures import ThreadPoolExecutor
from contextlib import closing
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import IO, Optional

import requests
import uvicorn
from fastapi import FastAPI, HTTPException
from pydantic import BaseModel

from tax.logging_utils import configure_logging, log_event

DEFAULT_PORT = 17373
DEFAULT_POLL_TTL = 30 * 60
DEFAULT_MAX_WORKERS = 16
DEFAULT_IMPORT_INTERVAL = 5.0
DEFAULT_REPLY_POLL_INTERVAL = 5.0
DEFAULT_STATUS_RETRY_INTERVAL = 5.0
DEFAULT_CLEANUP_INTERVAL = 24 * 60 * 60
LEGACY_POLL_BATCH_SIZE = 20
TERMINAL_RETENTION_DAYS = 7
DELIVERABLE_STATUSES = {"reply_received"}
TERMINAL_STATUSES = {"delivered", "delivery_failed", "expired"}
SYNC_STATUSES = {"delivered_pending_sync", "delivery_failed_pending_sync"}
logger = configure_logging("tax-agent")


def now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


def default_state_dir() -> Path:
    root = os.environ.get("XDG_STATE_HOME")
    return Path(root).expanduser() / "tax" if root else Path.home() / ".local" / "state" / "tax"


class WatchedTask(BaseModel):
    task_id: str
    agterm_session_id: str = ""
    agterm_socket: str = ""
    source: str = ""
    agent: str = ""
    app: str = ""


class AgentStore:
    def __init__(self, path: Path):
        self.path = path
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self.init_db()

    def connect(self) -> sqlite3.Connection:
        conn = sqlite3.connect(self.path, timeout=30)
        conn.row_factory = sqlite3.Row
        return conn

    def init_db(self) -> None:
        with closing(self.connect()) as conn, conn:
            conn.execute(
                """
                CREATE TABLE IF NOT EXISTS watched_tasks (
                    task_id TEXT PRIMARY KEY,
                    agterm_session_id TEXT,
                    agterm_socket TEXT,
                    source TEXT,
                    agent TEXT,
                    app TEXT,
                    status TEXT NOT NULL DEFAULT 'pending',
                    reply TEXT,
                    attempts INTEGER NOT NULL DEFAULT 0,
                    last_error TEXT,
                    created_at TEXT NOT NULL,
                    updated_at TEXT NOT NULL
                )
                """
            )
            columns = {row[1] for row in conn.execute("PRAGMA table_info(watched_tasks)")}
            if "agterm_socket" not in columns:
                conn.execute("ALTER TABLE watched_tasks ADD COLUMN agterm_socket TEXT")

    def add(self, task: WatchedTask) -> bool:
        now = now_iso()
        with closing(self.connect()) as conn, conn:
            cursor = conn.execute(
                """
                INSERT OR IGNORE INTO watched_tasks
                (task_id, agterm_session_id, agterm_socket, source, agent, app, status, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, 'pending', ?, ?)
                """,
                (
                    task.task_id,
                    task.agterm_session_id,
                    task.agterm_socket,
                    task.source,
                    task.agent,
                    task.app,
                    now,
                    now,
                ),
            )
            return cursor.rowcount > 0

    def reset(self) -> None:
        with closing(self.connect()) as conn, conn:
            conn.execute("DELETE FROM watched_tasks")
        # VACUUM must run outside the transaction used by DELETE.
        with closing(self.connect()) as conn:
            conn.execute("VACUUM")

    def get(self, task_id: str) -> Optional[sqlite3.Row]:
        with closing(self.connect()) as conn:
            return conn.execute("SELECT * FROM watched_tasks WHERE task_id = ?", (task_id,)).fetchone()

    def list_by_status(self, statuses: set[str]) -> list[sqlite3.Row]:
        placeholders = ", ".join("?" for _ in statuses)
        with closing(self.connect()) as conn:
            return conn.execute(
                f"SELECT * FROM watched_tasks WHERE status IN ({placeholders}) ORDER BY created_at",
                tuple(sorted(statuses)),
            ).fetchall()

    def expire_stale(self, ttl_seconds: int) -> int:
        cutoff = (datetime.now(timezone.utc) - timedelta(seconds=ttl_seconds)).isoformat()
        with closing(self.connect()) as conn, conn:
            cursor = conn.execute(
                "UPDATE watched_tasks SET status = 'expired', updated_at = ?, last_error = NULL "
                "WHERE status IN ('pending', 'waiting_reply') AND created_at < ?",
                (now_iso(), cutoff),
            )
            return cursor.rowcount

    def cleanup_terminal(self, retention_days: int = TERMINAL_RETENTION_DAYS) -> int:
        cutoff = (datetime.now(timezone.utc) - timedelta(days=retention_days)).isoformat()
        with closing(self.connect()) as conn, conn:
            cursor = conn.execute(
                "DELETE FROM watched_tasks "
                "WHERE status IN ('delivered', 'delivery_failed', 'expired') AND updated_at < ?",
                (cutoff,),
            )
            return cursor.rowcount

    def record_reply(self, task: WatchedTask, reply: str) -> str:
        now = now_iso()
        with closing(self.connect()) as conn, conn:
            conn.execute(
                """
                INSERT INTO watched_tasks
                (task_id, agterm_session_id, agterm_socket, source, agent, app, status, reply, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, 'reply_received', ?, ?, ?)
                ON CONFLICT(task_id) DO UPDATE SET
                    agterm_session_id = excluded.agterm_session_id,
                    agterm_socket = CASE WHEN excluded.agterm_socket != '' THEN excluded.agterm_socket ELSE watched_tasks.agterm_socket END,
                    source = excluded.source,
                    agent = excluded.agent,
                    app = excluded.app,
                    status = 'reply_received',
                    reply = excluded.reply,
                    last_error = NULL,
                    updated_at = excluded.updated_at
                WHERE watched_tasks.status NOT IN
                    ('delivering', 'delivered', 'delivery_failed', 'expired',
                     'delivered_pending_sync', 'delivery_failed_pending_sync')
                """,
                (
                    task.task_id,
                    task.agterm_session_id,
                    task.agterm_socket,
                    task.source,
                    task.agent,
                    task.app,
                    reply,
                    now,
                    now,
                ),
            )
            row = conn.execute("SELECT status FROM watched_tasks WHERE task_id = ?", (task.task_id,)).fetchone()
            return row["status"]

    def update(
        self,
        task_id: str,
        status: str,
        *,
        reply: Optional[str] = None,
        error: Optional[str] = None,
        increment_attempts: bool = False,
    ) -> None:
        assignments = ["status = ?", "updated_at = ?", "last_error = ?"]
        values: list[object] = [status, now_iso(), error]
        if reply is not None:
            assignments.append("reply = ?")
            values.append(reply)
        if increment_attempts:
            assignments.append("attempts = attempts + 1")
        values.append(task_id)
        with closing(self.connect()) as conn, conn:
            conn.execute(
                f"UPDATE watched_tasks SET {', '.join(assignments)} WHERE task_id = ?",
                values,
            )


class AgentInstanceLock:
    def __init__(self, path: Path):
        self.path = path
        self._handle: Optional[IO[str]] = None

    def acquire(self) -> bool:
        self.path.parent.mkdir(parents=True, exist_ok=True)
        handle = self.path.open("a+", encoding="utf-8")
        try:
            fcntl.flock(handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            handle.close()
            return False
        self._handle = handle
        return True

    def release(self) -> None:
        if self._handle is None:
            return
        fcntl.flock(self._handle.fileno(), fcntl.LOCK_UN)
        self._handle.close()
        self._handle = None


class TaxAgent:
    def __init__(
        self,
        server: str,
        api_key: str,
        state_dir: Path,
        poll_ttl: int = DEFAULT_POLL_TTL,
        retry_delay: float = 5.0,
        max_workers: int = DEFAULT_MAX_WORKERS,
        device_token: str = "",
        status_events: Optional[set[str]] = None,
        agterm_socket: str = "",
    ):
        self.server = server.rstrip("/")
        self.api_key = api_key
        self.device_token = device_token
        self.status_events = status_events if status_events is not None else {"blocked"}
        self.agterm_socket = agterm_socket
        self.state_dir = state_dir
        self.state_dir.mkdir(parents=True, exist_ok=True)
        self.store = AgentStore(self.state_dir / "agent.db")
        self.fallback_path = self.state_dir / "tasks.jsonl"
        self.poll_ttl = poll_ttl
        self.retry_delay = retry_delay
        self.stop_event = threading.Event()
        self._watching: set[str] = set()
        self._watching_lock = threading.Lock()
        self._importer: Optional[threading.Thread] = None
        self._reply_poller: Optional[threading.Thread] = None
        self._status_monitor: Optional[threading.Thread] = None
        self._status_process: Optional[subprocess.Popen[str]] = None
        self._status_process_lock = threading.Lock()
        self._last_agent_status: dict[str, str] = {}
        self._fallback_offset = 0
        self._next_cleanup_at = time.monotonic() + DEFAULT_CLEANUP_INTERVAL
        self._legacy_poll_offset = 0
        self._started = False
        self._stopped = False
        self._stop_lock = threading.Lock()
        self._executor = ThreadPoolExecutor(max_workers=max_workers, thread_name_prefix="tax-task")

    @property
    def headers(self) -> dict[str, str]:
        return {"Authorization": f"Bearer {self.api_key}"}

    def start(self) -> None:
        if self._started:
            return
        removed = self.store.cleanup_terminal()
        if removed:
            log_event(logger, "terminal_tasks_cleaned", removed=removed)
        self._fail_interrupted_deliveries()
        self.import_fallback()
        self._started = True
        self._importer = threading.Thread(target=self._import_loop, name="tax-fallback-importer", daemon=True)
        self._reply_poller = threading.Thread(target=self._reply_poll_loop, name="tax-reply-poller", daemon=True)
        self._importer.start()
        self._reply_poller.start()
        if self.status_events:
            self._status_monitor = threading.Thread(target=self._status_event_loop, name="tax-status-monitor", daemon=True)
            self._status_monitor.start()

    def stop(self) -> None:
        with self._stop_lock:
            if self._stopped:
                return
            self._stopped = True
            self.stop_event.set()
            with self._status_process_lock:
                if self._status_process is not None and self._status_process.poll() is None:
                    self._status_process.terminate()
            self._executor.shutdown(wait=False, cancel_futures=True)

    def register(self, task: WatchedTask) -> bool:
        task_id = task.task_id.strip()
        if not task_id:
            raise ValueError("task_id is required")
        normalized = task.model_copy(update={"task_id": task_id})
        return self.store.add(normalized)

    def watch(self, task_id: str) -> None:
        if self.stop_event.is_set():
            return
        row = self.store.get(task_id)
        if not row or row["status"] not in DELIVERABLE_STATUSES:
            return
        with self._watching_lock:
            if task_id in self._watching:
                return
            self._watching.add(task_id)
        try:
            self._executor.submit(self._watch_task_guarded, task_id)
        except RuntimeError:
            with self._watching_lock:
                self._watching.discard(task_id)

    def _watch_task_guarded(self, task_id: str) -> None:
        try:
            self._watch_task(task_id)
        except Exception as error:
            log_event(logger, "watcher_failed", level=logging.ERROR, task_id=task_id, error=str(error))
        finally:
            with self._watching_lock:
                self._watching.discard(task_id)

    def _watch_task(self, task_id: str) -> None:
        row = self.store.get(task_id)
        if not row or row["status"] not in DELIVERABLE_STATUSES or not row["reply"]:
            return
        self._deliver_once(task_id, row["reply"])

    def _deliver_once(self, task_id: str, reply: str) -> None:
        row = self.store.get(task_id)
        if not row or self.stop_event.is_set():
            return
        target = row["agterm_session_id"]
        if not target:
            error = "agterm session id is missing"
            self.store.update(task_id, "delivery_failed_pending_sync", error=error, increment_attempts=True)
            if self._mark_backend_status(task_id, "delivery_failed"):
                self.store.update(task_id, "delivery_failed", error=error)
            log_event(logger, "delivery_failed", level=logging.ERROR, task_id=task_id, error=error)
            return
        try:
            self.store.update(task_id, "delivering", error=None)
            socket = row["agterm_socket"] or ""
            if socket:
                self.inject_reply(reply, target, socket)
            else:
                self.inject_reply(reply, target)
        except (OSError, subprocess.SubprocessError) as error:
            self.store.update(
                task_id,
                "delivery_failed_pending_sync",
                error=str(error),
                increment_attempts=True,
            )
            if self._mark_backend_status(task_id, "delivery_failed"):
                self.store.update(task_id, "delivery_failed", error=str(error))
            log_event(
                logger, "delivery_failed", level=logging.ERROR, task_id=task_id, session_id=target, error=str(error)
            )
            return

        self.store.update(task_id, "delivered_pending_sync", error=None)
        if self._mark_backend_status(task_id, "delivered"):
            self.store.update(task_id, "delivered", error=None)
        log_event(logger, "reply_delivered", task_id=task_id, session_id=target)

    def inject_reply(self, reply: str, target: str, socket: str = "") -> None:
        executable = shutil.which("agtermctl")
        if not executable:
            raise FileNotFoundError("agtermctl not found in PATH")
        command = [executable, "session", "type", "--target", target, "--stdin"]
        if socket:
            command.extend(["--socket", socket])
        # The newline submits the reply after inserting it into the original session.
        subprocess.run(
            command,
            input=f"{reply}\n",
            text=True,
            check=True,
            capture_output=True,
            timeout=15,
        )

    def _agterm_command(self, *arguments: str, socket: str = "") -> list[str]:
        executable = shutil.which("agtermctl")
        if not executable:
            raise FileNotFoundError("agtermctl not found in PATH")
        command = [executable, *arguments]
        selected_socket = socket or self.agterm_socket
        if selected_socket:
            command.extend(["--socket", selected_socket])
        return command

    def _session_context(self, event: dict) -> tuple[str, str]:
        window = str(event.get("window") or "")
        session_id = str(event.get("session") or "")
        if not window or not session_id:
            return "", ""
        result = subprocess.run(
            self._agterm_command("tree", "--json", "--window", window),
            text=True,
            check=True,
            capture_output=True,
            timeout=10,
        )
        tree = json.loads(result.stdout).get("result", {}).get("tree", {})
        for workspace in tree.get("workspaces", []):
            for session in workspace.get("sessions", []):
                if session.get("id") == session_id:
                    cwd = str(session.get("cwd") or "")
                    context = f"Workspace: {workspace.get('name', '')}"
                    if cwd:
                        context += f"\nDirectory: {cwd}"
                    foreground = session.get("foreground") or []
                    command = Path(str(foreground[0])).name if foreground else ""
                    return context, command
        return "", ""

    @staticmethod
    def _agent_from_command(command: str) -> str:
        lowered = command.lower()
        for agent in ("pi", "claude", "codex", "opencode", "kimi"):
            if lowered == agent or lowered.startswith(f"{agent}-"):
                return agent
        return "agent"

    def handle_status_event(self, event: dict) -> bool:
        if event.get("kind") != "status":
            return False
        session_id = str(event.get("session") or "").strip()
        payload = event.get("payload") if isinstance(event.get("payload"), dict) else {}
        status = str(payload.get("status") or "").strip().lower()
        if not session_id or not status:
            return False
        previous = self._last_agent_status.get(session_id)
        self._last_agent_status[session_id] = status
        if previous == status or status not in self.status_events:
            return False

        name = str(payload.get("name") or session_id)
        try:
            context, command = self._session_context(event)
        except (OSError, subprocess.SubprocessError, ValueError) as error:
            log_event(logger, "status_context_failed", level=logging.WARNING, session_id=session_id, error=str(error))
            context, command = "", ""
        agent_name = self._agent_from_command(command)
        # Pi's extension sends a richer completed task with prompt and transcript.
        # Keep generic completion for agents that do not have that integration.
        if status == "completed" and agent_name == "pi":
            return False
        body = f"{name} requires attention" if status == "blocked" else f"{name} completed"
        response = requests.post(
            f"{self.server}/push",
            json={
                "device_token": self.device_token,
                "title": f"{agent_name} {status}",
                "body": body,
                "context": context,
                "logs": "",
                "source": "agterm-status",
                "agent": agent_name,
                "app": "tax",
                "agterm_session_id": session_id,
            },
            headers=self.headers,
            timeout=15,
        )
        try:
            response.raise_for_status()
            task_id = str(response.json().get("task_id") or "")
            if not task_id:
                raise ValueError("backend response does not contain task_id")
            self.register(
                WatchedTask(
                    task_id=task_id,
                    agterm_session_id=session_id,
                    agterm_socket=self.agterm_socket,
                    source="agterm-status",
                    agent=agent_name,
                    app="tax",
                )
            )
            log_event(logger, "status_push_sent", task_id=task_id, session_id=session_id, status=status)
            return True
        finally:
            response.close()

    def _status_event_loop(self) -> None:
        while not self.stop_event.is_set():
            process = None
            try:
                process = subprocess.Popen(
                    self._agterm_command("events", "--json", "--kind", "status"),
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    text=True,
                )
                with self._status_process_lock:
                    self._status_process = process
                if process.stdout is None:
                    raise RuntimeError("agterm event stream has no stdout")
                for line in process.stdout:
                    if self.stop_event.is_set():
                        break
                    try:
                        self.handle_status_event(json.loads(line))
                    except (requests.RequestException, ValueError) as error:
                        log_event(logger, "status_event_failed", level=logging.WARNING, error=str(error))
            except (OSError, subprocess.SubprocessError, RuntimeError) as error:
                log_event(logger, "status_monitor_failed", level=logging.WARNING, error=str(error))
            finally:
                if process is not None and process.poll() is None:
                    process.terminate()
                with self._status_process_lock:
                    if self._status_process is process:
                        self._status_process = None
            self.stop_event.wait(DEFAULT_STATUS_RETRY_INTERVAL)

    def _mark_backend_status(self, task_id: str, status: str) -> bool:
        response = None
        try:
            response = requests.post(
                f"{self.server}/task/{task_id}/update",
                json={"status": status},
                headers=self.headers,
                timeout=10,
            )
            response.raise_for_status()
            return bool(response.json().get("ok"))
        except (requests.RequestException, ValueError) as error:
            # Keep a local pending-sync state so a backend outage can never cause duplicate injection.
            log_event(
                logger,
                "backend_status_sync_failed",
                level=logging.WARNING,
                task_id=task_id,
                status=status,
                error=str(error),
            )
            return False
        finally:
            if response is not None:
                response.close()

    def _fail_interrupted_deliveries(self) -> None:
        for row in self.store.list_by_status({"delivering"}):
            self.store.update(
                row["task_id"],
                "delivery_failed_pending_sync",
                error="agent stopped while delivery result was unknown",
                increment_attempts=True,
            )

    def _sync_local_terminal_status(self, row: sqlite3.Row) -> None:
        status = row["status"]
        if status == "expired":
            backend_status = "expired"
        else:
            backend_status = "delivered" if status in {"delivered", "delivered_pending_sync"} else "delivery_failed"
        if self._mark_backend_status(row["task_id"], backend_status):
            self.store.update(row["task_id"], backend_status, error=row["last_error"])

    def _backend_reply_is_stale(self, item: dict[object, object]) -> bool:
        updated_at = item.get("updated_at")
        if not isinstance(updated_at, str) or not updated_at:
            return False
        try:
            timestamp = datetime.fromisoformat(updated_at.replace("Z", "+00:00"))
        except ValueError:
            return False
        if timestamp.tzinfo is None:
            timestamp = timestamp.replace(tzinfo=timezone.utc)
        return timestamp < datetime.now(timezone.utc) - timedelta(seconds=self.poll_ttl)

    def _schedule_backend_tasks(self, tasks: list[object]) -> int:
        scheduled = 0
        for item in tasks:
            if not isinstance(item, dict):
                continue
            task_id = str(item.get("id") or "").strip()
            reply = item.get("reply")
            if not task_id or not isinstance(reply, str) or not reply:
                continue

            row = self.store.get(task_id)
            if row and row["status"] in TERMINAL_STATUSES | SYNC_STATUSES:
                self._sync_local_terminal_status(row)
                continue
            with self._watching_lock:
                if task_id in self._watching:
                    continue

            task = WatchedTask(
                task_id=task_id,
                agterm_session_id=str(item.get("agterm_session_id") or ""),
                agterm_socket=str(row["agterm_socket"] or "") if row else "",
                source=str(item.get("source") or ""),
                agent=str(item.get("agent") or ""),
                app=str(item.get("app") or ""),
            )
            if self._backend_reply_is_stale(item):
                self.store.record_reply(task, reply)
                self.store.update(task_id, "expired")
                self._sync_local_terminal_status(self.store.get(task_id))
                log_event(logger, "stale_reply_expired", task_id=task_id, ttl_seconds=self.poll_ttl)
                continue
            if self.store.record_reply(task, reply) == "reply_received":
                self.watch(task_id)
                scheduled += 1
        return scheduled

    def _poll_legacy_replies(self) -> int:
        rows = self.store.list_by_status({"pending", "waiting_reply"})
        if not rows:
            self._legacy_poll_offset = 0
            return 0

        start = self._legacy_poll_offset % len(rows)
        count = min(LEGACY_POLL_BATCH_SIZE, len(rows))
        selected = [rows[(start + index) % len(rows)] for index in range(count)]
        self._legacy_poll_offset = (start + count) % len(rows)
        tasks = []
        for row in selected:
            response = None
            try:
                response = requests.get(
                    f"{self.server}/task/{row['task_id']}/reply",
                    params={"wait": "false"},
                    headers=self.headers,
                    timeout=10,
                )
                response.raise_for_status()
                payload = response.json()
                reply = payload.get("reply") if payload.get("ok") else None
                if reply:
                    tasks.append(
                        {
                            "id": row["task_id"],
                            "reply": reply,
                            "agterm_session_id": row["agterm_session_id"],
                            "source": row["source"],
                            "agent": row["agent"],
                            "app": row["app"],
                        }
                    )
            finally:
                if response is not None:
                    response.close()
        return self._schedule_backend_tasks(tasks)

    def poll_backend_replies(self) -> int:
        response = None
        try:
            response = requests.get(f"{self.server}/replies", headers=self.headers, timeout=15)
            if response.status_code == 404:
                return self._poll_legacy_replies()
            response.raise_for_status()
            payload = response.json()
            tasks = payload.get("tasks", [])
            if not isinstance(tasks, list):
                raise ValueError("backend replies payload has no task list")
            return self._schedule_backend_tasks(tasks)
        finally:
            if response is not None:
                response.close()

    def _reply_poll_loop(self) -> None:
        delay = 0.0
        while not self.stop_event.wait(delay):
            try:
                if time.monotonic() >= self._next_cleanup_at:
                    removed = self.store.cleanup_terminal()
                    if removed:
                        log_event(logger, "terminal_tasks_cleaned", removed=removed)
                    self._next_cleanup_at = time.monotonic() + DEFAULT_CLEANUP_INTERVAL
                expired = self.store.expire_stale(self.poll_ttl)
                if expired:
                    log_event(logger, "pending_tasks_expired", count=expired, ttl_seconds=self.poll_ttl)
                self.poll_backend_replies()
            except (requests.RequestException, ValueError) as error:
                log_event(logger, "reply_poll_failed", level=logging.WARNING, error=str(error))
                delay = self.retry_delay
            except Exception as error:
                log_event(logger, "reply_poll_unexpected_failure", level=logging.ERROR, error=str(error))
                delay = self.retry_delay
            else:
                delay = DEFAULT_REPLY_POLL_INTERVAL

    def import_fallback(self) -> int:
        if not self.fallback_path.exists():
            return 0
        imported = 0
        try:
            with self.fallback_path.open("rb") as queue:
                size = os.fstat(queue.fileno()).st_size
                if size < self._fallback_offset:
                    self._fallback_offset = 0
                queue.seek(self._fallback_offset)
                data = queue.read()
        except OSError as error:
            log_event(logger, "fallback_read_failed", level=logging.WARNING, error=str(error))
            return 0

        newline = data.rfind(b"\n")
        if newline < 0:
            return 0
        complete = data[: newline + 1]
        self._fallback_offset += newline + 1

        for raw_line in complete.splitlines():
            if not raw_line.strip():
                continue
            try:
                task = WatchedTask.model_validate(json.loads(raw_line))
                if self.store.add(task):
                    imported += 1
                    self.watch(task.task_id)
            except (ValueError, json.JSONDecodeError, UnicodeDecodeError) as error:
                log_event(logger, "fallback_entry_ignored", level=logging.WARNING, error=str(error))
        return imported

    def _import_loop(self) -> None:
        delay = DEFAULT_IMPORT_INTERVAL
        while not self.stop_event.wait(delay):
            try:
                self.import_fallback()
            except Exception as error:
                log_event(logger, "fallback_import_failed", level=logging.ERROR, error=str(error))
                delay = self.retry_delay
            else:
                delay = DEFAULT_IMPORT_INTERVAL


def create_app(agent: TaxAgent, shutdown_callback: Optional[Callable[[], None]] = None) -> FastAPI:
    app = FastAPI(title="tax-agent", docs_url=None, redoc_url=None)

    @app.get("/health")
    async def health():
        return {"ok": True, "watching": len(agent._watching)}

    @app.post("/task")
    async def register_task(task: WatchedTask):
        try:
            created = agent.register(task)
        except ValueError as error:
            raise HTTPException(status_code=400, detail=str(error)) from error
        return {"ok": True, "created": created, "task_id": task.task_id}

    @app.post("/shutdown")
    async def shutdown():
        agent.stop()
        if shutdown_callback:
            shutdown_callback()
        return {"ok": True}

    return app


def run_agent_server(
    server: str,
    api_key: str,
    port: int = DEFAULT_PORT,
    state_dir: Optional[Path] = None,
    poll_ttl: int = DEFAULT_POLL_TTL,
    device_token: str = "",
    status_events: Optional[set[str]] = None,
    agterm_socket: str = "",
) -> int:
    if not api_key:
        log_event(logger, "startup_failed", level=logging.ERROR, reason="api_key_not_configured")
        return 1
    resolved_state_dir = state_dir or default_state_dir()
    instance_lock = AgentInstanceLock(resolved_state_dir / "agent.lock")
    if not instance_lock.acquire():
        log_event(logger, "startup_failed", level=logging.ERROR, reason="already_running")
        return 1

    agent: Optional[TaxAgent] = None
    try:
        agent = TaxAgent(
            server,
            api_key,
            resolved_state_dir,
            poll_ttl=poll_ttl,
            device_token=device_token,
            status_events=status_events,
            agterm_socket=agterm_socket,
        )
        agent.start()
        server_holder: dict[str, uvicorn.Server] = {}

        def request_shutdown() -> None:
            running_server = server_holder.get("server")
            if running_server:
                running_server.should_exit = True

        app = create_app(agent, request_shutdown)
        config = uvicorn.Config(app, host="127.0.0.1", port=port, log_level="info")
        running_server = uvicorn.Server(config)
        server_holder["server"] = running_server
        log_event(logger, "listening", address=f"http://127.0.0.1:{port}")
        running_server.run()
        return 0
    finally:
        if agent is not None:
            agent.stop()
        instance_lock.release()
