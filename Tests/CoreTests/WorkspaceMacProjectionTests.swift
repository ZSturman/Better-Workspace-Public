import XCTest
@testable import BetterWorkspaceCore

final class WorkspaceMacProjectionTests: XCTestCase {
    private let deviceID = UUID()
    private let projectID = UUID()

    func testStableSourceIDsSurviveRenamesMovesAndRepeatedObservations() throws {
        var work = mobileWork(id: "existing-portable-id", title: "Draft", path: "To Do/Draft.bw.md")
        work.createdAt = Date(timeIntervalSince1970: 123_456)
        let initial = try WorkspaceMacProjection.observe(.init(workItems: [work]), in: WorkspaceReplica(), bindings: [], deviceID: deviceID)
        let identity = try XCTUnwrap(initial.bindings.first?.recordID)
        XCTAssertNotEqual(identity.uuidString, work.path)
        let restoredBindings = try JSONDecoder().decode([WorkspaceMacBinding].self, from: JSONEncoder().encode(initial.bindings))
        var moved = work; moved.title = "Renamed"
        let movedWork = mobileWork(id: work.id, title: moved.title, path: "To Do/Nested/Renamed.bw.md")
        let observed = try WorkspaceMacProjection.observe(.init(workItems: [movedWork]), in: initial.replica, bindings: restoredBindings, deviceID: deviceID)
        XCTAssertEqual(observed.bindings.first?.recordID, identity)
        XCTAssertEqual(observed.bindings.first?.relativePath, movedWork.path)
        XCTAssertEqual(observed.replica.records.count, 1)
        XCTAssertEqual(observed.replica.records.first?.resolved?.content.title, "Renamed")
        XCTAssertEqual(observed.replica.records.first?.resolved?.recordCreatedAt, work.createdAt, "A partial later index must not erase the original creation date")
        XCTAssertEqual(observed.replica.revisions.count, 2)
        let repeated = try WorkspaceMacProjection.observe(.init(workItems: [movedWork]), in: observed.replica, bindings: observed.bindings, deviceID: deviceID)
        XCTAssertEqual(try repeated.replica.fingerprint, try observed.replica.fingerprint)
        XCTAssertEqual(repeated.bindings, observed.bindings)
        // Lost receipt: the graph contains the revision but the old binding is used.
        let retry = try WorkspaceMacProjection.observe(.init(workItems: [movedWork]), in: observed.replica, bindings: initial.bindings, deviceID: deviceID)
        XCTAssertEqual(try retry.replica.fingerprint, try observed.replica.fingerprint)
    }

    func testMacObservationCannotConsumeAnOfflinePhoneBranch() throws {
        let original = mobileWork(id: UUID().uuidString, title: "Before", path: "To Do/Before.bw.md")
        let initial = try WorkspaceMacProjection.observe(.init(workItems: [original]), in: WorkspaceReplica(), bindings: [], deviceID: deviceID)
        let baseline = try XCTUnwrap(initial.replica.records.first?.resolved)
        var phone = initial.replica, edited = baseline.content
        edited.title = "Phone edit"
        let phoneRevision = try phone.save(recordID: baseline.recordID, content: edited, expectedHeads: [baseline.id], deviceID: UUID(), origin: .iOS)
        var mac = original; mac.body = "Mac edit"
        let result = try WorkspaceMacProjection.observe(.init(workItems: [mac]), in: phone, bindings: initial.bindings, deviceID: deviceID)
        let state = try XCTUnwrap(result.replica.records.first)
        XCTAssertTrue(state.isConflict)
        XCTAssertTrue(state.heads.contains { $0.id == phoneRevision.id })
        XCTAssertTrue(state.heads.contains { $0.content.body == "Mac edit" && $0.parents == [baseline.id] })
    }

    func testPartialIndexDefersUnknownOriginalsAndNeverInfersDeletion() throws {
        let work = mobileWork(id: UUID().uuidString, title: "Keep", path: "To Do/Keep.bw.md")
        let initial = try WorkspaceMacProjection.observe(.init(workItems: [work]), in: WorkspaceReplica(), bindings: [], deviceID: deviceID)
        var missingText = work; missingText.body = nil
        let partial = try WorkspaceMacProjection.observe(.init(workItems: [missingText]), in: initial.replica, bindings: initial.bindings, deviceID: deviceID)
        XCTAssertEqual(try partial.replica.fingerprint, try initial.replica.fingerprint)
        XCTAssertEqual(partial.bindings, initial.bindings)
        XCTAssertNotNil(partial.deferredSourceIDs["work:" + work.id])
        let absent = try WorkspaceMacProjection.observe(.init(), in: initial.replica, bindings: initial.bindings, deviceID: deviceID)
        XCTAssertEqual(try absent.replica.fingerprint, try initial.replica.fingerprint)
        var unbound = work; unbound.projectPath = "Projects/Not included"
        let deferred = try WorkspaceMacProjection.observe(.init(workItems: [unbound]), in: WorkspaceReplica(), bindings: [], deviceID: deviceID)
        XCTAssertEqual(deferred.replica.records.count, 1)
        XCTAssertEqual(deferred.replica.records.first?.resolved?.content.body, work.body)
        XCTAssertEqual(deferred.replica.locationIssues[try XCTUnwrap(UUID(uuidString: work.id))], .missingParent)
        XCTAssertNotNil(deferred.deferredSourceIDs["work:" + work.id])
    }

    func testUnresolvedProjectLinksRetainContentAndResolveWithoutConsumingOfflineEdits() throws {
        var work = mobileWork(id: UUID().uuidString, title: "Available work", path: "To Do/Available.bw.md")
        work.projectPath = "Projects/Unavailable"
        var unrelated = mobileWork(id: UUID().uuidString, title: "Other work", path: "To Do/Other.bw.md")
        unrelated.projectPath = work.projectPath
        let first = try WorkspaceMacProjection.observe(.init(workItems: [work, unrelated]), in: WorkspaceReplica(), bindings: [], deviceID: deviceID)
        let id = try XCTUnwrap(UUID(uuidString: work.id))
        let baseline = try XCTUnwrap(first.replica.records.first { $0.id == id }?.resolved)
        XCTAssertEqual(first.replica.locationIssues.count, 2)
        XCTAssertNotEqual(baseline.content.parentID, first.replica.records.first { $0.id != id }?.resolved?.content.parentID,
                          "Missing-reference tokens must not merge unrelated work by project name")
        let repeated = try WorkspaceMacProjection.observe(.init(workItems: [work, unrelated]), in: first.replica, bindings: first.bindings, deviceID: deviceID)
        XCTAssertEqual(try repeated.replica.fingerprint, try first.replica.fingerprint)
        var phone = first.replica, offline = baseline.content; offline.body = "Offline edit retained"
        try phone.save(recordID: id, content: offline, expectedHeads: [baseline.id], deviceID: UUID(), origin: .iOS)
        let snapshot = MobileWorkspaceSnapshot(entries: [.init(path: work.projectPath!, parentPath: "Projects", name: "Unavailable", isDirectory: true, revision: 1,
            projectDetails: .init(path: work.projectPath!, projectID: projectID.uuidString))], workItems: [work, unrelated])
        let resolved = try WorkspaceMacProjection.observe(snapshot, in: phone, bindings: first.bindings, deviceID: deviceID)
        let state = try XCTUnwrap(resolved.replica.records.first { $0.id == id })
        XCTAssertTrue(state.isConflict)
        XCTAssertTrue(state.heads.contains { $0.content.body == offline.body })
        XCTAssertTrue(state.heads.contains { $0.content.parentID == projectID && $0.content.body == work.body })
        XCTAssertTrue(resolved.deferredSourceIDs.isEmpty)
        XCTAssertEqual(resolved.replica.records.count, 3, "Only the real published project adds a record")
    }

    func testBodySavePreservesUnresolvedOriginalProjectLinkAndRejectsChangedLink() throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        var snapshot = fixture.snapshot(); snapshot.entries = []
        let initial = try WorkspaceMacProjection.observe(snapshot, in: WorkspaceReplica(), bindings: [], deviceID: deviceID)
        let id = try XCTUnwrap(UUID(uuidString: fixture.work.id))
        let baseline = try XCTUnwrap(initial.replica.records.first?.resolved)
        let binding = try XCTUnwrap(initial.bindings.first)
        var graph = initial.replica, edited = baseline.content; edited.body = "Phone edit with unavailable project"
        try graph.save(recordID: id, content: edited, expectedHeads: [baseline.id], deviceID: UUID(), origin: .iOS)
        guard case .update(let update) = try WorkspaceMacProjection.prepareWorkSave(recordID: id, in: graph, bindings: initial.bindings, workspace: .init(root: fixture.root)) else { return XCTFail("Expected body update") }
        XCTAssertEqual(update.projectPath, fixture.work.projectPath)
        XCTAssertEqual(update.extraFrontMatter, fixture.work.extraFrontMatter)
        XCTAssertEqual(update.body, edited.body)
        XCTAssertEqual(try WorkspaceMacProjection.readWorkContent(binding, bindings: initial.bindings, workspace: .init(root: fixture.root)), baseline.content)
        var source = fixture.work; source.projectPath = "Projects/Another unavailable project"
        let changed = try fixture.service.update(source), bytes = try Data(contentsOf: changed.url)
        XCTAssertThrowsError(try WorkspaceMacProjection.prepareWorkSave(recordID: id, in: graph, bindings: initial.bindings, workspace: .init(root: fixture.root)))
        XCTAssertEqual(try Data(contentsOf: changed.url), bytes)
        var move = baseline.content; move.parentID = UUID()
        // Received histories can contain unavailable destinations even though
        // the local editor correctly refuses to create such a move.
        let incoming = WorkspaceRecordRevision(recordID: id, parents: [baseline.id], deviceID: UUID(), origin: .iOS, content: move)
        let moved = try WorkspaceReplica(workspaceID: initial.replica.workspaceID, revisions: initial.replica.revisions + [incoming])
        var restore = changed; restore.projectPath = fixture.work.projectPath
        _ = try fixture.service.update(restore)
        XCTAssertThrowsError(try WorkspaceMacProjection.prepareWorkSave(recordID: id, in: moved, bindings: initial.bindings, workspace: .init(root: fixture.root)))
    }

    func testMissingFolderRetainsUUIDAndBodySavePreservesAdvancedProjectLink() throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let folderID = UUID()
        var item = fixture.work
        item.extraFrontMatter.append(WorkspaceMacProjection.folderParentKey + " " + folderID.uuidString)
        let saved = try fixture.service.update(item)
        var snapshot = fixture.snapshot(work: saved)
        snapshot.workItems[0].workspaceFolderID = folderID
        let initial = try WorkspaceMacProjection.observe(snapshot, in: WorkspaceReplica(), bindings: [], deviceID: deviceID)
        let id = try XCTUnwrap(UUID(uuidString: item.id))
        let baseline = try XCTUnwrap(initial.replica.records.first { $0.id == id }?.resolved)
        XCTAssertEqual(baseline.content.parentID, folderID)
        XCTAssertEqual(initial.replica.locationIssues[id], .missingParent)
        var graph = initial.replica, edited = baseline.content; edited.body = "Retained body"
        try graph.save(recordID: id, content: edited, expectedHeads: [baseline.id], deviceID: UUID(), origin: .iOS)
        guard case .update(let update) = try WorkspaceMacProjection.prepareWorkSave(recordID: id, in: graph, bindings: initial.bindings, workspace: .init(root: fixture.root)) else { return XCTFail("Expected body update") }
        XCTAssertEqual(update.extraFrontMatter, saved.extraFrontMatter)
        XCTAssertEqual(update.projectPath, saved.projectPath)
        let binding = try XCTUnwrap(initial.bindings.first { $0.recordID == id })
        XCTAssertEqual(try WorkspaceMacProjection.readWorkContent(binding, bindings: initial.bindings, workspace: .init(root: fixture.root)), baseline.content)
    }

    func testDuplicateIDsAndProtectedPathsAreRefused() throws {
        let a = mobileWork(id: UUID().uuidString, title: "A", path: "To Do/A.bw.md")
        let b = mobileWork(id: a.id, title: "B", path: "To Do/B.bw.md")
        XCTAssertThrowsError(try WorkspaceMacProjection.observe(.init(workItems: [a, b]), in: WorkspaceReplica(), bindings: [], deviceID: deviceID))
        for path in ["Projects/A/.git/Task.bw.md", "Projects/A/node_modules/Task.bw.md", "Projects/_audit/Task.bw.md", "../Task.bw.md"] {
            let work = mobileWork(id: UUID().uuidString, title: "Protected", path: path)
            XCTAssertThrowsError(try WorkspaceMacProjection.observe(.init(workItems: [work]), in: WorkspaceReplica(), bindings: [], deviceID: deviceID), path)
        }
    }

    func testRealPortableWorkRoundTripPreservesUnrelatedMetadataAndAcknowledgesCanonicalHead() throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let initial = try WorkspaceMacProjection.observe(fixture.snapshot(), in: WorkspaceReplica(), bindings: [], deviceID: deviceID)
        let id = try XCTUnwrap(UUID(uuidString: fixture.work.id))
        let baseline = try XCTUnwrap(initial.replica.records.first { $0.id == id }?.resolved)
        var replica = initial.replica, edited = baseline.content
        edited.title = "Planned on phone"; edited.body = "Edited offline"; edited.isComplete = true
        let desired = try replica.save(recordID: id, content: edited, expectedHeads: [baseline.id], deviceID: UUID(), origin: .iOS)
        let prepared = try WorkspaceMacProjection.prepareWorkSave(recordID: id, in: replica, bindings: initial.bindings, workspace: .init(root: fixture.root))
        guard case .update(let update) = prepared else { return XCTFail("Expected explicit update") }
        let saved = try fixture.service.update(update)
        XCTAssertEqual(saved.id, fixture.work.id)
        XCTAssertEqual(saved.title, edited.title); XCTAssertEqual(saved.body, edited.body)
        XCTAssertEqual(saved.status, .completed)
        XCTAssertEqual(saved.stage, fixture.work.stage); XCTAssertEqual(saved.priority, fixture.work.priority)
        XCTAssertEqual(saved.dueDate, fixture.work.dueDate)
        XCTAssertEqual(saved.featureIDs, fixture.work.featureIDs)
        XCTAssertEqual(saved.dependencyIDs, fixture.work.dependencyIDs)
        XCTAssertEqual(saved.notionPageID, fixture.work.notionPageID)
        XCTAssertEqual(saved.extraFrontMatter, fixture.work.extraFrontMatter)
        let bytes = try Data(contentsOf: saved.url)
        guard case .unchanged = try WorkspaceMacProjection.prepareWorkSave(recordID: id, in: replica, bindings: initial.bindings, workspace: .init(root: fixture.root)) else { return XCTFail("Retry should not rewrite the file") }
        XCTAssertEqual(try Data(contentsOf: saved.url), bytes)
        let observed = try WorkspaceMacProjection.observe(fixture.snapshot(work: saved), in: replica, bindings: initial.bindings, deviceID: deviceID)
        XCTAssertEqual(observed.bindings.first { $0.recordID == id }?.observedRevisionID, desired.id)
        XCTAssertFalse(observed.replica.records.first { $0.id == id }!.isConflict)
        XCTAssertEqual(observed.replica.revisions.count, replica.revisions.count)
    }

    func testStaleSourceAndSymlinkNeverOverwriteOriginal() throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let initial = try WorkspaceMacProjection.observe(fixture.snapshot(), in: WorkspaceReplica(), bindings: [], deviceID: deviceID)
        let id = try XCTUnwrap(UUID(uuidString: fixture.work.id)), baseline = try XCTUnwrap(initial.replica.records.first { $0.id == id }?.resolved)
        var replica = initial.replica, edited = baseline.content; edited.body = "Phone draft"
        try replica.save(recordID: id, content: edited, expectedHeads: [baseline.id], deviceID: UUID(), origin: .iOS)
        var external = fixture.work; external.body = "External change"
        let saved = try fixture.service.update(external)
        let bytes = try Data(contentsOf: saved.url)
        XCTAssertThrowsError(try WorkspaceMacProjection.prepareWorkSave(recordID: id, in: replica, bindings: initial.bindings, workspace: .init(root: fixture.root)))
        XCTAssertEqual(try Data(contentsOf: saved.url), bytes)
        let moved = fixture.root.appendingPathComponent("OwnedMovedOriginal.bw.md")
        try FileManager.default.moveItem(at: saved.url, to: moved)
        try FileManager.default.createSymbolicLink(at: saved.url, withDestinationURL: moved)
        XCTAssertThrowsError(try WorkspaceMacProjection.prepareWorkSave(recordID: id, in: replica, bindings: initial.bindings, workspace: .init(root: fixture.root)))
        XCTAssertEqual(try Data(contentsOf: moved), bytes)
    }

    func testReusedProjectPathPreservesBothUUIDsAndBlocksAmbiguousSaves() throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let initial = try WorkspaceMacProjection.observe(fixture.snapshot(), in: WorkspaceReplica(), bindings: [], deviceID: deviceID)
        var replaced = fixture.snapshot()
        let replacementID = UUID()
        replaced.entries = [.init(path: "Projects/Example", parentPath: "Projects", name: "Example", isDirectory: true, revision: 2,
            projectDetails: .init(path: "Projects/Example", projectID: replacementID.uuidString))]
        let result = try WorkspaceMacProjection.observe(replaced, in: initial.replica, bindings: initial.bindings, deviceID: deviceID)
        XCTAssertNotNil(result.replica.records.first { $0.id == UUID(uuidString: fixture.project.id) })
        XCTAssertNotNil(result.replica.records.first { $0.id == replacementID })
        XCTAssertNotNil(result.deferredSourceIDs["project:Projects/Example"])
        let id = try XCTUnwrap(UUID(uuidString: fixture.work.id)), before = try Data(contentsOf: fixture.work.url)
        XCTAssertThrowsError(try WorkspaceMacProjection.prepareWorkSave(recordID: id, in: result.replica, bindings: result.bindings, workspace: .init(root: fixture.root)))
        XCTAssertEqual(try Data(contentsOf: fixture.work.url), before)
    }

    // November 7: the October 20 To Do backup kept every id, so 1,353 bindings observed the
    // snapshot. A phone completion was written into the backup and the live file stayed open.
    func testBindingOnABackupCopyMovesToTheLiveFileAndKeepsNewerJournalEdits() throws {
        let id = UUID().uuidString.lowercased()
        var backup = mobileWork(id: id, title: "Project — Long audit title", path: "Backups/To-Do-pre-simplification-2026-10-20/Task.bw.md")
        backup.modifiedAt = Date(timeIntervalSince1970: 1_000)
        let initial = try WorkspaceMacProjection.observe(.init(workItems: [backup]), in: WorkspaceReplica(), bindings: [], deviceID: deviceID)
        let baseline = try XCTUnwrap(initial.replica.records.first?.resolved)
        var completed = baseline.content
        completed.isComplete = true
        let phone = WorkspaceRecordRevision(recordID: baseline.recordID, parents: [baseline.id], deviceID: UUID(), origin: .iOS,
                                            createdAt: Date(timeIntervalSince1970: 3_000), content: completed)
        let replica = try initial.replica.merging(WorkspaceReplica(workspaceID: initial.replica.workspaceID, revisions: [phone],
                                                                   joinedWorkspaceIDs: initial.replica.joinedWorkspaceIDs))
        // The Mac acknowledged the phone edit after writing it into the snapshot.
        let written = initial.bindings.map { WorkspaceMacBinding(recordID: $0.recordID, source: $0.source, sourceID: $0.sourceID, relativePath: $0.relativePath, observedRevisionID: phone.id) }
        var live = mobileWork(id: id, title: "Short title", path: "To Do/Short title.bw.md")
        live.body = "Original\n\nNote added in Finder."
        live.modifiedAt = Date(timeIntervalSince1970: 2_000)

        let moved = try WorkspaceMacProjection.observe(.init(workItems: [live]), in: replica, bindings: written, deviceID: deviceID)
        let binding = try XCTUnwrap(moved.bindings.first)
        XCTAssertEqual(binding.relativePath, live.path)
        let state = try XCTUnwrap(moved.replica.records.first)
        XCTAssertFalse(state.isConflict)
        let head = try XCTUnwrap(state.resolved)
        XCTAssertEqual(head.content.title, "Short title", "The live file's rename is newer than the snapshot's title")
        XCTAssertEqual(head.content.body, live.body)
        XCTAssertTrue(head.content.isComplete, "A completion newer than the live file is never reverted")
        let observed = try XCTUnwrap(moved.replica.revisions.first { $0.id == binding.observedRevisionID })
        XCTAssertFalse(observed.content.isComplete, "The binding observes the file as it is, so the Mac writes the merge into it")
        XCTAssertEqual(head.parents, [observed.id])

        let repeated = try WorkspaceMacProjection.observe(.init(workItems: [live]), in: moved.replica, bindings: moved.bindings, deviceID: deviceID)
        XCTAssertEqual(try repeated.replica.fingerprint, try moved.replica.fingerprint)
        let retry = try WorkspaceMacProjection.observe(.init(workItems: [live]), in: moved.replica, bindings: written, deviceID: deviceID)
        XCTAssertEqual(try retry.replica.fingerprint, try moved.replica.fingerprint, "A lost receipt must not add another merge")
    }

    func testLiveFileNewerThanTheJournalWinsWhenLeavingABackupCopy() throws {
        let id = UUID().uuidString
        var backup = mobileWork(id: id, title: "Old", path: "Backups/Snapshot/Task.bw.md")
        backup.modifiedAt = Date(timeIntervalSince1970: 1_000)
        let initial = try WorkspaceMacProjection.observe(.init(workItems: [backup]), in: WorkspaceReplica(), bindings: [], deviceID: deviceID)
        var live = mobileWork(id: id, title: "Completed in review", path: "To Do/Task.bw.md")
        live.status = .completed; live.body = "Original\n\nCompleted in the November 7, 2026 task review."
        live.modifiedAt = Date(timeIntervalSince1970: 5_000)
        let moved = try WorkspaceMacProjection.observe(.init(workItems: [live]), in: initial.replica, bindings: initial.bindings, deviceID: deviceID)
        let head = try XCTUnwrap(moved.replica.records.first?.resolved)
        XCTAssertEqual(head.content.title, live.title)
        XCTAssertTrue(head.content.isComplete)
        XCTAssertEqual(head.content.body, live.body)
        XCTAssertEqual(moved.bindings.first?.observedRevisionID, head.id)
        XCTAssertEqual(moved.replica.revisions.count, 2)
    }

    func testUnacknowledgedPhoneEditStaysAConflictWhenLeavingABackupCopy() throws {
        let id = UUID().uuidString
        let backup = mobileWork(id: id, title: "Old", path: "Backups/Snapshot/Task.bw.md")
        let initial = try WorkspaceMacProjection.observe(.init(workItems: [backup]), in: WorkspaceReplica(), bindings: [], deviceID: deviceID)
        let baseline = try XCTUnwrap(initial.replica.records.first?.resolved)
        var replica = initial.replica, edited = baseline.content
        edited.title = "Phone title"
        let phone = try replica.save(recordID: baseline.recordID, content: edited, expectedHeads: [baseline.id], deviceID: UUID(), origin: .iOS)
        let live = mobileWork(id: id, title: "Live title", path: "To Do/Task.bw.md")
        let moved = try WorkspaceMacProjection.observe(.init(workItems: [live]), in: replica, bindings: initial.bindings, deviceID: deviceID)
        let state = try XCTUnwrap(moved.replica.records.first)
        XCTAssertTrue(state.isConflict)
        XCTAssertTrue(state.heads.contains { $0.id == phone.id })
        XCTAssertTrue(state.heads.contains { $0.content.title == "Live title" })
    }

    func testBackupCopyNeverTakesOverALiveBindingSoFinderDeletionStillApplies() throws {
        let id = UUID().uuidString
        let live = mobileWork(id: id, title: "Live", path: "To Do/Task.bw.md")
        let initial = try WorkspaceMacProjection.observe(.init(workItems: [live]), in: WorkspaceReplica(), bindings: [], deviceID: deviceID)
        var backup = mobileWork(id: id, title: "Old snapshot", path: "Backups/Snapshot/Task.bw.md")
        backup.body = "Stale"
        let observed = try WorkspaceMacProjection.observe(.init(workItems: [backup]), in: initial.replica, bindings: initial.bindings, deviceID: deviceID)
        XCTAssertEqual(observed.bindings, initial.bindings)
        XCTAssertEqual(try observed.replica.fingerprint, try initial.replica.fingerprint)
    }

    func testMixedCaseIDsKeepOneRecordAcrossObservations() throws {
        let id = UUID()
        let lower = mobileWork(id: id.uuidString.lowercased(), title: "Task", path: "To Do/Task.bw.md")
        let initial = try WorkspaceMacProjection.observe(.init(workItems: [lower]), in: WorkspaceReplica(), bindings: [], deviceID: deviceID)
        XCTAssertEqual(initial.bindings.first?.recordID, id)
        var upper = mobileWork(id: id.uuidString, title: "Task", path: "To Do/Task.bw.md")
        upper.status = .completed
        let observed = try WorkspaceMacProjection.observe(.init(workItems: [upper]), in: initial.replica, bindings: initial.bindings, deviceID: deviceID)
        XCTAssertEqual(observed.replica.records.count, 1)
        XCTAssertEqual(observed.replica.records.first?.resolved?.content.isComplete, true)
        XCTAssertFalse(observed.replica.records.first!.isConflict)
    }

    func testBulkRelocationFromABackupCopyObservesEveryLiveFileInOnePass() throws {
        let ids = (0..<300).map { _ in UUID().uuidString.lowercased() }
        let backups = ids.enumerated().map { index, id -> MobileWorkItem in
            var work = mobileWork(id: id, title: "Old \(index)", path: "Backups/Snapshot/Old \(index).bw.md")
            work.modifiedAt = Date(timeIntervalSince1970: 1_000); return work
        }
        let initial = try WorkspaceMacProjection.observe(.init(workItems: backups), in: WorkspaceReplica(), bindings: [], deviceID: deviceID)
        let live = ids.enumerated().map { index, id -> MobileWorkItem in
            var work = mobileWork(id: id, title: "New \(index)", path: "To Do/New \(index).bw.md")
            work.status = index.isMultiple(of: 3) ? .open : .completed
            work.modifiedAt = Date(timeIntervalSince1970: 2_000); return work
        }
        let moved = try WorkspaceMacProjection.observe(.init(workItems: live), in: initial.replica, bindings: initial.bindings, deviceID: deviceID)
        XCTAssertEqual(moved.bindings.count, ids.count)
        XCTAssertTrue(moved.bindings.allSatisfy { $0.relativePath.hasPrefix("To Do/") })
        let heads = moved.replica.records.compactMap(\.resolved)
        XCTAssertEqual(heads.count, ids.count)
        XCTAssertEqual(heads.filter(\.content.isComplete).count, live.filter { $0.status == .completed }.count)
        XCTAssertTrue(heads.allSatisfy { $0.content.title.hasPrefix("New ") })
        XCTAssertFalse(moved.replica.records.contains(where: \.isConflict))
    }

    private func mobileWork(id: String, title: String, path: String) -> MobileWorkItem {
        .init(id: id, path: path, title: title, kind: .task, status: .open, stage: .next, priority: .medium, revision: 1, body: "Original")
    }

    private final class Fixture {
        let root: URL
        let project: ProjectRecord
        let work: WorkItem
        let service = WorkItemService()
        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("bw-mac-adapter-" + UUID().uuidString)
            let folder = root.appendingPathComponent("Projects/Example")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let store = ProjectStore(database: try Database(url: root.appendingPathComponent("private.sqlite")))
            project = store.register(url: folder)
            let draft = WorkItem(kind: .task, title: "Original", status: .inProgress, stage: .now, priority: .high,
                projectPath: "Projects/Example", dependencyIDs: [UUID().uuidString], featureIDs: [UUID().uuidString], notionPageID: UUID().uuidString,
                dueDate: Date(timeIntervalSince1970: 1_800_000_000), body: "Original body", extraFrontMatter: ["custom-source: preserved"], url: folder)
            work = try service.create(draft, in: folder.appendingPathComponent("Work"))
        }
        func snapshot(work: WorkItem? = nil) -> MobileWorkspaceSnapshot {
            let item = work ?? self.work
            let mobile = MobileWorkItem(id: item.id, path: String(item.url.canonicalPath.dropFirst(root.canonicalPath.count + 1)), title: item.title,
                kind: item.kind, status: item.status, stage: item.stage, priority: item.priority, projectPath: item.projectPath, dueDate: item.dueDate, revision: 1,
                body: item.body, dependencyIDs: item.dependencyIDs, featureIDs: item.featureIDs, milestoneIDs: item.milestoneIDs,
                createdAt: item.createdAt, modifiedAt: item.modifiedAt, completedAt: item.completedAt)
            return .init(entries: [.init(path: "Projects/Example", parentPath: "Projects", name: "Example", isDirectory: true, revision: 1,
                projectDetails: .init(path: "Projects/Example", projectID: project.id))], workItems: [mobile])
        }
        func remove() { try? FileManager.default.removeItem(at: root) }
    }
}

extension WorkspaceMacProjectionTests {
    func testRejectedWriteRetainsActualSourceAndPhoneVersionWithoutDuplicateRecovery() throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let initial = try WorkspaceMacProjection.observe(fixture.snapshot(), in: WorkspaceReplica(), bindings: [], deviceID: deviceID)
        let id = try XCTUnwrap(UUID(uuidString: fixture.work.id))
        let binding = try XCTUnwrap(initial.bindings.first { $0.recordID == id })
        let baseline = try XCTUnwrap(initial.replica.records.first { $0.id == id }?.resolved)
        var graph = initial.replica, edited = baseline.content; edited.body = "Phone requested edit"
        let desired = try graph.save(recordID: id, content: edited, expectedHeads: [baseline.id], deviceID: UUID(), origin: .iOS)
        let request = WorkspaceMacWriteRequest(binding: binding, revisionID: desired.id)
        // A policy/permission rejection with an unchanged original must still expose
        // the source as a choice, rather than stranding an invisible delivery queue.
        let refused = try request.rejectionRevision(in: graph, currentBinding: binding, source: baseline.content, deviceID: deviceID)
        XCTAssertTrue(try graph.merging(WorkspaceReplica(workspaceID: graph.workspaceID, revisions: [refused])).records.first { $0.id == id }!.isConflict)
        // A real source edit during a suspended write is reread through the same
        // bounded adapter; no path/filename search or speculative overwrite.
        var source = fixture.work; source.body = "Mac changed during write"
        let saved = try fixture.service.update(source)
        XCTAssertThrowsError(try WorkspaceMacProjection.prepareWorkSave(recordID: id, in: graph, bindings: initial.bindings, workspace: .init(root: fixture.root)))
        let fresh = try WorkspaceMacProjection.readWorkContent(binding, bindings: initial.bindings, workspace: .init(root: fixture.root))
        let rejected = try request.rejectionRevision(in: graph, currentBinding: binding, source: fresh, deviceID: deviceID)
        XCTAssertEqual(rejected, try request.rejectionRevision(in: graph, currentBinding: binding, source: fresh, deviceID: deviceID))
        graph = try graph.merging(WorkspaceReplica(workspaceID: graph.workspaceID, revisions: [rejected]))
        let state = try XCTUnwrap(graph.records.first { $0.id == id })
        XCTAssertEqual(Set(state.heads.map { $0.content.body }), ["Phone requested edit", "Mac changed during write"])
        let bindings = initial.bindings.map { $0.recordID == id ? WorkspaceMacBinding(recordID: id, source: .work, sourceID: binding.sourceID, relativePath: binding.relativePath, observedRevisionID: rejected.id) : $0 }
        let replay = try WorkspaceMacProjection.observe(fixture.snapshot(work: saved), in: graph, bindings: bindings, deviceID: deviceID)
        XCTAssertEqual(try replay.replica.fingerprint, try graph.fingerprint)
    }
}

extension WorkspaceMacProjectionTests {
    func testFinderDeletionSupersedesPhoneEditWithoutErasingHistory() throws {
        let f = try Fixture(); defer { f.remove() }
        let workspace = WorkspaceLocation(root: f.root)
        let initial = try WorkspaceMacProjection.observe(f.snapshot(), in: WorkspaceReplica(), bindings: [], deviceID: deviceID)
        let id = try XCTUnwrap(UUID(uuidString: f.work.id))
        let head = try XCTUnwrap(initial.replica.records.first { $0.id == id }?.resolved)
        var phone = initial.replica, content = head.content; content.body = "Retained offline phone edit"
        let edit = try phone.save(recordID: id, content: content, expectedHeads: [head.id], deviceID: UUID(), origin: .iOS)
        try FileManager.default.removeItem(at: f.work.url)
        let observation = WorkspaceMacObservation(replica: phone, bindings: initial.bindings)
        let rootID = try XCTUnwrap(FileIdentityResolver.identity(of: f.root))
        let deleted = try WorkspaceMacProjection.reconcileMissingSources(observation, workspace: workspace, rootIdentity: rootID, deviceID: deviceID)
        let tombstone = try XCTUnwrap(deleted.replica.records.first { $0.id == id }?.resolved)
        XCTAssertTrue(tombstone.content.isDeleted); XCTAssertEqual(tombstone.parents, [edit.id])
        XCTAssertTrue(deleted.replica.revisions.contains(edit))
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.work.url.path))
        let repeated = try WorkspaceMacProjection.reconcileMissingSources(deleted, workspace: workspace, rootIdentity: rootID, deviceID: deviceID)
        XCTAssertEqual(repeated.replica, deleted.replica)
    }

    func testRelocationMergeIsWrittenIntoTheLiveFileAndAcknowledged() throws {
        let f = try Fixture(); defer { f.remove() }
        let workspace = WorkspaceLocation(root: f.root)
        let id = try XCTUnwrap(UUID(uuidString: f.work.id))
        let backup = f.root.appendingPathComponent("Backups/Snapshot/" + f.work.url.lastPathComponent)
        try FileManager.default.createDirectory(at: backup.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: f.work.url, to: backup)
        let snapshot = try XCTUnwrap(f.service.read(at: backup))
        let initial = try WorkspaceMacProjection.observe(f.snapshot(work: snapshot), in: WorkspaceReplica(), bindings: [], deviceID: deviceID)
        let baseline = try XCTUnwrap(initial.replica.records.first { $0.id == id }?.resolved)
        var completed = baseline.content; completed.isComplete = true
        let phone = WorkspaceRecordRevision(recordID: id, parents: [baseline.id], deviceID: UUID(), origin: .iOS,
                                            createdAt: Date().addingTimeInterval(3_600), content: completed)
        let replica = try initial.replica.merging(WorkspaceReplica(workspaceID: initial.replica.workspaceID, revisions: [phone], joinedWorkspaceIDs: initial.replica.joinedWorkspaceIDs))
        let acknowledged = initial.bindings.map { $0.recordID == id ? WorkspaceMacBinding(recordID: id, source: $0.source, sourceID: $0.sourceID, relativePath: $0.relativePath, observedRevisionID: phone.id) : $0 }

        let moved = try WorkspaceMacProjection.observe(f.snapshot(), in: replica, bindings: acknowledged, deviceID: deviceID)
        guard case .update(let update) = try WorkspaceMacProjection.prepareWorkSave(recordID: id, in: moved.replica, bindings: moved.bindings, workspace: workspace)
        else { return XCTFail("The merge must be written into the live file") }
        let saved = try f.service.update(update)
        XCTAssertEqual(saved.url.canonicalPath, f.work.url.canonicalPath)
        XCTAssertEqual(saved.status, .completed)
        XCTAssertEqual(saved.body, f.work.body)
        XCTAssertNotEqual(f.service.read(at: backup)?.status, .completed, "The snapshot is not written")
        let settled = try WorkspaceMacProjection.observe(f.snapshot(work: saved), in: moved.replica, bindings: moved.bindings, deviceID: deviceID)
        let state = try XCTUnwrap(settled.replica.records.first { $0.id == id })
        XCTAssertFalse(state.isConflict)
        XCTAssertEqual(settled.bindings.first { $0.recordID == id }?.observedRevisionID, state.resolved?.id)
        XCTAssertEqual(state.resolved?.content.isComplete, true)
    }

    func testFinderDeletionOfALiveTaskIsNotRevivedByItsBackupCopy() throws {
        let f = try Fixture(); defer { f.remove() }
        let workspace = WorkspaceLocation(root: f.root)
        let initial = try WorkspaceMacProjection.observe(f.snapshot(), in: WorkspaceReplica(), bindings: [], deviceID: deviceID)
        let id = try XCTUnwrap(UUID(uuidString: f.work.id))
        let backup = f.root.appendingPathComponent("Backups/Snapshot/" + f.work.url.lastPathComponent)
        try FileManager.default.createDirectory(at: backup.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: f.work.url, to: backup)
        try FileManager.default.removeItem(at: f.work.url)
        let snapshot = try XCTUnwrap(f.service.items(under: f.root).first { $0.id == f.work.id })
        XCTAssertEqual(snapshot.url.canonicalPath, backup.canonicalPath)
        let observed = try WorkspaceMacProjection.observe(f.snapshot(work: snapshot), in: initial.replica, bindings: initial.bindings, deviceID: deviceID)
        let rootID = try XCTUnwrap(FileIdentityResolver.identity(of: f.root))
        let deleted = try WorkspaceMacProjection.reconcileMissingSources(observed, workspace: workspace, rootIdentity: rootID, deviceID: deviceID)
        XCTAssertEqual(deleted.replica.records.first { $0.id == id }?.resolved?.content.isDeleted, true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.path), "The snapshot copy is never touched")
    }

    func testUnavailableAreaAndSymlinkNeverBecomeFinderDeletion() throws {
        let f = try Fixture(); defer { f.remove() }
        let workspace = WorkspaceLocation(root: f.root)
        let initial = try WorkspaceMacProjection.observe(f.snapshot(), in: WorkspaceReplica(), bindings: [], deviceID: deviceID)
        let rootID = try XCTUnwrap(FileIdentityResolver.identity(of: f.root))
        let area = f.root.appendingPathComponent("Projects"), aside = f.root.appendingPathComponent("Unavailable")
        try FileManager.default.moveItem(at: area, to: aside)
        let unavailable = try WorkspaceMacProjection.reconcileMissingSources(initial, workspace: workspace, rootIdentity: rootID, deviceID: deviceID)
        XCTAssertEqual(unavailable.replica, initial.replica)
        try FileManager.default.createSymbolicLink(at: area, withDestinationURL: aside)
        let symlink = try WorkspaceMacProjection.reconcileMissingSources(initial, workspace: workspace, rootIdentity: rootID, deviceID: deviceID)
        XCTAssertEqual(symlink.replica, initial.replica)
        XCTAssertThrowsError(try WorkspaceMacProjection.reconcileMissingSources(initial, workspace: workspace, rootIdentity: .init(volume: "unrelated", fileID: 0), deviceID: deviceID))
    }

    func testFinderProjectMoveIntoIdeasKeepsUUIDAndOriginalFiles() throws {
        let f = try Fixture(); defer { f.remove() }
        let workspace = WorkspaceLocation(root: f.root), scope = UUID()
        let original = f.root.appendingPathComponent("Projects/Example")
        let identity = try XCTUnwrap(FileIdentityResolver.identity(of: original))
        let initial = try WorkspaceMacProjection.observe(f.snapshot(), in: WorkspaceReplica(), bindings: [], deviceID: deviceID, projectIdentities: ["Projects/Example": identity])
        let bytes = try Data(contentsOf: f.work.url)
        let destination = f.root.appendingPathComponent("Ideas/Example")
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: original, to: destination)
        let source = try WorkspaceMacFileSource.read(.init(relativePath: "Ideas/Example", kind: .idea), workspace: workspace, bindings: initial.bindings, scope: scope)
        XCTAssertEqual(source.id, UUID(uuidString: f.project.id))
        let observed = try WorkspaceMacProjection.observe(.init(), in: initial.replica, bindings: initial.bindings, deviceID: deviceID, files: [source])
        let idea = try XCTUnwrap(observed.replica.records.first { $0.id == source.id }?.resolved)
        XCTAssertEqual(idea.content.kind, .idea); XCTAssertFalse(idea.content.isDeleted)
        XCTAssertEqual(observed.bindings.first { $0.recordID == source.id }?.relativePath, "Ideas/Example")
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("Work/" + f.work.url.lastPathComponent)), bytes)
        let reconciled = try WorkspaceMacProjection.reconcileMissingSources(observed, workspace: workspace,
            rootIdentity: XCTUnwrap(FileIdentityResolver.identity(of: f.root)), deviceID: deviceID, previousBindings: initial.bindings)
        let workID = try XCTUnwrap(UUID(uuidString: f.work.id))
        let work = try XCTUnwrap(reconciled.replica.records.first { $0.id == workID }?.resolved)
        XCTAssertFalse(work.content.isDeleted); XCTAssertEqual(work.content.parentID, source.id)
        XCTAssertEqual(reconciled.bindings.first { $0.recordID == workID }?.relativePath, "Ideas/Example/Work/" + f.work.url.lastPathComponent)
        XCTAssertNil(reconciled.replica.locationIssues[workID])
        var edited = reconciled.replica, content = work.content; content.body = "Phone edit after Finder move"
        try edited.save(recordID: workID, content: content, expectedHeads: [work.id], deviceID: UUID(), origin: .iOS)
        guard case .update(let prepared) = try WorkspaceMacProjection.prepareWorkSave(recordID: workID, in: edited, bindings: reconciled.bindings, workspace: workspace) else { return XCTFail("Expected a bounded edit at the moved location") }
        XCTAssertEqual(prepared.body, content.body)
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("Work/" + f.work.url.lastPathComponent)), bytes)

        // And back into Projects. Before the Projects listing sees it, the idea's absence
        // from Ideas is a move, not a deletion; then the same record is a project again.
        try FileManager.default.moveItem(at: destination, to: original)
        let rootIdentity = try XCTUnwrap(FileIdentityResolver.identity(of: f.root))
        let unlisted = try WorkspaceMacProjection.reconcileMissingSources(
            WorkspaceMacProjection.observe(.init(), in: reconciled.replica, bindings: reconciled.bindings, deviceID: deviceID),
            workspace: workspace, rootIdentity: rootIdentity, deviceID: deviceID, previousBindings: reconciled.bindings)
        XCTAssertEqual(unlisted.replica.records.first { $0.id == source.id }?.resolved?.content.isDeleted, false, "A moved folder is not a deletion")
        let back = try WorkspaceMacProjection.observe(f.snapshot(), in: unlisted.replica, bindings: unlisted.bindings, deviceID: deviceID,
                                                      projectIdentities: ["Projects/Example": identity])
        let project = try XCTUnwrap(back.replica.records.first { $0.id == source.id }?.resolved)
        XCTAssertEqual(project.content.kind, .project); XCTAssertFalse(project.content.isDeleted)
        XCTAssertEqual(back.bindings.first { $0.recordID == source.id }?.source, .project)
        XCTAssertNil(back.deferredSourceIDs["project:Projects/Example"])

        // A kind change that cannot be proven the same folder waits on its own.
        let unproven = try WorkspaceMacProjection.observe(f.snapshot(), in: unlisted.replica, bindings: unlisted.bindings, deviceID: deviceID)
        XCTAssertNotNil(unproven.deferredSourceIDs["project:Projects/Example"])
        XCTAssertEqual(unproven.replica.records.first { $0.id == source.id }?.resolved?.content.kind, .idea)
    }
}

extension WorkspaceMacProjectionTests {
    /// Me / Agent / Either reaches devices from the Mac file, without changing the
    /// identity of any existing revision that has no responsibility.
    func testResponsibilityIsProjectedWithoutChangingExistingRevisionEncoding() throws {
        let plain = WorkspaceRecordContent(kind: .task, title: "Draft", body: "Body")
        let encoded = String(decoding: try JSONEncoder().encode(plain), as: UTF8.self)
        XCTAssertFalse(encoded.contains("responsibility"), "nil must not be encoded, or every revision's fingerprint changes")
        XCTAssertNil(try JSONDecoder().decode(WorkspaceRecordContent.self, from: Data(encoded.utf8)).responsibility)

        var work = mobileWork(id: "monitor-task", title: "Verify resize", path: "To Do/Verify resize.bw.md")
        work.actionMetadata = .init(fingerprint: "monitor:x", priority: "P1", actionScore: 80, delegation: "USER",
            tags: ["Agent follow-up"], requirements: [], agentExecutability: 10, humanInvolvement: 90, estimatedEffort: "Small",
            category: "Verification", reason: "Needs a person", evidence: ["Codex: try it"], agentSubtasks: [],
            userSubtasks: ["Verify resize"], blockedBy: [], isNextWork: false, isNextAgentAction: false, isNextUserAction: false)
        let observed = try WorkspaceMacProjection.observe(.init(workItems: [work]), in: WorkspaceReplica(), bindings: [], deviceID: deviceID)
        XCTAssertEqual(observed.replica.records.first?.resolved?.content.responsibility, "Me")
        let repeated = try WorkspaceMacProjection.observe(.init(workItems: [work]), in: observed.replica, bindings: observed.bindings, deviceID: deviceID)
        XCTAssertEqual(try repeated.replica.fingerprint, try observed.replica.fingerprint, "no revision churn")
    }
}

extension WorkspaceMacProjectionTests {
    /// Two identities at one unrelated project path must not block every device edit.
    func testAmbiguousUnrelatedProjectDoesNotBlockOtherWorkSaves() throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        var snapshot = fixture.snapshot(); snapshot.entries = []
        let initial = try WorkspaceMacProjection.observe(snapshot, in: WorkspaceReplica(), bindings: [], deviceID: deviceID)
        let id = try XCTUnwrap(UUID(uuidString: fixture.work.id))
        let baseline = try XCTUnwrap(initial.replica.records.first?.resolved)
        var graph = initial.replica, edited = baseline.content; edited.isComplete = true
        try graph.save(recordID: id, content: edited, expectedHeads: [baseline.id], deviceID: UUID(), origin: .iOS)
        let duplicates = (0..<2).map { _ -> WorkspaceMacBinding in
            let identity = UUID()
            return WorkspaceMacBinding(recordID: identity, source: .project, sourceID: identity.uuidString, relativePath: "Projects/Ambiguous",
                                       observedRevisionID: UUID(), fileIdentity: nil, sourceCreatedAt: nil, serviceID: nil)
        }
        guard case .update(let update) = try WorkspaceMacProjection.prepareWorkSave(recordID: id, in: graph, bindings: initial.bindings + duplicates,
                                                                                     workspace: .init(root: fixture.root)) else { return XCTFail("Expected an update") }
        XCTAssertEqual(update.status, .completed)
    }
}

extension WorkspaceMacProjectionTests {
    /// A project renamed in Finder keeps its queue work: the task's unchanged `project:`
    /// line resolves through ProjectStore's aliases in observation, save and reread alike,
    /// and the file's line is never rewritten by an ordinary save.
    func testRenamedProjectKeepsQueueWorkThroughItsFormerPath() throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let queue = fixture.root.appendingPathComponent("To Do")
        try FileManager.default.createDirectory(at: queue, withIntermediateDirectories: true)
        let queued = try fixture.service.create(WorkItem(kind: .task, title: "Queued", status: .open, stage: .now, priority: .medium,
            projectPath: "Projects/Former name", body: "Queued body", url: queue), in: queue)
        let aliases = ["Projects/Former name": "Projects/Example"]
        let unlinked = try WorkspaceMacProjection.observe(fixture.snapshot(work: queued), in: WorkspaceReplica(), bindings: [], deviceID: deviceID)
        XCTAssertNotNil(unlinked.deferredSourceIDs["work:" + queued.id], "Without the alias the link is unresolved")

        let initial = try WorkspaceMacProjection.observe(fixture.snapshot(work: queued), in: WorkspaceReplica(), bindings: [], deviceID: deviceID, projectAliases: aliases)
        XCTAssertTrue(initial.deferredSourceIDs.isEmpty, "\(initial.deferredSourceIDs)")
        let projectID = try XCTUnwrap(initial.bindings.first { $0.source == .project }?.recordID)
        let id = try XCTUnwrap(UUID(uuidString: queued.id))
        let baseline = try XCTUnwrap(initial.replica.records.first { $0.id == id }?.resolved)
        XCTAssertEqual(baseline.content.parentID, projectID)
        let binding = try XCTUnwrap(initial.bindings.first { $0.recordID == id })
        XCTAssertEqual(try WorkspaceMacProjection.readWorkContent(binding, bindings: initial.bindings, workspace: .init(root: fixture.root),
                                                                  replica: initial.replica, projectAliases: aliases), baseline.content)

        var graph = initial.replica, edited = baseline.content; edited.body = "Edited on the phone"
        try graph.save(recordID: id, content: edited, expectedHeads: [baseline.id], deviceID: UUID(), origin: .iOS)
        guard case .update(let update) = try WorkspaceMacProjection.prepareWorkSave(recordID: id, in: graph, bindings: initial.bindings,
                workspace: .init(root: fixture.root), projectAliases: aliases) else { return XCTFail("Expected a body update") }
        XCTAssertEqual(update.body, "Edited on the phone")
        XCTAssertEqual(update.projectPath, "Projects/Former name", "An ordinary save keeps the original line")

        // A path a project currently occupies always wins over an alias.
        let occupied = WorkspaceMacProjection.linking(["Projects/Former name": UUID(), "Projects/Example": projectID], aliases: aliases)
        XCTAssertNotEqual(occupied["Projects/Former name"], projectID)
    }
}

extension WorkspaceMacProjectionTests {
    /// A project archived out of Projects in Finder is retired; its queue work stays, no
    /// longer linked to the retired record, and a device edit to it still saves (observation
    /// and save resolve links the same way).
    func testWorkOfAProjectArchivedInFinderStaysEditable() throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let workspace = WorkspaceLocation(root: fixture.root)
        let queue = fixture.root.appendingPathComponent("To Do")
        try FileManager.default.createDirectory(at: queue, withIntermediateDirectories: true)
        let queued = try fixture.service.create(WorkItem(kind: .task, title: "Queued", status: .open, stage: .now, priority: .medium,
            projectPath: "Projects/Example", body: "Queued body", url: queue), in: queue)
        let identity = try XCTUnwrap(FileIdentityResolver.identity(of: fixture.root.appendingPathComponent("Projects/Example")))
        let initial = try WorkspaceMacProjection.observe(fixture.snapshot(work: queued), in: WorkspaceReplica(), bindings: [], deviceID: deviceID,
                                                         projectIdentities: ["Projects/Example": identity])
        let projectID = try XCTUnwrap(initial.bindings.first { $0.source == .project }?.recordID)
        let id = try XCTUnwrap(UUID(uuidString: queued.id))
        XCTAssertEqual(initial.replica.records.first { $0.id == id }?.resolved?.content.parentID, projectID)

        try FileManager.default.createDirectory(at: fixture.root.appendingPathComponent("Project Archives"), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: fixture.root.appendingPathComponent("Projects/Example"), to: fixture.root.appendingPathComponent("Project Archives/Example"))
        var unlisted = fixture.snapshot(work: queued); unlisted.entries = []
        let rootID = try XCTUnwrap(FileIdentityResolver.identity(of: fixture.root))
        let archived = try WorkspaceMacProjection.reconcileMissingSources(
            WorkspaceMacProjection.observe(unlisted, in: initial.replica, bindings: initial.bindings, deviceID: deviceID),
            workspace: workspace, rootIdentity: rootID, deviceID: deviceID, previousBindings: initial.bindings)
        XCTAssertEqual(archived.replica.records.first { $0.id == projectID }?.resolved?.content.isDeleted, true, "Leaving Projects retires the project")

        let after = try WorkspaceMacProjection.observe(unlisted, in: archived.replica, bindings: archived.bindings, deviceID: deviceID)
        let task = try XCTUnwrap(after.replica.records.first { $0.id == id }?.resolved)
        XCTAssertNotEqual(task.content.parentID, projectID)
        XCTAssertFalse(task.content.isDeleted)
        var graph = after.replica, edited = task.content; edited.body = "Edited after archiving"
        try graph.save(recordID: id, content: edited, expectedHeads: [task.id], deviceID: UUID(), origin: .iOS)
        guard case .update(let update) = try WorkspaceMacProjection.prepareWorkSave(recordID: id, in: graph, bindings: after.bindings, workspace: workspace)
        else { return XCTFail("Expected the edit to save") }
        XCTAssertEqual(update.projectPath, "Projects/Example", "The original line is kept")
    }
}
