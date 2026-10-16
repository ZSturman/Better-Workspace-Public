import XCTest

/// Uses the public sample mode in Release; no DEBUG fixtures or real iCloud data.
final class StoreScreenshotsUITests: XCTestCase {
    private func screenshot(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name; shot.lifetime = .keepAlways; add(shot)
    }

    private func select(_ title: String, in app: XCUIApplication) {
        let sidebars = app.descendants(matching: .any).matching(identifier: "workspace-sidebar-" + title.lowercased()).allElementsBoundByIndex
        if let sidebar = sidebars.first(where: { $0.isHittable }) { sidebar.tap(); return }
        let tabs = app.tabBars.buttons.matching(identifier: title).allElementsBoundByIndex
        guard let tab = tabs.first(where: { $0.isHittable }) else {
            XCTFail("No visible tab or sidebar destination for \(title)"); return
        }
        tab.tap()
    }

    func testCaptureStoreScreensAndSampleIsolation() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["-mobileCloudDisabled", "YES"]
        app.launch()
        defer { app.terminate(); XCUIDevice.shared.orientation = .portrait }
        let more = app.buttons["More workspace views"]
        XCTAssertTrue(more.waitForExistence(timeout: 20)); more.tap()
        let sample = app.buttons["workspace.sample.open"]
        XCTAssertTrue(sample.waitForExistence(timeout: 5)); sample.tap()
        XCTAssertTrue(app.staticTexts["Sample workspace"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["overview-next-work"].waitForExistence(timeout: 10))
        screenshot("01-overview")

        select("Projects", in: app)
        let project = app.buttons["mobile-project-Projects/Garden journal"].firstMatch
        XCTAssertTrue(project.waitForExistence(timeout: 10)); project.tap()
        XCTAssertTrue(app.buttons["project.score.edit"].waitForExistence(timeout: 10))
        screenshot("02-project")

        select("Work", in: app)
        let task = app.buttons.containing(NSPredicate(format: "label CONTAINS %@", "Sketch the weekly journal")).firstMatch
        XCTAssertTrue(task.waitForExistence(timeout: 10)); task.tap()
        let completion = app.buttons["work-toggle-completion"]
        XCTAssertTrue(app.staticTexts["work-body"].firstMatch.waitForExistence(timeout: 10))
        screenshot("03-work-plan")
        for _ in 0..<3 where !completion.isHittable { app.swipeUp() }
        XCTAssertTrue(completion.waitForExistence(timeout: 5))

        select("Ideas", in: app)
        let idea = app.buttons["mobile-idea-Ideas/Reading nook"].firstMatch
        XCTAssertTrue(idea.waitForExistence(timeout: 10)); idea.tap()
        XCTAssertTrue(app.buttons["idea.planning.edit"].waitForExistence(timeout: 10))
        screenshot("04-idea")
        app.buttons["idea.planning.edit"].tap()
        XCTAssertTrue(app.buttons["idea.planning.save"].waitForExistence(timeout: 10))
        screenshot("05-idea-priority")
        app.buttons["Cancel"].firstMatch.tap()
        select("Work", in: app)
        XCTAssertTrue(completion.waitForExistence(timeout: 5))
        let initialLabel = completion.label
        completion.tap()
        XCTAssertEqual(completion.label, initialLabel, "Sample actions must not change or queue work")
        app.buttons["workspace.sample.close"].tap()
        XCTAssertFalse(app.staticTexts["Sample workspace"].exists)
        XCTAssertFalse(app.buttons["mobile-project-Projects/Garden journal"].exists,
                       "Sample records must not replace the live index")
    }
}
