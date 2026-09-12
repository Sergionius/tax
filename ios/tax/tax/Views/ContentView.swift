import SwiftUI

struct ContentView: View {
    var body: some View {
        Group {
            #if DEBUG
            if let screenshotScreen = AppEnvironment.screenshotScreen {
                ScreenshotRootView(screen: screenshotScreen)
            } else {
                WorkspaceListView()
            }
            #else
            WorkspaceListView()
            #endif
        }
        // The app uses a dark appearance on every screen, including the terminal.
        // The terminal keeps its own explicit background and toolbar colors.
        .preferredColorScheme(.dark)
    }
}

#if DEBUG
private struct ScreenshotRootView: View {
    let screen: ScreenshotScreen

    var body: some View {
        switch screen {
        case .workspaces:
            WorkspaceListView()
        case .terminal:
            ScreenshotTerminalRootView()
        case .files:
            ScreenshotFilesRootView()
        case .settings:
            ScreenshotSettingsRootView()
        }
    }
}

private struct ScreenshotTerminalRootView: View {
    @State private var path: [RemoteNavigationRoute] = [.terminal(ScreenshotFixtures.primaryTerminal)]

    var body: some View {
        NavigationStack(path: $path) {
            Color.clear
                .workspaceScreenBackground()
                .navigationDestination(for: RemoteNavigationRoute.self) { route in
                    if case let .terminal(terminal) = route {
                        TerminalView(terminal: terminal)
                    }
                }
        }
    }
}

private struct ScreenshotFilesRootView: View {
    @State private var path = ["files"]

    var body: some View {
        NavigationStack(path: $path) {
            Color.clear
                .workspaceScreenBackground()
                .navigationDestination(for: String.self) { _ in
                    FileBrowserView(workspaceID: ScreenshotFixtures.primaryWorkspace.id, path: "")
                }
        }
    }
}

private enum ScreenshotSettingsRoute: Hashable {
    case settings
}

private struct ScreenshotSettingsRootView: View {
    @State private var path: [ScreenshotSettingsRoute] = [.settings]

    var body: some View {
        NavigationStack(path: $path) {
            Color.clear
                .workspaceScreenBackground()
                .navigationDestination(for: ScreenshotSettingsRoute.self) { _ in
                    SettingsView()
                }
        }
    }
}
#endif

#Preview {
    ContentView()
        .environment(SettingsStore())
        .environment(AppState())
        .environment(RemoteWorkspaceStore())
}
