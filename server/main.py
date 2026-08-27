import asyncio
import json
import logging
import os
import sqlite3
import time
import uuid
from contextlib import asynccontextmanager
from datetime import datetime, timedelta, timezone
from typing import Literal, Optional

from fastapi import BackgroundTasks, Depends, FastAPI, HTTPException, Query, Request, WebSocket, status
from starlette.websockets import WebSocketDisconnect
from fastapi.security import HTTPBearer, HTTPAuthorizationCredentials
from pydantic import BaseModel, Field

try:
    from server import apns, storage
    from server.relay import RelayHub
    from server.logging_config import configure_logging, log_event
except ModuleNotFoundError:  # Standalone deployment runs with server/ as the working directory.
    import apns
    import storage
    from relay import RelayHub
    from logging_config import configure_logging, log_event

DB_PATH = os.environ.get("TAX_DB_PATH", "/data/tax.db")
API_KEY = os.environ.get("TAX_API_KEY", "")
TASK_REPLY_TTL_SECONDS = 30 * 60

APNS_KEY_ID = os.environ.get("TAX_APNS_KEY_ID", "")
APNS_TEAM_ID = os.environ.get("TAX_APNS_TEAM_ID", "")
APNS_BUNDLE_ID = os.environ.get("TAX_APNS_BUNDLE_ID", "")
APNS_KEY_PATH = os.environ.get("TAX_APNS_KEY_PATH", "")
APNS_USE_SANDBOX = os.environ.get("TAX_APNS_USE_SANDBOX", "").lower() in ("1", "true", "yes")

security = HTTPBearer()
logger = configure_logging("tax-server")
relay_hub = RelayHub()


def require_api_key(credentials: HTTPAuthorizationCredentials = Depends(security)):
    token = credentials.credentials
    if not API_KEY or token != API_KEY:
        log_event(logger, "auth_failed", level=logging.WARNING, token_length=len(token), configured=bool(API_KEY))
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Invalid or missing API key",
            headers={"WWW-Authenticate": "Bearer"},
        )
    log_event(logger, "auth_ok", level=logging.DEBUG)
    return token


def init_db():
    storage.initialize(DB_PATH)


@asynccontextmanager
async def lifespan(app: FastAPI):
    init_db()
    yield


app = FastAPI(title="tax — Task Agent eXchange", lifespan=lifespan)


@app.middleware("http")
async def request_logging(request: Request, call_next):
    request_id = request.headers.get("x-request-id") or uuid.uuid4().hex
    started = time.monotonic()
    try:
        response = await call_next(request)
    except Exception:
        log_event(
            logger,
            "request_failed",
            level=logging.ERROR,
            request_id=request_id,
            method=request.method,
            path=request.url.path,
            duration_ms=round((time.monotonic() - started) * 1000),
        )
        raise
    response.headers["x-request-id"] = request_id
    log_event(
        logger,
        "request_completed",
        request_id=request_id,
        method=request.method,
        path=request.url.path,
        status_code=response.status_code,
        duration_ms=round((time.monotonic() - started) * 1000),
    )
    return response


class PushPayload(BaseModel):
    device_token: Optional[str] = Field(default=None, max_length=512)
    title: str = Field(min_length=1, max_length=256)
    body: str = Field(min_length=1, max_length=4096)
    context: Optional[str] = Field(default="", max_length=100_000)
    logs: Optional[str] = Field(default="", max_length=500_000)
    source: Optional[str] = ""
    agent: Optional[str] = ""
    app: Optional[str] = ""
    orca_terminal_handle: Optional[str] = ""
    orca_worktree_id: Optional[str] = ""
    orca_tab_id: Optional[str] = ""
    orca_pane_key: Optional[str] = ""


class TaskUpdate(BaseModel):
    status: Optional[Literal["pending", "replied", "delivered", "delivery_failed", "expired"]] = None
    context: Optional[str] = Field(default=None, max_length=100_000)
    logs: Optional[str] = Field(default=None, max_length=500_000)


class ReplyPayload(BaseModel):
    text: str = Field(min_length=1, max_length=20_000)


class DevicePreferences(BaseModel):
    push_mode: Literal["all", "tax", "off"] = "all"


class DeviceTokenPayload(BaseModel):
    device_token: str = Field(min_length=1, max_length=512)
    preferences: DevicePreferences = Field(default_factory=DevicePreferences)


def db_conn():
    return storage.connect(DB_PATH)


def expire_stale_tasks(conn: sqlite3.Connection) -> int:
    cutoff = (datetime.now(timezone.utc) - timedelta(seconds=TASK_REPLY_TTL_SECONDS)).isoformat()
    cursor = conn.execute(
        "UPDATE tasks SET status = 'expired', updated_at = ? "
        "WHERE (status = 'pending' AND created_at < ?) OR (status = 'replied' AND updated_at < ?)",
        (now_iso(), cutoff, cutoff),
    )
    conn.commit()
    return cursor.rowcount


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
    config = apns.APNSConfig(
        key_id=APNS_KEY_ID,
        team_id=APNS_TEAM_ID,
        bundle_id=APNS_BUNDLE_ID,
        key_path=APNS_KEY_PATH,
        use_sandbox=APNS_USE_SANDBOX,
    )
    result = await apns.send(config, logger, device_token, title, body, task_id, app_name, source, agent)
    conn = None
    try:
        conn = db_conn()
        conn.execute(
            "UPDATE tasks SET push_status = ?, push_attempted_at = ?, push_environment = ?, "
            "apns_status_code = ?, apns_reason = ?, apns_id = ?, updated_at = ? WHERE id = ?",
            (
                result.status,
                now_iso(),
                result.environment,
                result.status_code,
                result.reason,
                result.apns_id,
                now_iso(),
                task_id,
            ),
        )
        conn.commit()
    except sqlite3.Error as error:
        log_event(logger, "apns_result_store_failed", level=logging.ERROR, task_id=task_id, error=str(error))
    finally:
        if conn is not None:
            conn.close()
    return result


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


@app.websocket("/relay/{role}")
async def relay_socket(websocket: WebSocket, role: str, host_id: str, device_id: str):
    authorization = websocket.headers.get("authorization", "")
    if not API_KEY or authorization != f"Bearer {API_KEY}":
        await websocket.close(code=4401, reason="unauthorized")
        return
    if role not in {"host", "device"} or not host_id or not device_id or len(host_id) > 128 or len(device_id) > 128:
        await websocket.close(code=4400, reason="invalid route")
        return
    peer = await relay_hub.connect(role, host_id, device_id, websocket)
    try:
        await relay_hub.run(role, host_id, device_id, peer)
    except WebSocketDisconnect:
        pass
    finally:
        await relay_hub.disconnect(role, host_id, device_id, peer)


@app.post("/push", dependencies=[Depends(require_api_key)])
async def push(payload: PushPayload, background_tasks: BackgroundTasks):
    task_id = os.urandom(16).hex()
    created_at = now_iso()
    registration = device_registration(payload.device_token)
    device_token = payload.device_token or (registration["token"] if registration else None)
    mode = push_mode_for(registration)
    send_push, skip_reason = should_send_push(mode, payload.app or "")
    push_enqueued = bool(send_push and device_token)
    if not push_enqueued:
        skip_reason = skip_reason or "device_token_missing"

    log_event(
        logger,
        "task_created",
        task_id=task_id,
        token_configured=bool(device_token),
        source=payload.source,
        agent=payload.agent,
        app=payload.app,
        terminal_handle=payload.orca_terminal_handle,
        push_mode=mode,
    )

    conn = db_conn()
    try:
        conn.execute(
            "INSERT INTO tasks "
            "(id, device_token, title, body, status, context, logs, source, agent, app, "
            "orca_terminal_handle, orca_worktree_id, orca_tab_id, orca_pane_key, push_status, "
            "push_environment, apns_reason, created_at, updated_at) "
            "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
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
                payload.orca_terminal_handle,
                payload.orca_worktree_id,
                payload.orca_tab_id,
                payload.orca_pane_key,
                "queued" if push_enqueued else "skipped",
                "sandbox" if APNS_USE_SANDBOX else "production",
                skip_reason or "",
                created_at,
                created_at,
            ),
        )
        conn.commit()
    finally:
        conn.close()

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
        log_event(logger, "apns_enqueued", task_id=task_id)
    else:
        log_event(logger, "apns_skipped", task_id=task_id, reason=skip_reason)

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
        conn.close()
        raise HTTPException(status_code=400, detail="no fields to update")

    values.append(now_iso())
    values.append(task_id)

    cur.execute(f"UPDATE tasks SET {', '.join(fields)}, updated_at = ? WHERE id = ?", values)
    conn.commit()
    row = cur.execute("SELECT * FROM tasks WHERE id = ?", (task_id,)).fetchone()
    conn.close()

    if not row:
        raise HTTPException(status_code=404, detail="task not found")

    return {"ok": True, "task": row_to_dict(row)}


@app.get("/task/{task_id}", dependencies=[Depends(require_api_key)])
async def get_task(task_id: str):
    conn = db_conn()
    expire_stale_tasks(conn)
    row = conn.execute("SELECT * FROM tasks WHERE id = ?", (task_id,)).fetchone()
    conn.close()
    if not row:
        raise HTTPException(status_code=404, detail="task not found")
    return {"ok": True, "task": row_to_dict(row)}


@app.post("/task/{task_id}/reply", dependencies=[Depends(require_api_key)])
async def reply(task_id: str, payload: ReplyPayload):
    log_event(logger, "reply_received", task_id=task_id, reply_length=len(payload.text))
    conn = db_conn()
    expire_stale_tasks(conn)
    cur = conn.cursor()
    cur.execute(
        "UPDATE tasks SET reply = ?, status = 'replied', updated_at = ? "
        "WHERE id = ? AND reply IS NULL AND status = 'pending'",
        (payload.text, now_iso(), task_id),
    )
    updated = cur.rowcount
    conn.commit()
    row = cur.execute("SELECT * FROM tasks WHERE id = ?", (task_id,)).fetchone()
    conn.close()

    if not row:
        raise HTTPException(status_code=404, detail="task not found")
    if not updated:
        detail = "task expired" if row["status"] == "expired" else "reply already submitted"
        raise HTTPException(status_code=409, detail=detail)

    log_event(logger, "reply_saved", task_id=task_id)
    return {"ok": True, "task": row_to_dict(row)}


@app.get("/task/{task_id}/reply", dependencies=[Depends(require_api_key)])
async def get_reply(task_id: str, wait: bool = False):
    timeout = 30 if wait else 0
    deadline = time.time() + timeout

    log_event(logger, "reply_poll_started", level=logging.DEBUG, task_id=task_id, wait=wait, timeout=timeout)

    while True:
        conn = db_conn()
        expire_stale_tasks(conn)
        row = conn.execute("SELECT reply, status FROM tasks WHERE id = ?", (task_id,)).fetchone()
        conn.close()

        if row and row["reply"]:
            log_event(logger, "reply_poll_found", task_id=task_id, reply_length=len(row["reply"]))
            return {"ok": True, "reply": row["reply"]}

        if time.time() >= deadline:
            break
        await asyncio.sleep(1)

    log_event(logger, "reply_poll_empty", level=logging.DEBUG, task_id=task_id)
    return {"ok": False, "reply": None}


@app.get("/replies", dependencies=[Depends(require_api_key)])
async def list_pending_replies(limit: int = Query(default=500, ge=1, le=500)):
    conn = db_conn()
    expire_stale_tasks(conn)
    rows = conn.execute(
        "SELECT id, reply, orca_terminal_handle, orca_worktree_id, orca_tab_id, orca_pane_key, "
        "source, agent, app, updated_at "
        "FROM tasks WHERE status = 'replied' AND reply IS NOT NULL "
        "ORDER BY updated_at LIMIT ?",
        (limit,),
    ).fetchall()
    conn.close()
    return {"ok": True, "tasks": [row_to_dict(row) for row in rows]}


@app.get("/tasks", dependencies=[Depends(require_api_key)])
async def list_tasks(
    limit: int = Query(default=50, ge=1, le=500), offset: int = Query(default=0, ge=0)
):
    conn = db_conn()
    expire_stale_tasks(conn)
    rows = conn.execute(
        "SELECT * FROM tasks ORDER BY created_at DESC LIMIT ? OFFSET ?",
        (limit, offset),
    ).fetchall()
    conn.close()
    return {"ok": True, "tasks": [row_to_dict(r) for r in rows]}


@app.get("/health", dependencies=[Depends(require_api_key)])
async def health():
    conn = None
    try:
        conn = db_conn()
        conn.execute("SELECT 1").fetchone()
    except sqlite3.Error as error:
        log_event(logger, "health_failed", level=logging.ERROR, error=str(error))
        raise HTTPException(status_code=503, detail="database unavailable") from error
    finally:
        if conn is not None:
            conn.close()
    return {"ok": True, "database": "ok"}


@app.post("/diagnostics/push-test", dependencies=[Depends(require_api_key)])
async def diagnostic_push_test(background_tasks: BackgroundTasks):
    result = await push(
        PushPayload(
            title="tax diagnostic",
            body="Push delivery test",
            source="push-doctor",
            agent="diagnostic",
            app="tax",
        ),
        background_tasks,
    )
    return {
        **result,
        "environment": "sandbox" if APNS_USE_SANDBOX else "production",
        "device_registered": bool(device_registration()),
    }


@app.get("/diagnostics/push/{task_id}", dependencies=[Depends(require_api_key)])
async def diagnostic_push_status(task_id: str):
    conn = db_conn()
    try:
        row = conn.execute(
            "SELECT id, push_status, push_attempted_at, push_environment, apns_status_code, "
            "apns_reason, apns_id, device_token, source, created_at, updated_at "
            "FROM tasks WHERE id = ?",
            (task_id,),
        ).fetchone()
    finally:
        conn.close()
    if not row:
        raise HTTPException(status_code=404, detail="task not found")
    result = row_to_dict(row)
    result["device_registered"] = bool(result.pop("device_token", ""))
    return {"ok": True, "diagnostic": result}


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
    log_event(logger, "device_registered", push_mode=payload.preferences.push_mode)
    return {"ok": True, "preferences": payload.preferences.model_dump()}


if __name__ == "__main__":
    import uvicorn

    uvicorn.run(app, host="0.0.0.0", port=8000)
