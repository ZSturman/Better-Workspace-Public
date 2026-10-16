import XCTest

/// The app itself refuses real data during a test, even when a test forgets to say
/// where the fixtures are. Launch arguments are how a test points somewhere; their
/// absence must never mean "use the person's Workspace and iCloud inbox".
final class TestIsolationUITests: IsolatedUITestCase {

    func testALaunchWithNoRootsGetsAnEmptySandboxNotTheRealWorkspace() throws {
        let app = XCUIApplication()
        if app.state != .notRunning {
            app.terminate()
            _ = app.wait(for: .notRunning, timeout: 10)
        }
        // Only the database switch — no -workspaceRootPath, no -ingestRootPath.
        app.launchArguments = ["-bwWindowWidth", "1100", "-bwWindowHeight", "760"]
        // A bare directory of its own: beside `fixtureRoot`'s database sits the seeded
        // fixture Workspace, which would hide exactly the fallback being tested.
        let bare = Self.fixtureRoot.appendingPathComponent("bare", isDirectory: true)
        try FileManager.default.createDirectory(at: bare, withIntermediateDirectories: true)
        app.launchEnvironment["BW_TEST_DATABASE_PATH"] = bare.appendingPathComponent("test.sqlite").path
        app.launch()
        requireWindow(app)

        // The sandbox Workspace is empty, so no area is discovered. The real one has
        // Projects; if it were used, this row would appear.
        XCTAssertTrue(app.descendants(matching: .any)["sidebar.ingest"].firstMatch.waitForExistence(timeout: 20))
        Thread.sleep(forTimeInterval: 3)
        XCTAssertFalse(app.descendants(matching: .any)["sidebar.folder.Projects"].firstMatch.exists,
                       "A test launch without roots must not read the real ~/Workspace")

        // And the fallbacks were made beside the test database, not anywhere real.
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: bare.appendingPathComponent("Workspace").path,
                                                     isDirectory: &isDirectory) && isDirectory.boolValue)
        XCTAssertTrue(FileManager.default.fileExists(atPath: bare.appendingPathComponent("Inbox").path))
        add(XCTAttachment(screenshot: app.windows.firstMatch.screenshot()))
    }
}
