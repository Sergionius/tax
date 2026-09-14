# tax operations runbook

## Backend deployment

The backend runs as a systemd service behind a reverse proxy (primary variant) or as a Docker Compose container. Every deployment value comes from the private deployment configuration — `~/.config/tax/deploy.env` on the server, the file named by `TAX_DEPLOY_CONFIG`, or explicit environment variables; see [`LOCAL_CONFIGURATION.md`](LOCAL_CONFIGURATION.md) for the full contract. Deployment tooling validates the configuration and stops on missing or invalid values before touching SSH, Git, `sudo`, files, or services.

### Systemd (primary)

Prerequisites: a Linux server with systemd, Git, Python 3.11+ with venv/pip, `runuser` (util-linux), and Caddy installed using its official installation instructions. Point your domain's DNS at the server and allow inbound TCP 80/443. Keep backend ports on loopback. Commands below use a generic service user `deploy` and directory `/home/deploy/tax`; substitute your own consistently.

As root, create the service account if it does not already exist:

```bash
useradd --create-home --shell /bin/bash deploy
runuser -u deploy -- git clone https://github.com/Sergionius/tax.git /home/deploy/tax
install -d -m 700 -o deploy -g deploy /home/deploy/.config/tax
install -m 600 -o deploy -g deploy /home/deploy/tax/deploy.env.example /home/deploy/.config/tax/deploy.env
install -m 600 -o deploy -g deploy /home/deploy/tax/server/.env.example /home/deploy/tax/server/.env
install -d -m 700 -o deploy -g deploy /home/deploy/tax/keys
```

Edit both private files locally. Set all deployment values, a long random API key and your real APNs identifiers. Install your APNs `.p8` file at `TAX_DEPLOY_APNS_KEY_PATH`, owned by the service user with mode `0600`. The configured environment file must be readable by that user and have mode `0600`; it may be outside the checkout. Use simple `KEY=value` lines, quoting values with spaces. Do not source untrusted files.

The rendered Caddy block must be installed once. As root:

```bash
cd /home/deploy/tax
export TAX_DEPLOY_CONFIG=/home/deploy/.config/tax/deploy.env
./scripts/deploy-config.sh check
render_dir="$(mktemp -d)"
./scripts/deploy-config.sh render "$render_dir"
```

Inspect the rendered `Caddyfile` and add its block to `/etc/caddy/Caddyfile` using your editor, preserving other sites. Do not append a duplicate block if the domain already exists. Then validate and reload:

```bash
caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile
systemctl reload caddy
rm -r "$render_dir"
./deploy.sh
```

`deploy.sh` runs as root but performs venv installation and SQLite backups as the configured service user. It **never runs Git**. It checks the configured environment file and Caddy domain/upstream before changing the service, keeps mode-`0600` backups under the configured data directory's `backups/`, installs hash-checked dependencies, installs the rendered systemd unit and verifies authenticated health. Caddy configuration is never automatically overwritten. When changing ports, update its upstream first; deployment rejects mismatches.

For subsequent updates, as root (no service-user password needed):

```bash
cd /home/deploy/tax
export TAX_DEPLOY_CONFIG=/home/deploy/.config/tax/deploy.env
./reinstall-backend.sh
```

The reinstall script updates Git as the service user, using that user's repository access, then deploys as root. A non-root operator can run the same script if authorized for sudo; it will ask for that operator's password. From the Mac, `./scripts/deploy-backend.sh` connects to the configured SSH user and invokes this reinstall path. A sudo password is not needed for the service user when the operator already has a root session.

Dependency installation briefly stops the service before changing its venv. If it fails, the service remains stopped: fix the reported dependency/configuration problem and rerun deployment. Backups remain available; database rollback is never automatic. Do not restore an old database over a running service.

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
