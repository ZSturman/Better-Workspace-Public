import Foundation

public enum OverviewFocus: String, CaseIterable, Identifiable, Codable, Sendable {
    case almostDone, highestRated, revisit
    public var id: String { rawValue }
    public var title: String {
        switch self { case .almostDone: return "Almost done"; case .highestRated: return "Highest rated"; case .revisit: return "Needs a revisit" }
    }
}

public enum OverviewContent: String, CaseIterable, Identifiable, Codable, Sendable {
    case projects, ideas, features, milestones
    public var id: String { rawValue }
    public var title: String { rawValue.capitalized }
}

/// Evidence gathered from already-loaded records. Views never read files to rank.
public struct OverviewFocusItem: Identifiable, Hashable, Codable, Sendable {
    public var id: String
    public var path: String
    public var title: String
    public var kind: OverviewContent
    public var score: Double?
    public var completed: Int
    public var total: Int
    public var lastWorked: Date?
    public var lastChanged: Date?
    public var terminal: Bool
    public var blocked: Bool
    public init(id: String, path: String, title: String, kind: OverviewContent, score: Double? = nil,
                completed: Int = 0, total: Int = 0, lastWorked: Date? = nil, lastChanged: Date? = nil,
                terminal: Bool = false, blocked: Bool = false) {
        self.id = id; self.path = path; self.title = title; self.kind = kind; self.score = score
        self.completed = completed; self.total = total; self.lastWorked = lastWorked; self.lastChanged = lastChanged
        self.terminal = terminal; self.blocked = blocked
    }
    /// The revisit track's span; older activity sits at its end.
    public static let revisitHorizonDays: Double = 90
    public var remaining: Int { max(0, total - completed) }
    public var fraction: Double { total > 0 ? Double(completed) / Double(total) : 0 }
    public func reason(_ focus: OverviewFocus, now: Date = Date()) -> String {
        switch focus {
        case .almostDone: return "\(completed) of \(total) linked tasks done · \(remaining) left"
        case .highestRated: return "Your score \(Int((score ?? 0).rounded()))/100"
        case .revisit:
            guard let date = lastWorked ?? lastChanged else { return "Activity unknown" }
            let days = max(0, Int(now.timeIntervalSince(date) / 86_400))
            let what = lastWorked == nil ? "Files changed" : "Worked on"
            switch days {
            case 0: return "\(what) today"
            case 1: return "\(what) yesterday"
            default: return "\(what) \(days) days ago"
            }
        }
    }
}

public enum OverviewRanking {
    public static func items(_ items: [OverviewFocusItem], kind: OverviewContent, focus: OverviewFocus) -> [OverviewFocusItem] {
        items.filter { item in
            guard item.kind == kind, !item.terminal else { return false }
            switch focus {
            case .almostDone: return !item.blocked && item.total > 0 && item.completed > 0 && item.remaining > 0
            case .highestRated: return item.score?.isFinite == true
            case .revisit: return (item.lastWorked ?? item.lastChanged) != nil
            }
        }.sorted { a, b in
            switch focus {
            case .almostDone:
                if a.fraction != b.fraction { return a.fraction > b.fraction }
                if a.remaining != b.remaining { return a.remaining < b.remaining }
            case .highestRated: if a.score != b.score { return (a.score ?? 0) > (b.score ?? 0) }
            case .revisit:
                if a.lastWorked ?? a.lastChanged != b.lastWorked ?? b.lastChanged {
                    return (a.lastWorked ?? a.lastChanged ?? .distantFuture) < (b.lastWorked ?? b.lastChanged ?? .distantFuture)
                }
            }
            return a.title == b.title ? a.id < b.id : a.title.localizedStandardCompare(b.title) == .orderedAscending
        }
    }
}

public struct OverviewInboxItem: Identifiable, Hashable, Codable, Sendable {
    public var id: String
    public var path: String
    public var title: String
    public var category: String
    public var modified: Date
    public var size: Int64
    public var preview: String
    public var link: URL?
    public var fingerprint: String?
    public var priority: Int?
    public init(id: String, path: String, title: String, category: String, modified: Date, size: Int64,
                preview: String = "", link: URL? = nil, fingerprint: String? = nil, priority: Int? = nil) {
        self.id = id; self.path = path; self.title = title; self.category = category
        self.modified = modified; self.size = size; self.preview = preview; self.link = link; self.fingerprint = fingerprint; self.priority = priority
    }
    public var actions: WorkspaceInboxReview.ReviewActions { WorkspaceInboxReview.ReviewActions(category: category) }
    public var decision: String { actions.title }
}

public struct OverviewDigest: Codable, Hashable, Sendable {
    public static let path = "Overview-focus"
    public var focusItems: [OverviewFocusItem]
    public var inboxItem: OverviewInboxItem?
    public var inboxCheckedAt: Date?
    public var reviewItems: [OverviewInboxItem]?
    public var reviewCount: Int?
    public var attention: [WidgetAttentionItem]?
    public var captureReviews: [MobileCaptureReview]?
    public init(focusItems: [OverviewFocusItem] = [], inboxItem: OverviewInboxItem? = nil, inboxCheckedAt: Date? = nil, reviewItems: [OverviewInboxItem]? = nil, reviewCount: Int? = nil, attention: [WidgetAttentionItem]? = nil, captureReviews: [MobileCaptureReview]? = nil) {
        self.focusItems = focusItems; self.inboxItem = inboxItem; self.inboxCheckedAt = inboxCheckedAt
        self.reviewItems = reviewItems.map { Array($0.prefix(8)) }; self.reviewCount = reviewCount; self.attention = attention; self.captureReviews = captureReviews.map { Array($0.prefix(30)) }
    }
    private enum CodingKeys: String, CodingKey { case focusItems, inboxItem, inboxCheckedAt, reviewItems, reviewCount, attention, captureReviews }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(focusItems: try values.decodeIfPresent([OverviewFocusItem].self, forKey: .focusItems) ?? [],
            inboxItem: try values.decodeIfPresent(OverviewInboxItem.self, forKey: .inboxItem),
            inboxCheckedAt: try values.decodeIfPresent(Date.self, forKey: .inboxCheckedAt),
            reviewItems: try values.decodeIfPresent([OverviewInboxItem].self, forKey: .reviewItems),
            reviewCount: try values.decodeIfPresent(Int.self, forKey: .reviewCount),
            attention: try values.decodeIfPresent([WidgetAttentionItem].self, forKey: .attention),
            captureReviews: try values.decodeIfPresent([MobileCaptureReview].self, forKey: .captureReviews))
    }
    public static func decode(_ string: String?) -> OverviewDigest? {
        string.flatMap { $0.data(using: .utf8) }.flatMap { try? JSONDecoder().decode(Self.self, from: $0) }
    }
    /// Sorted keys: the publisher compares encodings to skip unchanged records.
    public var encoded: String? {
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        return (try? encoder.encode(self)).flatMap { String(data: $0, encoding: .utf8) }
    }
}

public struct OverviewInboxCommand: Hashable, Codable, Sendable {
    public enum Action: String, Codable, Sendable { case done, archive, retire, snooze, prioritize }
    public var item: OverviewInboxItem
    public var action: Action
    public var until: Date?
    public var priority: Int?
    public init(item: OverviewInboxItem, action: Action, until: Date? = nil, priority: Int? = nil) { self.item = item; self.action = action; self.until = until; self.priority = priority }
}
