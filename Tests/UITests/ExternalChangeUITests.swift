import XCTest

/// Changes made outside the app — by Finder, another editor, or a tool appending to
/// its log — while the app is open on them. The app must follow without a relaunch,
/// a manual refresh, or clicking away and back.
final class ExternalChangeUITests: IsolatedUITestCase {

    private var settingsFile: URL { Self.fixtureRoot.appendingPathComponent("Areas.json") }

    private func launch(startingIn area: String, settings: [String: String] = [:]) throws -> XCUIApplication {
        if settings.isEmpty == false {
            let areas = settings.map { "\"\($0.key)\": {\"configuration\": {\"layout\": \"\($0.value)\"}}" }
            try "{\"version\": 1, \"areas\": {\(areas.joined(separator: ","))}}"
                .write(to: settingsFile, atomically: true, encoding: .utf8)
        }
        let app = isolatedApp(arguments: ["-bwStartArea", area])
        app.launch()
        requireForeground(app)
        requireWindow(app)
        return app
    }

    private func text(_ app: XCUIApplication, containing fragment: String) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "value CONTAINS %@ OR label CONTAINS %@", fragment, fragment)).firstMatch
    }

    private func append(_ line: String, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((line + "\n").utf8))
        try handle.close()
    }

    /// Logs is a tail viewer for files other tools keep writing. Its lines used to be
    /// read once, on click, and never again.
    func testAnAppendedLogLineAppearsInTheOpenTail() throws {
        let log = Self.workspaceRoot.appendingPathComponent("Logs/2026-09-28/session.log")
        let app = try launch(startingIn: "Logs")
        XCTAssertTrue(text(app, containing: "Fixture content").waitForExistence(timeout: 20), "The newest day's log opens")

        try append("[2026-09-28 10:00:00] [ERROR] [fixture] appended-while-open", to: log)
        XCTAssertTrue(text(app, containing: "appended-while-open").waitForExistence(timeout: 10),
                      "A line written by another tool should appear without reselecting the file")
        add(XCTAttachment(screenshot: app.windows.firstMatch.screenshot()))
    }

    /// An opened outline folder re-reads when something lands inside it, and a nested
    /// selection is not dropped by an unrelated change in the same area.
    func testAnOpenedFolderUpdatesAndANestedSelectionSurvives() throws {
        let reference = Self.workspaceRoot.appendingPathComponent("For Reference")
        let guides = reference.appendingPathComponent("Guides", isDirectory: true)
        try FileManager.default.createDirectory(at: guides, withIntermediateDirectories: true)
        try "style".write(to: guides.appendingPathComponent("Style guide.md"), atomically: true, encoding: .utf8)

        let app = try launch(startingIn: "For Reference", settings: ["For Reference": "outline"])
        let outline = app.outlines["area.outline"]
        XCTAssertTrue(outline.waitForExistence(timeout: 20))
        let triangle = outline.disclosureTriangles.firstMatch
        XCTAssertTrue(triangle.waitForExistence(timeout: 10))
        triangle.click()
        let style = app.staticTexts["Style guide"].firstMatch
        XCTAssertTrue(style.waitForExistence(timeout: 10))
        style.click()
        XCTAssertFalse(app.staticTexts["Nothing selected"].waitForExistence(timeout: 2))

        // Inside the opened folder: it should appear there.
        try "voice".write(to: guides.appendingPathComponent("Voice guide.md"), atomically: true, encoding: .utf8)
        XCTAssertTrue(app.staticTexts["Voice guide"].waitForExistence(timeout: 10),
                      "A file added to an opened folder should appear in it")

        // Elsewhere in the same area: the nested selection must stay put.
        try "other".write(to: reference.appendingPathComponent("Unrelated.md"), atomically: true, encoding: .utf8)
        XCTAssertTrue(app.staticTexts["Unrelated"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["Nothing selected"].exists,
                       "A change elsewhere in the area must not drop a nested selection")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "value == 'Style guide' OR label == 'Style guide'"))
            .count >= 2, "The inspector still names the selected file")
        add(XCTAttachment(screenshot: app.windows.firstMatch.screenshot()))
    }

    /// A drilled gallery folder was read once, on click.
    func testADrilledGalleryFolderShowsANewImage() throws {
        let folder = Self.workspaceRoot.appendingPathComponent("For Inspiration/Moodboard", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let picture = Self.workspaceRoot.appendingPathComponent("For Inspiration/Wide inspiration.png")
        try FileManager.default.copyItem(at: picture, to: folder.appendingPathComponent("First.png"))

        let app = try launch(startingIn: "For Inspiration")
        let cell = app.staticTexts["Moodboard"].firstMatch
        XCTAssertTrue(cell.waitForExistence(timeout: 20))
        cell.doubleClick()
        XCTAssertTrue(app.staticTexts["First"].waitForExistence(timeout: 10))

        try FileManager.default.copyItem(at: picture, to: folder.appendingPathComponent("Second.png"))
        XCTAssertTrue(app.staticTexts["Second"].waitForExistence(timeout: 10),
                      "An image added to the open folder should appear in it")
        add(XCTAttachment(screenshot: app.windows.firstMatch.screenshot()))
    }

    /// Renaming the open area in Finder used to leave "Folder not found" on screen.
    func testRenamingTheOpenAreaInFinderKeepsItOpen() throws {
        let original = Self.workspaceRoot.appendingPathComponent("Client Notes", isDirectory: true)
        try FileManager.default.createDirectory(at: original, withIntermediateDirectories: true)
        try "kickoff".write(to: original.appendingPathComponent("Kickoff.md"), atomically: true, encoding: .utf8)

        let app = try launch(startingIn: "Client Notes")
        XCTAssertTrue(app.staticTexts["Kickoff"].waitForExistence(timeout: 20))

        try FileManager.default.moveItem(at: original, to: Self.workspaceRoot.appendingPathComponent("Clients"))
        XCTAssertTrue(app.descendants(matching: .any)["sidebar.folder.Clients"].firstMatch.waitForExistence(timeout: 15))
        XCTAssertFalse(app.staticTexts["Folder not found"].waitForExistence(timeout: 3),
                       "The open area should follow its rename")
        XCTAssertTrue(app.staticTexts["Kickoff"].exists, "and keep showing its contents")
        add(XCTAttachment(screenshot: app.windows.firstMatch.screenshot()))
    }

    /// Moving a project folder out in Finder while Projects was open crashed the app:
    /// a table cell read the model from the environment as its row was removed.
    func testAProjectMovedOutWhileProjectsIsOpenLeavesTheAppRunning() throws {
        let projects = Self.workspaceRoot.appendingPathComponent("Projects")
        let leaving = projects.appendingPathComponent("Leaving project", isDirectory: true)
        try FileManager.default.createDirectory(at: leaving, withIntermediateDirectories: true)
        try "x".write(to: leaving.appendingPathComponent("notes.md"), atomically: true, encoding: .utf8)

        let app = try launch(startingIn: "Projects")
        XCTAssertTrue(app.staticTexts["Leaving project"].waitForExistence(timeout: 20))
        try FileManager.default.moveItem(at: leaving, to: Self.fixtureRoot.appendingPathComponent("Leaving project"))

        let gone = NSPredicate(format: "exists == false")
        expectation(for: gone, evaluatedWith: app.staticTexts["Leaving project"])
        waitForExpectations(timeout: 10)
        XCTAssertEqual(app.state, .runningForeground, "Removing a row must not take the app down")
        XCTAssertTrue(app.staticTexts["Fixture project"].exists)
    }

    /// The whole Workspace going away (a drive unplugged) must read as unavailable, not
    /// as every area emptied — and coming back must bring it all back without a relaunch.
    func testAMissingWorkspaceSaysSoKeepsWhatItShowedAndRecovers() throws {
        let app = try launch(startingIn: "Projects")
        XCTAssertTrue(app.staticTexts["Fixture project"].waitForExistence(timeout: 20))

        let away = Self.fixtureRoot.appendingPathComponent("Workspace unplugged")
        try FileManager.default.moveItem(at: Self.workspaceRoot, to: away)
        XCTAssertTrue(app.descendants(matching: .any)["workspace.unavailable"].firstMatch.waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["Fixture project"].exists, "What was last seen stays on screen")
        add(XCTAttachment(screenshot: app.windows.firstMatch.screenshot()))

        try FileManager.default.moveItem(at: away, to: Self.workspaceRoot)
        let banner = app.descendants(matching: .any)["workspace.unavailable"].firstMatch
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: banner)
        waitForExpectations(timeout: 15)

        // Watching resumed: a project made now appears on its own.
        try FileManager.default.createDirectory(at: Self.workspaceRoot.appendingPathComponent("Projects/Arrived after"),
                                                withIntermediateDirectories: true)
        XCTAssertTrue(app.staticTexts["Arrived after"].waitForExistence(timeout: 15))
    }
}
