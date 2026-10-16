import XCTest

/// Analytics used to be an ordinary configurable folder. It now remains a native,
/// folder-driven dashboard even when an existing install saved `list`.
final class AnalyticsAreaUITests: IsolatedUITestCase {
    private var settingsFile: URL { Self.fixtureRoot.appendingPathComponent("Areas.json") }

    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    func testAnalyticsOverridesALegacyListPreferenceAndShowsDataSourceFolders() throws {
        try """
        {"version":1,"areas":{"Analytics":{"configuration":{"layout":"list"}}}}
        """.write(to: settingsFile, atomically: true, encoding: .utf8)
        let source = Self.workspaceRoot.appendingPathComponent("Analytics/Website", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try "date,visits\n2026-10-01,42\n".write(to: source.appendingPathComponent("daily.csv"), atomically: true, encoding: .utf8)

        let app = isolatedApp(arguments: ["-bwStartArea", "Analytics"])
        app.launch()
        requireForeground(app)
        requireWindow(app)

        XCTAssertFalse(element(app, "area.layout").exists,
                       "Analytics must not revert to its old generic List presentation")
        XCTAssertTrue(element(app, "analytics.dataSources").waitForExistence(timeout: 15))
        XCTAssertFalse(element(app, "analytics.destination.zacharysturman").exists,
                       "The retired named dashboard must not be presented")
    }
}
