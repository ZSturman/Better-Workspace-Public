import XCTest
@testable import BetterWorkspaceCore

final class ProjectGraphTests: XCTestCase {
    private func text(_ value: String) -> ProjectJSON { ProjectJSON(["type": "rich_text", "rich_text": [["type": "text", "text": ["content": value]]]]) }
    func testPropertyIDsDoNotReplaceDisplayedValues() {
        let value = ProjectJSON(["id": "title", "type": "title", "title": [["plain_text": "Top "], ["plain_text": "Note"]]])
        XCTAssertEqual(value.display, "Top Note")
        XCTAssertEqual(ProjectGraphRecord(sourceID: "s", kind: .projects, local: ["title": value]).title, "Top Note")
    }
    func testManyToManyWorkAndNewMediaStayRelated() {
        func relation(_ ids: [String]) -> ProjectJSON { ProjectJSON(["type": "relation", "relation": ids.map { ["id": $0] }]) }
        let project = ProjectGraphRecord(id: "project", pageID: "p", sourceID: "projects", kind: .projects, local: ["features": relation(["f1", "f2"])])
        let first = ProjectGraphRecord(pageID: "f1", sourceID: "features", kind: .features, local: ["tasks": relation(["t"])])
        let second = ProjectGraphRecord(pageID: "f2", sourceID: "features", kind: .features, local: ["tasks": relation(["t"])])
        let task = ProjectGraphRecord(pageID: "t", sourceID: "tasks", kind: .tasks, local: ["features": relation(["f1", "f2"])])
        let media = ProjectGraphRecord(sourceID: "assets", kind: .assets, local: ["project": relation(["p"])])
        XCTAssertEqual(Set(ProjectGraph.related(to: "p", in: [project, first, second, task, media]).map(\.id)), [first.id, second.id, task.id, media.id])
        XCTAssertEqual(task.relatedPageIDs, ["f1", "f2"])
    }
    func testPortableTypedRelationshipsPreserveUnknownFrontMatter() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bw-work-graph-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let work = WorkItem(kind: .task, title: "Multiple parents", parentID: "old", relatedIDs: ["r"], parentIDs: ["a", "b"], dependencyIDs: ["d"], featureIDs: ["f1", "f2"], milestoneIDs: ["m"], notionPageID: "remote", extraFrontMatter: ["custom-field: retain me"], url: root.appendingPathComponent("placeholder"))
        let saved = try WorkItemService().create(work, in: root)
        XCTAssertEqual(saved.parentID, "old"); XCTAssertEqual(saved.parentIDs, ["a", "b"])
        XCTAssertEqual(saved.featureIDs, ["f1", "f2"]); XCTAssertEqual(saved.dependencyIDs, ["d"])
        XCTAssertEqual(saved.notionPageID, "remote"); XCTAssertTrue(saved.extraFrontMatter.contains("custom-field: retain me"))
    }
    func testLosslessRichTextRoundTrip() throws {
        let value = ProjectJSON(["type": "rich_text", "rich_text": [["type": "mention", "mention": ["page": ["id": "p"]], "annotations": ["bold": true]]]])
        XCTAssertEqual(try JSONDecoder().decode(ProjectJSON.self, from: JSONEncoder().encode(value)), value)
    }
    func testThreeWayMergeRetainsLocalEditsAndReviewsConflicts() throws {
        let store = try ProjectGraphStore(database: Database(inMemory: true))
        var record = ProjectGraphRecord(pageID: "p", sourceID: "s", kind: .projects,
            local: ["a": text("local"), "b": text("base"), "c": text("local")],
            baseline: ["a": text("base"), "b": text("base"), "c": text("base")],
            remote: ["a": text("base"), "b": text("remote"), "c": text("remote")])
        try store.save(record); try store.acceptIncoming(record.id)
        record = try XCTUnwrap(store.records().first)
        XCTAssertEqual(record.local["a"], text("local")); XCTAssertEqual(record.local["b"], text("remote"))
        XCTAssertEqual(record.changes.first { $0.id == "c" }?.state, .conflict)
        try store.acceptIncoming(record.id, resolutions: ["c": true])
        XCTAssertEqual(try store.records().first?.changes.first { $0.id == "c" }?.state, .outgoing)
    }
    func testPendingChangesAndLeaseSurviveReopening() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bw-graph-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("private.sqlite")
        let first = try ProjectGraphStore(database: Database(url: url))
        let record = ProjectGraphRecord(sourceID: "s", kind: .resources, local: ["a": text("new")])
        try first.save(record); XCTAssertTrue(try first.acquire(owner: "first"))
        let second = try ProjectGraphStore(database: Database(url: url))
        XCTAssertEqual(try second.records().first?.local, record.local)
        XCTAssertFalse(try second.acquire(owner: "second"))
        try first.release(owner: "first"); XCTAssertTrue(try second.acquire(owner: "second"))
    }
    func testMissingLocalMediaFallsBackToPreviewAndExpires() {
        let schema = ProjectJSON(["relative path": ["id": "path", "type": "rich_text"], "preview": ["id": "preview", "type": "files"]])
        let source = ProjectGraphSource(id: "s", title: "assets", kind: .assets, schema: schema)
        let asset = ProjectGraphRecord(sourceID: "s", kind: .assets, local: ["path": text("missing/poster.png"),
            "preview": ProjectJSON(["type": "files", "files": [["type": "file", "file": ["url": "https://example.com/poster.png", "expiry_time": "2030-01-01T00:00:00Z"]]]])])
        let result = ProjectMediaResolver.resolve(asset, source: source, workspaceRoot: URL(fileURLWithPath: "/tmp"), projectRoots: [:])
        XCTAssertEqual(result.url?.absoluteString, "https://example.com/poster.png"); XCTAssertTrue(result.isPreview)
        XCTAssertEqual(result.staleLocalPath, "missing/poster.png")
        XCTAssertNil(ProjectMediaResolver.resolve(asset, source: source, workspaceRoot: URL(fileURLWithPath: "/tmp"), projectRoots: [:], now: Date(timeIntervalSince1970: 2_000_000_000)).url)
    }
    func testFormulaFieldsAreNeverWritable() {
        let source = ProjectGraphSource(id: "s", title: "milestones", kind: .milestones,
            schema: ProjectJSON(["status": ["id": "x", "type": "formula"], "description": ["id": "d", "type": "rich_text"]]))
        XCTAssertFalse(source.writable("x")); XCTAssertTrue(source.writable("d"))
    }
    func testChangingSignedPreviewURLDoesNotCreateAChange() {
        let a = ProjectJSON(["type": "file", "file": ["url": "https://example.com/image?signature=one", "expiry_time": "a"]])
        let b = ProjectJSON(["type": "file", "file": ["url": "https://example.com/image?signature=two", "expiry_time": "b"]])
        XCTAssertEqual(a.comparable, b.comparable)
    }
    func testPartialDraftPreservesDetailsAndExplicitClearing() {
        let existing = ProjectMetadata(domain: "Technology", status: "Active")
        let description = ProjectDescription(oneLiner: "Retain this", summary: "Existing story")
        let ratingFields = ProjectMetadataImport.suppliedFields(propertyNames: ["Personal Value"])
        let unchanged = ProjectMetadataImport.applying(ratingFields, values: .init(), to: existing, description: description)
        XCTAssertEqual(unchanged.metadata, existing); XCTAssertEqual(unchanged.description, description)
        let clearFields = ProjectMetadataImport.suppliedFields(propertyNames: ["Status"])
        let cleared = ProjectMetadataImport.applying(clearFields, values: .init(), to: existing, description: description)
        XCTAssertNil(cleared.metadata.status); XCTAssertEqual(cleared.metadata.domain, "Technology")
        XCTAssertEqual(cleared.description, description)
        XCTAssertFalse(ProjectMetadataImport.suppliedFields(propertyNames: ["repo"], relationNames: ["repo"]).contains(.github))
    }
    func testIndexPreservesMultipleParentsAndDraftRelations() {
        func relation(_ ids: [String]) -> ProjectJSON { ProjectJSON(["type": "relation", "relation": ids.map { ["id": $0] }]) }
        let project = ProjectGraphRecord(id: "p", pageID: "remote-p", sourceID: "projects", kind: .projects, local: ["f": relation(["f1", "f2"])])
        let features = ["f1", "f2"].map { ProjectGraphRecord(id: $0, pageID: $0, sourceID: "features", kind: .features, local: ["t": relation(["t"])]) }
        let task = ProjectGraphRecord(id: "t", pageID: "t", sourceID: "tasks", kind: .tasks, local: ["f": relation(["f1", "f2"])])
        let draft = ProjectGraphRecord(id: "draft", sourceID: "assets", kind: .assets, local: ["p": relation(["remote-p"])])
        XCTAssertEqual(Set(ProjectGraphIndex(records: [project, task, draft] + features).related(to: project).map(\.id)), ["f1", "f2", "t", "draft"])
    }
    func testDeadCheckerLockIsRecoveredAndLiveLockDoesNotExpire() throws {
        let store = try ProjectGraphStore(database: Database(inMemory: true))
        XCTAssertTrue(try store.acquire(owner: "pid:2147483647:dead"))
        let live = "pid:\(ProcessInfo.processInfo.processIdentifier):live"
        XCTAssertTrue(try store.acquire(owner: live))
        XCTAssertFalse(try store.acquire(owner: "other", now: Date().addingTimeInterval(7200)))
        try store.release(owner: live)
        XCTAssertTrue(try store.acquire(owner: "other"))
    }

    func testServiceObservationsDoNotOverwriteUnchangedLocalNarrative() {
        let source = ProjectGraphSource(id: "logs", title: "Work Logs", kind: .workLogs, schema: ProjectJSON(["progress_summary": ["id": "summary", "type": "rich_text"], "active seconds": ["id": "seconds", "type": "number"], "status": ["id": "computed", "type": "formula"]]))
        let initial = ProjectGraphRecord(sourceID: "logs", kind: .workLogs)
        let first = ProjectServiceBridge.applying(["progress_summary": ProjectServiceBridge.text("Observed"), "active seconds": .number(60)], serviceID: "draft", to: initial, source: source)
        var edited = first; edited.set("progress_summary", value: ProjectServiceBridge.text("My narrative"), source: source)
        let second = ProjectServiceBridge.applying(["progress_summary": ProjectServiceBridge.text("Observed"), "active seconds": .number(120), "status": .string("Done")], serviceID: "draft", to: edited, source: source)
        XCTAssertEqual(second.value("progress_summary", source: source).display, "My narrative")
        XCTAssertEqual(second.value("active seconds", source: source)["number"], .number(120))
        XCTAssertNil(second.local["computed"]); XCTAssertEqual(second.serviceRecordID, "draft")
    }

    func testSelectedProjectIncomingScopeIncludesUnacceptedAndNewRelations() {
        func relation(_ id: String) -> ProjectJSON { ProjectJSON(["type": "relation", "relation": [["id": id]]]) }
        let project = ProjectGraphRecord(id: "project", pageID: "p", sourceID: "projects", kind: .projects, remote: ["assets": relation("a")])
        let asset = ProjectGraphRecord(id: "asset", pageID: "a", sourceID: "assets", kind: .assets, remote: ["collections": relation("c")])
        let collection = ProjectGraphRecord(id: "collection", pageID: "c", sourceID: "collections", kind: .collections, remote: [:])
        let records = [project, asset, collection]
        XCTAssertTrue(ProjectGraphIndex(records: records).related(to: project).isEmpty)
        XCTAssertEqual(Set(ProjectGraphIndex(records: records, includingIncoming: true).related(to: project).map(\.id)), ["asset", "collection"])
    }

    func testDeepWorkHierarchyAndComputedMilestoneCompletion() {
        func relation(_ ids: [String]) -> ProjectJSON { ProjectJSON(["type": "relation", "relation": ids.map { ["id": $0] }]) }
        let project = ProjectGraphRecord(id: "p", pageID: "p", sourceID: "projects", kind: .projects, local: ["features": relation(["f0"])])
        let features = (0..<8).map { index in ProjectGraphRecord(id: "f\(index)", pageID: "f\(index)", sourceID: "features", kind: .features, local: ["children": relation(index < 7 ? ["f\(index + 1)"] : ["t0"])]) }
        let tasks = (0..<6).map { index in ProjectGraphRecord(id: "t\(index)", pageID: "t\(index)", sourceID: "tasks", kind: .tasks, local: ["children": relation(index < 5 ? ["t\(index + 1)"] : [])]) }
        XCTAssertEqual(ProjectGraphIndex(records: [project] + features + tasks).related(to: project).count, 14)
        let source = ProjectGraphSource(id: "milestones", title: "Milestones", kind: .milestones, schema: ProjectJSON(["all tasks complete?": ["id": "done", "type": "formula"], "tasks": ["id": "tasks", "type": "relation"], "status": ["id": "status", "type": "formula"]]))
        var milestone = ProjectGraphRecord(sourceID: "milestones", kind: .milestones, local: ["done": ProjectJSON(["type": "formula", "formula": ["type": "boolean", "boolean": true]])])
        XCTAssertFalse(ProjectGraph.isCompleted(milestone, source: source))
        milestone.local["tasks"] = relation(["t0"])
        XCTAssertTrue(ProjectGraph.isCompleted(milestone, source: source))
        milestone.set("status", value: .string("Manual"), source: source)
        XCTAssertNil(milestone.local["status"])
    }

    func testInitialImportProtectsLocalEditsAndTreatsRemoteEmptiesAsFills() {
        let source = ProjectGraphSource(id: "projects", title: "Projects", kind: .projects, schema: ProjectJSON(["summary": ["id": "summary", "type": "rich_text"], "domain": ["id": "domain", "type": "select"]]))
        var record = ProjectGraphRecord(pageID: "p", sourceID: "projects", kind: .projects, remote: ["summary": text("Remote story"), "domain": ProjectJSON(["type": "select", "select": NSNull()])])
        record.seedInitialLocalState(["summary": ProjectServiceBridge.text("Unsent local story"), "domain": ProjectJSON(["name": "Technology"])], source: source)
        XCTAssertEqual(record.changes.first { $0.id == "summary" }?.state, .conflict)
        XCTAssertEqual(record.changes.first { $0.id == "domain" }?.state, .outgoing)
        record.seedInitialLocalState(["summary": ProjectServiceBridge.text("Should not overwrite")], source: source)
        XCTAssertEqual(record.value("summary", source: source).display, "Unsent local story")
        let work = WorkItem(kind: .task, title: "Legacy", extraFrontMatter: ["notion-id: legacy-id"], url: URL(fileURLWithPath: "/tmp/fixture.bw.md"))
        XCTAssertEqual(work.importedNotionPageID, "legacy-id")
    }

    func testServiceBindingDoesNotSilentlyAcceptIncomingImport() {
        let source = ProjectGraphSource(id: "ideas", title: "Ideas", kind: .ideas, schema: ProjectJSON(["idea": ["id": "title", "type": "title"], "one liner": ["id": "line", "type": "rich_text"]]))
        let incoming = ProjectGraphRecord(pageID: "page", sourceID: "ideas", kind: .ideas, remote: ["title": ProjectJSON(["type": "title", "title": [["text": ["content": "Notion name"]]]]), "line": text("Notion description")])
        let bound = ProjectServiceBridge.applying(["idea": ProjectServiceBridge.text("Local name"), "one liner": ProjectServiceBridge.text(nil)], serviceID: "idea", to: incoming, source: source)
        XCTAssertTrue(bound.baseline.isEmpty)
        XCTAssertTrue(bound.changes.contains { $0.id == "title" && $0.state == .conflict })
        XCTAssertTrue(bound.changes.contains { $0.id == "line" && $0.state == .incoming })
    }

    func testServiceDateProjectionRetainsDayAndRangeWithoutEcho() {
        let source = ProjectGraphSource(id: "ideas", title: "Ideas", kind: .ideas, schema: ProjectJSON(["defer until": ["id": "date", "type": "date"]]))
        let values = ["date": ProjectJSON(["type": "date", "date": ["start": "2026-10-03", "end": "2026-10-05"]])]
        let record = ProjectGraphRecord(pageID: "page", sourceID: "ideas", kind: .ideas, local: values, baseline: values, remote: values)
        let bound = ProjectServiceBridge.applying(["defer until": ProjectJSON(["start": "2026-10-03T00:00:00Z"])], serviceID: "idea", to: record, source: source)
        XCTAssertEqual(bound.local, values); XCTAssertTrue(bound.changes.isEmpty)
        XCTAssertNotNil(ServiceDates.parse("2026-10-03"))
    }

    func testEmptyPageImportIsAcknowledgedAndBrowsesWithPlaceholder() throws {
        let store = try ProjectGraphStore(database: Database(inMemory: true))
        let empty = ProjectJSON(["type": "title", "title": []])
        let record = ProjectGraphRecord(pageID: "p", sourceID: "s", kind: .projects, remote: ["title": empty]); try store.save(record)
        try store.acceptIncoming(record.id)
        let accepted = try XCTUnwrap(store.record(id: record.id))
        XCTAssertEqual(accepted.title, "Untitled"); XCTAssertEqual(accepted.local["title"], empty)
        XCTAssertFalse(accepted.baseline.isEmpty); XCTAssertTrue(accepted.changes.isEmpty)
    }
    func testPreviewCachePreservesContentQueriesAndIgnoresExpiringAuthorization() throws {
        let first = try XCTUnwrap(URL(string: "https://example.com/preview?id=1&X-Amz-Signature=old&X-Amz-Date=one"))
        let renewed = try XCTUnwrap(URL(string: "https://example.com/preview?id=1&X-Amz-Signature=new&X-Amz-Date=two"))
        let different = try XCTUnwrap(URL(string: "https://example.com/preview?id=2"))
        XCTAssertEqual(ProjectMediaResolver.cacheIdentity(for: first), ProjectMediaResolver.cacheIdentity(for: renewed))
        XCTAssertNotEqual(ProjectMediaResolver.cacheIdentity(for: first), ProjectMediaResolver.cacheIdentity(for: different))
    }

    func testUnresolvedReportingIncludesStagedRelationsAndRecognizesDraftIDs() throws {
        let store = try ProjectGraphStore(database: Database(inMemory: true))
        let draft = ProjectGraphRecord(id: "draft", sourceID: "s", kind: .assets)
        let record = ProjectGraphRecord(sourceID: "s", kind: .projects, remote: ["links": ProjectJSON(["type": "relation", "relation": [["id": "missing"], ["id": "draft"]]])])
        try store.save(draft); try store.save(record)
        XCTAssertEqual(try store.unresolvedReferences(), ["missing"])
    }

    func testReferenceDetailsSeparateExternalSourcesFromMissingConfiguredRecords() throws {
        let store = try ProjectGraphStore(database: Database(inMemory: true))
        let source = ProjectGraphSource(id: "projects", title: "Projects", kind: .projects, schema: ProjectJSON(["Assets": ["id": "assets", "type": "relation", "relation": ["data_source_id": "assets"]], "Automation Logs": ["id": "logs", "type": "relation", "relation": ["data_source_id": "external"]]]))
        let assets = ProjectGraphSource(id: "assets", title: "Assets", kind: .assets, schema: .object([:]))
        try store.save(ProjectGraphRecord(sourceID: "projects", kind: .projects, remote: ["assets": ProjectJSON(["type": "relation", "relation": [["id": "missing-asset"]]]), "logs": ProjectJSON(["type": "relation", "relation": [["id": "external-log"]]])]))
        XCTAssertEqual(try store.referenceDetails(sources: [source, assets]), ["Missing Assets records": 1, "External: Automation Logs": 1])
    }

    func testServiceSelectionRefreshPreservesAcknowledgedNotionMetadata() {
        let source = ProjectGraphSource(id: "ideas", title: "Ideas", kind: .ideas, schema: ProjectJSON(["tags": ["id": "tags", "type": "multi_select"]]))
        let raw = ProjectJSON([["name": "swift"]])
        let canonical = ProjectJSON(["id": "tags", "type": "multi_select", "multi_select": [["id": "option-id", "name": "swift", "color": "blue"]]])
        var record = ProjectGraphRecord(pageID: "page", sourceID: source.id, kind: .ideas,
            local: ["tags": ProjectJSON(["id": "tags", "type": "multi_select", "multi_select": [["name": "swift"]]])], baseline: ["tags": canonical], remote: ["tags": canonical])
        record.serviceSnapshot = ["tags": raw]
        let repaired = ProjectServiceBridge.applying(["tags": raw], serviceID: "idea", to: record, source: source)
        XCTAssertEqual(repaired.local["tags"], canonical)
        XCTAssertEqual(repaired.baseline, record.baseline)
        XCTAssertEqual(ProjectServiceBridge.applying(["tags": raw], serviceID: "idea", to: repaired, source: source), repaired)
        let edited = ProjectServiceBridge.applying(["tags": ProjectJSON([["name": "swift"], ["name": "new tag"]])], serviceID: "idea", to: repaired, source: source)
        XCTAssertEqual(edited.local["tags"]?["multi_select"].array.count, 2)
        XCTAssertEqual(edited.changes.first?.state, .outgoing, "A real selection edit stays pending")
    }

    func testMultiSelectMetadataOnlyDifferenceDoesNotRequireAnotherMerge() {
        let source = ProjectGraphSource(id: "ideas", title: "Ideas", kind: .ideas, schema: ProjectJSON(["tags": ["id": "tags", "type": "multi_select"]]))
        let canonical = ProjectJSON(["id": "tags", "type": "multi_select", "multi_select": [["id": "option-id", "name": "swift", "color": "blue"]]])
        let record = ProjectGraphRecord(pageID: "page", sourceID: source.id, kind: .ideas,
            local: ["tags": ProjectJSON(["id": "tags", "type": "multi_select", "multi_select": [["name": "swift"]]])], baseline: ["tags": canonical], remote: ["tags": canonical])
        XCTAssertTrue(record.changes.isEmpty)
        XCTAssertTrue(ProjectSyncTriage.items(records: [record], sources: [source]).isEmpty)
    }

}
