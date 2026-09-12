import XCTest

@MainActor
final class TaxUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    func testFirstLaunchShowsRemoteConfigurationState() {
        let app = launch()
        XCTAssertTrue(app.staticTexts["Remote workspace not configured"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["Add host, device, and encryption settings."].exists)
        XCTAssertFalse(app.staticTexts["Mock tax task"].exists)
    }

    func testSettingsExposeRemoteConfigurationAndNoTaskReplyControls() {
        let app = launch()
        app.buttons["settings.open"].tap()
        XCTAssertTrue(app.textFields["settings.serverURL"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.secureTextFields["settings.apiKey"].exists)
        XCTAssertTrue(app.textFields["Host ID"].exists)
        XCTAssertTrue(app.textFields["Device ID"].exists)
        XCTAssertTrue(app.secureTextFields["256-bit encryption key"].exists)
        XCTAssertFalse(app.buttons["reply.send"].exists)

        XCTAssertFalse(app.staticTexts["Renderer"].exists)
    }

    func testScreenshotModeUsesDeterministicWorkspaceFixtures() {
        let app = launch("--screenshot-mode", "--screenshot-screen", "workspaces")

        XCTAssertTrue(app.staticTexts["Atlas"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["Orbit API"].exists)
        XCTAssertTrue(app.staticTexts["Release Notes"].exists)
    }

    func testScreenshotDetailScreensIncludeBackButton() {
        for screen in ["files", "settings"] {
            let app = launch("--screenshot-mode", "--screenshot-screen", screen)
            XCTAssertTrue(app.buttons["Back"].waitForExistence(timeout: 8), "Missing Back button on \(screen)")
            app.terminate()
        }
    }

    func testLiveRelayListsWorkspacesAndOpensFiles() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let apiKey = environment["TAX_UI_API_KEY"],
              let encryptionKey = environment["TAX_UI_E2EE_KEY"] else {
            throw XCTSkip("Live relay smoke requires TAX_UI_API_KEY and TAX_UI_E2EE_KEY")
        }
        let app = launch(
            "--mock-configured",
            "--mock-server-url", environment["TAX_UI_SERVER"] ?? "https://tax.138-249-127-23.nip.io",
            "--mock-api-key", apiKey,
            "--mock-host-id", environment["TAX_UI_HOST_ID"] ?? "mac-main",
            "--mock-device-id", environment["TAX_UI_DEVICE_ID"] ?? "iphone-main",
            "--mock-e2ee-key", encryptionKey
        )

        let workspace = app.staticTexts["main"].firstMatch
        XCTAssertTrue(workspace.waitForExistence(timeout: 20))
        workspace.tap()
        XCTAssertTrue(app.staticTexts["Browse workspace files"].waitForExistence(timeout: 10))
        app.staticTexts["Browse workspace files"].tap()
        XCTAssertTrue(app.navigationBars["Files"].waitForExistence(timeout: 10))
    }

    @discardableResult
    private func launch(_ arguments: String...) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"] + arguments
        app.launch()
        return app
    }
}
