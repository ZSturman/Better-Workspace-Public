import XCTest
@testable import BetterWorkspaceCore

private final class GraphTransport: URLProtocol {
    static let lock = NSLock()
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (Int, ProjectJSON))?
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "api.notion.com" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            Self.lock.lock(); let handler = Self.handler; Self.lock.unlock()
            let (status, body) = try XCTUnwrap(handler)(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: try JSONEncoder().encode(body))
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

final class NotionGraphSyncTests: XCTestCase {
    func testFocusedProjectCreationWritesOnlyOnePageAndRetainsRelatedDrafts() async throws {
        var creations = 0
        let (client, store) = try setup { request in
            creations += 1
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/v1/pages")
            let payload = try self.body(request)
            XCTAssertEqual(Set(payload["properties"].object.keys), ["title", "details"])
            return (200, ProjectJSON(["id": "created-project"]))
        }
        var schema = source.schema.object
        schema["Media"] = ProjectJSON(["id": "media", "type": "files"])
        try store.write("sources", [ProjectGraphSource(id: "s", title: "Projects", kind: .projects, schema: .object(schema))])
        var project = ProjectGraphRecord(sourceID: "s", kind: .projects, local: ["title": text("Selected project", type: "title"), "details": text("Keep details"), "links": ProjectJSON(["type": "relation", "relation": [["id": "unsent-related"]]])])
        project.localProjectID = "local-project"
        project.local["media"] = ProjectJSON(["type": "files", "files": [["type": "external", "name": "Preview", "external": ["url": "https://example.com/cover.png"]]]])
        project.pendingUploads = [.init(propertyID: "media", url: URL(fileURLWithPath: "/not-read/photo.png"), contentType: "image/png", byteCount: 1, modifiedAt: nil)]
        let related = ProjectGraphRecord(id: "unsent-related", sourceID: "s", kind: .tasks, local: ["title": text("Unrelated task", type: "title")])
        try store.save(project); try store.save(related)
        let sync = NotionProjectSync(store: store, client: client)
        try await sync.push(ids: [project.id], reviewed: [project], createProjectsOnly: true)
        let linked = try XCTUnwrap(store.record(id: project.id))
        XCTAssertEqual(linked.pageID, "created-project")
        XCTAssertEqual(linked.localProjectID, project.localProjectID)
        XCTAssertEqual(linked.pendingUploads, project.pendingUploads)
        XCTAssertEqual(linked.local["links"], project.local["links"])
        XCTAssertEqual(linked.local["media"], project.local["media"])
        XCTAssertNil(linked.baseline["media"], "Deferred media must not be acknowledged as sent")
        XCTAssertNil(try store.record(id: related.id)?.pageID)
        do { try await sync.push(ids: [project.id], reviewed: [project], createProjectsOnly: true); XCTFail("An old review must not create twice") } catch {}
        XCTAssertEqual(creations, 1)
    }

    func testFocusedProjectCreationRejectsStaleMissingSourceAndUncertainCreation() async throws {
        var writes = 0
        let (client, store) = try setup { _ in writes += 1; return (500, ProjectJSON(["message": "uncertain"])) }
        try store.write("sources", [ProjectGraphSource(id: "s", title: "Projects", kind: .projects, schema: source.schema)])
        var project = ProjectGraphRecord(sourceID: "missing", kind: .projects, local: ["title": text("Project", type: "title")])
        try store.save(project)
        let sync = NotionProjectSync(store: store, client: client)
        do { try await sync.push(ids: [project.id], reviewed: [project], createProjectsOnly: true); XCTFail("Missing source") } catch {}
        XCTAssertEqual(writes, 0)
        project.sourceID = "s"; try store.save(project)
        var changed = project; changed.local["details"] = text("Changed after review"); try store.save(changed)
        do { try await sync.push(ids: [project.id], reviewed: [project], createProjectsOnly: true); XCTFail("Stale review") } catch {}
        XCTAssertEqual(writes, 0)
        try store.save(project)
        do { try await sync.push(ids: [project.id], reviewed: [project], createProjectsOnly: true); XCTFail("Uncertain creation") } catch {}
        let uncertain = try XCTUnwrap(store.record(id: project.id))
        XCTAssertTrue(uncertain.ambiguousCreate)
        do { try await sync.push(ids: [project.id], reviewed: [uncertain], createProjectsOnly: true); XCTFail("No blind retry") } catch {}
        XCTAssertEqual(writes, 1)
    }

    private let source = ProjectGraphSource(id: "s", title: "tasks", kind: .tasks, schema: ProjectJSON([
        "Task": ["id": "title", "type": "title"], "Details": ["id": "details", "type": "rich_text"], "Formula": ["id": "formula", "type": "formula"], "Features": ["id": "links", "type": "relation", "relation": ["data_source_id": "s"]]]))
    private func text(_ value: String, type: String = "rich_text") -> ProjectJSON { ProjectJSON(["id": type == "title" ? "title" : "details", "type": type, type: value.isEmpty ? [] : [["type": "text", "text": ["content": value]]]]) }
    private func setup(_ handler: @escaping (URLRequest) throws -> (Int, ProjectJSON)) throws -> (NotionClient, ProjectGraphStore) {
        GraphTransport.lock.lock(); GraphTransport.handler = handler; GraphTransport.lock.unlock()
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [GraphTransport.self]
        let store = try ProjectGraphStore(database: Database(inMemory: true)); try store.write("sources", [source])
        return (NotionClient(token: "test", session: URLSession(configuration: config)), store)
    }
    private func body(_ request: URLRequest) throws -> ProjectJSON {
        if let data = request.httpBody { return try JSONDecoder().decode(ProjectJSON.self, from: data) }
        guard let stream = request.httpBodyStream else { return .null }
        stream.open(); defer { stream.close() }; var data = Data(); var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; data.append(buffer, count: count) }
        return try JSONDecoder().decode(ProjectJSON.self, from: data)
    }
    func testLocalDeletionRejectsAnOlderSendReviewWithoutWritingNotion() async throws {
        let (client, store) = try setup { _ in
            XCTFail("A locally deleted record must not reach the network from an old review")
            return (500, .null)
        }
        var record = ProjectGraphRecord(pageID: "p", sourceID: source.id, kind: .tasks,
            local: ["title": text("Task", type: "title")])
        record.localPath = "/fixture/Task.bw.md"
        try store.save(record)
        try store.recordLocalDeletion(path: try XCTUnwrap(record.localPath))
        try store.ingest(pages: [ProjectJSON(["id": "p", "properties": [:], "in_trash": false])], source: source)
        XCTAssertTrue(try store.record(id: record.id)?.locallyDeleted == true, "Background checks preserve the local deletion")
        do {
            try await NotionProjectSync(store: store, client: client).push(ids: [record.id], reviewed: [record])
            XCTFail("An old review should be refused")
        } catch {
            guard case NotionProjectSync.SyncError.stale = error else { return XCTFail("Expected stale review, got \(error)") }
        }
    }
    func testNewestConflictChoicesPreserveUnresolvedAndApplyOnlyChosenFields() throws {
        let store = try ProjectGraphStore(database: Database(inMemory: true))
        let base = ["details": text("shared"), "title": text("Shared title", type: "title")]
        var record = ProjectGraphRecord(pageID: "p", sourceID: "s", kind: .tasks, local: base, baseline: base, remote: base)
        let localDate = Date(timeIntervalSince1970: 200)
        record.set("Details", value: ProjectServiceBridge.text("local draft"), source: source, changedAt: localDate)
        record.remote["details"] = text("remote draft")
        record.local["title"] = text("Local title", type: "title") // Legacy: no known local edit date.
        record.remote["title"] = text("Remote title", type: "title")
        record.editedAt = Date(timeIntervalSince1970: 100)
        XCTAssertEqual(record.newestConflictChoice(for: "details"), true)
        XCTAssertNil(record.newestConflictChoice(for: "title"))
        record.editedAt = localDate
        XCTAssertNil(record.newestConflictChoice(for: "details"), "Ties require review")
        record.editedAt = Date(timeIntervalSince1970: 300)
        XCTAssertEqual(record.newestConflictChoice(for: "details"), false)
        try store.save(record)
        let restored = try XCTUnwrap(store.record(id: record.id))
        XCTAssertEqual(restored.localFieldEditedAt?["details"], localDate)
        try store.acceptIncoming(record.id, resolutions: ["details": try XCTUnwrap(restored.newestConflictChoice(for: "details"))])
        let applied = try XCTUnwrap(store.record(id: record.id))
        XCTAssertEqual(applied.local["details"]?.display, "remote draft")
        XCTAssertEqual(applied.local["title"]?.display, "Local title", "Unknown date must not silently replace local data")
        XCTAssertEqual(applied.changes.first { $0.id == "title" }?.state, .conflict)
    }
    func testUnchangedEditsAndImportedValuesDoNotInventFreshness() throws {
        let base = ["details": text("shared")]
        var record = ProjectGraphRecord(sourceID: "s", kind: .tasks, local: base, baseline: base, remote: base)
        record.set("Details", value: ProjectServiceBridge.text("draft"), source: source, changedAt: Date(timeIntervalSince1970: 100))
        record.set("Details", value: ProjectServiceBridge.text("draft"), source: source, changedAt: Date(timeIntervalSince1970: 200))
        XCTAssertEqual(record.localFieldEditedAt?["details"], Date(timeIntervalSince1970: 100))
        record = ProjectServiceBridge.applying(["Details": ProjectServiceBridge.text("service draft")], serviceID: "service", to: record, source: source)
        XCTAssertNil(record.localFieldEditedAt?["details"], "Service observation time is not the edit time")
        var initial = ProjectGraphRecord(sourceID: "s", kind: .tasks, remote: base)
        initial.seedInitialLocalState(["Details": ProjectServiceBridge.text("existing draft")], source: source)
        XCTAssertNil(initial.localFieldEditedAt?["details"])
        initial.remote["details"] = text("other draft")
        initial.editedAt = Date()
        XCTAssertNil(initial.newestConflictChoice(for: "details"))
        let data = try JSONEncoder().encode(ProjectGraphRecord(sourceID: "s", kind: .tasks))
        XCTAssertNil(try JSONDecoder().decode(ProjectGraphRecord.self, from: data).localFieldEditedAt)
    }
    func testNewerNotionPageTimestampInvalidatesNewestPreviewBeforeApplying() async throws {
        let base = ["details": text("shared")]
        var record = ProjectGraphRecord(pageID: "p", sourceID: "s", kind: .tasks, local: base, baseline: base, remote: ["details": text("remote draft")])
        record.set("Details", value: ProjectServiceBridge.text("local draft"), source: source, changedAt: Date(timeIntervalSince1970: 200))
        record.editedAt = Date(timeIntervalSince1970: 100)
        let (client, store) = try setup { _ in
            (200, ProjectJSON(["id": "p", "last_edited_time": "1970-01-01T00:05:00Z", "properties": ["Details": self.text("remote draft").foundationObject]]))
        }
        try store.save(record)
        do {
            try await NotionProjectSync(store: store, client: client).pull(ids: [record.id], reviewed: [record], resolutions: [record.id: ["details": true]])
            XCTFail("A changed timestamp must require a new review")
        } catch { guard case NotionProjectSync.SyncError.stale = error else { return XCTFail("Expected stale review, got \(error)") } }
        XCTAssertEqual(try store.record(id: record.id)?.local["details"]?.display, "local draft")
    }
    func testCompleteQueryAndRelationshipPagination() async throws {
        var requests = 0
        let (client, _) = try setup { request in
            requests += 1
            XCTAssertEqual(request.value(forHTTPHeaderField: "Notion-Version"), "2026-03-11")
            if request.url!.path.contains("properties") {
                let second = request.url!.query!.contains("start_cursor")
                return (200, ProjectJSON(["results": [["relation": ["id": second ? "b" : "a"]]], "has_more": !second, "next_cursor": second ? NSNull() : "next"]))
            }
            let second = try self.body(request)["start_cursor"].string != nil
            return (200, ProjectJSON(["results": second ? [] : [["id": "p", "properties": ["Links": ["id": "links", "type": "relation", "relation": [], "has_more": true]]]], "has_more": !second, "next_cursor": second ? NSNull() : "next-page"]))
        }
        let result = try await client.graphPages(sourceID: "s")
        XCTAssertTrue(result.complete); XCTAssertEqual(requests, 4)
        XCTAssertEqual(result.pages[0]["properties"]["Links"]["relation"].array.compactMap { $0["id"].string }, ["a", "b"])
    }
    func testPeopleAndFormattedMentionsReadPastPageResponseCap() async throws {
        let mentions = (0..<25).map { i in ["type": "mention", "mention": ["type": "page", "page": ["id": "p\(i)"]]] as [String: Any] }
        let (client, _) = try setup { request in
            let type = request.url!.path.hasSuffix("/people") ? "people" : "rich_text"
            if type == "rich_text" {
                XCTAssertTrue(request.url!.absoluteString.contains("text%3F%3A"))
                XCTAssertFalse(request.url!.absoluteString.contains("%25"))
            }
            let second = request.url!.query!.contains("start_cursor")
            let item: [String: Any] = type == "people" ? ["id": second ? "last" : "first"] : ["type": "text", "text": ["content": second ? "second" : "first"], "annotations": ["bold": true]]
            return (200, ProjectJSON(["results": [[type: item]], "has_more": !second, "next_cursor": second ? NSNull() : "opaque+&cursor"]))
        }
        let page = ProjectJSON(["id": "p", "properties": [
            "People": ["id": "people", "type": "people", "people": (0..<25).map { ["id": "u\($0)"] }],
            "Text": ["id": "text%3F%3A", "type": "rich_text", "rich_text": mentions]]])
        let full = try await client.completeProperties(page)
        XCTAssertEqual(full["properties"]["People"]["people"].array.last?["id"].string, "last")
        XCTAssertEqual(full["properties"]["Text"]["rich_text"].array.count, 2)
        XCTAssertTrue(full["properties"]["Text"]["rich_text"].array[1]["annotations"]["bold"].bool)
    }

    func testRollupUsesFinalCalculationAndCompleteOriginalValues() async throws {
        let (client, _) = try setup { request in
            let second = request.url!.query!.contains("start_cursor")
            let original = request.url!.path.hasSuffix("/original")
            let metadata: [String: Any] = original ? ["type": "array", "array": [], "function": "show_original"] : second ? ["type": "number", "number": 13, "function": "sum"] : ["type": "incomplete", "incomplete": [:], "function": "sum"]
            let item: [String: Any] = original ? ["type": "number", "number": second ? 8 : 5] : ["type": "relation", "relation": ["id": second ? "b" : "a"]]
            return (200, ProjectJSON(["results": [item], "has_more": !second, "next_cursor": second ? NSNull() : "next", "property_item": ["rollup": metadata]]))
        }
        let page = ProjectJSON(["id": "p", "properties": [
            "Sum": ["id": "sum", "type": "rollup", "rollup": ["type": "incomplete", "incomplete": [:]]],
            "Original": ["id": "original", "type": "rollup", "rollup": ["type": "array", "array": Array(repeating: ["type": "number", "number": 0], count: 25)]]]])
        let full = try await client.completeProperties(page)
        XCTAssertEqual(full["properties"]["Sum"]["rollup"]["number"], .number(13))
        XCTAssertEqual(full["properties"]["Original"]["rollup"]["array"].array.map { $0["number"] }, [.number(5), .number(8)])
    }

    func testMissingCursorIsAnIncompleteRead() async throws {
        let (client, _) = try setup { _ in (200, ProjectJSON(["results": [], "has_more": true])) }
        do { _ = try await client.graphPages(sourceID: "s"); XCTFail("Must reject incomplete pagination") } catch { XCTAssertTrue(error is NotionClient.Failure) }
    }
    func testExplicitClearRoundTripWritesOnlyChangedWritableFields() async throws {
        var remote = ["details": text("before"), "title": text("Task", type: "title"), "formula": ProjectJSON(["type": "formula", "formula": ["type": "number", "number": 3]])]
        var patches = 0
        let (client, store) = try setup { request in
            if request.httpMethod == "PATCH" {
                patches += 1; let body = try self.body(request)
                XCTAssertEqual(Set(body["properties"].object.keys), ["details"])
                XCTAssertEqual(body["properties"]["details"]["rich_text"].array, [])
                remote["details"] = self.text("")
            }
            return (200, ProjectJSON(["id": "p", "properties": ProjectJSON.object(remote).foundationObject]))
        }
        var record = ProjectGraphRecord(pageID: "p", sourceID: "s", kind: .tasks, local: remote, baseline: remote, remote: remote)
        record.local["details"] = text(""); try store.save(record)
        try await NotionProjectSync(store: store, client: client).push(ids: [record.id], reviewed: [record])
        XCTAssertEqual(patches, 1); XCTAssertTrue(try XCTUnwrap(store.records().first).changes.isEmpty)
    }
    func testAmbiguousCreationIsNeverBlindlyRetried() async throws {
        var creations = 0
        let (client, store) = try setup { request in creations += 1; return (500, ProjectJSON(["message": "unknown creation result"])) }
        let record = ProjectGraphRecord(sourceID: "s", kind: .tasks, local: ["title": text("new", type: "title")]); try store.save(record)
        let sync = NotionProjectSync(store: store, client: client)
        do { try await sync.push(ids: [record.id], reviewed: [record]); XCTFail("Expected failure") } catch {}
        let pending = try XCTUnwrap(store.records().first); XCTAssertTrue(pending.ambiguousCreate)
        do { try await sync.push(ids: [record.id], reviewed: [pending]); XCTFail("Expected reconciliation requirement") } catch {}
        XCTAssertEqual(creations, 1)
    }
    func testStaleReviewMakesNoWrites() async throws {
        var writes = 0
        let (client, store) = try setup { request in
            if request.httpMethod != "GET" { writes += 1 }
            return (200, ProjectJSON(["id": "p", "properties": ["Details": self.text("new remote").foundationObject]]))
        }
        let base = ["details": text("base")]
        let record = ProjectGraphRecord(pageID: "p", sourceID: "s", kind: .tasks, local: ["details": text("local")], baseline: base, remote: base); try store.save(record)
        do { try await NotionProjectSync(store: store, client: client).push(ids: [record.id], reviewed: [record]); XCTFail("Expected stale review") } catch { XCTAssertTrue(error is NotionProjectSync.SyncError) }
        XCTAssertEqual(writes, 0); XCTAssertEqual(try store.records().first?.local["details"], text("local"))
    }
    func testNewPagesExistBeforeRelationshipsAreAttached() async throws {
        var pages: [String: [String: ProjectJSON]] = [:], created = 0, attachments = 0
        let (client, store) = try setup { request in
            let body = try self.body(request)
            if request.url!.path == "/v1/pages" {
                created += 1; let id = "page\(created)"
                XCTAssertNil(body["properties"].object["links"])
                pages[id] = body["properties"].object.mapValues { value in var fields = value.object; fields["type"] = .string(fields.keys.first!); return .object(fields) }
                pages[id]?["links"] = ProjectJSON(["type": "relation", "relation": []])
                return (200, ProjectJSON(["id": id]))
            }
            let id = request.url!.lastPathComponent
            if request.httpMethod == "PATCH" {
                XCTAssertEqual(created, 2); attachments += 1
                let relation = try XCTUnwrap(body["properties"]["links"]["relation"].array.first?["id"].string)
                XCTAssertNotNil(pages[relation])
                pages[id]?["links"] = ProjectJSON(["type": "relation", "relation": [["id": relation]]])
            }
            return (200, ProjectJSON(["id": id, "properties": ProjectJSON.object(pages[id] ?? [:]).foundationObject]))
        }
        let feature = ProjectGraphRecord(sourceID: "s", kind: .features, local: ["title": text("feature", type: "title")])
        var task = ProjectGraphRecord(sourceID: "s", kind: .tasks, local: ["title": text("task", type: "title")]); task.local["links"] = ProjectJSON(["type": "relation", "relation": [["id": feature.id]]])
        try store.save(feature); try store.save(task)
        try await NotionProjectSync(store: store, client: client).push(ids: [feature.id, task.id], reviewed: [task, feature])
        XCTAssertEqual(created, 2); XCTAssertEqual(attachments, 1)
    }
    func testArchiveRequiresAnExplicitRequest() async throws {
        var archives = 0
        let (client, store) = try setup { request in
            if request.httpMethod == "PATCH" { XCTAssertTrue(try self.body(request)["in_trash"].bool); archives += 1 }
            return (200, ProjectJSON(["id": "p", "in_trash": archives > 0, "properties": [:]]))
        }
        var record = ProjectGraphRecord(pageID: "p", sourceID: "s", kind: .tasks); try store.save(record)
        let sync = NotionProjectSync(store: store, client: client)
        try await sync.push(ids: [record.id], reviewed: [record]); XCTAssertEqual(archives, 0)
        record.archiveRequested = true; try store.save(record)
        try await sync.push(ids: [record.id], reviewed: [record]); XCTAssertEqual(archives, 1)
        XCTAssertFalse(try XCTUnwrap(store.records().first).archiveRequested)
    }
    func testPartialUploadKeepsItsIDAndPendingFileForResume() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("preview.png"); try Data([1, 2, 3]).write(to: file)
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        var creates = 0, sends = 0
        let (client, store) = try setup { request in
            if request.url!.path == "/v1/file_uploads" { creates += 1; return (200, ProjectJSON(["id": "upload"])) }
            if request.url!.path.hasSuffix("/send") { sends += 1; return (200, ProjectJSON(["status": "pending"])) }
            if request.url!.path == "/v1/file_uploads/upload" { return (200, ProjectJSON(["status": "pending"])) }
            return (200, ProjectJSON(["id": "p", "properties": [:]]))
        }
        try store.write("sources", [ProjectGraphSource(id: "s", title: "Assets", kind: .assets, schema: ProjectJSON(["preview": ["id": "preview", "type": "files"]]))])
        var record = ProjectGraphRecord(pageID: "p", sourceID: "s", kind: .assets)
        let upload = ProjectPendingUpload(propertyID: "preview", url: file, contentType: "image/png", byteCount: 3, modifiedAt: attributes[.modificationDate] as? Date)
        record.pendingUploads = [upload]; try store.save(record)
        let sync = NotionProjectSync(store: store, client: client)
        for _ in 0..<2 {
            let reviewed = try XCTUnwrap(store.record(id: record.id))
            do { try await sync.push(ids: [record.id], reviewed: [reviewed]); XCTFail("Incomplete upload must remain pending") } catch {}
        }
        XCTAssertEqual(creates, 1); XCTAssertEqual(sends, 2)
        XCTAssertEqual(try store.record(id: record.id)?.pendingUploads, [upload])
        XCTAssertEqual(try store.read("fileUpload:\(upload.id)", as: String.self), "upload")
        XCTAssertNotNil(try store.record(id: record.id)?.error)
    }
    func testPermissionLossPreservesOfflineEditsAndMakesNoWrites() async throws {
        var writes = 0
        let (client, store) = try setup { request in
            if request.httpMethod != "GET" { writes += 1 }
            return (403, ProjectJSON(["message": "access revoked"]))
        }
        let base = ["details": text("before")]
        let record = ProjectGraphRecord(pageID: "p", sourceID: "s", kind: .tasks, local: ["details": text("offline")], baseline: base, remote: base)
        try store.save(record)
        do { try await NotionProjectSync(store: store, client: client).push(ids: [record.id], reviewed: [record]); XCTFail("Permission loss must stop writes") } catch {}
        XCTAssertEqual(writes, 0); XCTAssertEqual(try store.record(id: record.id), record)
    }
    func testStaleExistingPagePreventsUnrelatedCreation() async throws {
        var creates = 0
        let (client, store) = try setup { request in
            if request.httpMethod == "POST" { creates += 1 }
            return (200, ProjectJSON(["id": "p", "properties": ["Details": self.text("changed remotely").foundationObject]]))
        }
        let base = ["details": text("base")]
        let existing = ProjectGraphRecord(pageID: "p", sourceID: "s", kind: .tasks, local: ["details": text("local")], baseline: base, remote: base)
        let draft = ProjectGraphRecord(sourceID: "s", kind: .tasks, local: ["title": text("new", type: "title")])
        try store.save(existing); try store.save(draft)
        do { try await NotionProjectSync(store: store, client: client).push(ids: [draft.id, existing.id], reviewed: [draft, existing]); XCTFail("Must revalidate every record before creating") } catch {}
        XCTAssertEqual(creates, 0); XCTAssertNil(try store.record(id: draft.id)?.pageID)
    }
    func testBlockPaginationRetainsNestedAndUnsupportedContent() async throws {
        let (client, _) = try setup { request in
            if request.url!.path.contains("/nested/") { return (200, ProjectJSON(["results": [["id": "opaque", "type": "unsupported", "unsupported": ["future": "preserved"]]], "has_more": false])) }
            if request.url!.query?.contains("start_cursor") == true { return (200, ProjectJSON(["results": [["type": "divider", "divider": [:]]], "has_more": false])) }
            return (200, ProjectJSON(["results": [["id": "nested", "type": "toggle", "has_children": true, "toggle": ["rich_text": [["type": "text", "text": ["content": "Details"], "annotations": ["bold": true]]]]]], "has_more": true, "next_cursor": "next"]))
        }
        let content = try await client.pageContent(pageID: "p", editedAt: nil)
        XCTAssertEqual(content.blocks.count, 2)
        XCTAssertEqual(content.blocks[0]["_children"].array[0]["unsupported"]["future"].string, "preserved")
        XCTAssertTrue(content.blocks[0]["toggle"]["rich_text"].array[0]["annotations"]["bold"].bool)
        XCTAssertTrue(content.plainText.contains("Details"))
    }

    func testIncrementalTaskReadRefreshesComputedMilestoneParent() async throws {
        let milestoneSource = ProjectGraphSource(id: "m-source", title: "Milestones", kind: .milestones, schema: ProjectJSON(["status": ["id": "status", "type": "formula"], "tasks": ["id": "tasks", "type": "relation", "relation": ["data_source_id": "s"]]]))
        var parentReads = 0
        let (client, store) = try setup { request in
            if request.url!.path == "/v1/data_sources/s" { return (200, ProjectJSON(["id": "s", "title": [["text": ["content": "Tasks"]]], "properties": self.source.schema.foundationObject])) }
            if request.url!.path == "/v1/data_sources/s/query" { return (200, ProjectJSON(["results": [["id": "t", "properties": ["Task": self.text("Task", type: "title").foundationObject]]], "has_more": false])) }
            if request.url!.path == "/v1/data_sources/m-source/query" { return (200, ProjectJSON(["results": [], "has_more": false])) }
            if request.url!.path == "/v1/pages/m" { parentReads += 1; return (200, ProjectJSON(["id": "m", "properties": ["status": ["id": "status", "type": "formula", "formula": ["type": "string", "string": "Complete"]], "tasks": ["id": "tasks", "type": "relation", "relation": [["id": "t"]]]]])) }
            return (200, ProjectJSON(["bot": ["workspace_name": "Fixture"]]))
        }
        try store.write("sources", [source, milestoneSource]); try store.write("lastFullCheck", Date())
        let fields = ["tasks": ProjectJSON(["type": "relation", "relation": [["id": "t"]]])]
        let milestone = ProjectGraphRecord(pageID: "m", sourceID: "m-source", kind: .milestones, local: fields, baseline: fields, remote: fields); try store.save(milestone)
        let report = try await NotionProjectSync(store: store, client: client).check(seeds: [.tasks: "s"])
        XCTAssertTrue(report.failures.isEmpty, "\(report.failures)"); XCTAssertEqual(parentReads, 1)
        XCTAssertEqual(try store.record(id: milestone.id)?.remote["status"]?["formula"]["string"].string, "Complete")
        XCTAssertNil(try store.record(id: milestone.id)?.local["status"], "Detection must not apply the computed field")
    }

    func testFailedSourceReadRetainsSnapshotCountAndCursor() async throws {
        let (client, store) = try setup { request in
            if request.url!.path == "/v1/data_sources/s" { return (200, ProjectJSON(["id": "s", "title": [["text": ["content": "Tasks"]]], "properties": self.source.schema.foundationObject])) }
            if request.url!.path.hasSuffix("/query") { return (403, ProjectJSON(["message": "source access lost"])) }
            return (200, ProjectJSON(["bot": ["workspace_name": "Fixture"]]))
        }
        let fields = ["title": text("Retained", type: "title")]
        let record = ProjectGraphRecord(pageID: "p", sourceID: "s", kind: .tasks, local: fields, baseline: fields, remote: fields)
        try store.save(record); let cursor = Date(timeIntervalSince1970: 1_000)
        try store.write("cursor:s", cursor); try store.write("lastFullCheck", Date())
        let report = try await NotionProjectSync(store: store, client: client).check(seeds: [.tasks: "s"])
        XCTAssertEqual(report.counts["Tasks"], 1); XCTAssertNotNil(report.failures["Tasks"])
        XCTAssertEqual(try store.record(id: record.id), record); XCTAssertEqual(try store.read("cursor:s", as: Date.self), cursor)
    }
    func testIngestUpdatesTheKnownRecordForAPageAndCountsEachReadSource() async throws {
        let (client, store) = try setup { request in
            if request.url!.path == "/v1/data_sources/s" { return (200, ProjectJSON(["id": "s", "title": [["text": ["content": "Tasks"]]], "properties": self.source.schema.foundationObject])) }
            if request.url!.path.hasSuffix("/query") { return (200, ProjectJSON(["results": [["id": "p", "properties": ["Task": self.text("Renamed", type: "title").foundationObject]], ["id": "q", "properties": ["Task": self.text("New", type: "title").foundationObject]]], "has_more": false])) }
            return (200, ProjectJSON(["bot": ["workspace_name": "Fixture"]]))
        }
        let fields = ["title": text("Original", type: "title")]
        let known = ProjectGraphRecord(pageID: "p", sourceID: "s", kind: .tasks, local: fields, baseline: fields, remote: fields)
        try store.save(known); try store.write("lastFullCheck", Date())
        let report = try await NotionProjectSync(store: store, client: client).check(seeds: [.tasks: "s"])
        XCTAssertTrue(report.failures.isEmpty, "\(report.failures)"); XCTAssertEqual(report.counts["Tasks"], 2)
        let updated = try XCTUnwrap(store.record(pageID: "p"))
        XCTAssertEqual(updated.id, known.id, "A page already in the graph keeps its record")
        XCTAssertEqual(updated.local, fields, "Detection never applies remote fields")
        XCTAssertEqual(updated.remote["title"]?["title"].array.first?["text"]["content"].string, "Renamed")
        XCTAssertEqual(try store.records().count, 2)
    }
    func testAmbiguousCreationReconciliationChecksSourceAndKeepsIdentity() async throws {
        var correctSource = false
        let fields = ["title": text("Created once", type: "title")]
        let (client, store) = try setup { _ in (200, ProjectJSON(["id": "created", "parent": ["data_source_id": correctSource ? "s" : "wrong"], "properties": ["Task": fields["title"]!.foundationObject]])) }
        var record = ProjectGraphRecord(id: "local", sourceID: "s", kind: .tasks, local: fields); record.ambiguousCreate = true; try store.save(record)
        let staged = ProjectGraphRecord(pageID: "created", sourceID: "s", kind: .tasks, remote: fields); try store.save(staged)
        let sync = NotionProjectSync(store: store, client: client)
        do { try await sync.reconcileCreation(recordID: record.id, pageID: "created"); XCTFail("Wrong source must not bind") } catch {}
        XCTAssertTrue(try XCTUnwrap(store.record(id: record.id)).ambiguousCreate)
        correctSource = true; try await sync.reconcileCreation(recordID: record.id, pageID: "created")
        XCTAssertEqual(try store.record(id: record.id)?.pageID, "created"); XCTAssertFalse(try XCTUnwrap(store.record(id: record.id)).ambiguousCreate)
        XCTAssertNil(try store.record(id: staged.id)); XCTAssertEqual(try store.records().count, 1)
    }

    func testLargeInitialPullUsesCompleteSourceQueriesForRevalidation() async throws {
        var queries = 0, pageReads = 0
        let pages = (0..<101).map { index in ProjectJSON(["id": "page\(index)", "properties": ["Task": self.text("Task \(index)", type: "title").foundationObject]]) }
        let (client, store) = try setup { request in
            if request.url!.path.hasSuffix("/query") {
                queries += 1; let second = try self.body(request)["start_cursor"].string != nil
                return (200, ProjectJSON(["results": (second ? Array(pages.suffix(1)) : Array(pages.prefix(100))).map(\.foundationObject), "has_more": !second, "next_cursor": second ? NSNull() : "next"]))
            }
            pageReads += 1; return (500, ProjectJSON(["message": "Individual GETs should not be needed"]))
        }
        try store.ingest(pages: pages, source: source)
        let reviewed = try store.records()
        try await NotionProjectSync(store: store, client: client).pull(ids: Set(reviewed.map(\.id)), reviewed: reviewed)
        XCTAssertEqual(queries, 2); XCTAssertEqual(pageReads, 0)
        XCTAssertTrue(try store.records().allSatisfy { !$0.baseline.isEmpty && $0.changes.isEmpty })
    }

}

extension NotionGraphSyncTests {
    func testPotentialIdeaCreatesOnceThenUpdatesSameProjectAndDetectsExternalPromotion() async throws {
        let projects = ProjectGraphSource(id: "potential-projects", title: "Projects", kind: .projects, schema: ProjectJSON([
            "Name": ["id": "title", "type": "title"], "Status": ["id": "status", "type": "status"],
            "Local Directory": ["id": "directory", "type": "rich_text"], "Summary": ["id": "summary", "type": "rich_text"]]))
        var remote: [String: ProjectJSON] = [:]
        var creates = 0, patches = 0
        let (client, store) = try setup { request in
            if request.httpMethod == "POST" || request.httpMethod == "PATCH" {
                if request.httpMethod == "POST" { creates += 1 } else { patches += 1 }
                let properties = try self.body(request)["properties"].object
                for (key, value) in properties {
                    let type = try XCTUnwrap(value.object.keys.first)
                    var envelope = value.object; envelope["id"] = .string(key); envelope["type"] = .string(type)
                    remote[key] = .object(envelope)
                }
            }
            return (200, ProjectJSON(["id": "one-stable-page", "properties": ProjectJSON.object(remote).foundationObject]))
        }
        try store.write("sources", [projects])
        var details = IdeaProjectDetails(oneLiner: "", summary: "Initial idea")
        var record = try IdeaProjectBridge.applying(serviceID: "one-idea", title: "Studio", path: "/Fixture/Ideas/Studio", details: details, tags: [], ratings: [:], to: nil, source: projects)
        try store.save(record)
        let sync = NotionProjectSync(store: store, client: client)
        try await sync.push(ids: [record.id], reviewed: [record])
        record = try XCTUnwrap(store.record(id: record.id))
        XCTAssertEqual(record.pageID, "one-stable-page")
        details.summary = "Edited on a later day"
        let existing = try IdeaProjectBridge.existing(serviceID: "one-idea", path: "/Fixture/Ideas/Studio", records: store.records(), source: projects)
        record = try IdeaProjectBridge.applying(serviceID: "one-idea", title: "Studio", path: "/Fixture/Ideas/Studio", details: details, tags: [], ratings: [:], to: existing, source: projects)
        try store.save(record)
        try await sync.push(ids: [record.id], reviewed: [record], fields: [record.id: Set((record.serviceSnapshot ?? [:]).keys)])
        XCTAssertEqual(creates, 1); XCTAssertEqual(patches, 1)
        XCTAssertEqual(try store.records().count, 1)
        // A background read after a status edit retains the local idea and signals a review.
        remote["status"] = ProjectJSON(["id": "status", "type": "status", "status": ["name": "Active"]])
        try store.ingest(pages: [ProjectJSON(["id": "one-stable-page", "properties": ProjectJSON.object(remote).foundationObject])], source: projects)
        let promoted = try XCTUnwrap(store.record(id: record.id))
        XCTAssertEqual(IdeaProjectBridge.promotedStatus(promoted, source: projects), "Active")
        XCTAssertFalse(IdeaProjectBridge.canAutomaticallySend(promoted, source: projects))
        XCTAssertNil(promoted.localProjectID)
        XCTAssertEqual(promoted.localPath, "/Fixture/Ideas/Studio")
    }
}

extension NotionGraphSyncTests {
    /// After a completed local promotion, Notion can be unreachable. The retry must patch
    /// the same page with only the approved directory/status values, never create one.
    func testPromotionDirectoryUpdateRetriesSamePageWithOnlyApprovedFieldsAfterFailure() async throws {
        let projects = ProjectGraphSource(id: "promotion-projects", title: "Projects", kind: .projects, schema: ProjectJSON([
            "Name": ["id": "title", "type": "title"], "Status": ["id": "status", "type": "status"],
            "Local Directory": ["id": "directory", "type": "rich_text"], "Summary": ["id": "summary", "type": "rich_text"]]))
        var failing = false, creates = 0
        var remote: [String: ProjectJSON] = [:]
        var patched: [(String, Set<String>)] = []
        let (client, store) = try setup { request in
            if request.httpMethod == "POST" || request.httpMethod == "PATCH" {
                if request.httpMethod == "POST" { creates += 1 }
                if request.httpMethod == "PATCH" {
                    if failing { throw URLError(.notConnectedToInternet) }
                    patched.append((request.url?.path ?? "", Set(try self.body(request)["properties"].object.keys)))
                }
                for (key, value) in try self.body(request)["properties"].object {
                    let type = try XCTUnwrap(value.object.keys.first)
                    var envelope = value.object; envelope["id"] = .string(key); envelope["type"] = .string(type)
                    remote[key] = .object(envelope)
                }
            }
            return (200, ProjectJSON(["id": "stable-page", "properties": ProjectJSON.object(remote).foundationObject]))
        }
        try store.write("sources", [projects])
        let created = try IdeaProjectBridge.applying(serviceID: "promoted-idea", title: "Studio", path: "/Fixture/Ideas/Studio",
            details: .init(summary: "Remote summary"), tags: [], ratings: [:], to: nil, source: projects)
        try store.save(created)
        let sync = NotionProjectSync(store: store, client: client)
        try await sync.push(ids: [created.id], reviewed: [created])
        XCTAssertEqual(creates, 1)
        var record = try XCTUnwrap(store.record(id: created.id))
        XCTAssertEqual(record.pageID, "stable-page")
        // The completed move: bound to a local project, with the two approved values staged.
        record.localProjectID = "local-project"; record.localPath = "/Fixture/Projects/Studio"
        record.set("Status", value: ProjectJSON(["name": "Queued"]), source: projects)
        record.set("Local Directory", value: ProjectServiceBridge.text("/Fixture/Projects/Studio"), source: projects)
        // An unrelated local draft that the promotion did not authorize.
        record.set("Summary", value: ProjectServiceBridge.text("Unreviewed local draft"), source: projects)
        try store.save(record)
        failing = true
        let approved: Set<String> = ["status", "directory"]
        do { try await sync.push(ids: [record.id], reviewed: [record], fields: [record.id: approved]); XCTFail("A failed send must surface") } catch {}
        var pending = try XCTUnwrap(store.record(id: record.id))
        XCTAssertEqual(pending.pageID, "stable-page")
        XCTAssertEqual(pending.localProjectID, "local-project", "The local promotion stays valid while Notion fails")
        XCTAssertEqual(pending.value("Local Directory", source: projects).display, "/Fixture/Projects/Studio")
        failing = false
        pending = try XCTUnwrap(store.record(id: record.id))
        try await sync.push(ids: [pending.id], reviewed: [pending], fields: [pending.id: approved])
        XCTAssertEqual(creates, 1, "No second page")
        XCTAssertEqual(patched.count, 1)
        XCTAssertTrue(patched.first?.0.hasSuffix("/pages/stable-page") == true, patched.first?.0 ?? "")
        XCTAssertEqual(patched.first?.1, approved)
        XCTAssertEqual(try store.records().filter { $0.serviceRecordID == "promoted-idea" }.count, 1)
        let after = try XCTUnwrap(store.record(id: record.id))
        XCTAssertEqual(after.value("Summary", source: projects).display, "Unreviewed local draft", "The unrelated draft is retained, not sent or discarded")
    }
}
