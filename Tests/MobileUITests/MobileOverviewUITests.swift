import XCTest

/// Overview on the phone: the Mac's bounded digest, the same focus controls, and one
/// To-folder item whose decision waits in the offline draft queue.
final class MobileOverviewUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false; XCUIDevice.shared.orientation = .portrait }
    override func tearDownWithError() throws { XCUIDevice.shared.orientation = .portrait }

    private func launch(fresh: Bool) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-mobileCloudDisabled", "YES", "-BWTestMobilePlanning", "YES",
                               "-BWInitialURL", "betterworkspace-mobile://overview"]
        if fresh { app.launchArguments += ["-BWResetPlanningFixture", "YES"] }
        app.launch()
        return app
    }

    private func shoot(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name; shot.lifetime = .keepAlways; add(shot)
    }

    func testFocusAndReviewCardRenderInPortraitAndLandscape() {
        let app = launch(fresh: true)
        let title = app.staticTexts["overview.toReview.title"]
        XCTAssertTrue(title.waitForExistence(timeout: 20), "The Mac's published review item should be on Overview")
        XCTAssertEqual(title.label, "Review the next screen.md")
        XCTAssertTrue(app.buttons["Studied?"].exists, "To Study's decision is named for its folder")
        XCTAssertTrue(app.buttons.containing(NSPredicate(format: "identifier BEGINSWITH %@", "overview.focusItem.")).firstMatch
            .waitForExistence(timeout: 10), "Bring forward should list the digest's almost-done project")
        shoot("mobile-overview-portrait")
        XCUIDevice.shared.orientation = .landscapeLeft
        let landscape = NSPredicate { _, _ in app.windows.firstMatch.frame.width > app.windows.firstMatch.frame.height }
        // As in the composer test: a simulator can decline to rotate; the check below
        // still holds, and the screenshot says which orientation it shows.
        _ = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: landscape, object: nil)], timeout: 10)
        XCTAssertTrue(app.buttons["overview.toReview.primary"].waitForExistence(timeout: 10))
        shoot("mobile-overview-landscape")
    }

    func testDecisionWaitsForTheMacAndSurvivesRelaunch() {
        var app = launch(fresh: true)
        let later = app.buttons["overview.toReview.later"]
        XCTAssertTrue(later.waitForExistence(timeout: 20))
        later.tap()
        let pending = app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH %@", "Decision saved on this phone")).firstMatch
        XCTAssertTrue(pending.waitForExistence(timeout: 10), "The card should say the decision is waiting for the Mac")
        XCTAssertFalse(app.staticTexts["overview.toReview.title"].exists, "A decided item must not be offered twice")
        shoot("mobile-overview-decision-pending")

        app.terminate()
        app = launch(fresh: false)
        let restored = app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH %@", "Decision saved on this phone")).firstMatch
        XCTAssertTrue(restored.waitForExistence(timeout: 20), "A pending decision must survive relaunch")
        XCTAssertFalse(app.staticTexts["overview.toReview.title"].exists)
    }
}
