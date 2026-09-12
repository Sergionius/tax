# Claude Code and Codex notification hooks

## Goal

Provide the same Orca-terminal-aware completion push used by the Pi extension without changing Pi's extension lifecycle or implementation.

## Architecture

Claude Code and Codex invoke the existing `tax` executable when an agent turn finishes. Claude Code uses a `Stop` command hook and writes JSON to standard input. Codex uses its `notify` command and appends an `agent-turn-complete` JSON object as the final argument.

The `tax notify <provider>` command normalizes either event into a common notification containing a short preview, the final assistant message, basic session context, and routing metadata from the Orca environment. It sends that notification to the existing authenticated `/push` endpoint. The backend and iOS application require no new protocol or endpoint.

The Pi integration remains in `extensions/tax-push.ts` and is not routed through the Python adapter. This preserves Pi-specific session and failure analysis and avoids introducing a subprocess into its existing extension path.

## Safety and failure behavior

Hooks are best-effort and always exit successfully so a backend outage or invalid TAX configuration cannot block agent shutdown. Errors are silent unless `TAX_PUSH_DEBUG=1` is set. A notification is skipped outside an Orca terminal because it cannot provide a valid terminal deep link.

Only the final assistant message is used. The Claude transcript file is never opened. Payload fields use the same limits as the backend and Pi extension. Successfully sent event hashes are retained in a private local state file to suppress duplicate hook invocations.

## Verification

Unit tests cover both provider formats, payload bounds, Orca routing metadata, deduplication, and best-effort failure behavior. README instructions document the user-level Claude Code and Codex configuration.
