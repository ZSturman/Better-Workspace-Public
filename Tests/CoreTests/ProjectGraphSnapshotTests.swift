import XCTest
@testable import BetterWorkspaceCore

final class ProjectGraphSnapshotTests: XCTestCase {
    /// The Mac's Sync Center reads the snapshot; the policy and health must reach it, or
    /// the toolbar sorts with defaults while automatic passes follow the person's choice.
    func testSnapshotCarriesTheSyncPolicyAndHealth() throws {
        let store = try ProjectGraphStore(database: Database(inMemory: true))
        let source = ProjectGraphSource(id: "logs", title: "Work Logs", kind: .workLogs, schema: ProjectJSON(["Entry": ["id": "title", "type": "title"]]))
        try store.write("sources", [source])
        var draft = ProjectGraphRecord(id: "service", sourceID: source.id, kind: .workLogs); draft.serviceRecordID = "day"
        draft.set("Entry", value: ProjectServiceBridge.text("Day"), source: source, changedAt: nil)
        try store.save(draft)
        XCTAssertEqual(try store.snapshot().triage.first?.bucket, .obsolete)
        try store.write(ProjectSyncTriage.Policy.key, ProjectSyncTriage.Policy(receiveNotionChanges: true, offerServiceRecords: true))
        var health = ProjectSyncHealth(); health.record(.init(), report: .init(), at: Date(timeIntervalSince1970: 1))
        try store.write(ProjectSyncHealth.key, health)
        let snapshot = try store.snapshot()
        XCTAssertEqual(snapshot.policy, .init(receiveNotionChanges: true, offerServiceRecords: true))
        XCTAssertEqual(snapshot.health, health)
        XCTAssertEqual(snapshot.triage.first?.bucket, .decision, "Triage follows the stored policy")
    }

    func testSnapshotPreservesTriageIndexesAndDeletionProtection() throws {
        let store = try ProjectGraphStore(database: Database(inMemory: true))
        let source = ProjectGraphSource(id: "projects", title: "Projects", kind: .projects,
            schema: ProjectJSON(["Name": ["id": "name", "type": "title"]]))
        try store.write("sources", [source])
        var project = ProjectGraphRecord(id: "project", pageID: "project-page", sourceID: source.id, kind: .projects)
        project.localProjectID = "local-project"
        project.set("Name", value: ProjectJSON([["text": ["content": "Edited project"]]]), source: source)
        try store.save(project)
        var incoming = ProjectGraphRecord(id: "incoming", pageID: "incoming-page", sourceID: source.id, kind: .projects)
        incoming.remote = project.local
        try store.save(incoming)
        var deleted = incoming; deleted.id = "deleted"; deleted.pageID = "deleted-page"; deleted.locallyDeleted = true
        try store.save(deleted)
        try store.write("zen.choices.example.details", ["unrelated": "draft"])

        let snapshot = try store.snapshot()
        XCTAssertEqual(Set(snapshot.records.map(\.id)), ["project", "incoming"])
        XCTAssertEqual(snapshot.projectsByLocalID["local-project"], project)
        XCTAssertEqual(snapshot.projectsByPageID[ProjectGraph.normalizedID("project-page")], project)
        XCTAssertEqual(snapshot.sources, [source])
        XCTAssertEqual(snapshot.triage.map(\.id), ProjectSyncTriage.items(records: snapshot.records, sources: snapshot.sources).map(\.id))
        XCTAssertTrue(snapshot.incomingIDs.contains("incoming"))
        XCTAssertTrue(snapshot.outgoingIDs.contains("project"))
        XCTAssertFalse(snapshot.incomingIDs.contains("deleted"))
        XCTAssertEqual(try store.read("zen.choices.example.details", as: [String: String].self), ["unrelated": "draft"])
    }

    func testBackgroundSnapshotSeesSubsequentSavedEditsWithoutMutatingStore() async throws {
        let database = try Database(inMemory: true)
        let store = try ProjectGraphStore(database: database)
        var record = ProjectGraphRecord(id: "draft", sourceID: "tasks", kind: .tasks)
        try store.save(record)
        let first = try await Task.detached { try store.snapshot() }.value
        record.archiveRequested = true
        try store.save(record)
        let second = try await Task.detached { try store.snapshot() }.value
        XCTAssertFalse(try XCTUnwrap(first.records.first).archiveRequested)
        XCTAssertTrue(try XCTUnwrap(second.records.first).archiveRequested)
        XCTAssertEqual(try store.record(id: "draft"), record)
    }

    // MARK: Decoded-record cache (November 9 power work)

    /// Reads reuse decoded records, but never past a write from this connection,
    /// another connection, a rollback or a deletion.
    func testCachedRecordsFollowEveryWriteThatCanChangeThem() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("graph-cache-\(UUID().uuidString).sqlite")
        defer { for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: url.path + suffix) } }
        let store = try ProjectGraphStore(database: Database(url: url))
        let other = try ProjectGraphStore(database: Database(url: url))
        var first = ProjectGraphRecord(id: "first", sourceID: "tasks", kind: .tasks)
        try store.save(first)
        XCTAssertEqual(try store.records().map(\.id), ["first"])

        first.archiveRequested = true
        try store.save(first)
        XCTAssertEqual(try store.records().first?.archiveRequested, true, "This connection's write")

        try other.save(ProjectGraphRecord(id: "second", sourceID: "tasks", kind: .tasks))
        XCTAssertEqual(Set(try store.records().map(\.id)), ["first", "second"], "Another connection's commit")

        struct Abort: Error {}
        let database = try Database(url: url), rolledBack = try ProjectGraphStore(database: database)
        _ = try rolledBack.records()
        XCTAssertThrowsError(try database.transaction {
            try rolledBack.save(ProjectGraphRecord(id: "third", sourceID: "tasks", kind: .tasks))
            XCTAssertTrue(try rolledBack.records().contains { $0.id == "third" }, "Visible inside its own transaction")
            throw Abort()
        })
        XCTAssertFalse(try rolledBack.records().contains { $0.id == "third" }, "Gone after the rollback")

        try database.run("DELETE FROM project_graph_records WHERE id='second'")
        XCTAssertEqual(try rolledBack.records().map(\.id), ["first"])
        XCTAssertEqual(try store.records().map(\.id), ["first"])
    }

    /// An unchanged graph returns the same snapshot, so the Mac skips republishing it.
    func testUnchangedGraphKeepsItsSnapshotContentID() throws {
        let database = try Database(inMemory: true)
        let store = try ProjectGraphStore(database: database)
        try store.save(ProjectGraphRecord(id: "one", sourceID: "tasks", kind: .tasks))
        let first = try store.snapshot()
        try store.write("unrelated", ["key": "value"])
        XCTAssertEqual(try store.snapshot().contentID, first.contentID, "State outside the snapshot does not count")
        try store.write(ProjectSyncTriage.Policy.key, ProjectSyncTriage.Policy(receiveNotionChanges: true, offerServiceRecords: true))
        let policy = try store.snapshot()
        XCTAssertNotEqual(policy.contentID, first.contentID)
        try store.save(ProjectGraphRecord(id: "two", sourceID: "tasks", kind: .tasks))
        let records = try store.snapshot()
        XCTAssertNotEqual(records.contentID, policy.contentID)
        XCTAssertEqual(Set(records.records.map(\.id)), ["one", "two"])
        // Rewriting identical bytes is a write, but not a change.
        XCTAssertEqual(try database.run("UPDATE project_graph_records SET payload = payload"), 2)
        XCTAssertEqual(try store.snapshot().contentID, records.contentID)
    }

    func testProjectJSONDecodesEveryKindAndKeepsBooleansApartFromNumbers() throws {
        let json = #"{"o":{"a":[1,true,"s",null,{"n":false}]},"t":true,"f":false,"one":1,"zero":0,"d":2.5,"s":"x","n":null}"#
        let value = try JSONDecoder().decode(ProjectJSON.self, from: Data(json.utf8))
        XCTAssertEqual(value["t"], .bool(true)); XCTAssertEqual(value["f"], .bool(false))
        XCTAssertEqual(value["one"], .number(1)); XCTAssertEqual(value["zero"], .number(0)); XCTAssertEqual(value["d"], .number(2.5))
        XCTAssertEqual(value["s"], .string("x")); XCTAssertEqual(value["n"], .null)
        XCTAssertEqual(value["o"]["a"], .array([.number(1), .bool(true), .string("s"), .null, .object(["n": .bool(false)])]))
        XCTAssertEqual(try JSONDecoder().decode(ProjectJSON.self, from: JSONEncoder().encode(value)), value)
    }

    func testSourcePropertyLookupMatchesNamesLooselyAndSurvivesCoding() throws {
        let source = ProjectGraphSource(id: "s", title: "Projects", kind: .projects, schema: ProjectJSON([
            "Name": ["id": "title", "type": "title"], " Last Update At ": ["id": "lu", "type": "date"], "Work-Mode": ["id": "wm", "type": "select"]]))
        XCTAssertEqual(source.property(named: "name")?.id, "title")
        XCTAssertEqual(source.property(named: "last update at")?.id, "lu")
        XCTAssertEqual(source.property(named: "Work Mode")?.id, "wm", "Letters and digits only")
        XCTAssertNil(source.property(named: "Missing"))
        XCTAssertEqual(source.name(for: "wm"), "Work-Mode"); XCTAssertEqual(source.name(for: "unknown"), "unknown")
        let decoded = try JSONDecoder().decode(ProjectGraphSource.self, from: JSONEncoder().encode(source))
        XCTAssertEqual(decoded, source); XCTAssertEqual(decoded.hashValue, source.hashValue)
        XCTAssertEqual(decoded.property(named: "work mode")?.id, "wm")
        let coded = try XCTUnwrap(try JSONSerialization.jsonObject(with: JSONEncoder().encode(source)) as? [String: Any])
        XCTAssertEqual(Set(coded.keys), ["id", "title", "kind", "schema"], "Coded fields unchanged")
    }
}
