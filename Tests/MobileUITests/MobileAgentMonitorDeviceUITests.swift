import XCTest

/// Real-data checks on a physical iPhone/iPad for tasks the Agent Completion Monitor wrote
/// on the Mac. Opt in: `TEST_RUNNER_BW_DEVICE_REAL_DATA=1`, with the task title in
/// `TEST_RUNNER_BW_MONITOR_TASK`. Read-only unless `TEST_RUNNER_BW_COMPLETE_TASK` names a
/// task to mark completed (a disposable smoke-test task), which exercises device → Mac sync.
final class MobileAgentMonitorDeviceUITests: XCTestCase {
    private var environment: [String: String] { ProcessInfo.processInfo.environment }

    override func setUpWithError() throws {
        continueAfterFailure = false
        try XCTSkipUnless(environment["BW_DEVICE_REAL_DATA"] == "1", "Opt in with TEST_RUNNER_BW_DEVICE_REAL_DATA=1 on a device.")
    }

    private func openWorkspace(_ app: XCUIApplication) {
        let search = app.textFields["unified.search"]
        if search.exists { return }
        // A Connected Apps request sheet opens over the app at launch (and, once expired,
        // keeps doing so until another request arrives). Done only closes it.
        if app.navigationBars["Connected Apps"].exists { app.navigationBars["Connected Apps"].buttons["Done"].tap() }
        app.workspaceDestination("Workspace").tap()
        XCTAssertTrue(search.waitForExistence(timeout: 20))
    }

    /// The row for `title`, relaunching while the Mac's publication arrives (up to 4 min).
    private func row(_ title: String, in app: XCUIApplication) -> XCUIElement {
        let match = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'unified.item.' AND label CONTAINS %@", title)).firstMatch
        for attempt in 0..<8 {
            search(title, in: app)
            if match.waitForExistence(timeout: 20) { return match }
            if attempt < 7 { synchronize(app) }
        }
        return match
    }

    /// Types `text` into the Workspace search, clearing what was there first.
    private func search(_ text: String, in app: XCUIApplication) {
        openWorkspace(app)
        let search = app.textFields["unified.search"]
        // Submitting dismisses the keyboard; a tap during that animation is lost. Tap at
        // the end of the text and clear until the field is really empty: a partial clear
        // searches for nonsense.
        for _ in 0..<6 {
            search.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.5)).tap()
            guard app.keyboards.firstMatch.waitForExistence(timeout: 3) else { continue }
            let current = (search.value as? String) ?? ""
            if current.isEmpty || current == "Find in your workspace" { break }
            search.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count + 4))
        }
        search.typeText(text + "\n")
    }

    /// The app's own "Synchronize now", then the status it reports.
    private func synchronize(_ app: XCUIApplication) {
        openWorkspace(app)
        app.buttons["unified.connections"].tap()
        let now = app.buttons["Synchronize now"].firstMatch
        if now.waitForExistence(timeout: 10) { now.tap() }
        sleep(15)
        let status = XCTAttachment(string: app.staticTexts.allElementsBoundByIndex.prefix(12).map(\.label).joined(separator: "\n"))
        status.name = "sync-status"; status.lifetime = .keepAlways; add(status)
        if app.buttons["Done"].exists { app.buttons["Done"].tap() }
    }

    private func capture(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name; shot.lifetime = .keepAlways; add(shot)
    }

    func testMonitorTaskShowsOwnershipAndSurvivesBackgroundAndRelaunch() throws {
        let title = try XCTUnwrap(environment["BW_MONITOR_TASK"], "Set TEST_RUNNER_BW_MONITOR_TASK")
        let app = XCUIApplication()
        app.launch()
        defer { app.terminate() }

        let task = row(title, in: app)
        XCTAssertTrue(task.exists, "“\(title)” never arrived from the Mac")
        XCTAssertTrue(task.label.contains("For Me") || task.label.contains("For Agent") || task.label.contains("For Either"),
                      "Row shows no responsibility: \(task.label)")
        capture("workspace-row")
        task.tap()
        let owner = app.descendants(matching: .any)["unified.editor.responsibility"]
        XCTAssertTrue(owner.waitForExistence(timeout: 10))
        capture("workspace-editor")
        app.buttons["Cancel"].firstMatch.tap()

        // Background and return, then a full relaunch: the item is still there.
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 10) || app.wait(for: .runningBackgroundSuspended, timeout: 10))
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        XCTAssertTrue(task.waitForExistence(timeout: 15), "Lost the list after returning from the background")
        app.terminate()
        app.launch()
        XCTAssertTrue(row(title, in: app).exists, "Lost the item after relaunch")
        capture("after-relaunch")
    }

    func testCompleteSmokeTaskOnDevice() throws {
        let title = try XCTUnwrap(environment["BW_COMPLETE_TASK"].flatMap { $0.isEmpty ? nil : $0 },
                                  "Set TEST_RUNNER_BW_COMPLETE_TASK to a disposable task title")
        let app = XCUIApplication()
        app.launch()
        defer { app.terminate() }
        let task = row(title, in: app)
        XCTAssertTrue(task.exists)
        guard !task.label.contains("Completed") else { capture("already-completed"); return }
        task.tap()
        let completed = app.switches["Completed"].firstMatch
        XCTAssertTrue(completed.waitForExistence(timeout: 10))
        if completed.value as? String != "1" { completed.switches.firstMatch.exists ? completed.switches.firstMatch.tap() : completed.tap() }
        app.buttons["unified.editor.save"].tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS %@ AND label CONTAINS 'Completed'", title))
            .firstMatch.waitForExistence(timeout: 20))
        capture("completed-on-device")
        // Leave as a person would: the edit must still be sent from the background.
        XCUIDevice.shared.press(.home)
        sleep(20)
    }

    func testTaskIsCompletedHere() throws {
        let title = try XCTUnwrap(environment["BW_EXPECT_COMPLETED"].flatMap { $0.isEmpty ? nil : $0 },
                                  "Set TEST_RUNNER_BW_EXPECT_COMPLETED")
        let app = XCUIApplication()
        app.launch()
        defer { app.terminate() }
        let completed = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'unified.item.' AND label CONTAINS %@ AND label CONTAINS 'Completed'", title)).firstMatch
        for attempt in 0..<8 {
            if row(title, in: app).exists, completed.waitForExistence(timeout: 20) { break }
            if attempt < 7 { app.terminate(); app.launch() }
        }
        XCTAssertTrue(completed.exists, "This device never showed “\(title)” as completed")
        capture("completed-elsewhere")
    }

    /// Read-only: what this device shows for real data — Workspace, its connection, and Planning.
    func testInspectRealDataSurfaces() throws {
        let app = XCUIApplication()
        app.launch()
        defer { app.terminate() }
        openWorkspace(app)
        let search = app.textFields["unified.search"]
        if let current = search.value as? String, !current.isEmpty, current != "Find in your workspace" {
            search.tap(); search.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count) + "\n")
        }
        capture("workspace-all")
        let hierarchy = XCTAttachment(string: app.debugDescription); hierarchy.name = "workspace-hierarchy"; hierarchy.lifetime = .keepAlways; add(hierarchy)
        app.buttons["unified.connections"].tap()
        sleep(2)
        capture("connections")
        let connections = XCTAttachment(string: app.debugDescription); connections.name = "connections-hierarchy"; connections.lifetime = .keepAlways; add(connections)
        if app.buttons["Done"].exists { app.buttons["Done"].tap() } else if app.buttons["Close"].exists { app.buttons["Close"].tap() }
        app.workspaceDestination("Planning").tap()
        if app.segmentedControls["workspace.planningView"].buttons["Projects"].waitForExistence(timeout: 10) {
            app.segmentedControls["workspace.planningView"].buttons["Projects"].tap()
        }
        let smoke = app.buttons["mobile-project-Projects/Agent Monitor Smoke Test"]
        for _ in 0..<12 where !smoke.exists { app.swipeUp() }
        capture("planning-projects")
        if smoke.exists {
            smoke.tap()
            sleep(2)
            capture("planning-smoke-project")
            let detail = XCTAttachment(string: app.debugDescription); detail.name = "smoke-project-hierarchy"; detail.lifetime = .keepAlways; add(detail)
        }
        XCTAssertTrue(smoke.exists, "The smoke project is not in Planning")
    }

    /// Read-only expectations about real data, re-synchronizing while the Mac's changes
    /// arrive. `TEST_RUNNER_BW_EXPECT` is `;`-separated `once:Kind:Title`,
    /// `absent:Kind:Title`, `parent:Kind:Title:Parent title` or `completed:Kind:Title`
    /// (Kind as the row shows it: Project, Task, Idea, Folder, Note).
    func testExpectedWorkspaceState() throws {
        let spec = try XCTUnwrap(environment["BW_EXPECT"].flatMap { $0.isEmpty ? nil : $0 }, "Set TEST_RUNNER_BW_EXPECT")
        let checks = spec.split(separator: ";").map { $0.split(separator: ":", maxSplits: 3).map { String($0).trimmingCharacters(in: .whitespaces) } }
        let app = XCUIApplication()
        app.launch()
        defer { app.terminate() }

        func rows(_ kind: String, _ title: String) -> [XCUIElement] {
            search(title, in: app)
            // Equal titles are shown with a device suffix ("Better Signals-Mac-2").
            let pattern = "^" + NSRegularExpression.escapedPattern(for: title) + "(-[A-Za-z]+(-[0-9]+)?)?, " + NSRegularExpression.escapedPattern(for: kind) + "\\b.*"
            let query = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'unified.item.' AND label MATCHES %@", pattern))
            _ = query.firstMatch.waitForExistence(timeout: 5)
            let found = query.allElementsBoundByIndex
            let listed = XCTAttachment(string: title + "\n" + found.map(\.label).joined(separator: "\n"))
            listed.name = "rows-" + kind + "-" + title; listed.lifetime = .keepAlways; add(listed)
            return found
        }
        func failures() -> [String] {
            checks.compactMap { check in
                guard check.count >= 3 else { return "Malformed check \(check)" }
                let found = rows(check[1], check[2])
                switch check[0] {
                case "once": return found.count == 1 ? nil : "\(check[1]) “\(check[2])” appears \(found.count) times"
                case "absent": return found.isEmpty ? nil : "\(check[1]) “\(check[2])” is still shown"
                case "completed": return found.count == 1 && found[0].label.contains("Completed") ? nil : "\(check[1]) “\(check[2])” is not shown completed"
                case "parent":
                    guard check.count == 4 else { return "Malformed check \(check)" }
                    return found.count == 1 && found[0].label.contains("· " + check[3]) ? nil : "\(check[1]) “\(check[2])” is not under “\(check[3])”: \(found.map(\.label))"
                default: return "Unknown check \(check[0])"
                }
            }
        }
        var remaining = failures()
        for _ in 0..<8 where !remaining.isEmpty {
            synchronize(app)
            remaining = failures()
        }
        let report = XCTAttachment(string: (remaining.isEmpty ? ["All expectations met"] : remaining).joined(separator: "\n"))
        report.name = "expectations"; report.lifetime = .keepAlways; add(report)
        capture("expectations")
        XCTAssertTrue(remaining.isEmpty, remaining.joined(separator: "\n"))
    }

    /// Leaving and returning while synchronization runs, the way app switching does. Two
    /// real kills for holding a shared-container file lock while suspended (0xdead10cc)
    /// happened like this on October 27. The device's crash logs are checked separately.
    func testAppSwitchingDuringSynchronizationKeepsTheAppAlive() throws {
        let app = XCUIApplication()
        app.launch()
        defer { app.terminate() }
        openWorkspace(app)
        for round in 0..<12 {
            app.buttons["unified.connections"].tap()
            let now = app.buttons["Synchronize now"].firstMatch
            if now.waitForExistence(timeout: 10) { now.tap() }
            usleep(useconds_t(200_000 + 150_000 * (round % 4)))
            XCUIDevice.shared.press(.home)
            // Leaving can take a moment while a sheet animates away; wait for it, then
            // stay away. Not running here means it was killed: activate would relaunch it.
            XCTAssertTrue(app.wait(for: .runningBackground, timeout: 5) || app.wait(for: .runningBackgroundSuspended, timeout: 5),
                          "Round \(round): the app never left the foreground (state \(app.state.rawValue))")
            sleep(UInt32(2 + round % 3))
            XCTAssertTrue([XCUIApplication.State.runningBackground, .runningBackgroundSuspended].contains(app.state),
                          "Round \(round): the app exited while backgrounded; activate must not hide a relaunch (state \(app.state.rawValue))")
            app.activate()
            XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15), "Round \(round): the app did not come back")
            if app.buttons["Done"].exists { app.buttons["Done"].tap() }
        }
        XCTAssertTrue(app.state == .runningForeground)
        openWorkspace(app)
    }

    /// Upload and receive now, as a person would after editing offline.
    func testSynchronizeNow() throws {
        let app = XCUIApplication()
        app.launch()
        defer { app.terminate() }
        synchronize(app)
        synchronize(app)
    }
}
