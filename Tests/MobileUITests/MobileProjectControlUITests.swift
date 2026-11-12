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
        let opened = app.buttons["project.score.edit"].waitForExistence(timeout: 10)
        if opened == false { print("PROJECT NAVIGATION DIAGNOSTIC: " + app.debugDescription) }
        XCTAssertTrue(opened)
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
    func testProjectHistoryShowsDescriptionsDurationsAndLinkedSessionsInPortraitAndLandscape() {
        let app = launch(fresh: true); openProject(app)
        let history = app.buttons["project.history.open"].firstMatch
        for _ in 0..<5 where !history.isHittable { app.swipeUp() }
        XCTAssertTrue(history.waitForExistence(timeout: 10)); history.tap()
        XCTAssertTrue(app.staticTexts["1 work log · 1 recorded session"].waitForExistence(timeout: 10))
        let log = app.buttons["project.history.log.fixture-log"].firstMatch
        XCTAssertTrue(log.waitForExistence(timeout: 10)); log.tap()
        XCTAssertTrue(app.staticTexts["Active: 20m · Elapsed: 35m"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Reviewed the sync queue."].firstMatch.exists)
        XCUIDevice.shared.orientation = .landscapeLeft
        let duration = app.staticTexts["Active: 20m · Elapsed: 35m"]
        // A full swipe moves farther than the 390-point landscape window is tall and carries
        // the line from below the window to above it; scroll in short drags instead.
        let list = app.collectionViews["project.history"]
        for _ in 0..<10 where !(duration.exists && duration.isHittable) {
            list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.65))
                .press(forDuration: 0.1, thenDragTo: list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4)))
        }
        XCTAssertTrue(duration.exists && duration.isHittable)
        shoot("project-history-landscape")
    }

    func testProjectFilePreviewRendersAndRequestIsQueuedOnce() {
        let app = launch(fresh: true); openProject(app)
        let preview = app.staticTexts["Read-only project file preview."]
        for _ in 0..<8 where !preview.exists || !preview.isHittable { app.swipeUp() }
        XCTAssertTrue(preview.waitForExistence(timeout: 10))
        shoot("mobile-project-file-preview")
        let load = app.buttons["project.previews.load"]
        XCTAssertTrue(load.isEnabled); load.tap()
        XCTAssertFalse(load.isEnabled)
        XCTAssertTrue(load.label.contains("Waiting for the Mac"))
    }
}


extension MobileProjectControlUITests {
    func testScoringDomainImmediatelyRefreshesInlineDetails() {
        let app = launch(fresh: true); openProject(app)
        let inline = app.buttons["project.details.domain"]
        XCTAssertTrue(inline.waitForExistence(timeout: 10))
        app.buttons["project.score.edit"].tap()
        let domain = app.buttons["project.property.domain"]
        XCTAssertTrue(domain.waitForExistence(timeout: 10)); domain.tap()
        app.buttons["Add new domain…"].tap()
        let field = app.alerts.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5)); field.tap(); field.typeText("Technology")
        app.alerts.buttons["Add"].tap()
        app.buttons["project.score.save"].tap()
        XCTAssertTrue(inline.waitForExistence(timeout: 10))
        XCTAssertEqual(inline.value as? String, "Technology", "The open project reflects a scoring-sheet Save immediately")
    }
    func testDomainIsVisibleImmediatelyAndRetainedAfterOfflineRelaunch() {
        let app = launch(fresh: true); openProject(app)
        let domain = app.buttons["project.details.domain"].firstMatch
        XCTAssertTrue(domain.waitForExistence(timeout: 10)); domain.tap()
        app.buttons["Add new domain…"].tap()
        let field = app.alerts.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5)); field.tap(); field.typeText("Technology")
        app.alerts.buttons["Add"].tap()
        let save = app.buttons["Save project details"]
        for _ in 0..<8 where !save.isHittable { app.swipeUp() }
        XCTAssertTrue(save.isHittable); save.tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Saved on this device.")).firstMatch.exists)
        app.terminate()
        let reopened = launch(fresh: false); openProject(reopened)
        XCTAssertTrue(reopened.staticTexts["Saved domain: Technology"].waitForExistence(timeout: 10))
        let savedDomain = reopened.buttons["project.details.domain"].firstMatch
        for _ in 0..<5 where !savedDomain.isHittable { reopened.swipeUp() }
        XCTAssertEqual(savedDomain.value as? String, "Technology")
    }
    func testInlineProjectPropertiesSaveWithoutScoringNavigation() {
        let app = launch(fresh: true); openProject(app)
        let featured = app.switches["project.featured"]
        for _ in 0..<5 where !featured.exists || !featured.isHittable { app.swipeUp() }
        XCTAssertTrue(featured.waitForExistence(timeout: 10))
        featured.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        XCTAssertEqual(featured.value as? String, "1")
        let save = app.buttons["Save project details"]
        for _ in 0..<6 where !save.exists || !save.isHittable { app.swipeUp() }
        XCTAssertTrue(save.isHittable); save.tap()
        app.terminate()
        let reopened = launch(fresh: false); openProject(reopened)
        let saved = reopened.switches["project.featured"]
        for _ in 0..<5 where !saved.exists || !saved.isHittable { reopened.swipeUp() }
        XCTAssertTrue(saved.waitForExistence(timeout: 10)); XCTAssertEqual(saved.value as? String, "1")
        shoot("connected-project-inline-properties")
    }
}
