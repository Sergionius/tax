"""Persistent macOS reply agent for tax."""

from __future__ import annotations

import json
import os
import shutil
import sqlite3
import subprocess
import threading
import time
from datetime import datetime, timezone
from pathlib import Path
from collections.abc import Callable
from typing import Optional

import requests
import uvicorn
from fastapi import FastAPI, HTTPException
from pydantic import BaseModel

DEFAULT_PORT = 17373
DEFAULT_POLL_TTL = 24 * 60 * 60


def now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


def default_state_dir() -> Path:
    root = os.environ.get("XDG_STATE_HOME")
    return Path(root).expanduser() / "tax" if root else Path.home() / ".local" / "state" / "tax"


class WatchedTask(BaseModel):
    task_id: str
    agterm_session_id: str = ""
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
        with self.connect() as conn:
            conn.execute(
                """
                CREATE TABLE IF NOT EXISTS watched_tasks (
                    task_id TEXT PRIMARY KEY,
                    agterm_session_id TEXT,
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

    def add(self, task: WatchedTask) -> bool:
        now = now_iso()
        with self.connect() as conn:
            cursor = conn.execute(
                """
                INSERT OR IGNORE INTO watched_tasks
                (task_id, agterm_session_id, source, agent, app, status, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, 'pending', ?, ?)
                """,
                (
                    task.task_id,
                    task.agterm_session_id,
                    task.source,
                    task.agent,
                    task.app,
                    now,
                    now,
                ),
            )
            return cursor.rowcount > 0

    def unfinished(self) -> list[sqlite3.Row]:
        with self.connect() as conn:
            return conn.execute(
                "SELECT * FROM watched_tasks WHERE status != 'delivered' ORDER BY created_at"
            ).fetchall()

    def get(self, task_id: str) -> Optional[sqlite3.Row]:
        with self.connect() as conn:
            return conn.execute("SELECT * FROM watched_tasks WHERE task_id = ?", (task_id,)).fetchone()

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
        with self.connect() as conn:
            conn.execute(
                f"UPDATE watched_tasks SET {', '.join(assignments)} WHERE task_id = ?",
                values,
            )


class TaxAgent:
    def __init__(
        self,
        server: str,
        api_key: str,
        state_dir: Path,
        poll_ttl: int = DEFAULT_POLL_TTL,
        retry_delay: float = 5.0,
    ):
        self.server = server.rstrip("/")
        self.api_key = api_key
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

    @property
    def headers(self) -> dict[str, str]:
        return {"Authorization": f"Bearer {self.api_key}"}

    def start(self) -> None:
        self.import_fallback()
        for row in self.store.unfinished():
            self.watch(row["task_id"])
        self._importer = threading.Thread(target=self._import_loop, name="tax-fallback-importer", daemon=True)
        self._importer.start()

    def stop(self) -> None:
        self.stop_event.set()

    def register(self, task: WatchedTask) -> bool:
        task_id = task.task_id.strip()
        if not task_id:
            raise ValueError("task_id is required")
        normalized = task.model_copy(update={"task_id": task_id})
        created = self.store.add(normalized)
        self.watch(task_id)
        return created

    def watch(self, task_id: str) -> None:
        with self._watching_lock:
            if task_id in self._watching:
                return
            self._watching.add(task_id)
        threading.Thread(target=self._watch_task, args=(task_id,), name=f"tax-task-{task_id[:8]}", daemon=True).start()

    def _watch_task(self, task_id: str) -> None:
        try:
            row = self.store.get(task_id)
            if not row:
                return
            reply = row["reply"]
            if reply:
                self._deliver_until_done(task_id, reply)
                return

            created = datetime.fromisoformat(row["created_at"]).timestamp()
            deadline = created + self.poll_ttl
            self.store.update(task_id, "waiting_reply")

            while not self.stop_event.is_set() and time.time() < deadline:
                try:
                    response = requests.get(
                        f"{self.server}/task/{task_id}/reply",
                        params={"wait": "true"},
                        headers=self.headers,
                        timeout=35,
                    )
                    response.raise_for_status()
                    payload = response.json()
                    reply = payload.get("reply") if payload.get("ok") else None
                    if reply:
                        self.store.update(task_id, "reply_received", reply=reply)
                        self._deliver_until_done(task_id, reply)
                        return
                except requests.exceptions.ReadTimeout:
                    continue
                except (requests.RequestException, ValueError) as error:
                    self.store.update(task_id, "waiting_reply", error=str(error), increment_attempts=True)
                    self.stop_event.wait(self.retry_delay)

            if not self.stop_event.is_set():
                self.store.update(task_id, "expired", error="reply polling TTL expired")
        finally:
            with self._watching_lock:
                self._watching.discard(task_id)

    def _deliver_until_done(self, task_id: str, reply: str) -> None:
        while not self.stop_event.is_set():
            row = self.store.get(task_id)
            if not row:
                return
            try:
                self.inject_reply(reply, row["agterm_session_id"] or "active")
                self.store.update(task_id, "delivered", error=None)
                self._mark_backend_delivered(task_id)
                print(f"[tax-agent] delivered task_id={task_id} target={row['agterm_session_id'] or 'active'}")
                return
            except (OSError, subprocess.SubprocessError) as error:
                self.store.update(task_id, "delivery_failed", error=str(error), increment_attempts=True)
                print(f"[tax-agent] delivery failed task_id={task_id}: {error}")
                self.stop_event.wait(self.retry_delay)

    def inject_reply(self, reply: str, target: str) -> None:
        executable = shutil.which("agtermctl")
        if not executable:
            raise FileNotFoundError("agtermctl not found in PATH")
        # The newline submits the reply after inserting it into the original session.
        subprocess.run(
            [executable, "session", "type", "--target", target, "--stdin"],
            input=f"{reply}\n",
            text=True,
            check=True,
            capture_output=True,
            timeout=15,
        )

    def _mark_backend_delivered(self, task_id: str) -> None:
        try:
            response = requests.post(
                f"{self.server}/task/{task_id}/update",
                json={"status": "delivered"},
                headers=self.headers,
                timeout=10,
            )
            response.raise_for_status()
        except requests.RequestException as error:
            # Never inject a reply twice just because the optional status update failed.
            print(f"[tax-agent] backend status update failed task_id={task_id}: {error}")

    def import_fallback(self) -> int:
        if not self.fallback_path.exists():
            return 0
        imported = 0
        try:
            lines = self.fallback_path.read_text(encoding="utf-8").splitlines()
        except OSError as error:
            print(f"[tax-agent] fallback read failed: {error}")
            return 0
        for line in lines:
            if not line.strip():
                continue
            try:
                task = WatchedTask.model_validate(json.loads(line))
                if self.store.add(task):
                    imported += 1
                self.watch(task.task_id)
            except (ValueError, json.JSONDecodeError) as error:
                print(f"[tax-agent] ignored invalid fallback entry: {error}")
        return imported

    def _import_loop(self) -> None:
        while not self.stop_event.wait(5):
            self.import_fallback()


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
) -> int:
    if not api_key:
        print("[tax-agent] error: TAX_API_KEY is not configured")
        return 1
    agent = TaxAgent(server, api_key, state_dir or default_state_dir(), poll_ttl=poll_ttl)
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
    print(f"[tax-agent] listening on http://127.0.0.1:{port}")
    try:
        running_server.run()
    finally:
        agent.stop()
    return 0
