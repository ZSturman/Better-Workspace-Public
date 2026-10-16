import Foundation

/// Pure query semantics shared by every Projects presentation. Values in one rule
/// are alternatives; independent rules can be joined with all/any. Search always narrows.
public struct ProjectPropertyFilter: Codable, Hashable, Sendable, Identifiable {
    public enum Operation: String, Codable, CaseIterable, Sendable {
        case includesAny, includesAll, excludes
        public var title: String { self == .includesAny ? "Includes any" : self == .includesAll ? "Includes all" : "Excludes" }
    }
    public var field: String
    public var operation: Operation
    public var values: Set<String>
    public var id: String { field }
    public init(field: String, operation: Operation = .includesAny, values: Set<String> = []) {
        self.field = field; self.operation = operation; self.values = values
    }
    public func matches(_ actual: [String]) -> Bool {
        guard !values.isEmpty else { return true }
        let selected = Set(values.map(ProjectViewQuery.normalize)), actual = Set(actual.map(ProjectViewQuery.normalize))
        switch operation {
        case .includesAny: return !selected.isDisjoint(with: actual)
        case .includesAll: return selected.isSubset(of: actual)
        case .excludes: return selected.isDisjoint(with: actual)
        }
    }
}

public struct ProjectSortRule: Codable, Hashable, Sendable {
    public var field: String
    public var ascending: Bool
    public init(field: String, ascending: Bool = true) { self.field = field; self.ascending = ascending }
}

public struct ProjectQueryRecord: Sendable {
    public var id: String
    public var name: String
    public var values: [String: String]
    public var selections: [String: [String]]
    public init(id: String, name: String, values: [String: String], selections: [String: [String]] = [:]) {
        self.id = id; self.name = name; self.values = values; self.selections = selections
    }
    public func value(_ field: String) -> String { field == "name" ? name : values[field, default: ""] }
    public func selected(_ field: String) -> [String] {
        if let values = selections[field] { return values.isEmpty ? ["Not set"] : values }
        let value = value(field)
        return value.isEmpty ? ["Not set"] : [value]
    }
}

public enum ProjectActivityFilter: String, Codable, CaseIterable, Sendable {
    case all, recent, stale, unfinished, stalled
    public var title: String {
        switch self {
        case .all: return "Any activity"
        case .recent: return "Observed in last 7 days"
        case .stale: return "No observed work for 30+ days"
        case .unfinished: return "Has unfinished work"
        case .stalled: return "30+ days idle with 5+ open items"
        }
    }
    public func matches(_ row: ProjectQueryRecord) -> Bool {
        let age = row.values["sort:lastWorked"].flatMap(Double.init)
        // "At least N days" (no session since sensing began) can show inactivity, never recency.
        let lowerBound = row.values["bound:lastWorked"] == "lower"
        let open = row.values["openWork"].flatMap(Int.init)
        switch self {
        case .all: return true
        case .recent: return !lowerBound && (age.map { $0 >= 0 && $0 <= 7 } ?? false)
        case .stale: return age.map { $0 >= 30 } ?? false
        case .unfinished: return open.map { $0 > 0 } ?? false
        case .stalled: return (age.map { $0 >= 30 } ?? false) && (open.map { $0 >= 5 } ?? false)
        }
    }
}

public enum ProjectViewQuery {
    public static func normalize(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }
    public static func matches(_ row: ProjectQueryRecord, query: String, filters: [ProjectPropertyFilter], matchAny: Bool = false, activity: ProjectActivityFilter = .all) -> Bool {
        let filters = filters.filter { !$0.values.isEmpty }
        let propertiesMatch = filters.isEmpty || (matchAny ? filters.contains { $0.matches(row.selected($0.field)) } : filters.allSatisfy { $0.matches(row.selected($0.field)) })
        guard propertiesMatch, activity.matches(row) else { return false }
        let terms = normalize(query).split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !terms.isEmpty else { return true }
        let searchable = normalize(([row.name] + row.values.filter { !$0.key.hasPrefix("sort:") && !$0.key.hasPrefix("help:") && !$0.key.hasPrefix("can") && !$0.key.hasPrefix("provisional:") }.map(\.value)).joined(separator: " "))
        return terms.allSatisfy { searchable.contains($0) }
    }
    public static func orderedBefore(_ lhs: ProjectQueryRecord, _ rhs: ProjectQueryRecord, sorts: [ProjectSortRule]) -> Bool {
        for sort in sorts {
            let a = lhs.values["sort:" + sort.field] ?? lhs.value(sort.field)
            let b = rhs.values["sort:" + sort.field] ?? rhs.value(sort.field)
            // Missing observations always sort last, in either direction.
            if a.isEmpty != b.isEmpty { return !a.isEmpty }
            if let x = Double(a.replacingOccurrences(of: "%", with: "")), let y = Double(b.replacingOccurrences(of: "%", with: "")), x.isFinite, y.isFinite, x != y { return sort.ascending ? x < y : x > y }
            let comparison = a.localizedStandardCompare(b)
            if comparison != .orderedSame { return sort.ascending ? comparison == .orderedAscending : comparison == .orderedDescending }
        }
        let comparison = lhs.name.localizedStandardCompare(rhs.name)
        return comparison == .orderedSame ? lhs.id < rhs.id : comparison == .orderedAscending
    }
}
