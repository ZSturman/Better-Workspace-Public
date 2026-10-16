import XCTest

final class PrivacySupportUITests: XCTestCase {
    func testOfflinePrivacyInSettings() throws {
        continueAfterFailure = false
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bw-privacy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = XCUIApplication()
        app.launchEnvironment["BW_TEST_DATABASE_PATH"] = root.appendingPathComponent("tags.sqlite").path
        app.launchArguments = ["-bwOpenSettings", "YES", "-mobileCloudDisabled", "YES",
                               "-bwWindowWidth", "820", "-bwWindowHeight", "520"]
        app.launch()
        defer { app.terminate() }
        let privacy = app.buttons["Privacy"].firstMatch
        XCTAssertTrue(privacy.waitForExistence(timeout: 20)); privacy.click()
        XCTAssertTrue(app.staticTexts["Your workspace"].waitForExistence(timeout: 10))
        app.activate()
        privacy.click()
        let capture = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        capture.name = "mac-offline-privacy"; capture.lifetime = .keepAlways; add(capture)
    }
}
