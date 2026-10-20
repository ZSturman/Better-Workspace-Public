import Foundation

/// Analytics consumes the same filtered records as the table. It never infers effort
/// from commits, directory mtimes, normalized scores, or a missing observation.
public enum ProjectAnalytics {
    /// Untruncated totals for the same filtered scope as the chart rankings.
    public struct Summary: Sendable, Equatable {
        public let projectCount: Int
        public let openWork: Double?
        public let workCoverage: Int
        public let reviewCount: Int
        public let observedHours: Double?
        public let observationCoverage: Int
    }

    public static func summary(_ records: [ProjectQueryRecord], days: Int = 30, activeOnly: Bool = true) -> Summary {
        var seen = Set<String>()
        let scoped = records.filter { seen.insert($0.id).inserted && (!activeOnly || !ProjectMetadata(status: $0.value("status")).isTerminal) }
        func measurements(_ key: String) -> [Double] {
            scoped.compactMap { row in
                guard let value = row.values[key].flatMap(Double.init), value.isFinite, value >= 0 else { return nil }
                return value
            }
        }
        let work = measurements("openWork"), hours = measurements("hours\(days)")
        let reviewIDs = Set([Metric.stalled, .valueIdle].flatMap {
            bars(scoped, metric: $0, days: days, limit: scoped.count, activeOnly: false).map(\.id)
        })
        return Summary(projectCount: scoped.count, openWork: work.isEmpty ? nil : work.reduce(0, +),
                       workCoverage: work.count, reviewCount: reviewIDs.count,
                       observedHours: hours.isEmpty ? nil : hours.reduce(0, +), observationCoverage: hours.count)
    }

    public enum Metric: String, Codable, CaseIterable, Sendable {
        case backlog, nearDone, stalled, valueIdle, attention, domains, idle
        public static let defaultOrder: [Metric] = [.backlog, .nearDone, .stalled, .valueIdle, .attention, .domains]
        public var unit: String {
            switch self {
            case .backlog, .stalled: return "open records"
            case .nearDone: return "% complete"
            case .valueIdle: return "score"
            case .attention, .domains: return "hours"
            case .idle: return "days"
            }
        }
        /// Where the numbers come from, shown beside every chart title.
        public var evidence: String {
            switch self {
            case .backlog, .nearDone: return "Recorded work items"
            case .stalled: return "Recorded work · observed activity"
            case .valueIdle: return "Your ratings · observed activity"
            case .attention, .domains: return "Observed work log"
            case .idle: return "Observed activity"
            }
        }
        public var title: String {
            switch self {
            case .backlog: return "Outstanding work"
            case .nearDone: return "Closest to done"
            case .valueIdle: return "High value, not recently worked on"
            case .idle: return "Longest since observed work"
            case .stalled: return "Unfinished and inactive"
            case .attention: return "Recent attention"
            case .domains: return "Time by domain"
            }
        }
        public var explanation: String {
            switch self {
            case .backlog: return "Open recorded tasks, features and milestones. Counts describe scope, not equal units of effort. Parent and child records can both be counted."
            case .idle: return "Days since the service last observed work. For a project with no observed session, the days since sensing began for it (a lower bound, shown as ≥). File modification dates and bulk automated runs across many projects are not work sessions."
            case .nearDone: return "Share of recorded tasks, features and milestones already completed, for projects with both open and completed records. Only recorded work counts; it is not an estimate of remaining effort."
            case .valueIdle: return "Projects with a Project Score of 60 or more and no observed work within the selected period, highest score first. For a project never observed, the days since sensing began for it count as a lower bound; a project the service cannot account for is left out."
            case .stalled: return "Projects with at least five unfinished work records and no observed work within the selected period, ranked by unfinished count. For projects never observed, the age is a lower bound since sensing began (shown as ≥). A prompt to review scope, not a diagnosis."
            case .attention: return "Active hours in the selected period from the existing work log, including reconstructed sessions. Observation coverage varies; no record is not evidence of no work."
            case .domains: return "Recorded active hours summed by domain across the matching projects. Click a domain to show its projects. Unmeasured projects contribute no time; totals are not a complete timesheet."
            }
        }
    }
    public struct Bar: Identifiable, Sendable, Equatable {
        public var id: String
        public var title: String
        public var value: Double
        public var note: String?
        public var isLowerBound: Bool
        public init(id: String, title: String, value: Double, note: String? = nil, isLowerBound: Bool = false) {
            self.id = id; self.title = title; self.value = value; self.note = note; self.isLowerBound = isLowerBound
        }
    }
    public static func bars(_ records: [ProjectQueryRecord], metric: Metric, days: Int = 30, limit: Int = 10, activeOnly: Bool = true, ascending: Bool = false) -> [Bar] {
        let records = records.filter { !activeOnly || !ProjectMetadata(status: $0.value("status")).isTerminal }
        func number(_ row: ProjectQueryRecord, _ key: String) -> Double? {
            guard let value = row.values[key].flatMap(Double.init), value.isFinite, value >= 0 else { return nil }
            return value
        }
        var bars: [Bar]
        if metric == .domains {
            var totals: [String: Double] = [:]
            for row in records {
                guard let hours = number(row, "hours\(days)"), hours > 0 else { continue }
                let domain = row.value("domain").isEmpty ? "Not set" : row.value("domain")
                totals[domain, default: 0] += hours
            }
            bars = totals.map { .init(id: $0.key, title: $0.key, value: $0.value) }
        } else {
            bars = records.compactMap { row in
                let value: Double?
                switch metric {
                case .backlog: value = number(row, "openWork")
                case .idle: value = number(row, "sort:lastWorked")
                case .nearDone:
                    guard let open = number(row, "openWork"), open > 0, let done = number(row, "completedWork"), done > 0 else { return nil }
                    value = (done / (open + done) * 100).rounded()
                case .valueIdle:
                    guard let score = number(row, "score"), score >= 60, let age = number(row, "sort:lastWorked"), age >= Double(days) else { return nil }
                    value = score
                case .stalled:
                    guard let age = number(row, "sort:lastWorked"), age >= Double(days), let open = number(row, "openWork"), open >= 5 else { return nil }
                    value = open
                case .attention: value = number(row, "hours\(days)")
                case .domains: value = nil
                }
                guard let value, value > 0 else { return nil }
                let note: String?
                switch metric {
                case .nearDone: note = "\(row.value("completedWork")) completed · \(row.value("openWork")) open"
                case .valueIdle, .stalled:
                    let bound = row.values["bound:lastWorked"] == "lower"
                    note = number(row, "sort:lastWorked").map { bound ? "no observed work for at least \(Int($0)) days" : "last observed \(Int($0)) days ago" }
                case .idle: note = row.values["help:lastWorked"]
                default: note = nil
                }
                return Bar(id: row.id, title: row.name, value: value, note: note,
                           isLowerBound: metric == .idle && row.values["bound:lastWorked"] == "lower")
            }
        }
        return Array(bars.sorted {
            if $0.value != $1.value { return ascending ? $0.value < $1.value : $0.value > $1.value }
            return $0.title == $1.title ? $0.id < $1.id : $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }.prefix(max(0, limit)))
    }
}
