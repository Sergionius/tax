import XCTest

@MainActor
final class TaxUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    func testFirstLaunchShowsConfigurationState() {
        let app = launch()
        XCTAssertTrue(app.staticTexts["Configuration Required"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Add your API key in Settings."].exists || app.staticTexts["Configure API key and server URL in Settings."].exists)
    }

    func testSavingSettingsLoadsMockTasks() {
        let app = launch()
        app.tabBars.buttons["Settings"].tap()
        let apiKey = app.secureTextFields["settings.apiKey"]
        XCTAssertTrue(apiKey.waitForExistence(timeout: 3))
        apiKey.tap()
        apiKey.typeText("test-key")
        app.keyboards.buttons["Return"].tap()
        app.swipeUp()
        app.buttons["settings.save"].tap()
        app.tabBars.buttons["Tasks"].tap()
        XCTAssertTrue(app.staticTexts["Mock tax task"].waitForExistence(timeout: 5))
    }

    func testOpenTaskAndSendReply() {
        let app = launch("--mock-configured")
        XCTAssertTrue(app.staticTexts["Mock tax task"].waitForExistence(timeout: 5))
        app.staticTexts["Mock tax task"].tap()
        XCTAssertTrue(app.buttons["task.reply"].waitForExistence(timeout: 5))
        app.buttons["task.reply"].tap()
        let editor = app.textViews["reply.text"]
        XCTAssertTrue(editor.waitForExistence(timeout: 3))
        editor.tap()
        editor.typeText("UI reply")
        app.buttons["reply.send"].tap()
        XCTAssertTrue(app.staticTexts["UI reply"].waitForExistence(timeout: 5))
    }

    func testReplyErrorKeepsEnteredText() {
        let app = launch("--mock-reply-error")
        XCTAssertTrue(app.staticTexts["Mock tax task"].waitForExistence(timeout: 5))
        app.staticTexts["Mock tax task"].tap()
        app.buttons["task.reply"].tap()
        let editor = app.textViews["reply.text"]
        editor.tap()
        editor.typeText("Keep me")
        app.buttons["reply.send"].tap()
        XCTAssertTrue(app.alerts["Error"].waitForExistence(timeout: 5))
        app.alerts["Error"].buttons["OK"].tap()
        XCTAssertEqual(editor.value as? String, "Keep me")
    }

    func testMockPushOpensExpectedTask() {
        let app = launch("--mock-task-id", "mock-task-1")
        XCTAssertTrue(app.buttons["task.reply"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Review the generated tax report."].exists)
    }

    func testNetworkErrorShowsRetry() {
        let app = launch("--mock-network-error")
        XCTAssertTrue(app.buttons["tasks.retry"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["No network connection. Try again when you are online."].exists)
    }

    @discardableResult
    private func launch(_ arguments: String...) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"] + arguments
        app.launch()
        return app
    }
}
