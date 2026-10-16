import XCTest

final class MobileProjectControlUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false; XCUIDevice.shared.orientation = .portrait }
    override func tearDownWithError() throws { XCUIDevice.shared.orientation = .portrait }
    private func launch(fresh: Bool) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-mobileCloudDisabled", "YES", "-BWTestMobilePlanning", "YES", "-BWInitialURL", "betterworkspace-mobile://projects"]
        if fresh { app.launchArguments += ["-BWResetPlanningFixture", "YES"] }
        app.launch(); return app
    }
    private func shoot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
    private func openProject(_ app: XCUIApplication) {
        let row = app.buttons["mobile-project-Projects/Example"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 20)); row.tap()
        XCTAssertTrue(app.buttons["project.score.edit"].waitForExistence(timeout: 10))
    }
    func testProjectScoringAndDetailsSaveOfflineAndSurviveRelaunch() {
        let app = launch(fresh: true); openProject(app)
        XCTAssertTrue(app.staticTexts["New project created"].exists)
        app.buttons["project.score.edit"].tap()
        let fields = app.descendants(matching: .any).matching(identifier: "project.score.oneLiner")
        XCTAssertTrue(fields.firstMatch.waitForExistence(timeout: 10))
        let text = app.textFields["project.score.oneLiner"].exists ? app.textFields["project.score.oneLiner"] : app.textViews["project.score.oneLiner"]
        text.tap()
        text.typeText(" · Phone scored project")
        let editedText = (text.value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        shoot("mobile-scoring-keyboard")
        app.buttons["project.score.keyboardDone"].tap()
        // Dismiss the keyboard without saving, then choose a direction-aware rating.
        let metric = app.buttons["project.score.qualityOfLife"].firstMatch
        if !metric.isHittable { app.swipeUp() }
        XCTAssertTrue(metric.waitForExistence(timeout: 10)); metric.tap()
        app.buttons["5 · Transformative"].tap()
        shoot("mobile-project-scoring-portrait")
        XCTAssertTrue(app.buttons["project.score.save"].isHittable)
        app.buttons["project.score.save"].tap()
        app.terminate()
        let relaunched = launch(fresh: false); openProject(relaunched)
        relaunched.buttons["project.score.edit"].tap()
        let saved = relaunched.textFields["project.score.oneLiner"].exists ? relaunched.textFields["project.score.oneLiner"] : relaunched.textViews["project.score.oneLiner"]
        XCTAssertTrue(saved.waitForExistence(timeout: 10))
        XCTAssertEqual(saved.value as? String, editedText)
        XCTAssertTrue((saved.value as? String)?.contains("Phone scored project") == true)
        let score = relaunched.staticTexts["project.score.value"]
        if !score.isHittable { relaunched.swipeUp() }
        XCTAssertTrue(score.waitForExistence(timeout: 10))
        XCTAssertTrue(score.label.hasSuffix("/100"), "The saved answer contributes to the project score")
        let savedMetric = relaunched.buttons["project.score.qualityOfLife"].firstMatch
        if !savedMetric.isHittable { relaunched.swipeUp() }
        XCTAssertTrue(savedMetric.label.contains("Transformative"), "The selected answer survives relaunch")
        shoot("mobile-project-score-after-relaunch")
    }
    func testProjectFilePreviewRendersAndRequestIsQueuedOnce() {
        let app = launch(fresh: true); openProject(app)
        XCTAssertTrue(app.staticTexts["Read-only project file preview."].waitForExistence(timeout: 10))
        shoot("mobile-project-file-preview")
        let load = app.buttons["project.previews.load"]
        XCTAssertTrue(load.isEnabled); load.tap()
        XCTAssertFalse(load.isEnabled)
        XCTAssertTrue(load.label.contains("Waiting for the Mac"))
    }
}
