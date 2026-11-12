import XCTest
@testable import BetterWorkspaceCore

final class WorkspaceDeletionSafetyTests: XCTestCase {
    private func uncertain(_ path: String) -> ProjectGraphRecord {
        let field = ProjectJSON(["type": "rich_text", "rich_text": [["text": ["content": "Retained description"]]]])
        var record = ProjectGraphRecord(id: "uncertain", sourceID: "source", kind: .tasks,
            local: ["details": field], baseline: ["details": .null], remote: ["details": field])
        record.localPath = path; record.ambiguousCreate = true; record.error = "Create response was lost"
        record.serviceSnapshot = ["details": field]; record.serviceAcknowledgementPending = true
        return record
    }

    func testMissingFileSyncRetainsUncertainSentAndUnrelatedDrafts() throws {
        let store = try ProjectGraphStore(database: Database(inMemory: true))
        let ambiguous = uncertain("/fixture/selected")
        var ordinary = ProjectGraphRecord(id: "ordinary", sourceID: "source", kind: .tasks); ordinary.localPath = ambiguous.localPath
        var sent = ProjectGraphRecord(id: "sent", pageID: "remote", sourceID: "source", kind: .tasks); sent.localPath = ambiguous.localPath
        var unrelated = ProjectGraphRecord(id: "unrelated", sourceID: "source", kind: .tasks); unrelated.localPath = "/fixture/other"
        for record in [ambiguous, ordinary, sent, unrelated] { try store.save(record) }
        try store.removeUnsent(localPath: "/fixture/selected", reviewed: [ambiguous, ordinary, sent, unrelated])
        XCTAssertNil(try store.record(id: ordinary.id))
        XCTAssertEqual(try store.record(id: ambiguous.id), ambiguous)
        XCTAssertEqual(try store.record(id: sent.id), sent)
        XCTAssertEqual(try store.record(id: unrelated.id), unrelated)
        XCTAssertTrue(try store.snapshot().records.contains { $0.id == ambiguous.id }, "Recovery must remain visible")
        try store.removeUnsent(localPath: "/fixture/selected", reviewed: [ambiguous, ordinary, sent, unrelated])
        XCTAssertEqual(try store.record(id: ambiguous.id), ambiguous)
    }

    func testWholeFolderDeletionRetainsAmbiguousRecoveryAndRemoteState() throws {
        let store = try ProjectGraphStore(database: Database(inMemory: true))
        let ambiguous = uncertain("/fixture/folder/nested/note.bw.md")
        var ordinary = ProjectGraphRecord(id: "ordinary", sourceID: "source", kind: .tasks); ordinary.localPath = "/fixture/folder/task.bw.md"
        var sent = ProjectGraphRecord(id: "sent", pageID: "remote", sourceID: "source", kind: .tasks); sent.localPath = "/fixture/folder/linked.bw.md"
        sent.local = ambiguous.local; sent.baseline = ambiguous.baseline; sent.remote = ambiguous.remote
        var sibling = ProjectGraphRecord(id: "sibling", sourceID: "source", kind: .tasks); sibling.localPath = "/fixture/folder-other/keep.bw.md"
        for record in [ambiguous, ordinary, sent, sibling] { try store.save(record) }
        try store.recordLocalDeletion(path: "/fixture/folder")
        XCTAssertEqual(try store.record(id: ambiguous.id), ambiguous)
        XCTAssertNil(try store.record(id: ordinary.id))
        var deleted = sent; deleted.locallyDeleted = true
        XCTAssertEqual(try store.record(id: sent.id), deleted)
        XCTAssertEqual(try store.record(id: sibling.id), sibling)
        XCTAssertTrue(try store.snapshot().records.contains { $0.id == ambiguous.id })
        XCTAssertFalse(try store.snapshot().records.contains { $0.id == sent.id })
    }
}

extension WorkspaceDeletionSafetyTests {
    func testReviewedDraftRemovalRejectsConcurrentEditsAndPreservesNewDrafts() throws {
        let store = try ProjectGraphStore(database: Database(inMemory: true))
        var first = ProjectGraphRecord(id: "first", sourceID: "source", kind: .tasks); first.localPath = "/fixture/selected"
        var second = ProjectGraphRecord(id: "second", sourceID: "source", kind: .tasks); second.localPath = first.localPath
        for record in [first, second] { try store.save(record) }
        var changed = second; changed.error = "New recovery information"; try store.save(changed)
        XCTAssertThrowsError(try store.removeUnsent(localPath: "/fixture/selected", reviewed: [first, second]))
        XCTAssertEqual(try store.record(id: first.id), first, "The transaction must roll back partial removal")
        XCTAssertEqual(try store.record(id: second.id), changed)
        var later = ProjectGraphRecord(id: "later", sourceID: "source", kind: .tasks); later.localPath = first.localPath; try store.save(later)
        try store.removeUnsent(localPath: "/fixture/selected", reviewed: [first, changed])
        XCTAssertEqual(try store.record(id: later.id), later)
    }

    private final class Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bw-missing-review-" + UUID().uuidString)
        var workspace: WorkspaceLocation { .init(root: root.appendingPathComponent("Workspace")) }
        var parent: URL { workspace.root.appendingPathComponent("To Do") }
        var item: WorkItem { .init(id: "owned-task", kind: .task, title: "Reviewed missing task", body: "Keep this text", url: parent.appendingPathComponent("Task.bw.md")) }
        init() throws { try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true) }
        func capture() throws -> WorkspaceMissingWorkReview { try .capture([item], graphRecords: [], workspace: workspace) }
        func remove() { try? FileManager.default.removeItem(at: root) }
    }

    func testReviewBindsGraphDraftsByUUIDAndKindInsteadOfFilename() throws {
        let f = try Fixture(); defer { f.remove() }
        var owned = ProjectGraphRecord(id: f.item.id, sourceID: "source", kind: .tasks); owned.localPath = f.item.url.canonicalPath
        var unrelated = owned; unrelated.id = "different-identity"
        var foreignKind = owned; foreignKind.kind = .assets
        let review = try WorkspaceMissingWorkReview.capture([f.item], graphRecords: [owned, unrelated, foreignKind], workspace: f.workspace)
        XCTAssertEqual(review.graphRecords, [owned])
    }

    func testMissingReviewRestoresOnlyAbsentOriginalAndRefusesReplacement() throws {
        let f = try Fixture(); defer { f.remove() }
        let review = try f.capture(), entry = try XCTUnwrap(review.entries.first)
        let saved = try review.restore(entry, current: f.item, workspace: f.workspace)
        XCTAssertEqual(saved.id, f.item.id); XCTAssertEqual(saved.body, f.item.body)
        XCTAssertThrowsError(try review.validate(entry, current: f.item, workspace: f.workspace))
        XCTAssertThrowsError(try review.restore(entry, current: f.item, workspace: f.workspace))
        XCTAssertEqual(WorkItemService().read(at: f.item.url)?.id, f.item.id)
    }

    func testMissingReviewRefusesChangedParentRootSymlinkAndAppEdits() throws {
        let f = try Fixture(); defer { f.remove() }
        let review = try f.capture(), entry = try XCTUnwrap(review.entries.first)
        var changed = f.item; changed.body = "New app edit"
        XCTAssertThrowsError(try review.validate(entry, current: changed, workspace: f.workspace))
        try FileManager.default.moveItem(at: f.parent, to: f.parent.deletingLastPathComponent().appendingPathComponent("Old parent"))
        try FileManager.default.createDirectory(at: f.parent, withIntermediateDirectories: false)
        XCTAssertThrowsError(try review.validate(entry, current: f.item, workspace: f.workspace))
        let next = try f.capture(), nextEntry = try XCTUnwrap(next.entries.first)
        try FileManager.default.moveItem(at: f.workspace.root, to: f.root.appendingPathComponent("Old workspace"))
        try FileManager.default.createDirectory(at: f.parent, withIntermediateDirectories: true)
        XCTAssertThrowsError(try next.validate(nextEntry, current: f.item, workspace: f.workspace))
        try FileManager.default.removeItem(at: f.parent)
        try FileManager.default.createSymbolicLink(at: f.parent, withDestinationURL: f.root.appendingPathComponent("Old workspace/To Do"))
        XCTAssertThrowsError(try f.capture())
    }

    func testMissingParentIsNeverRecreatedAndForeignPathsAreRefused() throws {
        let f = try Fixture(); defer { f.remove() }
        try FileManager.default.removeItem(at: f.parent)
        let review = try f.capture(), entry = try XCTUnwrap(review.entries.first)
        try review.validate(entry, current: f.item, workspace: f.workspace)
        XCTAssertThrowsError(try review.restore(entry, current: f.item, workspace: f.workspace))
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.parent.path))
        let unsafe = WorkItem(id: "foreign", kind: .task, title: "No", url: f.workspace.root.appendingPathComponent("Projects/.git/Task.bw.md"))
        XCTAssertThrowsError(try WorkspaceMissingWorkReview.capture([unsafe], graphRecords: [], workspace: f.workspace))
    }
}
