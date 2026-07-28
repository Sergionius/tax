import Foundation
@testable import tax

actor RecordingTransport: HTTPTransport {
    enum Stub: @unchecked Sendable {
        case response(status: Int, data: Data)
        case failure(URLError)
        case invalidResponse(Data)
    }

    private var stubs: [Stub]
    private(set) var requests: [URLRequest] = []

    init(_ stubs: [Stub]) {
        self.stubs = stubs
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        guard !stubs.isEmpty else { throw URLError(.badServerResponse) }
        let stub = stubs.removeFirst()
        switch stub {
        case let .response(status, data):
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: status,
                httpVersion: nil,
                headerFields: nil
            )!
            return (data, response)
        case let .failure(error):
            throw error
        case let .invalidResponse(data):
            return (data, URLResponse(url: request.url!, mimeType: nil, expectedContentLength: data.count, textEncodingName: nil))
        }
    }

    func request(at index: Int = 0) -> URLRequest {
        requests[index]
    }
}

func makeTask(
    id: String = "task-1",
    status: String = "pending",
    reply: String? = nil
) -> Task {
    Task(
        id: id,
        deviceToken: nil,
        title: "Task \(id)",
        body: "Body",
        status: status,
        context: nil,
        logs: nil,
        reply: reply,
        createdAt: "2026-07-28T08:30:45Z",
        updatedAt: "2026-07-28T08:30:45Z"
    )
}

func taskResponseData(_ task: Task = makeTask()) throws -> Data {
    try JSONEncoder().encode(TaskResponse(ok: true, task: task))
}

actor ServiceStub: TaskServing {
    enum Behavior: Sendable {
        case success
        case failure
        case delayed
    }

    var tasks: [Task]
    var behavior: Behavior
    private(set) var sentReplies: [(String, String)] = []
    private(set) var registrations: [(String, PushMode)] = []

    init(tasks: [Task] = [makeTask()], behavior: Behavior = .success) {
        self.tasks = tasks
        self.behavior = behavior
    }

    func setBehavior(_ behavior: Behavior) {
        self.behavior = behavior
    }

    func fetchTasks() async throws -> [Task] {
        try await waitOrFail()
        return tasks
    }

    func fetchTask(id: String) async throws -> Task {
        try await waitOrFail()
        guard let task = tasks.first(where: { $0.id == id }) else { throw TaskServiceError.httpStatus(404, nil) }
        return task
    }

    func sendReply(taskID: String, text: String) async throws -> Task {
        sentReplies.append((taskID, text))
        try await waitOrFail()
        let old = tasks.first(where: { $0.id == taskID }) ?? makeTask(id: taskID)
        return Task(
            id: old.id,
            deviceToken: old.deviceToken,
            title: old.title,
            body: old.body,
            status: "replied",
            context: old.context,
            logs: old.logs,
            reply: text,
            createdAt: old.createdAt,
            updatedAt: old.updatedAt
        )
    }

    func registerDevice(token: String, pushMode: PushMode) async throws {
        registrations.append((token, pushMode))
        try await waitOrFail()
    }

    func health() async throws -> Bool {
        try await waitOrFail()
        return true
    }

    private func waitOrFail() async throws {
        switch behavior {
        case .success:
            break
        case .failure:
            throw TaskServiceError.network(.notConnectedToInternet)
        case .delayed:
            try await ContinuousClock().sleep(for: .milliseconds(200))
        }
    }
}
