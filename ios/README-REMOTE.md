# Remote Orca workspace client

The app root is now the live Orca workspace inventory. Configure the backend URL, API key, host ID, device ID, and the value printed by `tax e2ee-key generate` in Settings. API and E2EE keys are stored in iOS Keychain; routing IDs remain in preferences.

`RemoteClient` implements the v1 HKDF/ChaCha20-Poly1305 relay session. `RemoteWorkspaceStore` owns visible connection state, workspace/terminal inventory, operation acknowledgements, stream generations, reconnect, and fresh subscriptions. Input with an ambiguous acknowledgement is reported and never automatically replayed.

Terminal rendering is isolated behind `TerminalRenderer`. The first renderer embeds xterm.js 5.5 in `WKWebView`; its vendored license is in `Resources/Terminal/XTERM-LICENSE`. `TerminalView` forwards ordinary keyboard and paste input and provides Escape, Tab, Ctrl, Ctrl-C, arrows, and Enter controls. Renderer cell metrics produce terminal resize operations.

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
