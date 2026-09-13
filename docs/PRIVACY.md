# Privacy

This document describes precisely what TAX encrypts, what the backend and Apple can see, and what is stored where. It describes the software as shipped; your deployment may store more (for example if you enable content storage) and any reverse proxy or host in front of the backend sees connection metadata by definition.

## Three separate paths

TAX traffic uses three independent paths with different guarantees:

1. **Relay (terminal and file traffic)** — end-to-end encrypted.
2. **Agent notifications (HTTPS to the backend, then APNs)** — not end-to-end encrypted; notification content is processed by the backend and Apple.
3. **Device registration** — the APNs device token and push preferences stored on the backend.

## What is end-to-end encrypted — and what is not

Terminal and file traffic between the iPhone and the Mac host is end-to-end encrypted with a separate 256-bit tax key (ChaCha20-Poly1305, HKDF-SHA256 session derivation; see [`remote-protocol-v1.md`](remote-protocol-v1.md)). The backend never receives this key. It relays this traffic as ciphertext and does not persist it.

The encryption boundary ends there:

- **The backend sees routing and connection metadata** for the relay: host and device identifiers, session establishment, WebSocket connections, frame counts and timing. Anyone operating the server (you, or whoever administers it) can observe this metadata.
- **The backend processes notification content.** Completion pushes are not end-to-end encrypted: `tax run`, the Pi extension and the Claude Code/Codex hooks send `title`, `body`, `context` and `logs` to the backend over HTTPS, where they are processed and stored (subject to the storage policy below).
- **Apple receives the APNs alert title and body** (including a shortened response preview when an adapter sends one), plus routing identifiers (`host_id`, `workspace_id`, `terminal_id`) and small metadata fields (`app`, `source`, `agent`). `context` and `logs` are not sent to Apple; they stay on the backend.
- File operations are scoped to workspace roots on the Mac, but file names and contents that you open or edit are visible in decrypted form on both devices; encryption protects the network path, not the endpoints.

## What the backend stores

The backend keeps two kinds of rows in its SQLite database:

- **Notification tasks** — one row per push request: `id`, `device_token`, `title`, `body`, `context`, `logs`, `source`, `agent`, `app`, the Orca routing fields (`orca_terminal_handle`, `orca_worktree_id`, `orca_tab_id`, `orca_pane_key`), push diagnostics (`push_status`, `push_attempted_at`, `push_environment`, `apns_status_code`, `apns_reason`, `apns_id`) and timestamps (`created_at`, `updated_at`). Databases created before 0.4.0 also contain legacy reply columns; they are physically present but never read or written by current code.
- **Device registrations** — APNs device tokens with push-mode preferences. These are never deleted by the retention policy.

The task history API exposes a public projection that hides the device token and legacy columns.

## Storage policy for `context` and `logs`

`TAX_STORE_AGENT_CONTENT` controls whether the backend **persists** the `context` and `logs` fields of notification tasks:

- **Off by default.** Any value other than exactly `1` keeps storage off. When off, the backend stores empty strings for `context`/`logs`.
- **Opt-in with `1`.** Set `TAX_STORE_AGENT_CONTENT=1` in the backend environment (see `server/.env.example` and `server/docker-compose.yml`) to store them.
- **Applies to the existing database.** When storage is off, startup purges `context`/`logs` from all pre-existing rows, so upgrading with the default also empties previously stored content.
- **Delivery is unaffected.** Push delivery works identically whether storage is on or off.

## Retention

`TAX_TASK_RETENTION_DAYS` (default `7`) controls automatic deletion of notification tasks:

- Tasks strictly older than the configured number of days are deleted based on their `created_at` timestamp (UTC). Invalid values (non-integers or `<= 0`) prevent the service from starting.
- Cleanup runs once at startup and then hourly while the service runs.
- Device registrations are never deleted by retention, and the physical table schema is not changed.
- **Backups are not cleaned automatically.** Database backups created by deployment tooling or by you are plain SQLite copies that retain whatever the database contained at backup time; deleting or expiring them is your responsibility.

## Deleting data is not physical erasure

Deleting rows (manually or through retention) removes them from the SQLite logical content, but it is **not a guaranteed physical erase from the storage medium**. Freelist pages, write-ahead logs, filesystem journaling, snapshots, and backups can retain data until the space is reused and eventually overwritten. If your threat model requires physical erasure, restore from a backup taken before the data existed, recreate the database, or use encrypted storage at the volume level.

## Disabling storage does not block transmission

Turning `TAX_STORE_AGENT_CONTENT` off prevents **persistence** only. The `context` and `logs` fields are still transmitted to the backend over HTTPS with every push request — the backend simply discards them instead of writing them to the database. If you do not want that content to reach your server at all, do not send it: use notification sources that omit it, or do not wrap commands with `tax run`.

## Operational secrets

API keys, the tax E2EE key and Orca pairing credentials are secrets. TAX keeps the E2EE key in the macOS/iOS Keychain, and deployment configuration in private mode-`0600` files (see [`LOCAL_CONFIGURATION.md`](LOCAL_CONFIGURATION.md)). Report vulnerabilities privately per [`SECURITY.md`](../SECURITY.md).
