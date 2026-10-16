import XCTest
@testable import BetterWorkspaceCore

/// A small in-memory Notion: one data source, pages, and the endpoints the client uses.
/// Every request is counted; failures can be injected per method.
private final class FakeNotion: URLProtocol {
    static let lock = NSLock()
    nonisolated(unsafe) static var server = Server()

    struct Server {
        var droppedFields = Set<String>()
        var schema: [String: [String: Any]] = [:]   // property name -> definition (with "id")
        var pages: [String: [String: Any]] = [:]    // page id -> page JSON
        var requests: [String] = []
        var failures: [String: Int] = [:]           // "PATCH" / "POST" / "GET" -> remaining failures
        var unreachable = false
        var clock = Date(timeIntervalSince1970: 1_800_000_000)
        mutating func tick() -> String { clock.addTimeInterval(60); return ISO8601DateFormatter().string(from: clock) }
    }

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "api.notion.com" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    static func reset(_ schema: [String: [String: Any]]) { lock.lock(); server = Server(); server.schema = schema; lock.unlock() }
    static func with<T>(_ body: (inout Server) -> T) -> T { lock.lock(); defer { lock.unlock() }; return body(&server) }

    private static func body(_ request: URLRequest) -> [String: Any] {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable { let n = stream.read(&buffer, maxLength: buffer.count); if n <= 0 { break }; data.append(buffer, count: n) }
        }
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    override func startLoading() {
        let method = request.httpMethod ?? "GET"
        let path = request.url!.path.replacingOccurrences(of: "/v1/", with: "")
        let sent = Self.body(request)
        let (status, json): (Int, Any) = Self.with { server in
            server.requests.append("\(method) \(path)")
            if server.unreachable { return (-1, [:]) }
            if let remaining = server.failures["\(method) \(path)"] ?? server.failures[method], remaining > 0 {
                if server.failures["\(method) \(path)"] != nil { server.failures["\(method) \(path)"] = remaining - 1 } else { server.failures[method] = remaining - 1 }
                return (503, ["object": "error", "message": "Service unavailable"])
            }
            func propertyName(_ key: String) -> String? {
                server.schema.first { $0.key == key || ($0.value["id"] as? String) == key }?.key
            }
            func apply(_ properties: [String: Any], to page: inout [String: Any]) {
                var current = page["properties"] as? [String: Any] ?? [:]
                for (key, value) in properties {
                    guard let name = propertyName(key), let definition = server.schema[name], var envelope = value as? [String: Any] else { continue }
                    envelope["id"] = definition["id"]; envelope["type"] = definition["type"]
                    if server.droppedFields.contains(key), let type = definition["type"] as? String { envelope[type] = [] }
                    current[name] = envelope
                }
                page["properties"] = current
                page["last_edited_time"] = server.tick()
            }
            switch (method, path) {
            case ("GET", "users/me"): return (200, ["bot": ["workspace_name": "Fixture"]])
            case ("GET", "data_sources/tasks"):
                return (200, ["id": "tasks", "title": [["plain_text": "Tasks"]], "properties": server.schema])
            case ("POST", "data_sources/tasks/query"):
                return (200, ["results": Array(server.pages.values), "has_more": false])
            case ("POST", "pages"):
                let id = "page-\(server.pages.count + 1)"
                var page: [String: Any] = ["id": id, "in_trash": false, "properties": [:]]
                apply(sent["properties"] as? [String: Any] ?? [:], to: &page)
                server.pages[id] = page
                return (200, page)
            default:
                if path.hasPrefix("pages/") {
                    let id = String(path.dropFirst(6))
                    guard var page = server.pages[id] else { return (404, ["object": "error", "message": "Not found"]) }
                    if method == "PATCH" {
                        apply(sent["properties"] as? [String: Any] ?? [:], to: &page)
                        if let trash = sent["in_trash"] as? Bool { page["in_trash"] = trash }
                        server.pages[id] = page
                    }
                    return (200, page)
                }
                return (404, ["object": "error", "message": "Unhandled \(method) \(path)"])
            }
        }
        if status < 0 { client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)); return }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: json))
        client?.urlProtocolDidFinishLoading(self)
    }
}

final class ProjectAutoSyncTests: XCTestCase {
    private let schema: [String: [String: Any]] = [
        "Task": ["id": "title", "type": "title", "title": [:]],
        "Details": ["id": "details", "type": "rich_text", "rich_text": [:]],
        "Status": ["id": "status", "type": "select", "select": ["options": [["name": "Plan"], ["name": "Done"]]]],
        "Tags": ["id": "tags", "type": "multi_select", "multi_select": [:]],
        "Links": ["id": "links", "type": "relation", "relation": ["data_source_id": "tasks"]],
        "Score": ["id": "score", "type": "formula", "formula": [:]],
    ]
    private var store: ProjectGraphStore!
    private var client: NotionClient!
    private var source: ProjectGraphSource { ProjectGraphSource(id: "tasks", title: "Tasks", kind: .tasks, schema: ProjectJSON(schema)) }

    override func setUpWithError() throws {
        FakeNotion.reset(schema)
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [FakeNotion.self]
        client = NotionClient(token: "fixture", session: URLSession(configuration: config))
        store = try ProjectGraphStore(database: Database(inMemory: true))
        try store.write("sources", [source])
    }

    // MARK: Fixture helpers

    private func rich(_ text: String, type: String = "rich_text") -> [String: Any] {
        ["type": type, type: text.isEmpty ? [] : [["type": "text", "text": ["content": text], "plain_text": text]]]
    }
    private func select(_ name: String) -> [String: Any] { ["type": "select", "select": name.isEmpty ? NSNull() : ["name": name]] }
    /// A page in Notion and its record here, already in step.
    @discardableResult
    private func synced(_ id: String, title: String, details: String = "", status: String = "Plan") throws -> ProjectGraphRecord {
        var page: [String: Any] = ["id": id, "in_trash": false, "last_edited_time": "2027-01-15T00:00:00.000Z", "properties": [:]]
        var properties: [String: Any] = [:]
        for (name, value) in [("Task", rich(title, type: "title")), ("Details", rich(details)), ("Status", select(status))] {
            var envelope = value; envelope["id"] = schema[name]!["id"]; properties[name] = envelope
        }
        page["properties"] = properties
        FakeNotion.with { $0.pages[id] = page }
        try store.ingest(pages: [ProjectJSON(page)], source: source)
        try store.acceptIncoming(try XCTUnwrap(store.record(pageID: id)).id)
        return try XCTUnwrap(store.record(pageID: id))
    }
    private func notionEdit(_ id: String, _ name: String, _ value: [String: Any]) {
        FakeNotion.with { server in
            var page = server.pages[id]!; var properties = page["properties"] as! [String: Any]
            var envelope = value; envelope["id"] = server.schema[name]!["id"]; properties[name] = envelope
            page["properties"] = properties; page["last_edited_time"] = server.tick(); server.pages[id] = page
        }
    }
    private func localEdit(_ record: ProjectGraphRecord, _ name: String, _ value: ProjectJSON, at date: Date? = Date()) throws {
        var current = try XCTUnwrap(store.record(id: record.id))
        current.set(name, value: value, source: source, changedAt: date)
        try store.save(current)
    }
    private func run(at now: Date = Date()) async throws -> ProjectAutoSync.Report {
        try await ProjectAutoSync(store: store, client: client, fileExists: { _ in true }).run(seeds: [.tasks: "tasks"], now: now)
    }
    private func notionValue(_ id: String, _ name: String) -> String {
        FakeNotion.with { server in ProjectJSON((server.pages[id]!["properties"] as! [String: Any])[name]!).display }
    }
    private func localValue(_ record: ProjectGraphRecord, _ name: String) throws -> String {
        try XCTUnwrap(store.record(id: record.id)).value(name, source: source).display
    }
    private var writes: [String] { FakeNotion.with { $0.requests.filter { $0.hasPrefix("PATCH") || $0.hasPrefix("POST pages") } } }

    // MARK: Two-way

    func testNotionEditsAreReceivedAndLocalEditsSent() async throws {
        let first = try synced("p1", title: "Wire the buzzer", details: "before")
        let second = try synced("p2", title: "Calibrate")
        notionEdit("p1", "Details", rich("changed in Notion"))
        try localEdit(second, "Task", ProjectJSON([["type": "text", "text": ["content": "Calibrate the sensor"]]]))
        let report = try await run()
        XCTAssertEqual(try localValue(first, "Details"), "changed in Notion")
        XCTAssertEqual(notionValue("p2", "Task"), "Calibrate the sensor")
        XCTAssertEqual(Set(report.received), [first.id]); XCTAssertEqual(Set(report.sent), [second.id])
        XCTAssertEqual(writes, ["PATCH pages/p2"], "Only the record edited here is written")
        XCTAssertTrue(try ProjectSyncTriage.items(records: store.records(), sources: [source]).isEmpty, "Everything is in step afterwards")
    }

    func testARunWithNothingChangedWritesNothing() async throws {
        try synced("p1", title: "Quiet")
        _ = try await run(); _ = try await run()
        XCTAssertTrue(writes.isEmpty)
    }

    func testANewRecordIsCreatedOnceAcrossRepeatedRuns() async throws {
        var draft = ProjectGraphRecord(sourceID: "tasks", kind: .tasks)
        draft.set("Task", value: ProjectJSON([["type": "text", "text": ["content": "Made here"]]]), source: source)
        try store.save(draft)
        _ = try await run(); _ = try await run(); _ = try await run()
        XCTAssertEqual(writes.filter { $0 == "POST pages" }.count, 1)
        XCTAssertNotNil(try store.record(id: draft.id)?.pageID)
    }

    // MARK: Never silently

    func testAnUndatedConflictWaitsAndNeitherSideIsOverwritten() async throws {
        let record = try synced("p1", title: "Shared", details: "base")
        notionEdit("p1", "Details", rich("notion version"))
        try localEdit(record, "Details", ProjectJSON([["type": "text", "text": ["content": "local version"]]]), at: nil)
        let report = try await run()
        XCTAssertEqual(report.attention, 1)
        XCTAssertEqual(notionValue("p1", "Details"), "notion version")
        XCTAssertEqual(try localValue(record, "Details"), "local version")
        XCTAssertTrue(writes.isEmpty)
    }

    func testADatedConflictIsReconcilableButStillWaitsForAPerson() async throws {
        let record = try synced("p1", title: "Shared", details: "base")
        notionEdit("p1", "Details", rich("notion version"))
        try localEdit(record, "Details", ProjectJSON([["type": "text", "text": ["content": "local version"]]]), at: Date(timeIntervalSince1970: 1_900_000_000))
        _ = try await run()
        let item = try XCTUnwrap(ProjectSyncTriage.items(records: store.records(), sources: [source]).first)
        XCTAssertEqual(item.bucket, .reconcilable)
        XCTAssertEqual(item.fields.first?.recommended, .local, "The later edit is recommended")
        XCTAssertTrue(writes.isEmpty, "Conflicts are never resolved by automatic sync")
    }

    func testSeededMetadataNeverOverwritesNotionAndFillsWait() async throws {
        let record = try synced("p1", title: "Seeded", details: "Notion's text", status: "")
        try localEdit(record, "Details", ProjectJSON([["type": "text", "text": ["content": "older metadata"]]]), at: nil)
        try localEdit(record, "Status", ProjectJSON(["name": "Plan"]), at: nil)
        let report = try await run()
        XCTAssertEqual(report.attention, 1)
        XCTAssertTrue(writes.isEmpty)
        let fields = try XCTUnwrap(ProjectSyncTriage.items(records: store.records(), sources: [source]).first).fields
        XCTAssertEqual(fields.first { $0.name == "Details" }?.bucket, .decision)
        XCTAssertEqual(fields.first { $0.name == "Status" }?.bucket, .reconcilable, "Notion had no value")
    }

    func testArchivedInNotionNeedsADecision() async throws {
        let record = try synced("p1", title: "Gone in Notion")
        FakeNotion.with { $0.pages["p1"]!["in_trash"] = true; $0.pages["p1"]!["last_edited_time"] = $0.tick() }
        let report = try await run()
        XCTAssertEqual(report.attention, 1)
        let item = try XCTUnwrap(ProjectSyncTriage.items(records: store.records(), sources: [source]).first { $0.id == record.id })
        XCTAssertEqual(item.category, .archive)
        XCTAssertNotEqual(try store.record(id: record.id)?.acknowledgedArchived, true, "Not accepted on its own")
    }

    func testEqualSpellingsSettleWithoutWritingEitherSide() async throws {
        let record = try synced("p1", title: "Case", status: "Done")
        notionEdit("p1", "Status", select("Plan"))
        try localEdit(record, "Status", ProjectJSON(["name": "plan"]), at: nil)
        _ = try await run()
        XCTAssertTrue(writes.isEmpty)
        XCTAssertEqual(try localValue(record, "Status"), "Plan")
        XCTAssertTrue(try ProjectSyncTriage.items(records: store.records(), sources: [source]).isEmpty)
    }

    func testDeferredDifferenceIsSkippedUntilItChanges() async throws {
        let record = try synced("p1", title: "Later", details: "a")
        try localEdit(record, "Details", ProjectJSON([["type": "text", "text": ["content": "b"]]]))
        let item = try XCTUnwrap(ProjectSyncTriage.items(records: store.records(), sources: [source]).first)
        try store.deferDifference(item)
        let report = try await run()
        XCTAssertEqual(report.deferred, 1); XCTAssertTrue(writes.isEmpty)
        try localEdit(record, "Details", ProjectJSON([["type": "text", "text": ["content": "c"]]]))
        _ = try await run()
        XCTAssertEqual(notionValue("p1", "Details"), "c", "A new change ends the deferral")
    }

    // MARK: Failures

    func testATransientFailureBacksOffWithoutHoldingUpOtherRecords() async throws {
        let failing = try synced("p1", title: "One")
        let fine = try synced("p2", title: "Two")
        for record in [failing, fine] { try localEdit(record, "Details", ProjectJSON([["type": "text", "text": ["content": "edited"]]])) }
        // p1 stays down through the client's own retries; p2 is unaffected.
        FakeNotion.with { $0.failures["PATCH pages/p1"] = 1000 }
        let now = Date()
        let report = try await run(at: now)
        XCTAssertEqual(report.sent.count, 1)
        let failedID = try XCTUnwrap(report.failed.keys.first)
        let failure = try XCTUnwrap(store.read(ProjectAutoSync.failuresKey, as: [String: ProjectAutoSyncPlanner.Failure].self)?[failedID])
        XCTAssertEqual(failure.attempts, 1)
        XCTAssertEqual(failure.nextAttempt.timeIntervalSince(now), 60, accuracy: 1)
        FakeNotion.with { $0.failures["PATCH pages/p1"] = 0 }
        let before = writes.count
        let early = try await run(at: now.addingTimeInterval(30))
        XCTAssertEqual(early.waiting, 1); XCTAssertEqual(writes.count, before, "No retry before its time")
        let later = try await run(at: now.addingTimeInterval(120))
        XCTAssertEqual(later.sent, [failedID])
        XCTAssertNil(try store.read(ProjectAutoSync.failuresKey, as: [String: ProjectAutoSyncPlanner.Failure].self)?[failedID])
        XCTAssertEqual(notionValue("p1", "Details"), "edited"); XCTAssertEqual(notionValue("p2", "Details"), "edited")
    }

    func testOfflineEditsStayPendingAndIntact() async throws {
        let record = try synced("p1", title: "Offline", details: "before")
        try localEdit(record, "Details", ProjectJSON([["type": "text", "text": ["content": "written offline"]]]))
        FakeNotion.with { $0.unreachable = true }
        let report = try await run()
        XCTAssertFalse(report.readFailures.isEmpty)
        XCTAssertEqual(try localValue(record, "Details"), "written offline")
        XCTAssertEqual(report.failed.count, 1)
        FakeNotion.with { $0.unreachable = false }
        _ = try await run(at: Date().addingTimeInterval(120))
        XCTAssertEqual(notionValue("p1", "Details"), "written offline")
    }

    func testRepeatedFailuresAskForAttention() {
        let record = ProjectGraphRecord(pageID: "p", sourceID: "tasks", kind: .tasks)
        let item = ProjectSyncTriage.Item(record: record, category: .localEdit, bucket: .automatic, fields: [], projectIDs: [], reason: "")
        let failure = ProjectAutoSyncPlanner.Failure(attempts: 4, nextAttempt: .distantPast, message: "Forbidden")
        XCTAssertEqual(ProjectAutoSyncPlanner.plan([item], deferred: [:], failures: [record.id: failure]).attention.count, 1)
        XCTAssertEqual(ProjectAutoSyncPlanner.backoff(attempts: 9), 7200)
    }

    // MARK: Large backlogs and what never moves on its own

    func testALargeBacklogOfNotionRecordsIsReceivedInOneBatch() async throws {
        FakeNotion.with { server in
            for index in 0..<300 {
                server.pages["n\(index)"] = ["id": "n\(index)", "in_trash": false, "last_edited_time": "2027-01-15T00:00:00.000Z",
                                             "properties": ["Task": ["id": "title", "type": "title", "title": [["type": "text", "text": ["content": "Imported \(index)"], "plain_text": "Imported \(index)"]]]]]
            }
        }
        let report = try await run()
        XCTAssertEqual(report.received.count, 300)
        XCTAssertLessThan(FakeNotion.with { $0.requests.count }, 20, "One query per read, not one request per page")
        XCTAssertTrue(writes.isEmpty)
    }

    func testServiceRecordsUploadsAndOrphansNeverMoveAutomatically() async throws {
        var service = ProjectGraphRecord(sourceID: "tasks", kind: .workLogs); service.serviceRecordID = "worklog-1"
        service.set("Task", value: ProjectJSON([["type": "text", "text": ["content": "Daily log"]]]), source: source)
        var upload = ProjectGraphRecord(sourceID: "tasks", kind: .tasks)
        upload.set("Task", value: ProjectJSON([["type": "text", "text": ["content": "Screenshot"]]]), source: source)
        upload.pendingUploads = [ProjectPendingUpload(propertyID: "files", url: URL(fileURLWithPath: "/tmp/x.png"), contentType: "image/png", byteCount: 10, modifiedAt: nil)]
        var orphan = ProjectGraphRecord(sourceID: "tasks", kind: .tasks); orphan.localPath = "/gone.bw.md"
        orphan.set("Task", value: ProjectJSON([["type": "text", "text": ["content": "Orphan"]]]), source: source)
        for record in [service, upload, orphan] { try store.save(record) }
        let items = ProjectSyncTriage.items(records: try store.records(), sources: [source], fileExists: { $0 != "/gone.bw.md" })
        XCTAssertEqual(items.first { $0.id == service.id }?.category, .serviceRecord)
        XCTAssertEqual(items.first { $0.id == upload.id }?.category, .upload)
        XCTAssertEqual(items.first { $0.id == orphan.id }?.bucket, .obsolete)
        let plan = ProjectAutoSyncPlanner.plan(items, deferred: [:], failures: [:])
        XCTAssertTrue(plan.push.isEmpty); XCTAssertTrue(plan.pull.isEmpty)
    }

    // MARK: A person's choices (Sync Center)

    private func item(_ record: ProjectGraphRecord) throws -> ProjectSyncTriage.Item {
        try XCTUnwrap(ProjectSyncTriage.items(records: store.records(), sources: [source]).first { $0.id == record.id })
    }
    private func apply(_ items: [ProjectSyncTriage.Item], _ choices: [String: [String: ProjectSyncTriage.Side]]) async throws -> ProjectAutoSync.Report {
        try await ProjectAutoSync(store: store, client: client, fileExists: { _ in true }).apply(items, choices: choices)
    }

    func testChoosingNotionSettlesAConflictWithoutWriting() async throws {
        let record = try synced("p1", title: "Shared", details: "base")
        notionEdit("p1", "Details", rich("notion version"))
        try store.ingest(pages: [ProjectJSON(FakeNotion.with { $0.pages["p1"]! })], source: source)
        try localEdit(record, "Details", ProjectJSON([["type": "text", "text": ["content": "local version"]]]), at: nil)
        _ = try await apply([try item(record)], [record.id: ["details": .notion]])
        XCTAssertTrue(writes.isEmpty)
        XCTAssertEqual(try localValue(record, "Details"), "notion version")
        XCTAssertTrue(try ProjectSyncTriage.items(records: store.records(), sources: [source]).isEmpty)
    }

    func testChoosingThisMacSendsOnlyThatField() async throws {
        let record = try synced("p1", title: "Shared", details: "base")
        notionEdit("p1", "Details", rich("notion version"))
        notionEdit("p1", "Status", select("Done"))
        try store.ingest(pages: [ProjectJSON(FakeNotion.with { $0.pages["p1"]! })], source: source)
        try localEdit(record, "Details", ProjectJSON([["type": "text", "text": ["content": "local version"]]]), at: nil)
        _ = try await apply([try item(record)], [record.id: ["details": .local]])
        XCTAssertEqual(notionValue("p1", "Details"), "local version")
        XCTAssertEqual(try localValue(record, "Status"), "Done", "Notion's other change is taken")
        XCTAssertEqual(writes, ["PATCH pages/p1"])
    }

    func testBulkChoicesApplyPerRecord() async throws {
        let keepMine = try synced("p1", title: "One", details: "base")
        let takeTheirs = try synced("p2", title: "Two", details: "base")
        for (id, record) in [("p1", keepMine), ("p2", takeTheirs)] {
            notionEdit(id, "Details", rich("notion"))
            try store.ingest(pages: [ProjectJSON(FakeNotion.with { $0.pages[id]! })], source: source)
            try localEdit(record, "Details", ProjectJSON([["type": "text", "text": ["content": "mine"]]]), at: nil)
        }
        let report = try await apply([try item(keepMine), try item(takeTheirs)],
                                     [keepMine.id: ["details": .local], takeTheirs.id: ["details": .notion]])
        XCTAssertTrue(report.failed.isEmpty)
        XCTAssertEqual(notionValue("p1", "Details"), "mine"); XCTAssertEqual(notionValue("p2", "Details"), "notion")
        XCTAssertEqual(try localValue(takeTheirs, "Details"), "notion")
    }

    func testAChoiceAboutAnOlderVersionIsRefused() async throws {
        let record = try synced("p1", title: "Shared", details: "base")
        notionEdit("p1", "Details", rich("notion version"))
        try store.ingest(pages: [ProjectJSON(FakeNotion.with { $0.pages["p1"]! })], source: source)
        try localEdit(record, "Details", ProjectJSON([["type": "text", "text": ["content": "first"]]]), at: nil)
        let seen = try item(record)
        try localEdit(record, "Details", ProjectJSON([["type": "text", "text": ["content": "edited again"]]]), at: nil)
        let report = try await apply([seen], [record.id: ["details": .notion]])
        XCTAssertEqual(report.failed.count, 1)
        XCTAssertEqual(try localValue(record, "Details"), "edited again", "The newer local edit survives")
        XCTAssertTrue(writes.isEmpty)
    }

    // MARK: Additive merges

    private func tags(_ names: [String]) -> [String: Any] {
        ["type": "multi_select", "multi_select": names.map { ["name": $0] }]
    }

    private func tagMismatch(_ id: String, local: [String], remote: [String]) throws -> ProjectGraphRecord {
        let record = try synced(id, title: id, details: "base")
        notionEdit(id, "Tags", tags(["shared"]))
        try store.ingest(pages: [ProjectJSON(FakeNotion.with { $0.pages[id]! })], source: source)
        try store.acceptIncoming(record.id)
        notionEdit(id, "Tags", tags(remote))
        try store.ingest(pages: [ProjectJSON(FakeNotion.with { $0.pages[id]! })], source: source)
        try localEdit(record, "Tags", ProjectJSON(tags(local))["multi_select"], at: nil)
        return try XCTUnwrap(store.record(id: record.id))
    }

    func testMergeIsRecommendedButWaitsForReview() throws {
        let record = try tagMismatch("merge", local: ["shared", "local"], remote: ["shared", "remote"])
        let diff = try XCTUnwrap(item(record).fields.first { $0.id == "tags" })
        XCTAssertEqual(diff.recommended, .merge)
        XCTAssertEqual(diff.bucket, .reconcilable)
        XCTAssertEqual(diff.merged?["multi_select"].array.map { $0["name"].display }, ["shared", "remote", "local"])
        let plan = ProjectAutoSyncPlanner.plan([try item(record)], deferred: [:], failures: [:])
        XCTAssertTrue(plan.push.isEmpty); XCTAssertTrue(plan.pull.isEmpty)
        XCTAssertEqual(plan.attention.count, 1)
    }

    func testImportedTagMismatchRecommendsMergeAndNewNotionImportStaysAutomatic() throws {
        var record = try tagMismatch("imported-tags", local: ["local"], remote: ["remote"])
        record.baseline = [:]
        try store.save(record)
        XCTAssertEqual(try item(record).fields.first { $0.id == "tags" }?.recommended, .merge)
        record.local = [:]
        try store.save(record)
        let imported = try item(record)
        XCTAssertEqual(imported.bucket, .automatic)
        XCTAssertEqual(imported.category, .newInNotion)
        XCTAssertTrue(ProjectSyncTriage.mergeChoices(imported).isEmpty)
    }

    func testReviewedMergeSendsUnionAndAcknowledgesCanonicalResult() async throws {
        let record = try tagMismatch("merge", local: ["SHARED", "local"], remote: ["shared", "remote"])
        let report = try await apply([try item(record)], [record.id: ["tags": .merge]])
        XCTAssertTrue(report.failed.isEmpty)
        XCTAssertEqual(notionValue("merge", "Tags"), "shared, remote, local")
        let latest = try XCTUnwrap(store.record(id: record.id))
        XCTAssertEqual(latest.local["tags"], latest.remote["tags"])
        XCTAssertEqual(latest.baseline["tags"], latest.remote["tags"])
        XCTAssertTrue(latest.changes.allSatisfy { $0.state == .equal })
    }

    func testBulkMergeLeavesScalarConflictsAndUploadsPending() async throws {
        let first = try tagMismatch("one", local: ["mine"], remote: ["theirs"])
        let second = try tagMismatch("two", local: ["a"], remote: ["b"])
        notionEdit("one", "Details", rich("notion words"))
        notionEdit("one", "Status", select("Done"))
        try store.ingest(pages: [ProjectJSON(FakeNotion.with { $0.pages["one"]! })], source: source)
        try localEdit(first, "Details", ProjectJSON(rich("local words"))["rich_text"], at: nil)
        var before = try XCTUnwrap(store.record(id: first.id))
        before.pendingUploads = [ProjectPendingUpload(propertyID: "files", url: URL(fileURLWithPath: "/tmp/never-upload.png"), contentType: "image/png", byteCount: 10, modifiedAt: nil)]
        try store.save(before)
        let report = try await ProjectAutoSync(store: store, client: client).apply([try item(first), try item(second)], mergesOnly: true)
        XCTAssertTrue(report.failed.isEmpty)
        XCTAssertEqual(report.sent.count, 2)
        XCTAssertEqual(notionValue("one", "Tags"), "theirs, mine")
        XCTAssertEqual(notionValue("two", "Tags"), "b, a")
        let latest = try XCTUnwrap(store.record(id: first.id))
        XCTAssertEqual(latest.local["details"], before.local["details"])
        XCTAssertEqual(latest.baseline["details"], before.baseline["details"])
        XCTAssertEqual(latest.pendingUploads, before.pendingUploads)
        XCTAssertEqual(latest.local["status"], before.local["status"], "Unrelated incoming fields stay pending")
        XCTAssertEqual(latest.baseline["status"], before.baseline["status"])
        XCTAssertEqual(latest.changes.first { $0.id == "details" }?.state, .conflict)
        XCTAssertEqual(notionValue("one", "Details"), "notion words")
    }

    func testMergeRefusesNewNotionEditAndKeepsUnionPending() async throws {
        let record = try tagMismatch("stale-merge", local: ["mine"], remote: ["theirs"])
        let reviewed = try item(record)
        notionEdit("stale-merge", "Tags", tags(["newer"]))
        let report = try await apply([reviewed], [record.id: ["tags": .merge]])
        XCTAssertNotNil(report.failed[record.id])
        XCTAssertTrue(writes.isEmpty)
        XCTAssertEqual(notionValue("stale-merge", "Tags"), "newer")
        XCTAssertEqual(try localValue(record, "Tags"), "theirs, mine")
    }

    func testReviewedRelationshipMergeSendsBothReferences() async throws {
        let record = try synced("relation-merge", title: "Relationships")
        notionEdit("relation-merge", "Links", ["type": "relation", "relation": []])
        try store.ingest(pages: [ProjectJSON(FakeNotion.with { $0.pages["relation-merge"]! })], source: source)
        try store.acceptIncoming(record.id)
        notionEdit("relation-merge", "Links", ["type": "relation", "relation": [["id": "remote-page"]]])
        try store.ingest(pages: [ProjectJSON(FakeNotion.with { $0.pages["relation-merge"]! })], source: source)
        let linked = try synced("remote-page", title: "Already linked")
        try localEdit(record, "Links", ProjectJSON([["id": "local-page"], ["id": linked.id]]), at: nil)
        let report = try await apply([try item(record)], [record.id: ["links": .merge]])
        XCTAssertTrue(report.failed.isEmpty)
        let latest = try XCTUnwrap(store.record(id: record.id))
        XCTAssertEqual(latest.remote["links"]?["relation"].array.map { $0["id"].display }, ["remote-page", "local-page"])
        XCTAssertEqual(latest.local["links"], latest.baseline["links"])
    }

    func testMergeSupportsRelationsAndRefusesUnsafeShapes() throws {
        let oldOption = ProjectJSON(["type": "multi_select", "multi_select": [["id": "same-option", "name": "Old label"]]])
        let renamed = ProjectJSON(["type": "multi_select", "multi_select": [["id": "same-option", "name": "New label", "color": "blue"]]])
        XCTAssertEqual(ProjectSyncTriage.mergedValue(local: oldOption, notion: renamed), renamed)
        let id = "304aec944d3c8071aae2c18130d0e8e5"
        let relation = ProjectJSON(["type": "relation", "relation": [["id": id]]])
        let formatted = ProjectJSON(["type": "relation", "relation": [["id": "304aec94-4d3c-8071-aae2-c18130d0e8e5"], ["id": "another"]]])
        XCTAssertEqual(ProjectSyncTriage.mergedValue(local: relation, notion: formatted)?["relation"].array.count, 2)
        XCTAssertNil(ProjectSyncTriage.mergedValue(local: ProjectJSON(rich("one")), notion: ProjectJSON(rich("two"))))
        XCTAssertNil(ProjectSyncTriage.mergedValue(local: relation, notion: ProjectJSON(tags(["tag"]))))
        let oversized = ProjectJSON(tags((0..<101).map { "tag-\($0)" }))
        XCTAssertNil(ProjectSyncTriage.mergedValue(local: oversized, notion: ProjectJSON(tags([]))))
        let partial = ProjectJSON(["type": "relation", "relation": [["id": id]], "has_more": true])
        XCTAssertNil(ProjectSyncTriage.mergedValue(local: relation, notion: partial))
        let record = try synced("scalar", title: "Scalar", details: "words")
        XCTAssertThrowsError(try store.resolve(record.id, choices: ["details": .merge], expected: record))
        XCTAssertEqual(try store.record(id: record.id), record)
    }

    func testServiceAcknowledgementDoesNotInvalidateReviewedMerge() async throws {
        let record = try tagMismatch("service-merge", local: ["mine"], remote: ["theirs"])
        let report = try await ProjectAutoSync(store: store, client: client).apply([try item(record)], choices: [record.id: ["tags": .merge]], serviceAcknowledgements: [record.id])
        XCTAssertTrue(report.failed.isEmpty)
        XCTAssertEqual(notionValue("service-merge", "Tags"), "theirs, mine")
        XCTAssertEqual(try store.record(id: record.id)?.serviceAcknowledgementPending, true)
    }

    func testSuccessfulHTTPResponseCannotAcknowledgeDroppedMergeValues() async throws {
        let record = try tagMismatch("dropped", local: ["mine"], remote: ["theirs"])
        FakeNotion.with { $0.droppedFields = ["tags"] }
        let report = try await ProjectAutoSync(store: store, client: client).apply([try item(record)], mergesOnly: true)
        XCTAssertNotNil(report.failed[record.id])
        XCTAssertEqual(report.mergedFields, 0)
        let latest = try XCTUnwrap(store.record(id: record.id))
        XCTAssertEqual(latest.local["tags"]?["multi_select"].array.map { $0["name"].display }, ["theirs", "mine"])
        XCTAssertNotEqual(latest.local["tags"], latest.baseline["tags"])
    }

    func testLinksToRetiredRecordsCannotBeRecommendedAsMerges() throws {
        let record = try synced("parent", title: "Parent")
        var retired = ProjectGraphRecord(id: "retired-local", pageID: "retired-page", sourceID: "tasks", kind: .tasks)
        retired.remoteArchived = true; retired.locallyDeleted = true; try store.save(retired)
        try localEdit(record, "Links", ProjectJSON([["id": "retired-page"]]))
        let diff = try XCTUnwrap(item(record).fields.first { $0.id == "links" })
        XCTAssertNil(diff.merged); XCTAssertNil(diff.recommended)
        XCTAssertEqual(diff.bucket, .decision)
        XCTAssertTrue(diff.note?.contains("archived") == true)
        XCTAssertTrue(ProjectSyncTriage.mergeChoices(try item(record)).isEmpty)
    }

    private actor ProgressLog {
        var updates: [ProjectAutoSync.Progress] = []
        func append(_ value: ProjectAutoSync.Progress) { updates.append(value) }
        func snapshot() -> [ProjectAutoSync.Progress] { updates }
    }

    func testMergeReportsProgressAndPersistsCompletion() async throws {
        let record = try tagMismatch("progress", local: ["mine"], remote: ["theirs"])
        let log = ProgressLog()
        let report = try await ProjectAutoSync(store: store, client: client).apply([try item(record)], mergesOnly: true, progress: { await log.append($0) })
        let updates = await log.snapshot()
        XCTAssertEqual(updates.first?.completed, 0)
        XCTAssertEqual(updates.last?.completed, 1)
        XCTAssertEqual(updates.last?.total, 1)
        XCTAssertTrue(updates.first?.message.contains("Merging") == true)
        XCTAssertEqual(report.mergedFields, 1)
        XCTAssertTrue(report.completionSummary.contains("1 field merged"))
        XCTAssertEqual(try store.read(ProjectAutoSync.actionReportKey, as: ProjectAutoSync.Report.self), report)
        XCTAssertEqual(try store.read(ProjectAutoSync.lastChangesKey, as: ProjectAutoSync.Report.self), report)
        _ = try await ProjectAutoSync(store: store, client: client).apply([])
        XCTAssertEqual(try store.read(ProjectAutoSync.lastChangesKey, as: ProjectAutoSync.Report.self), report, "A zero-change check preserves the last applied result")
    }

    func testCompletionDescribesNoChangesErrorsAndPendingReview() throws {
        var report = ProjectAutoSync.Report()
        report.attention = 3
        report.failed = ["p": "Offline"]
        report.readFailures = ["Tasks": "Cannot read"]
        XCTAssertTrue(ProjectAutoSync.Report().completionSummary.contains("No changes applied"))
        XCTAssertTrue(report.completionSummary.contains("finished with issues"))
        XCTAssertTrue(report.completionSummary.contains("1 record failed"))
        XCTAssertTrue(report.completionSummary.contains("1 source could not be checked"))
        XCTAssertTrue(report.completionSummary.contains("3 records still need review"))
        let legacy = try JSONDecoder().decode(ProjectAutoSync.Report.self, from: Data("{\"received\":[],\"sent\":[],\"failed\":{},\"attention\":0,\"waiting\":0,\"deferred\":0,\"obsolete\":0,\"readFailures\":{}}".utf8))
        XCTAssertNil(legacy.mergedFields)
    }

    // MARK: Task status names

    func testUnchosenAutomaticItemCannotSendEditsMadeAfterPlanning() async throws {
        let record = try synced("stale-local", title: "Task", details: "base")
        try localEdit(record, "Details", ProjectJSON(rich("reviewed"))["rich_text"])
        let runner = ProjectAutoSync(store: store, client: client)
        let plan = try await runner.triage()
        try localEdit(record, "Details", ProjectJSON(rich("new unreviewed edit"))["rich_text"])
        let report = try await runner.apply(plan)
        XCTAssertNotNil(report.failed[record.id])
        XCTAssertEqual(notionValue("stale-local", "Details"), "base")
        XCTAssertEqual(try localValue(record, "Details"), "new unreviewed edit")
        XCTAssertTrue(writes.isEmpty)
    }

    func testBatchFailureCannotReReviewANewerNotionValueOnRetry() async throws {
        let record = try synced("stale-remote", title: "Task", details: "base")
        try localEdit(record, "Details", ProjectJSON(rich("local reviewed"))["rich_text"])
        let runner = ProjectAutoSync(store: store, client: client)
        let plan = try await runner.triage()
        notionEdit("stale-remote", "Details", rich("newer Notion edit"))
        let report = try await runner.apply(plan)
        XCTAssertNotNil(report.failed[record.id])
        XCTAssertEqual(notionValue("stale-remote", "Details"), "newer Notion edit")
        XCTAssertTrue(writes.isEmpty)
    }

    func testCancelledPassDoesNotReadOrWriteNotion() async throws {
        _ = try synced("cancelled", title: "Task")
        let runner = ProjectAutoSync(store: store, client: client)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await runner.run(seeds: [.tasks: "tasks"])
        }
        do { _ = try await task.value; XCTFail("Cancelled pass should stop") }
        catch is CancellationError {}
        XCTAssertTrue(FakeNotion.with { $0.requests.isEmpty })
    }

    func testAnEquivalentNotionStatusIsKept() {
        let options = ["Backlog", "Todo", "In Progress", "Done"]
        XCTAssertEqual(ProjectGraphPlanning.statusOption(for: .open, current: "Backlog", options: options), "Backlog")
        XCTAssertEqual(ProjectGraphPlanning.statusOption(for: .open, current: "Done", options: options), "Todo")
        XCTAssertEqual(ProjectGraphPlanning.statusOption(for: .completed, current: "Backlog", options: options), "Done")
        XCTAssertEqual(ProjectGraphPlanning.statusOption(for: .inProgress, current: "In Review", options: options + ["In Review"]), "In Review")
    }
}
