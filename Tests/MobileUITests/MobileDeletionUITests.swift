import XCTest

final class MobileDeletionUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false; XCUIDevice.shared.orientation = .portrait }
    override func tearDownWithError() throws { XCUIDevice.shared.orientation = .portrait }
    private func launch(_ tab: String, fresh: Bool = true) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-mobileCloudDisabled", "YES", "-BWTestMobilePlanning", "YES", "-BWInitialURL", "betterworkspace-mobile://" + tab]
        if fresh { app.launchArguments += ["-BWResetPlanningFixture", "YES"] }
        app.launch(); return app
    }
    private func screenshot(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name; shot.lifetime = .keepAlways; add(shot)
    }
    func testIdeaLongPressDeletionSurvivesOfflineRelaunch() {
        let app = launch("ideas")
        let row = app.buttons["mobile-idea-Ideas/Example.md"]
        XCTAssertTrue(row.waitForExistence(timeout: 15)); row.press(forDuration: 1)
        app.buttons["Delete idea"].tap()
        XCTAssertTrue(app.buttons["Move to Trash"].waitForExistence(timeout: 5))
        screenshot("delete-idea-iphone")
        app.buttons["Move to Trash"].tap()
        XCTAssertTrue(app.staticTexts["Record an idea. Add detail now, organize it when you are ready."].waitForExistence(timeout: 5))
        app.terminate()
        let reopened = launch("ideas", fresh: false)
        XCTAssertTrue(reopened.staticTexts["Record an idea. Add detail now, organize it when you are ready."].waitForExistence(timeout: 10))
        XCTAssertFalse(reopened.buttons["mobile-idea-Ideas/Example.md"].exists)
    }
    func testProjectLongPressRequiresConfirmationAndWorksInLandscape() {
        let app = launch("projects")
        let row = app.buttons["mobile-project-Projects/Example"]
        XCTAssertTrue(row.waitForExistence(timeout: 15)); row.press(forDuration: 1)
        app.buttons["Manage project"].tap()
        app.buttons["Delete project…"].tap()
        XCTAssertTrue(app.buttons["Move entire project to Trash"].waitForExistence(timeout: 5))
        screenshot("delete-project-iphone")
        app.buttons["Cancel"].tap()
        XCTAssertTrue(row.exists)
        row.tap()
        XCUIDevice.shared.orientation = .landscapeLeft
        app.buttons["Manage project"].tap()
        app.buttons["Delete project…"].tap()
        screenshot("delete-project-iphone-landscape")
        app.buttons["Move entire project to Trash"].tap()
        XCTAssertTrue(app.staticTexts["Create a project to start organizing its work."].waitForExistence(timeout: 10))
        XCTAssertFalse(row.exists)
    }

    func testFeatureLongPressUsesManageMenuAndLeavesOtherWork() {
        let app = launch("work")
        let feature = app.buttons.containing(NSPredicate(format: "label CONTAINS %@", "Offline reading")).firstMatch
        XCTAssertTrue(feature.waitForExistence(timeout: 15))
        for _ in 0..<4 { if feature.isHittable { break }; app.swipeUp() }
        feature.press(forDuration: 1)
        app.buttons["Manage feature"].tap()
        app.buttons["Delete…"].tap()
        XCTAssertTrue(app.buttons["Move to Trash"].waitForExistence(timeout: 5))
        screenshot("delete-feature-iphone")
        app.buttons["Move to Trash"].tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: feature)], timeout: 5), .completed)
        XCTAssertTrue(app.buttons.containing(NSPredicate(format: "label CONTAINS %@", "Sketch the next screen")).firstMatch.exists)
    }
}
