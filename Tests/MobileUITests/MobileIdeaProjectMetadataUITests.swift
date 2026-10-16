import XCTest

final class MobileIdeaProjectMetadataUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false; XCUIDevice.shared.orientation = .portrait }
    override func tearDownWithError() throws { XCUIDevice.shared.orientation = .portrait }
    private func launch(fresh: Bool) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-mobileCloudDisabled", "YES", "-BWTestMobilePlanning", "YES", "-BWInitialURL", "betterworkspace-mobile://ideas"]
        if fresh { app.launchArguments += ["-BWResetPlanningFixture", "YES"] }
        app.launch()
        let row = app.buttons["mobile-idea-Ideas/Potential studio"]
        XCTAssertTrue(row.waitForExistence(timeout: 15)); row.tap()
        let edit = app.buttons["idea.planning.edit"]
        if !edit.isHittable { app.swipeUp() }
        XCTAssertTrue(edit.waitForExistence(timeout: 10)); edit.tap()
        return app
    }
    func testPotentialProjectMetadataSurvivesOfflineSaveWithKeyboardAndLandscape() {
        let app = launch(fresh: true)
        app.buttons["idea.planning.potential"].tap(); app.buttons["Potential Project"].tap()
        let domain = app.textFields["idea.project.domain"]
        if !domain.isHittable { app.swipeUp() }
        XCTAssertTrue(domain.waitForExistence(timeout: 10)); domain.tap(); domain.typeText("Technology")
        let line = app.textFields["idea.project.oneLiner"]
        if !line.isHittable { app.swipeUp() }
        XCTAssertTrue(line.waitForExistence(timeout: 10)); line.tap(); line.typeText("A native planning tool")
        XCTAssertTrue(app.buttons["idea.planning.save"].isHittable)
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(app.buttons["idea.planning.save"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["idea.planning.save"].isHittable)
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); attachment.name = "idea-project-landscape-keyboard"; attachment.lifetime = .keepAlways; add(attachment)
        app.buttons["idea.planning.save"].tap(); app.terminate()
        XCUIDevice.shared.orientation = .portrait
        let reopened = launch(fresh: false)
        let savedDomain = reopened.textFields["idea.project.domain"]
        XCTAssertTrue(savedDomain.waitForExistence(timeout: 10)); XCTAssertEqual(savedDomain.value as? String, "Technology")
        let savedLine = reopened.textFields["idea.project.oneLiner"]
        if !savedLine.isHittable { reopened.swipeUp() }
        XCTAssertEqual(savedLine.value as? String, "A native planning tool")
    }
}
