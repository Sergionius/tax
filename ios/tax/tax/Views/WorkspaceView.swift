import SwiftUI

struct WorkspaceView: View {
    let workspace: RemoteWorkspace
    @Environment(RemoteWorkspaceStore.self) private var store
    @State private var showingCreate = false
    @State private var newTitle = ""
    @State private var renameTarget: RemoteTerminal?
    @State private var renameTitle = ""
    @State private var closeTarget: RemoteTerminal?

    var body: some View {
        List {
            Section("Terminals") {
                ForEach(store.terminals[workspace.id] ?? []) { terminal in
                    NavigationLink(value: RemoteNavigationRoute.terminal(terminal)) {
                        Label {
                            VStack(alignment: .leading) {
                                Text(terminal.title)
                                Text(terminal.connected ? "Connected" : "Disconnected").font(.caption).foregroundStyle(.secondary)
                            }
                        } icon: { Image(systemName: "terminal") }
                    }
                    .swipeActions {
                        Button("Close", role: .destructive) { closeTarget = terminal }
                        Button("Rename") { renameTarget = terminal; renameTitle = terminal.title }.tint(.blue)
                    }
                }
            }
            Section("Files") {
                NavigationLink {
                    FileBrowserView(workspaceID: workspace.id, path: "")
                } label: {
                    Label("Browse workspace files", systemImage: "folder")
                }
            }
        }
        .navigationTitle(workspace.displayName)
        .toolbar { Button { showingCreate = true } label: { Label("New terminal", systemImage: "plus") } }
        .task { await store.loadTerminals(workspaceID: workspace.id) }
        .alert("Create terminal", isPresented: $showingCreate) {
            TextField("Title (optional)", text: $newTitle)
            Button("Create") { Swift.Task { await store.createTerminal(workspaceID: workspace.id, title: newTitle); newTitle = "" } }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Rename terminal", isPresented: Binding(get: { renameTarget != nil }, set: { if !$0 { renameTarget = nil } })) {
            TextField("Title", text: $renameTitle)
            Button("Rename") { if let target = renameTarget { Swift.Task { await store.renameTerminal(target, title: renameTitle) } }; renameTarget = nil }
            Button("Cancel", role: .cancel) { renameTarget = nil }
        }
        .confirmationDialog("Close running terminal?", isPresented: Binding(get: { closeTarget != nil }, set: { if !$0 { closeTarget = nil } })) {
            Button("Close Terminal", role: .destructive) { if let target = closeTarget { Swift.Task { await store.closeTerminal(target) } }; closeTarget = nil }
            Button("Cancel", role: .cancel) { closeTarget = nil }
        }
    }
}
