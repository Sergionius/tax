# Mac Plan — tax

## Goal
Create a small background agent that receives task IDs from the pi extension, waits for iOS replies, and injects them back into the active agterm session.

## Component: `tax-agent`

A new pipx-installable Python CLI, or a standalone script in `scripts/tax-agent.py`. It runs on the Mac and stays in the background.

## Architecture

```
pi extension
  → POST /push  → backend returns task_id
  → POST http://127.0.0.1:17373/task
      {
        "task_id": "...",
        "agterm_session_id": "...",
        "source": "pi-extension",
        "agent": "pi",
        "app": "tax"
      }

  tax-agent
    → GET /task/{task_id}/reply?wait=true
    → iOS POST /task/{task_id}/reply
    → tax-agent receives reply
    → agtermctl session type "<reply>"
```

## CLI interface

```bash
tax-agent --server https://tax.138-249-127-23.nip.io --api-key *** --port 17373
```

Or via environment:
```bash
export TAX_SERVER=...
export TAX_API_KEY=...
tax-agent
```

## Local HTTP server

Listen on `127.0.0.1:17373`.

Endpoints:
- `POST /task` — register a new task to watch
- `GET /health` — check agent is alive
- `POST /shutdown` — stop agent

### `POST /task` payload
```json
{
  "task_id": "...",
  "agterm_session_id": "...",
  "source": "...",
  "agent": "...",
  "app": "..."
}
```

## Core loop

For each received task:
1. Start a background task / thread.
2. Poll `GET {server}/task/{task_id}/reply?wait=true` with timeout (e.g., 30s).
3. If reply arrives:
   - Run `agtermctl session type "<escaped_reply>"`.
   - If `agterm_session_id` is provided, try `agtermctl session type --id <id> "<reply>"` first; fallback to active session.
4. If timeout:
   - Log and forget, or retry later.
5. Optionally mark task delivered by `POST /task/{task_id}/update` with `status: delivered`.

## Fallback: file-based task queue

If the local HTTP server is unreachable, the pi extension can append to `~/.pi/tax/tasks.jsonl`:
```json
{"task_id":"...","agterm_session_id":"...","timestamp":"..."}
```

`tax-agent` reads this file every few seconds and processes new lines.

## agterm injection

Assume `agtermctl` is available on PATH. Commands:
```bash
# Current active session
agtermctl session type "hello from iOS"

# Specific session (if supported)
agtermctl session type --id <session_id> "hello from iOS"
```

If `agtermctl` is not available, log an error and keep the reply in a local queue.

## Installation & running

### Manual
```bash
pipx install git+https://github.com/Sergionius/tax.git#subdirectory=scripts/tax-agent
tax-agent &
```

### launchd (auto-start on login)
Create `~/Library/LaunchAgents/tax.agent.plist`:
```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" ...>
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>tax.agent</string>
    <key>ProgramArguments</key>
    <array>
        <string>/Users/sergiomalkin/.local/bin/tax-agent</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
</dict>
</plist>
```

Load:
```bash
launchctl load ~/Library/LaunchAgents/tax.agent.plist
```

## Changes needed in pi extension

Update `tax-push.ts`:
- After `POST /push`, parse response JSON and extract `task_id`.
- Try `POST http://127.0.0.1:17373/task` with the task metadata.
- On failure, append to `~/.pi/tax/tasks.jsonl`.

## Open questions

1. Does `agtermctl session type` support `--id`? Need to verify.
2. Should tax-agent use long-polling or repeated short polling? Use `?wait=true` which already long-polls for 30s.
3. Should tax-agent keep a persistent queue of pending tasks? Yes, in memory list + optional jsonl file.

## Acceptance criteria

- `tax-agent` starts and listens on a local port.
- pi extension can hand it a task ID.
- When iOS replies, the text appears in the active agterm session.
- If `tax-agent` is not running, extension falls back to jsonl and nothing is lost.
- Agent handles errors gracefully without blocking pi.
