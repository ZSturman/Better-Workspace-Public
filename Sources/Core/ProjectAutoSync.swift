import Foundation

/// One pass of automatic Notion sync: read what changed, then apply only what
/// `ProjectAutoSyncPlanner` says may move without a person.
///
/// Every write goes through `NotionProjectSync`, so the same protections hold as for a
/// reviewed Send or Get: one operation at a time, a re-read before every write, three-way
/// field merge, and journaled page creation that is never blindly retried. A failure is
/// kept to its record and retried later with backoff; it never stops the rest of the pass.
/// Nothing here runs unless the person has turned automatic sync on.
public actor ProjectAutoSync {
    public struct Report: Codable, Sendable, Equatable {
        public var finishedAt: Date?
        /// Record ids whose Notion side was taken here.
        public var received: [String] = []
        /// Record ids whose side was sent to Notion.
        public var sent: [String] = []
        public var failed: [String: String] = [:]
        public var attention = 0
        public var waiting = 0
        public var deferred = 0
        public var obsolete = 0
        public var mergedFields: Int?
        public var historicalLinkFieldsForReview: Int?
        /// Sources Notion could not be read from; their previous snapshots are kept.
        public var readFailures: [String: String] = [:]
        public init() {}
        public var completionSummary: String {
            let changed = sent.count + received.count
            let hasErrors = !failed.isEmpty || !readFailures.isEmpty
            var text = hasErrors ? "Sync finished with issues: \(sent.count) sent, \(received.count) received."
                : changed == 0 ? "Check complete. No changes applied." : "Sync complete: \(sent.count) sent, \(received.count) received."
            if let mergedFields, mergedFields > 0 { text += " \(mergedFields) \(mergedFields == 1 ? "field" : "fields") merged." }
            if let historicalLinkFieldsForReview, historicalLinkFieldsForReview > 0 { text += " \(historicalLinkFieldsForReview) historical link fields still need review." }
            if !failed.isEmpty { text += " \(failed.count) \(failed.count == 1 ? "record" : "records") failed." }
            if !readFailures.isEmpty { text += " \(readFailures.count) \(readFailures.count == 1 ? "source" : "sources") could not be checked." }
            if attention > 0 { text += " \(attention) records still need review." }
            return text
        }
    }

    public struct Progress: Sendable {
        public enum Phase: Sendable { case checking, applying, receiving, sending, merging }
        public let phase: Phase
        public let completed: Int
        public let total: Int
        public var message: String {
            switch phase {
            case .checking: return "Checking Notion for changes…"
            case .applying: return completed == total && total > 0 ? "Finishing sync…" : "Preparing \(total) records…"
            case .receiving: return "Receiving changes… \(completed) of \(total) records finished"
            case .sending: return "Sending changes… \(completed) of \(total) records finished"
            case .merging: return "Merging values… \(completed) of \(total) records finished"
            }
        }
    }
    public typealias ProgressHandler = @Sendable (Progress) async -> Void
    public static let lastMergesKey = "syncLastMergesReport"
    public static let lastChangesKey = "syncLastChangesReport"
    public static let actionReportKey = "syncActionReport"
    public static let failuresKey = "autoSyncFailures"
    public static let reportKey = "autoSyncReport"
    public static let deferredKey = "syncDeferred"

    private let store: ProjectGraphStore
    private let client: NotionClient
    private let fileExists: @Sendable (String) -> Bool
    public init(store: ProjectGraphStore, client: NotionClient,
                fileExists: @escaping @Sendable (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) {
        self.store = store; self.client = client; self.fileExists = fileExists
    }

    /// Records with a difference, sorted into buckets; what a Sync Center shows.
    public func triage() throws -> [ProjectSyncTriage.Item] {
        ProjectSyncTriage.items(records: try store.records(), sources: try store.read("sources", as: [ProjectGraphSource].self) ?? [],
                                fileExists: fileExists)
    }

    public func run(seeds: [ProjectEntityKind: String], disabled: Set<ProjectEntityKind> = [], now: Date = Date(), progress: ProgressHandler? = nil) async throws -> Report {
        try Task.checkCancellation()
        await progress?(.init(phase: .checking, completed: 0, total: 0))
        let readFailures = try await NotionProjectSync(store: store, client: client).check(seeds: seeds, disabled: disabled).failures
        let deferred = try store.read(Self.deferredKey, as: [String: String].self) ?? [:]
        let failures = try store.read(Self.failuresKey, as: [String: ProjectAutoSyncPlanner.Failure].self) ?? [:]
        let plan = ProjectAutoSyncPlanner.plan(try triage(), deferred: deferred, failures: failures, now: now)
        var report = try await apply(plan.pull + plan.push, now: now, progress: progress)
        report.readFailures = readFailures
        report.attention = plan.attention.count; report.waiting = plan.waiting.count
        report.deferred = plan.deferred.count; report.obsolete = plan.obsolete.count
        try store.write(Self.reportKey, report)
        return report
    }

    /// Applies items with per-field `choices` (on top of settling equal spellings): each
    /// is sent if anything of this Mac's remains to go out, otherwise received. Used by
    /// automatic passes and by a person acting in the Sync Center alike.
    public func apply(_ items: [ProjectSyncTriage.Item], choices: [String: [String: ProjectSyncTriage.Side]] = [:],
                      mergesOnly: Bool = false, serviceAcknowledgements: Set<String> = [], now: Date = Date(), progress: ProgressHandler? = nil) async throws -> Report {
        try Task.checkCancellation()
        let sync = NotionProjectSync(store: store, client: client)
        var report = Report()
        var failures = try store.read(Self.failuresKey, as: [String: ProjectAutoSyncPlanner.Failure].self) ?? [:]
        func failed(_ id: String, _ error: Error) {
            let attempts = (failures[id]?.attempts ?? 0) + 1
            failures[id] = .init(attempts: attempts, nextAttempt: now.addingTimeInterval(ProjectAutoSyncPlanner.backoff(attempts: attempts)),
                                 message: error.localizedDescription)
            report.failed[id] = error.localizedDescription
        }
        func publish(_ phase: Progress.Phase) async {
            await progress?(.init(phase: phase, completed: report.sent.count + report.received.count + report.failed.count, total: items.count))
        }
        await publish(mergesOnly ? .merging : .applying)
        var receive: [ProjectGraphRecord] = [], send: [ProjectGraphRecord] = []
        var mergedByRecord: [String: Int] = [:]
        for item in items {
            try Task.checkCancellation()
            guard try store.record(id: item.id) == item.record else {
                failed(item.id, NotionProjectSync.SyncError.stale); continue
            }
            let chosen = mergesOnly ? ProjectSyncTriage.mergeChoices(item)
                : ProjectAutoSyncPlanner.localChoices(item).merging(choices[item.id] ?? [:]) { _, person in person }
            if mergesOnly && chosen.isEmpty { continue }
            mergedByRecord[item.id] = chosen.values.filter { $0 == .merge }.count
            if !chosen.isEmpty, try !store.resolve(item.id, choices: chosen, expected: item.record) {
                failed(item.id, NotionProjectSync.SyncError.stale); continue
            }
            guard var current = try store.record(id: item.id) else { continue }
            if serviceAcknowledgements.contains(item.id) {
                current.serviceAcknowledgementPending = true
                try store.save(current)
            }
            if mergesOnly {
                do {
                    try await sync.push(ids: [current.id], reviewed: [current], fields: [current.id: Set(chosen.keys)])
                    if current.changes.contains(where: { chosen[$0.id] != nil && $0.state == .outgoing }) {
                        report.sent.append(current.id)
                    } else { report.received.append(current.id) }
                } catch is CancellationError { throw CancellationError() }
                catch { failed(current.id, error) }
                await publish(.merging)
                continue
            }
            let sends = current.pageID == nil || current.archiveRequested || !(current.pendingUploads ?? []).isEmpty
                || current.changes.contains { $0.state == .outgoing }
            if sends { send.append(current) } else { receive.append(current) }
        }

        // Receive in batches (a large batch reads whole sources once), falling back to
        // one record at a time so one stale record cannot hold up the rest.
        for chunk in stride(from: 0, to: receive.count, by: 500).map({ Array(receive[$0..<min($0 + 500, receive.count)]) }) {
            await publish(.receiving)
            do {
                try await sync.pull(ids: Set(chunk.map(\.id)), reviewed: chunk)
                report.received += chunk.map(\.id)
            } catch is CancellationError { throw CancellationError() }
            catch {
                for record in chunk {
                    try Task.checkCancellation()
                    do { try await sync.pull(ids: [record.id], reviewed: [record]); report.received.append(record.id) }
                    catch is CancellationError { throw CancellationError() }
                    catch { failed(record.id, error) }
                }
            }
        }

        // Send new pages first, so relationships between new records can be attached.
        send.sort { ($0.pageID == nil ? 0 : 1) < ($1.pageID == nil ? 0 : 1) }
        if !send.isEmpty {
            await publish(.sending)
            do {
                try await sync.push(ids: Set(send.map(\.id)), reviewed: send)
                report.sent += send.map(\.id)
            } catch is CancellationError { throw CancellationError() }
            catch {
                for record in send {
                    try Task.checkCancellation()
                    guard let current = try store.record(id: record.id) else { continue }
                    if current.ambiguousCreate { failed(current.id, NotionProjectSync.SyncError.ambiguous(current.title)); continue }
                    // A fresh read may have turned a reviewed outgoing field into a
                    // conflict. It is not an acknowledged send and cannot be retried.
                    if current.changes.contains(where: { $0.state == .conflict }) {
                        failed(current.id, NotionProjectSync.SyncError.stale); continue
                    }
                    guard current.pageID == nil || current.archiveRequested || current.changes.contains(where: { $0.state == .outgoing })
                            || current.pendingUploads?.isEmpty == false else { report.sent.append(current.id); continue }
                    do { try await sync.push(ids: [current.id], reviewed: [record]); report.sent.append(current.id) }
                    catch is CancellationError { throw CancellationError() }
                    catch { failed(current.id, error) }
                }
            }
        }
        for id in report.received + report.sent { failures.removeValue(forKey: id) }
        try store.write(Self.failuresKey, failures)
        report.finishedAt = Date()
        report.mergedFields = (report.sent + report.received).reduce(0) { $0 + (mergedByRecord[$1] ?? 0) }
        report.attention = ProjectAutoSyncPlanner.plan(try triage(), deferred: [:], failures: failures).attention.count
        try store.write(Self.actionReportKey, report)
        if !(report.sent + report.received).isEmpty { try store.write(Self.lastChangesKey, report) }
        if (report.mergedFields ?? 0) > 0 { try store.write(Self.lastMergesKey, report) }
        await publish(mergesOnly ? .merging : .applying)
        return report
    }
}

extension ProjectGraphStore {
    /// Keeps a difference out of automatic sync until it changes again.
    public func deferDifference(_ item: ProjectSyncTriage.Item) throws {
        var deferred = try read(ProjectAutoSync.deferredKey, as: [String: String].self) ?? [:]
        deferred[item.id] = item.fingerprint
        try write(ProjectAutoSync.deferredKey, deferred)
    }
    public func undeferDifference(_ id: String) throws {
        var deferred = try read(ProjectAutoSync.deferredKey, as: [String: String].self) ?? [:]
        deferred.removeValue(forKey: id)
        try write(ProjectAutoSync.deferredKey, deferred)
    }
}
