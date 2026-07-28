import XCTest
@testable import tax

@MainActor
final class ScreenStoreTests: XCTestCase {
    func testListLoadingEmptyContentAndErrorStates() async {
        let store = TaskListStore()
        let delayed = ServiceStub(behavior: .delayed)
        let loading = Swift.Task { await store.load(using: delayed) }
        await Swift.Task<Never, Never>.yield()
        XCTAssertEqual(store.state, .loading)
        await loading.value
        XCTAssertEqual(store.state, .content)

        let empty = ServiceStub(tasks: [])
        await store.load(using: empty)
        XCTAssertEqual(store.state, .empty)

        let failure = ServiceStub(tasks: [], behavior: .failure)
        await store.load(using: failure)
        guard case .error = store.state else { return XCTFail("Expected error state") }
    }

    func testListCanRetryAfterNetworkError() async {
        let service = ServiceStub(behavior: .failure)
        let store = TaskListStore()
        await store.load(using: service)
        guard case .error = store.state else { return XCTFail("Expected error") }

        await service.setBehavior(.success)
        await store.load(using: service)
        XCTAssertEqual(store.state, .content)
        XCTAssertEqual(store.tasks.count, 1)
    }

    func testReplyRejectsEmptyText() async {
        let service = ServiceStub()
        let store = ReplyStore()
        store.replyText = "  \n "
        XCTAssertFalse(store.canSend)
        let result = await store.send(taskID: "task-1", using: service)
        let sentReplies = await service.sentReplies
        XCTAssertNil(result)
        XCTAssertTrue(sentReplies.isEmpty)
    }

    func testReplyBlocksSecondSendWhileRequestIsRunning() async {
        let service = ServiceStub(behavior: .delayed)
        let store = ReplyStore()
        store.replyText = "answer"
        let first = Swift.Task { await store.send(taskID: "task-1", using: service) }
        await Swift.Task<Never, Never>.yield()
        XCTAssertTrue(store.isSending)
        let second = await store.send(taskID: "task-1", using: service)
        XCTAssertNil(second)
        _ = await first.value
        let sentCount = await service.sentReplies.count
        XCTAssertEqual(sentCount, 1)
    }

    func testReplyPreservesTextOnTemporaryFailure() async {
        let service = ServiceStub(behavior: .failure)
        let store = ReplyStore()
        store.replyText = "keep this reply"
        let result = await store.send(taskID: "task-1", using: service)
        XCTAssertNil(result)
        XCTAssertEqual(store.replyText, "keep this reply")
        XCTAssertNotNil(store.errorMessage)
    }

    func testDetailUpdatesAfterSuccessfulReply() async {
        let detail = TaskDetailStore()
        let original = makeTask()
        detail.apply(original)
        let reply = ReplyStore()
        reply.replyText = "done"
        let service = ServiceStub(tasks: [original])

        let updated = await reply.send(taskID: original.id, using: service)
        detail.apply(try! XCTUnwrap(updated))
        XCTAssertEqual(detail.task?.reply, "done")
        XCTAssertEqual(detail.task?.status, "replied")
    }
}
