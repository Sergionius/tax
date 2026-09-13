"""SQLite setup and connection helpers for the tax backend."""

from __future__ import annotations

import os
import sqlite3


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
