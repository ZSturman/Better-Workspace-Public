import XCTest

/// Owns every directory it reads/writes; no snapshots of the person's Workspace.
final class WorkspaceSetupUITests: XCTestCase {
    private var fixture: URL!
    private var root: URL { fixture.appendingPathComponent("Workspace") }
    override func setUpWithError() throws {
        continueAfterFailure = false
        fixture = FileManager.default.temporaryDirectory.appendingPathComponent("bw-setup-ui-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: fixture.appendingPathComponent("Inbox"), withIntermediateDirectories: false)
    }
    override func tearDownWithError() throws {
        let app = XCUIApplication(); app.terminate(); _ = app.wait(for: .notRunning, timeout: 10)
        if let fixture { try FileManager.default.removeItem(at: fixture) }
    }
    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["BW_TEST_DATABASE_PATH"] = fixture.appendingPathComponent("private.sqlite").path
        app.launchArguments = ["-workspaceRootPath", root.path, "-ingestRootPath", fixture.appendingPathComponent("Inbox").path,
                               "-bwWindowWidth", "820", "-bwWindowHeight", "520"]
        app.launch(); app.activate()
        return app
    }
    private func shot(_ app: XCUIApplication, _ name: String) {
        let capture = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        capture.name = name; capture.lifetime = .keepAlways; add(capture)
    }

    func testReviewedStarterPreservesFilesAndDiscoversCustomRootFolders() throws {
        for name in ["Projects", "Custom Area", "_Root Group"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: false)
        }
        let original = root.appendingPathComponent("Projects/Keep.txt"), bytes = Data("Original".utf8)
        try bytes.write(to: original)
        try bytes.write(to: root.appendingPathComponent("Features"))
        let app = launch()
        let setup = app.buttons["workspace.setup"]
        XCTAssertTrue(setup.waitForExistence(timeout: 20)); setup.click()
        let create = app.buttons["workspaceSetup.create"]
        XCTAssertTrue(create.waitForExistence(timeout: 10))
        let todo = app.checkBoxes["workspaceSetup.folder.To Do"]
        XCTAssertTrue(todo.waitForExistence(timeout: 10)); todo.click()
        XCTAssertEqual(create.label, "Create 1 Selected Folder")
        XCTAssertTrue(create.isHittable)
        shot(app, "workspace-setup-reviewed-existing-820")
        create.click()
        XCTAssertTrue(app.staticTexts["workspaceSetup.result"].waitForExistence(timeout: 10))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("Ideas").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("To Do").path))
        XCTAssertEqual(try Data(contentsOf: original), bytes)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("Features")), bytes)
        XCTAssertFalse(create.isEnabled, "Creation must not reselect folders the person left unchecked")
        app.buttons["workspaceSetup.done"].click()
        for name in ["Ideas", "Custom Area", "_Root Group"] {
            XCTAssertTrue(app.descendants(matching: .any)["sidebar.folder." + name].firstMatch.waitForExistence(timeout: 15))
        }
    }

    func testEmptyWorkspaceOffersSetupAndCompletionSurvivesRelaunch() throws {
        let app = launch()
        let create = app.buttons["workspaceSetup.create"]
        XCTAssertTrue(create.waitForExistence(timeout: 20))
        XCTAssertEqual(create.label, "Create 3 Selected Folders")
        shot(app, "workspace-setup-first-launch-820")
        create.click()
        XCTAssertTrue(app.staticTexts["workspaceSetup.result"].waitForExistence(timeout: 10))
        for name in ["Projects", "Ideas", "To Do"] { XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(name).path)) }
        app.buttons["workspaceSetup.done"].click()
        app.terminate(); XCTAssertTrue(app.wait(for: .notRunning, timeout: 10)); app.launch(); app.activate()
        XCTAssertTrue(app.buttons["workspace.setup"].waitForExistence(timeout: 20))
        XCTAssertFalse(app.buttons["workspaceSetup.create"].exists)
    }
}
