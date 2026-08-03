# agterm cookbook integration

## Goal

Make tax a reliable attention and reply bridge for agents running in agterm, while keeping the Pi extension as the rich source of prompt and transcript context.

## Architecture

The Pi extension remains authoritative for completed Pi turns. It sends the prompt, final assistant output, cwd and Pi session file to the backend, then registers the task with the local agent. The local-only registration additionally records `AGTERM_SOCKET`, ensuring a remote reply returns to the exact agterm instance and session. The socket is not sent to the remote backend.

The tax agent also subscribes to `agtermctl events --json --kind status`. By default it creates tasks only for `blocked`; this avoids duplicate completion pushes from Pi while covering approval dialogs and agents without a rich extension. Generic `completed` notifications are opt-in through `tax config --status-events blocked,completed`. Repeated identical status events are suppressed until the session changes status.

For each accepted event, tax resolves workspace, cwd and foreground agent using the event's explicit window and session IDs, creates a backend task, and stores it locally as replyable. The monitor reconnects after stream failure. Events are not replayed after downtime.

## User workflows

The repository ships optional agterm workflows: native project-to-Pi launcher, flagged live dashboard, native directory picker, smart split, and stable Pi conversation IDs based on `AGTERM_SESSION_ID`. `scripts/install-agterm-workflows.sh` installs an idempotent marked keymap block and the zsh wrapper. Destructive park-and-resume is intentionally excluded.

`tax doctor` checks the CLI, control socket, API key, backend, local agent, status hooks and device registration.

## Safety and testing

Reply delivery never falls back to the active session. Existing delivery and backend-sync state transitions remain unchanged. SQLite migration adds the local socket without replacing existing databases. Tests cover socket routing, local socket preservation, status task creation, deduplication and completion opt-in. Python tests, Ruff and shell syntax checks gate the change.
