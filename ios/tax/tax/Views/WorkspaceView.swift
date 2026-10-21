import SwiftUI

struct WorkspaceView: View {
    let workspace: RemoteWorkspace
    @Environment(RemoteWorkspaceStore.self) private var store
    @Environment(AppState.self) private var appState
    @State private var showingCreate = false
    @State private var newTitle = ""
    @State private var renameTarget: RemoteTerminal?
    @State private var renameTitle = ""
    @State private var closeTarget: RemoteTerminal?

    private var terminals: [RemoteTerminal]? { store.terminals[workspace.id] }

    /// The screen title is the project name; displayName is the fallback.
    private var screenTitle: String {
        workspace.projectName.isEmpty ? workspace.displayName : workspace.projectName
    }

    var body: some View {
        List {
            terminalsSection
            quickCommandsSection
            filesSection
        }
        .listStyle(.plain)
        .workspaceScreenTheme()
        .workspaceScreenBackground()
        .navigationTitle(screenTitle)
        .navigationBarTitleDisplayMode(.inline)
        .workspacePrincipalTitle(screenTitle)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showingCreate = true
                } label: {
                    Image(systemName: "plus")
                        .font(.workspaceUI(.body, weight: .medium))
                        .foregroundStyle(WorkspaceTheme.accentLight)
                }
                .accessibilityLabel("New terminal")
            }
        }
        .task {
            await store.loadTerminals(workspaceID: workspace.id)
            await store.loadQuickCommands(workspaceID: workspace.id)
        }
        .onChange(of: store.connectionState) { _, state in
            // The list is cleared on every connection change; reload it for this
            // host once the connection is online again.
            guard state == .online else { return }
            Swift.Task {
                await store.loadTerminals(workspaceID: workspace.id)
                await store.loadQuickCommands(workspaceID: workspace.id)
            }
        }
        .onChange(of: store.launchedQuickCommandTerminal) { _, launched in
            guard let launched, launched.workspaceID == workspace.id else { return }
            store.consumeLaunchedQuickCommandTerminal()
            appState.navigationPath.append(RemoteNavigationRoute.terminal(launched))
        }
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

    @ViewBuilder
    private var terminalsSection: some View {
        Section {
            switch terminals {
            case nil where store.errorMessage == nil:
                WorkspaceLoadingState(text: "Loading terminals…")
            case let loaded? where loaded.isEmpty:
                emptyTerminalsRow
            case let loaded?:
                ForEach(loaded) { terminal in
                    terminalRow(terminal)
                }
            default:
                EmptyView()
            }
        } header: {
            WorkspaceSectionHeader(title: "Terminals")
        }
    }

    @ViewBuilder
    private var quickCommandsSection: some View {
        Section {
            quickCommandsContent
        } header: {
            WorkspaceSectionHeader(title: "Quick Commands")
        }
    }

    @ViewBuilder
    private var quickCommandsContent: some View {
        let commands = store.quickCommands[workspace.id]
        if commands == nil, store.quickCommandError == nil {
            WorkspaceLoadingState(text: "Loading Quick Commands…")
        } else {
            if let message = store.quickCommandError {
                quickCommandMessageRow(message) {
                    Swift.Task { await store.loadQuickCommands(workspaceID: workspace.id) }
                }
            }
            if let commands, !commands.isEmpty {
                ForEach(commands.visible(in: workspace)) { command in
                    QuickCommandRow(
                        command: command,
                        isRunning: store.runningQuickCommandID == command.id,
                        isBusy: store.runningQuickCommandID != nil
                    ) {
                        Swift.Task { await store.runQuickCommand(workspace: workspace, command: command) }
                    }
                }
            } else if store.quickCommandError == nil {
                quickCommandEmptyRow
            }
            if let runError = store.quickCommandRunError {
                quickCommandMessageRow(runError, retry: nil)
            }
        }
    }

    private var quickCommandEmptyRow: some View {
        VStack(spacing: 8) {
            Image(systemName: "bolt")
                .font(.workspaceUI(.title2))
                .foregroundStyle(WorkspaceTheme.textDim)
            Text("No Quick Commands saved in Orca")
                .font(.workspaceUI(.subheadline))
                .foregroundStyle(WorkspaceTheme.textLo)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .workspaceCardListRow()
        .accessibilityElement(children: .combine)
    }

    /// Shows the host/Runtime message in full; it is never truncated and never
    /// falls back to typing into a terminal.
    private func quickCommandMessageRow(_ message: String, retry: (() -> Void)? = nil) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.workspaceUI(.subheadline))
                    .foregroundStyle(WorkspaceTheme.accentLight)
                Text(message)
                    .font(.workspaceUI(.footnote))
                    .foregroundStyle(WorkspaceTheme.textLo)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let retry {
                Button("Retry", action: retry)
                    .font(.workspaceUI(.subheadline, weight: .medium))
                    .foregroundStyle(WorkspaceTheme.accentLight)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8)
        .workspaceCardListRow()
    }

    private var filesSection: some View {
        Section {
            NavigationLink {
                FileBrowserView(workspaceID: workspace.id, path: "")
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "folder")
                        .font(.workspaceUI(.title3))
                        .foregroundStyle(WorkspaceTheme.accent)
                        .frame(width: 26)
                    Text("Browse workspace files")
                        .font(.workspaceUI(.body, weight: .medium))
                        .foregroundStyle(WorkspaceTheme.textHi)
                        .lineLimit(1)
                }
            }
            .buttonStyle(WorkspaceCardButtonStyle())
            .workspaceCardListRow()
        } header: {
            WorkspaceSectionHeader(title: "Files")
        }
    }

    private func terminalRow(_ terminal: RemoteTerminal) -> some View {
        NavigationLink(value: RemoteNavigationRoute.terminal(terminal)) {
            TerminalSessionCard(terminal: terminal)
        }
        .buttonStyle(WorkspaceCardButtonStyle())
        .workspaceEmphasis(isActive: terminal.connected)
        .workspaceCardListRow()
        .swipeActions {
            Button("Close", role: .destructive) { closeTarget = terminal }
            Button("Rename") { renameTarget = terminal; renameTitle = terminal.title }.tint(WorkspaceTheme.accent)
        }
    }

    private var emptyTerminalsRow: some View {
        VStack(spacing: 8) {
            Image(systemName: "terminal")
                .font(.workspaceUI(.title2))
                .foregroundStyle(WorkspaceTheme.textDim)
            Text("No terminals yet")
                .font(.workspaceUI(.subheadline))
                .foregroundStyle(WorkspaceTheme.textLo)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .workspaceCardListRow()
        .accessibilityElement(children: .combine)
    }
}

/// A Quick Command row: label plus a short type explanation. Tapping sends
/// one run operation; taps are blocked while another launch is in flight.
private struct QuickCommandRow: View {
    let command: RemoteQuickCommand
    let isRunning: Bool
    let isBusy: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: command.isAgentPrompt ? "sparkles" : "terminal")
                    .font(.workspaceUI(.title3))
                    .foregroundStyle(WorkspaceTheme.accent)
                    .frame(width: 26)
                VStack(alignment: .leading, spacing: 3) {
                    Text(command.label)
                        .font(.workspaceUI(.body, weight: .medium))
                        .foregroundStyle(WorkspaceTheme.textHi)
                        .lineLimit(2)
                    Text(command.kindSummary)
                        .font(.workspaceUI(.caption, weight: .medium))
                        .foregroundStyle(WorkspaceTheme.textLo)
                }
                Spacer()
                if isRunning { ProgressView().controlSize(.small) }
            }
        }
        .buttonStyle(WorkspaceCardButtonStyle())
        .workspaceCardListRow()
        .disabled(isBusy)
        .accessibilityLabel(command.label)
        .accessibilityHint(command.kindSummary)
    }
}

/// Terminal session card: the bright accent bar on the left appears only
/// for active (connected) sessions; disconnected ones are dimmed.
private struct TerminalSessionCard: View {
    let terminal: RemoteTerminal

    var body: some View {
        HStack(spacing: 12) {
            WorkspaceActiveBar(isActive: terminal.connected)
            Image(systemName: terminal.connected ? "terminal.fill" : "terminal")
                .font(.workspaceUI(.title3))
                .foregroundStyle(terminal.connected ? WorkspaceTheme.accent : WorkspaceTheme.accentDim)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 3) {
                Text(terminal.title)
                    .font(.workspaceUI(.body, weight: .medium))
                    .foregroundStyle(WorkspaceTheme.textHi)
                    .lineLimit(1)
                Text(terminal.connected ? "Connected" : "Disconnected")
                    .font(.workspaceUI(.caption, weight: .medium))
                    .foregroundStyle(terminal.connected ? WorkspaceTheme.accentLight : WorkspaceTheme.textLo)
            }
        }
    }
}
