import SwiftUI

struct TaskListView: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(AppState.self) private var appState
    @State private var store = TaskListStore()
    @State private var showsSettings = false

    var body: some View {
        @Bindable var appState = appState

        NavigationStack(path: $appState.navigationPath) {
            Group {
                if !store.tasks.isEmpty {
                    conversationList
                } else {
                    emptyContent
                }
            }
            .background(Color.white)
            .navigationTitle("tax")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showsSettings = true
                    } label: {
                        Image(systemName: "slider.horizontal.3")
                    }
                    .accessibilityLabel("Settings")
                    .accessibilityIdentifier("settings.open")
                }
            }
            .task { await load() }
            .onChange(of: appState.refreshToken) { _, _ in
                Swift.Task { await load(showOverlay: false) }
            }
            .navigationDestination(for: String.self) { taskID in
                TaskDetailView(taskID: taskID)
            }
            .sheet(isPresented: $showsSettings) {
                SettingsSheet()
            }
            .alert("Could Not Refresh", isPresented: errorBinding) {
                Button("Retry") { Swift.Task { await load() } }
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    private var conversationList: some View {
        List(store.tasks) { task in
            NavigationLink(value: task.id) {
                ConversationRow(task: task)
            }
            .accessibilityIdentifier("task.\(task.id)")
            .listRowInsets(EdgeInsets(top: 14, leading: 20, bottom: 14, trailing: 14))
            .listRowSeparatorTint(Color.black.opacity(0.08))
            .listRowBackground(Color.white)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .refreshable { await load(showOverlay: false) }
    }

    @ViewBuilder
    private var emptyContent: some View {
        switch store.state {
        case .idle, .empty:
            ContentUnavailableView {
                Label("No conversations", systemImage: "bubble.left.and.bubble.right")
            } description: {
                Text(settings.apiKey.isEmpty ? "Connect the app to start receiving agent results." : "New agent results will appear here.")
            } actions: {
                if settings.apiKey.isEmpty {
                    Button("Open Settings") { showsSettings = true }
                        .buttonStyle(.borderedProminent)
                }
            }
        case .loading:
            ProgressView("Loading conversations…")
        case let .error(message):
            ContentUnavailableView {
                Label(settings.apiKey.isEmpty ? "Configuration Required" : "Could Not Load Conversations", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                if settings.apiKey.isEmpty {
                    Button("Open Settings") { showsSettings = true }
                        .accessibilityIdentifier("settings.open.empty")
                } else {
                    Button("Retry") { Swift.Task { await load() } }
                        .accessibilityIdentifier("tasks.retry")
                }
            }
        case .content:
            EmptyView()
        }
    }

    private var errorMessage: String? {
        guard !store.tasks.isEmpty, case let .error(message) = store.state else { return nil }
        return message
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { if !$0 { store.dismissError() } }
        )
    }

    private func load(showOverlay: Bool = true) async {
        await store.load(using: settings.configuredService, showOverlay: showOverlay)
    }
}

private struct ConversationRow: View {
    let task: Task

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            statusIndicator
                .padding(.top, 7)

            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(task.title)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Color.black)
                        .lineLimit(1)

                    Spacer(minLength: 8)

                    Text(task.displayListTimestamp)
                        .font(.caption)
                        .foregroundStyle(Color.black.opacity(0.45))
                }

                if !preview.isEmpty {
                    Text(preview)
                        .font(.subheadline)
                        .foregroundStyle(Color.black.opacity(0.58))
                        .lineLimit(2)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var statusIndicator: some View {
        Circle()
            .fill(statusColor)
            .frame(width: task.statusKind == .pending ? 8 : 6, height: task.statusKind == .pending ? 8 : 6)
            .accessibilityLabel("Status: \(task.displayStatus)")
    }

    private var preview: String {
        if let reply = task.reply, !reply.isEmpty {
            return "You: \(reply)"
        }
        return task.body
    }

    private var statusColor: Color {
        switch task.statusKind {
        case .pending: .blue
        case .success: Color.black.opacity(0.25)
        case .failure: .red
        case .unknown: Color.black.opacity(0.25)
        }
    }
}

private struct SettingsSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            SettingsView()
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
        }
        .preferredColorScheme(.light)
    }
}
