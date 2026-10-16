import XCTest
import AppKit

/// Explicit operator-only acceptance. Ordinary suites must never attach to real data.
/// Launch /Applications/Better Workspace.app in Projects → Charts, then set
/// BW_VERIFY_REAL_INSTALLATION=1 in this test's environment. No launch/termination,
/// presets, saves, remote writes or workspace mutations are performed here.
final class RealInstallationSmokeUITests: XCTestCase {
    func testRealDataInactivityCharts() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["BW_VERIFY_REAL_INSTALLATION"] == "1",
                          "Opt-in real-installation acceptance; use isolated fixtures by default")
        let installed = URL(fileURLWithPath: "/Applications/Better Workspace.app").standardizedFileURL
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: "com.zacharysturman.BetterWorkspace")
        try XCTSkipUnless(running.count == 1 && running.first?.bundleURL?.standardizedFileURL == installed,
                          "Exactly the installed app must already be running")
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.zacharysturman.BetterWorkspace")
        app.activate()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 30))
        let charts = app.descendants(matching: .any)["projects.charts"].firstMatch
        XCTAssertTrue(charts.waitForExistence(timeout: 30), "Open Projects → Charts before this acceptance test")
        let period = app.descendants(matching: .any)["projects.charts.period"].firstMatch
        let original = try XCTUnwrap(period.value as? String)
        defer {
            if (period.value as? String) != original {
                period.click(); app.menuItems[original].firstMatch.click()
            }
        }
        for days in ["7 days", "30 days", "90 days"] {
            period.click(); app.menuItems[days].firstMatch.click()
            XCTAssertEqual(period.value as? String, days)
            let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
            attachment.name = "installed-real-charts-" + days
            attachment.lifetime = .keepAlways; add(attachment)
        }
    }
}
