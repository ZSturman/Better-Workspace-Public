import XCTest

final class MobileWorkspaceUITests: XCTestCase {
    private func launchOffline() -> XCUIApplication {
        let app = XCUIApplication()
        // A used device has a cached index; these checks are about a first launch.
        app.launchArguments = ["-mobileCloudDisabled", "YES", "-BWIgnoreSnapshotCache", "YES"]
        app.launch()
        return app
    }

    func testOfflineStateKeepsCaptureAvailable() {
        let app = launchOffline()
        XCTAssertTrue(app.workspaceDestination("Overview").exists)
        let unavailable = app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS %@", "Sync unavailable")
        ).firstMatch
        XCTAssertTrue(unavailable.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Choose the next step for a project, or record a new idea."].exists)
    }

    func testMobileFirstDestinationsRemainReachableOffline() {
        let app = launchOffline()
        // Since October 23 Projects and Work share Planning, beside Workspace.
        for area in ["Overview", "Workspace", "Planning", "Ideas", "Ingest"] {
            let destination = app.workspaceDestination(area)
            XCTAssertTrue(destination.exists, "Missing \(area) destination")
            destination.tap()
            // A first launch offers the Workspace welcome; it covers the tab bar.
            if area == "Workspace", app.buttons["unified.welcome.local"].waitForExistence(timeout: 3) {
                app.buttons["unified.welcome.local"].tap()
            }
        }
        for view in ["Projects", "Work"] {
            app.openPlanning(view)
            XCTAssertTrue(app.navigationBars[view].waitForExistence(timeout: 10), "Planning shows \(view)")
        }
        XCTAssertFalse(app.buttons["Library"].exists)
    }

    func testWidgetDeepLinksOpenWorkAndIdeas() {
        let work = XCUIApplication()
        work.launchArguments = ["-mobileCloudDisabled", "YES",
                                "-BWInitialURL", "betterworkspace-mobile://work"]
        work.launch()
        XCTAssertTrue(work.navigationBars["Work"].waitForExistence(timeout: 20))

        let ideas = XCUIApplication()
        ideas.launchArguments = ["-mobileCloudDisabled", "YES",
                                "-BWInitialURL", "betterworkspace-mobile://ideas"]
        ideas.launch()
        XCTAssertTrue(ideas.navigationBars["Ideas"].waitForExistence(timeout: 20))
    }

    func testTipKitDatastoreResetLeavesOverviewAvailable() {
        let app = XCUIApplication()
        app.launchArguments = ["-mobileCloudDisabled", "YES",
                               "-BWResetTipsForTesting", "YES"]
        app.launch()
        XCTAssertTrue(app.navigationBars["Overview"].waitForExistence(timeout: 20))
    }
}
