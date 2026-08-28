import SwiftUI

struct WorkspaceListView: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(RemoteWorkspaceStore.self) private var store
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var appState = appState
        NavigationStack(path: $appState.navigationPath) {
            Group {
                if store.connectionState == .connecting && store.workspaces.isEmpty { ProgressView("Connecting to Mac…") }
                else if settings.remoteConfiguration == nil {
                    ContentUnavailableView("Remote workspace not configured", systemImage: "desktopcomputer", description: Text("Add host, device, and encryption settings."))
                } else if store.workspaces.isEmpty {
                    ContentUnavailableView("No open Orca workspaces", systemImage: "rectangle.stack")
                } else {
                    List(store.workspaces) { workspace in
                        NavigationLink(value: RemoteNavigationRoute.workspace(workspace)) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(workspace.displayName).font(.headline)
                                Text([workspace.projectName, workspace.branch.replacingOccurrences(of: "refs/heads/", with: "")].filter { !$0.isEmpty }.joined(separator: " · "))
                                    .font(.subheadline).foregroundStyle(.secondary)
                                Label("\(workspace.terminalCount) terminals · \(workspace.agentState)", systemImage: "terminal")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .refreshable { await store.refresh() }
                }
            }
            .navigationTitle("Orca")
            .navigationDestination(for: RemoteNavigationRoute.self) { route in
                switch route {
                case let .workspace(workspace): WorkspaceView(workspace: workspace)
                case let .terminal(terminal): TerminalView(terminal: terminal)
                }
            }
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    ConnectionStatus(state: store.connectionState)
                    NavigationLink(destination: SettingsView()) { Image(systemName: "gear") }
                        .accessibilityIdentifier("settings.open")
                }
            }
            .task {
                if store.connectionState == .macOffline, settings.remoteConfiguration != nil {
                    await store.connect(settings: settings)
                }
                await routePendingDestination()
            }
            .onChange(of: appState.pendingDestination) { _, _ in Swift.Task { await routePendingDestination() } }
            .onChange(of: store.workspaces) { _, _ in Swift.Task { await routePendingDestination() } }
            .alert("Remote connection", isPresented: Binding(get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })) {
                Button("OK") { store.errorMessage = nil }
            } message: { Text(store.errorMessage ?? "") }
        }
    }

    private func routePendingDestination() async {
        guard let destination = appState.pendingDestination else { return }
        guard destination.hostID == settings.hostID.trimmingCharacters(in: .whitespacesAndNewlines) else {
            store.errorMessage = "This notification targets Mac \(destination.hostID), but \(settings.hostID) is configured."
            appState.finishRouting()
            return
        }
        guard let workspaceID = destination.workspaceID else {
            appState.navigationPath = []
            appState.finishRouting()
            return
        }
        guard let workspace = store.workspaces.first(where: { $0.id == workspaceID }) else {
            if store.connectionState == .online {
                store.errorMessage = "The linked workspace is no longer open on the Mac."
                appState.finishRouting()
            }
            return
        }
        appState.navigationPath = [.workspace(workspace)]
        guard let terminalID = destination.terminalID else {
            appState.finishRouting()
            return
        }
        await store.loadTerminals(workspaceID: workspaceID)
        for _ in 0 ..< 20 {
            if let terminal = store.terminals[workspaceID]?.first(where: { $0.id == terminalID }) {
                guard appState.pendingDestination == destination else { return }
                appState.navigationPath.append(.terminal(terminal))
                appState.finishRouting()
                return
            }
            try? await Swift.Task.sleep(for: .milliseconds(100))
        }
        guard appState.pendingDestination == destination else { return }
        store.errorMessage = "The linked terminal is no longer available."
        appState.finishRouting()
    }
}

struct ConnectionStatus: View {
    let state: RemoteConnectionState
    var terminalReconnectInProgress = false

    private var title: String {
        if terminalReconnectInProgress { return "Terminal reconnecting" }
        return switch state {
        case .connecting: "Connecting to Mac"
        case .online: "Mac online"
        case .macOffline: "Mac offline"
        case .orcaOffline: "Orca offline"
        case .incompatible: "Orca incompatible"
        case .reconnecting: "Reconnecting to Mac"
        }
    }

    private var color: Color {
        if terminalReconnectInProgress { return .orange }
        return switch state {
        case .online: .green
        case .connecting, .reconnecting: .orange
        case .macOffline, .orcaOffline, .incompatible: .red
        }
    }

    var body: some View {
        HStack(spacing: 5) {
            if terminalReconnectInProgress || state == .connecting || state == .reconnecting {
                ProgressView()
                    .controlSize(.mini)
                    .tint(color)
            } else {
                Circle()
                    .fill(color)
                    .frame(width: 8, height: 8)
            }
            Text(title)
                .font(.caption.weight(.medium))
        }
        .fixedSize()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Mac connection: \(title)")
    }
}
