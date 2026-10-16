import Foundation

/// Observed measurements about projects, read from the background service.
///
/// Watcher is the brain, this app is the face. It has been sensing filesystem activity
/// for a while, infers work sessions from it, and derives roughly thirty dimensions
/// with an honest account of how much it actually knows. Reimplementing that in Swift
/// would be thousands of lines to arrive at the same numbers.
///
/// Two rules, both from Watcher's own client contract:
///
/// 1. **Never recompute a formula here.** Present `value`, `state`, `raw_value` and
///    `explanation` as given. If a number looks wrong, it is wrong in the backend and
///    that is where it gets fixed — a second implementation would only disagree.
/// 2. **Unknown, provisional and known stay distinguishable.** An unmeasured project
///    has no value; it does not have zero. Watcher is careful about this and the
///    distinction must survive the trip into the UI.
///
/// Nothing here is required. When the daemon is not running every measurement is
/// simply unknown, which is the truth, and the rest of the app is unaffected.

public enum MeasurementState: String, Codable, Sendable {
    /// Not measurable from what is on hand. Renders as an em dash, never as zero.
    case unknown
    /// Calculable, but resting on incomplete observation — worth showing, worth marking.
    case provisional
    case known
}

public struct MeasuredValue: Sendable, Hashable {
    public let dimension: String
    /// Normalized 0–100, except `activityAge`, which is in days. `nil` when unknown.
    public let value: Double?
    /// The measurement in its own terms — hours, days — before normalization.
    public let rawValue: Double?
    public let unit: String?
    public let state: MeasurementState
    /// The backend's own words for what this number means and what it does not prove.
    public let explanation: String?
    public let source: String?
    public let formulaVersion: String?
    /// "At least this much": the service reports how long it has watched without
    /// observing work, not a measured age. It can never establish recency.
    public var isLowerBound: Bool = false

    public var isKnown: Bool { value != nil }
    public var isProvisional: Bool { state == .provisional }
}

public struct ProjectMeasurements: Sendable {
    public let watcherID: String
    public let name: String
    public let dimensions: [String: MeasuredValue]

    public func measurement(_ dimension: MeasurementDimension) -> MeasuredValue? {
        dimensions[dimension.rawValue]
    }
}

/// The dimensions this app surfaces.
///
/// Watcher publishes about thirty. These are the observed ones — the family that needs
/// nothing from the user and improves on its own as the daemon keeps running. The
/// manual family is computed locally from `ProjectScore`, and the outcome family
/// (progress, finishability, momentum) is deliberately left out: it requires per
/// project scope declarations that do not exist for any project.
public enum MeasurementDimension: String, CaseIterable, Identifiable, Sendable {
    case investmentObserved = "investment_observed"
    case investment30d = "investment_30d"
    case activity7d = "activity_7d"
    case activity30d = "activity_30d"
    case activityAge = "activity_age"
    case consistency28d = "consistency_28d"
    case staleness
    case neglect

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .investmentObserved: return "Effort"
        case .investment30d: return "Effort 30d"
        case .activity7d: return "Active 7d"
        case .activity30d: return "Active 30d"
        case .activityAge: return "Last worked"
        case .consistency28d: return "Consistency"
        case .staleness: return "Staleness"
        case .neglect: return "Neglect"
        }
    }

    /// `activity_age` is in days; everything else here is a 0–100 score.
    public var isDuration: Bool { self == .activityAge }
}

/// Reads `/v1/scoring/*` from Better Workspace's background service.
///
/// Loopback only, and read-only: this app never writes to Watcher's databases, which
/// is the boundary its architecture depends on.
public actor MeasurementService {

    public static let shared = MeasurementService()

    /// Where the background service listens, when not the default loopback port.
    public static let defaultsBaseURLKey = "backgroundServiceURL"
    /// The same setting under the name it had before the service was adopted; still
    /// honoured so an existing override keeps working.
    public static let legacyDefaultsBaseURLKey = "watcherBaseURL"
    public static let defaultBaseURL = URL(string: "http://127.0.0.1:8765")!

    /// Whether the last attempt reached the daemon. `nil` before the first attempt.
    public private(set) var isReachable: Bool?
    public private(set) var lastRefreshed: Date?
    public private(set) var lastError: String?

    private var byWatcherID: [String: ProjectMeasurements] = [:]
    private var recentSessions: [WorkSession] = []

    public init() {}

    /// The service to call: `baseURL` when given, otherwise the configured one -- except
    /// that an isolated test run never reaches the real service. It answers `nil` there
    /// unless its launch names a service (`-backgroundServiceURL`), and callers treat
    /// that exactly like a service that could not be read.
    public static func serviceURL(_ baseURL: URL?) -> URL? {
        if let baseURL { return baseURL }
        if TestIsolation.isActive,
           TestIsolation.launchArgument(defaultsBaseURLKey) == nil,
           TestIsolation.launchArgument(legacyDefaultsBaseURLKey) == nil {
            return nil
        }
        return resolvedBaseURL()
    }

    public static func resolvedBaseURL(defaults: UserDefaults = .standard) -> URL {
        if let custom = defaults.string(forKey: defaultsBaseURLKey) ?? defaults.string(forKey: legacyDefaultsBaseURLKey),
           custom.isEmpty == false, let url = URL(string: custom) {
            return url
        }
        return defaultBaseURL
    }

    public func measurements(watcherID: String?) -> ProjectMeasurements? {
        guard let watcherID else { return nil }
        return byWatcherID[watcherID]
    }

    public func measurement(_ dimension: MeasurementDimension, watcherID: String?) -> MeasuredValue? {
        measurements(watcherID: watcherID)?.measurement(dimension)
    }

    public var projectCount: Int { byWatcherID.count }

    /// Completed sessions, newest first. Empty when the daemon is not running, which
    /// is a legitimate state — Overview falls back to filesystem timestamps.
    public func sessions(limit: Int = 20) -> [WorkSession] {
        Array(recentSessions.prefix(limit))
    }

    /// Fetches recent sessions. Fails quietly, like `refresh()`.
    @discardableResult
    public func refreshSessions(baseURL: URL? = nil, timeout: TimeInterval = 10) async -> Bool {
        #if DEBUG
        if let directory = BackgroundServiceClient.fixtureDirectory {
            guard let data = try? Data(contentsOf: directory.appendingPathComponent("v1_sessions.json")),
                  let sessions = try? Self.decodeSessions(data) else { return false }
            recentSessions = sessions
            return true
        }
        #endif
        guard let root = Self.serviceURL(baseURL) else { return false }
        let url = root.appendingPathComponent("v1/sessions")
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return false }
            recentSessions = try Self.decodeSessions(data)
            return true
        } catch {
            return false
        }
    }

    /// Watcher's project ids keyed by file identity (`device:inode`, the same form as
    /// `FileIdentity.key`), or `nil` when the daemon could not be read.
    ///
    /// Better Projects' documents carried these ids for the projects that existed when
    /// they were imported; this is how a project made since then gets joined.
    public func projectIDsByIdentityKey(baseURL: URL? = nil, timeout: TimeInterval = 10) async -> [String: String]? {
        #if DEBUG
        if let directory = BackgroundServiceClient.fixtureDirectory {
            guard let data = try? Data(contentsOf: directory.appendingPathComponent("v1_projects.json")) else { return nil }
            return try? Self.decodeProjectIdentities(data)
        }
        #endif
        guard let root = Self.serviceURL(baseURL) else { return nil }
        let url = root.appendingPathComponent("v1/projects")
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }
            return try Self.decodeProjectIdentities(data)
        } catch {
            return nil
        }
    }

    static func decodeProjectIdentities(_ data: Data) throws -> [String: String] {
        struct Envelope: Decodable {
            let data: [Row]
            struct Row: Decodable {
                let id: String
                let device: Int64?
                let inode: UInt64?
                let status: String?
            }
        }
        var out: [String: String] = [:]
        for row in try JSONDecoder().decode(Envelope.self, from: data).data {
            // A project Watcher has seen deleted can share an inode with whatever the
            // filesystem reused it for.
            guard row.status != "deleted", let device = row.device, let inode = row.inode else { continue }
            out[FileIdentity(volume: String(device), fileID: inode).key] = row.id
        }
        return out
    }

    /// Fetches every project's dimensions in one request.
    ///
    /// A daemon that is not running is an ordinary, expected state, not an error worth
    /// putting in front of anyone: the call fails quietly, `isReachable` becomes false,
    /// and whatever was last known is kept rather than being replaced with nothing.
    @discardableResult
    public func refresh(baseURL: URL? = nil, timeout: TimeInterval = 10) async -> Bool {
        #if DEBUG
        if let directory = BackgroundServiceClient.fixtureDirectory {
            do {
                byWatcherID = try Self.decode(Data(contentsOf: directory.appendingPathComponent("v1_scoring_projects.json")))
                isReachable = true; lastRefreshed = Date(); lastError = nil
                return true
            } catch {
                isReachable = false; lastError = error.localizedDescription
                return false
            }
        }
        #endif
        guard let root = Self.serviceURL(baseURL) else { return false }
        let url = root.appendingPathComponent("v1/scoring/projects")
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.httpMethod = "GET"

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                isReachable = false
                lastError = "The background service answered \(code)"
                return false
            }
            byWatcherID = try Self.decode(data)
            isReachable = true
            lastRefreshed = Date()
            lastError = nil
            return true
        } catch {
            isReachable = false
            lastError = error.localizedDescription
            return false
        }
    }

    // MARK: - Decoding

    private struct Envelope: Decodable {
        let data: Payload
        struct Payload: Decodable {
            let projects: [Project]
        }
        struct Project: Decodable {
            let id: String
            let name: String
            let dimensions: [String: Dimension]?
        }
        struct Dimension: Decodable {
            let value: Double?
            let raw_value: RawValue?
            let unit: String?
            let state: String?
            let explanation: String?
            let source: String?
            let formula_version: String?
            let window: Window?
        }
        /// Only `bound` matters here; any other shape is ignored rather than failing the decode.
        struct Window: Decodable {
            let bound: String?
            private enum Keys: String, CodingKey { case bound }
            init(from decoder: Decoder) throws {
                bound = (try? decoder.container(keyedBy: Keys.self)).flatMap { try? $0.decodeIfPresent(String.self, forKey: .bound) } ?? nil
            }
        }
        /// `raw_value` is a number for most dimensions and a breakdown object for the
        /// windowed ones. Only the number is meaningful here; anything else is dropped
        /// rather than being allowed to fail the whole decode.
        enum RawValue: Decodable {
            case number(Double)
            case other
            init(from decoder: Decoder) throws {
                let container = try decoder.singleValueContainer()
                if let value = try? container.decode(Double.self) { self = .number(value) } else { self = .other }
            }
            var number: Double? { if case let .number(value) = self { return value }; return nil }
        }
    }

    static func decode(_ data: Data) throws -> [String: ProjectMeasurements] {
        let envelope = try JSONDecoder().decode(Envelope.self, from: data)
        var out: [String: ProjectMeasurements] = [:]
        for project in envelope.data.projects {
            let dimensions = (project.dimensions ?? [:]).mapValues { raw in
                MeasuredValue(
                    dimension: "",
                    value: raw.value,
                    rawValue: raw.raw_value?.number,
                    unit: raw.unit,
                    // An unrecognized state is treated as unknown rather than guessed at.
                    state: raw.state.flatMap(MeasurementState.init(rawValue:)) ?? .unknown,
                    explanation: raw.explanation,
                    source: raw.source,
                    formulaVersion: raw.formula_version,
                    isLowerBound: raw.window?.bound == "lower"
                )
            }
            // Re-key so each measurement carries the dimension it belongs to.
            var named: [String: MeasuredValue] = [:]
            for (key, measurement) in dimensions {
                named[key] = MeasuredValue(
                    dimension: key, value: measurement.value, rawValue: measurement.rawValue,
                    unit: measurement.unit, state: measurement.state,
                    explanation: measurement.explanation, source: measurement.source,
                    formulaVersion: measurement.formulaVersion, isLowerBound: measurement.isLowerBound
                )
            }
            out[project.id] = ProjectMeasurements(watcherID: project.id, name: project.name, dimensions: named)
        }
        return out
    }
}

/// One observed work session, as the background service recorded it.
///
/// Only `completed` sessions are worth anything: Watcher marks a great many as
/// `discarded` because they were a file provider, a dev server heartbeat or a metadata
/// write rather than a person working, and counting those inflates everything.
public struct WorkSession: Sendable, Hashable, Identifiable {
    public let id: String
    public let projectID: String
    public let projectName: String
    public let startedAt: Date
    public let endedAt: Date
    public let activeSeconds: Double
    public let files: [String]
    public let gitBranch: String?
    public let gitSubject: String?

    public var activeHours: Double { activeSeconds / 3600 }

    /// The files worth naming when reminding someone where they were — not the
    /// bookkeeping another tool happened to write during the session.
    public var interestingFiles: [String] {
        files
            .map { ($0 as NSString).lastPathComponent }
            .filter { NoiseFilter.isForeignMetadata(name: $0) == false && $0.hasPrefix(".") == false }
    }
}

extension MeasurementService {

    private struct SessionEnvelope: Decodable {
        let data: [Row]
        struct Row: Decodable {
            let id: String
            let project_id: String
            let project_name: String
            let started_at: String
            let ended_at: String
            let active_seconds: Double
            let status: String
            let files_json: String?
            let git_json: String?
        }
    }

    /// Recently completed sessions, newest first.
    static func decodeSessions(_ data: Data) throws -> [WorkSession] {
        let envelope = try JSONDecoder().decode(SessionEnvelope.self, from: data)
        let full = ISO8601DateFormatter()
        full.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        func parse(_ raw: String) -> Date? { full.date(from: raw) ?? plain.date(from: raw) }

        return envelope.data.compactMap { row -> WorkSession? in
            guard row.status == "completed",
                  let started = parse(row.started_at), let ended = parse(row.ended_at)
            else { return nil }
            let files = row.files_json
                .flatMap { $0.data(using: .utf8) }
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String] } ?? []
            let git = row.git_json
                .flatMap { $0.data(using: .utf8) }
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
            return WorkSession(
                id: row.id, projectID: row.project_id, projectName: row.project_name,
                startedAt: started, endedAt: ended, activeSeconds: row.active_seconds,
                files: files,
                gitBranch: git["branch"] as? String,
                gitSubject: git["head_subject"] as? String
            )
        }
        .sorted { $0.endedAt > $1.endedAt }
    }
}
