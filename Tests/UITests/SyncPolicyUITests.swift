import XCTest
import BetterWorkspaceCore

/// The October 27 backlog, in miniature: a routine Notion change, a background-service
/// draft and one genuine conflict. Only the conflict is counted in orange; the routine
/// change waits in Ready and the service draft in Cleanup. Isolated launches never reach
/// Notion. See docs/SYNC_BACKLOG_2026-10-27.md.
final class SyncPolicyUITests: IsolatedUITestCase {
    private var store: ProjectGraphStore!
    private let tasks = ProjectGraphSource(id: "tasks", title: "Tasks", kind: .tasks, schema: ProjectJSON([
        "Task": ["id": "title", "type": "title"], "Details": ["id": "details", "type": "rich_text"]]))
    private let logs = ProjectGraphSource(id: "logs", title: "Work Logs", kind: .workLogs, schema: ProjectJSON([
        "Entry": ["id": "title", "type": "title"], "Summary": ["id": "details", "type": "rich_text"]]))

    private func text(_ value: String, type: String = "rich_text") -> ProjectJSON {
        ProjectJSON(["id": type == "title" ? "title" : "details", "type": type, type: [["type": "text", "text": ["content": value], "plain_text": value]]])
    }

    override func setUpWithError() throws {
        try super.setUpWithError()
        store = try ProjectGraphStore(database: Database(url: Self.fixtureRoot.appendingPathComponent("test.sqlite")))
        try store.write("sources", [tasks, logs])
        var conflict = ProjectGraphRecord(id: "conflict", pageID: "p-conflict", sourceID: "tasks", kind: .tasks,
            local: ["title": text("Shared task", type: "title"), "details": text("local words")],
            baseline: ["title": text("Shared task", type: "title"), "details": text("base")],
            remote: ["title": text("Shared task", type: "title"), "details": text("notion words")])
        conflict.editedAt = Date()
        // Written to Notion by the work-log writer: only Notion changed.
        let routine = ProjectGraphRecord(id: "routine", pageID: "p-routine", sourceID: "logs", kind: .workLogs,
            local: ["title": text("Daily session", type: "title"), "details": text("before")],
            baseline: ["title": text("Daily session", type: "title"), "details": text("before")],
            remote: ["title": text("Daily session", type: "title"), "details": text("written in Notion")])
        // Observed by the background service, never sent: kept by the service.
        var service = ProjectGraphRecord(id: "service", sourceID: "logs", kind: .workLogs,
            local: ["title": text("Better Workspace · 2026-10-27", type: "title")])
        service.serviceRecordID = "day-27"
        for record in [conflict, routine, service] { try store.save(record) }
    }

    func testOnlyAGenuineDecisionIsCountedInOrange() throws {
        let app = isolatedApp(arguments: ["-bwStartArea", "Overview", "-bwWindowWidth", "820", "-bwWindowHeight", "720"])
        app.launch(); requireWindow(app)
        let indicator = app.descendants(matching: .any)["projects.sync"].firstMatch
        XCTAssertTrue(indicator.waitForExistence(timeout: 15))
        XCTAssertEqual(indicator.value as? String, "1 need you, 1 waiting", "Not 3: the routine change and the service draft are not decisions")
        indicator.click()
        XCTAssertTrue(app.staticTexts["sync.status"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["sync.status"].firstMatch.value as? String, "1 change to review")
        let policy = app.staticTexts["sync.policy"].firstMatch
        XCTAssertTrue((policy.value as? String ?? policy.label).contains("Notion changes wait until you receive them"))

        app.radioButtons["Ready"].firstMatch.click()
        XCTAssertTrue(app.descendants(matching: .any)["sync.row.Daily session"].firstMatch.waitForExistence(timeout: 5))
        app.radioButtons["Cleanup"].firstMatch.click()
        XCTAssertTrue(app.descendants(matching: .any)["sync.row.Better Workspace · 2026-10-27"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertNotNil(try store.record(id: "service"), "Listed, not removed")

        // Turning on automatic receiving changes the stated policy, not the count of decisions.
        // The toolbar's context menu holds the same toggles; use the open More menu's.
        let more = app.descendants(matching: .any)["sync.more"].firstMatch
        more.click()
        let receive = more.menuItems["sync.policy.receive"].firstMatch
        XCTAssertTrue(receive.waitForExistence(timeout: 3), "\(app.menuItems.matching(identifier: "sync.policy.receive").count) receive toggles")
        receive.click()
        let stored = expectation(for: NSPredicate { _, _ in
            (try? self.store.read(ProjectSyncTriage.Policy.key, as: ProjectSyncTriage.Policy.self))??.receiveNotionChanges == true
        }, evaluatedWith: nil)
        let feedback = app.staticTexts["sync.feedback"].firstMatch
        XCTAssertTrue(feedback.waitForExistence(timeout: 5), "The change is confirmed")
        XCTAssertFalse((feedback.value as? String ?? feedback.label).contains("could not be saved"), feedback.value as? String ?? feedback.label)
        let restated = expectation(for: NSPredicate { _, _ in (policy.value as? String ?? policy.label).contains("received automatically") }, evaluatedWith: nil)
        wait(for: [restated], timeout: 5)
        wait(for: [stored], timeout: 5)
        XCTAssertEqual(indicator.value as? String, "1 need you, 1 waiting")
    }
}
