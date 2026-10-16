import Foundation

/// What Better Workspace reads from its background service.
///
/// The background service is the headless half of this app: it keeps watching the
/// Workspace while the window is closed, infers work sessions, drafts the work log,
/// keeps idea metadata and resurfaces ideas while you work. It began life as Workspace
/// Watcher's daemon, and it is still that Python process — see `docs/BACKGROUND_SERVICE.md`
/// for why it was adopted rather than rewritten, and which data each side owns.
///
/// The division is deliberate:
///
/// - **The service produces observations.** Sessions, the event journal, work-log drafts,
///   resurfacing scores and notification delivery are computed continuously, so they
///   live where the computation runs. This app never recomputes them.
/// - **The service stores idea metadata privately in SQLite.** Legacy
///   `watcher.item.toml` files are import sources only. This app reads and edits
///   metadata through the API; it never parses or writes sidecars.
/// - **This app owns everything a person decides** — projects, ratings, work items,
///   tags, ingest — and every screen.
///
/// Like `MeasurementService`, every call is optional. A service that is not running is
/// an ordinary state: each read answers `nil` ("could not read"), never an empty list,
/// so a view can keep showing what it last had.
public actor BackgroundServiceClient {

    public static let shared = BackgroundServiceClient()

    public init() {}

    #if DEBUG
    /// UI tests only: answer every read from `<directory>/<path with / as _>.json`
    /// instead of the network. A sandboxed test runner cannot serve HTTP, and an
    /// isolated test must never read the real service.
    nonisolated(unsafe) public static var fixtureDirectory: URL?
    #endif

    private func get(_ path: String, baseURL: URL?, timeout: TimeInterval) async -> Data? {
        #if DEBUG
        if let directory = Self.fixtureDirectory {
            let name = path.replacingOccurrences(of: "/", with: "_") + ".json"
            return try? Data(contentsOf: directory.appendingPathComponent(name))
        }
        #endif
        guard let root = MeasurementService.serviceURL(baseURL) else { return nil }
        let url = root.appendingPathComponent(path)
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode)
        else { return nil }
        return data
    }

    /// Whether the service is up and watching. `nil` when it could not be reached.
    public func health(baseURL: URL? = nil, timeout: TimeInterval = 3) async -> ServiceHealth? {
        guard let data = await get("v1/health", baseURL: baseURL, timeout: timeout) else { return nil }
        return try? Self.decodeHealth(data)
    }

    /// Transfer only Notion-writing authority; observations and private records remain service-owned.
    public func claimProjectGraphWriter(baseURL: URL? = nil) async -> Bool {
        #if DEBUG
        if Self.fixtureDirectory != nil { return true }
        #endif
        guard let root = MeasurementService.serviceURL(baseURL) else { return false }
        let url = root.appendingPathComponent("v1/notion/project-graph-writer")
        var request = URLRequest(url: url); request.httpMethod = "POST"; request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("{\"owner\":\"better-workspace\"}".utf8)
        guard let (_, response) = try? await URLSession.shared.data(for: request), let http = response as? HTTPURLResponse else { return false }
        return (200..<300).contains(http.statusCode)
    }

    public func projectGraphOwnsNotionWrites(baseURL: URL? = nil) async -> Bool {
        guard let data = await get("v1/notion/project-graph-writer", baseURL: baseURL, timeout: 3), let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        let payload = json["data"] as? [String: Any] ?? json
        return payload["owner"] as? String == "better-workspace"
    }
    public func acknowledgeGraphLink(kind: ProjectEntityKind, recordID: String, pageID: String, baseURL: URL? = nil) async -> Bool {
        #if DEBUG
        if Self.fixtureDirectory != nil { return true }
        #endif
        guard let root = MeasurementService.serviceURL(baseURL) else { return false }
        let url = root.appendingPathComponent("v1/notion/project-graph-link")
        var request = URLRequest(url: url); request.httpMethod = "POST"; request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["kind": kind.rawValue, "record_id": recordID, "page_id": pageID])
        guard let (_, response) = try? await URLSession.shared.data(for: request), let http = response as? HTTPURLResponse else { return false }
        return (200..<300).contains(http.statusCode)
    }

    /// The session in progress right now, if any. `.some(nil)` means "read it, nobody is
    /// working"; `nil` means "could not read".
    public func liveSession(baseURL: URL? = nil, timeout: TimeInterval = 5) async -> LiveSession?? {
        guard let data = await get("v1/session/live", baseURL: baseURL, timeout: timeout) else { return nil }
        return .some(try? Self.decodeLiveSession(data))
    }

    public func ideas(baseURL: URL? = nil, timeout: TimeInterval = 10) async -> [IdeaRecord]? {
        guard let data = await get("v1/ideas", baseURL: baseURL, timeout: timeout) else { return nil }
        return try? Self.decodeIdeas(data)
    }

    /// Ideas the service has scored as worth bringing back for the active project,
    /// best first. Computed by the service's scheduler; reading never recomputes.
    public func resurfacing(baseURL: URL? = nil, timeout: TimeInterval = 10) async -> [IdeaRecord]? {
        guard let data = await get("v1/ideas/resurfacing", baseURL: baseURL, timeout: timeout) else { return nil }
        return try? Self.decodeIdeas(data)
    }

    public func workLogs(baseURL: URL? = nil, timeout: TimeInterval = 10) async -> [WorkLogEntry]? {
        guard let data = await get("v1/work-logs", baseURL: baseURL, timeout: timeout) else { return nil }
        return try? Self.decodeWorkLogs(data)
    }

    /// What each day's Work Log rests on, from the service's last backfill run: recorded
    /// live, reconstructed from the surviving journals, or no evidence at all.
    public func workLogCoverage(baseURL: URL? = nil, timeout: TimeInterval = 10) async -> [String: WorkLogDayCoverage]? {
        guard let data = await get("v1/work-logs/coverage", baseURL: baseURL, timeout: timeout) else { return nil }
        return try? Self.decodeWorkLogCoverage(data)
    }

    public func notifications(baseURL: URL? = nil, timeout: TimeInterval = 10) async -> [ServiceNotification]? {
        guard let data = await get("v1/notifications", baseURL: baseURL, timeout: timeout) else { return nil }
        return try? Self.decodeNotifications(data)
    }

    /// The service's intent folders by id, as absolute paths. Used to follow a widget's
    /// link to one; nil when the service could not be read.
    public func intentFolderPaths(baseURL: URL? = nil, timeout: TimeInterval = 5) async -> [String: String]? {
        struct Row: Decodable { let id: String; let path: String; let exists_flag: Int? }
        guard let data = await get("v1/intents", baseURL: baseURL, timeout: timeout),
              let rows = try? JSONDecoder().decode(Envelope<[Row]>.self, from: data).data else { return nil }
        return Dictionary(rows.filter { $0.exists_flag != 0 }.map { ($0.id, $0.path) }, uniquingKeysWith: { first, _ in first })
    }

    /// The optional Notion integration as the service has it configured. `nil` when the
    /// service could not be read.
    public func notionStatus(baseURL: URL? = nil, timeout: TimeInterval = 5) async -> ServiceNotionStatus? {
        guard let data = await get("v1/settings", baseURL: baseURL, timeout: timeout) else { return nil }
        return try? Self.decodeNotionStatus(data)
    }

    /// Turns mirroring local ideas to the Notion Ideas database on or off. Local ideas
    /// are unaffected either way. Answers the setting now in force, or nil on failure.
    public func setIdeasNotionSync(_ enabled: Bool, baseURL: URL? = nil, timeout: TimeInterval = 5) async -> Bool? {
        #if DEBUG
        if Self.fixtureDirectory != nil { return enabled }
        #endif
        guard let root = MeasurementService.serviceURL(baseURL) else { return nil }
        let url = root.appendingPathComponent("v1/settings/ideas-notion-sync")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["enabled": enabled])
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }
        struct Row: Decodable { let ideas_notion_sync_enabled: Bool }
        return try? JSONDecoder().decode(Envelope<Row>.self, from: data).data.ideas_notion_sync_enabled
    }

    /// Records what someone did with a suggestion. `notRelated` teaches resurfacing not to
    /// pair that idea with the project again; `dismiss` only clears it.
    @discardableResult
    public func act(on notificationID: String, _ action: ServiceNotification.Action,
                    baseURL: URL? = nil, timeout: TimeInterval = 5) async -> Bool {
        #if DEBUG
        if Self.fixtureDirectory != nil { return true }
        #endif
        guard let root = MeasurementService.serviceURL(baseURL) else { return false }
        let url = root.appendingPathComponent("v1/notifications/\(notificationID)/actions")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["action": action.rawValue])
        guard let (_, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse else { return false }
        return (200..<300).contains(http.statusCode)
    }

    /// Changes an idea's private metadata through its owning service; this
    /// sends only what changed and answers the idea as the service now has it, or nil
    /// when the change was not made.
    public func updateIdea(id: String, _ changes: IdeaChanges,
                           baseURL: URL? = nil, timeout: TimeInterval = 10) async -> IdeaRecord? {
        guard changes.isEmpty == false else { return nil }
        #if DEBUG
        if Self.fixtureDirectory != nil {
            // A UI test edits its canned ideas; it must never reach a real service.
            guard let idea = await ideas()?.first(where: { $0.id == id }) else { return nil }
            func value(_ new: String?, _ old: String?) -> String? {
                guard let new else { return old }
                return new.isEmpty ? nil : new
            }
            var result = IdeaRecord(id: idea.id, title: idea.title, path: idea.path,
                              type: value(changes.type, idea.type), status: value(changes.status, idea.status),
                              oneLiner: value(changes.oneLiner, idea.oneLiner), impact: value(changes.impact, idea.impact),
                              effort: idea.effort, tags: idea.tags, relatedProjects: idea.relatedProjects,
                              keepSuggesting: changes.keepSuggesting ?? idea.keepSuggesting, deferUntil: idea.deferUntil,
                              lastScore: idea.lastScore, lastSurfacedAt: idea.lastSurfacedAt)
            result.planning = changes.planning ?? idea.planning
            return result
        }
        #endif
        guard let root = MeasurementService.serviceURL(baseURL) else { return nil }
        let url = root.appendingPathComponent("v1/ideas/\(id)")
        var request = URLRequest(url: url)
        request.httpMethod = "PATCH"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: changes.body)
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode)
        else { return nil }
        return try? Self.decodeIdea(data)
    }

    public func registerIdea(at url: URL, baseURL: URL? = nil) async -> IdeaRecord? {
        #if DEBUG
        if Self.fixtureDirectory != nil { return await ideas()?.first { $0.canonicalPath == url.canonicalPath } }
        #endif
        guard let root = MeasurementService.serviceURL(baseURL) else { return nil }
        var request = URLRequest(url: root.appendingPathComponent("v1/ideas/register"))
        request.httpMethod = "POST"; request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["path": url.canonicalPath])
        guard let (data, response) = try? await URLSession.shared.data(for: request), let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }
        return try? Self.decodeIdea(data)
    }

    public func relocateIdea(id: String, source: String, destination: String) async -> Bool {
        #if DEBUG
        // A fixture can mark the idea service unavailable to test interrupted promotions.
        if let fixture = Self.fixtureDirectory { return !FileManager.default.fileExists(atPath: fixture.appendingPathComponent("relocate-unavailable").path) }
        #endif
        guard let root = MeasurementService.serviceURL(nil) else { return false }
        var request = URLRequest(url: root.appendingPathComponent("v1/ideas/" + id + "/relocate"))
        request.httpMethod = "POST"; request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["source": source, "destination": destination])
        guard let (_, response) = try? await URLSession.shared.data(for: request), let http = response as? HTTPURLResponse else { return false }
        return (200..<300).contains(http.statusCode)
    }

    // MARK: - Decoding

    private struct Envelope<T: Decodable>: Decodable { let data: T }

    static func decodeNotionStatus(_ data: Data) throws -> ServiceNotionStatus {
        struct Health: Decodable { let state: String?; let error: String?; let synced: Int?; let errors: Int? }
        struct Row: Decodable {
            let notion_enabled: Bool
            let ideas_notion_sync_enabled: Bool
            let notion: Notion?
            struct Notion: Decodable {
                let token_present: Bool?
                let databases: [String: String]?
                let projects_cache_health: Health?
                let ideas_sync_health: Health?
                let ideas_sync_paused_until: String?
                let work_logs_notion_sync: Bool?
                let work_logs_authoritative_writer: String?
            }
        }
        let row = try JSONDecoder().decode(Envelope<Row>.self, from: data).data
        func health(_ h: Health?) -> ServiceNotionStatus.Health? {
            h.map { .init(state: $0.state ?? "unknown", error: $0.error, synced: $0.synced, errors: $0.errors) }
        }
        return ServiceNotionStatus(
            enabled: row.notion_enabled,
            tokenPresent: row.notion?.token_present ?? false,
            projectsDatabaseID: row.notion?.databases?["projects"].nonEmpty,
            workLogDatabaseID: row.notion?.databases?["work_log"].nonEmpty,
            ideasDatabaseID: row.notion?.databases?["ideas"].nonEmpty,
            ideasSyncEnabled: row.ideas_notion_sync_enabled,
            ideasSyncHealth: health(row.notion?.ideas_sync_health),
            ideasSyncPausedUntil: row.notion?.ideas_sync_paused_until.flatMap(ServiceDates.parse),
            projectsCacheHealth: health(row.notion?.projects_cache_health),
            workLogSyncEnabled: row.notion?.work_logs_notion_sync ?? false,
            workLogWriter: row.notion?.work_logs_authoritative_writer
        )
    }

    static func decodeHealth(_ data: Data) throws -> ServiceHealth {
        struct Row: Decodable { let state: String; let watch_roots: [String]? }
        let row = try JSONDecoder().decode(Envelope<Row>.self, from: data).data
        return ServiceHealth(state: row.state, watchRoots: row.watch_roots ?? [])
    }

    static func decodeLiveSession(_ data: Data) throws -> LiveSession? {
        struct Row: Decodable {
            let active: Bool
            let elapsed_seconds: Double?
            let project: Project?
            let session: Session?
            let recent_files: [FileRow]?
            struct Project: Decodable { let id: String?; let name: String?; let path: String? }
            struct Session: Decodable { let id: String?; let project_id: String?; let project_name: String?; let started_at: String? }
            /// The service has sent both bare paths and `{path: …}` rows here.
            enum FileRow: Decodable {
                case path(String)
                init(from decoder: Decoder) throws {
                    let container = try decoder.singleValueContainer()
                    if let value = try? container.decode(String.self) { self = .path(value); return }
                    struct Keyed: Decodable { let path: String? }
                    self = .path((try? container.decode(Keyed.self).path) ?? "")
                }
                var value: String { if case let .path(path) = self { return path }; return "" }
            }
        }
        let row = try JSONDecoder().decode(Envelope<Row>.self, from: data).data
        guard row.active else { return nil }
        let name = row.project?.name ?? row.session?.project_name
        guard let name else { return nil }
        return LiveSession(
            sessionID: row.session?.id,
            projectID: row.project?.id ?? row.session?.project_id,
            projectName: name,
            projectPath: row.project?.path,
            startedAt: row.session?.started_at.flatMap(ServiceDates.parse),
            elapsedSeconds: row.elapsed_seconds ?? 0,
            recentFiles: (row.recent_files ?? []).map(\.value).filter { $0.isEmpty == false }
        )
    }

    private struct IdeaRow: Decodable {
        let id: String
        let title: String
        let path: String
        let type: String?
        let status: String?
        let one_liner: String?
        let impact: String?
        let effort: LooseString?
        let tags: [String]?
        let related_projects: [String]?
        let keep_suggesting: Bool?
        let defer_until: String?
        let last_score: Double?
        let last_surfaced_at: String?
        let notion_page_id: String?
        let planning: IdeaPlanning?

        var record: IdeaRecord {
            IdeaRecord(
                id: id, title: title, path: path,
                type: type.nonEmpty, status: status.nonEmpty, oneLiner: one_liner.nonEmpty,
                impact: impact.nonEmpty, effort: effort?.value.nonEmpty,
                tags: tags ?? [], relatedProjects: related_projects ?? [],
                keepSuggesting: keep_suggesting ?? true,
                deferUntil: defer_until.flatMap(ServiceDates.parse),
                lastScore: last_score,
                lastSurfacedAt: last_surfaced_at.flatMap(ServiceDates.parse), notionPageID: notion_page_id, planning: planning
            )
        }
    }

    static func decodeIdeas(_ data: Data) throws -> [IdeaRecord] {
        try JSONDecoder().decode(Envelope<[IdeaRow]>.self, from: data).data.map(\.record)
    }

    static func decodeIdea(_ data: Data) throws -> IdeaRecord {
        try JSONDecoder().decode(Envelope<IdeaRow>.self, from: data).data.record
    }

    static func decodeWorkLogs(_ data: Data) throws -> [WorkLogEntry] {
        struct Row: Decodable {
            let id: String
            let project_id: String?
            let project_name: String
            let date_key: String
            let status: String
            let payload_json: String?
            let notion_page_id: String?
        }
        struct Payload: Decodable {
            let active_minutes: Double?
            let elapsed_minutes: Double?
            let session_count: Int?
            let summary: String?
            let files: [String]?
            let backfilled_session_count: Int?
        }
        return try JSONDecoder().decode(Envelope<[Row]>.self, from: data).data.map { row in
            let payload = row.payload_json
                .flatMap { $0.data(using: .utf8) }
                .flatMap { try? JSONDecoder().decode(Payload.self, from: $0) }
            return WorkLogEntry(
                id: row.id, projectID: row.project_id, projectName: row.project_name, dateKey: row.date_key,
                status: row.status, activeMinutes: payload?.active_minutes ?? 0,
                elapsedMinutes: payload?.elapsed_minutes ?? 0, sessionCount: payload?.session_count ?? 0,
                summary: payload?.summary.nonEmpty, files: payload?.files ?? [],
                syncedToNotion: row.notion_page_id?.isEmpty == false,
                reconstructedSessionCount: payload?.backfilled_session_count ?? 0, notionPageID: row.notion_page_id
            )
        }
        .sorted { ($0.dateKey, $0.projectName) > ($1.dateKey, $1.projectName) }
    }

    static func decodeWorkLogCoverage(_ data: Data) throws -> [String: WorkLogDayCoverage] {
        struct Day: Decodable {
            let status: String
            let filesystem_events: Int?
            let terminal_events: Int?
            let reconstructed_sessions: Int?
        }
        struct Report: Decodable { let days: [String: Day]? }
        let report = try JSONDecoder().decode(Envelope<Report>.self, from: data).data
        return (report.days ?? [:]).mapValues { day in
            WorkLogDayCoverage(status: WorkLogDayCoverage.Status(rawValue: day.status) ?? .unknown,
                               evidenceCount: (day.filesystem_events ?? 0) + (day.terminal_events ?? 0),
                               reconstructedSessions: day.reconstructed_sessions ?? 0)
        }
    }

    static func decodeNotifications(_ data: Data) throws -> [ServiceNotification] {
        struct Row: Decodable {
            let id: String
            let type: String
            let title: String
            let body: String?
            let entity_id: String?
            let state: String
            let selected_action: String?
            let created_at: String
        }
        return try JSONDecoder().decode(Envelope<[Row]>.self, from: data).data.map { row in
            ServiceNotification(
                id: row.id, type: row.type, title: row.title, body: row.body.nonEmpty, entityID: row.entity_id,
                state: row.state, selectedAction: row.selected_action,
                createdAt: ServiceDates.parse(row.created_at) ?? .distantPast
            )
        }
        .sorted { $0.createdAt > $1.createdAt }
    }
}

/// `effort` has been both a word and a number in idea metadata.
private struct LooseString: Decodable {
    let value: String?
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let text = try? container.decode(String.self) { value = text }
        else if let number = try? container.decode(Double.self) { value = String(format: "%g", number) }
        else { value = nil }
    }
}

private extension Optional where Wrapped == String {
    var nonEmpty: String? {
        guard let self, self.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else { return nil }
        return self
    }
}

enum ServiceDates {
    static func parse(_ raw: String) -> Date? {
        ProjectDates.parse(raw)
    }
}

public struct ServiceHealth: Sendable, Hashable {
    public let state: String
    public let watchRoots: [String]
    public var isRunning: Bool { state == "running" }
}

public struct LiveSession: Sendable, Hashable {
    public let sessionID: String?
    public let projectID: String?
    public let projectName: String
    /// Workspace-relative, e.g. `Projects/Better Workspace`, when the service knows it.
    public let projectPath: String?
    public let startedAt: Date?
    public let elapsedSeconds: Double
    public let recentFiles: [String]
}

/// One idea as the service knows it: a file/folder plus privately stored metadata.
public struct IdeaRecord: Sendable, Hashable, Identifiable {
    public let id: String
    public let title: String
    /// Absolute path of the idea's file or folder.
    public let path: String
    public let type: String?
    public let status: String?
    public let oneLiner: String?
    public let impact: String?
    public let effort: String?
    public let tags: [String]
    public let relatedProjects: [String]
    public let keepSuggesting: Bool
    public let deferUntil: Date?
    public let lastScore: Double?
    public let lastSurfacedAt: Date?

    public var notionPageID: String? = nil
    public var planning: IdeaPlanning? = nil
    public var canonicalPath: String { URL(fileURLWithPath: path).canonicalPath }
}

public struct WorkLogEntry: Sendable, Hashable, Identifiable {
    public let id: String
    public let projectID: String?
    public let projectName: String
    /// `YYYY-MM-DD`, the day the work happened.
    public let dateKey: String
    /// The service's draft state: `prepared`, `synced`, `failed`…
    public let status: String
    public let activeMinutes: Double
    public let elapsedMinutes: Double
    public let sessionCount: Int
    public let summary: String?
    public let files: [String]
    public let syncedToNotion: Bool
    /// Sessions rebuilt from the surviving journals rather than observed live.
    public var reconstructedSessionCount: Int = 0
    public var notionPageID: String? = nil

    public var isReconstructed: Bool { reconstructedSessionCount > 0 }
    public var isWhollyReconstructed: Bool { reconstructedSessionCount > 0 && reconstructedSessionCount >= sessionCount }
}

/// What one day of the Work Log rests on.
public struct WorkLogDayCoverage: Sendable, Hashable {
    public enum Status: String, Sendable {
        case recorded
        case reconstructed
        case recordedAndReconstructed = "recorded_and_reconstructed"
        /// Activity was observed, none of it in a project.
        case noProjectWork = "no_project_work"
        /// Nothing survives for the day: not filled in.
        case noEvidence = "no_evidence"
        case unknown
    }

    public let status: Status
    public let evidenceCount: Int
    public let reconstructedSessions: Int

    public init(status: Status, evidenceCount: Int, reconstructedSessions: Int) {
        self.status = status
        self.evidenceCount = evidenceCount
        self.reconstructedSessions = reconstructedSessions
    }
}

public struct ServiceNotification: Sendable, Hashable, Identifiable {
    public enum Action: String, Sendable { case open, dismiss, notRelated = "not_related", archive }

    public let id: String
    /// `suggestion` for a resurfaced idea; other kinds are operational.
    public let type: String
    public let title: String
    public let body: String?
    /// The idea (or other item) this is about.
    public let entityID: String?
    public let state: String
    /// What was done with it, once someone did something.
    public let selectedAction: String?
    public let createdAt: Date

    public var isOpenSuggestion: Bool { type == "suggestion" && selectedAction == nil && state != "acted" }
}

/// An edit to an idea's metadata. A nil field is left as it is; an empty string clears it.
public struct IdeaChanges: Sendable, Hashable {
    public var status: String?
    public var type: String?
    public var impact: String?
    public var oneLiner: String?
    public var keepSuggesting: Bool?
    public var title: String?
    public var effort: String?
    public var tags: [String]?
    public var relatedProjects: [String]?
    /// Empty string explicitly clears the defer date.
    public var deferUntil: String?
    public var planning: IdeaPlanning?
    public var expectedPlanning: IdeaPlanning?
    public var checksPlanning = false

    public init(status: String? = nil, type: String? = nil, impact: String? = nil,
                oneLiner: String? = nil, keepSuggesting: Bool? = nil) {
        self.status = status
        self.type = type
        self.impact = impact
        self.oneLiner = oneLiner
        self.keepSuggesting = keepSuggesting
    }

    public var isEmpty: Bool { body.isEmpty }

    /// The service's field names.
    public var body: [String: Any] {
        var out: [String: Any] = [:]
        if let planning, let data = try? JSONEncoder().encode(planning), let value = try? JSONSerialization.jsonObject(with: data) { out["planning"] = value }
        if checksPlanning {
            out["expected_planning"] = expectedPlanning.flatMap { try? JSONEncoder().encode($0) }.flatMap { try? JSONSerialization.jsonObject(with: $0) } ?? NSNull()
        }
        if let status { out["status"] = status.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let type { out["type"] = type.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let impact { out["impact"] = impact.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let oneLiner { out["one_liner"] = oneLiner.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let keepSuggesting { out["keep_suggesting"] = keepSuggesting }
        if let title { out["title"] = title }
        if let effort { out["effort"] = effort }
        if let tags { out["tags"] = tags }
        if let relatedProjects { out["related_projects"] = relatedProjects }
        if let deferUntil { out["defer_until"] = deferUntil.isEmpty ? NSNull() : deferUntil as Any }
        return out
    }

    /// What differs between an idea and the values a person has now entered.
    public static func between(_ idea: IdeaRecord, status: String, type: String, impact: String,
                               oneLiner: String, keepSuggesting: Bool) -> IdeaChanges {
        func changed(_ old: String?, _ new: String) -> String? {
            let trimmed = new.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed == (old ?? "") ? nil : trimmed
        }
        return IdeaChanges(status: changed(idea.status, status), type: changed(idea.type, type),
                           impact: changed(idea.impact, impact), oneLiner: changed(idea.oneLiner, oneLiner),
                           keepSuggesting: keepSuggesting == idea.keepSuggesting ? nil : keepSuggesting)
    }

    /// The service's suggested values, then every value already in use, without repeats.
    public static func choices(suggested: [String], inUse: [String?]) -> [String] {
        var seen = Set<String>()
        return (suggested + inUse.compactMap { $0 }.sorted()).filter { seen.insert($0.lowercased()).inserted }
    }

    public static let suggestedStatuses = ["raw", "exploring", "plan", "to_implement", "to_write", "archived"]
    public static let suggestedTypes = ["unclassified", "project", "feature", "story", "experiment", "media", "task"]
    public static let suggestedImpacts = ["Low", "Medium", "High"]
}

/// The service's optional Notion integration: which databases it is pointed at, and
/// what it does with them. Observations remain service-owned; structured metadata
/// can synchronize through the reviewed project graph after writer handoff.
public struct ServiceNotionStatus: Sendable, Hashable {
    public struct Health: Sendable, Hashable {
        /// `ok`, `error`, or `database_missing` when the database itself no longer resolves.
        public let state: String
        public let error: String?
        public let synced: Int?
        public let errors: Int?
    }

    /// Whether the service reads Notion at all (the Projects cache that work-log entries
    /// use to name their project).
    public let enabled: Bool
    public let tokenPresent: Bool
    public let projectsDatabaseID: String?
    public let workLogDatabaseID: String?
    public let ideasDatabaseID: String?
    /// Whether local ideas are mirrored to the Notion Ideas database.
    public let ideasSyncEnabled: Bool
    public let ideasSyncHealth: Health?
    /// Set after the Ideas database stopped resolving; sync retries after this.
    public let ideasSyncPausedUntil: Date?
    public let projectsCacheHealth: Health?
    /// Whether work-log entries are written to the Notion work log (a config-file switch).
    public let workLogSyncEnabled: Bool
    public let workLogWriter: String?
}
