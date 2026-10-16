import AppIntents
import Foundation
import BetterWorkspaceCore

/// The WidgetKit process reads this projection from the versioned localhost
/// API, never the background service's SQLite database. Its schema is produced by
/// `widget_snapshot.py` and is also used for configuration entity queries.
enum WorkspaceWidgetStore {
    static func load() async -> WorkspaceWidgetSnapshot? {
        guard let url = URL(string: "http://127.0.0.1:8765/v1/widgets/snapshot"),
              let (data, response) = try? await URLSession.shared.data(from: url),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }
        return try? JSONDecoder.workspaceWidget.decode(WidgetEnvelope<WorkspaceWidgetSnapshot>.self, from: data).data
    }
}

private struct WidgetEnvelope<Value: Decodable>: Decodable { let data: Value }

extension JSONDecoder {
    static let workspaceWidget: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

struct WorkspaceWidgetSnapshot: Codable {
    let schemaVersion: Int
    let generatedAt: Date
    let projects: [WidgetProject]
    let intents: [WidgetIntentFolder]
    let session: WidgetSession
    let resurfaced: [WidgetResurfacedItem]
    let activity: [WidgetActivity]
    let today: WidgetToday
    let health: WidgetHealth
    let counts: WidgetCounts

    enum CodingKeys: String, CodingKey {
        case projects, intents, session, resurfaced, activity, today, health, counts
        case schemaVersion = "schema_version"
        case generatedAt = "generated_at"
    }
}

struct WidgetProject: Codable, Identifiable, Hashable {
    let id, name, path, status, nextAction: String
    let domain: String?
    /// The human status (Active, Paused, Complete…), distinct from `status`,
    /// which is the filesystem active/deleted fact.
    let statusLabel: String?
    let tags: [WidgetTag]
    let score: Double
    /// Days since the last completed session that showed real file activity;
    /// nil when this project has never been worked on. This is the one thing
    /// genuinely measured for every project, so it is what widgets display.
    let daysSinceLastSession: Double?
    let openGoalsCount: Int
    let needsAttention, isCurrent, hasActiveSession: Bool
    enum CodingKeys: String, CodingKey {
        case id, name, path, status, domain, tags, score
        case statusLabel = "status_label", daysSinceLastSession = "days_since_last_session"
        case nextAction = "next_action"; case openGoalsCount = "open_goals_count"
        case needsAttention = "needs_attention"; case isCurrent = "is_current"; case hasActiveSession = "has_active_session"
    }

    /// Short enough for a small widget row: "today", "3d", "5mo", "never".
    var recencyLabel: String {
        guard let days = daysSinceLastSession else { return "never" }
        if days < 1 { return "today" }
        if days < 2 { return "1d" }
        if days < 30 { return "\(Int(days))d" }
        return "\(Int(days / 30))mo"
    }
}
struct WidgetTag: Codable, Hashable { let id, display: String }
struct WidgetIntentFolder: Codable, Identifiable { let id, name: String; let count: Int; let items: [WidgetIntentItem] }
struct WidgetIntentItem: Codable, Identifiable { let id, title, status: String; let updatedAt: Date; enum CodingKeys: String, CodingKey { case id, title, status; case updatedAt = "updated_at" } }
struct WidgetResurfacedItem: Codable, Identifiable { let id, title, intent, why: String; let score: Double?; let surfacedAt: Date; enum CodingKeys: String, CodingKey { case id, title, intent, why, score; case surfacedAt = "surfaced_at" } }
struct WidgetActivity: Codable, Identifiable { let id, type, summary: String; let at: Date; let projectID: String?; enum CodingKeys: String, CodingKey { case id, type, summary, at; case projectID = "project_id" } }
struct WidgetToday: Codable { let sessionCount: Int; let activeSeconds: Double; let projects: [String]; let meaningfulEvents: Int; enum CodingKeys: String, CodingKey { case projects; case sessionCount = "session_count"; case activeSeconds = "active_seconds"; case meaningfulEvents = "meaningful_events" } }
struct WidgetCounts: Codable {
    let projects, intentItems, attentionProjects: Int
    /// Projects with real file activity in the last seven days, and projects
    /// with no domain yet (so invisible to every organizational lens).
    /// Optional so an older snapshot on disk still decodes.
    let active7d, unfiledProjects: Int?
    enum CodingKeys: String, CodingKey {
        case projects
        case intentItems = "intent_items", attentionProjects = "attention_projects"
        case active7d = "active_7d", unfiledProjects = "unfiled_projects"
    }
}
struct WidgetHealth: Codable { let watcherState: String; let problems: [WidgetProblem]; enum CodingKeys: String, CodingKey { case problems; case watcherState = "watcher_state" } }
struct WidgetProblem: Codable, Identifiable { let component, state: String; let error: String?; var id: String { component } }

struct WidgetSession: Codable {
    let active: Bool
    let session: WidgetSessionInfo?
    let project: WidgetProjectReference?
    let elapsedSeconds: Double
    let goals: [WidgetGoal]
    let goalsCompleted, goalsTotal: Int?
    enum CodingKeys: String, CodingKey { case active, session, project, goals; case elapsedSeconds = "elapsed_seconds"; case goalsCompleted = "goals_completed"; case goalsTotal = "goals_total" }
}
struct WidgetSessionInfo: Codable { let id: String; let startedAt: Date; enum CodingKeys: String, CodingKey { case id; case startedAt = "started_at" } }
struct WidgetProjectReference: Codable { let id, name: String }
struct WidgetGoal: Codable, Identifiable { let id, projectId, text: String; let completed: Int; enum CodingKeys: String, CodingKey { case id, text, completed; case projectId = "project_id" } }

// MARK: - Configuration entities

struct WorkspaceProjectEntity: AppEntity {
    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Workspace Project")
    static var defaultQuery = WorkspaceProjectQuery()
    let id: String
    let name: String
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
}

struct WorkspaceProjectQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [WorkspaceProjectEntity] {
        if let dashboard = WidgetDashboardRuntime.load() {
            return identifiers.map { id in WorkspaceProjectEntity(id: id, name: dashboard.project(id: id)?.name ?? "Unavailable project") }
        }
        let projects = await WorkspaceWidgetStore.load()?.projects ?? []
        return identifiers.map { id in WorkspaceProjectEntity(id: id, name: projects.first { $0.id == id }?.name ?? "Unavailable project") }
    }
    func suggestedEntities() async throws -> [WorkspaceProjectEntity] {
        if let dashboard = WidgetDashboardRuntime.load() { return dashboard.projects.filter { !$0.focus.terminal }.prefix(50).map { .init(id: $0.id, name: $0.name) } }
        return (await WorkspaceWidgetStore.load()?.projects ?? []).prefix(20).map { WorkspaceProjectEntity(id: $0.id, name: $0.name) }
    }
}

extension WorkspaceProjectQuery {
    func entities(matching string: String) async throws -> [WorkspaceProjectEntity] {
        if let dashboard = WidgetDashboardRuntime.load() { return dashboard.projects.filter { $0.name.localizedCaseInsensitiveContains(string) }.map { .init(id: $0.id, name: $0.name) } }
        return try await suggestedEntities().filter { $0.name.localizedCaseInsensitiveContains(string) }
    }
}
struct WorkspaceIntentEntity: AppEntity {
    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Intent Folder")
    static var defaultQuery = WorkspaceIntentQuery()
    let id: String
    let name: String
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
}
struct WorkspaceIntentQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [WorkspaceIntentEntity] {
        let values = await WorkspaceWidgetStore.load()?.intents ?? []
        return values.filter { identifiers.contains($0.id) }.map { WorkspaceIntentEntity(id: $0.id, name: $0.name) }
    }
    func suggestedEntities() async throws -> [WorkspaceIntentEntity] {
        (await WorkspaceWidgetStore.load()?.intents ?? []).map { WorkspaceIntentEntity(id: $0.id, name: $0.name) }
    }
}

enum ProjectCount: String, AppEnum { case one = "1", three = "3", five = "5"; static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Project Count"); static var caseDisplayRepresentations: [ProjectCount: DisplayRepresentation] = [.one: "One", .three: "Top 3", .five: "Top 5"]; var value: Int { Int(rawValue)! } }
enum ItemCount: String, AppEnum { case three = "3", five = "5", eight = "8"; static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Item Count"); static var caseDisplayRepresentations: [ItemCount: DisplayRepresentation] = [.three: "3 items", .five: "5 items", .eight: "8 items"]; var value: Int { Int(rawValue)! } }
enum ActivityScope: String, AppEnum { case meaningful, sessions, projects; static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Activity Type"); static var caseDisplayRepresentations: [ActivityScope: DisplayRepresentation] = [.meaningful: "Meaningful activity", .sessions: "Sessions", .projects: "Projects"] }

struct WorkNextConfiguration: WidgetConfigurationIntent { static var title: LocalizedStringResource = "Configure Work Queue"; @Parameter(title: "Projects", default: .three) var count: ProjectCount; @Parameter(title: "Tag") var tag: String? }
struct IntentInboxConfiguration: WidgetConfigurationIntent { static var title: LocalizedStringResource = "Configure Intent Inbox"; @Parameter(title: "Intent") var intent: WorkspaceIntentEntity?; @Parameter(title: "Items", default: .five) var count: ItemCount }
struct ProjectFocusConfiguration: WidgetConfigurationIntent { static var title: LocalizedStringResource = "Configure Project Focus"; @Parameter(title: "Project") var project: WorkspaceProjectEntity? }
struct ActivityConfiguration: WidgetConfigurationIntent { static var title: LocalizedStringResource = "Configure Recent Activity"; @Parameter(title: "Show", default: .meaningful) var scope: ActivityScope }
