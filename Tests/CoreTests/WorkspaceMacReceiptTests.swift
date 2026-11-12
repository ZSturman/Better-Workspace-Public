import XCTest
@testable import BetterWorkspaceCore

final class WorkspaceMacReceiptTests: XCTestCase {
    func testUnchangedSourcePollKeepsApprovalReceiptWhileSavingNewPortableContent() throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let observation = try fixture.observe(title: "First")
        let first = try fixture.receipts.commit(observation, sourceID: fixture.sourceID, sourceRoot: fixture.workspace, expectedReceiptID: nil, graph: fixture.graph)
        let repeated = try fixture.receipts.commit(fixture.observe(title: "First"), sourceID: fixture.sourceID, sourceRoot: fixture.workspace, expectedReceiptID: first.id, graph: fixture.graph)
        XCTAssertEqual(first.id, repeated.id, "A no-op poll must not invalidate a person's open creation/merge preview")
        var graph = try fixture.graph.load()
        let note = try graph.save(content: .init(kind: .note, title: "Unbound portable note"), expectedHeads: [], deviceID: UUID(), origin: .iOS)
        let next = try fixture.receipts.commit(.init(replica: graph, bindings: first.bindings), sourceID: fixture.sourceID, sourceRoot: fixture.workspace, expectedReceiptID: repeated.id, graph: fixture.graph)
        XCTAssertEqual(next.id, first.id)
        XCTAssertEqual(try fixture.graph.load().records.first { $0.id == note.recordID }?.resolved, note)
    }

    func testGraphAndSourceReceiptReopenAndStaleReceiptCannotAdvance() throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let observation = try fixture.observe(title: "First")
        let first = try fixture.receipts.commit(observation, sourceID: fixture.sourceID, sourceRoot: fixture.workspace,
            expectedReceiptID: nil, graph: fixture.graph)
        let reopened = try WorkspaceMacReceiptStore(database: Database(url: fixture.database.url))
        XCTAssertEqual(try reopened.load(sourceID: fixture.sourceID), first)
        XCTAssertEqual(try fixture.graph.load().records.first?.resolved?.content.title, "First")
        let stale = try fixture.observe(title: "Old prepared value")
        XCTAssertThrowsError(try reopened.commit(stale, sourceID: fixture.sourceID, sourceRoot: fixture.workspace,
            expectedReceiptID: nil, graph: fixture.graph))
        XCTAssertEqual(try fixture.graph.load().records.first?.resolved?.content.title, "First")
    }

    func testSQLFailureAfterGraphSaveRetainsOldReceiptAndRetryDoesNotDuplicate() throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let original = try fixture.observe(title: "First")
        let first = try fixture.receipts.commit(original, sourceID: fixture.sourceID, sourceRoot: fixture.workspace,
            expectedReceiptID: nil, graph: fixture.graph)
        let changed = try fixture.observe(title: "Second")
        try fixture.database.execute("CREATE TRIGGER reject_owned_receipt BEFORE UPDATE ON workspace_mac_observations BEGIN SELECT RAISE(ABORT,'owned fixture interruption'); END;")
        XCTAssertThrowsError(try fixture.receipts.commit(changed, sourceID: fixture.sourceID, sourceRoot: fixture.workspace,
            expectedReceiptID: first.id, graph: fixture.graph))
        XCTAssertEqual(try fixture.receipts.load(sourceID: fixture.sourceID), first)
        let interrupted = try fixture.graph.load()
        XCTAssertEqual(interrupted.records.first?.resolved?.content.title, "Second")
        try fixture.database.execute("DROP TRIGGER reject_owned_receipt")
        let replay = try fixture.observe(title: "Second")
        XCTAssertEqual(replay.replica.revisions.count, interrupted.revisions.count)
        try fixture.receipts.commit(replay, sourceID: fixture.sourceID, sourceRoot: fixture.workspace,
            expectedReceiptID: first.id, graph: fixture.graph)
        XCTAssertEqual(try fixture.graph.load().revisions.count, interrupted.revisions.count)
        XCTAssertEqual(try fixture.receipts.load(sourceID: fixture.sourceID)?.bindings, replay.bindings)
    }

    func testRootReplacementAndCorruptReceiptNeverResetMetadataOrGraph() throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let observation = try fixture.observe(title: "Retain")
        let first = try fixture.receipts.commit(observation, sourceID: fixture.sourceID, sourceRoot: fixture.workspace,
            expectedReceiptID: nil, graph: fixture.graph)
        let anotherRoot = fixture.root.appendingPathComponent("OtherWorkspace")
        try FileManager.default.createDirectory(at: anotherRoot, withIntermediateDirectories: false)
        let before = try fixture.graph.load()
        XCTAssertNotEqual(try WorkspaceMacReceiptStore.sourceID(deviceID: fixture.deviceID, sourceRoot: fixture.workspace),
                          try WorkspaceMacReceiptStore.sourceID(deviceID: fixture.deviceID, sourceRoot: anotherRoot))
        XCTAssertThrowsError(try fixture.receipts.validateRoot(first, sourceRoot: anotherRoot))
        XCTAssertThrowsError(try fixture.receipts.commit(observation, sourceID: fixture.sourceID, sourceRoot: anotherRoot,
            expectedReceiptID: first.id, graph: fixture.graph))
        XCTAssertEqual(try fixture.graph.load(), before)
        try fixture.database.run("UPDATE workspace_mac_observations SET receipt=? WHERE source_id=?", [.text("corrupt"), .text(fixture.sourceID.uuidString)])
        XCTAssertThrowsError(try fixture.receipts.load(sourceID: fixture.sourceID))
        XCTAssertThrowsError(try fixture.receipts.commit(observation, sourceID: fixture.sourceID, sourceRoot: fixture.workspace,
            expectedReceiptID: nil, graph: fixture.graph))
        XCTAssertEqual(try fixture.graph.load(), before)
        XCTAssertEqual(try fixture.database.query("SELECT receipt FROM workspace_mac_observations", row: { $0.string(0) }), ["corrupt"])
    }

    private final class Fixture {
        let root: URL, workspace: URL
        let sourceID = UUID(), workID = UUID(), deviceID = UUID()
        let graph: WorkspaceReplicaStore, database: Database, receipts: WorkspaceMacReceiptStore
        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("bw-mac-receipts-" + UUID().uuidString)
            workspace = root.appendingPathComponent("Workspace")
            try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
            graph = WorkspaceReplicaStore(directory: root.appendingPathComponent("PrivateGraph"), initialWorkspaceID: sourceID)
            database = try Database(url: root.appendingPathComponent("private.sqlite"))
            receipts = try WorkspaceMacReceiptStore(database: database)
        }
        func observe(title: String) throws -> WorkspaceMacObservation {
            let previous = try receipts.load(sourceID: sourceID)
            let work = MobileWorkItem(id: workID.uuidString, path: "To Do/Record.bw.md", title: title,
                kind: .task, status: .open, stage: .next, priority: .medium, revision: 1, body: "Owned fixture")
            return try WorkspaceMacProjection.observe(.init(workItems: [work]), in: graph.load(), bindings: previous?.bindings ?? [], deviceID: deviceID)
        }
        func remove() { try? FileManager.default.removeItem(at: root) }
    }
}
