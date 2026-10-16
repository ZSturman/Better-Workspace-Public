import XCTest

final class MobileProjectParityUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false; XCUIDevice.shared.orientation = .portrait }
    override func tearDownWithError() throws { XCUIDevice.shared.orientation = .portrait }
    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-mobileCloudDisabled", "YES", "-BWTestMobilePlanning", "YES", "-BWResetPlanningFixture", "YES", "-BWInitialURL", "betterworkspace-mobile://overview"]
        app.launch(); return app
    }
    private func shoot(_ name: String) {
        let image = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); image.name = name; image.lifetime = .keepAlways; add(image)
    }
    private func reveal(_ element: XCUIElement, app: XCUIApplication) {
        for _ in 0..<7 { if element.exists && element.isHittable { return }; app.swipeUp() }
        XCTAssertTrue(element.exists && element.isHittable)
    }
    func testAssessmentBacklogAndInsightsUsePublishedMacMetadata() {
        let app = launch()
        app.workspaceDestination("Projects").tap()
        let project = app.staticTexts["Example"].firstMatch
        XCTAssertTrue(project.waitForExistence(timeout: 15)); project.tap()
        let assessment = app.buttons["project.assessment.open"].firstMatch
        // NavigationLink is exposed as a button on both compact and regular layouts.
        reveal(assessment, app: app); assessment.tap()
        let risk = app.buttons["project.audit.score.TechnicalRisk"].firstMatch
        reveal(risk, app: app); risk.tap()
        let explanation = app.staticTexts["project.audit.scoreExplanation"].firstMatch
        reveal(explanation, app: app)
        XCTAssertTrue(explanation.label.contains("MORE risk")); shoot("mobile-assessment-risk")
        let reason = app.buttons["project.audit.expand.test-work"].firstMatch
        reveal(reason, app: app); reason.tap()
        shoot("mobile-backlog-expanded-before-scroll")
        reveal(app.staticTexts["project.audit.reason.test-work"], app: app)
        shoot("mobile-ranked-backlog")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        let insights = app.buttons["project.insights.open"].firstMatch
        reveal(insights, app: app); insights.tap()
        XCTAssertTrue(app.descendants(matching: .any)["project.insights.history"].firstMatch.waitForExistence(timeout: 10))
        shoot("mobile-project-history")
        let estimate = app.buttons["project.insights.estimate"].firstMatch
        reveal(estimate, app: app); estimate.tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH %@", "Rough estimate:")).firstMatch.waitForExistence(timeout: 5))
        shoot("mobile-pace-explained")
        let types = app.descendants(matching: .any)["project.insights.types"].firstMatch
        reveal(types, app: app); shoot("mobile-work-type-chart")
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(types.waitForExistence(timeout: 10)); shoot("mobile-insights-landscape")
    }
    func testInboxReviewExpandsAndRemembersChoice() {
        let app = launch()
        let review = app.buttons["overview.toReview.expand"].firstMatch
        XCTAssertTrue(review.waitForExistence(timeout: 15))
        XCTAssertFalse(app.staticTexts["overview.toReview.preview"].exists)
        review.tap(); shoot("mobile-inbox-expanded-before-check"); XCTAssertTrue(app.descendants(matching: .any)["overview.toReview.preview"].firstMatch.waitForExistence(timeout: 5))
        shoot("mobile-inbox-review-expanded")
        app.terminate(); app.launchArguments.removeLast(4); app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["overview.toReview.preview"].firstMatch.waitForExistence(timeout: 15))
    }
}
