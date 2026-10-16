import XCTest

/// Before the first snapshot arrives the phone has nothing to show, and must say it is
/// loading rather than invite someone to create their first project.
final class MobileLoadingStateUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    override func tearDown() {
        XCUIDevice.shared.orientation = .portrait
    }

    private func launchSlow() -> XCUIApplication {
        let app = XCUIApplication()
        // Offline, so the held-back fetch then fails into the ordinary unavailable state.
        app.launchArguments = ["-mobileCloudDisabled", "YES", "-bwSimulatedReadDelay", "25", "-BWIgnoreSnapshotCache", "YES"]
        app.launch()
        return app
    }

    private func attach(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testTabsSayTheyAreLoadingBeforeTheFirstSnapshot() {
        let app = launchSlow()
        let loading = app.descendants(matching: .any)["mobile-loading"].firstMatch
        XCTAssertTrue(loading.waitForExistence(timeout: 20), "Overview should say it is loading")
        XCTAssertFalse(app.staticTexts["Choose the next step for a project, or record a new idea."].exists)
        attach("Overview loading portrait")

        for tab in ["Projects", "Work", "Ideas"] {
            app.workspaceDestination(tab).tap()
            XCTAssertTrue(app.descendants(matching: .any)["mobile-loading"].firstMatch.waitForExistence(timeout: 5),
                          "\(tab) should say it is loading")
            attach("\(tab) loading portrait")
        }
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(app.descendants(matching: .any)["mobile-loading"].firstMatch.waitForExistence(timeout: 5))
        attach("Ideas loading landscape")
        XCUIDevice.shared.orientation = .portrait

        // Once the held-back fetch fails, the honest offline empty state replaces it.
        app.workspaceDestination("Overview").tap()
        XCTAssertTrue(app.staticTexts["Choose the next step for a project, or record a new idea."]
            .waitForExistence(timeout: 45))
        XCTAssertFalse(app.descendants(matching: .any)["mobile-loading"].firstMatch.exists)
        attach("Overview after first fetch")
    }
}
