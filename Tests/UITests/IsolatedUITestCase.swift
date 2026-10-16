import XCTest
import AppKit
import BetterWorkspaceCore

/// The runner owns this root, so it can seed and remove it despite its sandbox.
/// The unsandboxed Mac app receives explicit paths and never touches the user's data.
class IsolatedUITestCase: XCTestCase {
    static var fixtureRoot: URL!
    static var workspaceRoot: URL { fixtureRoot.appendingPathComponent("Workspace") }
    static var inboxRoot: URL { fixtureRoot.appendingPathComponent("Inbox") }

    /// The person's real Workspace. The runner is sandboxed, so its own home directory
    /// is a container; this is the actual one.
    static var realWorkspace: URL {
        let home = getpwuid(getuid()).flatMap { String(validatingCString: $0.pointee.pw_dir) } ?? NSHomeDirectory()
        return URL(fileURLWithPath: home).appendingPathComponent("Workspace")
    }

    /// Names at the real Workspace root and one level into each area.
    ///
    /// A tripwire, not the protection: the app refuses real data during a test on its
    /// own (`TestIsolation`). This catches whatever that misses — the way
    /// `UITest Idea 43981.md` once landed in the real Ideas and went unnoticed.
    static func realWorkspaceSnapshot() -> [String: [String]] {
        let fm = FileManager.default
        var snapshot: [String: [String]] = [:]
        guard let top = try? fm.contentsOfDirectory(atPath: realWorkspace.path) else { return snapshot }
        snapshot[""] = top.sorted()
        for name in top where name.hasPrefix(".") == false {
            if let inside = try? fm.contentsOfDirectory(atPath: realWorkspace.appendingPathComponent(name).path) {
                snapshot[name] = inside.sorted()
            }
        }
        return snapshot
    }

    private var realWorkspaceBefore: [String: [String]] = [:]

    override func setUpWithError() throws {
        continueAfterFailure = false
        Self.terminateStrayInstances()
        realWorkspaceBefore = Self.realWorkspaceSnapshot()
        Self.fixtureRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bw-ui-\(UUID().uuidString)")
        // The real Workspace's root folders, as of the survey in DESIGN.md §2 — purpose-
        // built and configured alike — so the fixture exercises both layers.
        for name in Self.fixtureAreaNames {
            try FileManager.default.createDirectory(at: Self.workspaceRoot.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        try FileManager.default.createDirectory(at: Self.inboxRoot, withIntermediateDirectories: true)
        try "# Fixture idea\nA note for inspector validation.".write(to: Self.workspaceRoot.appendingPathComponent("Ideas/Fixture idea.md"), atomically: true, encoding: .utf8)
        for path in ["Projects/Fixture project/README.md", "For Reference/Fixture reference.md",
                     "To Organize/Old note.txt", "Review/Review note.md", "Assets/Fixture collection/Fixture asset.txt",
                     "Backups/Fixture backup.txt", "Logs/2026-09-28/session.log", "Logs/2026-09-27/session.log"] {
            let url = Self.workspaceRoot.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try ("# Fixture content\n" + String(repeating: "Long readable log line · ", count: 25)).write(to: url, atomically: true, encoding: .utf8)
        }
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_600_000_000)],
            ofItemAtPath: Self.workspaceRoot.appendingPathComponent("To Organize/Old note.txt").path)
        let image = NSImage(size: NSSize(width: 480, height: 240))
        image.lockFocus()
        NSColor.systemBlue.setFill()
        NSRect(x: 0, y: 0, width: 480, height: 240).fill()
        NSColor.systemOrange.setFill()
        NSRect(x: 0, y: 0, width: 100, height: 240).fill()
        image.unlockFocus()
        let data = NSBitmapImageRep(data: image.tiffRepresentation!)!.representation(using: .png, properties: [:])!
        for path in ["For Reference/Wide reference.png", "For Inspiration/Wide inspiration.png"] {
            try data.write(to: Self.workspaceRoot.appendingPathComponent(path))
        }
        let project = Self.inboxRoot.appendingPathComponent("Drop Project")
        try FileManager.default.createDirectory(at: project.appendingPathComponent("src"), withIntermediateDirectories: true)
        try "# Drop Project".write(to: project.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try "print('fixture')".write(to: project.appendingPathComponent("src/main.py"), atomically: true, encoding: .utf8)
    }

    static let fixtureAreaNames = [
        "Analytics", "Assets", "Backups", "Calendar", "Features", "For Inspiration", "For Reference",
        "Ideas", "Logs", "Milestones", "Overview", "Projects", "Review", "Social Posts", "Study",
        "To Do", "To Look Up", "To Organize", "To Read", "To Refactor", "To Watch",
    ]

    func isolatedApp(arguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        // This app keeps a MenuBarExtra and returns false from
        // `applicationShouldTerminateAfterLastWindowClosed`, so an earlier instance can
        // still be alive with no window. Launching then adopts that windowless process
        // and every query fails with "element not found" rather than the truth.
        // `terminate()` is asynchronous. Starting the next test before this has
        // finished makes XCUITest attach to precisely that dying, windowless process.
        // This was intermittent in a full suite and produced misleading UI failures.
        if app.state != .notRunning {
            app.terminate()
            _ = app.wait(for: .notRunning, timeout: 10)
        }
        app.launchArguments = ["-workspaceRootPath", Self.workspaceRoot.path,
                               "-ingestRootPath", Self.inboxRoot.path,
                               "-bwWindowWidth", "1400", "-bwWindowHeight", "900"] + arguments
        app.launchEnvironment["BW_TEST_DATABASE_PATH"] = Self.fixtureRoot.appendingPathComponent("test.sqlite").path
        return app
    }

    /// Waits for the app to become frontmost, asking once more if activation is lost.
    ///
    /// Activation can be taken straight back after launch: with another app on its own
    /// Space, WindowServer's Space switch made that app frontmost again ~20 ms after this
    /// one (system log, 2026-10-05), and the launch then failed 30 s later on a check
    /// the app never had a chance at. That is the machine, not the app.
    @discardableResult
    func requireForeground(_ app: XCUIApplication) -> Bool {
        if app.wait(for: .runningForeground, timeout: 10) == false { app.activate() }
        let foreground = app.wait(for: .runningForeground, timeout: 20)
        XCTAssertTrue(foreground, "The app never became the frontmost app")
        return foreground
    }

    /// Waits for a real window, and says so when there isn't one.
    ///
    /// A windowless app reports every element as missing, which reads like a UI
    /// regression and is not one. Check this before anything else.
    @discardableResult
    func requireWindow(_ app: XCUIApplication, timeout: TimeInterval = 30) -> Bool {
        let appeared = app.windows.firstMatch.waitForExistence(timeout: timeout)
        XCTAssertTrue(appeared, "The app launched but never opened a window — nothing below this can pass")
        return appeared
    }

    /// The sidebar rows the app actually discovered, in the order it shows them.
    ///
    /// Areas are no longer a fixed list of nine: the sidebar is built from whatever
    /// top-level folders exist. A test that hardcodes nine names asserts the old model.
    func discoveredFolderNames() -> [String] {
        (try? FileManager.default.contentsOfDirectory(
            at: Self.workspaceRoot, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        ))?
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .map(\.lastPathComponent)
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending } ?? []
    }

    /// What identifies an area once it is open: its header title, except in Projects.
    ///
    /// The Projects browser (since the project graph workspace) puts search, sync and
    /// the Table/Cards/Decide picker where other areas show an `AreaHeader`, so there
    /// is no "Projects" title to find. Its presentation picker is the header there.
    func areaHeader(_ app: XCUIApplication, _ name: String) -> XCUIElement {
        if name == "Projects" {
            return app.descendants(matching: .any)["projects.presentation"].firstMatch
        }
        return app.staticTexts[name].firstMatch
    }

    /// Columns of multi-column SwiftUI `Table`s on screen.
    ///
    /// On this macOS a `Table` is exposed with the `Outline` role, exactly like a
    /// `List`, so `app.tables` is always empty — asserting on it passes or fails
    /// regardless of the UI. What tells a real table apart is its columns: a `List` has
    /// one, identified `ListColumn`; a `Table` has one per `TableColumn`, with a header.
    func tableColumns(_ app: XCUIApplication) -> XCUIElementQuery {
        app.descendants(matching: .tableColumn).matching(NSPredicate(format: "identifier != 'ListColumn'"))
    }

    /// A sidebar row, scrolled into view first.
    ///
    /// At the smallest window the sidebar scrolls, and it only renders the rows in
    /// view: a row scrolled away still "exists" but has an empty frame and cannot be
    /// clicked. XCUITest does not scroll it into view by itself, so this does what a
    /// person would — scroll toward it until it can be clicked.
    @discardableResult
    func revealSidebarRow(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        let row = app.descendants(matching: .any)[identifier].firstMatch
        let sidebar = app.outlines["Sidebar"].firstMatch
        guard row.waitForExistence(timeout: 15), sidebar.exists else { return row }
        // Positive deltas move toward the top on macOS. Most requested folders
        // are below the initial viewport; do not spend twelve slow hit tests at
        // the top before ever trying to reveal them.
        for direction in [CGFloat(-1), 1] {
            var attempts = 0
            while row.isHittable == false && attempts < 5 {
                sidebar.scroll(byDeltaX: 0, deltaY: 240 * direction)
                attempts += 1
            }
            if row.isHittable { break }
        }
        return row
    }

    /// Opens the ingest inbox.
    ///
    /// The app lands on Overview now, so anything that drives capture has to navigate
    /// there first — the capture field is not on screen at launch any more.
    func openIngest(_ app: XCUIApplication) {
        if app.buttons["ingest.newCapture"].firstMatch.exists { return }
        let row = app.descendants(matching: .any)["sidebar.ingest"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 20), "The Ingest sidebar row is unreachable")
        row.click()
        // Callers click into Ingest straight away; wait for it rather than race it.
        XCTAssertTrue(app.buttons["ingest.newCapture"].firstMatch.waitForExistence(timeout: 20), "Ingest never opened")
    }

    /// A button in an open/save panel, avoiding the Touch Bar copy of it.
    ///
    /// macOS mirrors a panel's default button onto the Touch Bar, and a plain
    /// `app.buttons[title]` can resolve to that mirror — which XCUITest then refuses
    /// to click. The panel itself is not under `app.windows`, so this looks where it
    /// actually lives and falls back to filtering by position.
    func panelButton(_ app: XCUIApplication, _ title: String) -> XCUIElement? {
        for scope in [app.dialogs, app.sheets, app.windows] {
            let candidate = scope.buttons[title].firstMatch
            if candidate.waitForExistence(timeout: 5) { return candidate }
        }
        // Last resort: anything with that title that is not sitting in the Touch Bar
        // strip along the very top of the screen.
        return app.descendants(matching: .button)
            .matching(identifier: title)
            .allElementsBoundByIndex
            .first { $0.exists && $0.frame.minY > 40 && $0.frame.height > 0 }
    }

    /// Instances of the test build that a test started without tracking them.
    /// `XCUIApplication.open(_:)` launches one per link, and `terminate()` ends only the
    /// instance it launched; the rest lived on for minutes and answered the next test's
    /// activation in place of its own app -- a window on another test's fixture, no
    /// inspection panel. Only this build is touched, never an installed copy.
    static func terminateStrayInstances() {
        let build = Bundle.main.bundleURL.deletingLastPathComponent()
            .appendingPathComponent("BetterWorkspace.app").standardizedFileURL
        let strays = NSRunningApplication.runningApplications(withBundleIdentifier: "com.zacharysturman.BetterWorkspace")
            .filter { $0.bundleURL?.standardizedFileURL == build }
        guard strays.isEmpty == false else { return }
        strays.forEach { $0.forceTerminate() }
        let deadline = Date().addingTimeInterval(10)
        while strays.contains(where: { $0.isTerminated == false }), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
    }

    override func tearDownWithError() throws {
        let app = XCUIApplication()
        if app.state != .notRunning {
            app.terminate()
            _ = app.wait(for: .notRunning, timeout: 10)
        }
        Self.terminateStrayInstances()
        if let root = Self.fixtureRoot { try FileManager.default.removeItem(at: root) }
        Self.fixtureRoot = nil

        let after = Self.realWorkspaceSnapshot()
        if after != realWorkspaceBefore {
            let changed = Set(after.keys).union(realWorkspaceBefore.keys)
                .filter { after[$0] != realWorkspaceBefore[$0] }
                .map { key -> String in
                    let added = Set(after[key] ?? []).subtracting(realWorkspaceBefore[key] ?? [])
                    let removed = Set(realWorkspaceBefore[key] ?? []).subtracting(after[key] ?? [])
                    return "\(key.isEmpty ? "(root)" : key): +\(added.sorted()) -\(removed.sorted())"
                }
            // Something outside the test may have changed it too (a sync, the person
            // working); the message says what, so it can be told apart from a leak.
            XCTFail("The real ~/Workspace changed during this test: \(changed.sorted().joined(separator: "; "))")
        }
    }
}
