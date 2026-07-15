# iOS Agent Skills for tax

This folder contains third-party agent skills for building the iOS SwiftUI app.
All files are MIT licensed and attributed to their original authors.

## Contents

| File | Skill | Author | License | Source |
|------|-------|--------|---------|--------|
| `swiftui-pro.md` | SwiftUI Pro | Paul Hudson (twostraws) | MIT | https://github.com/twostraws/SwiftUI-Agent-Skill |
| `swift-concurrency-pro.md` | Swift Concurrency Pro | Paul Hudson (twostraws) | MIT | https://github.com/twostraws/Swift-Concurrency-Agent-Skill |
| `swiftui-ui-patterns.md` | SwiftUI UI Patterns | Thomas Ricouard (Dimillian) | MIT | https://github.com/Dimillian/Skills |
| `background-execution.md` | Background Execution | Anton Novoselov (n0an) | MIT | https://github.com/n0an/Background-Execution-Agent-Skill |
| `ios-simulator.md` | iOS Simulator Skill | Conor Luddy | MIT | https://github.com/conorluddy/ios-simulator-skill |
| `ios-simulator-claude.md` | iOS Simulator CLAUDE.md | Conor Luddy | MIT | https://github.com/conorluddy/ios-simulator-skill |

## Usage

These skills are for Claude Code, Codex, Gemini, Cursor, and other AI agents.
The project-specific instructions are in `../AGENTS.md`.

## Installation in Claude Code / Codex

```bash
npx skills add https://github.com/twostraws/swiftui-agent-skill --skill swiftui-pro
npx skills add https://github.com/twostraws/swift-concurrency-agent-skill --skill swift-concurrency-pro
npx skills add https://github.com/n0an/Background-Execution-Agent-Skill --skill background-execution
npx skills add https://github.com/conorluddy/ios-simulator-skill --skill ios-simulator-skill
```

## License

All files in this directory are copies of MIT-licensed third-party works.
See each file header/source for full attribution.
