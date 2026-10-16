import XCTest

/// What the background service contributes to the app, end to end: idea metadata in
/// Ideas, the work log under Logs, the live session and resurfaced ideas in the menu bar,
/// and the service controls in Settings.
///
/// The service is replaced by canned responses (`-bwServiceFixture`), shaped like the
/// real ones. An isolated test never reads the real service and never installs it.
final class BackgroundServiceUITests: IsolatedUITestCase {

    private var fixtureDirectory: URL { Self.fixtureRoot.appendingPathComponent("service") }

    private func writeServiceFixtures() throws {
        try FileManager.default.createDirectory(at: fixtureDirectory, withIntermediateDirectories: true)
        let ideas = Self.workspaceRoot.appendingPathComponent("Ideas")
        for name in ["Desk focus timer", "Parked experiment"] {
            try FileManager.default.createDirectory(at: ideas.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        func write(_ name: String, _ data: Any) throws {
            let body = try JSONSerialization.data(withJSONObject: ["schema_version": 1, "data": data])
            try body.write(to: fixtureDirectory.appendingPathComponent(name))
        }
        try write("v1_health.json", ["state": "running", "watch_roots": []])
        try write("v1_session_live.json", [
            "active": true, "elapsed_seconds": 2580,
            "session": ["id": "s1", "started_at": "2026-10-01T01:00:00+00:00"],
            "project": ["id": "p1", "name": "Fixture project"],
            "recent_files": [],
        ])
        try write("v1_ideas.json", [
            ["id": "i1", "title": "Desk focus timer", "path": ideas.appendingPathComponent("Desk focus timer").path,
             "type": "product", "status": "exploring", "impact": "High",
             "one_liner": "A timer that starts a work session when you flip it.", "keep_suggesting": true],
            ["id": "i2", "title": "Parked experiment", "path": ideas.appendingPathComponent("Parked experiment").path,
             "type": "experiment", "status": "parked", "keep_suggesting": false],
        ])
        let payload = try String(data: JSONSerialization.data(withJSONObject: [
            "active_minutes": 84, "session_count": 3, "summary": "Wrote the sync queue and its retry policy.",
        ]), encoding: .utf8)!
        try write("v1_work-logs.json", [
            ["id": "w1", "project_name": "Fixture project", "date_key": "2026-09-30", "status": "prepared",
             "payload_json": payload, "notion_page_id": NSNull()],
        ])
        try write("v1_settings.json", [
            "notion_enabled": true, "ideas_notion_sync_enabled": true, "ideas_notion_sync_default": false,
            "notion": ["token_present": true,
                       "databases": ["projects": "304aec944d3c80a8", "work_log": "304aec944d3c803f", "ideas": "304aec944d3c8071"],
                       "projects_cache_health": ["state": "ok"], "ideas_sync_health": ["state": "ok", "synced": 30],
                       "work_logs_enabled": true, "work_logs_notion_sync": false],
        ])
        try write("v1_notifications.json", [
            ["id": "n1", "type": "suggestion", "title": "Desk focus timer", "body": "Resurfaced", "entity_id": "i1",
             "state": "delivered", "selected_action": NSNull(), "created_at": "2026-10-01T01:10:00+00:00"],
        ])
    }

    private func launch(startArea: String) throws -> XCUIApplication {
        try writeServiceFixtures()
        let app = isolatedApp(arguments: ["-bwServiceFixture", fixtureDirectory.path, "-bwStartArea", startArea])
        app.launch()
        requireWindow(app)
        return app
    }

    func testIdeasShowTheMetadataTheServiceKeeps() throws {
        let app = try launch(startArea: "Ideas")
        XCTAssertTrue(app.staticTexts["A timer that starts a work session when you flip it."].waitForExistence(timeout: 20))
        XCTAssertTrue(app.staticTexts["Status and type: exploring, product, High impact"].exists)
        XCTAssertTrue(app.staticTexts["Status and type: parked, experiment"].exists)
        add(XCTAttachment(screenshot: app.windows.firstMatch.screenshot()))
    }

    func testAnIdeasMetadataIsEditedInTheInspector() throws {
        let app = try launch(startArea: "Ideas")
        let row = app.staticTexts["Parked experiment"]
        XCTAssertTrue(row.waitForExistence(timeout: 20))
        row.click()
        let status = app.textFields["Status"]
        XCTAssertTrue(status.waitForExistence(timeout: 10), "The inspector offers the idea's metadata")
        status.click()
        status.typeKey("a", modifierFlags: .command)
        status.typeText("exploring")
        app.buttons["Save"].click()
        XCTAssertTrue(app.staticTexts["Status and type: exploring, experiment"].waitForExistence(timeout: 10),
                      "The list shows the saved status")
        add(XCTAttachment(screenshot: app.windows.firstMatch.screenshot()))
    }

    /// The desktop widgets link into the app. An idea's link opens Ideas with that idea
    /// selected; a link to something unknown falls back to Overview.
    func testAWidgetLinkOpensTheIdeaItNames() throws {
        let app = try launch(startArea: "Overview")
        app.open(URL(string: "betterworkspace://item/i2")!)
        XCTAssertTrue(app.textFields["Status"].waitForExistence(timeout: 15), "The idea is selected in the inspector")
        XCTAssertEqual(app.textFields["Status"].value as? String, "parked")
        app.open(URL(string: "betterworkspace://today")!)
        XCTAssertTrue(app.radioButtons["Work Log"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.radioButtons["Work Log"].value as? Int, 1, "Today's work opens the work log")
    }

    func testTheWorkLogIsReadableUnderLogs() throws {
        let app = try launch(startArea: "Logs")
        let workLog = app.radioButtons["Work Log"]
        XCTAssertTrue(workLog.waitForExistence(timeout: 20))
        workLog.click()
        // Each entry is one combined accessibility element; its text is its value.
        let entry = app.staticTexts.matching(NSPredicate(format: "value CONTAINS %@", "Wrote the sync queue")).firstMatch
        XCTAssertTrue(entry.waitForExistence(timeout: 10))
        XCTAssertTrue((entry.value as? String)?.contains("3 sessions") == true)
        XCTAssertTrue(app.staticTexts["2026-09-30"].exists)
        add(XCTAttachment(screenshot: app.windows.firstMatch.screenshot()))
    }

    func testSettingsOffersTheBackgroundService() throws {
        let app = try launch(startArea: "Overview")
        app.typeKey(",", modifierFlags: .command)
        // Settings may be split into tabs; the service controls live under Services.
        let services = app.toolbars.buttons["Services"].exists ? app.toolbars.buttons["Services"] : app.buttons["Services"]
        if services.waitForExistence(timeout: 5) { services.click() }
        let section = app.staticTexts["Background service"]
        XCTAssertTrue(section.waitForExistence(timeout: 10))
        // The status comes from launchd, so the button's title varies by machine; one of
        // the three must be there.
        let titles = ["Start Background Service", "Restart Background Service", "Adopt from Workspace Watcher"]
        XCTAssertTrue(titles.contains { app.buttons[$0].waitForExistence(timeout: 10) })
        // A grouped Form draws a Toggle as a switch or a checkbox depending on the OS.
        let mirror = app.descendants(matching: .any)["service.notion.mirrorIdeas"]
        XCTAssertTrue(mirror.waitForExistence(timeout: 15), "Idea sync can be switched from Better Workspace")
        XCTAssertEqual((mirror.value as? Int) ?? Int(mirror.value as? String ?? ""), 1)
        XCTAssertTrue(app.staticTexts["ideas mirrored here"].exists)
        add(XCTAttachment(screenshot: app.windows.firstMatch.screenshot()))
    }

    /// The menu bar panel's content, hosted in an ordinary window (`-bwMenuBarPanelInWindow`)
    /// because the MenuBarExtra panel itself is out of this runner's reach. The view and
    /// the model are the real ones; only the window around them differs.
    func testTheMenuBarPanelShowsTheSessionAndWhatIsResurfaced() throws {
        try writeServiceFixtures()
        let app = isolatedApp(arguments: ["-bwServiceFixture", fixtureDirectory.path, "-bwStartArea", "Overview",
                                          "-bwMenuBarPanelInWindow", "YES"])
        app.launch()
        requireWindow(app)
        let panel = app.windows["Menu Bar Panel (inspection)"]
        XCTAssertTrue(panel.waitForExistence(timeout: 15))
        XCTAssertFalse(panel.staticTexts["Resurfaced"].exists)
        panel.menuButtons["capture.more"].click()
        app.menuItems["Show activity"].click()
        XCTAssertTrue(panel.descendants(matching: .any)["Working on Fixture project"].waitForExistence(timeout: 15))
        XCTAssertTrue(panel.staticTexts["Resurfaced"].exists)
        XCTAssertTrue(panel.staticTexts["Desk focus timer"].exists)
        XCTAssertTrue(panel.buttons["Process Inbox…"].exists)
        add(XCTAttachment(screenshot: panel.screenshot()))

        // Acting on a suggestion records it with the service and takes it off the list.
        let actions = panel.menuButtons.matching(NSPredicate(format: "identifier != %@ AND identifier != %@", "capture.more", "capture.destination")).firstMatch
        XCTAssertTrue(actions.exists)
        actions.click()
        app.menuItems["Dismiss"].click()
        XCTAssertTrue(panel.staticTexts["Desk focus timer"].waitForNonExistence(timeout: 10))
        XCTAssertFalse(panel.staticTexts["Resurfaced"].exists)
    }

    func testTheMenuBarShowsTheSessionAndWhatIsResurfaced() throws {
        let app = try launch(startArea: "Overview")
        let item = app.statusItems.firstMatch
        guard item.waitForExistence(timeout: 10) else {
            throw XCTSkip("The menu bar extra is not reachable from this test runner")
        }
        // With "Automatically hide and show the menu bar" on, the status item is off
        // screen until the pointer reaches the top edge, and a click at its frame lands
        // on whatever window is there instead. Reveal the menu bar first, as a person does.
        item.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .withOffset(CGVector(dx: 0, dy: -item.frame.midY)).hover()
        sleep(1)
        item.click()
        // Whatever the accessibility tree says, record what is actually on screen, so a
        // person can see the panel even when the runner cannot query it.
        sleep(2)
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "menu-bar-panel"
        shot.lifetime = .keepAlways
        add(shot)
        // The panel's own controls prove it opened. On some runners a MenuBarExtra
        // window never enters the accessibility hierarchy at all; that says nothing
        // about the app, so it is a skip rather than a failure.
        guard app.buttons["Process Inbox…"].waitForExistence(timeout: 5) else {
            throw XCTSkip("The menu bar extra's panel is not in this runner's accessibility hierarchy")
        }
        app.menuButtons["capture.more"].firstMatch.click()
        app.menuItems["Show activity"].firstMatch.click()
        let live = app.descendants(matching: .any)["Working on Fixture project"]
        XCTAssertTrue(live.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Resurfaced"].exists)
        XCTAssertTrue(app.staticTexts["Desk focus timer"].exists)
        add(XCTAttachment(screenshot: XCUIScreen.main.screenshot()))
        app.typeKey(.escape, modifierFlags: [])
    }
}
