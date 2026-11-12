import XCTest

/// Invoked by Tools/test_root_integrations.py with an owned loopback server/app.
final class WorkspaceRootItemUITests: XCTestCase {
    private var fixture: URL!
    private var root: URL { fixture.appendingPathComponent("Workspace") }
    override func setUpWithError() throws {
        continueAfterFailure = false
        try XCTSkipUnless(ProcessInfo.processInfo.environment["BW_ROOT_WEB_URL"] != nil, "Use the owned integration fixture runner")
        fixture = FileManager.default.temporaryDirectory.appendingPathComponent("bw-root-ui-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: fixture.appendingPathComponent("Inbox"), withIntermediateDirectories: false)
    }
    override func tearDownWithError() throws {
        guard let fixture else { return }
        let app = XCUIApplication(); app.terminate(); _ = app.wait(for: .notRunning, timeout: 10)
        try FileManager.default.removeItem(at: fixture)
    }
    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["BW_TEST_DATABASE_PATH"] = fixture.appendingPathComponent("private.sqlite").path
        app.launchArguments = ["-workspaceRootPath", root.path, "-ingestRootPath", fixture.appendingPathComponent("Inbox").path,
                               "-bwWindowWidth", "820", "-bwWindowHeight", "520"]
        app.launch(); app.activate(); return app
    }
    private func select(_ name: String, in app: XCUIApplication) {
        let row = app.descendants(matching: .any)["sidebar.root." + name].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 20)); row.click()
    }
    private func shot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }

    func testEmbeddedWebNavigationReloadPopupFailuresAndFileFallback() throws {
        let base = try XCTUnwrap(ProcessInfo.processInfo.environment["BW_ROOT_WEB_URL"])
        try Data(("[InternetShortcut]\nURL=" + base + "/start").utf8).write(to: root.appendingPathComponent("Local.url"))
        try Data("URL=javascript:alert(1)".utf8).write(to: root.appendingPathComponent("Invalid.url"))
        try Data("Ordinary reference note".utf8).write(to: root.appendingPathComponent("Readme.txt"))
        let app = launch(); select("Local.url", in: app)
        XCTAssertTrue(app.staticTexts["First fixture page"].waitForExistence(timeout: 20))
        app.links["Next page"].click()
        XCTAssertTrue(app.staticTexts["Second fixture page"].waitForExistence(timeout: 15))
        app.buttons["rootWeb.back"].click()
        XCTAssertTrue(app.staticTexts["First fixture page"].waitForExistence(timeout: 15))
        app.buttons["rootWeb.forward"].click()
        XCTAssertTrue(app.staticTexts["Second fixture page"].waitForExistence(timeout: 15))
        let visit = app.staticTexts.matching(NSPredicate(format: "value BEGINSWITH 'Visit ' OR label BEGINSWITH 'Visit '")).firstMatch
        let oldVisit = visit.value as? String ?? visit.label
        app.buttons["rootWeb.reload"].click()
        let reloaded = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in visit.exists && (visit.value as? String ?? visit.label) != oldVisit }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [reloaded], timeout: 15), .completed)
        app.links["Popup page"].click()
        XCTAssertTrue(app.staticTexts["Popup fixture page"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["rootWeb.external"].isEnabled)
        shot(app, "root-webpage-820-navigation")
        app.links["Unsupported link"].click()
        XCTAssertTrue(app.staticTexts["rootWeb.error"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Popup fixture page"].exists)
        app.links["Server error"].click()
        let httpError = app.staticTexts["rootWeb.error"]
        let failed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in httpError.exists && (httpError.value as? String ?? httpError.label).contains("503") }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [failed], timeout: 10), .completed)
        select("Invalid.url", in: app)
        XCTAssertTrue(app.staticTexts["rootWeb.error"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["rootWeb.external"].isEnabled)
        select("Readme.txt", in: app)
        XCTAssertTrue(app.buttons["rootFile.open"].waitForExistence(timeout: 10))
        app.terminate(); XCTAssertTrue(app.wait(for: .notRunning, timeout: 10)); app.launch(); app.activate()
        XCTAssertTrue(app.buttons["rootFile.open"].waitForExistence(timeout: 20), "Root selection must survive relaunch")
    }

    func testApplicationDetailsLaunchAndUnavailableBundle() throws {
        let source = try XCTUnwrap(ProcessInfo.processInfo.environment["BW_ROOT_APPLICATION_FIXTURE"])
        // Keep the helper/receipt in its owned build fixture, rather than asking a
        // separate app to write into the UI runner's protected app container.
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("Fixture.app"), withDestinationURL: URL(fileURLWithPath: source))
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Unavailable.app"), withIntermediateDirectories: false)
        let app = launch(); select("Fixture.app", in: app)
        XCTAssertTrue(app.staticTexts["Version 1.2"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["Fixture Application"].exists)
        let name = app.textFields["rootApp.shortcutName"]
        XCTAssertTrue(name.waitForExistence(timeout: 10)); name.click(); name.typeText("Owned fixture shortcut")
        XCTAssertTrue(app.buttons["rootApp.runShortcut"].isEnabled)
        shot(app, "root-application-820-details")
        app.buttons["rootApp.open"].click()
        let receipt = URL(fileURLWithPath: source).deletingLastPathComponent().appendingPathComponent("Opened.txt")
        let opened = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in FileManager.default.fileExists(atPath: receipt.path) }, object: nil)
        let result = XCTWaiter.wait(for: [opened], timeout: 15)
        if result != .completed {
            let error = app.staticTexts["rootApp.error"]
            print("APPLICATION_LAUNCH_ERROR: " + (error.exists ? String(describing: error.value) : "No error displayed"))
            shot(app, "root-application-launch-failure")
        }
        XCTAssertEqual(result, .completed)
        app.activate(); select("Unavailable.app", in: app)
        XCTAssertTrue(app.staticTexts["rootApp.error"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["rootApp.open"].isEnabled)
    }
}
