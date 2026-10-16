import XCTest
import BetterWorkspaceCore

/// Projects → a project: the Next Action can be completed, renamed and deleted in place,
/// and Insights / Charts render from real work records. Ingest's folder row is short.
final class ProjectQuickEditUITests: IsolatedUITestCase {

    private var toDo: URL { Self.workspaceRoot.appendingPathComponent("To Do", isDirectory: true) }

    @discardableResult
    private func task(_ id: String, _ title: String, stage: WorkItemStage, priority: WorkItemPriority = .high,
                      status: WorkItemStatus = .open, completedAt: Date? = nil) throws -> WorkItem {
        let item = WorkItem(id: id, kind: .task, title: title, status: status, stage: stage, priority: priority,
                            projectPath: "Projects/Fixture project", completedAt: completedAt,
                            url: toDo.appendingPathComponent("placeholder"))
        return try WorkItemService().create(item, in: toDo)
    }

    private func openFixtureProject() throws -> XCUIApplication {
        let database = try Database(url: Self.fixtureRoot.appendingPathComponent("test.sqlite"))
        _ = ProjectStore(database: database).register(url: Self.workspaceRoot.appendingPathComponent("Projects/Fixture project"))
        let app = isolatedApp(arguments: ["-bwStartArea", "Projects", "-bwWindowWidth", "1200", "-bwWindowHeight", "900"])
        app.launch(); requireWindow(app)
        app.radioButtons["Cards"].firstMatch.click()
        let card = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Fixture project")).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 15)); card.click()
        XCTAssertTrue(app.descendants(matching: .any)["projects.nextAction"].firstMatch.waitForExistence(timeout: 10))
        return app
    }

    private func read(_ item: WorkItem) -> String { (try? String(contentsOf: item.url)) ?? "" }

    private func waitUntil(_ timeout: TimeInterval = 10, _ condition: @escaping () -> Bool) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    func testNextActionCanBeRenamedCompletedAndDeletedInPlace() throws {
        let first = try task("qa-first", "Draft the outline", stage: .now)
        let second = try task("qa-second", "Review the draft", stage: .next)
        let app = try openFixtureProject()
        let title = app.staticTexts["projects.nextAction.title"].firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 10))
        XCTAssertEqual(title.value as? String, "Draft the outline")

        // Rename in place: double-click the title.
        title.doubleClick()
        let field = app.textFields["projects.nextAction.titleField"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeKey("a", modifierFlags: .command)
        field.typeText("Draft the outline and intro\r")
        XCTAssertTrue(waitUntil { self.read(first).contains("Draft the outline and intro") }, "The file carries the new title")
        XCTAssertTrue(app.staticTexts["Draft the outline and intro"].firstMatch.waitForExistence(timeout: 5))

        // Complete: after the short undo window the card moves on.
        app.buttons["projects.nextAction.complete"].firstMatch.click()
        XCTAssertTrue(waitUntil { self.read(first).contains("status: completed") }, "Completion is written to the record")
        XCTAssertTrue(waitUntil { title.exists && (title.value as? String) == "Review the draft" }, "The next action takes its place")
        shoot(app, "next-action-after-complete")

        // Delete: confirmed, then gone from To Do (into the test's own trash).
        // The card has just swapped in the next record; a click during that re-render
        // can be lost, so wait for the button and retry once.
        let delete = app.buttons["projects.nextAction.delete"].firstMatch
        XCTAssertTrue(waitUntil { delete.isHittable })
        delete.click()
        // Not the Touch Bar's copy of the dialog's button.
        if !app.buttons["Move to Trash"].firstMatch.waitForExistence(timeout: 5) { delete.click() }
        XCTAssertTrue(app.buttons["Move to Trash"].firstMatch.waitForExistence(timeout: 5))
        let confirm = try XCTUnwrap(panelButton(app, "Move to Trash"))
        confirm.click()
        XCTAssertTrue(waitUntil { FileManager.default.fileExists(atPath: second.url.path) == false })
        let trashed = (try? FileManager.default.contentsOfDirectory(atPath: Self.fixtureRoot.appendingPathComponent("Trash").path)) ?? []
        XCTAssertTrue(trashed.contains { $0.hasSuffix(second.url.lastPathComponent) }, "Recoverable: \(trashed)")
        XCTAssertTrue(app.staticTexts["All caught up"].firstMatch.waitForExistence(timeout: 10))
    }

    func testTaskNotesAreRenderedAsMarkdownInTheEditor() throws {
        var item = WorkItem(id: "qa-markdown", kind: .task, title: "Formatted notes", stage: .now, priority: .high,
                            projectPath: "Projects/Fixture project", url: toDo.appendingPathComponent("placeholder"))
        item.body = "## Plan\n\n- [ ] Check the **bold** step\n- [x] Finished step\n"
        _ = try WorkItemService().create(item, in: toDo)
        let app = try openFixtureProject()
        app.buttons["projects.nextAction.edit"].firstMatch.click()
        let preview = app.descendants(matching: .any)["workItem.notesPreview"].firstMatch
        XCTAssertTrue(preview.waitForExistence(timeout: 10), "Existing notes open rendered")
        XCTAssertTrue(app.descendants(matching: .any)["workItem.editNotes"].firstMatch.exists, "and one click from editing")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "value == %@", "Check the bold step")).firstMatch
                        .waitForExistence(timeout: 5), "Inline ** markers are styling, not text")
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "value CONTAINS %@", "- [ ]")).firstMatch.exists,
                       "Checklist syntax is drawn as a checkbox")
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "value CONTAINS %@", "better-workspace:")).firstMatch.exists,
                       "Front matter is not shown")
    }

    func testInsightsAndComparisonChartsRenderFromWorkRecords() throws {
        try task("qa-open-1", "Open one", stage: .now)
        try task("qa-open-2", "Open two", stage: .later, priority: .low)
        for week in 1...3 {
            try task("qa-done-\(week)", "Done \(week)", stage: .now, status: .completed,
                     completedAt: Calendar.current.date(byAdding: .day, value: -week * 7, to: Date()))
        }
        let app = try openFixtureProject()
        app.radioButtons["Insights"].firstMatch.click()
        XCTAssertTrue(app.descendants(matching: .any)["projects.insights.progress"].firstMatch.waitForExistence(timeout: 10),
                      "Progress over time renders")
        XCTAssertTrue(app.descendants(matching: .any)["projects.insights.composition"].firstMatch.exists)
        XCTAssertTrue(app.descendants(matching: .any)["projects.insights.stages"].firstMatch.exists)
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "value CONTAINS %@", "Rough estimate:")).firstMatch.exists,
                       "The estimate is collapsed so the chart remains historical")
        let estimate = app.buttons["projects.insights.estimate.toggle"].firstMatch
        XCTAssertTrue(estimate.exists); estimate.click()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "value CONTAINS %@", "Rough estimate:")).firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "value CONTAINS %@", "this is not a deadline")).firstMatch.exists)
        shoot(app, "project-insights")

        app.buttons["All Projects"].firstMatch.click()
        app.radioButtons["Charts"].firstMatch.click()
        XCTAssertTrue(app.descendants(matching: .any)["projects.charts.backlog"].firstMatch.waitForExistence(timeout: 10),
                      "Outstanding work compares projects")
        XCTAssertTrue(app.descendants(matching: .any)["projects.charts.nearDone"].firstMatch.exists,
                      "Two open and three completed records make this project 60% done")
        shoot(app, "projects-charts")
        app.radioButtons["Cards"].firstMatch.click()
    }

    func testCaptureFoldersAreShortAndRecentFirst() throws {
        let app = isolatedApp()
        app.launch(); requireWindow(app); openIngest(app)
        app.buttons["ingest.newCapture"].firstMatch.click()
        let field = app.textViews["ingest.captureField"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        let save = app.buttons["ingest.captureButton"].firstMatch
        XCTAssertTrue(save.exists)
        XCTAssertEqual(save.label, "Save to Inbox", "Reads “Inbox”; VoiceOver says where it saves")
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "title BEGINSWITH %@", "Add to")).firstMatch.exists,
                       "No “Add to …” on every button")
        let leading = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "capture.file.")).count
        XCTAssertLessThanOrEqual(leading, 5, "At most five folders up front")
        XCTAssertFalse(app.buttons["capture.file.To Watch"].exists, "Unused folders wait under More")

        field.click(); field.typeText("Recent folder check")
        let more = app.descendants(matching: .any)["capture.moreDestinations"].firstMatch
        XCTAssertTrue(more.exists)
        more.click()
        XCTAssertTrue(app.menuItems["To Watch"].firstMatch.waitForExistence(timeout: 5))
        app.menuItems["To Watch"].firstMatch.click()
        let filed = Self.workspaceRoot.appendingPathComponent("To Watch/Recent folder check.md")
        XCTAssertTrue(waitUntil { FileManager.default.fileExists(atPath: filed.path) })
        XCTAssertTrue(app.buttons["capture.file.To Watch"].firstMatch.waitForExistence(timeout: 5),
                      "A folder just used moves into the recent row")
    }

    private func shoot(_ app: XCUIApplication, _ name: String) {
        Thread.sleep(forTimeInterval: 1)
        guard ProcessInfo.processInfo.environment["BW_CAPTURE_SCREENSHOTS"] == "1" else { return }
        let shot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot()); shot.name = name; shot.lifetime = .keepAlways; add(shot)
    }
}
