import asyncio
import json
import os
import sqlite3
import time
from contextlib import asynccontextmanager
from datetime import datetime, timezone
from typing import Literal, Optional

import httpx
import jwt
from fastapi import BackgroundTasks, Depends, FastAPI, HTTPException, status
from fastapi.security import HTTPBearer, HTTPAuthorizationCredentials
from pydantic import BaseModel, Field

DB_PATH = os.environ.get("TAX_DB_PATH", "/data/tax.db")
API_KEY = os.environ.get("TAX_API_KEY", "")

APNS_KEY_ID = os.environ.get("TAX_APNS_KEY_ID", "")
APNS_TEAM_ID = os.environ.get("TAX_APNS_TEAM_ID", "")
APNS_BUNDLE_ID = os.environ.get("TAX_APNS_BUNDLE_ID", "")
APNS_KEY_PATH = os.environ.get("TAX_APNS_KEY_PATH", "")
APNS_USE_SANDBOX = os.environ.get("TAX_APNS_USE_SANDBOX", "").lower() in ("1", "true", "yes")

security = HTTPBearer()


def require_api_key(credentials: HTTPAuthorizationCredentials = Depends(security)):
    token = credentials.credentials
    if not API_KEY or token != API_KEY:
        print(f"[tax-server] auth failed: token length={len(token)}, expected length={len(API_KEY)}")
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Invalid or missing API key",
            headers={"WWW-Authenticate": "Bearer"},
        )
    print("[tax-server] auth ok")
    return token


def _add_missing_columns(conn: sqlite3.Connection, table: str, columns: dict[str, str]) -> None:
    existing = {row[1] for row in conn.execute(f"PRAGMA table_info({table})")}
    for name, sql_type in columns.items():
        if name not in existing:
            conn.execute(f"ALTER TABLE {table} ADD COLUMN {name} {sql_type}")


def init_db():
    db_dir = os.path.dirname(DB_PATH)
    if db_dir:
        os.makedirs(db_dir, exist_ok=True)
    conn = sqlite3.connect(DB_PATH)
    try:
        conn.execute("""
            CREATE TABLE IF NOT EXISTS tasks (
                id TEXT PRIMARY KEY,
                device_token TEXT NOT NULL,
                title TEXT,
                body TEXT,
                status TEXT DEFAULT 'pending',
                context TEXT,
                logs TEXT,
                reply TEXT,
                source TEXT,
                agent TEXT,
                app TEXT,
                agterm_session_id TEXT,
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
                "agterm_session_id": "TEXT",
            },
        )
        _add_missing_columns(conn, "device_tokens", {"preferences": "TEXT"})
        conn.commit()
    finally:
        conn.close()


@asynccontextmanager
async def lifespan(app: FastAPI):
    init_db()
    yield


app = FastAPI(title="tax — Task Agent eXchange", lifespan=lifespan)


class PushPayload(BaseModel):
    device_token: Optional[str] = None
    title: str
    body: str
    context: Optional[str] = ""
    logs: Optional[str] = ""
    source: Optional[str] = ""
    agent: Optional[str] = ""
    app: Optional[str] = ""
    agterm_session_id: Optional[str] = ""


class TaskUpdate(BaseModel):
    status: Optional[str] = None
    context: Optional[str] = None
    logs: Optional[str] = None


class ReplyPayload(BaseModel):
    text: str


class DevicePreferences(BaseModel):
    push_mode: Literal["all", "tax", "off"] = "all"


class DeviceTokenPayload(BaseModel):
    device_token: str
    preferences: DevicePreferences = Field(default_factory=DevicePreferences)


def db_conn():
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    return conn


def now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


def row_to_dict(row: sqlite3.Row) -> dict:
    return dict(row)


async def send_apns(
    device_token: str,
    title: str,
    body: str,
    task_id: str,
    app_name: str = "",
    source: str = "",
    agent: str = "",
):
    print(f"[tax-server] send_apns task_id={task_id} token_set={bool(device_token)} key_path={APNS_KEY_PATH}")
    if not device_token or not APNS_KEY_PATH or not os.path.exists(APNS_KEY_PATH):
        print("[tax-server] APNS key not configured or device token empty; push not sent")
        return

    with open(APNS_KEY_PATH) as f:
        key = f.read()

    token_time = int(time.time())
    auth_token = jwt.encode(
        {"iss": APNS_TEAM_ID, "iat": token_time, "exp": token_time + 3600},
        key,
        algorithm="ES256",
        headers={"kid": APNS_KEY_ID},
    )

    host = "api.development.push.apple.com" if APNS_USE_SANDBOX else "api.push.apple.com"
    url = f"https://{host}/3/device/{device_token}"

    payload = {
        "aps": {
            "alert": {"title": title, "body": body},
            "sound": "default",
            "badge": 1,
            "category": "TASK",
        },
        "task_id": task_id,
        "app": app_name,
        "source": source,
        "agent": agent,
    }

    async with httpx.AsyncClient(http2=True) as client:
        try:
            r = await client.post(
                url,
                json=payload,
                headers={
                    "apns-topic": APNS_BUNDLE_ID,
                    "authorization": f"bearer {auth_token}",
                    "apns-priority": "10",
                    "apns-push-type": "alert",
                },
            )
            print(f"[tax-server] APNs status={r.status_code} body={r.text}")
        except Exception as e:
            print(f"[tax-server] APNs error: {e}")


def device_registration(token: Optional[str] = None) -> Optional[sqlite3.Row]:
    conn = db_conn()
    try:
        if token:
            return conn.execute("SELECT token, preferences FROM device_tokens WHERE token = ?", (token,)).fetchone()
        return conn.execute("SELECT token, preferences FROM device_tokens ORDER BY updated_at DESC LIMIT 1").fetchone()
    finally:
        conn.close()


def push_mode_for(registration: Optional[sqlite3.Row]) -> str:
    if not registration or not registration["preferences"]:
        return "all"
    try:
        preferences = json.loads(registration["preferences"])
    except (TypeError, json.JSONDecodeError):
        return "all"
    mode = preferences.get("push_mode", "all")
    return mode if mode in {"all", "tax", "off"} else "all"


def should_send_push(mode: str, app_name: str) -> tuple[bool, Optional[str]]:
    if mode == "off":
        return False, "push_mode_off"
    if mode == "tax" and app_name != "tax":
        return False, "app_filtered"
    return True, None


@app.post("/push", dependencies=[Depends(require_api_key)])
async def push(payload: PushPayload, background_tasks: BackgroundTasks):
    task_id = os.urandom(16).hex()
    created_at = now_iso()
    registration = device_registration(payload.device_token)
    device_token = payload.device_token or (registration["token"] if registration else None)
    mode = push_mode_for(registration)
    send_push, skip_reason = should_send_push(mode, payload.app or "")

    print(
        f"[tax-server] /push task_id={task_id} device_token={'set' if device_token else 'empty'} "
        f"title={payload.title} source={payload.source} agent={payload.agent} app={payload.app} "
        f"agterm_session_id={payload.agterm_session_id} push_mode={mode}"
    )

    conn = db_conn()
    try:
        conn.execute(
            "INSERT INTO tasks "
            "(id, device_token, title, body, status, context, logs, source, agent, app, agterm_session_id, created_at, updated_at) "
            "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
            (
                task_id,
                device_token or "",
                payload.title,
                payload.body,
                "pending",
                payload.context,
                payload.logs,
                payload.source,
                payload.agent,
                payload.app,
                payload.agterm_session_id,
                created_at,
                created_at,
            ),
        )
        conn.commit()
    finally:
        conn.close()

    push_enqueued = bool(send_push and device_token)
    if push_enqueued:
        background_tasks.add_task(
            send_apns,
            device_token or "",
            payload.title,
            payload.body,
            task_id,
            payload.app or "",
            payload.source or "",
            payload.agent or "",
        )
        print(f"[tax-server] /push task_id={task_id} APNs enqueued")
    else:
        skip_reason = skip_reason or "device_token_missing"
        print(f"[tax-server] /push task_id={task_id} APNs skipped reason={skip_reason}")

    return {
        "ok": True,
        "task_id": task_id,
        "push_enqueued": push_enqueued,
        "push_skip_reason": skip_reason,
    }


@app.post("/task/{task_id}/update", dependencies=[Depends(require_api_key)])
async def update_task(task_id: str, update: TaskUpdate):
    conn = db_conn()
    cur = conn.cursor()

    fields = []
    values = []
    if update.status is not None:
        fields.append("status = ?")
        values.append(update.status)
    if update.context is not None:
        fields.append("context = ?")
        values.append(update.context)
    if update.logs is not None:
        fields.append("logs = ?")
        values.append(update.logs)

    if not fields:
        return {"ok": False, "error": "no fields to update"}

    values.append(now_iso())
    values.append(task_id)

    cur.execute(f"UPDATE tasks SET {', '.join(fields)}, updated_at = ? WHERE id = ?", values)
    conn.commit()
    row = cur.execute("SELECT * FROM tasks WHERE id = ?", (task_id,)).fetchone()
    conn.close()

    if not row:
        return {"ok": False, "error": "not found"}

    return {"ok": True, "task": row_to_dict(row)}


@app.get("/task/{task_id}", dependencies=[Depends(require_api_key)])
async def get_task(task_id: str):
    conn = db_conn()
    row = conn.execute("SELECT * FROM tasks WHERE id = ?", (task_id,)).fetchone()
    conn.close()
    if not row:
        return {"ok": False, "error": "not found"}
    return {"ok": True, "task": row_to_dict(row)}


@app.post("/task/{task_id}/reply", dependencies=[Depends(require_api_key)])
async def reply(task_id: str, payload: ReplyPayload):
    print(f"[tax-server] /task/{task_id}/reply received text length={len(payload.text)}")
    conn = db_conn()
    cur = conn.cursor()
    cur.execute(
        "UPDATE tasks SET reply = ?, status = 'replied', updated_at = ? WHERE id = ?",
        (payload.text, now_iso(), task_id),
    )
    conn.commit()
    row = cur.execute("SELECT * FROM tasks WHERE id = ?", (task_id,)).fetchone()
    conn.close()

    if not row:
        return {"ok": False, "error": "not found"}

    print(f"[tax-server] /task/{task_id}/reply saved")
    return {"ok": True, "task": row_to_dict(row)}


@app.get("/task/{task_id}/reply", dependencies=[Depends(require_api_key)])
async def get_reply(task_id: str, wait: bool = False):
    timeout = 30 if wait else 0
    deadline = time.time() + timeout

    print(f"[tax-server] /task/{task_id}/reply poll wait={wait} timeout={timeout}")

    while True:
        conn = db_conn()
        row = conn.execute("SELECT reply, status FROM tasks WHERE id = ?", (task_id,)).fetchone()
        conn.close()

        if row and row["reply"]:
            print(f"[tax-server] /task/{task_id}/reply found reply length={len(row['reply'])}")
            return {"ok": True, "reply": row["reply"]}

        if time.time() >= deadline:
            break
        await asyncio.sleep(1)

    print(f"[tax-server] /task/{task_id}/reply no reply within timeout")
    return {"ok": False, "reply": None}


@app.get("/replies", dependencies=[Depends(require_api_key)])
async def list_pending_replies(limit: int = 500):
    conn = db_conn()
    rows = conn.execute(
        "SELECT id, reply, agterm_session_id, source, agent, app, updated_at "
        "FROM tasks WHERE status = 'replied' AND reply IS NOT NULL "
        "ORDER BY updated_at LIMIT ?",
        (limit,),
    ).fetchall()
    conn.close()
    return {"ok": True, "tasks": [row_to_dict(row) for row in rows]}


@app.get("/tasks", dependencies=[Depends(require_api_key)])
async def list_tasks(limit: int = 50, offset: int = 0):
    conn = db_conn()
    rows = conn.execute(
        "SELECT * FROM tasks ORDER BY updated_at DESC LIMIT ? OFFSET ?",
        (limit, offset),
    ).fetchall()
    conn.close()
    return {"ok": True, "tasks": [row_to_dict(r) for r in rows]}


@app.get("/health", dependencies=[Depends(require_api_key)])
async def health():
    return {"ok": True}


@app.post("/register-device", dependencies=[Depends(require_api_key)])
async def register_device(payload: DeviceTokenPayload):
    token = payload.device_token.strip()
    if not token:
        raise HTTPException(status_code=400, detail="device_token is required")

    now = now_iso()
    preferences = json.dumps(payload.preferences.model_dump(), separators=(",", ":"))
    conn = db_conn()
    try:
        conn.execute(
            "INSERT INTO device_tokens (token, preferences, created_at, updated_at) VALUES (?, ?, ?, ?) "
            "ON CONFLICT(token) DO UPDATE SET preferences = excluded.preferences, updated_at = excluded.updated_at",
            (token, preferences, now, now),
        )
        conn.commit()
    finally:
        conn.close()
    print(f"[tax-server] registered device token_set=true push_mode={payload.preferences.push_mode}")
    return {"ok": True, "preferences": payload.preferences.model_dump()}


if __name__ == "__main__":
    import uvicorn

    uvicorn.run(app, host="0.0.0.0", port=8000)
