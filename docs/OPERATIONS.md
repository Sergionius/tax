# tax operations runbook

## Status flow

`pending → replied → delivered` is the successful path. `delivery_failed` is terminal. The Mac agent may temporarily keep `delivered_pending_sync` or `delivery_failed_pending_sync` while the backend is unavailable; these states prevent duplicate text injection.

## Backend outage

1. Check `GET /health` with the bearer credential.
2. Check service and reverse-proxy logs.
3. Verify the SQLite filesystem is writable and has free space.
4. Restart the service only after preserving logs. The Mac agent recovers replies after backend recovery while the 30-minute reply window remains open.
5. Confirm pending replies with `GET /replies`; do not submit them manually unless the local agent state has been inspected.

## APNs failures

- `400`: inspect APNs reason and payload shape.
- `403`: verify Key ID, Team ID, bundle ID and `.p8` permissions.
- `410`: remove/replace the expired device token.
- `429`: reduce retries and respect APNs backoff.
- Sandbox tokens require the development APNs host; TestFlight uses production.

Never paste API keys, provider JWTs, full device tokens, context or reply text into tickets or logs.

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
4. Verify `/health`, create a test task and complete one reply flow.
5. Revoke the old credential.

APNs `.p8` files must be mode `0600`, outside Git, and rotated independently from `TAX_API_KEY`.

## Release preflight

Run `scripts/preflight.sh`. Record commit SHA, package/app version, target environment and result. The script never uploads or deploys. Production deployment always requires a separate explicit command and confirmation.
