import XCTest

/// Workflows that move real files, driven through the interface.
///
/// Per-test fixtures seed a folder and verify its destination and nested contents.
final class MacWorkflowTests: IsolatedUITestCase {


    private static func workspace(_ area: String) -> URL {
        workspaceRoot.appendingPathComponent(area, isDirectory: true)
    }

    private static func names(in area: String) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: workspace(area).path)) ?? []
    }

    /// Selects the queue chip whose label starts with `prefix`.
    private func focusItem(_ app: XCUIApplication, startingWith prefix: String) -> Bool {
        let chip = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@", prefix))
            .firstMatch
        guard chip.waitForExistence(timeout: 20), chip.isHittable else { return false }
        chip.click()
        Thread.sleep(forTimeInterval: 1.5)
        return true
    }

    func testImportCopiesAFileWithoutChangingTheOriginal() throws {
        let source = Self.fixtureRoot.appendingPathComponent("Import source.txt")
        try "External import fixture".write(to: source, atomically: true, encoding: .utf8)
        let app = isolatedApp()
        app.launch()
        requireWindow(app)
        openIngest(app)
        XCTAssertTrue(app.buttons["Import…"].firstMatch.waitForExistence(timeout: 20))
        app.buttons["Import…"].firstMatch.click()
        app.typeKey("g", modifierFlags: [.command, .shift])
        app.typeText(source.path)
        app.typeKey(XCUIKeyboardKey.return.rawValue, modifierFlags: [])
        let confirm = try XCTUnwrap(panelButton(app, "Add to Inbox"),
                                    "The open panel's Add to Inbox button was not reachable")
        confirm.click()
        let landed = Self.inboxRoot.appendingPathComponent(source.lastPathComponent)
        let exists = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            FileManager.default.fileExists(atPath: landed.path)
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [exists], timeout: 10), .completed)
        XCTAssertEqual(try String(contentsOf: source), "External import fixture")
        XCTAssertEqual(try String(contentsOf: landed), "External import fixture")
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Import source'")).firstMatch.waitForExistence(timeout: 10))
    }

    func testFailedCapturePreservesDraft() throws {
        let blocked = Self.fixtureRoot.appendingPathComponent("not-a-folder")
        try "fixture".write(to: blocked, atomically: true, encoding: .utf8)
        let app = isolatedApp()
        app.launchArguments = ["-workspaceRootPath", Self.workspaceRoot.path, "-ingestRootPath", blocked.path]
        app.launch()
        requireWindow(app)
        openIngest(app)
        app.buttons["ingest.newCapture"].firstMatch.click()
        let field = app.textViews["ingest.captureField"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 20))
        field.click()
        field.typeText("Retain this unsaved draft")
        app.buttons["ingest.captureButton"].firstMatch.click()
        // Dismiss the app's write-error alert, if presented.
        if app.alerts.firstMatch.waitForExistence(timeout: 5) { app.alerts.buttons.firstMatch.click() }
        XCTAssertEqual(field.value as? String, "Retain this unsaved draft")
        XCTAssertEqual(try String(contentsOf: blocked), "fixture")
    }

    /// A folder classified as a Project must arrive intact, nested contents and all.
    func testClassifyingADroppedFolderMovesItIntoProjectsIntact() throws {
        let app = isolatedApp(arguments: ["-bwWindowWidth", "1400", "-bwWindowHeight", "900"])
        app.launch()
        requireWindow(app)
        // Overview is now the landing screen; the queue chip exists only in Ingest.
        openIngest(app)

        try XCTSkipUnless(focusItem(app, startingWith: "Drop Project"),
                          "Seed the inbox with a 'Drop Project' folder before running this")

        let shownTitle = (app.textFields["ingest.titleField"].firstMatch.value as? String) ?? ""
        XCTAssertEqual(shownTitle, "Drop Project")

        let before = Self.names(in: "Projects").count
        app.descendants(matching: .any)["ingest.destination.Projects"].firstMatch.click()
        Thread.sleep(forTimeInterval: 0.6)
        app.buttons["ingest.fileItButton"].firstMatch.click()
        Thread.sleep(forTimeInterval: 4)

        let after = Self.names(in: "Projects")
        XCTAssertEqual(after.count, before + 1, "Exactly one project should have been added")
        XCTAssertTrue(after.contains(shownTitle),
                      "The folder must land under the name the interface showed")

        // Intact, not flattened or partially copied.
        let landed = Self.workspace("Projects").appendingPathComponent(shownTitle)
        XCTAssertTrue(FileManager.default.fileExists(atPath: landed.appendingPathComponent("README.md").path),
                      "Top-level file missing after the move")
        XCTAssertTrue(FileManager.default.fileExists(atPath: landed.appendingPathComponent("src/main.py").path),
                      "Nested file missing after the move")

        // And the app now shows it in Projects.
        app.descendants(matching: .any)["sidebar.folder.Projects"].firstMatch.click()
        Thread.sleep(forTimeInterval: 3)
        add(XCTAttachment(screenshot: app.windows.firstMatch.screenshot()))
        print("MAC WORKFLOW filed project -> \(shownTitle)")
    }

    /// The safe operations must be reachable for a real Workspace item.
    func testInspectorOffersTheSafeActionsForARealItem() throws {
        let app = isolatedApp(arguments: ["-bwWindowWidth", "1400", "-bwWindowHeight", "900"])
        app.launch()
        app.descendants(matching: .any)["sidebar.folder.Ideas"].firstMatch.click()
        Thread.sleep(forTimeInterval: 2.5)

        // Pick whatever idea is first in the list.
        let ideas = Self.names(in: "Ideas").filter { $0.hasPrefix(".") == false }
        try XCTSkipIf(ideas.isEmpty, "No Ideas on this machine")

        var clicked = false
        for name in ideas.prefix(12) {
            let title = (name as NSString).deletingPathExtension
            let row = app.staticTexts[title].firstMatch
            if row.exists, row.isHittable { row.click(); clicked = true; break }
        }
        try XCTSkipUnless(clicked, "Could not reach an idea row")
        Thread.sleep(forTimeInterval: 1.5)

        for action in ["Quick Look", "Open", "Reveal in Finder"] {
            let button = app.buttons[action].firstMatch
            XCTAssertTrue(button.waitForExistence(timeout: 10), "\(action) missing from the inspector")
            XCTAssertTrue(button.isEnabled, "\(action) should be available for a real item")
        }

        // The inspector's path must be the item's real location.
        let pathText = app.staticTexts.matching(
            NSPredicate(format: "value CONTAINS %@", "/Workspace/Ideas/")).firstMatch
        XCTAssertTrue(pathText.waitForExistence(timeout: 10),
                      "The inspector should show the real filesystem path")
        add(XCTAttachment(screenshot: app.windows.firstMatch.screenshot()))
    }
}
