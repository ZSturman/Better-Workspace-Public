import XCTest

final class MobileWorkspaceChangesUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false; XCUIDevice.shared.orientation = .portrait }
    override func tearDownWithError() throws { XCUIDevice.shared.orientation = .portrait }

    private func launch(_ area: String, fresh: Bool = true) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-mobileCloudDisabled", "YES", "-BWTestMobilePlanning", "YES", "-BWInitialURL", "betterworkspace-mobile://" + area]
        if fresh { app.launchArguments += ["-BWResetPlanningFixture", "YES"] }
        app.launch(); return app
    }
    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<6 where !element.exists || !element.isHittable { app.swipeUp() }
        XCTAssertTrue(element.isHittable)
    }
    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
    func testOneWorkspaceAndIndependentIdeaGroupAndSortControls() {
        let app = launch("ideas")
        XCTAssertFalse(app.segmentedControls["workspace.experience"].exists)
        XCTAssertTrue(app.buttons["mobile-idea-Ideas/Potential studio"].waitForExistence(timeout: 15))
        app.buttons["ideas.filterSort"].tap()
        app.buttons["Group by"].tap(); app.buttons["Potential"].tap()
        XCTAssertTrue(app.staticTexts["Project"].waitForExistence(timeout: 5))
        app.buttons["ideas.filterSort"].tap()
        app.buttons["Sort by"].tap(); app.buttons["Score"].tap()
        XCTAssertTrue(app.staticTexts["Project"].exists, "Changing sort must retain grouping")
        capture("mobile-ideas-group-potential-sort-score")
        app.buttons["ideas.filterSort"].tap(); app.buttons["Reset view"].tap()
    }
    func testZenScoringFillsTheScreenAndSavesOfflineInLandscape() {
        let app = launch("projects")
        let project = app.buttons["mobile-project-Projects/Example"]
        XCTAssertTrue(project.waitForExistence(timeout: 15)); project.tap()
        app.buttons["project.zen.open"].tap()
        XCTAssertTrue(app.staticTexts["zen.question"].waitForExistence(timeout: 10))
        app.buttons["zen.rating.5"].tap()
        capture("mobile-zen-scoring-portrait")
        XCUIDevice.shared.orientation = .landscapeLeft
        let next = app.buttons["zen.next"]; XCTAssertTrue(next.waitForExistence(timeout: 10)); XCTAssertTrue(next.isHittable)
        capture("mobile-zen-scoring-landscape")
        app.buttons["project.score.save"].tap()
        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(app.buttons["project.zen.open"].waitForExistence(timeout: 10))
        app.terminate()
        let reopened = launch("projects", fresh: false)
        XCTAssertTrue(reopened.buttons["mobile-project-Projects/Example"].waitForExistence(timeout: 15)); reopened.buttons["mobile-project-Projects/Example"].tap()
        reopened.buttons["project.zen.open"].tap()
        XCTAssertTrue(reopened.buttons["zen.rating.5"].waitForExistence(timeout: 10))
        XCTAssertTrue(reopened.buttons["zen.rating.5"].isSelected)
    }
    func testIdeaDomainChoosesOrAddsAndPersistsThroughTheMacDraft() {
        let app = launch("ideas")
        let idea = app.buttons["mobile-idea-Ideas/Potential studio"]
        XCTAssertTrue(idea.waitForExistence(timeout: 15)); idea.tap()
        let edit = app.buttons["idea.planning.edit"]; reveal(edit, in: app); edit.tap()
        let domain = app.buttons["idea.project.domain"]; reveal(domain, in: app); domain.tap()
        app.buttons["Add new domain…"].tap()
        let input = app.alerts.textFields.firstMatch
        XCTAssertTrue(input.waitForExistence(timeout: 5)); input.tap(); input.typeText("Mobile design")
        app.alerts.buttons["Add"].tap()
        capture("mobile-idea-select-or-add-domain")
        app.buttons["idea.planning.save"].tap()
        app.terminate()
        let reopened = launch("ideas", fresh: false)
        XCTAssertTrue(reopened.buttons["mobile-idea-Ideas/Potential studio"].waitForExistence(timeout: 15)); reopened.buttons["mobile-idea-Ideas/Potential studio"].tap()
        let reedit = reopened.buttons["idea.planning.edit"]; reveal(reedit, in: reopened); reedit.tap()
        XCTAssertTrue(reopened.buttons["idea.project.domain"].waitForExistence(timeout: 10))
        XCTAssertTrue(reopened.buttons["idea.project.domain"].label.contains("Mobile design") || (reopened.buttons["idea.project.domain"].value as? String) == "Mobile design")
    }
    func testDownloadRequestSurvivesOfflineRelaunchAndCanBeRemoved() {
        let app = launch("projects")
        XCTAssertTrue(app.buttons["mobile-project-Projects/Example"].waitForExistence(timeout: 15)); app.buttons["mobile-project-Projects/Example"].tap()
        let toggle = app.switches["download.enabled"]; reveal(toggle, in: app); toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        XCTAssertEqual(toggle.value as? String, "1")
        XCTAssertTrue(app.staticTexts["Waiting for download from the Mac…"].waitForExistence(timeout: 5))
        capture("mobile-project-offline-download-waiting")
        app.terminate()
        let reopened = launch("projects", fresh: false)
        XCTAssertTrue(reopened.buttons["mobile-project-Projects/Example"].waitForExistence(timeout: 15)); reopened.buttons["mobile-project-Projects/Example"].tap()
        let restored = reopened.switches["download.enabled"]; reveal(restored, in: reopened)
        XCTAssertEqual(restored.value as? String, "1"); restored.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        XCTAssertEqual(restored.value as? String, "0")
        XCTAssertFalse(reopened.staticTexts["Waiting for download from the Mac…"].exists)
    }
}
