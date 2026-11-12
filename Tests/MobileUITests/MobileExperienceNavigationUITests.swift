import XCTest

/// Exercises the production shell with only owned journal/capture fixtures and an
/// offline Mac snapshot. Navigation must never require a second app presentation.
final class MobileExperienceNavigationUITests: XCTestCase {
    func testCaptureCurrentPlanningForStore() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["BW_RELEASE_STORE_INSTALL"] == "1")
        let app = application(route: "projects")
        app.launchArguments += ["-BWResetPlanningFixture", "YES"]
        app.launch(); defer { app.terminate() }
        let row = app.buttons["mobile-project-Projects/Example"]
        XCTAssertTrue(row.waitForExistence(timeout: 20)); row.tap()
        let domain = app.buttons["project.details.domain"]
        XCTAssertTrue(domain.waitForExistence(timeout: 10)); domain.tap()
        app.buttons["Add new domain…"].tap()
        let field = app.alerts.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5)); field.tap(); field.typeText("Technology")
        app.alerts.buttons["Add"].tap()
        let save = app.buttons["Save project details"]
        for _ in 0..<8 where !save.isHittable { app.swipeUp() }
        XCTAssertTrue(save.isHittable); save.tap()
        let saved = app.staticTexts["Saved domain: Technology"]
        for _ in 0..<10 where !saved.isHittable { app.swipeDown() }
        XCTAssertTrue(saved.isHittable)
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "store-current-planning"; attachment.lifetime = .keepAlways; add(attachment)
    }
    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }
    override func tearDownWithError() throws { XCUIDevice.shared.orientation = .portrait }

    private func application(route: String? = nil) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-BWUnifiedFixture", UUID().uuidString,
            "-BWTestUnifiedNavigation", "YES", "-BWTestMobilePlanning", "YES",
            "-mobileCloudDisabled", "YES", "-BWTestCaptureInboxID", UUID().uuidString,
            // Other tests delete fixture ideas in the shared planning suite.
            "-BWResetPlanningFixture", "YES"]
        if let route { app.launchArguments += ["-BWInitialURL", "betterworkspace-mobile://" + route] }
        return app
    }
    private func select(_ name: String, app: XCUIApplication) {
        let destination = app.workspaceDestination(name)
        XCTAssertTrue(destination.waitForExistence(timeout: 10)); destination.tap()
    }
    private func openWorkspace(_ app: XCUIApplication) {
        select("Workspace", app: app)
        let welcome = app.buttons["unified.welcome.local"]
        if welcome.waitForExistence(timeout: 3) { welcome.tap() }
        XCTAssertTrue(app.buttons["unified.new"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["unified.macTools"].exists)
        XCTAssertFalse(app.buttons["unified.backFromMac"].exists)
    }
    func testOneShellRetainsPlanningPathsAndWorkspaceSearch() {
        let app = application(); app.launch(); defer { app.terminate() }
        XCTAssertTrue(app.navigationBars["Overview"].waitForExistence(timeout: 15))
        openWorkspace(app)
        let search = app.textFields["unified.search"]
        search.tap(); search.typeText("Navigation marker")
        search.typeText("\n")
        select("Planning", app: app)
        app.segmentedControls["workspace.planningView"].buttons["Projects"].tap()
        let project = app.buttons["mobile-project-Projects/Example"]
        XCTAssertTrue(project.waitForExistence(timeout: 10)); project.tap()
        XCTAssertTrue(app.navigationBars["Example"].waitForExistence(timeout: 10))
        app.segmentedControls["workspace.planningView"].buttons["Work"].tap()
        XCTAssertTrue(app.navigationBars["Work"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["New work"].isHittable, "The planning selector must not cover the creation toolbar")
        app.segmentedControls["workspace.planningView"].buttons["Projects"].tap()
        XCTAssertTrue(app.navigationBars["Example"].waitForExistence(timeout: 10), "Projects keeps its pushed detail when changing planning views")
        select("Ideas", app: app)
        XCTAssertTrue(app.buttons["mobile-idea-Ideas/Example.md"].waitForExistence(timeout: 10))
        select("Ingest", app: app)
        XCTAssertTrue(app.navigationBars["Ingest"].waitForExistence(timeout: 10))
        select("Workspace", app: app)
        XCTAssertEqual(search.value as? String, "Navigation marker")
        select("Overview", app: app)
        XCTAssertTrue(app.navigationBars["Overview"].waitForExistence(timeout: 10))
        app.buttons["workspace.settings"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Devices & recovery"].exists)
    }
    func testColdWorkLinkSelectsPlanningAndKeepsGlobalNavigation() {
        let app = application(route: "task?id=test-work"); app.launch(); defer { app.terminate() }
        XCTAssertTrue(app.descendants(matching: .any)["work-body"].firstMatch.waitForExistence(timeout: 15))
        XCTAssertTrue(app.segmentedControls["workspace.planningView"].buttons["Work"].isSelected)
        openWorkspace(app)
        select("Planning", app: app)
        XCTAssertTrue(app.descendants(matching: .any)["work-body"].firstMatch.waitForExistence(timeout: 10))
    }
    func testColdJournalLinkOpensWorkspaceEditor() {
        let app = application(); app.launch(); defer { app.terminate() }
        openWorkspace(app)
        app.buttons["unified.new"].tap()
        let title = app.textFields["unified.editor.title"]
        XCTAssertTrue(title.waitForExistence(timeout: 10)); title.tap(); title.typeText("Navigation journal item")
        app.buttons["unified.editor.save"].tap()
        let item = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'unified.item.'")).firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 10))
        let id = String(item.identifier.dropFirst("unified.item.".count))
        app.terminate()
        app.launchArguments += ["-BWInitialURL", "betterworkspace-mobile://task?id=" + id]
        app.launch()
        XCTAssertTrue(title.waitForExistence(timeout: 15))
        XCTAssertEqual(title.value as? String, "Navigation journal item")
        app.buttons["Cancel"].tap()
        select("Overview", app: app)
        XCTAssertTrue(app.navigationBars["Overview"].waitForExistence(timeout: 10))
    }
}
