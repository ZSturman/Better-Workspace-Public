import XCTest
import BetterWorkspaceCore

final class ProjectContinuationUITests: IsolatedUITestCase {
    func testActivityAndExistingNotionLinkAtMinimumWindowSize() throws {
        let db = try Database(url: Self.fixtureRoot.appendingPathComponent("test.sqlite"))
        let store = ProjectStore(database: db)
        let record = store.register(url: Self.workspaceRoot.appendingPathComponent("Projects/Fixture project"))
        store.setExternalIDs(watcherID: "history-service", documentID: nil, for: record.id)
        let source = ProjectGraphSource(id: "project-source", title: "Projects", kind: .projects,
            schema: ProjectJSON(["Name": ["id": "title", "type": "title"]]))
        let graph = try ProjectGraphStore(database: db)
        try graph.write("sources", [source])
        let title = ProjectJSON(["type": "title", "title": [["text": ["content": "Existing history page"]]]])
        let page = ProjectGraphRecord(id: "existing-page", pageID: "abcd-ef01", sourceID: source.id, kind: .projects,
            local: ["title": title], baseline: ["title": title], remote: ["title": title])
        try graph.save(page)
        let service = Self.fixtureRoot.appendingPathComponent("service")
        try FileManager.default.createDirectory(at: service, withIntermediateDirectories: true)
        func write(_ filename: String, _ data: Any) throws {
            try JSONSerialization.data(withJSONObject: ["data": data]).write(to: service.appendingPathComponent(filename))
        }
        let session: [String: Any] = ["session_id": "history-session", "start": "2026-10-21T10:00:00Z", "end": "2026-10-21T10:35:00Z", "active_seconds": 1200, "files": ["Sources/View.swift"]]
        let payload: [String: Any] = ["active_minutes": 20, "elapsed_minutes": 35, "session_count": 1, "summary": "Reviewed the sync queue.", "sessions": [session], "start": "2026-10-21T10:00:00Z", "end": "2026-10-21T10:35:00Z"]
        try write("v1_health.json", ["state": "running", "watch_roots": []])
        try write("v1_work-logs.json", [["id": "history-log", "project_id": "history-service", "project_name": "Fixture project", "date_key": "2026-10-21", "status": "prepared", "session_ids_json": "[\"history-session\"]", "payload_json": String(decoding: try JSONSerialization.data(withJSONObject: payload), as: UTF8.self)]])
        let app = isolatedApp(arguments: ["-bwServiceFixture", service.path, "-bwStartArea", "Projects", "-bwWindowWidth", "820", "-bwWindowHeight", "520"])
        app.launchArguments = ["-workspaceRootPath", Self.workspaceRoot.path, "-ingestRootPath", Self.inboxRoot.path,
            "-bwServiceFixture", service.path, "-bwStartArea", "Projects", "-bwWindowWidth", "820", "-bwWindowHeight", "520"]
        app.launch(); defer { app.terminate() }; requireForeground(app)
        if app.windows.firstMatch.waitForExistence(timeout: 3) == false {
            print("PROJECT WINDOW DIAGNOSTIC: " + app.debugDescription)
            DistributedNotificationCenter.default().postNotificationName(Notification.Name("com.zacharysturman.BetterWorkspace.test.reopen"), object: Self.fixtureRoot.path, userInfo: nil, deliverImmediately: true)
        }
        requireWindow(app)
        XCTAssertEqual(app.windows.firstMatch.frame.width, 820, accuracy: 2)
        XCTAssertEqual(app.windows.firstMatch.frame.height, 520, accuracy: 2)
        let project = app.staticTexts["Fixture project"].firstMatch
        XCTAssertTrue(project.waitForExistence(timeout: 20)); project.doubleClick()
        let activity = app.radioButtons["Activity"].firstMatch
        XCTAssertTrue(activity.waitForExistence(timeout: 10)); activity.click()
        XCTAssertTrue(app.staticTexts["1 work log · 1 recorded session"].waitForExistence(timeout: 15))
        let log = app.descendants(matching: .any)["project.history.log.history-log"].firstMatch
        XCTAssertTrue(log.waitForExistence(timeout: 10))
        app.disclosureTriangles["NSOutlineViewDisclosureButtonKey"].firstMatch.click()
        XCTAssertTrue(app.staticTexts["Active: 20m · Elapsed: 35m"].waitForExistence(timeout: 10))
        app.radioButtons["Details"].firstMatch.click()
        let link = app.buttons["project.notion.link"].firstMatch
        let details = app.scrollViews.containing(.button, identifier: "project.notion.link").firstMatch
        XCTAssertTrue(details.waitForExistence(timeout: 10))
        for _ in 0..<8 where link.frame.maxY > details.frame.maxY - 20 { details.scroll(byDeltaX: 0, deltaY: -180) }
        XCTAssertLessThan(link.frame.maxY, details.frame.maxY)
        XCTAssertTrue(link.isHittable); link.click()
        let choose = app.buttons["Link Existing history page"].firstMatch
        let hasChoice = choose.waitForExistence(timeout: 10)
        if hasChoice == false { print("NOTION LINK SHEET DIAGNOSTIC: " + app.debugDescription) }
        XCTAssertTrue(hasChoice); choose.click()
        let linked = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in store.record(id: record.id)?.notionPageID == "abcd-ef01" }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [linked], timeout: 10), .completed)
        XCTAssertEqual(try graph.records().filter { $0.pageID != nil }.count, 1)
        XCTAssertTrue(app.buttons["notion.syncNow"].firstMatch.exists)
    }
}
