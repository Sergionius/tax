import SwiftUI

struct TaskDetailView: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(AppState.self) private var appState
    let taskID: String

    @State private var task: Task?
    @State private var errorMessage: String?
    @State private var isLoading = false
    @State private var isRefreshing = false
    @State private var showsReply = false

    var body: some View {
        Group {
            if let task {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        header(task)
                        DetailSection(title: "Body", text: task.body)
                        DetailSection(title: "Context", text: task.context)
                        DetailSection(title: "Logs", text: task.logs, monospaced: true)
                        DetailSection(title: "Reply", text: task.reply)
                    }
                    .padding()
                }
            } else if isLoading {
                ProgressView("Loading task…")
            } else {
                ContentUnavailableView("Task Not Loaded", systemImage: "doc.text.magnifyingglass")
            }
        }
        .navigationTitle("Task")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Reply") { showsReply = true }
                    .disabled(task == nil)
            }
        }
        .task { await load() }
        .refreshable { await load(showOverlay: false) }
        .onChange(of: appState.refreshToken) { _, _ in
            Swift.Task { await load(showOverlay: task == nil) }
        }
        .sheet(isPresented: $showsReply) {
            if let task {
                NavigationStack {
                    ReplyView(task: task) { updatedTask in
                        self.task = updatedTask
                        appState.requestRefresh()
                    }
                }
            }
        }
        .alert("Error", isPresented: errorBinding) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )
    }

    private func header(_ task: Task) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(task.title)
                .font(.title2.bold())
            LabeledContent("Status", value: task.status)
            if !task.createdAt.isEmpty { LabeledContent("Created", value: task.displayCreatedAt) }
            if !task.updatedAt.isEmpty { LabeledContent("Updated", value: task.displayUpdatedAt) }
            Text(task.id)
                .font(.caption)
                .textSelection(.enabled)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func load(showOverlay: Bool = true) async {
        guard !isLoading, !isRefreshing else { return }

        guard let service = settings.configuredService else {
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
            task = try await service.fetchTask(id: taskID)
        } catch is CancellationError {
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct DetailSection: View {
    let title: String
    let text: String?
    var monospaced = false

    var body: some View {
        if let text, !text.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(.headline)
                Text(text)
                    .font(monospaced ? .system(.body, design: .monospaced) : .body)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}
