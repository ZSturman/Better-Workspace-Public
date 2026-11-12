import XCTest

/// Settings → Services → Agent completion monitor, from a canned monitor status. An
/// isolated run never starts the real monitor (`AgentMonitorSupervisor`).
final class AgentMonitorUITests: XCTestCase {
    func testSettingsShowsStatusModelAgentsAndActivityAtMinimumSize() throws {
        continueAfterFailure = false
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bw-agent-monitor-ui-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let status: [String: Any] = [
            "heartbeat": Date().timeIntervalSince1970 + 3600, "phase": "watching", "mode": "apply", "pendingJobs": 0,
            "lmstudio": ["available": true, "model": "qwen/qwen3.5-9b"],
            "agents": [["name": "codex", "displayName": "Codex", "available": true, "sessionsLastDay": 3],
                       ["name": "claude", "displayName": "Claude Code", "available": true, "sessionsLastDay": 1],
                       ["name": "copilot", "displayName": "GitHub Copilot", "available": true, "sessionsLastDay": 0],
                       ["name": "antigravity", "displayName": "Antigravity", "available": false, "sessionsLastDay": 0]],
            "recent": [["at": "2026-10-26T05:00:00-07:00", "agent": "codex", "project": "Better Workspace", "job": "j1",
                        "new": 1, "completed": 1, "next": ["title": "Manually verify corner-drag resize", "ownerLabel": "Me"]],
                       ["at": "2026-10-26T04:00:00-07:00", "agent": "claude", "project": "Home Services", "job": "j2",
                        "reason": "no meaningful work (no file changes, summary or next steps)"]],
            "errors": [], "deferredCount": 2, "logPath": root.appendingPathComponent("monitor.log").path,
        ]
        let statusFile = root.appendingPathComponent("status.json")
        try JSONSerialization.data(withJSONObject: status).write(to: statusFile)

        let app = XCUIApplication()
        app.launchEnvironment["BW_TEST_DATABASE_PATH"] = root.appendingPathComponent("tags.sqlite").path
        app.launchArguments = ["-bwOpenSettings", "YES", "-mobileCloudDisabled", "YES", "-agentMonitorEnabled", "YES",
                               "-bwAgentMonitorStatus", statusFile.path, "-bwWindowWidth", "820", "-bwWindowHeight", "520"]
        app.launch()
        defer { app.terminate() }
        let services = app.buttons["Services"].firstMatch
        XCTAssertTrue(services.waitForExistence(timeout: 20)); services.click()
        // A grouped-form Toggle is a Switch on macOS.
        let toggle = app.switches["settings.agentMonitor.enabled"].firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 10))
        XCTAssertEqual(toggle.value as? Int, 1)
        func shows(_ text: String) -> Bool {
            app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", text, text)).firstMatch.exists
        }
        XCTAssertEqual(app.staticTexts["settings.agentMonitor.status"].value as? String, "Watching")
        XCTAssertTrue(shows("Available · qwen/qwen3.5-9b"))
        XCTAssertTrue(shows("Claude Code"))
        let recent = app.buttons.matching(identifier: "settings.agentMonitor.recent")
        XCTAssertEqual(recent.count, 2)
        XCTAssertTrue(recent.element(boundBy: 0).label.contains("next: Manually verify corner-drag resize"))
        let form = app.scrollViews.firstMatch
        for _ in 0..<4 where !recent.element(boundBy: 0).isHittable { form.scroll(byDeltaX: 0, deltaY: -200) }
        let capture = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        capture.name = "agent-monitor-settings"; capture.lifetime = .keepAlways; add(capture)
    }
}
