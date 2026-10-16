import XCTest

final class PrivacySupportUITests: XCTestCase {
    func testOfflinePrivacyIsReachableFromOverview() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-mobileCloudDisabled", "YES", "-BWTestMobilePlanning", "YES",
                               "-BWInitialURL", "betterworkspace-mobile://overview"]
        app.launch()
        let menu = app.buttons["More workspace views"]
        XCTAssertTrue(menu.waitForExistence(timeout: 20)); menu.tap()
        app.buttons["Privacy & Support"].tap()
        XCTAssertTrue(app.navigationBars["Privacy & Support"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Your workspace"].exists)
        let capture = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        capture.name = "iphone-offline-privacy"; capture.lifetime = .keepAlways; add(capture)
        app.terminate()
    }
}
