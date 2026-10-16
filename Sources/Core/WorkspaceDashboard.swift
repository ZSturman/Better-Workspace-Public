import Foundation
import Darwin

public struct WidgetAttentionItem: Codable, Hashable, Identifiable, Sendable {
    public enum Category: String, Codable, CaseIterable, Sendable { case failure, overdue, blocked, inbox, project }
    public var id: String
    public var title: String
    public var reason: String
    public var category: Category
    public var route: WidgetRoute
    public init(id: String, title: String, reason: String, category: Category, route: WidgetRoute) {
        self.id = id; self.title = title; self.reason = reason; self.category = category; self.route = route
    }
}

/// Routes contain identities or bounded relative paths, never arbitrary filesystem URLs.
public enum WidgetRoute: Codable, Hashable, Sendable {
    case project(String), task(String), idea(String), review(String), capture(String), charts(String), attention(String), overview
    public func url(mobile: Bool) -> URL {
        var components = URLComponents()
        components.scheme = mobile ? "betterworkspace-mobile" : "betterworkspace"
        let host: String, value: String
        switch self {
        case .project(let id): host = "widget-project"; value = id
        case .task(let id): host = "task"; value = id
        case .idea(let path): host = "widget-idea"; value = path
        case .review(let id): host = "review"; value = id
        case .capture(let name): host = "inbox"; value = name
        case .charts(let mode): host = "charts"; value = mode
        case .attention(let category): host = "attention"; value = category
        case .overview: host = "overview"; value = ""
        }
        components.host = host
        components.queryItems = value.isEmpty ? nil : [URLQueryItem(name: "id", value: value)]
        return components.url!
    }
    public init?(url: URL) {
        guard ["betterworkspace", "betterworkspace-mobile"].contains(url.scheme ?? "") else { return nil }
        let id = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "id" }?.value ?? ""
        switch url.host {
        case "widget-project": self = .project(id)
        case "task": self = .task(id)
        case "widget-idea": self = .idea(id)
        case "review": self = .review(id)
        case "inbox": self = .capture(id)
        case "charts": self = .charts(id)
        case "attention": self = .attention(id)
        case "overview": self = .overview
        default: return nil
        }
    }
}

public struct DashboardProject: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var serviceID: String?
    public var path: String
    public var name: String
    public var status: String?
    public var focus: OverviewFocusItem
    public var nextTask: MobileWorkItem?
    public var rankingScore: Double? = nil
    public var route: WidgetRoute { .project(id) }
}

public struct DashboardCapture: Codable, Hashable, Identifiable, Sendable {
    public var id: String { name }
    public var name: String
    public var modified: Date
    public var expectedChildren: Set<String>
    public init(name: String, modified: Date, expectedChildren: Set<String> = []) {
        self.name = name; self.modified = modified; self.expectedChildren = expectedChildren
    }
}

public struct WidgetCaptureFiling: Codable, Hashable, Sendable {
    public var capture: DashboardCapture
    public var destination: String
    public init(capture: DashboardCapture, destination: String) { self.capture = capture; self.destination = destination }
}

public enum WidgetTaskQueue: String, Codable, CaseIterable, Sendable { case next, overdue, inProgress }

/// Disposable display data. File contents and the workspace database are never read
/// by an extension. Task bodies are omitted; existing editors preserve them on saves.
public struct WorkspaceDashboardSnapshot: Codable, Hashable, Sendable {
    public var projects: [DashboardProject]
    public var work: [MobileWorkItem]
    public var focusItems: [OverviewFocusItem]
    public var reviewItems: [OverviewInboxItem]
    public var reviewCount: Int?
    public var reviewCheckedAt: Date?
    public var attention: [WidgetAttentionItem]
    public var captures: [DashboardCapture]
    public var captureCount: Int?
    public var captureUpdatedAt: Date?
    public var destinations: [MobileCaptureDestination]
    public var updatedAt: Date
    public init(projects: [DashboardProject] = [], work: [MobileWorkItem] = [], focusItems: [OverviewFocusItem] = [],
                reviewItems: [OverviewInboxItem] = [], reviewCount: Int? = nil, reviewCheckedAt: Date? = nil,
                attention: [WidgetAttentionItem] = [], captures: [DashboardCapture] = [], captureCount: Int? = nil,
                captureUpdatedAt: Date? = nil, destinations: [MobileCaptureDestination] = [], updatedAt: Date = Date()) {
        self.projects = projects; self.work = work; self.focusItems = focusItems
        self.reviewItems = Array(reviewItems.prefix(8)); self.reviewCount = reviewCount; self.reviewCheckedAt = reviewCheckedAt
        self.attention = attention; self.captures = Array(captures.prefix(30)); self.captureCount = captureCount
        self.captureUpdatedAt = captureUpdatedAt; self.destinations = destinations; self.updatedAt = updatedAt
    }

    public func project(id: String?) -> DashboardProject? {
        guard let id else { return projects.first { !$0.focus.terminal } }
        return projects.first { $0.id == id || $0.path == id || $0.serviceID == id }
    }
    public func tasks(queue: WidgetTaskQueue, projectID: String? = nil, now: Date = Date()) -> [MobileWorkItem] {
        let path = projectID.flatMap { project(id: $0)?.path }
        if projectID != nil && path == nil { return [] }
        var candidates = work.filter { $0.kind == .task && $0.status != .completed && (path == nil || $0.projectPath == path) }
        switch queue {
        case .next:
            // Repeatedly use the same recommendation function as the apps. Dependencies
            // are resolved against the whole universe, not only the displayed project.
            var ordered: [MobileWorkItem] = []
            while let next = WorkItemRecommendation.nextMobileAction(in: candidates, allItems: work, projectScores: Dictionary(uniqueKeysWithValues: projects.compactMap { project in (project.rankingScore ?? project.focus.score).map { (project.path, $0) } })) {
                ordered.append(next); candidates.removeAll { $0.id == next.id }
            }
            return ordered
        case .overdue: candidates = candidates.filter { $0.dueDate.map { $0 < Calendar.current.startOfDay(for: now) } ?? false }
        case .inProgress: candidates = candidates.filter { $0.status == .inProgress }
        }
        return candidates.sorted {
            if queue == .overdue, $0.dueDate != $1.dueDate { return ($0.dueDate ?? .distantFuture) < ($1.dueDate ?? .distantFuture) }
            if $0.stage != $1.stage { return $0.stage.rank < $1.stage.rank }
            if $0.priority != $1.priority { return $0.priority.rank < $1.priority.rank }
            return $0.title == $1.title ? $0.id < $1.id : $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
    }

    public static func make(from snapshot: MobileWorkspaceSnapshot) -> Self {
        let work = snapshot.workItems.map { item -> MobileWorkItem in var item = item; item.body = nil; return item }
        // Convert once, rather than re-encoding every work item's metadata for every project.
        let portable = work.map(WorkItemRecommendation.portableForRecommendation)
        let portableByProject = Dictionary(grouping: portable.filter { $0.kind == .task }, by: { $0.projectPath ?? "" })
        let grouped = Dictionary(grouping: work.filter { $0.kind == .task }, by: { $0.projectPath ?? "" })
        let projectEntries: [MobileWorkspaceEntry] = snapshot.entries.filter { $0.parentPath == "Projects" && $0.isDirectory }
        var projects: [DashboardProject] = []
        for entry in projectEntries {
            let details = entry.projectDetails
            let evidence = snapshot.overview?.focusItems.first { $0.kind == .projects && $0.path == entry.path }
            let tasks = grouped[entry.path] ?? []
            let terminalStatuses = ["complete", "completed", "archived", "cancelled", "canceled"]
            let terminal: Bool = details?.status.map { terminalStatuses.contains($0.lowercased()) } ?? evidence?.terminal ?? false
            let score: Double? = (details?.ratingCoverage ?? 0) >= 0.5 ? details?.manualScore : evidence?.score
            let focus = OverviewFocusItem(id: details?.projectID ?? entry.path, path: entry.path, title: entry.name, kind: .projects,
                score: score,
                completed: tasks.filter { $0.status == .completed }.count, total: tasks.count,
                lastWorked: details?.lastWorked ?? evidence?.lastWorked, lastChanged: entry.modifiedAt,
                terminal: terminal, blocked: evidence?.blocked ?? false)
            let nextID = WorkItemRecommendation.nextAction(in: portableByProject[entry.path] ?? [], allItems: portable)?.id
            projects.append(DashboardProject(id: focus.id, serviceID: details?.serviceID, path: entry.path, name: entry.name,
                status: details?.status, focus: focus, nextTask: tasks.first { $0.id == nextID }, rankingScore: details?.rankingScore ?? evidence?.score))
        }
        projects.sort { $0.name == $1.name ? $0.id < $1.id : $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        var focuses = snapshot.overview?.focusItems.filter { $0.kind != .projects } ?? []
        focuses += projects.map(\.focus)
        return Self(projects: projects, work: work, focusItems: focuses,
            reviewItems: snapshot.overview?.reviewItems ?? snapshot.overview?.inboxItem.map { [$0] } ?? [],
            reviewCount: snapshot.overview?.reviewCount, reviewCheckedAt: snapshot.overview?.inboxCheckedAt,
            attention: snapshot.overview?.attention ?? [], destinations: MobileCaptureCatalog.destinations(from: snapshot.entries), updatedAt: snapshot.fetchedAt)
    }

    public func attentionItems(now: Date = Date()) -> [WidgetAttentionItem] {
        var result = attention.filter { $0.category == .failure || $0.category == .project }
        let completed = Set(work.filter { $0.status == .completed }.flatMap { [$0.id, $0.importedNotionPageID].compactMap { $0 } })
        for item in work where item.status != .completed {
            if item.dueDate.map({ $0 < Calendar.current.startOfDay(for: now) }) == true {
                result.append(.init(id: "overdue:\(item.id)", title: item.title, reason: "Overdue · \(item.dueDate!.formatted(date: .abbreviated, time: .omitted))", category: .overdue, route: .task(item.id)))
            } else if item.needsAttention {
                result.append(.init(id: "unplaced:\(item.id)", title: item.title, reason: "\(item.kind.displayName) has no project", category: .blocked, route: .task(item.id)))
            } else if !(item.actionMetadata?.blockedBy.isEmpty ?? true) || !(item.dependencyIDs ?? []).allSatisfy({ completed.contains($0) }) {
                result.append(.init(id: "blocked:\(item.id)", title: item.title, reason: "Waiting on a blocker or unfinished dependency", category: .blocked, route: .task(item.id)))
            }
        }
        if let count = reviewCount, count > 0 { result.append(.init(id: "review", title: "Inbox review", reason: "\(count) items due for review", category: .inbox, route: .review(""))) }
        if let count = captureCount, count > 0 { result.append(.init(id: "capture", title: "Captures to file", reason: "\(count) captures waiting", category: .inbox, route: .capture(""))) }
        return result.sorted {
            let order = WidgetAttentionItem.Category.allCases
            let a = order.firstIndex(of: $0.category)!, b = order.firstIndex(of: $1.category)!
            if a != b { return a < b }
            return $0.id < $1.id
        }
    }
}

public enum DashboardWidgetStore {
    public static func directory(appGroup: String) -> URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)?.appendingPathComponent("WidgetDashboard", isDirectory: true)
    }
    public static func load(directory: URL) -> WorkspaceDashboardSnapshot? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("snapshot.json")) else { return nil }
        return try? JSONDecoder().decode(WorkspaceDashboardSnapshot.self, from: data)
    }
    public static func save(_ snapshot: WorkspaceDashboardSnapshot, directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(snapshot)
        guard data.count <= MobileSnapshotCache.byteLimit else { throw MobilePlanningFiles.Error.invalid("Widget snapshot exceeds its size limit.") }
        try data.write(to: directory.appendingPathComponent("snapshot.json"), options: .atomic)
    }
    /// Serializes read/modify/write across the app and widget process. Capture
    /// publication and CloudKit publication each own a different part of the cache.
    public static func update(directory: URL, _ transform: (WorkspaceDashboardSnapshot?) throws -> WorkspaceDashboardSnapshot) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let descriptor = open(directory.appendingPathComponent("snapshot.lock").path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw WidgetCommandError.message("Widget cache could not be locked.") }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw WidgetCommandError.message("Widget cache is busy.") }
        defer { flock(descriptor, LOCK_UN) }
        try save(transform(load(directory: directory)), directory: directory)
    }
    public static func saveWorkspace(_ snapshot: WorkspaceDashboardSnapshot, directory: URL) throws {
        try update(directory: directory) { existing in
            var value = snapshot
            if let existing {
                if existing.updatedAt > snapshot.updatedAt { return existing }
                value.captures = existing.captures; value.captureCount = existing.captureCount; value.captureUpdatedAt = existing.captureUpdatedAt
            }
            return value
        }
    }
}
