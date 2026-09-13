# APNs smoke checklist

Run this check on a physical iPhone: the simulator does not receive real APNs pushes.

## Run details

- App version / build:
- Git commit:
- Device:
- iOS:
- Build: Debug / TestFlight
- APNs: sandbox / production
- Date and operator:
- Result: PASS / FAIL
- Defect links:

## Preparation

- [ ] Install a fresh Debug or TestFlight build.
- [ ] Verify the bundle ID matches the APNs topic.
- [ ] On the Mac, run an agent (pi, Claude Code, or Codex) inside an Orca terminal so the push deep-links to a specific terminal.
- [ ] In Settings, enter the server URL, API key, Host ID, Device ID, and E2EE key, then tap **Save Settings**.
- [ ] Allow notifications in system settings.
- [ ] Tap **Request Push Registration** and confirm a device token appears.
- [ ] Run `Check Server Health` and `tax push-doctor` on the Mac.

## Main scenario

- [ ] Wait for an agent turn to finish and receive the push while the app is closed.
- [ ] Tap the notification and confirm the correct Mac, workspace, and terminal open.
- [ ] Receive a push with the app in the foreground; check the banner.
- [ ] Check the `all`, `tax`, and `off` push modes: pushes arrive in `all` and `tax`, none in `off`. Restore the desired mode.
- [ ] Confirm that a push for a closed terminal does not break the app: the workspace opens with a closed-terminal message.

## Reconnect

- [ ] Turn the iPhone's network off and on again; confirm the app reconnects to the relay and restores the terminal snapshot without mixing generations.

## PASS criterion

All mandatory items pass; discrepancies are recorded as defect links. The APNs environment matches the build type: sandbox for Debug, production for TestFlight/App Store.
