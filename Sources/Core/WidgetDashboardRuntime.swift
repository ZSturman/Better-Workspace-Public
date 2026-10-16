import Foundation

/// Shared by a widget provider and its intents. Network requests are optional; a
/// timeout leaves the durable command and last successful projection untouched.
public enum WidgetDashboardRuntime {
    public static var appGroup: String {
        #if os(macOS)
        WidgetAppGroup.mac
        #else
        WidgetAppGroup.mobile
        #endif
    }
    public static func load() -> WorkspaceDashboardSnapshot? {
        guard let store = WidgetCommandStore.shared(appGroup: appGroup), let snapshot = DashboardWidgetStore.load(directory: store.directory) else { return nil }
        try? store.reconcile(snapshot)
        return (try? store.overlay(snapshot)) ?? snapshot
    }
    public static func refresh(force: Bool = false) async {
        #if os(iOS)
        guard let store = WidgetCommandStore.shared(appGroup: appGroup),
              let defaults = UserDefaults(suiteName: appGroup), defaults.bool(forKey: MobileCloudStore.disabledDefaultsKey) == false else { return }
        let existing = DashboardWidgetStore.load(directory: store.directory)
        let pending = ((try? store.records()) ?? []).contains { $0.pending }
        guard force || pending || existing == nil || Date().timeIntervalSince(existing!.updatedAt) > 900,
              (try? store.claim("refresh", seconds: 60)) == true else { return }
        do {
            try await bounded(seconds: 10) {
                defer { try? store.release("refresh") }
                let cloud = MobileCloudStore(defaults: defaults)
                let workspace = MobileIntentOutbox(defaults: defaults, ledger: store)
                _ = await workspace.flush { try await cloud.submit($0) }
                let captures = MobileCaptureQueue(defaults: defaults, ledger: store)
                _ = await captures.flush(using: cloud)
                let ids = try store.records().filter { !$0.settled && $0.edit != nil && $0.state != .cancelled && $0.state != .rejected }.map(\.id)
                let receipts = try await cloud.planningReceipts(for: ids)
                for receipt in receipts { try store.receipt(id: receipt.id, applied: receipt.applied, message: receipt.message, workModifiedAt: receipt.workModifiedAt, now: receipt.appliedAt ?? Date()) }
                let source = try await cloud.fetchSnapshot()
                // The existing cache rejects an empty answer over a populated index.
                let cache = MobileSnapshotCache(appGroup: appGroup)
                guard cache?.save(source) == true else { return }
                let dashboard = WorkspaceDashboardSnapshot.make(from: source)
                try DashboardWidgetStore.saveWorkspace(dashboard, directory: store.directory)
            }
            try store.clear("transportError")
        } catch { try? store.set("transportError", error.localizedDescription) }
        #endif
    }

    public static func complete(taskID: String) throws {
        guard let store = WidgetCommandStore.shared(appGroup: appGroup) else { throw WidgetCommandError.message("Shared widget storage is unavailable.") }
        try complete(taskID: taskID, store: store)
    }
    public static func complete(taskID: String, store: WidgetCommandStore) throws {
        guard let source = DashboardWidgetStore.load(directory: store.directory),
              let original = source.work.first(where: { $0.id == taskID && $0.kind == .task && $0.status != .completed }) else {
            throw WidgetCommandError.message("This task changed or disappeared. Refresh before completing it.")
        }
        guard original.modifiedAt != nil else { throw WidgetCommandError.message("Refresh from Mac to get this task's revision before completing it.") }
        var work = original; work.status = .completed
        let edit = MobilePlanningEdit(operation: .saveWork, title: work.title, work: work, originalWork: original, tagIDs: work.tagIDs)
        try store.append(.planning(edit), coalesce: true)
    }

    public static func undo(id: UUID) throws {
        guard let store = WidgetCommandStore.shared(appGroup: appGroup) else { throw WidgetCommandError.message("Shared widget storage is unavailable.") }
        try undo(id: id, store: store)
    }
    public static func undo(id: UUID, store: WidgetCommandStore) throws {
        guard let record = try store.records().first(where: { $0.id == id }),
              let original = record.edit?.originalWork, let changed = record.edit?.work else { throw WidgetCommandError.message("The completion is no longer available.") }
        if try store.cancelUnsent(id) { return }
        guard record.state == .applied, let source = DashboardWidgetStore.load(directory: store.directory),
              let current = source.work.first(where: { $0.id == changed.id }),
              record.workModifiedAt != nil, current.modifiedAt == record.workModifiedAt, MobilePlanningFiles.sameWidgetFields(current, changed) else {
            throw WidgetCommandError.message("Wait for the Mac's updated task before undoing. A later task edit cannot be reversed here.")
        }
        var work = current; work.status = original.status
        try store.append(.planning(MobilePlanningEdit(operation: .saveWork, title: work.title, work: work, originalWork: current, tagIDs: current.tagIDs)), coalesce: true)
        try store.settle([id])
    }

    private final class Gate: @unchecked Sendable {
        let lock = NSLock(); var resumed = false
        func claim() -> Bool { lock.lock(); defer { lock.unlock() }; guard !resumed else { return false }; resumed = true; return true }
    }
    private static func bounded(seconds: TimeInterval, _ operation: @escaping @Sendable () async throws -> Void) async throws {
        let gate = Gate()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            Task {
                do { try await operation(); if gate.claim() { continuation.resume() } }
                catch { if gate.claim() { continuation.resume(throwing: error) } }
            }
            Task {
                try? await Task.sleep(for: .seconds(seconds))
                if gate.claim() { continuation.resume(throwing: WidgetCommandError.message("Offline · saved actions will retry when connectivity returns.")) }
            }
        }
    }
}
