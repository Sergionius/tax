"""SQLite setup and connection helpers for the tax backend."""

from __future__ import annotations

import os
import sqlite3
from datetime import datetime, timedelta, timezone


def connect(path: str) -> sqlite3.Connection:
    conn = sqlite3.connect(path)
    conn.row_factory = sqlite3.Row
    return conn


def _add_missing_columns(conn: sqlite3.Connection, table: str, columns: dict[str, str]) -> None:
    existing = {row[1] for row in conn.execute(f"PRAGMA table_info({table})")}
    for name, sql_type in columns.items():
        if name not in existing:
            conn.execute(f"ALTER TABLE {table} ADD COLUMN {name} {sql_type}")


def initialize(path: str) -> None:
    db_dir = os.path.dirname(path)
    if db_dir:
        os.makedirs(db_dir, exist_ok=True)
    conn = sqlite3.connect(path)
    try:
        conn.execute("""
            CREATE TABLE IF NOT EXISTS tasks (
                id TEXT PRIMARY KEY,
                device_token TEXT NOT NULL,
                title TEXT,
                body TEXT,
                context TEXT,
                logs TEXT,
                source TEXT,
                agent TEXT,
                app TEXT,
                orca_terminal_handle TEXT,
                orca_worktree_id TEXT,
                orca_tab_id TEXT,
                orca_pane_key TEXT,
                push_status TEXT,
                push_attempted_at TEXT,
                push_environment TEXT,
                apns_status_code INTEGER,
                apns_reason TEXT,
                apns_id TEXT,
                created_at TEXT,
                updated_at TEXT
            )
        """)
        conn.execute("""
            CREATE TABLE IF NOT EXISTS device_tokens (
                token TEXT PRIMARY KEY,
                preferences TEXT,
                created_at TEXT,
                updated_at TEXT
            )
        """)
        _add_missing_columns(
            conn,
            "tasks",
            {
                "source": "TEXT",
                "agent": "TEXT",
                "app": "TEXT",
                "orca_terminal_handle": "TEXT",
                "orca_worktree_id": "TEXT",
                "orca_tab_id": "TEXT",
                "orca_pane_key": "TEXT",
                "push_status": "TEXT",
                "push_attempted_at": "TEXT",
                "push_environment": "TEXT",
                "apns_status_code": "INTEGER",
                "apns_reason": "TEXT",
                "apns_id": "TEXT",
            },
        )
        _add_missing_columns(conn, "device_tokens", {"preferences": "TEXT"})
        conn.commit()
    finally:
        conn.close()


def _parse_utc(value: str | None) -> datetime | None:
    """Parse a task timestamp and normalize it to UTC; None when unparseable."""
    if not value:
        return None
    try:
        parsed = datetime.fromisoformat(value)
    except ValueError:
        return None
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=timezone.utc)
    return parsed.astimezone(timezone.utc)


def purge_agent_content(conn: sqlite3.Connection) -> int:
    """Replace stored context/logs with empty strings; returns rows changed."""
    cursor = conn.execute(
        "UPDATE tasks SET context = '', logs = '' "
        "WHERE IFNULL(context, '') != '' OR IFNULL(logs, '') != ''"
    )
    return cursor.rowcount


def delete_expired_tasks(
    conn: sqlite3.Connection, retention_days: int, *, now: datetime | None = None
) -> int:
    """Delete tasks whose created_at (UTC) is strictly older than the retention window.

    Device registrations and the physical schema are left untouched. Rows with
    unparseable timestamps are kept rather than guessed about.
    """
    cutoff = (now or datetime.now(timezone.utc)) - timedelta(days=retention_days)
    rows = conn.execute("SELECT id, created_at FROM tasks").fetchall()
    expired = []
    for row in rows:
        created = _parse_utc(row["created_at"])
        if created is not None and created < cutoff:
            expired.append((row["id"],))
    if expired:
        conn.executemany("DELETE FROM tasks WHERE id = ?", expired)
    return len(expired)


def run_startup_cleanup(
    path: str,
    *,
    store_agent_content: bool,
    retention_days: int,
    now: datetime | None = None,
) -> dict[str, int]:
    """Startup maintenance in a single short transaction.

    Purges stored agent content when storage is disabled and deletes tasks
    beyond the retention window. Opens and closes its own connection; raises
    on failure so callers can treat it as a startup error.
    """
    conn = connect(path)
    try:
        with conn:
            purged = 0 if store_agent_content else purge_agent_content(conn)
            deleted = delete_expired_tasks(conn, retention_days, now=now)
        return {"purged_tasks": purged, "deleted_tasks": deleted}
    finally:
        conn.close()


def run_retention_cleanup(
    path: str, *, retention_days: int, now: datetime | None = None
) -> int:
    """Periodic retention cleanup.

    Uses a short-lived connection and a single transaction per call so no
    connection is held between periodic iterations. Returns deleted rows.
    """
    conn = connect(path)
    try:
        with conn:
            return delete_expired_tasks(conn, retention_days, now=now)
    finally:
        conn.close()
