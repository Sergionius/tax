# tax operations runbook

## Backend deployment

The backend runs as a systemd service behind a reverse proxy (primary variant) or as a Docker Compose container. Every deployment value comes from the private deployment configuration — `~/.config/tax/deploy.env` on the server, the file named by `TAX_DEPLOY_CONFIG`, or explicit environment variables; see [`LOCAL_CONFIGURATION.md`](LOCAL_CONFIGURATION.md) for the full contract. Deployment tooling validates the configuration and stops on missing or invalid values before touching SSH, Git, `sudo`, files, or services.

### Systemd (primary)

Prepare the server once:

```bash
ssh <your-host>
mkdir -p ~/.config/tax
cp /path/to/checkout/deploy.env.example ~/.config/tax/deploy.env
chmod 600 ~/.config/tax/deploy.env
# edit ~/.config/tax/deploy.env and fill in the real values
git clone <your-repo-url> "$TAX_DEPLOY_PROJECT_DIR"
```

Then deploy from your machine, or from the server checkout directly:

```bash
./scripts/deploy-backend.sh   # from your machine; runs deploy.sh over SSH
# or, on the server:
cd "$TAX_DEPLOY_PROJECT_DIR" && git pull --ff-only origin main && ./deploy.sh
```

`deploy.sh` renders the systemd unit and reverse-proxy configuration from the private values (it refuses to install files with unresolved placeholders), creates a consistent online SQLite backup with an integrity check, installs backend dependencies from the generated `server/requirements.txt` with hash checking, restarts `tax.service`, and verifies `/health` and the database schema.

### Docker Compose (alternative)

From the checkout on the server:

```bash
cp server/.env.example server/.env   # then fill in real values; chmod 600 server/.env
docker compose -f server/docker-compose.yml --env-file server/.env up -d --build
```

The container port is fixed at `8000`; the host loopback port (`TAX_DEPLOY_PORT`, default `8000`), the persistent data directory (`TAX_COMPOSE_DATA_DIR`) and the APNs key directory (`TAX_COMPOSE_KEYS_DIR`) are configurable. Keep the host port equal to the port your reverse proxy forwards to. Compose fails fast when `TAX_API_KEY` or the APNs variables are missing.

The service must be reachable only on a loopback interface or a private network in front of your TLS-terminating reverse proxy; do not expose it directly to the Internet.

## Push status flow

`push_status` is the only live delivery status for a notification task:

- `queued` — task accepted, APNs send scheduled;
- `sent` — Apple accepted the push (HTTP 2xx);
- `failed` — APNs rejected the request or was unreachable; `apns_status_code` and `apns_reason` are stored on the task;
- `skipped` — no device token, `push_mode` is `off`, or the app filter rejected the source.

Rows created before 0.4.0 may have an empty `push_status`; `tax status` displays those historical records as `unknown`. The legacy `status` column still physically present in old databases is never read or written by current code.

Task history (`GET /task/{task_id}` and `GET /tasks`) returns an explicit public projection: `id`, `title`, `body`, `context`, `logs`, `source`, `agent`, `app`, Orca routing fields, push/APNs fields and timestamps. Legacy reply fields and device tokens are not exposed, and GET requests never modify the database.

Inspect a task with `GET /diagnostics/push/{task_id}` or run `tax push-doctor` on the Mac.

Notifications are fire-and-forget: if the backend is down when an agent finishes, the push is not replayed later. Send a new notification after the backend recovers.

## Backend outage

1. Check `GET /health` with the bearer credential.
2. Check service and reverse-proxy logs.
3. Verify the SQLite filesystem is writable and has free space.
4. Restart the service only after preserving logs.
5. Verify delivery with `tax push-doctor` once the service is healthy.

## APNs failures

- `400`: inspect APNs reason and payload shape.
- `403`: verify Key ID, Team ID, bundle ID and `.p8` permissions.
- `410`: remove/replace the expired device token.
- `429`: reduce retries and respect APNs backoff.
- Sandbox tokens require the development APNs host; TestFlight uses production.

Never paste API keys, provider JWTs, full device tokens, context or message text into tickets or logs.

## SQLite backup and restore

Create a consistent online backup:

```bash
sqlite3 /data/tax.db ".backup '/data/tax-$(date +%F-%H%M%S).db'"
sqlite3 /data/tax.db 'PRAGMA integrity_check;'
```

Restore only while the service is stopped, retain the previous database, then run `PRAGMA integrity_check` and `/health` before accepting traffic.

Backups are plain SQLite copies and are not covered by the retention policy or any automatic cleanup; delete or expire them yourself. Deleting rows from the live database is not a guaranteed physical erase either — see [`PRIVACY.md`](PRIVACY.md).

## Credential rotation

1. Generate the replacement credential.
2. Update backend secret storage and restart/reload.
3. Update Mac and iOS clients.
4. Verify `/health` and confirm `tax push-doctor` reports `APNs result: sent`.
5. Revoke the old credential.

APNs `.p8` files must be mode `0600`, outside Git, and rotated independently from `TAX_API_KEY`.

## Release preflight

Run `scripts/preflight.sh`. Record commit SHA, package/app version, target environment and result. The script never uploads or deploys. Production deployment always requires a separate explicit command and confirmation.
