import XCTest
import SwiftData
@testable import BetterWorkspaceCore

@MainActor
final class WorkspaceSessionTests: XCTestCase {
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bw-session-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        return root
    }
    func testAllKindsSaveOfflineReopenAndStaleEditorPreservesNewerVersion() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let session = try await WorkspaceSession.open(directory: root, fixture: true)
        let project = try await session.save(content: .init(kind: .project, title: "Offline project"), expectedHeads: [])
        for kind in WorkspaceRecordContent.Kind.allCases where kind != .project {
            _ = try await session.save(content: .init(kind: kind, title: kind.rawValue, body: "Written without a Mac · ✓", parentID: project.recordID), expectedHeads: [])
        }
        try session.finishWelcome()
        let reopened = try await WorkspaceSession.open(directory: root, fixture: true)
        XCTAssertEqual(reopened.records.count, WorkspaceRecordContent.Kind.allCases.count)
        XCTAssertTrue(reopened.settings.welcomeCompleted); XCTAssertFalse(reopened.cloudEnabled)
        XCTAssertEqual(reopened.deviceID, session.deviceID)
        var edited = project.content; edited.title = "Renamed"
        let rename = try await reopened.save(recordID: project.recordID, content: edited, expectedHeads: [project.id])
        do { _ = try await session.save(recordID: project.recordID, content: project.content, expectedHeads: [project.id]); XCTFail("Stale Save must fail") }
        catch { XCTAssertEqual(error as? WorkspaceReplicaError, .changed) }
        XCTAssertEqual(try reopened.store.load().records.first { $0.id == project.recordID }?.resolved?.id, rename.id)
    }
    func testReviewedMergeIsCheckpointedAndRecoveryRetainsLaterChanges() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let session = try await WorkspaceSession.open(directory: root, fixture: true)
        let local = try await session.save(content: .init(kind: .note, title: "Same title", body: "Original"), expectedHeads: [])
        var incoming = try WorkspaceReplica()
        _ = try incoming.save(content: .init(kind: .note, title: "Same title", body: "Another device"), expectedHeads: [], deviceID: UUID(), origin: .mac)
        let peer = WorkspaceCloudPeer(deviceID: UUID(), sourceID: incoming.workspaceID, name: "Mac", platform: "Mac", replica: incoming, approvals: [])
        let preview = try session.review(peer)
        XCTAssertEqual(preview.addedRevisionCount, 1)
        let checkpoint = try await session.approve(peer, preview: preview)
        XCTAssertEqual(session.records.count, 2); XCTAssertEqual(try session.checkpoints().map(\.canonicalPath), [checkpoint.canonicalPath])
        XCTAssertEqual(Set(session.replica.displayTitles.values).count, 2)
        var changed = local.content; changed.body = "Later edit"
        _ = try await session.save(recordID: local.recordID, content: changed, expectedHeads: [local.id])
        try await session.recover(checkpoint)
        let recovered = try XCTUnwrap(session.records.first { $0.id == local.recordID })
        XCTAssertTrue(recovered.isConflict)
        XCTAssertEqual(Set(recovered.heads.map { $0.content.body }), ["Original", "Later edit"])
        XCTAssertEqual(session.records.count, 2)
    }
    func testStaleMergePreviewDoesNotJoinOrCreateCheckpoint() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let session = try await WorkspaceSession.open(directory: root, fixture: true)
        let incoming = try WorkspaceReplica()
        let peer = WorkspaceCloudPeer(deviceID: UUID(), sourceID: incoming.workspaceID, name: "iPad", platform: "iOS", replica: incoming, approvals: [])
        let preview = try session.review(peer)
        _ = try await session.save(content: .init(kind: .idea, title: "Changed during review"), expectedHeads: [])
        do { _ = try await session.approve(peer, preview: preview); XCTFail("Stale approval must fail") }
        catch { XCTAssertEqual(error as? WorkspaceReplicaError, .changed) }
        XCTAssertEqual(session.replica.joinedWorkspaceIDs, [session.sourceID]); XCTAssertTrue(try session.checkpoints().isEmpty)
    }
    func testPeerListRetainsConnectedDevicesAfterApprovalAndRefresh() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let session = try await WorkspaceSession.open(directory: root, fixture: true)
        let incoming = try WorkspaceReplica()
        let peer = WorkspaceCloudPeer(deviceID: UUID(), sourceID: incoming.workspaceID, name: "iPad", platform: "iOS", replica: incoming, approvals: [])
        try await session.receive([session.payload(), peer])
        XCTAssertEqual(session.pendingPeers.map(\.id), [peer.id]); XCTAssertTrue(session.connectedPeers.isEmpty)
        _ = try await session.approve(peer, preview: session.review(peer))
        XCTAssertTrue(session.pendingPeers.isEmpty)
        XCTAssertEqual(session.connectedPeers.map(\.id), [peer.id], "Approval must not make the peer disappear")
        try await session.receive([session.payload(), peer])
        XCTAssertTrue(session.pendingPeers.isEmpty); XCTAssertEqual(session.connectedPeers.map(\.id), [peer.id])
        try await session.receive([session.payload()])
        XCTAssertTrue(session.connectedPeers.isEmpty, "Removed advertisements must not remain listed")
    }
    func testUpgradeReadsOriginalDiskStoreWithoutModifyingItAndImportsAreIdempotent() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let original = try WorkspaceNotebookPersistence.container(at: root.appendingPathComponent("Earlier/Notebook.store"))
        let project = try WorkspaceNotebookEditor.save(in: original.mainContext, kind: .project, title: "Earlier project", body: "Keep", projectID: nil)
        let note = try WorkspaceNotebookEditor.save(in: original.mainContext, kind: .document, title: "Earlier note", body: "Offline text", projectID: project.recordID)
        let session = try await WorkspaceSession.open(directory: root.appendingPathComponent("Current"), fixture: true)
        try await session.importNotebook(from: original.mainContext)
        let first = try XCTUnwrap(session.records.first { $0.id == note.recordID }?.resolved)
        var changed = first.content; changed.body = "Current edit"
        _ = try await session.save(recordID: note.recordID, content: changed, expectedHeads: [first.id])
        let before = try session.replica.fingerprint
        try await session.importNotebook(from: original.mainContext)
        XCTAssertEqual(try session.replica.fingerprint, before)
        XCTAssertEqual(session.records.first { $0.id == note.recordID }?.resolved?.content.parentID, project.recordID)
        let reopened = try WorkspaceNotebookPersistence.container(at: root.appendingPathComponent("Earlier/Notebook.store"))
        let rows = try reopened.mainContext.fetch(FetchDescriptor<WorkspaceNotebookRecord>())
        XCTAssertEqual(rows.count, 2); XCTAssertEqual(rows.first { $0.recordID == note.recordID }?.body, "Offline text")
    }
    func testCorruptSettingsNeverReplaceWorkspace() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let session = try await WorkspaceSession.open(directory: root, fixture: true)
        _ = try await session.save(content: .init(kind: .idea, title: "Retain"), expectedHeads: [])
        let bytes = try Data(contentsOf: root.appendingPathComponent("workspace.json"))
        try Data("broken".utf8).write(to: root.appendingPathComponent("settings.json"))
        do { _ = try await WorkspaceSession.open(directory: root, fixture: true); XCTFail("Corruption must be surfaced") } catch { }
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("workspace.json")), bytes)
    }
    func testJoinApprovalOnlyAcknowledgesExactReviewedOfflineBase() throws {
        let a = try WorkspaceReplica(), b = try WorkspaceReplica()
        let approval = try WorkspaceJoinApproval(local: a, incoming: b, authorDeviceID: UUID())
        let joined = try a.joining(b)
        XCTAssertTrue(try approval.authorizes(local: b, incoming: joined))
        var edited = b
        _ = try edited.save(content: .init(kind: .task, title: "New offline work"), expectedHeads: [], deviceID: UUID(), origin: .iOS)
        XCTAssertFalse(try approval.authorizes(local: edited, incoming: joined))
        XCTAssertFalse(try approval.authorizes(local: WorkspaceReplica(), incoming: joined))
    }
    func testCloudAdvertisementUnionSurvivesCanonicalIdentityAdoptionAndRacingRestore() throws {
        let device = UUID()
        var old = try WorkspaceReplica()
        _ = try old.save(content: .init(kind: .task, title: "Server only"), expectedHeads: [], deviceID: device, origin: .iOS)
        var localBase = try WorkspaceReplica(workspaceID: old.workspaceID)
        _ = try localBase.save(content: .init(kind: .idea, title: "Local only"), expectedHeads: [], deviceID: device, origin: .iOS)
        let local = try localBase.joining(WorkspaceReplica())
        let combined = try WorkspaceCloudTransport.combined(.init(deviceID: device, sourceID: old.workspaceID, name: "Device", platform: "iOS", replica: local, approvals: []),
            with: .init(deviceID: device, sourceID: old.workspaceID, name: "Device", platform: "iOS", replica: old, approvals: []))
        XCTAssertEqual(combined.replica.workspaceID, local.workspaceID); XCTAssertEqual(combined.replica.records.count, 2)
        XCTAssertThrowsError(try WorkspaceCloudTransport.combined(combined, with: .init(deviceID: UUID(), sourceID: old.workspaceID, name: "Other", platform: "iOS", replica: old, approvals: [])))
    }
}

final class WorkspaceMacWriteJournalTests: XCTestCase {
    func testInterruptedWriteAcknowledgesExactRevisionWhenNewerEditArrives() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bw-write-journal-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var graph = try WorkspaceReplica()
        let first = try graph.save(content: .init(kind: .task, title: "Original"), expectedHeads: [], deviceID: UUID(), origin: .mac)
        var changed = first.content; changed.title = "Write in flight"
        let selected = try graph.save(recordID: first.recordID, content: changed, expectedHeads: [first.id], deviceID: UUID(), origin: .iOS)
        let binding = WorkspaceMacBinding(recordID: first.recordID, source: .work, sourceID: first.recordID.uuidString, relativePath: "To Do/Task.bw.md", observedRevisionID: first.id)
        let request = WorkspaceMacWriteRequest(binding: binding, revisionID: selected.id)
        let journal = WorkspaceMacWriteJournal(directory: root)
        try journal.begin(request); try journal.begin(request)
        changed.title = "Arrived during write"
        let newer = try graph.save(recordID: first.recordID, content: changed, expectedHeads: [selected.id], deviceID: UUID(), origin: .iOS)
        let reopened = WorkspaceMacWriteJournal(directory: root)
        XCTAssertEqual(try reopened.pending(), [request])
        XCTAssertEqual(try request.selectedReplica(in: graph).records.first?.resolved?.id, selected.id)
        let ack = try request.acknowledgedBindings([binding])
        XCTAssertEqual(ack.first?.observedRevisionID, selected.id)
        let source = MobileWorkItem(id: first.recordID.uuidString, path: binding.relativePath, title: selected.content.title, kind: .task, status: .open, stage: .next, priority: .medium, revision: 1, body: "")
        let observed = try WorkspaceMacProjection.observe(.init(workItems: [source]), in: graph, bindings: ack, deviceID: UUID())
        XCTAssertEqual(observed.replica.records.first?.resolved?.id, newer.id)
        XCTAssertEqual(observed.replica.revisions.count, graph.revisions.count)
        try reopened.finish(request); XCTAssertTrue(try journal.pending().isEmpty)
    }
    func testUnrelatedAncestryOrReboundSourceCannotAcknowledgeRequest() throws {
        var graph = try WorkspaceReplica()
        let first = try graph.save(content: .init(kind: .task, title: "A"), expectedHeads: [], deviceID: UUID(), origin: .mac)
        let unrelated = try graph.save(content: .init(kind: .task, title: "B"), expectedHeads: [], deviceID: UUID(), origin: .mac)
        let binding = WorkspaceMacBinding(recordID: first.recordID, source: .work, sourceID: first.recordID.uuidString, relativePath: "To Do/A.bw.md", observedRevisionID: first.id)
        let request = WorkspaceMacWriteRequest(binding: binding, revisionID: unrelated.id)
        XCTAssertThrowsError(try request.selectedReplica(in: graph))
        let valid = WorkspaceMacWriteRequest(binding: binding, revisionID: first.id)
        let changed = WorkspaceMacBinding(recordID: binding.recordID, source: .work, sourceID: binding.sourceID, relativePath: "To Do/Rebound.bw.md", observedRevisionID: UUID())
        XCTAssertThrowsError(try valid.acknowledgedBindings([changed]))
    }
}

@MainActor
final class WorkspaceUnifiedWidgetTests: XCTestCase {
    func testProjectionPreservesIntegrationsRemovesStaleDeletedVersionsAndOmitsBodies() throws {
        var graph = try WorkspaceReplica()
        let project = try graph.save(content: .init(kind: .project, title: "Portable project"), expectedHeads: [], deviceID: UUID(), origin: .iOS)
        let task = try graph.save(content: .init(kind: .task, title: "Portable task", body: "Private note body", parentID: project.recordID), expectedHeads: [], deviceID: UUID(), origin: .iOS)
        let old = MobileWorkItem(id: task.recordID.uuidString, path: "Projects/Existing/Task.bw.md", title: "Previous title", kind: .task, status: .open, stage: .now, priority: .high, dueDate: Date(), revision: 4)
        let capture = DashboardCapture(name: "Existing capture.md", modified: Date())
        let source = WorkspaceDashboardSnapshot(work: [old], captures: [capture], captureCount: 1)
        let combined = WorkspaceUnifiedWidgets.overlay(source, replica: graph)
        XCTAssertEqual(combined.captures, [capture]); XCTAssertEqual(combined.captureCount, 1)
        XCTAssertEqual(combined.work.count, 1); XCTAssertEqual(combined.work.first?.title, "Portable task")
        XCTAssertNil(combined.work.first?.body); XCTAssertEqual(combined.work.first?.priority, .high)
        XCTAssertEqual(combined.work.first?.stage, .now); XCTAssertEqual(combined.work.first?.workspaceRevisionID, task.id)
        XCTAssertEqual(combined.work.first?.projectPath, combined.projects.first?.path)
        XCTAssertEqual(combined.projects.first?.focus.total, 1)
        var deleted = task.content; deleted.isDeleted = true
        _ = try graph.save(recordID: task.recordID, content: deleted, expectedHeads: [task.id], deviceID: UUID(), origin: .iOS)
        XCTAssertTrue(WorkspaceUnifiedWidgets.overlay(source, replica: graph).work.isEmpty)
    }
    func testWidgetCompletionUsesExactJournalHeadAndWorksWithoutMacQueue() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bw-widget-journal-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let session = try await WorkspaceSession.open(directory: root, fixture: true)
        let task = try await session.save(content: .init(kind: .task, title: "Complete offline", body: "Preserve notes"), expectedHeads: [])
        XCTAssertThrowsError(try WorkspaceUnifiedWidgets.completeIfPresent(taskID: task.recordID.uuidString, expectedRevisionID: UUID(), directory: root))
        XCTAssertTrue(try WorkspaceUnifiedWidgets.completeIfPresent(taskID: task.recordID.uuidString, expectedRevisionID: task.id, directory: root))
        let saved = try XCTUnwrap(session.store.load().records.first?.resolved)
        XCTAssertTrue(saved.content.isComplete); XCTAssertEqual(saved.content.body, "Preserve notes"); XCTAssertEqual(saved.parents, [task.id])
        XCTAssertThrowsError(try WorkspaceUnifiedWidgets.completeIfPresent(taskID: task.recordID.uuidString, expectedRevisionID: task.id, directory: root))
        XCTAssertFalse(try WorkspaceUnifiedWidgets.completeIfPresent(taskID: UUID().uuidString, expectedRevisionID: UUID(), directory: root))
    }
}

extension WorkspaceSessionTests {
    func testActualPeerDeliveryRequiresApprovalThenPreservesRepeatedOfflineConflicts() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let a = try await WorkspaceSession.open(directory: root.appendingPathComponent("A"), fixture: true)
        let b = try await WorkspaceSession.open(directory: root.appendingPathComponent("B"), fixture: true)
        let item = try await a.save(content: .init(kind: .note, title: "Shared"), expectedHeads: [])
        _ = try await b.save(content: .init(kind: .idea, title: "B only"), expectedHeads: [])
        try await a.receive([b.payload()])
        XCTAssertEqual(a.pendingPeers.count, 1); XCTAssertEqual(a.records.count, 1)
        _ = try await a.approve(b.payload(), preview: a.review(b.payload()))
        try await b.receive([a.payload()])
        XCTAssertTrue(b.pendingPeers.isEmpty); XCTAssertEqual(a.replica, b.replica)
        var left = item.content; left.body = "A offline"
        _ = try await a.save(recordID: item.recordID, content: left, expectedHeads: [item.id])
        var right = item.content; right.body = "B offline"
        _ = try await b.save(recordID: item.recordID, content: right, expectedHeads: [item.id])
        try await a.receive([b.payload()]); try await b.receive([a.payload()])
        let fingerprint = try a.replica.fingerprint
        try await a.receive([b.payload()]); try await b.receive([a.payload()])
        XCTAssertEqual(try a.replica.fingerprint, fingerprint)
        XCTAssertEqual(try b.replica.fingerprint, fingerprint)
        XCTAssertTrue(a.records.first { $0.id == item.recordID }!.isConflict)
        XCTAssertEqual(a.records.count, 2)
    }
}

extension WorkspaceSessionTests {
    func testConcurrentSetupSharesOnePersistentInstallationIdentity() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let identities = try await withThrowingTaskGroup(of: UUID.self) { group in
            for _ in 0..<8 {
                group.addTask { @MainActor in try await WorkspaceSession.open(directory: root, fixture: true).deviceID }
            }
            var values: [UUID] = []
            for try await identity in group { values.append(identity) }
            return values
        }
        XCTAssertEqual(Set(identities).count, 1)
        let reopened = try await WorkspaceSession.open(directory: root, fixture: true)
        XCTAssertEqual(reopened.deviceID, identities.first)
        XCTAssertEqual(reopened.replica.joinedWorkspaceIDs, [reopened.sourceID])
    }
}

extension WorkspaceSessionTests {
    func testCachedViewDataTracksEditsDeletionAndUnchangedRefresh() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let session = try await WorkspaceSession.open(directory: root, fixture: true)
        let first = try await session.save(content: .init(kind: .note, title: "Same"), expectedHeads: [])
        _ = try await session.save(content: .init(kind: .note, title: "Same"), expectedHeads: [])
        XCTAssertEqual(Set(session.displayTitles.values).count, 2)
        XCTAssertEqual(session.records.flatMap(\.heads), session.replica.records.flatMap(\.heads))
        var deleted = first.content; deleted.isDeleted = true
        _ = try await session.save(recordID: first.recordID, content: deleted, expectedHeads: [first.id])
        XCTAssertEqual(Array(session.displayTitles.values), ["Same"])
        let titles = session.displayTitles, before = session.records
        try await session.reload()
        XCTAssertEqual(session.records.flatMap(\.heads), before.flatMap(\.heads)); XCTAssertEqual(session.displayTitles, titles)
        XCTAssertEqual(session.locationIssues, session.replica.locationIssues)
    }

    /// A save during a pass used to be dropped until the next periodic pass (or the next
    /// launch, when the app was closed first). It now gets a follow-up pass, and its caller
    /// returns only after that pass.
    func testAChangeSavedDuringAPassGetsAFollowUpPassBeforeItsCallerReturns() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let session = try await WorkspaceSession.open(directory: root, fixture: true)
        var passes = 0, second: Task<Void, Never>?, secondReturnedAfter = 0
        session.macBridge = {
            passes += 1
            if passes == 1 {
                second = Task { @MainActor in await session.synchronize(); secondReturnedAfter = passes }
                try await Task.sleep(for: .milliseconds(300))
            }
        }
        await session.synchronize()
        await second?.value
        XCTAssertEqual(passes, 2, "One follow-up pass, no more")
        XCTAssertEqual(secondReturnedAfter, 2, "The caller waited for its pass")
        XCTAssertFalse(session.syncing)
    }

    /// A peer that adds nothing is accepted without reloading or rewriting the store; one
    /// with a new revision is still merged.
    func testAnUnchangedPeerIsSkippedAndANewRevisionStillArrives() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let session = try await WorkspaceSession.open(directory: root, fixture: true)
        let project = try await session.save(content: .init(kind: .project, title: "Shared"), expectedHeads: [])
        let store = root.appendingPathComponent("workspace.json")
        let before = try FileManager.default.attributesOfItem(atPath: store.path)[.modificationDate] as? Date
        let same = WorkspaceCloudPeer(deviceID: UUID(), sourceID: session.sourceID, name: "iPad", platform: "iOS", replica: session.replica, approvals: [])
        try await session.receive([session.payload(), same])
        XCTAssertTrue(session.pendingPeers.isEmpty)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: store.path)[.modificationDate] as? Date, before, "Nothing was rewritten")

        var theirs = session.replica, content = project.content; content.title = "Renamed on the iPad"
        try theirs.save(recordID: project.recordID, content: content, expectedHeads: [project.id], deviceID: same.deviceID, origin: .iOS)
        let changed = WorkspaceCloudPeer(deviceID: same.deviceID, sourceID: session.sourceID, name: "iPad", platform: "iOS", replica: theirs, approvals: [])
        try await session.receive([session.payload(), changed])
        XCTAssertEqual(session.records.first { $0.id == project.recordID }?.resolved?.content.title, "Renamed on the iPad")
    }
}
