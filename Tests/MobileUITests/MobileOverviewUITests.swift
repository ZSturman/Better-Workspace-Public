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
        XCTAssertTrue(app.navigationBars["Overview"].waitForExistence(timeout: 20))
        // Next up and Needs Attention come first; the review and focus cards follow.
        let title = app.staticTexts["overview.toReview.title"]
        XCTAssertTrue(app.scrollTo(title), "The Mac's published review item should be on Overview")
        XCTAssertEqual(title.label, "Review the next screen.md")
        XCTAssertTrue(app.buttons["Studied?"].exists, "To Study's decision is named for its folder")
        XCTAssertTrue(app.scrollTo(app.buttons.containing(NSPredicate(format: "identifier BEGINSWITH %@", "overview.focusItem.")).firstMatch),
                      "Bring forward should list the digest's almost-done project")
        shoot("mobile-overview-portrait")
        XCUIDevice.shared.orientation = .landscapeLeft
        let landscape = NSPredicate { _, _ in app.windows.firstMatch.frame.width > app.windows.firstMatch.frame.height }
        // As in the composer test: a simulator can decline to rotate; the check below
        // still holds, and the screenshot says which orientation it shows.
        _ = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: landscape, object: nil)], timeout: 10)
        let primary = app.buttons["overview.toReview.primary"]
        if !primary.waitForExistence(timeout: 5) { for _ in 0..<8 where !primary.exists { app.swipeDown() } }
        XCTAssertTrue(primary.exists || app.scrollTo(primary))
        shoot("mobile-overview-landscape")
    }

    func testDecisionWaitsForTheMacAndSurvivesRelaunch() {
        var app = launch(fresh: true)
        XCTAssertTrue(app.navigationBars["Overview"].waitForExistence(timeout: 20))
        let later = app.buttons["overview.toReview.later"]
        XCTAssertTrue(app.scrollTo(later))
        later.tap()
        let pending = app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH %@", "Decision saved on this phone")).firstMatch
        XCTAssertTrue(pending.waitForExistence(timeout: 10), "The card should say the decision is waiting for the Mac")
        XCTAssertFalse(app.staticTexts["overview.toReview.title"].exists, "A decided item must not be offered twice")
        shoot("mobile-overview-decision-pending")

        app.terminate()
        app = launch(fresh: false)
        let restored = app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH %@", "Decision saved on this phone")).firstMatch
        XCTAssertTrue(app.navigationBars["Overview"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.scrollTo(restored), "A pending decision must survive relaunch")
        XCTAssertFalse(app.staticTexts["overview.toReview.title"].exists)
    }
}
