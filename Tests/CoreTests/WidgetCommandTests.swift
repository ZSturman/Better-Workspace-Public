import XCTest
@testable import BetterWorkspaceCore

final class WidgetCommandTests: XCTestCase {
    private var root: URL!
    private var store: WidgetCommandStore!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("BWWidgetTests-" + UUID().uuidString)
        store = try WidgetCommandStore(directory: root)
    }
    override func tearDownWithError() throws {
        store = nil
        try FileManager.default.removeItem(at: root)
    }
    private func review(id: String = "item", fingerprint: String? = "sha256-original") -> MobilePlanningEdit {
        .init(operation: .reviewInbox, title: "Read.md", inboxReview: .init(item: .init(id: id, path: "To Read/Read.md", title: "Read.md", category: "To Read", modified: Date(timeIntervalSince1970: 5), size: 2, preview: "Hi", fingerprint: fingerprint), action: .done))
    }
    func testConfirmationExpiresAndCannotConfirmAnotherPreview() throws {
        let time = Date(timeIntervalSince1970: 1000)
        let first = try store.stage(scope: "review", edit: review(), now: time)
        _ = try store.stage(scope: "review", edit: review(id: "another"), now: time)
        XCTAssertThrowsError(try store.confirm(scope: "review", token: first.id, now: time))
        let second = try store.confirmation(scope: "review", now: time)!
        XCTAssertThrowsError(try store.confirm(scope: "review", token: second.id, now: time.addingTimeInterval(301)))
        XCTAssertTrue(try store.records().isEmpty)
        XCTAssertThrowsError(try store.stage(scope: "review", edit: review(fingerprint: nil)))
        XCTAssertThrowsError(try store.stage(scope: "review", edit: review(fingerprint: "")))
    }
    func testCancelAndDuplicateConfirmationDoNotCreateExtraCommands() throws {
        let first = try store.stage(scope: "review", edit: review())
        try store.clear("confirmation:review")
        XCTAssertThrowsError(try store.confirm(scope: "review", token: first.id))
        let second = try store.stage(scope: "review", edit: review())
        let id = try store.confirm(scope: "review", token: second.id)
        XCTAssertThrowsError(try store.confirm(scope: "review", token: second.id))
        XCTAssertEqual(try store.append(.planning(review()), coalesce: true), id)
        XCTAssertEqual(try store.records().count, 1)
    }
    func testConcurrentConnectionsKeepEveryCommandAndExclusiveDeliveryLease() throws {
        let other = try WidgetCommandStore(directory: root)
        let group = DispatchGroup()
        let errors = ErrorBox()
        for index in 0..<30 {
            group.enter()
            DispatchQueue.global().async {
                defer { group.leave() }
                do { try (index.isMultiple(of: 2) ? self.store! : other).append(.planning(self.review(id: "\(index)"))) }
                catch { errors.add(error) }
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 10), .success)
        XCTAssertTrue(errors.values.isEmpty, "\(errors.values)")
        XCTAssertEqual(try store.records().count, 30)
        XCTAssertTrue(try store.beginDelivery(stream: "workspace"))
        XCTAssertFalse(try other.beginDelivery(stream: "workspace"))
    }
    func testSendingCannotBeCancelledAndRejectionSurvivesReopen() throws {
        let id = try store.append(.planning(review()))
        XCTAssertTrue(try store.beginSending(id))
        XCTAssertFalse(try store.cancelUnsent(id), "A network send must not race with Undo")
        try store.receipt(id: id, applied: false, message: "Original changed")
        let reopened = try WidgetCommandStore(directory: root)
        XCTAssertEqual(try reopened.records().first?.state, .rejected)
        XCTAssertEqual(try reopened.records().first?.message, "Original changed")
    }
    func testLegacyMigrationPreservesIDsErrorsAndDoesNotReplayTwice() throws {
        let suite = "BWWidgetMigration-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let edit = review()
        defaults.set(try JSONEncoder().encode([edit]), forKey: "BWMobilePlanningDrafts")
        defaults.set([edit.id.uuidString: "Conflict"], forKey: "BWMobilePlanningErrors")
        try store.migrate(defaults: defaults, outboxKey: "mobileWorkspaceIntentOutbox", stream: "workspace", planning: true)
        try store.migrate(defaults: defaults, outboxKey: "mobileWorkspaceIntentOutbox", stream: "workspace", planning: true)
        XCTAssertEqual(try store.records().map(\.id), [edit.id])
        XCTAssertEqual(try store.records().first?.state, .rejected)
        XCTAssertNotNil(defaults.data(forKey: "BWMobilePlanningDrafts"))
    }
    func testDraftSaveDoesNotEraseAnotherProcessNewDraft() throws {
        let defaults = UserDefaults(suiteName: "BWWidgetDraft-" + UUID().uuidString)!
        let drafts = MobilePlanningDraftStore(defaults: defaults, ledger: store)
        _ = drafts.load()
        let edit = review()
        try store.append(.planning(edit))
        drafts.save([])
        XCTAssertEqual(drafts.load().map(\.id), [edit.id])
    }
    func testUnsentCompletionOverlayCountsProgressAndCancelsCleanly() throws {
        let task = MobileWorkItem(id: "task", path: "Projects/A/Work/T.bw.md", title: "Task", kind: .task, status: .open, stage: .next, priority: .medium, projectPath: "Projects/A", revision: 1)
        var changed = task; changed.status = .completed
        let source = WorkspaceDashboardSnapshot.make(from: .init(entries: [.init(path: "Projects/A", parentPath: "Projects", name: "A", isDirectory: true, revision: 1)], workItems: [task]))
        let id = try store.append(.planning(.init(operation: .saveWork, title: task.title, work: changed, originalWork: task)))
        XCTAssertEqual(try store.overlay(source).projects.first?.focus.completed, 1)
        XCTAssertTrue(try store.cancelUnsent(id))
        XCTAssertEqual(try store.overlay(source).projects.first?.focus.completed, 0)
    }
    func testFilingRejectsUnboundedDestinationsAndSnapshotWriteIsAtomic() throws {
        let capture = DashboardCapture(name: "Capture.md", modified: Date())
        XCTAssertThrowsError(try MobilePlanningFiles.validate(.init(operation: .fileCapture, title: capture.name, captureFiling: .init(capture: capture, destination: "../Outside"))))
        let source = WorkspaceDashboardSnapshot(captures: [capture], captureCount: 1)
        try DashboardWidgetStore.save(source, directory: root)
        XCTAssertEqual(DashboardWidgetStore.load(directory: root)?.captures, [capture])
    }
    func testCompletionReversalRequiresExactAppliedRevision() throws {
        let original = MobileWorkItem(id: "task", path: "Tasks/T.bw.md", title: "Task", kind: .task, status: .open,
            stage: .next, priority: .medium, revision: 1, modifiedAt: Date(timeIntervalSince1970: 10))
        var source = WorkspaceDashboardSnapshot(work: [original])
        try DashboardWidgetStore.save(source, directory: root)
        try WidgetDashboardRuntime.complete(taskID: "task", store: store)
        let id = try XCTUnwrap(store.records().first?.id)
        XCTAssertTrue(try store.beginSending(id))
        let revision = Date(timeIntervalSinceReferenceDate: 813_490_123.1234567)
        try store.receipt(id: id, applied: true, workModifiedAt: revision)
        XCTAssertEqual(try store.records().first?.workModifiedAt, revision, "Subsecond revision tokens must round-trip exactly")
        XCTAssertThrowsError(try WidgetDashboardRuntime.undo(id: id, store: store), "The downloaded index is still stale")
        var completed = original; completed.status = .completed; completed.modifiedAt = Date(timeIntervalSince1970: 21)
        source.work = [completed]; try DashboardWidgetStore.save(source, directory: root)
        XCTAssertThrowsError(try WidgetDashboardRuntime.undo(id: id, store: store), "Even a notes-only edit changes the revision")
        completed.modifiedAt = revision
        source.work = [completed]; try DashboardWidgetStore.save(source, directory: root)
        try WidgetDashboardRuntime.undo(id: id, store: store)
        let reversal = try XCTUnwrap(store.records().last?.edit)
        XCTAssertEqual(reversal.work?.status, .open)
        XCTAssertEqual(reversal.originalWork?.modifiedAt, completed.modifiedAt)
    }
    func testInterruptedDeliveryRecoversSameImmutableOperation() throws {
        let id = try store.append(.planning(review()))
        XCTAssertTrue(try store.beginDelivery(stream: "capture"))
        XCTAssertTrue(try store.beginSending(id))
        try store.release("delivery:capture")
        let reopened = try WidgetCommandStore(directory: root)
        XCTAssertTrue(try reopened.beginDelivery(stream: "workspace"))
        XCTAssertEqual(try reopened.records().first?.id, id)
        XCTAssertEqual(try reopened.records().first?.state, .queued)
    }
    func testSnapshotDoesNotOverlayTaskEditedAfterPreview() throws {
        let original = MobileWorkItem(id: "task", path: "Tasks/T.bw.md", title: "Task", kind: .task, status: .open,
            stage: .next, priority: .medium, revision: 1, modifiedAt: Date(timeIntervalSince1970: 10))
        var completed = original; completed.status = .completed
        try store.append(.planning(.init(operation: .saveWork, title: original.title, work: completed, originalWork: original)))
        var later = original; later.modifiedAt = Date(timeIntervalSince1970: 11)
        XCTAssertEqual(try store.overlay(.init(work: [later])).work.first?.status, .open)
    }
    func testConcurrentCaptureAndWorkspacePublicationPreservesBoth() throws {
        let source = WorkspaceDashboardSnapshot(captureCount: 0)
        try DashboardWidgetStore.save(source, directory: root)
        let group = DispatchGroup(), errors = ErrorBox()
        for index in 0..<20 {
            group.enter()
            DispatchQueue.global().async {
                defer { group.leave() }
                do {
                    if index.isMultiple(of: 2) { try DashboardWidgetStore.saveWorkspace(source, directory: self.root) }
                    else {
                        try DashboardWidgetStore.update(directory: self.root) { existing in
                            var value = existing!; value.captureCount = (value.captureCount ?? 0) + 1; return value
                        }
                    }
                } catch { errors.add(error) }
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 10), .success)
        XCTAssertTrue(errors.values.isEmpty)
        XCTAssertEqual(DashboardWidgetStore.load(directory: root)?.captureCount, 10)
    }
    func testDeliveredLegacyCaptureDoesNotFillPendingCapacity() throws {
        let intent = MobileWorkspaceIntent.captureClassification(name: "Capture.md", kind: nil, tagIDs: [])
        try store.append(intent, stream: "capture")
        try store.delivered([intent.id])
        XCTAssertFalse(try XCTUnwrap(store.records().first).pending)
    }
    func testAppliedReviewSettlesOnlyAgainstFreshQueueAndCanReappearAfterMacUndo() throws {
        let edit = review(), applied = Date(timeIntervalSince1970: 100)
        let id = try store.append(.planning(edit))
        try store.receipt(id: id, applied: true, now: applied)
        try store.receipt(id: id, applied: true, now: applied.addingTimeInterval(20))
        XCTAssertEqual(try store.records().first?.appliedAt, applied, "Reading a receipt again must not move its application time")
        var source = WorkspaceDashboardSnapshot(reviewItems: [edit.inboxReview!.item], reviewCount: 1,
            reviewCheckedAt: applied.addingTimeInterval(-1), updatedAt: applied.addingTimeInterval(30))
        try store.reconcile(source)
        XCTAssertFalse(try XCTUnwrap(store.records().first).settled)
        XCTAssertTrue(try store.overlay(source).reviewItems.isEmpty)
        source.reviewCheckedAt = applied.addingTimeInterval(1)
        try store.reconcile(source)
        XCTAssertTrue(try XCTUnwrap(store.records().first).settled)
        XCTAssertEqual(try store.overlay(source).reviewItems.map(\.id), [edit.inboxReview!.item.id], "A canonical Mac Undo may restore the same item")
    }
    func testAppliedFilingDoesNotHideNewCaptureWithReusedName() throws {
        let applied = Date(timeIntervalSince1970: 100)
        let original = DashboardCapture(name: "Capture.md", modified: applied.addingTimeInterval(-10))
        let id = try store.append(.planning(.init(operation: .fileCapture, title: original.name,
            captureFiling: .init(capture: original, destination: "Tasks"))))
        try store.receipt(id: id, applied: true, now: applied)
        let newer = DashboardCapture(name: original.name, modified: applied.addingTimeInterval(1))
        let source = WorkspaceDashboardSnapshot(captures: [newer], captureCount: 1,
            captureUpdatedAt: applied.addingTimeInterval(2), updatedAt: applied.addingTimeInterval(2))
        XCTAssertEqual(try store.overlay(source).captures, [newer])
        try store.reconcile(source)
        XCTAssertTrue(try XCTUnwrap(store.records().first).settled)
        XCTAssertEqual(try store.overlay(source).captureCount, 1)
    }
    func testAppliedCompletionSettlesWhenCanonicalRevisionArrives() throws {
        let applied = Date(timeIntervalSince1970: 100)
        let original = MobileWorkItem(id: "task", path: "Tasks/T.bw.md", title: "Task", kind: .task, status: .open,
            stage: .next, priority: .medium, revision: 1, modifiedAt: applied.addingTimeInterval(-10))
        var completed = original; completed.status = .completed
        let id = try store.append(.planning(.init(operation: .saveWork, title: original.title, work: completed, originalWork: original)))
        try store.receipt(id: id, applied: true, workModifiedAt: applied, now: applied)
        var source = WorkspaceDashboardSnapshot(work: [original], updatedAt: applied.addingTimeInterval(1))
        try store.reconcile(source)
        XCTAssertFalse(try XCTUnwrap(store.records().first).settled)
        completed.modifiedAt = applied; source.work = [completed]
        try store.reconcile(source)
        XCTAssertTrue(try XCTUnwrap(store.records().first).settled)
        try DashboardWidgetStore.save(source, directory: root)
        try WidgetDashboardRuntime.undo(id: id, store: store)
        XCTAssertEqual(try store.records().last?.edit?.work?.status, .open)
    }
    private final class ErrorBox: @unchecked Sendable {
        private let lock = NSLock(); private var stored: [String] = []
        var values: [String] { lock.lock(); defer { lock.unlock() }; return stored }
        func add(_ error: Error) { lock.lock(); defer { lock.unlock() }; stored.append(String(describing: error)) }
    }
}
