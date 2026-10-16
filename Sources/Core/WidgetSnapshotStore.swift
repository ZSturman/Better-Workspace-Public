import Foundation

/// The two iOS apps intentionally do not share a widget container.  Ingest owns the
/// files it captures, while Better Workspace Mobile owns only its disposable CloudKit
/// projection.  Widgets receive a small, app-specific summary rather than either
/// application's full data store.
public enum WidgetAppGroup {
    public static let ingest = "group.com.zacharysturman.BetterWorkspace.ingest"
    public static let mac = "MF8J7AY2X3.com.zacharysturman.BetterWorkspace.widgets"
    public static let mobile = "group.com.zacharysturman.BetterWorkspace.mobile"
}

/// The `kind` strings WidgetKit uses to match a reload request to a timeline provider.
/// They live here because an app and its extension are separate targets: a literal
/// typed twice drifts silently, and a reload for an unknown kind simply does nothing.
public enum WidgetKind {
    public static let ingestInbox = "IngestInboxWidget"
    public static let nextWork = "NextWorkWidget"
    public static let recentIdeas = "RecentIdeasWidget"
    public static let quickCapture = "QuickCaptureWidget"
    public static let macQuickCapture = "MacQuickCaptureWidget"
}

public struct IngestWidgetCapture: Codable, Equatable, Sendable {
    public let name: String
    public let modifiedAt: Date
    /// Where it is now, in words ("Needs filing", "In For Reference").
    public let status: String?

    public init(name: String, modifiedAt: Date, status: String? = nil) {
        self.name = name
        self.modifiedAt = modifiedAt
        self.status = status
    }
}

public struct IngestWidgetSnapshot: Codable, Equatable, Sendable {
    public enum State: String, Codable, Sendable {
        case ready
        case needsInbox
    }

    public let state: State
    public let inboxCount: Int
    public let newestCapture: IngestWidgetCapture?
    /// Inbox items with no destination yet. Optional: older snapshots lack it.
    public let needsFilingCount: Int?
    public let updatedAt: Date

    public init(state: State, inboxCount: Int, newestCapture: IngestWidgetCapture?,
                needsFilingCount: Int? = nil, updatedAt: Date = Date()) {
        self.state = state
        self.inboxCount = max(0, inboxCount)
        self.newestCapture = newestCapture
        self.needsFilingCount = needsFilingCount.map { max(0, $0) }
        self.updatedAt = updatedAt
    }
}

public struct WorkspaceWidgetWorkItem: Codable, Equatable, Sendable {
    public let title: String
    /// A next-action title alone is ambiguous on the Home Screen.  Keep the project
    /// name in the small widget projection so the hand-off has its essential context.
    public let projectName: String?
    public let kind: String
    public let stage: String
    public let priority: String
    public let dueDate: Date?

    public init(title: String, projectName: String? = nil, kind: String, stage: String, priority: String, dueDate: Date?) {
        self.title = title
        self.projectName = projectName
        self.kind = kind
        self.stage = stage
        self.priority = priority
        self.dueDate = dueDate
    }
}

public struct WorkspaceWidgetIdea: Codable, Equatable, Sendable {
    public let title: String
    public let modifiedAt: Date?

    public init(title: String, modifiedAt: Date?) {
        self.title = title
        self.modifiedAt = modifiedAt
    }
}

public struct WorkspaceWidgetSnapshot: Codable, Equatable, Sendable {
    public let nextWorkItem: WorkspaceWidgetWorkItem?
    public let openWorkCount: Int
    public let inProgressWorkCount: Int
    public let recentIdeas: [WorkspaceWidgetIdea]
    public let fetchedAt: Date

    public init(nextWorkItem: WorkspaceWidgetWorkItem?, openWorkCount: Int,
                inProgressWorkCount: Int, recentIdeas: [WorkspaceWidgetIdea], fetchedAt: Date) {
        self.nextWorkItem = nextWorkItem
        self.openWorkCount = max(0, openWorkCount)
        self.inProgressWorkCount = max(0, inProgressWorkCount)
        self.recentIdeas = Array(recentIdeas.prefix(3))
        self.fetchedAt = fetchedAt
    }

    /// Keep the mobile widget's recommendation deterministic and aligned with the
    /// desktop's documented ordering: active work, then Now/Next/Later, priority,
    /// and finally a stable title comparison.
    public static func make(from snapshot: MobileWorkspaceSnapshot) -> Self {
        let active = snapshot.workItems.filter { $0.status != .completed }.sorted { lhs, rhs in
            if lhs.stage != rhs.stage { return lhs.stage.rank < rhs.stage.rank }
            if lhs.priority != rhs.priority { return lhs.priority.rank < rhs.priority.rank }
            return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
        }
        let next = WorkItemRecommendation.nextMobileAction(in: snapshot.workItems).map {
            WorkspaceWidgetWorkItem(title: $0.title,
                                    projectName: $0.projectPath?.split(separator: "/").last.map(String.init),
                                    kind: $0.kind.rawValue, stage: $0.stage.rawValue,
                                    priority: $0.priority.rawValue, dueDate: $0.dueDate)
        }
        let ideas = snapshot.ideas.sorted { lhs, rhs in
            let lhsDate = lhs.modifiedAt ?? .distantPast
            let rhsDate = rhs.modifiedAt ?? .distantPast
            if lhsDate != rhsDate { return lhsDate > rhsDate }
            return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
        }.prefix(3).map { WorkspaceWidgetIdea(title: $0.title, modifiedAt: $0.modifiedAt) }

        return Self(
            nextWorkItem: next,
            openWorkCount: active.count,
            inProgressWorkCount: snapshot.workItems.filter { $0.status == .inProgress }.count,
            recentIdeas: ideas,
            fetchedAt: snapshot.fetchedAt
        )
    }
}

/// A tiny Codable bridge between an iOS app and its own WidgetKit extension.  A
/// missing or unreadable value means the widget should use its setup/empty state;
/// callers never erase a last-known-good snapshot on a sync failure.
public final class WidgetSnapshotStore: @unchecked Sendable {
    private enum Key {
        static let ingest = "widget.ingest.snapshot.v1"
        static let workspace = "widget.workspace.snapshot.v1"
    }

    private let defaults: UserDefaults

    public init?(appGroup: String) {
        guard let defaults = UserDefaults(suiteName: appGroup) else { return nil }
        self.defaults = defaults
    }

    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    public func save(_ snapshot: IngestWidgetSnapshot) {
        save(snapshot, key: Key.ingest)
    }

    public func save(_ snapshot: WorkspaceWidgetSnapshot) {
        save(snapshot, key: Key.workspace)
    }

    /// Saves an Ingest snapshot, except when doing so would replace a useful snapshot
    /// with the setup state.
    ///
    /// Resolving the inbox can fail transiently — iCloud not yet mounted on a cold
    /// launch, a security-scoped bookmark that did not restore — and that is not the
    /// same thing as the user having no inbox.  Overwriting in that case would swap a
    /// real count for "Set up your shared Inbox" until the next successful refresh.
    /// Returns whether anything was written, so the caller can skip a pointless reload.
    @discardableResult
    public func savePreservingLastKnownGood(_ snapshot: IngestWidgetSnapshot) -> Bool {
        if snapshot.state == .needsInbox, let existing = ingestSnapshot(), existing.state == .ready {
            return false
        }
        save(snapshot)
        return true
    }

    public func ingestSnapshot() -> IngestWidgetSnapshot? {
        load(IngestWidgetSnapshot.self, key: Key.ingest)
    }

    public func workspaceSnapshot() -> WorkspaceWidgetSnapshot? {
        load(WorkspaceWidgetSnapshot.self, key: Key.workspace)
    }

    private func save<Value: Encodable>(_ value: Value, key: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        defaults.set(data, forKey: key)
    }

    private func load<Value: Decodable>(_ type: Value.Type, key: String) -> Value? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}
