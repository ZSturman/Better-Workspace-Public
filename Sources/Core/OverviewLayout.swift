import Foundation

public enum OverviewSectionID: String, Codable, CaseIterable, Identifiable, Sendable {
    case resume, nextAction, attention, focus, review, projects, ideas, activity, health, pending
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .resume: "Pick up where you left off"
        case .nextAction: "Next up"
        case .attention: "Needs attention"
        case .focus: "Bring forward"
        case .review: "One thing to review"
        case .projects: "Projects"
        case .ideas: "Ideas"
        case .activity: "Recent activity"
        case .health: "Service health"
        case .pending: "Waiting changes"
        }
    }
}

public struct OverviewLayout: Codable, Equatable, Sendable {
    public var order: [OverviewSectionID]
    public var hidden: Set<OverviewSectionID>
    public init(order: [OverviewSectionID] = OverviewSectionID.allCases, hidden: Set<OverviewSectionID> = []) {
        // Ignore duplicate/stale preferences and append newly introduced sections.
        var seen = Set<OverviewSectionID>()
        self.order = (order + OverviewSectionID.allCases).filter { seen.insert($0).inserted }
        self.hidden = hidden
    }
    public static let simple = OverviewLayout(hidden: [.resume, .focus, .projects, .ideas, .activity, .health])
    public func visible(in supported: [OverviewSectionID]) -> [OverviewSectionID] {
        order.filter { supported.contains($0) && !hidden.contains($0) }
    }
    public static func load(_ value: String, defaultOrder: [OverviewSectionID] = OverviewSectionID.allCases) -> OverviewLayout {
        guard let decoded = try? JSONDecoder().decode(OverviewLayout.self, from: Data(value.utf8)) else { return OverviewLayout(order: defaultOrder) }
        return OverviewLayout(order: decoded.order, hidden: decoded.hidden)
    }
    public var encoded: String { String(decoding: (try? JSONEncoder().encode(self)) ?? Data(), as: UTF8.self) }
}
