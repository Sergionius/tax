# Remote Orca workspace client

The app root is now the live Orca workspace inventory. Configure the backend URL, API key, host ID, device ID, and the value printed by `tax e2ee-key generate` in Settings. API and E2EE keys are stored in iOS Keychain; routing IDs remain in preferences.

`RemoteClient` implements the v1 HKDF/ChaCha20-Poly1305 relay session. `RemoteWorkspaceStore` owns visible connection state, workspace/terminal inventory, operation acknowledgements, stream generations, reconnect, and fresh subscriptions. Input with an ambiguous acknowledgement is reported and never automatically replayed.

Terminal rendering is isolated behind an independent tax-owned renderer contract. SwiftTerm 1.20.0 is the only bundled terminal renderer. The contract covers renderer readiness with a viewport, viewport changes, binary input, snapshot reset/application completion, incremental bytes, and focus. A future libghostty adapter must implement only this contract; it must not change `RemoteWorkspaceStore`, the remote protocol, or the Mac host.

`TerminalView` forwards ordinary keyboard and paste input and provides Escape, Tab, Ctrl, Ctrl-C, arrows, and Enter controls. Renderer cell metrics produce terminal resize operations.

### Terminal renderer acceptance

Using a live Orca terminal session on a physical iPhone, verify the only bundled SwiftTerm renderer:

1. Verify that the initial snapshot appears as one complete screen.
2. Create substantial scrollback and verify smooth scrolling and a stable position while output arrives.
3. Type rapidly and verify that input is neither delayed nor duplicated.
4. Open the keyboard and verify that the active prompt remains visible; close it and verify the viewport recovers.
5. Run a TUI program such as `pi` or `vim` in its alternate screen and verify that it renders and accepts input correctly.
6. Reconnect and verify that the screen is restored from the new snapshot without mixing generations.

Development validation:

```bash
xcodebuild build-for-testing \
  -project ios/tax/tax.xcodeproj \
  -scheme tax \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO
```

`RemoteProtocolTests` contains the same deterministic crypto contract vector as Python and validates the terminal binary header. End-to-end relay/Orca validation remains available through `tax remote-smoke --start-pi`.

Phase 3 acceptance was also exercised through the Simulator UI against a live local relay and Orca Runtime: the app loaded open workspaces, opened an existing TUI with ANSI fidelity, created a terminal, typed `pi`, pressed the accessory Enter key, rendered Pi, and sent Ctrl-C.

Phase 4 adds a workspace-scoped file browser, bounded filename search, UTF-8 editor, native Markdown preview, and read-only image preview. Saves carry the revision returned by the Mac; conflicts require an explicit Reload or Overwrite choice, and leaving a modified editor requires discard confirmation.

Phase 5 removes the task conversation/reply UI. Pushes now deep-link to a configured host, workspace, or terminal. Backgrounding intentionally closes the WebSocket; foregrounding negotiates a new encrypted session, refreshes inventory, and requests a fresh terminal snapshot rather than relying on unsupported background execution.
