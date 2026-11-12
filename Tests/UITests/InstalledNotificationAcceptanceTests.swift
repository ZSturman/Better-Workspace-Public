import XCTest

/// Release acceptance against the installed /Applications app, not a test copy: a real Agent
/// Monitor notification is clicked in Notification Center and the app must open that project's
/// Tasks. Opt in with `TEST_RUNNER_BW_NOTIFICATION_MARKER=<text>`; the driver posts the
/// notification (through the monitor's outbox, which this sandboxed runner cannot write) once
/// the test prints `BWNC-READY`, with `<text>` in its subtitle. Reads the app; changes nothing.
final class InstalledNotificationAcceptanceTests: XCTestCase {
    func testClickingAMonitorNotificationOpensTheProjectTasks() throws {
        let marker = try XCTUnwrap(ProcessInfo.processInfo.environment["BW_NOTIFICATION_MARKER"].flatMap { $0.isEmpty ? nil : $0 },
                                   "Set TEST_RUNNER_BW_NOTIFICATION_MARKER")
        let project = ProcessInfo.processInfo.environment["BW_NOTIFICATION_PROJECT"] ?? "Better Workspace"
        // Attach to the running installed copy by its location; a bundle identifier resolves
        // to this test's own build. Never launch it here.
        let app = XCUIApplication(url: URL(fileURLWithPath: "/Applications/BetterWorkspace.app"))
        XCTAssertTrue(app.state == .runningForeground || app.state == .runningBackground, "The installed app is not running")
        // A known starting state: no window open, so the click must open one.
        for window in app.windows.allElementsBoundByIndex {
            let close = window.buttons[XCUIIdentifierCloseWindow]
            if close.exists { close.click() }
        }
        XCTAssertEqual(app.windows.count, 0, "Could not start from a closed window")
        print("BWNC-READY")

        let center = XCUIApplication(bundleIdentifier: "com.apple.notificationcenterui")
        let banner = center.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@ OR title CONTAINS %@", marker, marker, marker)).firstMatch
        XCTAssertTrue(banner.waitForExistence(timeout: 60), "The notification never appeared in Notification Center")
        // Evidence is the accessibility tree: the runner has no Screen Recording permission.
        let before = XCTAttachment(string: banner.debugDescription); before.name = "banner"; before.lifetime = .keepAlways; add(before)
        print("BWNC-BANNER \(banner.elementType.rawValue) \(banner.frame)")
        banner.click()

        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 15), "Clicking did not open a window")
        let tasks = app.radioButtons["Tasks"].firstMatch
        let selected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == 1"), object: tasks)
        XCTAssertEqual(XCTWaiter.wait(for: [selected], timeout: 15), .completed, "The Tasks section is not selected")
        let title = app.staticTexts.matching(NSPredicate(format: "value == %@ OR label == %@", project, project)).firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 10), "The window does not show \(project)")
        let after = XCTAttachment(string: window.debugDescription); after.name = "opened"; after.lifetime = .keepAlways; add(after)
        print("BWNC-OPENED window=\(window.title) tasksSelected=\(tasks.value ?? "") project=\(project)")
    }
}
