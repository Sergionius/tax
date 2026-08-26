# Task status contract

| Status | Meaning | Next status |
|---|---|---|
| `pending` | Task is stored, no reply yet | `replied`, `expired` |
| `replied` | Backend has a reply waiting for the Mac agent | `delivered`, `delivery_failed`, `expired` |
| `delivered` | Reply was accepted by the target Orca terminal | terminal |
| `delivery_failed` | Reply could not be inserted and will not be retried automatically | terminal |
| `expired` | No reply was accepted within 30 minutes, or a reply waited 30 minutes without delivery | terminal |

The Mac agent also uses local-only synchronization states `delivered_pending_sync` and `delivery_failed_pending_sync`. They mean the Orca delivery result is already known but the backend acknowledgement failed. A reply in either state must never be injected again.

A reply without `orca_terminal_handle` must become `delivery_failed`; it must never be sent to the active terminal as a fallback. A stale handle may be replaced only by a unique writable terminal matching the saved Orca tab and pane leaf. Unknown states must be displayed defensively by clients and must not be treated as deliverable by the Mac agent.
