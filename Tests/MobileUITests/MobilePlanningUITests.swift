import XCTest

final class MobilePlanningUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false; XCUIDevice.shared.orientation = .portrait }
    override func tearDownWithError() throws { XCUIDevice.shared.orientation = .portrait }
    private func launch(_ tab: String = "overview", fresh: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-mobileCloudDisabled", "YES", "-BWTestMobilePlanning", "YES",
                               "-BWInitialURL", "betterworkspace-mobile://" + tab]
        if fresh { app.launchArguments += ["-BWResetPlanningFixture", "YES"] }
        app.launch()
        return app
    }
    private func shoot(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name; shot.lifetime = .keepAlways; add(shot)
    }
    func testIdeasOpenDescriptionTagsAndFilesAndCanBecomeFeatures() {
        let app = launch("ideas")
        let idea = app.buttons["mobile-idea-Ideas/Example.md"]
        XCTAssertTrue(idea.waitForExistence(timeout: 20)); idea.tap()
        XCTAssertTrue(app.staticTexts["Title, description, then supporting files."].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Design"].exists)
        XCTAssertTrue(app.staticTexts["reference.png"].exists)
        shoot("mobile-idea-detail")
        app.buttons["Create feature plan"].tap()
        XCTAssertTrue(app.navigationBars["New Feature"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Save"].isEnabled, "A project is optional; without one it waits under Needs Attention")
        app.buttons["work-link-project"].tap()
        app.buttons["Example"].tap()
        XCTAssertTrue(app.buttons["work-link-project"].label.contains("Example"))
        XCTAssertTrue(app.buttons["work-link-milestone"].exists, "A feature can belong to a milestone")
        XCTAssertFalse(app.buttons["work-link-feature"].exists, "…but not to another feature")
        XCTAssertTrue(app.buttons["Save"].isEnabled)
        app.buttons["Cancel"].tap()
    }
    func testProjectStartsWithNextWorkAndCanAddFeaturesAndMilestones() {
        let app = launch("projects")
        let project = app.buttons["mobile-project-Projects/Example"]
        XCTAssertTrue(project.waitForExistence(timeout: 20)); project.tap()
        XCTAssertTrue(app.staticTexts["Up Next"].waitForExistence(timeout: 10))
        let next = app.buttons.containing(NSPredicate(format: "label CONTAINS %@", "Sketch the next screen")).firstMatch
        // Waits out the push animation instead of sampling hittability mid-flight.
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "isHittable == true"), object: next)], timeout: 10), .completed)
        shoot("mobile-project-next-steps")
        for (kind, title) in [("feature", "New Feature"), ("milestone", "New Milestone")] {
            // One Add menu in the toolbar, for every kind.
            app.buttons["project-add"].tap()
            let add = app.buttons["project-add-" + kind]
            XCTAssertTrue(add.waitForExistence(timeout: 5))
            add.tap()
            XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 10))
            XCTAssertTrue(app.buttons["work-link-project"].label.contains("Example"))
            app.buttons["Cancel"].tap()
        }
    }
    func testUnplacedFeatureNeedsAttentionUntilAProjectIsChosen() {
        let app = launch("work", fresh: true)
        let attention = app.descendants(matching: .any)["work-needs-attention"].firstMatch
        XCTAssertTrue(attention.waitForExistence(timeout: 20), "A feature with no project is called out")
        XCTAssertTrue(app.buttons.containing(NSPredicate(format: "label CONTAINS %@", "Unplaced feature")).firstMatch.exists)
        shoot("mobile-work-needs-attention")
        app.buttons["work-choose-project"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Example"].waitForExistence(timeout: 5))
        app.buttons["Example"].tap()
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: attention)
        XCTAssertEqual(XCTWaiter.wait(for: [gone], timeout: 10), .completed, "Placed, it leaves Needs Attention")

        // The detail screen links it further, to a milestone or back to no project.
        let row = app.buttons.containing(NSPredicate(format: "label CONTAINS %@", "Unplaced feature")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10)); row.tap()
        XCTAssertTrue(app.staticTexts["Part of"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["work-link-project"].label.contains("Example"))
        shoot("mobile-work-belongs-to")
    }

    func testWorkIsSelectableAndEditedDraftSurvivesOfflineRelaunch() {
        let marker = "Offline follow-up " + UUID().uuidString
        let app = launch("work")
        let work = app.buttons.containing(NSPredicate(format: "label CONTAINS %@", "Sketch the next screen")).firstMatch
        XCTAssertTrue(work.waitForExistence(timeout: 20)); work.tap()
        app.buttons["Edit"].tap()
        XCTAssertTrue(app.textViews["planning-description"].waitForExistence(timeout: 10))
        let text = app.textViews["planning-description"]
        text.tap(); text.typeText(" " + marker)
        if app.buttons["Done"].exists { app.buttons["Done"].tap() }
        shoot("mobile-work-editor")
        app.buttons["Save"].tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", marker)).firstMatch.waitForExistence(timeout: 10))
        shoot("mobile-work-offline-save")
        app.terminate()
        app.launch()
        let reopened = app.buttons.containing(NSPredicate(format: "label CONTAINS %@", "Sketch the next screen")).firstMatch
        XCTAssertTrue(reopened.waitForExistence(timeout: 20)); reopened.tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", marker)).firstMatch.waitForExistence(timeout: 10))
        shoot("mobile-work-offline-persisted-after-relaunch")
    }
    func testTaskNotesReadAsFormattedMarkdown() {
        let app = launch("work", fresh: true)
        let work = app.buttons.containing(NSPredicate(format: "label CONTAINS %@", "Sketch the next screen")).firstMatch
        XCTAssertTrue(work.waitForExistence(timeout: 20)); work.tap()
        // Every rendered block carries the body's identifier; read them all.
        let blocks = app.descendants(matching: .any).matching(identifier: "work-body")
        XCTAssertTrue(blocks.firstMatch.waitForExistence(timeout: 10))
        let text = blocks.allElementsBoundByIndex.map(\.label).joined(separator: "\n")
        for expected in ["Plan", "Keep the next action clear.", "Sketch the empty state", "List the screens"] {
            XCTAssertTrue(text.contains(expected), "\(expected) missing from: \(text)")
        }
        for syntax in ["##", "**", "- ["] {
            XCTAssertFalse(text.contains(syntax), "Raw \(syntax) shown: \(text)")
        }
        shoot("mobile-task-markdown")
    }
    func testNewFeatureDraftSurvivesOfflineRelaunch() {
        let marker = "Functional audit feature " + UUID().uuidString.prefix(8)
        let app = launch("projects")
        let project = app.buttons["mobile-project-Projects/Example"]
        XCTAssertTrue(project.waitForExistence(timeout: 20)); project.tap()
        app.buttons["project-add"].tap()
        let add = app.buttons["project-add-feature"]
        XCTAssertTrue(add.waitForExistence(timeout: 5))
        add.tap()
        XCTAssertTrue(app.navigationBars["New Feature"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["Save"].isEnabled, "An empty title must not create a feature")
        let title = app.textFields["planning-title"]
        title.tap(); title.typeText(marker)
        let description = app.textViews["planning-description"]
        description.tap(); description.typeText("A synthetic feature for offline persistence verification.")
        if app.buttons["Done"].exists { app.buttons["Done"].tap() }
        shoot("mobile-new-feature-before-save")
        app.buttons["Save"].tap()
        let feature = app.buttons.containing(NSPredicate(format: "label CONTAINS %@", marker)).firstMatch
        for _ in 0..<4 { if feature.exists { break }; app.swipeUp() }
        XCTAssertTrue(feature.waitForExistence(timeout: 10)); feature.tap()
        XCTAssertTrue(app.staticTexts["A synthetic feature for offline persistence verification."].waitForExistence(timeout: 10))
        shoot("mobile-new-feature-saved-offline")
        app.terminate()
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 10))
        app.launch()
        XCTAssertTrue(project.waitForExistence(timeout: 20)); project.tap()
        for _ in 0..<4 { if feature.exists { break }; app.swipeUp() }
        XCTAssertTrue(feature.waitForExistence(timeout: 10)); feature.tap()
        XCTAssertTrue(app.staticTexts["A synthetic feature for offline persistence verification."].waitForExistence(timeout: 10))
        shoot("mobile-new-feature-persisted-after-relaunch")
    }
    func testOverviewHasNoLibraryOrHealthySyncBanner() {
        let app = launch()
        XCTAssertTrue(app.navigationBars["Overview"].waitForExistence(timeout: 20))
        XCTAssertFalse(app.buttons["Library"].exists)
        XCTAssertFalse(app.staticTexts["Mac-published index"].exists)
        shoot("mobile-overview")
    }
}
