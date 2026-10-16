import XCTest

final class WidgetNavigationUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }
    private func launch(_ route: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-mobileCloudDisabled", "YES", "-BWTestMobilePlanning", "YES", "-BWResetPlanningFixture", "YES",
            "-BWTestCaptureInboxID", "widget-navigation-" + UUID().uuidString, "-BWInitialURL", "betterworkspace-mobile://" + route]
        app.launch(); return app
    }
    func testMissingPinnedProjectExplainsInsteadOfSelectingAnother() {
        let app = launch("widget-project?id=missing")
        XCTAssertTrue(app.staticTexts["Record unavailable"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["This pinned project is no longer available."].exists)
    }
    func testTaskLinkOpensExactWorkItem() {
        let app = launch("task?id=test-work")
        XCTAssertTrue(app.staticTexts["Sketch the next screen"].firstMatch.waitForExistence(timeout: 15))
        XCTAssertTrue(app.descendants(matching: .any)["work-body"].firstMatch.waitForExistence(timeout: 10))
    }
    func testReviewLinkKeepsMissingItemIdentity() {
        let app = launch("review?id=missing-review")
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "This review item changed")).firstMatch.waitForExistence(timeout: 15))
        XCTAssertFalse(app.staticTexts["Review the next screen.md"].exists)
    }
}
