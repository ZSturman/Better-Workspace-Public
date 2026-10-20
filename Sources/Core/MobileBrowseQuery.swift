import Foundation

public enum MobileBrowseGroup: String, CaseIterable, Identifiable, Codable {
    case none, potential, domain, status, phase
    public var id: String { rawValue }
    public var title: String { self == .none ? "None" : rawValue.capitalized }
}
public enum MobileBrowseSort: String, CaseIterable, Identifiable, Codable {
    case recommended, score, dateAdded, modified, name
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .recommended: "Recommended"
        case .score: "Score"
        case .dateAdded: "Date added"
        case .modified: "Last updated"
        case .name: "Name"
        }
    }
}
public struct MobileBrowseSection<Item: Identifiable>: Identifiable {
    public let title: String
    public var items: [Item]
    public var id: String { title }
}

/// Independent grouping and sorting. Missing scores/dates remain last in both directions.
public struct MobileBrowseQuery: Codable, Equatable {
    public var group: MobileBrowseGroup = .none
    public var sort: MobileBrowseSort = .recommended
    public var ascending = false
    public var search = ""
    public var domain = ""
    public var potential = ""
    public var status = ""
    public var phase = ""
    public init() {}

    public func ideas(_ values: [MobileIdea]) -> [MobileBrowseSection<MobileIdea>] {
        let filtered = values.filter { idea in
            let metadata = idea.planning?.project?.metadata
            return (search.isEmpty || [idea.title, idea.description ?? ""].contains { $0.localizedCaseInsensitiveContains(search) })
                && (domain.isEmpty || metadata?.domain == domain)
                && (potential.isEmpty || (idea.planning?.potential?.rawValue ?? "unclassified") == potential)
                && (status.isEmpty || metadata?.status == status) && (phase.isEmpty || metadata?.phase == phase)
        }.sorted { lhs, rhs in
            if sort == .recommended { return IdeaRanking.comesFirst(lhs, rhs) }
            return compare(lhs, rhs, name: { $0.title }, number: { $0.planning?.score(preferences: $0.scoringPreferences ?? .init()).projectScore },
                date: { sort == .dateAdded ? $0.createdAt : $0.modifiedAt })
        }
        return sections(filtered) { idea in
            switch group {
            case .none: ""
            case .potential: idea.planning?.potential?.title ?? "Unclassified"
            case .domain: idea.planning?.project?.metadata.domain ?? "No domain"
            case .status: idea.planning?.project?.metadata.status ?? "No status"
            case .phase: idea.planning?.project?.metadata.phase ?? "No phase"
            }
        }
    }
    public func projects(_ values: [MobileWorkspaceEntry]) -> [MobileBrowseSection<MobileWorkspaceEntry>] {
        let filtered = values.filter { entry in
            let details = entry.projectDetails
            return entry.isDirectory && (search.isEmpty || entry.name.localizedCaseInsensitiveContains(search))
                && (domain.isEmpty || details?.domain == domain) && (status.isEmpty || details?.status == status)
                && (phase.isEmpty || details?.phase == phase)
        }.sorted { lhs, rhs in
            compare(lhs, rhs, name: { $0.name }, number: { $0.projectDetails?.rankingScore },
                date: { sort == .dateAdded ? $0.projectDetails?.createdAt : $0.modifiedAt })
        }
        return sections(filtered) { entry in
            switch group {
            case .domain: entry.projectDetails?.domain ?? "No domain"
            case .status: entry.projectDetails?.status ?? "No status"
            case .phase: entry.projectDetails?.phase ?? "No phase"
            default: ""
            }
        }
    }
    private func sections<Item: Identifiable>(_ items: [Item], key: (Item) -> String) -> [MobileBrowseSection<Item>] {
        let grouped = Dictionary(grouping: items, by: key)
        return grouped.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }.map { .init(title: $0, items: grouped[$0]!) }
    }
    private func compare<Item>(_ lhs: Item, _ rhs: Item, name: (Item) -> String, number: (Item) -> Double?, date: (Item) -> Date?) -> Bool where Item: Identifiable, Item.ID == String {
        if sort == .name {
            let comparison = name(lhs).localizedStandardCompare(name(rhs))
            if comparison != .orderedSame { return ascending ? comparison == .orderedAscending : comparison == .orderedDescending }
        } else {
            let left = sort == .score || sort == .recommended ? number(lhs) : date(lhs)?.timeIntervalSince1970
            let right = sort == .score || sort == .recommended ? number(rhs) : date(rhs)?.timeIntervalSince1970
            if left != right {
                guard let left else { return false }; guard let right else { return true }
                return ascending ? left < right : left > right
            }
        }
        let comparison = name(lhs).localizedStandardCompare(name(rhs))
        return comparison == .orderedSame ? lhs.id < rhs.id : comparison == .orderedAscending
    }
}
