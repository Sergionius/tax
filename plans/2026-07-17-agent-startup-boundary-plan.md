# Plan: isolate `tax agent` tasks by process lifetime

## Goal

A newly started `tax agent` must ignore every task that existed before that process started. SQLite and the fallback file are runtime state, not an archive. A task must be injected into agterm at most once during one agent lifetime, and network failures must not cause unbounded threads, file descriptors, or traceback storms.

## Root cause

The current fallback importer rereads the complete `tasks.jsonl` every five seconds and calls `watch()` even when `AgentStore.add()` reports that the task already exists. A delivered row retains its reply, so every later watcher immediately injects that reply again. Repetition creates many watcher threads, HTTP connections, subprocesses, and SQLite connections. This exhausts the process file-descriptor limit (`Errno 24`); SQLite open failures and DNS errors are downstream symptoms.

The existing startup recovery also watches every status except `delivered`, including expired and failed historical tasks. That conflicts with the required process-lifetime boundary.

## Chosen behavior

1. Acquire a non-blocking single-instance lock before touching runtime state.
2. At startup, delete all rows from `watched_tasks` and compact SQLite.
3. Truncate the old fallback file before starting the importer.
4. Do not recover or poll any task from a previous process lifetime.
5. Keep current-lifetime rows in SQLite until shutdown so duplicate registrations cannot cause duplicate injection.
6. Delete that runtime history at the next successful startup.
7. Accept only tasks registered through the local API or appended to fallback after startup.

The backend may retain historical tasks for iOS display, but the Mac agent will not subscribe to them unless the current process receives a new local handoff.

## Implementation

### 1. Single-instance protection

Add a lock file under the selected state directory, for example `agent.lock`. In `run_agent_server`, acquire `fcntl.flock(..., LOCK_EX | LOCK_NB)` before constructing or starting `TaxAgent`, and retain the open file descriptor until server shutdown.

If another process owns the lock:

- print one concise `tax-agent is already running` message;
- return a non-zero exit code;
- do not clear SQLite or fallback state.

This prevents a second invocation from deleting the active agent's task state before failing to bind port `17373`.

### 2. Runtime-only SQLite state

Add `AgentStore.reset()`:

- execute `DELETE FROM watched_tasks`;
- run `VACUUM` outside the delete transaction so old rows and unused pages are physically removed;
- leave the schema intact.

Call it exactly once from `TaxAgent.start()` after the single-instance lock is held. Remove startup recovery through `unfinished()`; no historical row is eligible after restart.

Rows remain after delivery during the current process. This is necessary because a duplicate HTTP handoff or duplicate fallback line with the same `task_id` must remain a no-op. They are removed on the next startup.

Guard `start()` against repeated invocation on the same object.

### 3. Fallback as a forward-only runtime queue

At startup, truncate `tasks.jsonl` and initialize an in-memory byte offset to zero. This intentionally discards tasks written while the agent was stopped.

During the current run, importer iterations must:

- read only bytes after the saved offset;
- process newline-terminated JSON records;
- leave an incomplete final record for the next iteration;
- advance the offset only past complete records;
- reset the offset safely if the file was externally truncated;
- call `watch()` only when `store.add()` returns `True`.

Do not rewrite or truncate the file during active importing because the TypeScript extension may append concurrently. The file is bounded to one process lifetime and is truncated on the next launch.

No payload timestamp or migration is required: the startup truncation itself defines the relevance boundary.

### 4. Registration and delivery deduplication

Change `register()` so it calls `watch()` only for a newly inserted row. A duplicate `/task` request returns `created: false` and does no further work.

Before scheduling work, `watch()` verifies that the row exists and has a runnable status. Terminal states such as `delivered`, `expired`, and any ignored/cancelled state are not scheduled.

Set a delivery state before invoking `agtermctl`. The existing in-memory `_watching` set remains a second guard against concurrent watchers for the same ID. Keep the row in `delivered` state after successful injection.

### 5. Bound resource usage

Replace unrestricted `threading.Thread` creation for each task with a bounded `ThreadPoolExecutor` (recommended default: 16 workers). New unique tasks can queue, but at most 16 long polls or deliveries execute simultaneously.

On shutdown:

- set `stop_event`;
- stop the importer;
- shut down the executor without waiting indefinitely for long polls;
- release the single-instance lock after Uvicorn exits.

Explicitly close HTTP responses from GET and POST requests. Keep request timeouts. This ensures sockets are released deterministically rather than relying on garbage collection.

### 6. Error handling and logging

Wrap watcher and importer entry points so an unexpected exception cannot emit an uncontrolled thread traceback or permanently kill the importer.

Expected transient failures should produce concise one-line logs:

- backend connection/DNS failure: retain `waiting_reply`, increment attempts, retry after `retry_delay`;
- fallback read/parse error: log once per iteration and continue;
- SQLite operational error: log a concise task/importer error and back off;
- `agtermctl` failure: retain `delivery_failed` and retry within the current process lifetime.

Do not create another watcher in response to an error. The existing watcher owns retries until success, expiration, or shutdown.

### 7. Documentation

Update `README.md` and `plans/mac-plan.md` to state:

- fallback tasks created while the agent is stopped are intentionally discarded on the next startup;
- SQLite is current-process deduplication and retry state, not persistent recovery/history;
- only backend/iOS retains historical tasks.

Remove wording that promises persistent recovery of old fallback tasks.

## Test plan

Add or update tests in `tests/test_agent.py`:

1. **Startup reset:** rows created before `start()` are deleted and not watched.
2. **Old fallback ignored:** a preexisting JSONL entry is removed at startup and never registered.
3. **New fallback imported once:** a line appended after startup is added and scheduled once across multiple importer passes.
4. **Partial JSONL line:** an incomplete record is not consumed; it is imported after its newline arrives.
5. **Duplicate local registration:** the second registration does not call `watch()`.
6. **Delivered fallback duplicate:** repeating an already delivered task ID cannot inject again.
7. **Terminal status guard:** `watch()` does not schedule delivered or expired rows.
8. **Bounded execution:** scheduling more than the worker limit does not create an unbounded number of worker threads.
9. **Network failure:** request errors are retried without escaping from the watcher wrapper.
10. **Single-instance lock:** a second lock acquisition fails without resetting state; acquisition succeeds after release.
11. **Successful reply:** preserve the existing assertion that a reply is injected into the requested agterm session and marked delivered locally/backend.
12. **Local API:** preserve health, task registration, deduplication, and shutdown coverage.

Run:

```bash
pytest -q
ruff check src tests
```

If TypeScript tests are not configured, run the existing package typecheck/build command and manually verify that fallback output remains newline-delimited JSON.

## Manual verification

1. Stop all agent instances.
2. Seed `agent.db` and `tasks.jsonl` with historical task IDs.
3. Start `tax agent`; verify no historical task is polled or injected.
4. Submit a new task from pi; reply from iOS; verify exactly one injection.
5. Wait through several fallback importer intervals; verify no repeated delivery.
6. Disconnect DNS temporarily; verify bounded workers and concise retry logs.
7. Start a second `tax agent`; verify it exits without modifying the running instance.
8. Restart the agent; verify previous runtime rows and fallback lines are gone.

## Acceptance criteria

- No task created before agent startup is polled or delivered.
- A task is injected no more than once per agent lifetime.
- SQLite contains only the current process lifetime's task state.
- Old SQLite rows and fallback contents are removed on startup.
- Duplicate fallback scans and duplicate local requests do not spawn watchers.
- Concurrent watcher count is bounded.
- DNS/backend outages do not produce unbounded traceback storms or exhaust file descriptors.
- A second agent process cannot reset the active process's state.
- All automated tests and lint checks pass.
