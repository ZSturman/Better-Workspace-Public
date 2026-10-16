import XCTest
@testable import BetterWorkspaceCore

final class ProjectGraphSnapshotTests: XCTestCase {
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
}
