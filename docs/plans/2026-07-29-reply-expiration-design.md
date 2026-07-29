# Reply expiration and safe delivery

## Goal

Prevent stale iPhone replies from reaching an unrelated agterm pane and stop tracking tasks that are no longer useful.

## Design

A task may accept a reply for 30 minutes after `created_at`. Both the backend and Mac agent expire unanswered `pending` tasks after that deadline. An accepted reply also expires if it waits 30 minutes without delivery. `expired` is terminal: the agent does not poll it through the legacy per-task endpoint, and the backend rejects a late reply with HTTP 409.

The agent probes the aggregate `/replies` endpoint on every polling cycle. A 404 enables legacy polling only for that cycle, so an upgraded or recovered backend is detected automatically.

Delivery requires a non-empty `agterm_session_id`. Missing session metadata causes an immediate terminal `delivery_failed` acknowledgement. The agent never substitutes the currently active agterm session.

## Error handling

A closed session or missing session ID is not retried. Existing pending-sync states continue protecting successfully or unsuccessfully injected replies from duplicate delivery when backend acknowledgement fails. A stale reply returned by an older backend is ignored when its local task is already terminal.

## Verification

Regression tests cover 30-minute local/backend expiration, rejection of late replies, endpoint re-probing after a legacy fallback, and refusal to inject a reply without a session ID.
