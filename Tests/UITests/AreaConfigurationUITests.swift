import XCTest

/// The configurable-area layer, driven through the real app: a folder the app has
/// never heard of is discovered, presented, and configured without a code change, and
/// its settings land in the private file rather than the folder.
final class AreaConfigurationUITests: IsolatedUITestCase {

    private var clientNotes: URL { Self.workspaceRoot.appendingPathComponent("Client Notes") }
    private var settingsFile: URL { Self.fixtureRoot.appendingPathComponent("Areas.json") }

    override func setUpWithError() throws {
        try super.setUpWithError()
        try FileManager.default.createDirectory(at: clientNotes.appendingPathComponent("Contracts"),
                                                withIntermediateDirectories: true)
        for name in ["Q3 kickoff.md", "Pricing questions.md"] {
            try "# \(name)".write(to: clientNotes.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
    }

    private func launch(startingIn area: String, width: Int = 820, height: Int = 520) -> XCUIApplication {
        let app = isolatedApp(arguments: ["-bwStartArea", area,
                                          "-bwWindowWidth", "\(width)", "-bwWindowHeight", "\(height)"])
        app.launch()
        requireForeground(app)
        requireWindow(app)
        return app
    }

    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    func testAnUnfamiliarFolderIsListedThenConfiguredPrivately() throws {
        let app = launch(startingIn: "Client Notes")
        let contentsBefore = try FileManager.default.contentsOfDirectory(atPath: clientNotes.path).sorted()

        XCTAssertTrue(element(app, "sidebar.folder.Client Notes").waitForExistence(timeout: 15))
        XCTAssertTrue(element(app, "area.setUp").waitForExistence(timeout: 10),
                      "A folder nobody has configured should say it is using the default list")
        XCTAssertTrue(app.staticTexts["Q3 kickoff"].waitForExistence(timeout: 10))
        add(XCTAttachment(screenshot: app.windows.firstMatch.screenshot()))

        let layout = element(app, "area.layout")
        XCTAssertTrue(layout.waitForExistence(timeout: 5))
        layout.click()
        app.menuItems["Table"].click()

        XCTAssertTrue(element(app, "area.table").waitForExistence(timeout: 10), "Choosing Table should show a table")
        XCTAssertGreaterThan(tableColumns(app).count, 1, "A table has real columns, not a single list column")
        XCTAssertTrue(app.buttons["Modified"].exists, "Its columns have headers to sort by")
        XCTAssertFalse(element(app, "area.setUp").exists, "A configured folder is no longer unfamiliar")
        add(XCTAttachment(screenshot: app.windows.firstMatch.screenshot()))

        let saved = try String(contentsOf: settingsFile, encoding: .utf8)
        XCTAssertTrue(saved.contains("\"Client Notes\""), saved)
        XCTAssertTrue(saved.contains("\"table\""), saved)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: clientNotes.path).sorted(), contentsBefore,
                       "Configuring an area must not write anything into the folder")

        // Kept across launches.
        app.terminate()
        let relaunched = launch(startingIn: "Client Notes")
        XCTAssertTrue(element(relaunched, "area.table").waitForExistence(timeout: 15))
    }

    func testAFolderMadeInFinderWhileRunningBecomesAnArea() throws {
        let app = launch(startingIn: "Ideas", width: 1100, height: 800)
        XCTAssertTrue(element(app, "sidebar.folder.Ideas").waitForExistence(timeout: 15))

        let live = Self.workspaceRoot.appendingPathComponent("Made While Running")
        try FileManager.default.createDirectory(at: live, withIntermediateDirectories: true)
        try "note".write(to: live.appendingPathComponent("first.txt"), atomically: true, encoding: .utf8)

        let row = element(app, "sidebar.folder.Made While Running")
        XCTAssertTrue(row.waitForExistence(timeout: 20), "A Finder-created folder should appear without a relaunch")
        row.click()
        XCTAssertTrue(app.staticTexts["first"].waitForExistence(timeout: 10))
    }

    func testAWorkQueueFolderCreatesItsOwnKindInPlace() throws {
        let app = launch(startingIn: "Features", width: 1100, height: 800)
        let create = element(app, "area.newWorkItem")
        XCTAssertTrue(create.waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["New Feature"].exists, "Features is configured as a feature queue")
    }
}
