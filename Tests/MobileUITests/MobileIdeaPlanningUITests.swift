import XCTest

final class MobileIdeaPlanningUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false; XCUIDevice.shared.orientation = .portrait }
    override func tearDownWithError() throws { XCUIDevice.shared.orientation = .portrait }
    private func launch(fresh: Bool) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-mobileCloudDisabled", "YES", "-BWTestMobilePlanning", "YES", "-BWInitialURL", "betterworkspace-mobile://ideas"]
        if fresh { app.launchArguments += ["-BWResetPlanningFixture", "YES"] }
        app.launch(); return app
    }
    private func open(_ app: XCUIApplication) {
        let idea = app.buttons["mobile-idea-Ideas/Potential studio"]
        XCTAssertTrue(idea.waitForExistence(timeout: 15)); idea.tap()
        let edit = app.buttons["idea.planning.edit"]
        if !edit.isHittable { app.swipeUp() }
        XCTAssertTrue(edit.waitForExistence(timeout: 10)); edit.tap()
    }
    func testIdeaPriorityAndPotentialStayIdeasAndPersistOffline() {
        let app = launch(fresh: true); open(app)
        app.buttons["idea.planning.potential"].tap()
        app.buttons["Potential Milestone"].tap()
        app.buttons["idea.planning.priority"].tap()
        app.buttons["5 · Highest"].tap()
        let portrait = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); portrait.name = "idea-potential-priority-mobile"; portrait.lifetime = .keepAlways; add(portrait)
        XCTAssertTrue(app.buttons["idea.planning.save"].isHittable); app.buttons["idea.planning.save"].tap()
        app.terminate()
        let reopened = launch(fresh: false); open(reopened)
        XCTAssertTrue(reopened.buttons["idea.planning.potential"].label.contains("Milestone"))
        XCTAssertTrue(reopened.buttons["idea.planning.priority"].label.contains("5"))
    }
    func testPromotionHasExplicitWholeFolderConfirmationAndQueuesMacMove() {
        let app = launch(fresh: true)
        let row = app.buttons["mobile-idea-Ideas/Potential studio"]
        XCTAssertTrue(row.waitForExistence(timeout: 15)); row.tap()
        let promote = app.buttons["idea.promote.project"]
        if !promote.isHittable { app.swipeUp() }
        XCTAssertTrue(promote.waitForExistence(timeout: 10)); promote.tap()
        let move = app.buttons["Move entire folder to Projects"]
        XCTAssertTrue(move.waitForExistence(timeout: 10)); move.tap()
        XCTAssertTrue(app.buttons["idea.promote.project"].exists, "The idea remains until the Mac acknowledges its move")
    }
}
