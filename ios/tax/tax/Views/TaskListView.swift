import SwiftUI

struct TaskListView: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(AppState.self) private var appState
    @State private var store = TaskListStore()

    var body: some View {
        @Bindable var appState = appState

        NavigationStack(path: $appState.navigationPath) {
            Group {
                if !store.tasks.isEmpty {
                    taskList
                } else {
                    emptyContent
                }
            }
            .navigationTitle("Tasks")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Swift.Task { await load() }
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .disabled(store.state == .loading)
                    .accessibilityIdentifier("tasks.refresh")
                }
            }
            .task { await load() }
            .onChange(of: appState.refreshToken) { _, _ in
                Swift.Task { await load(showOverlay: false) }
            }
            .navigationDestination(for: String.self) { taskID in
                TaskDetailView(taskID: taskID)
            }
            .alert("Error", isPresented: errorBinding) {
                Button("Retry") { Swift.Task { await load() } }
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    private var taskList: some View {
        List(store.tasks) { task in
            NavigationLink(value: task.id) {
                TaskRowView(task: task)
            }
            .accessibilityIdentifier("task.\(task.id)")
        }
        .refreshable { await load(showOverlay: false) }
    }

    @ViewBuilder
    private var emptyContent: some View {
        switch store.state {
        case .idle, .empty:
            ContentUnavailableView(
                "No Tasks",
                systemImage: "tray",
                description: Text(settings.apiKey.isEmpty ? "Add your API key in Settings." : "Pull to refresh or wait for a push notification.")
            )
        case .loading:
            ProgressView("Loading…")
        case let .error(message):
            ContentUnavailableView {
                Label(settings.apiKey.isEmpty ? "Configuration Required" : "Could Not Load Tasks", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Retry") { Swift.Task { await load() } }
                    .accessibilityIdentifier("tasks.retry")
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

private struct TaskRowView: View {
    let task: Task

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(task.title)
                    .font(.headline)
                    .lineLimit(2)
                Spacer()
                Text(task.displayStatus)
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(statusColor.opacity(0.15), in: Capsule())
                    .foregroundStyle(statusColor)
            }

            if !task.body.isEmpty {
                Text(task.body)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }

            Text(task.updatedAt.isEmpty ? task.displayCreatedAt : task.displayUpdatedAt)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
    }

    private var statusColor: Color {
        switch task.statusKind {
        case .success: .green
        case .failure: .red
        case .pending: .orange
        case .unknown: .secondary
        }
    }
}
