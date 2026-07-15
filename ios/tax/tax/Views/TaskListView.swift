import SwiftUI

struct TaskListView: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(AppState.self) private var appState
    @State private var tasks: [Task] = []
    @State private var navigationPath: [String] = []
    @State private var errorMessage: String?
    @State private var isLoading = false
    @State private var isRefreshing = false

    var body: some View {
        NavigationStack(path: $navigationPath) {
            Group {
                if tasks.isEmpty, !isLoading {
                    ContentUnavailableView(
                        "No Tasks",
                        systemImage: "tray",
                        description: Text(settings.apiKey.isEmpty ? "Add your API key in Settings." : "Pull to refresh or wait for a push notification.")
                    )
                } else {
                    List(tasks) { task in
                        NavigationLink(value: task.id) {
                            TaskRowView(task: task)
                        }
                    }
                    .refreshable { await load(showOverlay: false) }
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
                    .disabled(isLoading)
                }
            }
            .overlay {
                if isLoading {
                    ProgressView("Loading…")
                        .padding()
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
            .task { await load() }
            .onAppear {
                openSelectedTaskIfNeeded(appState.selectedTaskID)
            }
            .onChange(of: appState.refreshToken) { _, _ in
                Swift.Task { await load(showOverlay: !isRefreshing) }
            }
            .onChange(of: appState.selectedTaskID) { _, taskID in
                openSelectedTaskIfNeeded(taskID)
            }
            .navigationDestination(for: String.self) { taskID in
                TaskDetailView(taskID: taskID)
            }
            .alert("Error", isPresented: errorBinding) {
                Button("OK") { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )
    }

    private func openSelectedTaskIfNeeded(_ taskID: String?) {
        guard let taskID else { return }
        defer { appState.clearSelectedTask() }
        guard navigationPath.last != taskID else { return }
        navigationPath.append(taskID)
    }

    private func load(showOverlay: Bool = true) async {
        guard !isLoading, !isRefreshing else { return }

        guard let service = settings.configuredService else {
            tasks = []
            errorMessage = "Configure API key and server URL in Settings."
            return
        }

        if showOverlay {
            isLoading = true
        } else {
            isRefreshing = true
        }
        defer {
            isLoading = false
            isRefreshing = false
        }

        do {
            tasks = try await service.fetchTasks()
        } catch is CancellationError {
        } catch {
            errorMessage = error.localizedDescription
        }
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
                Text(task.status)
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
        switch task.status.lowercased() {
        case "replied", "done", "completed": .green
        case "failed", "error": .red
        case "pending", "new": .orange
        default: .secondary
        }
    }
}
