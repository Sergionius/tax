# tax (Task Agent eXchange) — remote Orca workspace for iPhone

A self-hosted, end-to-end encrypted iPhone remote for Orca.

`tax` connects your iPhone to open Orca workspaces and terminals on your Mac through a relay you control. The app renders ANSI/TUI output, sends input to the selected PTY, creates and closes terminals, runs console agents (pi, Claude Code, Codex) and any CLI program, and lets you browse and edit workspace files safely.

## Why TAX when Orca already has a mobile app?

[Orca Mobile](https://www.onorca.dev/docs/mobile) is the best choice for most Orca users. It provides a rich, official companion experience with Chat UI, source control, browser access, agent accounts, notifications, and many other features. It also protects traffic with end-to-end encryption.

TAX serves a narrower use case: remote access through infrastructure you control.

- Run the relay on your own server.
- Connect without exposing the Orca runtime to the public Internet.
- Use remote access without depending on Orca Relay or an Orca cloud account.
- Keep terminal and file traffic end-to-end encrypted with a key unavailable to the relay.
- Expose only terminals, workspace inventory, and scoped file operations.
- Send terminal-aware completion notifications from Pi, Claude Code, Codex, or any command wrapped with `tax run`.
- Control deployment, authentication, retention, APNs, and application code.

TAX is not a replacement for the full Orca Mobile experience. It is a small, self-hosted remote-access layer for users who prioritize infrastructure ownership, data minimization, and operational control. Its end-to-end encryption is not a differentiator over Orca Mobile; the difference is owning the infrastructure and the deliberately narrower feature set.

## Screenshots

<table>
  <tr>
    <td align="center"><img src="docs/images/workspaces.png" width="280" alt="Remote workspace list"><br><sub>Remote workspaces</sub></td>
    <td align="center"><img src="docs/images/terminal.png" width="280" alt="Remote agent terminal"><br><sub>Agent terminal</sub></td>
  </tr>
  <tr>
    <td align="center"><img src="docs/images/files.png" width="280" alt="Workspace file browser"><br><sub>Workspace files</sub></td>
    <td align="center"><img src="docs/images/settings.png" width="280" alt="Self-hosted connection settings"><br><sub>Self-hosted settings</sub></td>
  </tr>
</table>

All screenshots use deterministic demo data. No live server, credentials, device tokens, workspace paths, or terminal sessions are included.

## How it works

- **Orca Runtime on the Mac** — the source of workspaces and terminals.
- **tax remote host on the Mac** — an adapter to Orca's private protocol plus a scoped file service.
- **Backend on your server** — relays end-to-end encrypted terminal and file traffic as ciphertext, and separately handles agent notifications, which arrive over HTTPS with content the backend processes and forwards to Apple via APNs.
- **iOS app** — a SwiftUI client with SwiftTerm 1.20.0 as the only bundled terminal renderer.
- **E2EE** — a separate 256-bit tax key that the backend never receives.

The terminal renderer is connected through an independent tax-owned contract: readiness with a viewport, viewport changes, binary input, reset/application snapshot, incremental bytes, and focus. Only SwiftTerm implements this contract today; a future libghostty adapter must implement the same contract without changing `RemoteWorkspaceStore`, the remote protocol, or the Mac host.

The backend never receives terminal input/output or file contents. Ambiguously delivered terminal input is never replayed automatically. See [`docs/PRIVACY.md`](docs/PRIVACY.md) for what is encrypted, what the backend and Apple can see, and what is stored.

## Requirements

- Orca running on a Mac. The Mac must stay powered on and awake (for example with `caffeinate` or Energy settings) whenever you want to connect; the relay and the Orca runtime both live there.
- The `tax` CLI on the Mac (`./scripts/install.sh`).
- The backend deployed on your own server (systemd or Docker Compose; see [`docs/OPERATIONS.md`](docs/OPERATIONS.md)).
- An iPhone with the tax app. You must build and sign the app yourself with your own Apple Developer team and bundle identifier, and configure your own APNs key: push notifications are tied to the signing identity (the APNs topic is the app's bundle ID), so a prebuilt binary signed by someone else cannot receive your pushes.
- Four matching values:
  - backend API key;
  - tax E2EE key;
  - Host ID, typically `mac-main`;
  - Device ID, typically `iphone-main`.

The API key, E2EE key, and Orca pairing code are secrets. Never put them in Git, messages, screenshots, or logs.

## Setup

### 1. Deploy the backend

Full systemd and Docker Compose instructions, including the reverse proxy, environment file, and health checks, are in [`docs/OPERATIONS.md`](docs/OPERATIONS.md). Note the server URL and the API key stored in the backend environment file.

### 2. Configure the CLI on the Mac

```bash
read -s 'TAX_KEY?Backend API key: '; echo
tax config \
  --server https://tax.example.com \
  --api-key "$TAX_KEY"
unset TAX_KEY
```

Use your own backend domain in place of `https://tax.example.com`.

### 3. Generate the tax E2EE key

On the Mac, generate a separate key:

```bash
tax e2ee-key generate
```

It is stored in the macOS Keychain under the service `tax.remote.e2ee`. To show it again and copy it to the clipboard:

```bash
tax e2ee-key show | pbcopy
```

Paste this value into the **256-bit encryption key** field on the iPhone. The backend never receives this key.

### 4. Pair the Mac host with Orca

1. Open Orca on the Mac.
2. Open **Settings → Runtime Environments**.
3. In the **Share this Orca server** section, click **New Link**.
4. Generate the link and choose **Copy pairing URL**.
5. Save the URL to a protected file:

```bash
mkdir -p ~/.config/tax
install -m 600 /dev/null ~/.config/tax/orca-pairing
pbpaste > ~/.config/tax/orca-pairing
chmod 600 ~/.config/tax/orca-pairing
```

Use the runtime pairing URL from **Share this Orca server**. The copy button in the **Orca Mobile** section may produce a mobile/relay offer of a different format that `tax remote-host` rejects. The pairing URL belongs to the Orca Runtime and is not a substitute for the tax E2EE key.

### 5. Connect the iPhone

Open the gear icon in the app and fill in:

| Field | Value |
|---|---|
| Server URL | your backend URL, for example `https://tax.example.com` |
| API Key | the value from the backend environment file |
| Host ID | `mac-main` |
| Device ID | `iphone-main` |
| 256-bit encryption key | the output of `tax e2ee-key show` |

Tap **Save Settings**, then **Request Push Registration**. The device token is registered on the backend automatically.

### 6. Run the Mac host in the background

Install the user LaunchAgent:

```bash
./scripts/install-remote-host-launch-agent.sh
```

It starts after macOS login, runs without an open Terminal, and restarts the host automatically after a drop. The API key comes from `tax config`, the E2EE key from the Keychain, and the pairing code from `~/.config/tax/orca-pairing`.

Inspect and control it with:

```bash
launchctl print gui/$UID/tax.remote-host
launchctl kickstart -k gui/$UID/tax.remote-host
tail -f ~/.local/state/tax/logs/remote-host.log
```

For other identifiers:

```bash
./scripts/install-remote-host-launch-agent.sh \
  --host-id mac-main \
  --device-id iphone-main \
  --pairing-code-file ~/.config/tax/orca-pairing
```

Manual foreground mode remains available for diagnostics:

```bash
tax remote-host \
  --host-id mac-main \
  --device-id iphone-main \
  --orca-pairing-code-file ~/.config/tax/orca-pairing
```

The indicator in the top-left corner of the app should turn green and show `online`. The Mac must be powered on and awake, and Orca must be running.

### 7. Verify

1. Open a workspace.
2. Open an existing terminal and check the ANSI/TUI output.
3. Create a new terminal with the `+` button.
4. Run an agent such as `pi` or `claude` and press `enter`.
5. Check `Ctrl-C`, resize, rename, and close.
6. Open **Browse workspace files**, a text file, the Markdown preview, and an image.

For the terminal renderer acceptance steps, see [`ios/README-REMOTE.md`](ios/README-REMOTE.md). To verify the backend and APNs end to end, run on the Mac:

```bash
tax doctor
tax push-doctor
```

A successful `APNs result: sent` with HTTP `200` means Apple accepted the push. Whether a banner is shown also depends on the iPhone's Notifications permissions, Focus, and Scheduled Summary.

## Agent notifications

### Completion pushes with `tax run`

`tax run` turns any command into a completion notification. For example, on the Mac:

```bash
tax run pytest -q
```

How it works:

- the command runs directly, without a shell; stdout and stderr are combined and streamed to the current terminal;
- after the process exits, exactly one completion push is sent: the title is built from the executable name (`pytest completed` or `pytest failed`), the body contains the exit code, `context` carries the original command, and `logs` carries the last 500 lines of output;
- metadata includes `source=tax-cli`, `app=tax`, the executable name in the `agent` field, the Host ID from `TAX_HOST_ID` (default `mac-main`), and the Orca routing fields `ORCA_TERMINAL_HANDLE`, `ORCA_WORKTREE_ID` (falling back to `ORCA_WORKSPACE_ID`), `ORCA_TAB_ID`, `ORCA_PANE_KEY`;
- `tax run` returns the original exit code of the command; a failed push delivery does not change it, and there are no retries or response waits — the notification is one-way;
- the device token is stored on the backend: the iPhone registers it with **Request Push Registration**, and if no token is set in `tax config`, the backend uses the latest registration.

Without `ORCA_TERMINAL_HANDLE` the push is still sent, but on the iPhone it opens only the configured host without a specific terminal.

### Pi, Claude Code, and Codex

TAX can send the same terminal-aware completion notifications for Pi, Claude Code, and Codex. Pi uses `extensions/tax-push.ts`; enabling the hooks below does not change or replace the Pi extension.

Before enabling a hook:

1. Install the CLI with `./scripts/install.sh` and confirm that `tax` is available in `PATH`.
2. Configure the backend with `tax config`.
3. Run the agent inside an Orca terminal. TAX intentionally skips the notification when `ORCA_TERMINAL_HANDLE` is unavailable, because the iPhone would not have a terminal to open.

#### Claude Code

Merge this `Stop` hook into `~/.claude/settings.json`:

```json
{
  "hooks": {
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "tax notify claude"
          }
        ]
      }
    ]
  }
}
```

Claude Code writes the hook event to standard input. TAX uses only the final assistant message and event metadata; it does not read the transcript file. Claude Code hooks are disabled when Claude is started with `--bare`.

#### Codex

Add the following top-level setting to `~/.codex/config.toml`:

```toml
notify = ["tax", "notify", "codex"]
```

Codex appends the `agent-turn-complete` JSON event as the final command-line argument.

Both adapters include the Orca terminal/worktree identifiers from the environment, post to the existing `/push` endpoint, and exit successfully even if notification delivery fails. Duplicate completion events are suppressed locally. To print hook errors during setup, start the agent with `TAX_PUSH_DEBUG=1`.

The push preview contains a shortened final response. The full final response and basic event context are sent to the configured TAX backend over HTTPS, matching the existing Pi notification behavior. See [`docs/PRIVACY.md`](docs/PRIVACY.md) for what this means and how storage is controlled.

### Push deep links

Terminal-aware notifications carry Orca routing identifiers (`host_id`, `workspace_id`, `terminal_id`) alongside the alert title and body; tapping the push opens the corresponding Mac, workspace, or terminal. For a non-default Host ID, set it in the agent's environment:

```bash
export TAX_HOST_ID=mac-main
```

The legacy task/reply UI has been removed.

## Upgrading from versions before 0.4.0

The legacy reply mechanics are removed: the CLI no longer runs a background agent and no longer waits for a response from the iPhone. When upgrading via `./scripts/install.sh`:

- the installer removes only the `tax.agent` LaunchAgent (`gui/$UID/tax.agent` and `~/Library/LaunchAgents/tax.agent.plist`);
- the remote host and its LaunchAgent are untouched and keep working as before;
- old SQLite columns in the backend database remain physically in place (additive migration), but the app no longer reads or writes them; task history exposes only the public projection without legacy fields;
- local Mac data — `agent.db`, journals, and `tasks.jsonl` — is preserved and no longer used; removing it manually is not required.

## Development checks

```bash
uv lock --check
uv sync --locked --extra dev
uv run --locked --extra dev ruff check server src tests
uv run --locked --extra dev pytest -q
npm test
./scripts/preflight.sh
```

## Documentation

- [`docs/PRIVACY.md`](docs/PRIVACY.md) — what is encrypted, what is stored, and retention;
- [`docs/OPERATIONS.md`](docs/OPERATIONS.md) — backend deployment (systemd/Docker Compose), operations, and troubleshooting;
- [`docs/LOCAL_CONFIGURATION.md`](docs/LOCAL_CONFIGURATION.md) — private configuration and iOS signing;
- [`ios/README.md`](ios/README.md) — the iOS client;
- [`ios/README-REMOTE.md`](ios/README-REMOTE.md) — remote client details and terminal renderer acceptance;
- [`docs/remote-protocol-v1.md`](docs/remote-protocol-v1.md) — E2EE and wire protocol;
- [`docs/orca-runtime-compatibility.md`](docs/orca-runtime-compatibility.md) — Orca Runtime compatibility.
