import Foundation

/// What automatic Notion passes keep finding, kept small and private in the graph state.
///
/// It notices the things that built the October backlogs: a review queue that only grows,
/// records that are moved again on every pass (a feedback loop), differences that keep
/// changing while they wait for a person, and passes that stop succeeding. It never moves
/// anything and never blocks a pass; it explains. See docs/SYNC_BACKLOG_2026-10-27.md.
public struct ProjectSyncHealth: Codable, Sendable, Equatable {
    public static let key = "syncHealth"

    public struct Sample: Codable, Sendable, Equatable {
        public var at: Date
        /// Records waiting for a person.
        public var attention: Int
        /// Records that move without a decision (send, receive, settle, or one Receive action).
        public var routine: Int
        /// Records backing off after a failure.
        public var waiting: Int
        public var failed: Int
        public var readFailures: Int
        public var moved: Int
    }

    public enum Finding: Equatable, Sendable {
        /// The review queue grew by this much within a day.
        case growing(from: Int, to: Int)
        /// Automatic passes have not completed cleanly since this time.
        case stalled(since: Date)
        /// Records failed in this many consecutive passes.
        case failing(passes: Int)
        /// Notion sources could not be read in this many consecutive passes.
        case unreadable(passes: Int)
        /// Records sent or received in three or more consecutive passes.
        case loop(records: Int)
        /// Waiting records whose difference changed three or more times while waiting.
        case recurring(records: Int)

        public var message: String {
            switch self {
            case .growing(let from, let to): return "Records needing review grew from \(from) to \(to) in a day."
            case .stalled(let since): return "Automatic sync has not finished cleanly since \(since.formatted(date: .abbreviated, time: .shortened))."
            case .failing(let passes): return "Some records have failed in the last \(passes) passes; each retries with backoff."
            case .unreadable(let passes): return "Notion could not be read in the last \(passes) passes; previous values are kept."
            case .loop(let records): return "\(records) \(records == 1 ? "record was" : "records were") synced again on every recent pass; something keeps changing \(records == 1 ? "it" : "them")."
            case .recurring(let records): return "\(records) \(records == 1 ? "record keeps" : "records keep") changing while waiting for review."
            }
        }
    }

    /// A day of five-minute passes; older samples are dropped.
    public static let sampleLimit = 288
    public static let growthWindow: TimeInterval = 86_400
    /// Twelve missed five-minute passes.
    public static let stallAfter: TimeInterval = 3_600
    public static let consecutiveThreshold = 3

    public var samples: [Sample] = []
    public var lastSuccess: Date?
    /// Consecutive passes in which each record was sent or received.
    public var consecutiveMoves: [String: Int] = [:]
    /// For records waiting for a person: the last fingerprint and how often it changed.
    public var waitingFingerprints: [String: String] = [:]
    public var waitingChanges: [String: Int] = [:]

    public init() {}

    /// `plan` is what remained after the pass; `settled` the records it settled here, which
    /// count as moved: a record settled on every pass is a loop too.
    public mutating func record(_ plan: ProjectAutoSyncPlanner.Plan, report: ProjectAutoSync.Report, settled: Set<String> = [], at now: Date) {
        let moved = Set(report.sent + report.received).union(settled)
        samples.append(.init(at: now, attention: plan.attention.count,
                             routine: plan.push.count + plan.pull.count + plan.settle.count + plan.receivable.count,
                             waiting: plan.waiting.count, failed: report.failed.count, readFailures: report.readFailures.count, moved: moved.count))
        samples.removeAll { now.timeIntervalSince($0.at) > Self.growthWindow }
        if samples.count > Self.sampleLimit { samples.removeFirst(samples.count - Self.sampleLimit) }
        if report.failed.isEmpty && report.readFailures.isEmpty { lastSuccess = now }
        consecutiveMoves = Dictionary(uniqueKeysWithValues: moved.map { ($0, (consecutiveMoves[$0] ?? 0) + 1) })
        var fingerprints: [String: String] = [:], changes: [String: Int] = [:]
        for item in plan.attention {
            fingerprints[item.id] = item.fingerprint
            let previous = waitingFingerprints[item.id]
            changes[item.id] = (waitingChanges[item.id] ?? 0) + (previous != nil && previous != item.fingerprint ? 1 : 0)
        }
        waitingFingerprints = fingerprints; waitingChanges = changes
    }

    public func findings(now: Date = Date(), automatic: Bool) -> [Finding] {
        var found: [Finding] = []
        if let latest = samples.last {
            let window = samples.filter { now.timeIntervalSince($0.at) <= Self.growthWindow }
            if let low = window.map(\.attention).min(), latest.attention - low >= 20, Double(latest.attention) >= Double(max(low, 1)) * 1.5 {
                found.append(.growing(from: low, to: latest.attention))
            }
        }
        // Measured between passes that ran, so sleep, a quit app or a spell in manual
        // mode is not mistaken for passes failing.
        if automatic, let first = samples.first, let latest = samples.last {
            let since = lastSuccess ?? first.at
            if latest.at.timeIntervalSince(since) > Self.stallAfter { found.append(.stalled(since: since)) }
        }
        func trailing(_ test: (Sample) -> Bool) -> Int { samples.reversed().prefix { test($0) }.count }
        let failing = trailing { $0.failed > 0 }, unreadable = trailing { $0.readFailures > 0 }
        if failing >= Self.consecutiveThreshold { found.append(.failing(passes: failing)) }
        if unreadable >= Self.consecutiveThreshold { found.append(.unreadable(passes: unreadable)) }
        let looping = consecutiveMoves.values.filter { $0 >= Self.consecutiveThreshold }.count
        if looping > 0 { found.append(.loop(records: looping)) }
        let recurring = waitingChanges.values.filter { $0 >= Self.consecutiveThreshold }.count
        if recurring > 0 { found.append(.recurring(records: recurring)) }
        return found
    }
}
