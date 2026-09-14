# tax remote protocol v1

The backend routes binary WebSocket messages by `host_id` and `device_id`. It rejects text frames and never persists relay traffic. A route keeps at most 64 frames while its peer is disconnected; overflow closes the source with retryable code 1013.

## Session establishment

The device creates a random 128-bit session ID and 256-bit salt and sends a binary `TAX-E2EE-1` session hello. Both peers combine these values with the separately configured 256-bit tax key using HKDF-SHA256. The HKDF context includes protocol version, host ID, device ID, and session ID and produces independent device-to-host and host-to-device keys.

Application frames use ChaCha20-Poly1305. Their authenticated data includes version, channel, direction, sequence, session ID, host ID, and device ID. Nonces combine a directional prefix with the 64-bit sequence. Duplicate and stale sequences are rejected. A reconnect always creates a new session ID and salt.

The API key authenticates the relay connection only and is not key material. The Mac tax key is stored under service `tax.remote.e2ee` in macOS Keychain:

```bash
tax e2ee-key generate
tax e2ee-key show
```

The generated value is shown once for copying to iPhone. It must not be placed in logs, source control, URLs, or backend storage.

## Channels and messages

Encrypted channel selection is application-defined; channel 1 is JSON control and channel 2 is binary terminal traffic. Control messages contain:

- `version`
- `type`
- `request_id`
- optional stable `operation_id` for mutations
- bounded `payload`

Supported types are defined by `MessageType` in `src/tax/remote_protocol.py`, covering host state, workspace/terminal inventory and operations, file operations, operation results, and protocol errors.

Terminal binary frames have a 24-byte network-order header: protocol version, opcode, reserved bytes, stream ID, generation, sequence, then payload. Generation and sequence changes force resnapshot rather than replay. The shared fixture is `tests/fixtures/remote-protocol-v1.json`.

A `terminal.subscribe` request must include the renderer's initial `columns` and `rows`, each an integer from 1 through 1000. The host uses this mobile viewport when creating the subscription, before sending the initial snapshot. Viewport changes received before the stream is established replace the pending dimensions and do not produce resize frames. Once established, the client sends only the latest viewport when it differs from the subscription viewport. Reconnects and renderer changes create a new logical subscription and repeat this initial-viewport handshake; input and resize frames from older stream generations are rejected.

## Scoped file operations

`file.list`, `file.search`, `file.read`, and `file.write` accept a `workspace_id` from the current Orca inventory plus a relative path. The Mac resolves every path against the active workspace root, rejects absolute paths, traversal, and escaping symlinks, and revokes access as soon as the workspace closes. Filename search is bounded and skips common generated directories.

Text reads and writes require UTF-8. Images are read-only previews. A read returns a SHA-256 revision; a write is atomic and succeeds only when `expected_revision` still matches. A conflict returns `file_conflict`. Overwrite requires a new request with explicit `force: true`; the client never silently replaces the Mac version.

For this file traffic the relay sees only ciphertext and does not persist file names or contents; notification delivery is a separate path described in `docs/PRIVACY.md`.

## Mac host and CLI smoke

Start the persistent Mac host with a dedicated Orca runtime pairing credential:

```bash
tax remote-host \
  --host-id mac-main \
  --device-id iphone-main \
  --orca-pairing-code-file ~/.config/tax/orca-pairing
```

The `tax remote-host` process reads the tax encryption key from macOS Keychain, connects as the host role, and exposes only tax-owned protocol messages. Workspace and terminal inventory, create/rename/close, input, resize, snapshots, and incremental output are translated by `RemoteHost`; Orca-private values remain in `OrcaRuntimeAdapter`. Terminal subscriptions use the mobile client semantics and the initial viewport supplied by the device; the tax protocol does not expose the underlying Orca subscription framing.

Before iOS is available, validate the full encrypted path with:

```bash
tax remote-smoke --host-id mac-main --device-id iphone-main --start-pi
```

The smoke creates a real Orca terminal, subscribes to its initial snapshot, sends a unique command, verifies its incremental output, optionally starts `pi`, sends Ctrl-C, and closes the fixture terminal. Input uses a stable `operation_id` and is acknowledged only after the Mac Runtime call succeeds. Ambiguous input is not automatically repeated.

## Push deep links and app lifecycle

APNs alerts carry the notification `title` and `body` (which may include a shortened response preview) plus `host_id`, optional `workspace_id`, and optional `terminal_id` routing identifiers used for deep links. The obsolete task/reply action is not exposed by the iOS app. See `docs/PRIVACY.md` for the exact visibility boundaries. A destination is persisted until SwiftUI consumes it. The app validates the host against its configuration and reports a closed workspace or terminal instead of navigating to stale state.

The iOS app does not claim background WebSocket execution. Entering the background closes the relay connection; foreground activation creates a new E2EE session, refreshes inventory, and resubscribes the visible terminal for a fresh snapshot. Unacknowledged terminal input is still never replayed.

Mac diagnostics log only protocol counters, Orca version/compatibility state, and capability counts. They do not log workspace paths, IDs, terminal output, input, file names, file contents, credentials, or encryption keys.

## Limits

- control message: 256 KiB;
- encrypted WebSocket frame: 8 MiB;
- relay offline queue: 64 frames per source connection;
- directory page: 200 entries; filename search: 200 results;
- editable UTF-8 text: 2 MiB; image preview: 10 MiB;
- terminal stream and operation retries remain conservative: ambiguous input is never replayed.
