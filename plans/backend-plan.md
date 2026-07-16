# Backend Plan — tax

## Goal
Support push filtering by app/source, store device preferences, and expose the existing reply endpoints for the Mac agent.

## Changes to `server/main.py`

### 1. Extend `PushPayload`
Add optional metadata fields so the backend knows the source of the push and can route it to the right consumers.

```python
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
```

### 2. Extend `DeviceTokenPayload` with preferences
```python
class DeviceTokenPayload(BaseModel):
    device_token: str
    preferences: Optional[dict] = {}
```

### 3. Update schema
Add `preferences` column to `device_tokens` and store as JSON text.

```python
CREATE TABLE IF NOT EXISTS device_tokens (
    token TEXT PRIMARY KEY,
    preferences TEXT,
    created_at TEXT,
    updated_at TEXT
)
```

### 4. Store preferences on `/register-device`
- Serialize `payload.preferences` to JSON string.
- Upsert as usual.

### 5. Filter push by `app` and `push_mode`
In `push()`:
- Load latest device token with its `preferences`.
- If `preferences.push_mode == "off"`: skip APNs.
- If `preferences.push_mode == "tax"`: send only if `payload.app == "tax"`.
- If `preferences.push_mode == "all"` or missing: send always.

### 6. Store push metadata in `tasks` table
Add columns to `tasks`:
- `source TEXT`
- `agent TEXT`
- `app TEXT`
- `agterm_session_id TEXT`

Or store them as JSON in a `meta` column.

### 7. Ensure `/push` returns `task_id`
Already returns `{"ok": True, "task_id": task_id}`. Keep it.

### 8. Add `/tasks` endpoint (optional, useful for debugging)
Already exists. Keep it as is.

### 9. Logging
Keep detailed logging already added. Ensure new fields are logged.

## Open questions
- Should filtering happen on `app` or `source`? Agreed: primary filter is `app == "tax"`, secondary optional filter by `source`.
- Should `off` mode prevent task creation or only APNs? Only APNs should be skipped; task should still be stored for history.

## Acceptance criteria
- `POST /push` with `app: "tax"` sends APNs when device is in `tax` mode.
- `POST /push` with `app: "tax"` is skipped when device is in `off` mode.
- `POST /register-device` stores `preferences`.
- `GET /task/{id}/reply?wait=true` still works for the Mac agent.
- `/push` returns `task_id` and stores metadata.
