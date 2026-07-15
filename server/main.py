import asyncio
import json
import os
import sqlite3
import time
from contextlib import asynccontextmanager
from datetime import datetime, timezone
from typing import Optional

import httpx
import jwt
from fastapi import BackgroundTasks, Depends, FastAPI, HTTPException, status
from fastapi.security import HTTPBearer, HTTPAuthorizationCredentials
from pydantic import BaseModel

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
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Invalid or missing API key",
            headers={"WWW-Authenticate": "Bearer"},
        )
    return token


def init_db():
    os.makedirs(os.path.dirname(DB_PATH), exist_ok=True)
    conn = sqlite3.connect(DB_PATH)
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
            created_at TEXT,
            updated_at TEXT
        )
    """)
    conn.execute("""
        CREATE TABLE IF NOT EXISTS device_tokens (
            token TEXT PRIMARY KEY,
            created_at TEXT,
            updated_at TEXT
        )
    """)
    conn.commit()
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


class TaskUpdate(BaseModel):
    status: Optional[str] = None
    context: Optional[str] = None
    logs: Optional[str] = None


class ReplyPayload(BaseModel):
    text: str


class DeviceTokenPayload(BaseModel):
    device_token: str


def db_conn():
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    return conn


def now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


def row_to_dict(row: sqlite3.Row) -> dict:
    return dict(row)


async def send_apns(device_token: str, title: str, body: str, task_id: str):
    if not device_token or not APNS_KEY_PATH or not os.path.exists(APNS_KEY_PATH):
        print(f"[tax-server] APNS key not configured or device token empty; push not sent")
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
        },
        "task_id": task_id,
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


def latest_device_token() -> Optional[str]:
    conn = db_conn()
    row = conn.execute(
        "SELECT token FROM device_tokens ORDER BY updated_at DESC LIMIT 1"
    ).fetchone()
    conn.close()
    if row:
        return row["token"]
    return None


@app.post("/push", dependencies=[Depends(require_api_key)])
async def push(payload: PushPayload, background_tasks: BackgroundTasks):
    task_id = os.urandom(16).hex()
    created_at = now_iso()
    device_token = payload.device_token or latest_device_token()

    conn = db_conn()
    conn.execute(
        "INSERT INTO tasks (id, device_token, title, body, status, context, logs, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
        (task_id, device_token or "", payload.title, payload.body, "pending", payload.context, payload.logs, created_at, created_at),
    )
    conn.commit()
    conn.close()

    background_tasks.add_task(send_apns, device_token or "", payload.title, payload.body, task_id)

    return {"ok": True, "task_id": task_id}


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

    return {"ok": True, "task": row_to_dict(row)}


@app.get("/task/{task_id}/reply", dependencies=[Depends(require_api_key)])
async def get_reply(task_id: str, wait: bool = False):
    timeout = 30 if wait else 0
    deadline = time.time() + timeout

    while True:
        conn = db_conn()
        row = conn.execute("SELECT reply, status FROM tasks WHERE id = ?", (task_id,)).fetchone()
        conn.close()

        if row and row["reply"]:
            return {"ok": True, "reply": row["reply"]}

        if time.time() >= deadline:
            break
        await asyncio.sleep(1)

    return {"ok": False, "reply": None}


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
    conn = db_conn()
    conn.execute(
        "INSERT INTO device_tokens (token, created_at, updated_at) VALUES (?, ?, ?) "
        "ON CONFLICT(token) DO UPDATE SET updated_at = excluded.updated_at",
        (token, now, now),
    )
    conn.commit()
    conn.close()
    return {"ok": True}


if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8000)
