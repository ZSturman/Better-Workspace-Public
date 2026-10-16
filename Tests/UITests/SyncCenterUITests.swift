import XCTest
import BetterWorkspaceCore

/// The Sync Center on an isolated fixture. Isolated launches can never reach Notion
/// (`NotionClient` refuses), so these exercise everything up to the network, and show
/// that a failed send leaves local work intact.
final class SyncCenterUITests: IsolatedUITestCase {
    private var store: ProjectGraphStore!
    private let tasks = ProjectGraphSource(id: "tasks", title: "Tasks", kind: .tasks, schema: ProjectJSON([
        "Task": ["id": "title", "type": "title"], "Details": ["id": "details", "type": "rich_text"]]))

    private func text(_ value: String, type: String = "rich_text") -> ProjectJSON {
        ProjectJSON(["id": type == "title" ? "title" : "details", "type": type, type: [["type": "text", "text": ["content": value], "plain_text": value]]])
    }

    override func setUpWithError() throws {
        try super.setUpWithError()
        store = try ProjectGraphStore(database: Database(url: Self.fixtureRoot.appendingPathComponent("test.sqlite")))
        try store.write("sources", [tasks])
        // A conflict with no edit times: needs a person.
        var conflict = ProjectGraphRecord(id: "conflict", pageID: "p-conflict", sourceID: "tasks", kind: .tasks,
            local: ["title": text("Shared task", type: "title"), "details": text("local words")],
            baseline: ["title": text("Shared task", type: "title"), "details": text("base")],
            remote: ["title": text("Shared task", type: "title"), "details": text("notion words")])
        conflict.editedAt = Date()
        // A Notion record not yet brought here: ready.
        let incoming = ProjectGraphRecord(id: "incoming", pageID: "p-incoming", sourceID: "tasks", kind: .tasks,
            remote: ["title": text("New in Notion", type: "title")])
        // A draft whose file is gone: cleanup.
        var orphan = ProjectGraphRecord(id: "orphan", sourceID: "tasks", kind: .tasks, local: ["title": text("Orphaned draft", type: "title")])
        orphan.localPath = Self.fixtureRoot.appendingPathComponent("gone.bw.md").path
        // An edit made here: ready to send.
        var edited = ProjectGraphRecord(id: "edited", pageID: "p-edited", sourceID: "tasks", kind: .tasks,
            local: ["title": text("Edited here", type: "title"), "details": text("new")],
            baseline: ["title": text("Edited here", type: "title"), "details": text("old")],
            remote: ["title": text("Edited here", type: "title"), "details": text("old")])
        edited.localFieldEditedAt = ["details": Date()]
        for record in [conflict, incoming, orphan, edited] { try store.save(record) }
    }

    private func launch() -> XCUIApplication {
        let app = isolatedApp(arguments: ["-bwStartArea", "Overview", "-bwWindowWidth", "1100", "-bwWindowHeight", "720"])
        app.launch(); requireWindow(app)
        return app
    }

    private func openSyncCenter(_ app: XCUIApplication) {
        let indicator = app.descendants(matching: .any)["projects.sync"].firstMatch
        XCTAssertTrue(indicator.waitForExistence(timeout: 15))
        XCTAssertEqual(indicator.value as? String, "1 need you, 2 waiting")
        indicator.click()
        XCTAssertTrue(app.staticTexts["sync.status"].firstMatch.waitForExistence(timeout: 5))
    }

    private func shoot(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot()); shot.name = name; shot.lifetime = .keepAlways; add(shot)
    }

    func testManualByDefaultWithSectionsDeferAndCleanup() throws {
        let app = launch()
        openSyncCenter(app)
        XCTAssertEqual(app.staticTexts["sync.status"].firstMatch.value as? String, "1 need you")
        let manual = app.radioButtons["Manual"].firstMatch
        XCTAssertEqual(manual.value as? Int, 1, "Automatic sync is off until turned on")
        shoot(app, "sync-center-needs-you")

        // One conflict needs a choice: both values shown, nothing chosen for it.
        app.descendants(matching: .any)["sync.row.Shared task"].firstMatch.click()
        XCTAssertTrue(app.staticTexts["notion words"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["local words"].firstMatch.exists)
        XCTAssertFalse(app.buttons["sync.detail.apply"].firstMatch.isEnabled, "Apply waits for a choice")
        shoot(app, "sync-center-conflict")

        // Decide later: it leaves Needs You until it changes.
        app.buttons["sync.detail.later"].firstMatch.click()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "value == %@", "Everything is in sync")).firstMatch.exists
                      || app.staticTexts.matching(NSPredicate(format: "value CONTAINS %@", "ready to sync")).firstMatch.waitForExistence(timeout: 5))

        // Cleanup: the orphaned draft is discarded; nothing in Notion is touched.
        app.radioButtons["Cleanup"].firstMatch.click()
        app.descendants(matching: .any)["sync.row.Orphaned draft"].firstMatch.click()
        app.buttons["Discard Draft"].firstMatch.click()
        app.buttons["sync.summary.confirm"].firstMatch.click()
        let gone = expectation(for: NSPredicate { _, _ in (try? self.store.record(id: "orphan")) == nil }, evaluatedWith: nil)
        wait(for: [gone], timeout: 5)
        XCTAssertNotNil(try store.record(id: "conflict"), "Only the draft is forgotten")
        shoot(app, "sync-center-cleanup")
    }

    func testBulkSummaryAndAFailedSendKeepsLocalWork() throws {
        let app = launch()
        openSyncCenter(app)
        app.radioButtons["Ready"].firstMatch.click()
        let safe = app.buttons["sync.applySafe"].firstMatch
        XCTAssertTrue(safe.waitForExistence(timeout: 5))
        safe.click()
        let summary = app.descendants(matching: .any)["sync.summary"].firstMatch
        XCTAssertTrue(summary.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Records received"].firstMatch.exists)
        shoot(app, "sync-center-bulk-summary")
        app.buttons["sync.summary.confirm"].firstMatch.click()
        // Notion cannot be reached from an isolated run: nothing is lost or half-applied.
        let settled = expectation(for: NSPredicate { _, _ in
            (try? self.store.read(ProjectAutoSync.failuresKey, as: [String: ProjectAutoSyncPlanner.Failure].self))?.isEmpty == false
        }, evaluatedWith: nil)
        wait(for: [settled], timeout: 15)
        let edited = try XCTUnwrap(store.record(id: "edited"))
        XCTAssertEqual(edited.local["details"]?.display, "new", "The local edit is intact")
        XCTAssertEqual(edited.baseline["details"]?.display, "old", "and still pending")
        let feedback = app.staticTexts["sync.feedback"].firstMatch
        XCTAssertTrue(feedback.waitForExistence(timeout: 5))
        XCTAssertTrue((feedback.value as? String ?? feedback.label).contains("failed"))
        shoot(app, "sync-feedback-failed")
    }

    func testMergePreviewAndScopedConfirmationAtNarrowWidth() throws {
        let schema = ProjectJSON([
            "Task": ["id": "title", "type": "title"],
            "Details": ["id": "details", "type": "rich_text"],
            "Tags": ["id": "tags", "type": "multi_select"]])
        try store.write("sources", [ProjectGraphSource(id: "tasks", title: "Tasks", kind: .tasks, schema: schema)])
        func tags(_ values: [String]) -> ProjectJSON {
            ProjectJSON(["id": "tags", "type": "multi_select", "multi_select": values.map { ["name": $0] }])
        }
        var record = try XCTUnwrap(store.record(id: "conflict"))
        record.local["tags"] = tags(["shared", "local tag"])
        record.remote["tags"] = tags(["shared", "notion tag"])
        record.baseline["tags"] = tags(["shared"])
        try store.save(record)
        let app = isolatedApp(arguments: ["-bwStartArea", "Overview", "-bwWindowWidth", "820", "-bwWindowHeight", "720"])
        app.launch(); requireWindow(app)
        openSyncCenter(app)
        app.descendants(matching: .any)["sync.row.Shared task"].firstMatch.click()
        XCTAssertTrue(app.descendants(matching: .any)["sync.choose.Tags"].firstMatch.waitForExistence(timeout: 5))
        let preview = app.staticTexts["sync.mergePreview.Tags"].firstMatch
        XCTAssertTrue(preview.exists)
        let rendered = preview.value as? String ?? preview.label
        XCTAssertTrue(rendered.contains("local tag"), rendered); XCTAssertTrue(rendered.contains("notion tag"), rendered)
        XCTAssertFalse(app.buttons["sync.detail.apply"].firstMatch.isEnabled, "The text conflict still needs a choice")
        let merge = app.buttons["sync.detail.merge"].firstMatch
        XCTAssertTrue(merge.isHittable)
        shoot(app, "sync-merge-preview-820")
        merge.click()
        XCTAssertTrue(app.staticTexts["Fields merged (keep values from both sides)"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Notion values replaced"].firstMatch.exists)
        shoot(app, "sync-merge-confirmation-820")
        app.buttons["Cancel"].firstMatch.click()
        XCTAssertEqual(try store.record(id: record.id), record, "Cancel leaves all fields unchanged")
    }

    func testCompletedSyncFeedbackSurvivesRelaunch() throws {
        var report = ProjectAutoSync.Report()
        report.sent = ["edited"]; report.received = ["incoming"]; report.mergedFields = 2; report.finishedAt = Date()
        try store.write(ProjectAutoSync.actionReportKey, report)
        let app = isolatedApp(arguments: ["-bwStartArea", "Overview", "-bwWindowWidth", "820", "-bwWindowHeight", "720"])
        app.launch(); requireWindow(app); openSyncCenter(app)
        let feedback = app.staticTexts["sync.feedback"].firstMatch
        XCTAssertTrue(feedback.waitForExistence(timeout: 5))
        let message = feedback.value as? String ?? feedback.label
        XCTAssertTrue(message.contains("1 sent, 1 received"), message)
        XCTAssertTrue(message.contains("2 fields merged"), message)
        shoot(app, "sync-feedback-complete-820")
    }

    func testNoChangeCheckKeepsLastAppliedCountsVisible() throws {
        var changed = ProjectAutoSync.Report()
        changed.sent = ["edited"]; changed.mergedFields = 2; changed.finishedAt = Date().addingTimeInterval(-60)
        var checked = ProjectAutoSync.Report(); checked.finishedAt = Date()
        try store.write(ProjectAutoSync.lastChangesKey, changed)
        try store.write(ProjectAutoSync.actionReportKey, checked)
        let app = isolatedApp(arguments: ["-bwStartArea", "Overview", "-bwWindowWidth", "820", "-bwWindowHeight", "720"])
        app.launch(); requireWindow(app); openSyncCenter(app)
        let lastChanges = app.staticTexts["sync.lastChanges"].firstMatch
        XCTAssertTrue(lastChanges.waitForExistence(timeout: 5))
        XCTAssertTrue((lastChanges.value as? String ?? lastChanges.label).contains("2 fields merged"))
        shoot(app, "sync-feedback-last-changes-820")
    }

    func testSwitchingModesIsRemembered() throws {
        var app = launch()
        openSyncCenter(app)
        app.radioButtons["Automatic"].firstMatch.click()
        XCTAssertEqual(app.radioButtons["Automatic"].firstMatch.value as? Int, 1)
        let feedback = app.staticTexts["sync.feedback"].firstMatch
        XCTAssertTrue(feedback.waitForExistence(timeout: 5))
        XCTAssertTrue((feedback.value as? String ?? feedback.label).contains("Automatic sync enabled"))
        app.terminate(); _ = app.wait(for: .notRunning, timeout: 10)
        app = launch()
        openSyncCenter(app)
        XCTAssertEqual(app.radioButtons["Automatic"].firstMatch.value as? Int, 1, "The choice survives a relaunch")
        app.radioButtons["Manual"].firstMatch.click()
        XCTAssertEqual(app.radioButtons["Manual"].firstMatch.value as? Int, 1)
        XCTAssertNotNil(try store.record(id: "edited")?.local["details"], "Turning automatic sync off loses nothing pending")
    }
}
