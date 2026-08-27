import SwiftUI

struct WorkspaceListView: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(RemoteWorkspaceStore.self) private var store

    var body: some View {
        NavigationStack {
            Group {
                if store.connectionState == .connecting && store.workspaces.isEmpty { ProgressView("Connecting to Mac…") }
                else if settings.remoteConfiguration == nil {
                    ContentUnavailableView("Remote workspace not configured", systemImage: "desktopcomputer", description: Text("Add host, device, and encryption settings."))
                } else if store.workspaces.isEmpty {
                    ContentUnavailableView("No open Orca workspaces", systemImage: "rectangle.stack")
                } else {
                    List(store.workspaces) { workspace in
                        NavigationLink(value: workspace) {
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
            .navigationDestination(for: RemoteWorkspace.self) { WorkspaceView(workspace: $0) }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { ConnectionBadge(state: store.connectionState) }
                ToolbarItem(placement: .topBarTrailing) { NavigationLink(destination: SettingsView()) { Image(systemName: "gear") } }
            }
            .task { if store.connectionState == .macOffline { await store.connect(settings: settings) } }
            .alert("Remote connection", isPresented: Binding(get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })) {
                Button("OK") { store.errorMessage = nil }
            } message: { Text(store.errorMessage ?? "") }
        }
    }
}

private struct ConnectionBadge: View {
    let state: RemoteConnectionState
    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(state == .online ? .green : .orange).frame(width: 8, height: 8)
            Text(state.rawValue.replacingOccurrences(of: "_", with: " ")).font(.caption)
        }
        .accessibilityLabel("Mac connection: \(state.rawValue)")
    }
}
