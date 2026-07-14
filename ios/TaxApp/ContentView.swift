import SwiftUI

struct ContentView: View {
    @State private var serverURL: String = UserDefaults.standard.string(forKey: "serverURL") ?? "https://138.249.127.23.nip.io"
    @State private var tasks: [TaskItem] = []
    @State private var selectedTask: TaskItem?
    @State private var replyText: String = ""
    @State private var isLoading: Bool = false

    var body: some View {
        NavigationView {
            VStack {
                HStack {
                    TextField("Server URL", text: $serverURL)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                    Button("Save") {
                        UserDefaults.standard.set(serverURL, forKey: "serverURL")
                    }
                }
                .padding()

                if let token = UserDefaults.standard.string(forKey: "deviceToken") {
                    Text("Device token: \(token.prefix(16))...")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.horizontal)
                }

                Button(action: loadTasks) {
                    HStack {
                        Image(systemName: "arrow.clockwise")
                        Text("Refresh")
                    }
                }
                .disabled(isLoading)

                List(tasks) { task in
                    Button(action: { selectedTask = task }) {
                        VStack(alignment: .leading) {
                            Text(task.title).font(.headline)
                            Text(task.body).font(.subheadline).foregroundColor(.secondary)
                            Text(task.status).font(.caption).foregroundColor(statusColor(task.status))
                        }
                    }
                }
            }
            .navigationTitle("tax")
        }
        .sheet(item: $selectedTask) { task in
            TaskDetailView(task: task, serverURL: serverURL, onReply: { loadTasks() })
        }
        .onAppear(perform: loadTasks)
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("OpenTask"))) { notification in
            if let taskId = notification.object as? String {
                openTask(id: taskId)
            }
        }
    }

    func statusColor(_ status: String) -> Color {
        switch status {
        case "pending": return .orange
        case "replied": return .green
        case "completed": return .blue
        case "failed": return .red
        default: return .gray
        }
    }

    func loadTasks() {
        guard let url = URL(string: "\(serverURL)/tasks") else { return }
        isLoading = true
        URLSession.shared.dataTask(with: url) { data, _, _ in
            isLoading = false
            guard let data = data else { return }
            if let response = try? JSONDecoder().decode(TasksResponse.self, from: data) {
                DispatchQueue.main.async {
                    self.tasks = response.tasks
                }
            }
        }.resume()
    }

    func openTask(id: String) {
        guard let url = URL(string: "\(serverURL)/task/\(id)") else { return }
        URLSession.shared.dataTask(with: url) { data, _, _ in
            guard let data = data else { return }
            if let response = try? JSONDecoder().decode(TaskResponse.self, from: data),
               let task = response.task {
                DispatchQueue.main.async {
                    self.selectedTask = task
                }
            }
        }.resume()
    }
}

struct TaskDetailView: View {
    let task: TaskItem
    let serverURL: String
    let onReply: () -> Void

    @State private var replyText: String = ""
    @Environment(\.dismiss) var dismiss

    var body: some View {
        NavigationView {
            Form {
                Section("Status") {
                    Text(task.status)
                }
                Section("Context") {
                    Text(task.context)
                }
                Section("Logs") {
                    Text(task.logs)
                        .font(.system(.body, design: .monospaced))
                }
                Section("Reply") {
                    TextEditor(text: $replyText)
                        .frame(minHeight: 100)
                }
            }
            .navigationTitle(task.title)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Send") { sendReply() }
                }
            }
        }
    }

    func sendReply() {
        guard let url = URL(string: "\(serverURL)/task/\(task.id)/reply") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONEncoder().encode(["text": replyText])

        URLSession.shared.dataTask(with: request) { _, _, _ in
            DispatchQueue.main.async {
                dismiss()
                onReply()
            }
        }.resume()
    }
}

struct TaskItem: Identifiable, Codable {
    let id: String
    let title: String
    let body: String
    let status: String
    let context: String
    let logs: String?
    let reply: String?
    let created_at: String?
    let updated_at: String?
}

struct TasksResponse: Codable {
    let ok: Bool
    let tasks: [TaskItem]
}

struct TaskResponse: Codable {
    let ok: Bool
    let task: TaskItem?
}
