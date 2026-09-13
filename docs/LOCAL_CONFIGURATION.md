# Local configuration

TAX ships without owner-specific values. Infrastructure addresses, deployment
paths and iOS signing identifiers live in private, untracked files on your
machine. This document defines the configuration contract shared by the CLI,
the deployment scripts and the iOS project.

## Private files

| File | Purpose | In Git |
| --- | --- | --- |
| `~/.config/tax/config.json` | CLI settings: server URL, API key, device token (`tax config`) | Never |
| `~/.config/tax/deploy.env` | Server deployment settings (see contract below) | Never |
| `ios/Config/Local.xcconfig` | iOS signing overrides | Never |

`deploy.env.example` and `ios/Config/Local.xcconfig.example` are the tracked
templates. They contain placeholder values only.

Keep every private file with mode `0600`. Never print their contents or
credentials in diagnostics, logs or tickets.

## Deployment configuration contract

`~/.config/tax/deploy.env` (or the file named by `TAX_DEPLOY_CONFIG`) is a
shell-readable file with the following variables:

| Variable | Meaning |
| --- | --- |
| `TAX_DEPLOY_HOST` | SSH destination for `scripts/deploy-backend.sh` (`user@host`) |
| `TAX_DEPLOY_USER` | Service user running the systemd unit |
| `TAX_DEPLOY_GROUP` | Service group running the systemd unit |
| `TAX_DEPLOY_PROJECT_DIR` | Absolute path to the TAX checkout on the server |
| `TAX_DEPLOY_DOMAIN` | Public domain terminating TLS in front of the backend |
| `TAX_DEPLOY_PORT` | Loopback port; systemd, reverse proxy and health check must agree |
| `TAX_DEPLOY_DB_PATH` | Absolute path to the SQLite database file |
| `TAX_DEPLOY_APNS_KEY_PATH` | Absolute path to the APNs signing key (`.p8`) |
| `TAX_DEPLOY_ENV_FILE` | Absolute path to the backend environment file read by the systemd unit |

## Precedence

Deployment settings are resolved in this order:

1. Explicit environment variables (for example `TAX_DEPLOY_HOST` set in the
   calling shell) override everything else.
2. The file named by `TAX_DEPLOY_CONFIG`.
3. `~/.config/tax/deploy.env`.

Rules:

- If `TAX_DEPLOY_CONFIG` is set and the file does not exist, deployment
  tooling fails with an error; it never silently falls back to another file.
- Missing or invalid required values are reported before any SSH connection,
  Git operation, `sudo` call, file change or service command.

## File permissions and secrecy

- Create private files with `umask 077` and keep them at mode `0600`
  (`chmod 600 <file>`).
- Never commit, print, or log the contents of private files, API keys,
  provider JWTs or device tokens. Diagnostics must refer to file paths, not
  values.
- Never paste credentials into tickets, issues or screenshots.

## Migrating existing settings

When a TAX release stops shipping previously tracked defaults (deployment
paths, domains, signing identifiers), move your current values into the
private files first:

- Copy the values you use today into `~/.config/tax/deploy.env` and
  `ios/Config/Local.xcconfig`.
- Never overwrite an existing private file. If the target file already
  exists with different values, stop and resolve the conflict manually;
  do not replace live values with the example placeholders.
- A migration that cannot find a required value must stop with an error
  instead of substituting an example.
- iPhone app: the current build falls back to a built-in server URL when no
  URL has been saved. A future build removes that fallback. Before installing
  it, open TAX → Settings on the iPhone, enter your server URL (the same one
  the CLI uses) and API key, and save, so both are persisted explicitly in
  app preferences. The private URL is never embedded in app code, migration
  code or documentation.

## iOS signing configuration

`ios/Config/Local.xcconfig` (template:
`ios/Config/Local.xcconfig.example`) defines the signing contract:

| Variable | Meaning |
| --- | --- |
| `TAX_DEVELOPMENT_TEAM` | Apple Development Team ID |
| `TAX_APP_BUNDLE_IDENTIFIER` | App bundle identifier |
| `TAX_TESTS_BUNDLE_IDENTIFIER` | Unit test bundle identifier |
| `TAX_UITESTS_BUNDLE_IDENTIFIER` | UI test bundle identifier |

Setup:

```bash
cp ios/Config/Local.xcconfig.example ios/Config/Local.xcconfig
chmod 600 ios/Config/Local.xcconfig
# then edit in your team ID and bundle identifiers
```

Keep the app bundle identifier and team stable: existing Keychain entries
and the Orca pairing file (`~/.config/tax/orca-pairing`) stay valid only
while the app identity is unchanged. Do not regenerate or delete Keychain
items or the pairing file when editing this configuration.

## Preparing private configuration on the server

The backend host needs its own private deployment file. Prepare it yourself
over SSH; the TAX repository and its scripts do not create it remotely:

```bash
ssh <your-host>
mkdir -p ~/.config/tax
cp /path/to/checkout/deploy.env.example ~/.config/tax/deploy.env
chmod 600 ~/.config/tax/deploy.env
# edit ~/.config/tax/deploy.env and fill in the real values
```

The deployment scripts read this file before they touch SSH, Git, `sudo`,
files or services, and they report missing values instead of guessing.
Updating this repository on the server does not deploy or restart anything
by itself; run your usual deploy step only after the private configuration
is complete.
