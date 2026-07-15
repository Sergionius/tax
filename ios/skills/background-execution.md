<h1 align="center">Background Execution Agent Skill</h1>

<p align="center">
    <img src="https://img.shields.io/badge/iOS-13+-2980b9.svg" alt="iOS 13+" />
    <img src="https://img.shields.io/badge/swift-5.9+-F05138.svg" alt="Swift 5.9+" />
    <img src="https://img.shields.io/badge/license-MIT-lightgrey.svg" alt="MIT License" />
    <a href="https://agentskills.io/home">
        <img src="https://img.shields.io/badge/Agent%20Skills-Compatible-purple.svg" alt="Agent Skills Compatible" />
    </a>
</p>

An agent skill that helps AI coding agents like Claude Code, Codex, Cursor, and Gemini write correct Swift background-execution code - scheduling deferred work, finishing work after the app backgrounds, transferring files in the background, and waking the app via push, while respecting the system constraints that decide whether the work runs at all.

It uses the [Agent Skills](https://agentskills.io/home) format, so it works smoothly with Claude Code, Codex, Gemini, Cursor, and more.


## What It Covers

- **BackgroundTasks** - `BGTaskScheduler`, `BGAppRefreshTask`, `BGProcessingTask`, `BGContinuedProcessingTask` (iOS/iPadOS 26 user-initiated work with progress UI, submission strategy, background GPU access), `BGHealthResearchTask`, registration timing, `BGTaskSchedulerPermittedIdentifiers`, submit/reschedule, expiration and `setTaskCompleted`, error codes
- **Task assertions** - `beginBackgroundTask(withName:expirationHandler:)` / `endBackgroundTask`, balanced/idempotent bracketing, `backgroundTimeRemaining`, `ProcessInfo.performExpiringActivity` for extensions and watchOS, assertions vs scheduler
- **Background URLSession** - `URLSessionConfiguration.background(withIdentifier:)`, the mandatory delegate, the full relaunch flow (`handleEventsForBackgroundURLSession` + `urlSessionDidFinishEvents`), `isDiscretionary`, `sessionSendsLaunchEvents`, `timeoutIntervalForResource`, expensive/constrained network access, resume data, file-backed uploads
- **Push** - silent/background notifications (`content-available`, `apns-push-type: background`, `apns-priority: 5`, the `remote-notification` mode, `UIBackgroundFetchResult`, system throttling/coalescing), PushKit/VoIP and the iOS 13+ CallKit reporting requirement
- **Background modes** - the full `UIBackgroundModes` matrix, background location (`allowsBackgroundLocationUpdates`, significant-change, region monitoring, the location indicator), BLE / external accessory / nearby interaction / push-to-talk, deprecated background fetch
- **Background audio** - playback and recording: `AVAudioSession` categories/modes/options, recording the mic while the screen is locked, mic permission (`AVAudioApplication.requestRecordPermission`), interruption and route-change handling, `AVAudioEngine` taps, and the realtime-thread / activation / teardown gotchas that bite in production
- **SwiftUI** - `ScenePhase`, the `.backgroundTask(.appRefresh:)` / `.backgroundTask(.urlSession:)` scene modifier, async cancellation handling, scheduling vs handling
- **macOS** - `NSBackgroundActivityScheduler`, `ProcessInfo.beginActivity` / `performActivity` and App Nap, `SMAppService` login items / agents / daemons, the cross-platform availability map
- **Lifecycle** - scene activation states, the background execution sequence, `sceneDidEnterBackground` vs the deprecated app-delegate callbacks, the ~5 s background-transition budget
- **Constraints and testing** - the opportunistic/discretionary budget model, force-quit semantics, `backgroundRefreshStatus`, Low Power Mode, thermal state, the lldb `_simulateLaunchForTaskWithIdentifier:` / `_simulateExpirationForTaskWithIdentifier:` commands, device-only testing
- **Anti-patterns** - ~30 catches including unregistered/double-registered tasks, missing expiration handlers, unbalanced `beginBackgroundTask`, completion-handler use on background sessions, multiple sessions per identifier, mishandled relaunch, missing `apns-push-type`, unreported VoIP pushes, `location` mode mismatches, and more


## Installing

You can install this skill into Claude Code, Codex, Gemini, Cursor, and more by using `npx`:

```bash
npx skills add https://github.com/n0an/Background-Execution-Agent-Skill --skill background-execution
```

If you get the error `npx: command not found`, it means you don't have Node installed. You need to run this command to install Node through Homebrew:

```bash
brew install node
```

And if *that* fails it usually means you need to [install Homebrew](https://brew.sh) first.

When using `npx`, you can select exactly which agents you want to use during the installation. You can also select whether the skill should be installed just for one project, or whether it should be made available for all your projects.

### Alternative install methods

**Claude Code:**

```bash
/plugin install n0an/Background-Execution-Agent-Skill
```

**Gemini:**

```bash
gemini extensions install https://github.com/n0an/Background-Execution-Agent-Skill.git --consent
```

Alternatively, you can clone this whole repository and install it however you want.


## Using Background Execution

The skill is called Background Execution, and can be triggered in various ways. For example, in Claude Code you would use this:

> /background-execution

And in Codex you would use this:

> $background-execution

In both cases you can provide specific instructions if you want only a partial review. For example, `/background-execution Fix the BGAppRefreshTask in SyncManager.swift` on Claude, or `$background-execution Add a background URLSession download manager` in Codex.

You can also trigger it using natural language:

> Use the Background Execution skill to review why my background refresh never runs.


## Why Use an Agent Skill for Background Execution?

Background execution has changed substantially across iOS releases - `BGTaskScheduler` replaced the old background-fetch API in iOS 13, the scene lifecycle replaced the app-delegate lifecycle, SwiftUI added `.backgroundTask`, and iOS 26 added `BGContinuedProcessingTask`. Most LLM training data reflects the older shape, so agents routinely generate code that:

- Registers a `BGTaskScheduler` handler in view code or after launch finishes, so it never fires on a background launch - or registers the same identifier twice and crashes the app
- Omits the expiration handler or never calls `setTaskCompleted`, so the system kills the app and throttles future scheduling
- Uses `beginBackgroundTask` to start fresh multi-minute work and leaves the assertion unbalanced
- Uses completion-handler convenience methods (or `dataTask`) on a background `URLSession`, or creates a new session per download, and never wires up the relaunch flow
- Sends a silent push without `apns-push-type: background`, or expects it to deliver reliably
- Sets `allowsBackgroundLocationUpdates = true` without the `location` mode (a fatal crash)
- Assumes background work is guaranteed, ignoring force-quit, Low Power Mode, and Background App Refresh being off

This skill:

- **Catches anti-patterns** LLMs default to, with before/after fixes
- **Routes work to the right API** with an explicit decision tree (assertion vs scheduler vs background session vs push)
- **Covers newer APIs** like `BGContinuedProcessingTask`, the SwiftUI `.backgroundTask` modifier, and `SMAppService`
- **Enforces the system contract** - registration timing, the completion handlers, the relaunch flow, and graceful degradation under the constraints that gate background work


## Contributing

Contributions are welcome - whether adding new checks, improving existing examples, or fixing typos.

- Keep Markdown concise. There is a token cost to using skills, so respect the token budgets of users.
- Do not repeat things LLMs already know. Focus on edge cases, surprises, and common mistakes.
- All work must be licensed under the MIT license.


## License

Available under the [MIT License](LICENSE), which permits commercial use, modification, distribution, and private use.
