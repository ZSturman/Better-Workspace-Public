import XCTest

/// Quitting and relaunching brings back where you were — the open area, and whether the
/// inspector was showing — and copes with that area having changed while the app was
/// closed.
final class StateRestorationUITests: IsolatedUITestCase {

    /// No `-bwStartArea`: the point is what the app chooses on its own.
    private func launch() -> XCUIApplication {
        let app = isolatedApp()
        app.launch()
        requireWindow(app)
        return app
    }

    private func relaunch(_ app: XCUIApplication) -> XCUIApplication {
        app.terminate()
        _ = app.wait(for: .notRunning, timeout: 10)
        return launch()
    }

    private func open(_ app: XCUIApplication, area: String) {
        let row = revealSidebarRow(app, "sidebar.folder.\(area)")
        XCTAssertTrue(row.waitForExistence(timeout: 20))
        row.click()
    }

    private func header(_ app: XCUIApplication, _ title: String) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "identifier == %@ AND (value == %@ OR label == %@)", "area.title", title, title)).firstMatch
    }

    func testTheOpenAreaAndTheInspectorComeBackAfterAQuit() throws {
        var app = launch()
        XCTAssertTrue(header(app, "Overview").waitForExistence(timeout: 20), "First launch opens on Overview")
        open(app, area: "For Reference")
        XCTAssertTrue(header(app, "For Reference").waitForExistence(timeout: 10))
        app.buttons["Inspector"].firstMatch.click()
        XCTAssertFalse(app.staticTexts["Nothing selected"].waitForExistence(timeout: 2), "Inspector hidden")

        app = relaunch(app)
        XCTAssertTrue(header(app, "For Reference").waitForExistence(timeout: 20), "Reopens on the area left open")
        XCTAssertFalse(app.staticTexts["Nothing selected"].waitForExistence(timeout: 3), "The inspector stays hidden")
        add(XCTAttachment(screenshot: app.windows.firstMatch.screenshot()))
    }

    func testAnAreaRenamedWhileClosedIsFollowed() throws {
        let original = Self.workspaceRoot.appendingPathComponent("Client Notes", isDirectory: true)
        try FileManager.default.createDirectory(at: original, withIntermediateDirectories: true)
        try "kickoff".write(to: original.appendingPathComponent("Kickoff.md"), atomically: true, encoding: .utf8)

        var app = launch()
        open(app, area: "Client Notes")
        XCTAssertTrue(app.staticTexts["Kickoff"].waitForExistence(timeout: 10))
        app.terminate()
        _ = app.wait(for: .notRunning, timeout: 10)

        try FileManager.default.moveItem(at: original, to: Self.workspaceRoot.appendingPathComponent("Clients"))
        app = launch()
        XCTAssertTrue(app.staticTexts["Kickoff"].waitForExistence(timeout: 20), "Reopens on the renamed area")
        XCTAssertTrue(header(app, "Clients").exists)
        XCTAssertFalse(app.staticTexts["Folder not found"].exists)
    }

    func testAnAreaRemovedWhileClosedFallsBackToOverview() throws {
        let doomed = Self.workspaceRoot.appendingPathComponent("Temporary", isDirectory: true)
        try FileManager.default.createDirectory(at: doomed, withIntermediateDirectories: true)
        try "x".write(to: doomed.appendingPathComponent("x.md"), atomically: true, encoding: .utf8)

        var app = launch()
        open(app, area: "Temporary")
        XCTAssertTrue(app.staticTexts["x"].waitForExistence(timeout: 10))
        app.terminate()
        _ = app.wait(for: .notRunning, timeout: 10)

        try FileManager.default.removeItem(at: doomed)
        app = launch()
        XCTAssertTrue(header(app, "Overview").waitForExistence(timeout: 20))
        XCTAssertFalse(app.staticTexts["Folder not found"].exists)
    }
}
