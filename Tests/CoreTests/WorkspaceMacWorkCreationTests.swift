import XCTest
@testable import BetterWorkspaceCore

final class WorkspaceMacWorkCreationTests: XCTestCase {
    private struct Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bw-work-create-" + UUID().uuidString)
        var workspace: WorkspaceLocation { .init(root: root) }
        init() throws { try FileManager.default.createDirectory(at: root.appendingPathComponent("To Do"), withIntermediateDirectories: true) }
        func remove() { try? FileManager.default.removeItem(at: root) }
        func request(_ graph: WorkspaceReplica, _ id: UUID, bindings: [WorkspaceMacBinding] = [], reserved: Set<String> = []) throws -> WorkspaceMacWorkCreation {
            try .prepare(recordID: id, in: graph, bindings: bindings, workspace: workspace, directoryPath: "To Do", reservedPaths: reserved)
        }
    }
    func testSameNamesKeepUUIDsAndExistingFilesWithOriginSuffixes() throws {
        let f = try Fixture(); defer { f.remove() }
        let occupied = f.root.appendingPathComponent("To Do/Same name.bw.md")
        let original = Data("Unrelated existing file".utf8); try original.write(to: occupied)
        var graph = try WorkspaceReplica()
        let a = try graph.save(content: .init(kind: .task, title: "Same name", body: "Phone task"), expectedHeads: [], deviceID: UUID(), origin: .iOS)
        let b = try graph.save(content: .init(kind: .feature, title: "Same name", body: "Other task"), expectedHeads: [], deviceID: UUID(), origin: .iOS)
        let first = try f.request(graph, a.recordID)
        let second = try f.request(graph, b.recordID, reserved: [first.relativePath])
        XCTAssertEqual(first.relativePath, "To Do/Same name-iOS.bw.md")
        XCTAssertEqual(second.relativePath, "To Do/Same name-iOS-2.bw.md")
        let (one, binding) = try first.materialize(in: graph, bindings: [], workspace: f.workspace)
        let (two, _) = try second.materialize(in: graph, bindings: [binding], workspace: f.workspace)
        XCTAssertEqual(one.id, a.recordID.uuidString); XCTAssertEqual(two.id, b.recordID.uuidString)
        XCTAssertEqual(try Data(contentsOf: occupied), original)
        XCTAssertEqual(one.body, "Phone task"); XCTAssertEqual(two.body, "Other task")
    }
    func testDurableReplayAcknowledgesExactRevisionThenAppliesLaterEdit() throws {
        let f = try Fixture(); defer { f.remove() }
        var graph = try WorkspaceReplica()
        let base = try graph.save(content: .init(kind: .milestone, title: "Release", body: "First\n"), expectedHeads: [], deviceID: UUID(), origin: .iOS)
        let request = try f.request(graph, base.recordID)
        let journal = WorkspaceMacCreationJournal(directory: f.root.appendingPathComponent("PrivateJournal"))
        try request.validateApproval(in: graph, bindings: [])
        try journal.begin(request)
        let (written, binding) = try request.materialize(in: graph, bindings: [], workspace: f.workspace)
        var changed = base.content; changed.body = "Later offline edit"
        let later = try graph.save(recordID: base.recordID, content: changed, expectedHeads: [base.id], deviceID: UUID(), origin: .iOS)
        XCTAssertThrowsError(try request.validateApproval(in: graph, bindings: []))
        let restored = try XCTUnwrap(WorkspaceMacCreationJournal(directory: f.root.appendingPathComponent("PrivateJournal")).pending().first)
        let bytes = try Data(contentsOf: written.url)
        let (replayed, exact) = try restored.materialize(in: graph, bindings: [], workspace: f.workspace)
        XCTAssertEqual(replayed.id, written.id); XCTAssertEqual(exact, binding)
        XCTAssertEqual(exact.observedRevisionID, base.id); XCTAssertNotEqual(exact.observedRevisionID, later.id)
        XCTAssertEqual(try Data(contentsOf: written.url), bytes)
        guard case .update(let update) = try WorkspaceMacProjection.prepareWorkSave(recordID: base.recordID, in: graph, bindings: [exact], workspace: f.workspace) else { return XCTFail("Later edits must use the existing writer") }
        XCTAssertEqual(try WorkItemService().update(update).body, changed.body)
        try journal.finish(restored); XCTAssertTrue(try journal.pending().isEmpty)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: f.root.appendingPathComponent("To Do").path).count, 1)
    }
    func testOccupiedAfterPreviewAndEditedReplayNeverOverwrite() throws {
        let f = try Fixture(); defer { f.remove() }
        var graph = try WorkspaceReplica()
        let base = try graph.save(content: .init(kind: .task, title: "Race", body: "Planned"), expectedHeads: [], deviceID: UUID(), origin: .iOS)
        let request = try f.request(graph, base.recordID)
        let url = f.root.appendingPathComponent(request.relativePath)
        let journal = WorkspaceMacCreationJournal(directory: f.root.appendingPathComponent("PrivateJournal"))
        try journal.begin(request)
        let external = Data("A file created after the preview".utf8); try external.write(to: url)
        XCTAssertThrowsError(try request.materialize(in: graph, bindings: [], workspace: f.workspace))
        XCTAssertEqual(try Data(contentsOf: url), external)
        try journal.finish(request)
        XCTAssertTrue(try journal.pending().isEmpty)
        XCTAssertEqual(try Data(contentsOf: url), external, "Canceling a queued write keeps existing files")
        XCTAssertEqual(graph.records.first?.resolved?.id, base.id, "Canceling keeps the portable item")
        XCTAssertEqual(try f.request(graph, base.recordID).relativePath, "To Do/Race-iOS.bw.md")
        // Remove only this test's own synthetic file, then verify interrupted replay.
        try FileManager.default.removeItem(at: url)
        var saved = try request.materialize(in: graph, bindings: [], workspace: f.workspace).0
        saved.body = "An external edit"; saved = try WorkItemService().update(saved)
        XCTAssertThrowsError(try request.materialize(in: graph, bindings: [], workspace: f.workspace))
        XCTAssertEqual(try WorkItemService().read(at: saved.url)?.body, saved.body)
    }
    func testReplacedDestinationAndSymlinkAreRefusedWithoutCreatingFiles() throws {
        let f = try Fixture(); defer { f.remove() }
        var graph = try WorkspaceReplica()
        let base = try graph.save(content: .init(kind: .goal, title: "Bounded"), expectedHeads: [], deviceID: UUID(), origin: .mac)
        let request = try f.request(graph, base.recordID)
        let directory = f.root.appendingPathComponent("To Do"), moved = f.root.appendingPathComponent("OwnedOldQueue")
        try FileManager.default.moveItem(at: directory, to: moved)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        XCTAssertThrowsError(try request.materialize(in: graph, bindings: [], workspace: f.workspace))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
        try FileManager.default.removeItem(at: directory)
        try FileManager.default.createSymbolicLink(at: directory, withDestinationURL: moved)
        XCTAssertThrowsError(try f.request(graph, base.recordID))
        XCTAssertThrowsError(try request.materialize(in: graph, bindings: [], workspace: f.workspace))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: moved.path).isEmpty)
    }
    func testProjectMustBeBoundAndRetainItsDirectoryIdentity() throws {
        let f = try Fixture(); defer { f.remove() }
        var graph = try WorkspaceReplica()
        let project = try graph.save(content: .init(kind: .project, title: "Project"), expectedHeads: [], deviceID: UUID(), origin: .mac)
        let task = try graph.save(content: .init(kind: .task, title: "Child", parentID: project.recordID), expectedHeads: [], deviceID: UUID(), origin: .iOS)
        XCTAssertThrowsError(try f.request(graph, task.recordID))
        let path = "Projects/Project", url = f.root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let binding = WorkspaceMacBinding(recordID: project.recordID, source: .project, sourceID: project.recordID.uuidString, relativePath: path, observedRevisionID: project.id)
        let request = try f.request(graph, task.recordID, bindings: [binding])
        let (created, _) = try request.materialize(in: graph, bindings: [binding], workspace: f.workspace)
        XCTAssertEqual(created.projectPath, path)
        try FileManager.default.moveItem(at: url, to: f.root.appendingPathComponent("OwnedOriginalProject"))
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        XCTAssertThrowsError(try request.materialize(in: graph, bindings: [binding], workspace: f.workspace))
        XCTAssertThrowsError(try f.request(graph, project.recordID))
    }
}
