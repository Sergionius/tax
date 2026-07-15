[![Ask DeepWiki](https://deepwiki.com/badge.svg)](https://deepwiki.com/conorluddy/ios-simulator-skill)

# iOS Simulator Skill for Claude Code

Production-ready skill for building, testing, and automating iOS apps. 27 scripts optimized for both human developers and AI agents.

(If you'd prefer an MCP, [XC-MCP](https://github.com/conorluddy/xc-mcp))

## Xcode Build + Simulator Automation

This skill covers both sides of iOS development:

- **Xcode builds** via `xcodebuild` — compile, test, and parse results with progressive error disclosure
- **Simulator interaction** via `xcrun simctl` and `idb` — semantic UI navigation, accessibility testing, device lifecycle

If you only need Xcode build tooling without the simulator scripts, see the plugin version: [xclaude-plugin](https://github.com/conorluddy/xclaude-plugin)

## Installation

### Via Plugin Marketplace (Recommended)

In Claude Code:

```
/plugin marketplace add conorluddy/ios-simulator-skill
/plugin install ios-simulator-skill@conorluddy
```

### Via Git Clone

```bash
# Personal installation
git clone https://github.com/conorluddy/ios-simulator-skill.git ~/.claude/skills/ios-simulator-skill

# Project installation
git clone https://github.com/conorluddy/ios-simulator-skill.git .claude/skills/ios-simulator-skill
```

Restart Claude Code. The skill loads automatically.

### Prerequisites

- macOS 12+
- Xcode Command Line Tools (`xcode-select --install`)
- Python 3
- IDB (optional, for interactive features: `brew tap facebook/fb && brew install idb-companion`)
- Pillow (optional, for visual diffs: `pip3 install pillow`)

## Features

### Xcode Build with Progressive Disclosure

The `build_and_test.py` script wraps `xcodebuild` with token-efficient output. A build returns a single summary line with an xcresult ID:

```
Build: SUCCESS (0 errors, 3 warnings) [xcresult-20251018-143052]
```

Then drill into details on demand:

```bash
python scripts/build_and_test.py --get-errors xcresult-20251018-143052
python scripts/build_and_test.py --get-warnings xcresult-20251018-143052
python scripts/build_and_test.py --get-log xcresult-20251018-143052
```

This keeps agent conversations focused — no walls of build output unless you ask for them.

### Simulator Navigation via Accessibility

Instead of fragile pixel-coordinate tapping, all navigation uses iOS accessibility APIs to find elements by meaning:

```bash
# Fragile — breaks if UI changes
idb ui tap 320 400

# Robust — finds by meaning
python scripts/navigator.py --find-text "Login" --tap
```

The accessibility tree gives structured data (element types, labels, frames, tap targets) at ~10 tokens default output vs 1,600-6,300 tokens for a screenshot. See [AI-Accessible Apps](https://www.conor.fyi/writing/ai-access) for more on why accessibility-first navigation matters for AI agents.

### Screenshot Token Optimization

When screenshots are needed (visual verification, bug reports, diffs), the skill automatically resizes and compresses them to minimize token cost. Default output across all 27 scripts is 3-5 lines — 96% reduction vs raw tool output.

| Task | Raw Tools | This Skill | Savings |
|------|-----------|-----------|---------|
| Screen analysis | 200+ lines | 5 lines | 97.5% |
| Find & tap button | 100+ lines | 1 line | 99% |
| Login flow | 400+ lines | 15 lines | 96% |

### All 27 Scripts

Every script supports `--help` and `--json`. See **SKILL.md** for the complete reference.

#### Build & Development

| Script | What it does | Key flags |
|--------|-------------|-----------|
| `build_and_test.py` | Build Xcode projects, run tests, parse xcresult bundles | `--project`, `--scheme`, `--test`, `--get-errors`, `--get-warnings` |
| `log_monitor.py` | Real-time log monitoring with severity filtering | `--app`, `--severity`, `--follow`, `--duration` |

#### Device State

| Script | What it does | Key flags |
|--------|-------------|-----------|
| `appearance.py` | Switch dark mode, dynamic type, locale, region | `--theme`, `--text-size`, `--locale`, `--region`, `--reset` |
| `location.py` | Simulate GPS coordinates and run built-in scenarios | `--lat`, `--lng`, `--city`, `--gpx`, `--list-scenarios`, `--clear` |

#### Navigation & Interaction

| Script | What it does | Key flags |
|--------|-------------|-----------|
| `screen_mapper.py` | Analyze current screen, list interactive elements | `--verbose`, `--hints` |
| `navigator.py` | Find and interact with elements semantically | `--find-text`, `--find-type`, `--find-id`, `--tap`, `--enter-text` |
| `gesture.py` | Swipes, scrolls, pinches, long press, pull to refresh | `--swipe`, `--scroll`, `--pinch`, `--long-press`, `--refresh` |
| `keyboard.py` | Text input and hardware button control | `--type`, `--key`, `--button`, `--clear`, `--dismiss` |
| `app_launcher.py` | Launch, terminate, install, deep link apps | `--launch`, `--terminate`, `--install`, `--open-url`, `--list` |

#### Testing & Analysis

| Script | What it does | Key flags |
|--------|-------------|-----------|
| `accessibility_audit.py` | WCAG compliance checking on current screen | `--verbose`, `--output` |
| `visual_diff.py` | Compare two screenshots for visual changes | `--threshold`, `--output`, `--details` |
| `test_recorder.py` | Automated test documentation with screenshots | `--test-name`, `--output` |
| `app_state_capture.py` | Debugging snapshots (screenshot, hierarchy, logs) | `--app-bundle-id`, `--output`, `--log-lines` |
| `sim_health_check.sh` | Verify environment (Xcode, simctl, IDB, Python) | — |
| `model_inspector.py` | Inspect Core Data / SwiftData models from project files | `--project-path`, `--raw`, `--show-versions` |
| `container.py` | Inspect app sandbox: list, cat, UserDefaults, Core Data, export | `--ls`, `--cat`, `--userdefaults`, `--core-data-path`, `--export` |
| `hang_watcher.py` (HangBuster) | Record + summarise `os_log` hang events with progressive disclosure (session mode + raw NDJSON + legacy stream); auto-restart on stream EOF/subprocess death | `--start`, `--stop`, `--get-details`, `--list-sessions`, `--diff`, `--budget-tokens` |
| `localization_audit.py` | Audit `.xcstrings` catalogs for missing keys, unused keys, placeholder mismatches | `--catalog`, `--source`, `--strict` |

#### Permissions & Environment

| Script | What it does | Key flags |
|--------|-------------|-----------|
| `clipboard.py` | Copy text to simulator clipboard for paste testing | `--copy`, `--test-name` |
| `status_bar.py` | Override status bar (time, battery, network) | `--preset`, `--time`, `--battery-level`, `--clear` |
| `push_notification.py` | Send simulated push notifications | `--bundle-id`, `--title`, `--body`, `--payload` |
| `privacy_manager.py` | Grant, revoke, reset app permissions (13 services) | `--bundle-id`, `--grant`, `--revoke`, `--reset` |

#### Device Lifecycle

| Script | What it does | Key flags |
|--------|-------------|-----------|
| `simctl_boot.py` | Boot simulators with readiness verification | `--name`, `--wait-ready`, `--timeout`, `--all`, `--type` |
| `simctl_shutdown.py` | Gracefully shutdown simulators | `--name`, `--verify`, `--all`, `--type` |
| `simctl_create.py` | Create simulators by device type and OS version | `--device`, `--runtime`, `--list-devices` |
| `simctl_delete.py` | Delete simulators with safety confirmation | `--name`, `--yes`, `--all`, `--old` |
| `simctl_erase.py` | Factory reset without deletion | `--name`, `--verify`, `--all`, `--booted` |

## Configuration

Every operational limit — timeouts, output caps, polling intervals, cache size, post-action delays — is tunable via an `IOS_SIM_*` environment variable. Defaults are tuned for **local development on Apple Silicon**.

### Boot & lifecycle timeouts

| Variable | Default | Purpose |
|---|---|---|
| `IOS_SIM_BOOT_TIMEOUT` | `300` | Wait for simulator readiness after boot |
| `IOS_SIM_BOOT_SUBPROCESS_TIMEOUT` | `60` | Timeout for the `simctl boot` call itself |
| `IOS_SIM_ERASE_TIMEOUT` | `90` | Wait for factory-reset verification |
| `IOS_SIM_POLL_INTERVAL` | `0.5` | How often to re-check boot/erase state |
| `IOS_SIM_STATE_SUBPROCESS_TIMEOUT` | `15` | Per-subprocess timeout in `app_state_capture.py` |

### Build & test output caps

| Variable | Default | Purpose |
|---|---|---|
| `IOS_SIM_BUILD_SUMMARY_CAP` | `15` | Errors / failed tests in default summary |
| `IOS_SIM_BUILD_VERBOSE_CAP` | `100` | Errors / warnings in verbose mode |
| `IOS_SIM_BUILD_JSON_CAP` | `50` | Max errors / failed tests in JSON output |
| `IOS_SIM_BUILD_LOG_PREVIEW` | `4000` | Build log chars in default output |
| `IOS_SIM_BUILD_TIMEOUT` | `1800` | Hard cap on `xcodebuild build` |
| `IOS_SIM_TEST_TIMEOUT` | `2700` | Hard cap on `xcodebuild test` |
| `IOS_SIM_INTROSPECT_TIMEOUT` | `60` | Timeout for `xcodebuild -list` and `xcrun simctl list` |

### Log monitor output

| Variable | Default | Purpose |
|---|---|---|
| `IOS_SIM_LOG_TEXT_SUMMARY` | `15` | Errors / warnings in text summary |
| `IOS_SIM_LOG_LINE_MAX` | `300` | Per-line truncation |
| `IOS_SIM_LOG_TAIL` | `200` | Recent log lines in verbose/JSON |
| `IOS_SIM_HANG_MIN_MS` | `250` | HangBuster threshold |
| `IOS_SIM_HANG_SESSION_TTL_HOURS` | `24` | HangBuster session prune age |
| `IOS_SIM_HANG_DEFAULT_TOP_N` | `3` | Default top-N clusters in `--stop` |
| `IOS_SIM_HANG_MAX_RESTARTS` | `3` | HangBuster worker respawn attempts |
| `IOS_SIM_HANG_TOTAL_CAP_MB` | `100` | HangBuster aggregate disk cap |

### UI navigation & screen mapping

| Variable | Default | Purpose |
|---|---|---|
| `IOS_SIM_MAX_ELEMENTS` | `25` | Tappable elements listed by `navigator.py` |
| `IOS_SIM_SCREEN_BUTTONS_PREVIEW` | `15` | Button names in `screen_mapper.py` summary |
| `IOS_SIM_SCREEN_SECTION_ITEMS` | `10` | Items per section in `screen_mapper.py` |
| `IOS_SIM_APPS_PREVIEW` | `30` | Installed apps listed by `app_launcher.py` |
| `IOS_SIM_TAP_SETTLE_MS` | `500` | Delay after tap before reading new state |
| `IOS_SIM_RELAUNCH_DELAY_MS` | `1000` | Delay between terminate and re-launch |

### Accessibility audit

| Variable | Default | Purpose |
|---|---|---|
| `IOS_SIM_A11Y_TOP_ISSUES` | `10` | Top issues per audit |
| `IOS_SIM_A11Y_LABEL_MAX` | `80` | Max chars of `AXLabel` retained |

### Cache

| Variable | Default | Purpose |
|---|---|---|
| `IOS_SIM_CACHE_TTL_HOURS` | `1` | Cache validity |
| `IOS_SIM_CACHE_MAX_ENTRIES` | `500` | Hard cap; oldest evicted |

## Examples

```bash
# Slow CI runner — give boot up to 10 minutes
IOS_SIM_BOOT_TIMEOUT=600 python scripts/simctl_boot.py --wait-ready

# Monorepo with many warnings
IOS_SIM_BUILD_VERBOSE_CAP=500 python scripts/build_and_test.py --verbose

# Complex Settings-style screen
IOS_SIM_MAX_ELEMENTS=100 python scripts/navigator.py --list-tappable

# Snappy app — cut tap-settle delay
IOS_SIM_TAP_SETTLE_MS=250 python scripts/navigator.py --find-text "Login" --tap

# Long CI pipeline — keep cache entries valid
IOS_SIM_CACHE_TTL_HOURS=8 python scripts/build_and_test.py --project MyApp.xcodeproj
```

## Evaluation

Tested using [Claude Code evals](https://docs.claude.com/en/docs/claude-code/evals):

| Condition | Pass Rate |
|-----------|-----------|
| With skill | **100%** (3/3) |
| Without skill | **46%** (~1.4/3) |

```bash
claude evals run evals/evals.json --skill ios-simulator-skill
```

## License

MIT
