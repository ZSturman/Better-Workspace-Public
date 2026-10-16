import Foundation

/// Open work by stage plus completed work: the numbers behind the progress strip shown
/// wherever work is listed. Built from Mac records or phone projections alike.
public struct WorkProgressCounts: Equatable, Sendable {
    public var now = 0, next = 0, later = 0, completed = 0
    public var open: Int { now + next + later }
    public var total: Int { open + completed }
    /// Completed share, 0…1; zero when there is no work at all.
    public var fractionDone: Double { total == 0 ? 0 : Double(completed) / Double(total) }

    public init(now: Int = 0, next: Int = 0, later: Int = 0, completed: Int = 0) {
        self.now = now; self.next = next; self.later = later; self.completed = completed
    }

    public init(_ items: some Sequence<(status: WorkItemStatus, stage: WorkItemStage)>) {
        for item in items {
            if item.status == .completed { completed += 1; continue }
            switch item.stage {
            case .now: now += 1
            case .next: next += 1
            case .later: later += 1
            }
        }
    }

    public init(_ items: [MobileWorkItem]) { self.init(items.lazy.map { (status: $0.status, stage: $0.stage) }) }
    public init(_ items: [WorkItem]) { self.init(items.lazy.map { (status: $0.status, stage: $0.stage) }) }
}

/// How many dates fall in each of the last `weeks` calendar weeks, oldest first. Dates
/// outside the window are ignored; a week with nothing is still present, as zero.
public struct WeeklyCounts: Equatable, Sendable {
    public struct Week: Equatable, Sendable, Identifiable {
        public let start: Date
        public let count: Int
        public var id: Date { start }
    }
    public let weeks: [Week]
    public var total: Int { weeks.reduce(0) { $0 + $1.count } }

    public init(dates: [Date], weeks count: Int = 8, now: Date = Date(), calendar: Calendar = .current) {
        guard count > 0, let current = calendar.dateInterval(of: .weekOfYear, for: now)?.start else { weeks = []; return }
        let starts = (0..<count).reversed().compactMap { calendar.date(byAdding: .weekOfYear, value: -$0, to: current) }
        var tally = Dictionary(uniqueKeysWithValues: starts.map { ($0, 0) })
        for date in dates {
            guard let start = calendar.dateInterval(of: .weekOfYear, for: date)?.start, tally[start] != nil else { continue }
            tally[start, default: 0] += 1
        }
        weeks = starts.map { Week(start: $0, count: tally[$0] ?? 0) }
    }
}
