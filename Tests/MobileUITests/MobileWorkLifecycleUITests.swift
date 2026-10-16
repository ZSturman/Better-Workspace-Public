import XCTest

/// Work items from creation to deletion, on the offline planning fixture: every change
/// must show up on every screen that lists the item, and survive a relaunch. Runs on
/// iPhone (tabs) and iPad (sidebar) alike.
final class MobileWorkLifecycleUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false; XCUIDevice.shared.orientation = .portrait }
    override func tearDownWithError() throws { XCUIDevice.shared.orientation = .portrait }

    private func launch(_ tab: String = "work", fresh: Bool = true) -> XCUIApplication {
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

    private func row(_ app: XCUIApplication, _ title: String) -> XCUIElement {
        app.buttons.containing(NSPredicate(format: "label CONTAINS %@", title)).firstMatch
    }

    /// LabeledContent reads as one element, "Label, value".
    private func label(_ app: XCUIApplication, _ prefix: String) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", prefix)).firstMatch
    }

    private func back(_ app: XCUIApplication) {
        let back = app.navigationBars.buttons["BackButton"].firstMatch
        if back.waitForExistence(timeout: 3) { back.tap(); return }
        // Older systems label the back button with the previous title instead.
        app.navigationBars.buttons.element(boundBy: 0).tap()
    }

    private func confirmDelete(_ app: XCUIApplication) {
        let confirm = app.buttons.matching(NSPredicate(format: "label == 'Delete' AND identifier != 'work-delete'"))
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            // The dialog's button is the last "Delete" on screen (a swipe action or the
            // detail screen's own button may still be behind it).
            let all = confirm.allElementsBoundByIndex.filter(\.isHittable)
            if let last = all.last, app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Trash")).firstMatch.exists {
                last.tap(); return
            }
            Thread.sleep(forTimeInterval: 0.25)
        }
        XCTFail("No delete confirmation appeared")
    }

    private func openAnalytics(_ app: XCUIApplication) {
        app.workspaceDestination("Overview").tap()
        // A tab keeps its stack: coming back may land on the Analytics already open,
        // which must then show the change rather than what it showed before.
        if app.navigationBars["Analytics"].waitForExistence(timeout: 2) { return }
        let more = app.buttons["More workspace views"]
        XCTAssertTrue(more.waitForExistence(timeout: 15)); more.tap()
        let analytics = app.buttons["Analytics"]
        XCTAssertTrue(analytics.waitForExistence(timeout: 10)); analytics.tap()
        XCTAssertTrue(app.navigationBars["Analytics"].waitForExistence(timeout: 10))
    }

    private func chartValue(_ app: XCUIApplication, _ identifier: String) -> String {
        let chart = app.descendants(matching: .any)[identifier]
        XCTAssertTrue(chart.waitForExistence(timeout: 10), "\(identifier) missing")
        return chart.value as? String ?? ""
    }

    func testCompleteRestoreAndDeleteReachEveryScreenAndSurviveRelaunch() {
        let title = "Sketch the next screen"
        let app = launch()
        let work = row(app, title)
        XCTAssertTrue(work.waitForExistence(timeout: 20)); work.tap()

        // Complete: the detail updates in place, and the button becomes Reopen.
        app.buttons["work-toggle-completion"].tap()
        XCTAssertTrue(label(app, "Status, Completed").waitForExistence(timeout: 10))
        XCTAssertEqual(app.buttons["work-toggle-completion"].label, "Reopen")
        shoot("work-completed-detail")
        back(app)
        // Off the Now list, into Completed.
        XCTAssertTrue(app.buttons["Completed (2)"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["Now"].exists, "Nothing is left in Now")
        app.workspaceDestination("Overview").tap()
        let next = app.buttons["overview-next-work"]
        if next.waitForExistence(timeout: 5) { XCTAssertFalse(next.label.contains(title), "Overview still recommends completed work") }

        // Restore from the Completed group.
        app.workspaceDestination("Work").tap()
        let completed = app.buttons["Completed (2)"]
        XCTAssertTrue(completed.waitForExistence(timeout: 10)); completed.tap()
        XCTAssertTrue(row(app, title).waitForExistence(timeout: 10)); row(app, title).tap()
        app.buttons["work-toggle-completion"].tap()
        XCTAssertTrue(label(app, "Status, Open").waitForExistence(timeout: 10))
        back(app)
        XCTAssertTrue(app.staticTexts["Now"].waitForExistence(timeout: 10), "Reopened work returns to Now")
        XCTAssertTrue(app.buttons["Completed (1)"].exists)

        // Delete, after confirming.
        row(app, title).tap()
        app.buttons["work-delete"].tap()
        shoot("work-delete-confirmation")
        confirmDelete(app)
        XCTAssertTrue(app.navigationBars["Work"].waitForExistence(timeout: 10), "Deleting leaves the detail screen")
        XCTAssertFalse(row(app, title).waitForExistence(timeout: 2))
        app.workspaceDestination("Projects").tap()
        let project = app.buttons["mobile-project-Projects/Example"]
        XCTAssertTrue(project.waitForExistence(timeout: 10))
        XCTAssertFalse(project.label.contains(title), "The project row still names deleted work")
        project.tap()
        XCTAssertTrue(app.staticTexts["Up Next"].waitForExistence(timeout: 10))
        XCTAssertFalse(row(app, title).exists, "The project page still lists deleted work")
        shoot("work-deleted-project")

        // Everything above was saved on the phone and must survive a relaunch.
        app.terminate()
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 10))
        let relaunched = launch(fresh: false)
        XCTAssertTrue(relaunched.navigationBars["Work"].waitForExistence(timeout: 20))
        XCTAssertTrue(row(relaunched, "Offline reading").waitForExistence(timeout: 10))
        XCTAssertFalse(row(relaunched, title).exists, "Deleted work came back after relaunch")
        XCTAssertTrue(relaunched.buttons["Completed (1)"].exists)
        XCTAssertTrue(relaunched.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "waiting for the Mac")).firstMatch.exists,
                      "Waiting changes are still reported after relaunch")
    }

    func testSwipeActionsCompleteAndDeleteFromTheList() {
        let app = launch()
        let feature = row(app, "Offline reading")
        XCTAssertTrue(feature.waitForExistence(timeout: 20))
        feature.swipeRight()
        let complete = app.buttons["Complete"]
        XCTAssertTrue(complete.waitForExistence(timeout: 5)); complete.tap()
        XCTAssertTrue(app.buttons["Completed (2)"].waitForExistence(timeout: 10))
        let task = row(app, "Sketch the next screen")
        task.swipeLeft()
        let delete = app.buttons["Delete"]
        XCTAssertTrue(delete.waitForExistence(timeout: 5)); delete.tap()
        confirmDelete(app)
        XCTAssertFalse(row(app, "Sketch the next screen").waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Add work, then choose what to do now or next."].exists, "An empty Work list says what to do")
        shoot("work-swipe-empty")
    }

    func testANewTaskKeepsItsDueDateThroughEditAndCompletion() {
        let marker = "Due task " + UUID().uuidString.prefix(6)
        let app = launch()
        let add = app.buttons["New work"]
        XCTAssertTrue(add.waitForExistence(timeout: 20)); add.tap()
        let title = app.textFields["planning-title"]
        XCTAssertTrue(title.waitForExistence(timeout: 10)); title.tap(); title.typeText(marker)
        // On iPad the editor is a form sheet; with the keyboard up the toggle is below
        // the fold and not yet in the hierarchy.
        if app.buttons["Done"].exists { app.buttons["Done"].tap() }
        // The due date is an advanced option.
        let more = app.buttons["More Options"].firstMatch
        for _ in 0..<4 where !more.exists || !more.isHittable { app.swipeUp() }
        more.tap()
        let due = app.switches["Due date"].firstMatch
        for _ in 0..<4 where !due.exists || !due.isHittable { app.swipeUp() }
        due.tap()
        if app.switches["Due date"].value as? String == "0" { app.switches["Due date"].switches.firstMatch.tap() }
        XCTAssertEqual(app.switches["Due date"].value as? String, "1")
        app.buttons["Save"].tap()

        let created = row(app, marker)
        XCTAssertTrue(created.waitForExistence(timeout: 10)); created.tap()
        XCTAssertTrue(label(app, "Due, ").waitForExistence(timeout: 10), "The due date is shown")
        // Edit before the Mac has seen it, then complete it.
        app.buttons["Edit"].tap()
        let field = app.textFields["planning-title"]
        XCTAssertTrue(field.waitForExistence(timeout: 10)); field.tap(); field.typeText(" edited")
        app.buttons["Save"].tap()
        XCTAssertTrue(app.staticTexts[marker + " edited"].waitForExistence(timeout: 10))
        XCTAssertTrue(label(app, "Due, ").exists, "Editing kept the due date")
        app.buttons["work-toggle-completion"].tap()
        XCTAssertTrue(label(app, "Status, Completed").waitForExistence(timeout: 10))

        app.terminate()
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 10))
        let relaunched = launch(fresh: false)
        let group = relaunched.buttons["Completed (2)"]
        XCTAssertTrue(group.waitForExistence(timeout: 20)); group.tap()
        let saved = row(relaunched, marker + " edited")
        XCTAssertTrue(saved.waitForExistence(timeout: 10)); saved.tap()
        XCTAssertTrue(label(relaunched, "Due, ").waitForExistence(timeout: 10))
        XCTAssertTrue(label(relaunched, "Status, Completed").exists)
        shoot("new-task-due-after-relaunch")
    }

    /// Progress sits beside the work it summarizes and follows changes. Overview and Work
    /// summarize all work, so they agree with each other and include work with no
    /// project (a project is optional; that work waits under Needs Attention). A
    /// project's strip counts only that project's work.
    func testProgressChartsAgreeAcrossScreensFollowChangesAndFitLandscape() {
        let app = launch("overview")
        // Fixture: Example has one Now task, one Later feature and one completed task;
        // one Next feature has no project.
        let workspaceBefore = "1 now · 1 next · 1 later · 25% done"
        let projectBefore = "1 now · 1 later · 33% done"
        XCTAssertEqual(chartValue(app, "overview-progress"), workspaceBefore)
        app.workspaceDestination("Work").tap()
        XCTAssertEqual(chartValue(app, "work-progress"), workspaceBefore)
        app.workspaceDestination("Projects").tap()
        let project = app.buttons["mobile-project-Projects/Example"]
        XCTAssertTrue(project.waitForExistence(timeout: 10)); project.tap()
        XCTAssertEqual(chartValue(app, "project-progress"), projectBefore, "Unplaced work is not this project's work")
        shoot("progress-project-portrait")

        XCUIDevice.shared.orientation = .landscapeLeft
        let strip = app.descendants(matching: .any)["project-progress"]
        XCTAssertTrue(strip.waitForExistence(timeout: 10))
        let window = app.windows.firstMatch.frame
        XCTAssertGreaterThanOrEqual(strip.frame.minX, window.minX, "Progress overflows the landscape window")
        XCTAssertLessThanOrEqual(strip.frame.maxX, window.maxX, "Progress overflows the landscape window")
        XCTAssertGreaterThan(strip.frame.width, 200)
        shoot("progress-project-landscape")
        XCUIDevice.shared.orientation = .portrait

        // Complete the Now task from Work; every copy updates.
        app.workspaceDestination("Work").tap()
        let task = row(app, "Sketch the next screen")
        XCTAssertTrue(task.waitForExistence(timeout: 10)); task.tap()
        app.buttons["work-toggle-completion"].tap()
        XCTAssertTrue(label(app, "Status, Completed").waitForExistence(timeout: 10))
        back(app)
        let workspaceAfter = "1 next · 1 later · 50% done"
        XCTAssertEqual(chartValue(app, "work-progress"), workspaceAfter)
        app.workspaceDestination("Overview").tap()
        XCTAssertEqual(chartValue(app, "overview-progress"), workspaceAfter)
        app.workspaceDestination("Projects").tap()
        XCTAssertEqual(chartValue(app, "project-progress"), "1 later · 67% done", "The open project page kept stale progress")
    }

    func testIdeasShowRecentActivityAndAnalyticsHasNoSeparateWorkCharts() {
        let app = launch("ideas")
        let activity = app.descendants(matching: .any)["ideas-activity"]
        XCTAssertTrue(activity.waitForExistence(timeout: 20))
        XCTAssertTrue((activity.value as? String ?? "").contains("1 this week"), "\(activity.value ?? "")")
        openAnalytics(app)
        XCTAssertFalse(app.descendants(matching: .any)["analytics-work-by-type"].exists)
    }

    /// Real workspaces hold thousands of records; search must reach open and completed
    /// work, and stay available after adding work.
    func testWorkSearchFindsOpenAndCompletedWorkAfterAddingWork() {
        let app = launch()
        let add = app.buttons["New work"]
        XCTAssertTrue(add.waitForExistence(timeout: 20)); add.tap()
        let title = app.textFields["planning-title"]
        XCTAssertTrue(title.waitForExistence(timeout: 10)); title.tap(); title.typeText("Searchable addition")
        app.buttons["Save"].tap()
        XCTAssertTrue(app.navigationBars["Work"].waitForExistence(timeout: 10))
        let field = app.searchFields["Find work"]
        if !field.waitForExistence(timeout: 5) { app.swipeDown() }
        XCTAssertTrue(field.waitForExistence(timeout: 10), "Work has no search field after adding work")
        field.tap(); field.typeText("brief")
        XCTAssertTrue(row(app, "Write the brief").waitForExistence(timeout: 10), "Search does not reach completed work")
        XCTAssertFalse(row(app, "Sketch the next screen").exists)
        shoot("work-search")
    }

    private func refreshCount(_ app: XCUIApplication) -> Int {
        app.workspaceDestination("Overview").tap()
        let refresh = app.buttons["Refresh workspace index"]
        XCTAssertTrue(refresh.waitForExistence(timeout: 10))
        let value = refresh.value as? String ?? ""
        return Int(value.components(separatedBy: "refreshes ").last ?? "") ?? -1
    }

    /// A task page can be pulled down to refresh, so it can learn its task changed or was
    /// deleted on another device without leaving the page.
    func testPullingATaskPageAsksForARefresh() {
        let app = launch()
        let before = refreshCount(app)
        app.workspaceDestination("Work").tap()
        let task = row(app, "Sketch the next screen")
        XCTAssertTrue(task.waitForExistence(timeout: 10)); task.tap()
        let priority = label(app, "Priority, ")
        XCTAssertTrue(priority.waitForExistence(timeout: 10))
        let start = priority.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: 500)))
        XCTAssertTrue(label(app, "Priority, ").waitForExistence(timeout: 10))
        XCTAssertGreaterThan(refreshCount(app), before, "Pulling the task page did not refresh")
    }
}
