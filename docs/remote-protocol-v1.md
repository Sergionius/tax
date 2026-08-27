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

## Mac host and CLI smoke

Start the persistent Mac host with a dedicated Orca runtime pairing credential:

```bash
tax remote-host \
  --host-id mac-main \
  --device-id iphone-main \
  --orca-pairing-code-file ~/.config/tax/orca-pairing
```

`tax-agent` reads the tax encryption key from macOS Keychain, connects as the host role, and exposes only tax-owned protocol messages. Workspace and terminal inventory, create/rename/close, input, resize, snapshots, and incremental output are translated by `RemoteHost`; Orca-private values remain in `OrcaRuntimeAdapter`.

Before iOS is available, validate the full encrypted path with:

```bash
tax remote-smoke --host-id mac-main --device-id iphone-main --start-pi
```

The smoke creates a real Orca terminal, subscribes to its initial snapshot, sends a unique command, verifies its incremental output, optionally starts `pi`, sends Ctrl-C, and closes the fixture terminal. Input uses a stable `operation_id` and is acknowledged only after the Mac Runtime call succeeds. Ambiguous input is not automatically repeated.

## Limits

- control message: 256 KiB;
- encrypted WebSocket frame: 8 MiB;
- relay offline queue: 64 frames per source connection;
- terminal stream and operation retries remain conservative: ambiguous input is never replayed.
