import SwiftUI

struct WorkspaceListView: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(RemoteWorkspaceStore.self) private var store
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var appState = appState
        NavigationStack(path: $appState.navigationPath) {
            Group {
                if store.connectionState == .connecting && store.workspaces.isEmpty {
                    WorkspaceLoadingState(text: "Connecting to Mac…", fillsScreen: true)
                } else if settings.remoteConfiguration == nil {
                    WorkspaceEmptyState(
                        title: "Remote workspace not configured",
                        icon: "desktopcomputer",
                        description: "Add host, device, and encryption settings."
                    )
                } else if store.workspaces.isEmpty {
                    WorkspaceEmptyState(title: "No open Orca workspaces", icon: "rectangle.stack")
                } else {
                    workspaceList
                }
            }
            .workspaceScreenTheme()
            .workspaceScreenBackground()
            .navigationDestination(for: RemoteNavigationRoute.self) { route in
                switch route {
                case let .workspace(workspace): WorkspaceView(workspace: workspace)
                case let .terminal(terminal): TerminalView(terminal: terminal)
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Text("tax")
                        .font(.workspaceUI(.title2, weight: .semibold))
                        .foregroundStyle(WorkspaceTheme.textHi)
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    // Leading padding: the toolbar capsule wraps the whole group;
                    // without it the indicator hugs the left edge asymmetrically.
                    WorkspaceConnectionIndicator(state: store.connectionState)
                        .padding(.leading, 8)
                    NavigationLink(destination: SettingsView()) {
                        Image(systemName: "gear")
                            .font(.workspaceUI(.body, weight: .medium))
                            .foregroundStyle(WorkspaceTheme.textLo)
                    }
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

    private var workspaceList: some View {
        List(store.workspaces) { workspace in
            NavigationLink(value: RemoteNavigationRoute.workspace(workspace)) {
                WorkspaceListCard(workspace: workspace)
            }
            .buttonStyle(WorkspaceCardButtonStyle())
            .workspaceEmphasis(isActive: workspace.isVisuallyActive)
            .workspaceCardListRow()
        }
        .listStyle(.plain)
        .refreshable { await store.refresh() }
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

/// Workspace card in the list: project name on top, with the branch,
/// path, terminal count and current agent status below.
/// Active state differs only in styling.
private struct WorkspaceListCard: View {
    let workspace: RemoteWorkspace

    /// The card title is the project name; displayName is the fallback.
    private var cardTitle: String {
        workspace.projectName.isEmpty ? workspace.displayName : workspace.projectName
    }

    private var branchName: String {
        workspace.branch.replacingOccurrences(of: "refs/heads/", with: "")
    }

    private var symbolColor: Color {
        workspace.isVisuallyActive ? WorkspaceTheme.accent : WorkspaceTheme.accentDim
    }

    var body: some View {
        HStack(spacing: 12) {
            WorkspaceActiveBar(isActive: workspace.isVisuallyActive)
            VStack(alignment: .leading, spacing: 7) {
                Text(cardTitle)
                    .font(.workspaceUI(.headline, weight: .semibold))
                    .foregroundStyle(WorkspaceTheme.textHi)
                    .lineLimit(1)
                if !branchName.isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.triangle.branch")
                            .font(.workspaceUI(.caption2, weight: .medium))
                            .foregroundStyle(symbolColor)
                        Text(branchName)
                            .font(.workspaceMono(.caption))
                            .foregroundStyle(WorkspaceTheme.textLo)
                            .lineLimit(1)
                    }
                }
                Text(workspace.path)
                    .font(.workspaceMono(.caption2))
                    .foregroundStyle(WorkspaceTheme.textDim)
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 8) {
                    HStack(spacing: 4) {
                        Image(systemName: "terminal")
                            .font(.workspaceUI(.caption2, weight: .medium))
                            .foregroundStyle(symbolColor)
                        Text("\(workspace.terminalCount) terminals")
                            .font(.workspaceMono(.caption2, weight: .medium))
                            .foregroundStyle(WorkspaceTheme.textLo)
                    }
                    WorkspaceBadge(text: workspace.agentState, icon: "brain", isActive: workspace.isVisuallyActive)
                }
            }
        }
    }
}

/// Themed connection indicator for the workspace list.
/// The terminal keeps using `ConnectionStatus` — its appearance is unchanged.
struct WorkspaceConnectionIndicator: View {
    let state: RemoteConnectionState

    private var title: String {
        switch state {
        case .connecting: "Connecting to Mac"
        case .online: "Mac online"
        case .macOffline: "Mac offline"
        case .orcaOffline: "Orca offline"
        case .incompatible: "Orca incompatible"
        case .reconnecting: "Reconnecting to Mac"
        }
    }

    private var color: Color {
        switch state {
        case .online: .green
        case .connecting, .reconnecting: .orange
        case .macOffline, .orcaOffline, .incompatible: .red
        }
    }

    var body: some View {
        HStack(spacing: 5) {
            if state == .connecting || state == .reconnecting {
                ProgressView()
                    .controlSize(.mini)
                    .tint(color)
            } else {
                Circle()
                    .fill(color)
                    .frame(width: 8, height: 8)
            }
            Text(title)
                .font(.workspaceUI(.caption, weight: .medium))
                .foregroundStyle(WorkspaceTheme.textLo)
                .lineLimit(1)
        }
        .fixedSize()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Mac connection: \(title)")
    }
}

private extension RemoteWorkspace {
    /// Dimmed styling applies only to the "inactive" status.
    /// In any other case the card is regular, with a bright bar and badge.
    var isVisuallyActive: Bool {
        agentState.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() != "inactive"
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
