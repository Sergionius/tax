# Orca Runtime compatibility

The private Orca protocol is used only by the Mac-side `OrcaRuntimeAdapter`. It is not part of the tax remote protocol and must never be implemented in the backend or iOS app.

## Pinned build

| tax probe | Orca version | Orca commit | Runtime daemon protocol | Result |
|---|---:|---|---:|---|
| Phase 0 | 1.4.188 | `2b1254d68192676e04674c2826e5f8f63992f1ad` | 36 | inventory, snapshot, and incremental stream verified |

Observed runtime capabilities required by the adapter:

- `terminal.binary-stream.v1`
- `terminal.multiplex.v1`
- `runtime.status.compat.v1`

## Discovery and authentication

Orca writes `orca-runtime.json` in its user-data directory. The file identifies the runtime generation and available transports:

- authenticated newline-delimited JSON RPC on a local Unix socket;
- an E2EE WebSocket used for streaming methods.

The Unix socket authenticates with the per-runtime token in the metadata file. It supports one-shot methods such as `status.get`, `worktree.ps`, `terminal.list`, and `terminal.read`, but intentionally rejects streaming methods.

The WebSocket requires an Orca pairing offer. Its handshake uses an ephemeral Curve25519 key pair and the public key pinned in the offer. After authentication, `terminal.multiplex` carries JSON control events plus encrypted binary terminal frames. Pairing credentials are secrets: do not put them in command-line arguments, logs, fixtures, or Git. The probe accepts them only through `TAX_ORCA_PAIRING_CODE` or a mode-0600 file.

## Terminal stream

`terminal.multiplex` starts as a streaming RPC, then accepts a binary `Subscribe` frame on control stream 0. Each terminal gets a positive stream ID. Binary frames use a 16-byte little-endian header followed by a payload:

- byte 0: kind (`0x74`)
- byte 1: version (`1`)
- byte 2: opcode
- byte 3: reserved
- bytes 4–7: stream ID
- bytes 8–15: sequence number (high word, then low word)

A subscription emits `SnapshotStart`, one or more `SnapshotChunk` frames, and `SnapshotEnd` before incremental `Output`/`OutputSpan` frames. Flow-controlled output must be acknowledged. A sequence gap or reconnect requires a new snapshot; input must not be replayed automatically.

## Probe

```bash
# Credential-free inventory through local authenticated RPC
scripts/orca-runtime-probe.cjs inventory

# True snapshot + incremental stream through Orca's E2EE WebSocket
scripts/orca-runtime-probe.cjs stream \
  --terminal term_… \
  --pairing-code-file ~/.config/tax/orca-probe-pairing \
  --duration-ms 5000
```

The probe dynamically loads protocol helpers shipped by the installed Orca build. This is deliberate: a missing helper or changed wire contract produces an explicit compatibility failure instead of silently parsing the wrong protocol.

## Mac runtime adapter

`src/tax/orca_runtime.py` is the stable boundary consumed by the future remote host. It exposes tax-owned workspace, terminal, event, and diagnostic models while containing all private Orca method names and response mapping.

Control operations use authenticated local Runtime RPC. Terminal subscriptions use the packaged `orca-runtime-terminal-bridge.cjs`, which maintains Orca's E2EE WebSocket and multiplexes snapshot, incremental output, input, resize, and resnapshot frames. The bridge is shipped inside the Python wheel; `scripts/orca-runtime-terminal-bridge.cjs` is a development wrapper.

The adapter requires a dedicated Orca pairing code for streaming. Create it through Orca's pairing UI and save it in a mode-0600 file. Do not copy tokens directly from Orca's private device registry. This credential authenticates tax-agent to the local Orca Runtime and is separate from the tax E2EE key introduced in Phase 2.

Mutating one-shot RPC calls are never retried because a disconnected response has an ambiguous outcome. Read-only calls use bounded exponential backoff. Stream reconnect belongs to the remote host lifecycle: discard the old generation and request a fresh subscription/snapshot rather than replaying input.

## Update smoke test

After every Orca update:

1. update the version, commit, and daemon protocol row above;
2. run inventory and confirm open workspaces/terminals match `orca worktree ps` and `orca terminal list`;
3. subscribe to a fixture terminal and confirm a complete snapshot;
4. emit a unique line in that PTY and confirm it arrives once as incremental output;
5. interrupt the connection and confirm a new subscription starts from a fresh snapshot;
6. regenerate only sanitized fixtures.

Never commit runtime metadata, device tokens, pairing URLs, public/private key material, absolute user paths, terminal output, or command contents.
