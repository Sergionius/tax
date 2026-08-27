# tax Remote Orca Workspace — Design

Date: 2026-08-27
Status: accepted

## 1. Goal

Turn the iOS `tax` app from a list of completed push tasks into a live remote client for the Orca instance running on one Mac.

The primary experience is a real interactive terminal. The user can inspect open Orca projects and terminals, open an existing terminal, create a terminal, type commands such as `pi`, and interact with the resulting TUI running on the Mac. File browsing and safe text editing are supporting features.

Push notifications no longer open a stored task conversation. They route directly to the relevant live workspace and terminal.

## 2. Accepted product decisions

- Replace the current task/conversation UI rather than retain an Inbox tab.
- Show only workspaces/worktrees currently open in Orca.
- Support one Mac in the first release; include `host_id` in the protocol for future multi-host support.
- Use the internal Orca Runtime protocol for low-latency terminal subscriptions rather than polling the public CLI.
- Isolate the private Orca protocol in a Mac-side adapter so iOS and backend do not depend on it.
- Keep the iOS app native SwiftUI.
- Render terminals with `xterm.js` in `WKWebView` behind a `TerminalRenderer` abstraction. This allows a future `libghostty` renderer.
- First-release terminal controls: view and type in existing terminals; send Enter, Ctrl-C and special keys; create, rename and close terminals.
- File controls: tree, filename search, text viewing/editing, Markdown preview, image preview, and conflict-safe saves.
- Keep manual backend URL and API-key configuration.
- Add a separate 256-bit encryption key configured on both Mac and iPhone and stored in Keychain.
- Backend is an E2EE relay and does not store terminal output, commands, or file contents.

## 3. Scope

### 3.1 First release

- Live connection-state display.
- Open Orca workspace/worktree inventory.
- Terminal inventory and status.
- Full terminal snapshot and incremental PTY streaming.
- Terminal input, resize, Enter, Escape, Tab, arrows, Ctrl and Ctrl-C.
- Create, rename and close terminal.
- File tree and filename search within an open worktree.
- Read text, Markdown and supported images.
- Edit and save text with revision conflict detection.
- Push deep links to a host, workspace and terminal.
- Reconnect by requesting a fresh snapshot.
- Protocol and Orca compatibility diagnostics.

### 3.2 Deferred

- Multiple Macs in the UI.
- Creating or deleting worktrees from iOS.
- Split-pane creation and layout editing.
- Full source-control UI, commits, PRs, issue integrations, browser and design mode.
- Offline terminal interaction.
- Server-side scrollback or file history.
- Rich IDE editing, language servers and binary-file editing.
- Chat projection of agent output.

## 4. Architecture

```text
Orca Runtime
    ↕ local WebSocket / private RPC
Mac tax-agent
    - OrcaRuntimeAdapter
    - Remote protocol host
    - scoped file service
    - E2EE session
    ↕ encrypted WebSocket
FastAPI backend relay
    - authentication
    - host/device routing
    - ciphertext forwarding
    ↕ encrypted WebSocket
iOS SwiftUI app
    - host/workspace/terminal stores
    - E2EE session
    - TerminalRenderer
    - file browser/editor
```

### 4.1 Mac agent

`tax-agent` becomes a persistent remote host. Its `OrcaRuntimeAdapter` owns all knowledge of Orca's internal handshake, RPC methods, graph snapshots, terminal subscriptions and binary frames.

The adapter exposes a stable internal interface:

- `list_workspaces()`
- `watch_workspace_graph()`
- `list_terminals(workspace_id)`
- `subscribe_terminal(terminal_id)`
- `send_terminal_input(terminal_id, bytes)`
- `resize_terminal(terminal_id, columns, rows)`
- `create_terminal(workspace_id, title?)`
- `rename_terminal(terminal_id, title)`
- `close_terminal(terminal_id)`

File access does not depend on the Orca wire protocol. It operates locally through a scoped service whose roots are derived only from the currently open workspace inventory.

### 4.2 Backend

The existing FastAPI backend gains a WebSocket relay alongside the current APNs endpoints. It authenticates both roles with the existing API key and routes connections by `host_id` and `device_id`.

It may inspect only a small routing envelope. Application payloads are encrypted. It keeps no durable terminal, command, or file data. Bounded in-memory queues may absorb short bursts, but overflow closes or resynchronizes the affected stream instead of growing without limit.

### 4.3 iOS

The existing conversation screens are replaced by workspace, terminal and file flows. Networking, encryption and terminal rendering are separate modules. The UI consumes only the versioned tax remote protocol and is independent of Orca's private RPC.

## 5. Remote protocol

The protocol is versioned independently from the app and Orca adapter. It has a JSON control channel and binary terminal frames.

Core messages:

- `host.hello`
- `host.snapshot`
- `host.state`
- `workspace.list`
- `terminal.list`
- `terminal.subscribe`
- `terminal.snapshot`
- `terminal.output`
- `terminal.input`
- `terminal.resize`
- `terminal.create`
- `terminal.rename`
- `terminal.close`
- `file.list`
- `file.search`
- `file.read`
- `file.write`
- `operation.result`
- `protocol.error`

Each request carries `request_id`. Mutating control operations carry a stable `operation_id` so the Mac can deduplicate them. Terminal input is handled more conservatively: the Mac acknowledges only after Orca Runtime accepts the bytes, and clients do not automatically replay input whose delivery is ambiguous.

A terminal subscription begins with a complete snapshot and stream generation. Incremental frames belong to that generation. If frames are missed, reordered, or received after a reconnect, iOS discards them and requests a new snapshot.

## 6. E2EE and authentication

The API key authenticates access to the backend but is not used as the E2EE secret. The user configures a separate random 256-bit encryption key on Mac and iPhone. The Mac command `tax e2ee-key generate` creates a suitable value. Both platforms store it in Keychain.

For every connection, peers establish a new session identifier and salt and derive directional keys with HKDF. Payloads use ChaCha20-Poly1305. Authenticated metadata includes protocol version, host ID, device ID, session ID, channel and sequence number.

Sequence tracking rejects duplicate and stale frames. Fresh session identifiers prevent replay across reconnects. Logs must redact API keys, encryption keys, plaintext commands, terminal bytes and file contents.

## 7. User interface

### 7.1 Workspace list

The root screen lists only open Orca workspaces, grouped by project. Rows show worktree name, branch, terminal count and summarized agent state. The navigation bar shows Mac connectivity and offers refresh/settings.

### 7.2 Workspace screen

A workspace has terminal and file destinations. The terminal list allows opening, creating, renaming and closing terminals. Closing a running terminal requires confirmation.

### 7.3 Terminal screen

The terminal fills the available area. `xterm.js` runs in `WKWebView` through a `TerminalRenderer` protocol supporting initialization, snapshot restore, byte writes, resize, clear, selection and input callbacks.

A keyboard accessory exposes Escape, Tab, Ctrl, arrow keys and Ctrl-C. Normal keyboard input and paste are sent as terminal bytes. Typing `pi` and Enter starts Pi in the real Orca PTY on the Mac.

The viewport calculates columns and rows from rendered cell metrics and sends resize events after layout or orientation changes.

### 7.4 Files

The file tab provides a lazy directory tree and filename search. Text opens in an editor, Markdown can switch to preview, and supported images open in a viewer.

Every read returns a revision hash. Writes include the expected revision. A mismatch returns `file_conflict`; iOS offers reload or an explicit force-save rather than overwriting silently.

### 7.5 Push routing

APNs payloads include `host_id`, `workspace_id` and `terminal_id`. Opening a notification connects to the Mac and navigates to that terminal. If it no longer exists, the app opens the workspace and explains that the target closed.

## 8. File-system safety

The Mac file service accepts only workspace-relative paths. Before every operation it resolves and canonicalizes the path, verifies that it remains under an active worktree root, and rejects escaping symlinks and traversal.

Initial limits:

- bounded directory page size;
- bounded search result count;
- bounded editable text-file size;
- image size limits;
- no binary writes;
- no access outside open worktrees.

Workspace closure immediately revokes its file root and subscriptions.

## 9. Lifecycle and failure behavior

Visible connection states:

- `connecting`
- `online`
- `mac_offline`
- `orca_offline`
- `incompatible`
- `reconnecting`

When iOS backgrounds, live terminal subscriptions close. APNs remains available. Foreground recovery re-establishes E2EE and requests fresh host and terminal snapshots.

On network loss, the terminal may retain the last rendered snapshot but becomes read-only. An unacknowledged terminal input is reported as ambiguous and is not repeated automatically. File writes are successful only after a positive Mac acknowledgement.

If Orca's private protocol changes, the adapter reports `runtime_incompatible` with Orca and adapter versions. It must back off rather than enter a crash loop. The rest of `tax-agent`, backend and iOS remain operational for diagnostics.

## 10. Testing

### 10.1 Unit

- Encryption/decryption, HKDF context and nonce construction.
- Replay, stale sequence and session-generation rejection.
- Frame parsing, limits and backpressure.
- Idempotent operation handling.
- Terminal snapshot generation transitions.
- Path containment and escaping symlinks.
- File revision and conflict behavior.

### 10.2 Contract

Maintain shared JSON fixtures for Python, backend and Swift implementations. Verify every control message, error and binary-frame header across languages.

### 10.3 Orca adapter

Run against an installed Orca with a fixture workspace and terminal. Test handshake, graph inventory, snapshot, stream, input, resize, create, rename and close. A focused compatibility smoke runs after every Orca update.

### 10.4 Backend

Test role authentication, host routing, peer disconnects, queue limits, frame-size limits, and prove that relay persistence contains no plaintext payload.

### 10.5 iOS

Test workspace loading, terminal navigation, keyboard controls, renderer snapshot/write ordering, reconnect, terminal creation, file viewing, conflict handling and push deep links.

### 10.6 End to end

Create a temporary workspace and Orca terminal, send a unique command from an iOS test client, assert exact output, interrupt/reconnect the relay, and verify recovery from a fresh terminal snapshot. A second flow starts `pi` and verifies that the interactive process appears in the Mac terminal.

## 11. Implementation sequence

### Phase 0 — Orca protocol investigation

1. Pin the current Orca commit/version.
2. Trace runtime discovery, handshake and authentication.
3. Trace workspace graph and terminal subscription frames.
4. Build a read-only probe that lists open workspaces and prints terminal output.
5. Document a compatibility matrix and captured sanitized fixtures.

Exit: a standalone probe can observe a live existing Orca terminal reliably.

### Phase 1 — Stable Mac runtime boundary

1. Add `WorkspaceRuntime` and terminal event models.
2. Implement `OrcaRuntimeAdapter` behind that interface.
3. Support inventory, snapshot, stream, input and resize.
4. Add create, rename and close.
5. Add reconnect/backoff and incompatibility diagnostics.

Exit: local tests can run `pi` in a real Orca PTY through the adapter.

### Phase 2 — Remote protocol and E2EE

1. Define protocol schemas, limits and binary headers.
2. Implement Keychain-backed encryption-key configuration on Mac.
3. Implement HKDF, ChaCha20-Poly1305 and replay protection.
4. Add the FastAPI WebSocket relay and routing.
5. Connect Mac-agent and a command-line test client through production-like relay conditions.

Exit: encrypted remote terminal streaming and input work without iOS.

### Phase 3 — iOS workspace and terminal MVP

1. Replace the conversation root with workspace navigation.
2. Add Swift WebSocket/E2EE client and connection state.
3. Add workspace and terminal stores.
4. Add `TerminalRenderer` and xterm/WKWebView implementation.
5. Add input composer, accessory keys, resize, reconnect and snapshots.
6. Add create, rename and close controls.

Exit: the iPhone can create a Mac terminal, type `pi`, and interact with it.

### Phase 4 — Files

1. Implement scoped Mac file service.
2. Add list/search/read/write protocol operations.
3. Add file tree, editor, Markdown preview and image preview.
4. Add revision conflict UI and size/binary guards.

Exit: safe file inspection and text editing work inside an open worktree.

### Phase 5 — Push migration and hardening

1. Change pushes to host/workspace/terminal deep links.
2. Remove obsolete task conversation UI and reply flow.
3. Add background/foreground recovery.
4. Add queue limits, metrics, redacted diagnostics and compatibility reporting.
5. Run end-to-end, security and Orca-update smoke suites.

Exit: the old task UI is gone and release acceptance criteria pass.

## 12. Acceptance criteria

- The app lists the open workspaces and terminals from the configured Mac's Orca instance.
- Existing terminal output appears with ANSI/TUI fidelity and low interactive latency.
- Input typed on iPhone reaches the exact selected Orca PTY.
- A user can create a terminal, type `pi`, press Enter and interact with Pi running on Mac.
- Rename, close, special keys, Ctrl-C and terminal resize work.
- Reconnect produces a correct fresh snapshot without duplicated commands.
- Files are accessible only under active worktree roots.
- Conflicting file saves never overwrite silently.
- Backend cannot read or persist terminal, command or file plaintext.
- An incompatible Orca update produces an actionable diagnostic rather than silent failure or a crash loop.
