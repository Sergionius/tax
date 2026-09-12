# tax operations runbook

## Push status flow

Every notification task records a `push_status`:

- `queued` — task accepted, APNs send scheduled;
- `sent` — Apple accepted the push (HTTP 2xx);
- `failed` — APNs rejected the request or was unreachable; `apns_status_code` and `apns_reason` are stored on the task;
- `skipped` — no device token, `push_mode` is `off`, or the app filter rejected the source.

Inspect a task with `GET /diagnostics/push/{task_id}` or run `tax push-doctor` on the Mac. Task `status` values beyond `pending`/`expired` belong to the removed reply pipeline and are not used by current clients.

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

## Credential rotation

1. Generate the replacement credential.
2. Update backend secret storage and restart/reload.
3. Update Mac and iOS clients.
4. Verify `/health` and confirm `tax push-doctor` reports `APNs result: sent`.
5. Revoke the old credential.

APNs `.p8` files must be mode `0600`, outside Git, and rotated independently from `TAX_API_KEY`.

## Release preflight

Run `scripts/preflight.sh`. Record commit SHA, package/app version, target environment and result. The script never uploads or deploys. Production deployment always requires a separate explicit command and confirmation.
