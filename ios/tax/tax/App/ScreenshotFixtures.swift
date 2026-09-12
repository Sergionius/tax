#if DEBUG
import Foundation

enum ScreenshotScreen: String {
    case workspaces
    case terminal
    case files
    case settings
}

enum ScreenshotFixtures {
    static let primaryWorkspace = RemoteWorkspace(
        id: "workspace-atlas",
        projectID: "project-atlas",
        projectName: "Atlas",
        path: "~/Developer/atlas",
        branch: "refs/heads/feature/offline-sync",
        displayName: "atlas-main",
        terminalCount: 3,
        agentState: "running"
    )

    static let workspaces = [
        primaryWorkspace,
        RemoteWorkspace(
            id: "workspace-orbit",
            projectID: "project-orbit",
            projectName: "Orbit API",
            path: "~/Developer/orbit-api",
            branch: "refs/heads/main",
            displayName: "orbit-main",
            terminalCount: 2,
            agentState: "idle"
        ),
        RemoteWorkspace(
            id: "workspace-notes",
            projectID: "project-notes",
            projectName: "Release Notes",
            path: "~/Developer/release-notes",
            branch: "refs/heads/docs/public-launch",
            displayName: "release-notes",
            terminalCount: 1,
            agentState: "inactive"
        )
    ]

    static let primaryTerminal = RemoteTerminal(
        id: "terminal-pi",
        workspaceID: primaryWorkspace.id,
        title: "⋮  π - tax",
        connected: true,
        writable: true,
        columns: 48,
        rows: 28
    )

    static let terminals = [
        primaryTerminal,
        RemoteTerminal(
            id: "terminal-tests",
            workspaceID: primaryWorkspace.id,
            title: "tests",
            connected: true,
            writable: true,
            columns: 48,
            rows: 28
        ),
        RemoteTerminal(
            id: "terminal-server",
            workspaceID: primaryWorkspace.id,
            title: "dev server",
            connected: false,
            writable: false,
            columns: 48,
            rows: 28
        )
    ]

    static let rootFiles = [
        RemoteFileEntry(name: "Sources", path: "Sources", isDirectory: true, size: nil),
        RemoteFileEntry(name: "Tests", path: "Tests", isDirectory: true, size: nil),
        RemoteFileEntry(name: "README.md", path: "README.md", isDirectory: false, size: 4_812),
        RemoteFileEntry(name: "Package.swift", path: "Package.swift", isDirectory: false, size: 1_246),
        RemoteFileEntry(name: "architecture.md", path: "docs/architecture.md", isDirectory: false, size: 3_907),
        RemoteFileEntry(name: ".github", path: ".github", isDirectory: true, size: nil)
    ]

    static func terminalSnapshot(rows: Int) -> Data {
        let escape = "\u{001B}"
        var output = "\(escape)[2J\(escape)[H"

        func line(_ row: Int, _ text: String = "", background: String? = nil, style: String = "") {
            output += "\(escape)[\(row);1H"
            if let background { output += "\(escape)[48;2;\(background)m" }
            output += "\(escape)[2K\(style)\(text)\(escape)[0m"
        }

        let successPanel = "38;49;39"
        line(1, "  EDIT  Sources/Sync/RetryPolicy.swift", background: successPanel, style: "\(escape)[1;37m")
        line(2, background: successPanel)
        line(3, "  Added cancellation-safe retries", background: successPanel, style: "\(escape)[37m")
        line(4, "  with bounded exponential backoff.", background: successPanel, style: "\(escape)[37m")
        line(5, background: successPanel)
        line(6, "  TEST  RetryPolicyTests", background: successPanel, style: "\(escape)[1;37m")
        line(7, "  ✓ 12 tests passed", background: successPanel, style: "\(escape)[32m")
        line(8, background: successPanel)
        line(9, "  Took 0.8s", background: successPanel, style: "\(escape)[90m")

        line(11, " Running verification", style: "\(escape)[3;90m")

        let toolPanel = "39;39;47"
        line(13, " $ swift test", background: toolPanel, style: "\(escape)[1;37m")
        line(14, background: toolPanel)
        line(15, " Building for debugging...", background: toolPanel, style: "\(escape)[37m")
        line(16, " Build complete!", background: toolPanel, style: "\(escape)[37m")
        line(17, background: toolPanel)
        line(18, " Test Suite 'RetryPolicyTests' passed", background: toolPanel, style: "\(escape)[37m")
        line(19, " Executed 12 tests, 0 failures", background: toolPanel, style: "\(escape)[37m")
        line(20, background: toolPanel)
        line(21, " ✓ All checks passed", background: toolPanel, style: "\(escape)[32m")
        line(22, background: toolPanel)
        line(23, " Took 1.2s", background: toolPanel, style: "\(escape)[90m")

        line(26, " ⋮ Working", style: "\(escape)[36m")
        line(29, "────────────────────────────────────────────", style: "\(escape)[36m")
        line(31, "  Polish the reconnect status message", style: "\(escape)[37m")
        line(33, "────────────────────────────────────────────", style: "\(escape)[36m")

        let footerRow = max(36, rows - 2)
        line(footerRow, " ~/Developer/atlas (feature/offline-sync)", style: "\(escape)[90m")
        line(footerRow + 1, " ↑18k ↓4k  $0.42   context 24%", style: "\(escape)[90m")
        return Data(output.utf8)
    }
}
#endif
