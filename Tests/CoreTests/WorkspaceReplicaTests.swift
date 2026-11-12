import XCTest
import SwiftData
@testable import BetterWorkspaceCore

final class WorkspaceReplicaTests: XCTestCase {
    private let device = UUID()

    func testStandaloneKindsPersistAcrossReopenAndUseUUIDIdentity() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let store = WorkspaceReplicaStore(directory: root, initialWorkspaceID: UUID())
        let workspaceID = try store.load().workspaceID
        let project = try store.save(content: .init(kind: .project, title: "Same name"), expectedHeads: [], deviceID: device, origin: .iOS)
        for kind in WorkspaceRecordContent.Kind.allCases where kind != .project {
            try store.save(content: .init(kind: kind, title: "Same name", body: "Offline " + kind.rawValue, parentID: project.recordID),
                expectedHeads: [], deviceID: device, origin: .iOS)
        }
        let reopened = try WorkspaceReplicaStore(directory: root, initialWorkspaceID: UUID()).load()
        XCTAssertEqual(reopened.workspaceID, workspaceID)
        XCTAssertEqual(reopened.records.count, WorkspaceRecordContent.Kind.allCases.count)
        XCTAssertEqual(Set(reopened.records.map(\.id)).count, reopened.records.count)
        XCTAssertEqual(reopened.records.filter { $0.resolved?.content.parentID == project.recordID }.count, WorkspaceRecordContent.Kind.allCases.count - 1)
    }

    func testConcurrentEditsAndDeletionRetainBothVersionsRegardlessOfClock() throws {
        let id = UUID(), first = revision(record: UUID(), title: "Before")
        let local = revision(record: first.recordID, title: "Edited offline", parents: [first.id], at: .distantPast)
        let deleted = revision(record: first.recordID, title: "Before", parents: [first.id], deleted: true, at: .distantFuture)
        let a = try WorkspaceReplica(workspaceID: id, revisions: [first, local])
        let b = try WorkspaceReplica(workspaceID: id, revisions: [first, deleted])
        let merged = try a.merging(b)
        XCTAssertEqual(merged.revisions.count, 3)
        let state = try XCTUnwrap(merged.records.first)
        XCTAssertTrue(state.isConflict)
        XCTAssertNil(state.resolved)
        XCTAssertEqual(Set(state.heads.map(\.id)), [local.id, deleted.id])
        XCTAssertEqual(try merged.fingerprint, try b.merging(a).fingerprint)
        XCTAssertEqual(try merged.fingerprint, try merged.merging(a).merging(b).fingerprint)
    }

    func testResolutionRetainsHistoryAndCannotConsumeAnUnseenChange() throws {
        let root = revision(record: UUID(), title: "Before")
        let a = revision(record: root.recordID, title: "iPhone", parents: [root.id])
        let b = revision(record: root.recordID, title: "Mac", parents: [root.id])
        var replica = try WorkspaceReplica(revisions: [root, a, b])
        let original = replica
        XCTAssertThrowsError(try replica.save(recordID: root.recordID, content: a.content, expectedHeads: [a.id], deviceID: device, origin: .iOS, resolvingConflict: true))
        XCTAssertEqual(replica, original)
        XCTAssertThrowsError(try replica.save(recordID: root.recordID, content: a.content, expectedHeads: [a.id, b.id], deviceID: device, origin: .iOS))
        let resolution = try replica.save(recordID: root.recordID, content: a.content, expectedHeads: [a.id, b.id], deviceID: device, origin: .iOS, resolvingConflict: true)
        XCTAssertEqual(replica.revisions.count, 4)
        XCTAssertEqual(replica.records.first?.resolved?.id, resolution.id)
        let late = revision(record: root.recordID, title: "iPad still offline", parents: [root.id])
        replica = try replica.merging(WorkspaceReplica(workspaceID: replica.workspaceID, revisions: [root, late]))
        XCTAssertEqual(Set(replica.records.first!.heads.map(\.id)), [late.id, resolution.id])
    }

    func testOutOfOrderPagesNeverHideLastUsableVersion() throws {
        let root = revision(record: UUID(), title: "Before")
        let middle = revision(record: root.recordID, title: "Middle", parents: [root.id])
        let latest = revision(record: root.recordID, title: "Latest", parents: [middle.id])
        var replica = try WorkspaceReplica(revisions: [root, latest])
        XCTAssertEqual(replica.pendingRevisionCount, 1)
        XCTAssertEqual(replica.records.first?.resolved?.id, root.id)
        XCTAssertThrowsError(try replica.save(recordID: latest.recordID, content: latest.content, expectedHeads: [], deviceID: device, origin: .iOS))
        replica = try replica.merging(WorkspaceReplica(revisions: [middle]))
        XCTAssertEqual(replica.pendingRevisionCount, 0)
        XCTAssertEqual(replica.records.first?.resolved?.id, latest.id)
    }

    func testRevisionCollisionAndMalformedAncestryAreRejected() throws {
        let root = revision(record: UUID(), title: "Keep")
        let different = WorkspaceRecordRevision(id: root.id, recordID: root.recordID, deviceID: root.deviceID, origin: .iOS, createdAt: root.createdAt, content: .init(kind: .note, title: "Overwrite"))
        let replica = try WorkspaceReplica(revisions: [root])
        XCTAssertThrowsError(try replica.merging(WorkspaceReplica(revisions: [different]))) { XCTAssertEqual($0 as? WorkspaceReplicaError, .revisionCollision) }
        XCTAssertThrowsError(try WorkspaceReplica(revisions: [root, root]))
        let wrongItem = revision(record: UUID(), title: "Wrong parent", parents: [root.id])
        XCTAssertThrowsError(try WorkspaceReplica(revisions: [root, wrongItem]))
        let a = UUID(), b = UUID()
        XCTAssertThrowsError(try WorkspaceReplica(revisions: [
            revision(id: a, record: root.recordID, title: "A", parents: [b]),
            revision(id: b, record: root.recordID, title: "B", parents: [a])]))
    }

    func testMovesRenamesAndTombstoneRestorePreserveIdentity() throws {
        var replica = try WorkspaceReplica()
        let folder = try replica.save(content: .init(kind: .folder, title: "Folder"), expectedHeads: [], deviceID: device, origin: .iOS)
        let note = try replica.save(content: .init(kind: .note, title: "Draft"), expectedHeads: [], deviceID: device, origin: .iOS)
        var moved = note.content; moved.title = "Renamed"; moved.parentID = folder.recordID
        let move = try replica.save(recordID: note.recordID, content: moved, expectedHeads: [note.id], deviceID: device, origin: .mac)
        var deleted = moved; deleted.isDeleted = true
        let deletion = try replica.save(recordID: note.recordID, content: deleted, expectedHeads: [move.id], deviceID: device, origin: .mac)
        XCTAssertTrue(replica.records.first { $0.id == note.recordID }!.resolved!.content.isDeleted)
        try replica.save(recordID: note.recordID, content: moved, expectedHeads: [deletion.id], deviceID: device, origin: .iOS)
        XCTAssertEqual(replica.records.first { $0.id == note.recordID }?.resolved?.content, moved)
        XCTAssertEqual(replica.revisions.filter { $0.recordID == note.recordID }.count, 4)
    }

    func testLocalHierarchyCyclesAndMissingParentsAreRefusedWithoutMutation() throws {
        var replica = try WorkspaceReplica()
        let a = try replica.save(content: .init(kind: .folder, title: "A"), expectedHeads: [], deviceID: device, origin: .iOS)
        let b = try replica.save(content: .init(kind: .folder, title: "B", parentID: a.recordID), expectedHeads: [], deviceID: device, origin: .iOS)
        let original = replica
        var loop = a.content; loop.parentID = b.recordID
        XCTAssertThrowsError(try replica.save(recordID: a.recordID, content: loop, expectedHeads: [a.id], deviceID: device, origin: .iOS))
        XCTAssertThrowsError(try replica.save(content: .init(kind: .note, title: "Orphan", parentID: UUID()), expectedHeads: [], deviceID: device, origin: .iOS))
        XCTAssertEqual(replica, original)
    }

    func testExistingMissingLocationAllowsBodyEditButNeverANewInvalidMove() throws {
        let orphan = WorkspaceRecordRevision(recordID: UUID(), deviceID: device, origin: .mac,
            content: .init(kind: .task, title: "Retained", body: "Original", parentID: UUID()))
        var graph = try WorkspaceReplica(revisions: [orphan])
        var edit = orphan.content; edit.body = "Available offline"
        let saved = try graph.save(recordID: orphan.recordID, content: edit, expectedHeads: [orphan.id], deviceID: UUID(), origin: .iOS)
        XCTAssertEqual(saved.content.parentID, orphan.content.parentID)
        XCTAssertEqual(graph.locationIssues[orphan.recordID], .missingParent)
        let before = graph
        var invalidMove = edit; invalidMove.parentID = UUID()
        XCTAssertThrowsError(try graph.save(recordID: orphan.recordID, content: invalidMove, expectedHeads: [saved.id], deviceID: device, origin: .mac))
        XCTAssertThrowsError(try graph.save(content: edit, expectedHeads: [], deviceID: device, origin: .mac))
        XCTAssertThrowsError(try graph.save(recordID: orphan.recordID, content: edit, expectedHeads: [orphan.id], deviceID: device, origin: .mac))
        XCTAssertEqual(graph, before)
    }

    func testUnrelatedSameNamedFoldersHaveStableDistinctPresentation() throws {
        let mac = WorkspaceRecordRevision(recordID: UUID(), deviceID: device, origin: .mac, content: .init(kind: .folder, title: "Notes"))
        let phone = WorkspaceRecordRevision(recordID: UUID(), deviceID: UUID(), origin: .iOS, content: .init(kind: .folder, title: "notes"))
        let reserved = WorkspaceRecordRevision(recordID: UUID(), deviceID: device, origin: .mac, content: .init(kind: .folder, title: "Notes-Mac"))
        let id = UUID()
        let a = try WorkspaceReplica(workspaceID: id, revisions: [mac, phone, reserved])
        let b = try WorkspaceReplica(workspaceID: id, revisions: [reserved, phone, mac])
        XCTAssertEqual(a.records.count, 3)
        XCTAssertTrue(a.records.allSatisfy { !$0.isConflict })
        XCTAssertEqual(a.displayTitles, b.displayTitles)
        XCTAssertEqual(a.displayTitles[reserved.recordID], "Notes-Mac")
        XCTAssertEqual(a.displayTitles[mac.recordID], "Notes-Mac-2")
        XCTAssertEqual(a.displayTitles[phone.recordID], "notes-iOS")
        XCTAssertEqual(mac.content.title, "Notes", "Presentation must not rename or overwrite original content")
    }

    func testConcurrentMovesExposeCyclesAndKeepEveryRecordUntilReviewedMove() throws {
        var base = try WorkspaceReplica()
        let a = try base.save(content: .init(kind: .folder, title: "A"), expectedHeads: [], deviceID: device, origin: .mac)
        let b = try base.save(content: .init(kind: .folder, title: "B"), expectedHeads: [], deviceID: device, origin: .mac)
        var phone = base, mac = base
        var movedA = a.content; movedA.parentID = b.recordID
        var movedB = b.content; movedB.parentID = a.recordID
        try phone.save(recordID: a.recordID, content: movedA, expectedHeads: [a.id], deviceID: UUID(), origin: .iOS)
        try mac.save(recordID: b.recordID, content: movedB, expectedHeads: [b.id], deviceID: device, origin: .mac)
        var merged = try phone.merging(mac)
        XCTAssertEqual(merged.records.count, 2)
        XCTAssertEqual(merged.locationIssues[a.recordID], .cycle)
        XCTAssertEqual(merged.locationIssues[b.recordID], .cycle)
        let head = try XCTUnwrap(merged.records.first { $0.id == b.recordID }?.resolved)
        try merged.save(recordID: b.recordID, content: b.content, expectedHeads: [head.id], deviceID: device, origin: .mac)
        XCTAssertTrue(merged.locationIssues.isEmpty)
        XCTAssertEqual(merged.records.count, 2)
    }

    func testDeletingParentLeavesChildrenRecoverableAndDescribesLocationIssue() throws {
        var replica = try WorkspaceReplica()
        let project = try replica.save(content: .init(kind: .project, title: "Project"), expectedHeads: [], deviceID: device, origin: .iOS)
        let task = try replica.save(content: .init(kind: .task, title: "Keep task", parentID: project.recordID), expectedHeads: [], deviceID: device, origin: .iOS)
        var deleted = project.content; deleted.isDeleted = true
        let tombstone = try replica.save(recordID: project.recordID, content: deleted, expectedHeads: [project.id], deviceID: device, origin: .iOS)
        XCTAssertEqual(replica.records.first { $0.id == task.recordID }?.resolved?.content.isDeleted, false)
        XCTAssertEqual(replica.locationIssues[task.recordID], .deletedParent)
        try replica.save(recordID: project.recordID, content: project.content, expectedHeads: [tombstone.id], deviceID: device, origin: .mac)
        XCTAssertTrue(replica.locationIssues.isEmpty)
    }

    func testFingerprintCanonicalizesMultiParentSetOrder() throws {
        let root = revision(record: UUID(), title: "First")
        let a = revision(record: root.recordID, title: "A", parents: [root.id])
        let b = revision(record: root.recordID, title: "B", parents: [root.id])
        let resolved = revision(record: root.recordID, title: "Resolved", parents: [a.id, b.id])
        let id = UUID()
        let replica = try WorkspaceReplica(workspaceID: id, revisions: [root, a, b, resolved])
        let decoded = try JSONDecoder().decode(WorkspaceReplica.self, from: JSONEncoder().encode(replica))
        XCTAssertEqual(try replica.fingerprint, try decoded.fingerprint)
        XCTAssertEqual(try replica.fingerprint, try WorkspaceReplica(workspaceID: id, revisions: [resolved, b, a, root]).fingerprint)
    }

    func testReviewedMergeChecksBothSourcesAndWritesRecoverableCheckpoint() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let store = WorkspaceReplicaStore(directory: root, initialWorkspaceID: UUID())
        try store.save(content: .init(kind: .project, title: "Local"), expectedHeads: [], deviceID: device, origin: .iOS)
        let before = try store.load()
        let incoming = try WorkspaceReplica(revisions: [revision(record: UUID(), title: "Mac")])
        let preview = try store.previewMerge(incoming)
        XCTAssertEqual(try store.load(), before, "Preview must not import anything")
        XCTAssertThrowsError(try store.receive(incoming), "Independent workspace IDs require approval")
        let checkpoint = try store.applyReviewedMerge(incoming, approved: preview)
        XCTAssertEqual(try JSONDecoder().decode(WorkspaceReplica.self, from: Data(contentsOf: checkpoint)), before)
        let combined = try store.load()
        XCTAssertEqual(combined.workspaceID, preview.resultWorkspaceID)
        XCTAssertEqual(combined.joinedWorkspaceIDs, [before.workspaceID, incoming.workspaceID])
        XCTAssertEqual(combined.records.count, 2)
        let changed = try WorkspaceReplica(workspaceID: incoming.workspaceID, revisions: incoming.revisions + [revision(record: UUID(), title: "Late")])
        XCTAssertThrowsError(try store.applyReviewedMerge(changed, approved: preview))
        XCTAssertThrowsError(try store.applyReviewedMerge(incoming, approved: preview))
        XCTAssertEqual(try store.load(), combined)
        try store.receive(WorkspaceReplica(workspaceID: combined.workspaceID, revisions: incoming.revisions))
        XCTAssertEqual(try store.load().records.count, 2)
    }

    func testBothPeersAdoptOneIdentityAndContinueOfflineEditsAfterReviewedJoin() throws {
        let aRoot = try fixture(), bRoot = try fixture()
        defer { try? FileManager.default.removeItem(at: aRoot); try? FileManager.default.removeItem(at: bRoot) }
        let a = WorkspaceReplicaStore(directory: aRoot, initialWorkspaceID: UUID())
        let b = WorkspaceReplicaStore(directory: bRoot, initialWorkspaceID: UUID())
        let aRecord = try a.save(content: .init(kind: .note, title: "Phone"), expectedHeads: [], deviceID: device, origin: .iOS)
        try b.save(content: .init(kind: .project, title: "Mac"), expectedHeads: [], deviceID: UUID(), origin: .mac)
        let beforeA = try a.load(), beforeB = try b.load()
        let previewA = try a.previewMerge(beforeB), previewB = try b.previewMerge(beforeA)
        XCTAssertEqual(previewA.resultWorkspaceID, previewB.resultWorkspaceID)
        try a.applyReviewedMerge(beforeB, approved: previewA)
        try b.applyReviewedMerge(beforeA, approved: previewB)
        XCTAssertEqual(try a.load().fingerprint, try b.load().fingerprint)
        try a.save(recordID: aRecord.recordID, content: .init(kind: .note, title: "Offline edit"), expectedHeads: [aRecord.id], deviceID: device, origin: .iOS)
        try b.receive(a.load())
        try a.receive(b.load())
        XCTAssertEqual(try a.load().fingerprint, try b.load().fingerprint)
        XCTAssertEqual(try b.load().records.first { $0.id == aRecord.recordID }?.resolved?.content.title, "Offline edit")
        let unadopted = beforeA.workspaceID == previewA.resultWorkspaceID ? beforeB : beforeA
        XCTAssertThrowsError(try a.receive(unadopted), "The other peer must adopt the reviewed identity before routine delivery")
    }

    func testRoutineSyncCannotSmuggleAnUnapprovedWorkspaceJoin() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let store = WorkspaceReplicaStore(directory: root, initialWorkspaceID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
        let original = try store.load()
        let foreign = try WorkspaceReplica(revisions: [revision(record: UUID(), title: "Other workspace")])
        let unreviewed = try original.joining(foreign)
        XCTAssertEqual(unreviewed.workspaceID, original.workspaceID)
        XCTAssertThrowsError(try store.receive(unreviewed))
        XCTAssertEqual(try store.load(), original)
    }

    func testCorruptOrNewerStoreIsNeverReplaced() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("workspace.json")
        let store = WorkspaceReplicaStore(directory: root, initialWorkspaceID: UUID())
        for bytes in [Data("corrupt".utf8), Data("{\"formatVersion\":999,\"workspaceID\":\"\(UUID().uuidString)\",\"revisions\":[]}".utf8)] {
            try bytes.write(to: url)
            XCTAssertThrowsError(try store.load())
            XCTAssertThrowsError(try store.save(content: .init(kind: .note, title: "Do not replace"), expectedHeads: [], deviceID: device, origin: .iOS))
            XCTAssertEqual(try Data(contentsOf: url), bytes)
        }
    }

    func testTwoStoreInstancesCannotLoseEachOthersChanges() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let a = WorkspaceReplicaStore(directory: root, initialWorkspaceID: UUID())
        let b = WorkspaceReplicaStore(directory: root, initialWorkspaceID: UUID())
        let id = try a.load().workspaceID
        DispatchQueue.concurrentPerform(iterations: 20) { index in
            do {
                try (index.isMultiple(of: 2) ? a : b).save(content: .init(kind: .note, title: "Note \(index)"), expectedHeads: [], deviceID: device, origin: .iOS)
            } catch { XCTFail("Concurrent save: \(error)") }
        }
        XCTAssertEqual(try b.load().workspaceID, id)
        XCTAssertEqual(try a.load().records.count, 20)
    }

    func testSymlinkStoreIsRefusedWithoutTouchingTarget() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("original.json")
        let bytes = Data("private bytes".utf8); try bytes.write(to: target)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("workspace.json"), withDestinationURL: target)
        XCTAssertThrowsError(try WorkspaceReplicaStore(directory: root, initialWorkspaceID: UUID()).load())
        XCTAssertEqual(try Data(contentsOf: target), bytes)
    }

    private func revision(id: UUID = UUID(), record: UUID, title: String, parents: Set<UUID> = [],
                          deleted: Bool = false, at date: Date = Date()) -> WorkspaceRecordRevision {
        WorkspaceRecordRevision(id: id, recordID: record, parents: parents, deviceID: device, origin: .mac,
            createdAt: date, content: .init(kind: .note, title: title, isDeleted: deleted))
    }

    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("bw-replica-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        return root
    }
}

@MainActor
final class WorkspaceNotebookImportTests: XCTestCase {
    func testPublishedDataImportsAdditivelyWithLinksArchivesAndStableIDs() throws {
        let container = try WorkspaceNotebookPersistence.container(inMemory: true)
        let context = container.mainContext
        let project = try WorkspaceNotebookEditor.save(in: context, kind: .project, title: "Published project", body: "Keep original", projectID: nil)
        let task = try WorkspaceNotebookEditor.save(in: context, kind: .task, title: "Published task", body: "Offline work", projectID: project.recordID)
        task.isComplete = true
        let note = try WorkspaceNotebookEditor.save(in: context, kind: .document, title: "Archived note", body: "Recoverable", projectID: project.recordID)
        try WorkspaceNotebookEditor.setArchived(true, record: note, in: context)
        let workspaceID = UUID()
        let imported = try WorkspaceNotebookImport.preview(from: context, workspaceID: workspaceID)
        let again = try WorkspaceNotebookImport.preview(from: context, workspaceID: workspaceID)
        XCTAssertEqual(try imported.fingerprint, try again.fingerprint)
        XCTAssertEqual(try imported.merging(again).revisions.count, 3)
        XCTAssertEqual(imported.records.first { $0.id == task.recordID }?.resolved?.content.parentID, project.recordID)
        XCTAssertEqual(imported.records.first { $0.id == task.recordID }?.resolved?.content.isComplete, true)
        XCTAssertEqual(imported.records.first { $0.id == task.recordID }?.resolved?.recordCreatedAt, task.createdAt)
        XCTAssertEqual(imported.records.first { $0.id == note.recordID }?.resolved?.content.isDeleted, true)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<WorkspaceNotebookRecord>()), 3)
        XCTAssertEqual(project.body, "Keep original")
        XCTAssertTrue(note.isArchived)
        XCTAssertFalse(context.hasChanges, "Import must not edit the published store")
    }

    func testDuplicateLegacyUUIDsRetainDifferentContentAsConflict() throws {
        let container = try WorkspaceNotebookPersistence.container(inMemory: true)
        let a = WorkspaceNotebookRecord(kind: .idea, title: "Version A")
        let b = WorkspaceNotebookRecord(kind: .idea, title: "Version B"); b.recordID = a.recordID
        container.mainContext.insert(a); container.mainContext.insert(b); try container.mainContext.save()
        let imported = try WorkspaceNotebookImport.preview(from: container.mainContext, workspaceID: UUID())
        XCTAssertEqual(imported.records.count, 1)
        XCTAssertTrue(imported.records[0].isConflict)
        XCTAssertEqual(Set(imported.records[0].heads.map { $0.content.title }), ["Version A", "Version B"])
    }
}
