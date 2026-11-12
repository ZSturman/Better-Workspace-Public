// Workspace Project Exchange, schema 1. Keep the Better Workspace (Sources/Core) and
// Finder Workspace Extensions (Sources/WorkspaceCore) copies byte-identical; check with
// Tools/check-exchange-contract.sh. Foundation only: no database, network or UI access.
// Each source alone writes its folder's snapshot and receipts: Better Workspace in
// `better-workspace` (projects, tasks, ideas), Finder Workspace Extensions in
// `finder-workspace` (project metadata it owns). Requesters only submit requests.
import Foundation
import Darwin

/// One lifecycle vocabulary for both apps. The stored status text (often a Notion
/// option) stays authoritative; this classification only drives badges, tags and filters.
public enum ExchangeLifecycle: String, Codable, CaseIterable, Sendable {
    case notSet, active, inProgress, backburner, maintained, blocked, needsReview, completed, archived

    public var title: String {
        switch self {
        case .notSet: "Not Set"; case .active: "Active"; case .inProgress: "In Progress"
        case .backburner: "Backburner"; case .maintained: "Maintained"; case .blocked: "Blocked"
        case .needsReview: "Needs Review"; case .completed: "Completed"; case .archived: "Archived"
        }
    }

    /// What each choice means, for menus and help text.
    public var meaning: String {
        switch self {
        case .notSet: "No lifecycle chosen yet."
        case .active: "In the current rotation."
        case .inProgress: "Being worked on now."
        case .backburner: "Not being worked on now; planned for when there is time."
        case .maintained: "Complete, with occasional maintenance and updates."
        case .blocked: "Waiting on something outside the project."
        case .needsReview: "Needs a decision or a look before continuing."
        case .completed: "Finished; no ongoing work expected."
        case .archived: "Closed, abandoned or superseded."
        }
    }

    /// Classifies free status text. `nil` means the text is present but unrecognized,
    /// so callers can show it verbatim instead of guessing.
    public static func classify(_ raw: String?) -> ExchangeLifecycle? {
        guard let raw = ExchangeText.clean(raw) else { return .notSet }
        let value = raw.lowercased()
        if let exact = allCases.first(where: { $0.title.lowercased() == value || $0.rawValue.lowercased() == value }) { return exact }
        let words = " " + value.map { $0.isLetter || $0.isNumber ? $0 : " " }.split(separator: " ").joined(separator: " ") + " "
        func has(_ phrases: [String]) -> Bool { phrases.contains { words.contains(" " + $0) } }
        // Order matters: "completed – maintained" is maintained, "abandoned" is not done.
        if has(["not set", "unset", "none", "untriaged"]) { return .notSet }
        if has(["block", "waiting on", "stuck"]) { return .blocked }
        if has(["review", "needs decision", "triage"]) { return .needsReview }
        if has(["maintain", "maintenance", "support", "sustain", "evergreen", "shipped", "released", "live"]) { return .maintained }
        if has(["back burner", "backburner", "pause", "on hold", "hold", "someday", "dormant", "parked", "shelved", "backlog", "idea", "planned", "not started", "later", "inactive"]) { return .backburner }
        if has(["archiv", "abandon", "cancel", "deprecat", "supersed", "retired", "dropped", "closed", "obsolete"]) { return .archived }
        if has(["incomplete", "in progress", "doing", "in development", "developing", "building", "wip", "working", "underway"]) { return .inProgress }
        if has(["complete", "done", "finished"]) { return .completed }
        if has(["active", "current", "ongoing", "open", "started"]) { return .active }
        return nil
    }

    /// The text to store for this lifecycle: an option the person already uses when one
    /// means the same thing (for example a Notion "Paused" for Backburner), else the title.
    public func preferredText(options: [String]) -> String? {
        guard self != .notSet else { return nil }
        let cleaned = options.compactMap(ExchangeText.clean)
        return cleaned.first { $0.caseInsensitiveCompare(title) == .orderedSame }
            ?? cleaned.first { Self.classify($0) == self } ?? title
    }
}

public enum ExchangeText {
    public static let maximumBytes = 512
    public static func clean(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }
    public static func valid(_ value: String?) -> Bool {
        guard let value else { return true }
        return value.utf8.count <= maximumBytes && !value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }
}

public struct ExchangeTask: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    /// Opaque source revision; echo it unchanged in an `ExchangeTaskChange`.
    public var revision: String
    public var title: String
    /// `open`, `in-progress` or `completed`.
    public var status: String
    public var stage: String?
    public var priority: String?
    public var dueDate: Date?
    public init(id: String, revision: String, title: String, status: String, stage: String? = nil, priority: String? = nil, dueDate: Date? = nil) {
        self.id = id; self.revision = revision; self.title = title; self.status = status
        self.stage = stage; self.priority = priority; self.dueDate = dueDate
    }
}

public enum ExchangeField: String, Codable, CaseIterable, Sendable {
    case status, phase, domain, maintenanceCadence, completionModel, statusDetail, portfolioPriority
}

public struct ExchangeProject: Codable, Sendable, Equatable, Identifiable {
    /// The source project id. Stable across renames and moves.
    public var id: String
    /// Changes whenever any published field changes.
    public var revision: String
    public var path: String
    /// `<volume>:<fileID>`; volumes may be device numbers or `uuid-…` values.
    public var identityKey: String?
    public var name: String
    public var notionLinked: Bool
    public var status: String?
    public var lifecycle: ExchangeLifecycle?
    public var phase: String?
    public var domain: String?
    public var maintenanceCadence: String?
    public var completionModel: String?
    public var projectType: String?
    public var statusDetail: String?
    /// 1 (someday) … 5 (critical); `nil` is untriaged.
    public var portfolioPriority: Int?
    /// The source's configured project score, on a 0…100 scale.
    public var score: Double?
    public var blockers: [String]
    public var currentWork: [String]
    public var nextWork: [String]
    public var lastUpdateAt: Date?
    public var openTaskCount: Int
    /// A bounded page of the project's open tasks, most actionable first.
    public var tasks: [ExchangeTask]

    public init(id: String, path: String, name: String, identityKey: String? = nil, notionLinked: Bool = false,
                status: String? = nil, phase: String? = nil, domain: String? = nil, maintenanceCadence: String? = nil,
                completionModel: String? = nil, projectType: String? = nil, statusDetail: String? = nil,
                portfolioPriority: Int? = nil, blockers: [String] = [], currentWork: [String] = [], nextWork: [String] = [],
                lastUpdateAt: Date? = nil, openTaskCount: Int = 0, tasks: [ExchangeTask] = [], score: Double? = nil) {
        self.id = id; self.path = path; self.name = name; self.identityKey = identityKey; self.notionLinked = notionLinked
        self.status = status; self.phase = phase; self.domain = domain; self.maintenanceCadence = maintenanceCadence
        self.completionModel = completionModel; self.projectType = projectType; self.statusDetail = statusDetail
        self.portfolioPriority = portfolioPriority; self.blockers = blockers; self.currentWork = currentWork
        self.nextWork = nextWork; self.lastUpdateAt = lastUpdateAt; self.openTaskCount = openTaskCount; self.tasks = tasks
        self.score = score
        revision = ""
        seal()
    }

    /// Recomputes derived values after editing fields; call before publishing.
    public mutating func seal() {
        lifecycle = ExchangeLifecycle.classify(status)
        revision = Self.fingerprint(self)
    }

    /// Editable values as the exchange compares them.
    public func value(_ field: ExchangeField) -> String? {
        switch field {
        case .status: ExchangeText.clean(status)
        case .phase: ExchangeText.clean(phase)
        case .domain: ExchangeText.clean(domain)
        case .maintenanceCadence: ExchangeText.clean(maintenanceCadence)
        case .completionModel: ExchangeText.clean(completionModel)
        case .statusDetail: ExchangeText.clean(statusDetail)
        case .portfolioPriority: portfolioPriority.map(String.init)
        }
    }

    public static func fingerprint(_ project: ExchangeProject) -> String {
        var copy = project; copy.revision = ""
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; encoder.dateEncodingStrategy = .secondsSince1970
        let data = (try? encoder.encode(copy)) ?? Data()
        // FNV-1a keeps the contract Foundation-only; this detects change, it is not security.
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in data { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
        return String(format: "%016llx", hash)
    }
}

public struct ExchangeNotionState: Codable, Sendable, Equatable {
    public var configured: Bool
    public var summary: String
    /// `status` properties reject unknown options; `select` properties create them.
    public var statusPropertyKind: String?
    public init(configured: Bool, summary: String, statusPropertyKind: String? = nil) {
        self.configured = configured; self.summary = summary; self.statusPropertyKind = statusPropertyKind
    }
}

/// Read-only idea folder labels from Better Workspace’s existing service projection.
public struct ExchangeIdeaFacts: Codable, Sendable, Equatable {
    public var domain: String?
    public var status: String?
    public var priority: Int?
    public var score: Double?
    /// Absent until an indexed task explicitly links to this idea's path.
    public var openTaskCount: Int?
    public init(domain: String?, status: String?, priority: Int? = nil, score: Double? = nil, openTaskCount: Int? = nil) {
        self.domain = ExchangeText.clean(domain)
        self.status = ExchangeText.clean(status)
        self.priority = priority; self.score = score; self.openTaskCount = openTaskCount
    }
}

public struct ExchangeSnapshot: Codable, Sendable, Equatable {
    public static let schema = 1
    public static let lifetime: TimeInterval = 900
    public var schemaVersion = ExchangeSnapshot.schema
    public var sourceID: String
    public var generatedAt: Date
    public var expiresAt: Date
    public var workspaceRoot: String?
    public var notion: ExchangeNotionState
    public var statusOptions: [String]
    public var phaseOptions: [String]
    public var domainOptions: [String]
    public var projects: [ExchangeProject]
    /// Absolute folder paths. Omitted when the source has no complete idea read.
    public var ideaFolders: [String: ExchangeIdeaFacts]?
    public init(sourceID: String = "better-workspace", generatedAt: Date = Date(), workspaceRoot: String?, notion: ExchangeNotionState,
                statusOptions: [String], phaseOptions: [String], domainOptions: [String], projects: [ExchangeProject],
                ideaFolders: [String: ExchangeIdeaFacts]? = nil) {
        self.sourceID = sourceID; self.generatedAt = generatedAt; expiresAt = generatedAt.addingTimeInterval(Self.lifetime)
        self.workspaceRoot = workspaceRoot; self.notion = notion; self.statusOptions = statusOptions
        self.phaseOptions = phaseOptions; self.domainOptions = domainOptions; self.projects = projects
        self.ideaFolders = ideaFolders
    }
    public func isCurrent(at now: Date = Date()) -> Bool { now < expiresAt && now.timeIntervalSince(generatedAt) > -60 }
}

/// One field edit. `base` is the value the requester last saw; the source applies the
/// edit only while its current value still equals `base` (or already equals `value`).
public struct ExchangeChange: Codable, Sendable, Equatable {
    public var field: ExchangeField
    public var base: String?
    public var value: String?
    public init(field: ExchangeField, base: String?, value: String?) {
        self.field = field; self.base = ExchangeText.clean(base); self.value = ExchangeText.clean(value)
    }
}

public struct ExchangeTaskChange: Codable, Sendable, Equatable {
    public var taskID: String
    public var revision: String
    public var status: String
    public init(taskID: String, revision: String, status: String) { self.taskID = taskID; self.revision = revision; self.status = status }
}

public struct ExchangeRequest: Codable, Sendable, Equatable, Identifiable {
    public static let maximumBytes = 16_384
    public var schemaVersion = ExchangeSnapshot.schema
    public var id: UUID
    public var issuedAt: Date
    public var requesterID: String
    public var projectID: String
    public var projectPath: String
    public var changes: [ExchangeChange]
    public var task: ExchangeTaskChange?
    public init(id: UUID = UUID(), issuedAt: Date = Date(), requesterID: String, projectID: String, projectPath: String,
                changes: [ExchangeChange] = [], task: ExchangeTaskChange? = nil) {
        self.id = id; self.issuedAt = issuedAt; self.requesterID = requesterID; self.projectID = projectID
        self.projectPath = projectPath; self.changes = changes; self.task = task
    }

    /// Structural checks only; the source still re-reads and compares current values.
    public func validate(now: Date = Date()) throws {
        guard schemaVersion == ExchangeSnapshot.schema else { throw ExchangeError.unsupported }
        guard issuedAt.timeIntervalSince(now) < 300, now.timeIntervalSince(issuedAt) < 30 * 86_400 else { throw ExchangeError.expired }
        guard !changes.isEmpty || task != nil, changes.count <= ExchangeField.allCases.count,
              Set(changes.map(\.field)).count == changes.count,
              !requesterID.isEmpty, requesterID.utf8.count <= 128, !projectID.isEmpty, projectID.utf8.count <= 128,
              projectPath.hasPrefix("/"), projectPath.utf8.count <= 4096,
              changes.allSatisfy({ ExchangeText.valid($0.base) && ExchangeText.valid($0.value) }) else { throw ExchangeError.invalid }
        for change in changes where change.field == .portfolioPriority {
            if let value = change.value { guard let number = Int(value), (1...5).contains(number) else { throw ExchangeError.invalid } }
        }
        if let task {
            guard !task.taskID.isEmpty, task.taskID.utf8.count <= 256, task.revision.utf8.count <= 128,
                  ["open", "in-progress", "completed"].contains(task.status) else { throw ExchangeError.invalid }
        }
    }
}

public struct ExchangeReceipt: Codable, Sendable, Equatable, Identifiable {
    public enum Outcome: String, Codable, Sendable { case applied, unchanged, conflict, rejected }
    public var schemaVersion = ExchangeSnapshot.schema
    public var id: UUID { requestID }
    public var requestID: UUID
    public var projectID: String
    public var outcome: Outcome
    public var message: String
    public var conflicts: [ExchangeField]
    public var warnings: [String]
    /// The source's current project after processing, when it still exists.
    public var project: ExchangeProject?
    public var processedAt: Date
    public init(requestID: UUID, projectID: String, outcome: Outcome, message: String, conflicts: [ExchangeField] = [],
                warnings: [String] = [], project: ExchangeProject? = nil, processedAt: Date = Date()) {
        self.requestID = requestID; self.projectID = projectID; self.outcome = outcome; self.message = message
        self.conflicts = conflicts; self.warnings = warnings; self.project = project; self.processedAt = processedAt
    }
}

/// Per-field three-way comparison. A request is all-or-nothing: one conflicting field
/// rejects the whole edit, so a person never gets half of what they chose.
public enum ExchangeMerge {
    public struct Plan: Equatable, Sendable {
        public var updates: [ExchangeField: String?] = [:]
        public var conflicts: [ExchangeField] = []
        public var outcome: ExchangeReceipt.Outcome {
            !conflicts.isEmpty ? .conflict : updates.isEmpty ? .unchanged : .applied
        }
    }
    public static func plan(_ changes: [ExchangeChange], current: (ExchangeField) -> String?) -> Plan {
        var plan = Plan()
        for change in changes {
            let now = ExchangeText.clean(current(change.field))
            if now == change.value { continue }
            if now == change.base { plan.updates[change.field] = .some(change.value) } else { plan.conflicts.append(change.field) }
        }
        if !plan.conflicts.isEmpty { plan.updates = [:] }
        return plan
    }
}

public enum ExchangeError: LocalizedError, Sendable, Equatable {
    case unsupported, expired, invalid, unavailable
    public var errorDescription: String? {
        switch self {
        case .unsupported: "This exchange file uses an unsupported schema."
        case .expired: "This exchange request is too old or dated in the future."
        case .invalid: "This exchange file is invalid, oversized or symbolic."
        case .unavailable: "The exchange folder is unavailable."
        }
    }
}

/// `~/Library/Application Support/WorkspaceExchange/v1/<source>`, owner-only (0700):
/// `projects.json` (source writes), `requests/` (requesters write), `processing/` and
/// `receipts/` (source writes). Every read refuses symbolic links and oversized files.
public struct ExchangeFiles: Sendable {
    public static let snapshotNotification = "com.zacharysturman.WorkspaceExchange.snapshot.v1"
    public static let requestNotification = "com.zacharysturman.WorkspaceExchange.request.v1"
    public static let maximumSnapshotBytes = 8 * 1_048_576
    public static let maximumReceiptBytes = 262_144
    public let directory: URL
    public init(directory: URL) { self.directory = directory.standardizedFileURL }
    public static func standard(source: String = "better-workspace") -> ExchangeFiles {
        let base = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support/WorkspaceExchange/v1", isDirectory: true)
        return ExchangeFiles(directory: base.appendingPathComponent(source, isDirectory: true))
    }
    public var snapshotURL: URL { directory.appendingPathComponent("projects.json") }
    var requests: URL { directory.appendingPathComponent("requests", isDirectory: true) }
    var processing: URL { directory.appendingPathComponent("processing", isDirectory: true) }
    var receipts: URL { directory.appendingPathComponent("receipts", isDirectory: true) }

    public func prepare() throws {
        for url in [directory, requests, processing, receipts] {
            var info = stat()
            if lstat(url.path, &info) == 0 {
                guard info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid() else { throw ExchangeError.unavailable }
            } else {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            }
            chmod(url.path, 0o700)
        }
    }

    // MARK: Source side

    public func writeSnapshot(_ snapshot: ExchangeSnapshot) throws {
        try prepare()
        let data = try Self.encoder.encode(snapshot)
        guard data.count <= Self.maximumSnapshotBytes else { throw ExchangeError.invalid }
        try data.write(to: snapshotURL, options: .atomic)
    }
    /// Pending request ids, oldest first, bounded so a flood cannot stall the source.
    public func pendingRequests(limit: Int = 50) -> [UUID] { Self.ids(in: requests, limit: limit) }
    /// Claimed but unreceipted requests, e.g. after a crash mid-apply.
    public func claimedRequests(limit: Int = 50) -> [UUID] { Self.ids(in: processing, limit: limit) }
    /// Atomically takes a request; `nil` when the requester cancelled it or another
    /// pass already claimed it.
    public func claim(_ id: UUID) -> ExchangeRequest? {
        let source = requests.appendingPathComponent(id.uuidString + ".json"), target = processing.appendingPathComponent(id.uuidString + ".json")
        guard rename(source.path, target.path) == 0 else { return nil }
        return claimed(id)
    }
    public func claimed(_ id: UUID) -> ExchangeRequest? {
        let url = processing.appendingPathComponent(id.uuidString + ".json")
        guard let data = try? Self.bounded(url, maximum: ExchangeRequest.maximumBytes),
              let request = try? Self.decoder.decode(ExchangeRequest.self, from: data), request.id == id else {
            unlink(url.path); return nil
        }
        return request
    }
    public func hasReceipt(_ id: UUID) -> Bool { FileManager.default.fileExists(atPath: receipts.appendingPathComponent(id.uuidString + ".json").path) }
    /// Writes the receipt before releasing the claim, so a crash between them repeats
    /// only an idempotent comparison, never an unreceipted edit.
    public func finish(_ receipt: ExchangeReceipt) throws {
        try prepare()
        try Self.encoder.encode(receipt).write(to: receipts.appendingPathComponent(receipt.requestID.uuidString + ".json"), options: .atomic)
        unlink(processing.appendingPathComponent(receipt.requestID.uuidString + ".json").path)
    }
    public func release(_ id: UUID) { unlink(processing.appendingPathComponent(id.uuidString + ".json").path) }
    /// Removes receipts nobody collected within `age`.
    public func pruneReceipts(olderThan age: TimeInterval = 7 * 86_400, now: Date = Date()) {
        for url in (try? FileManager.default.contentsOfDirectory(at: receipts, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] {
            if let date = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, now.timeIntervalSince(date) > age { unlink(url.path) }
        }
    }

    // MARK: Requester side

    public func readSnapshot() throws -> ExchangeSnapshot {
        let snapshot = try Self.decoder.decode(ExchangeSnapshot.self, from: Self.bounded(snapshotURL, maximum: Self.maximumSnapshotBytes))
        guard snapshot.schemaVersion == ExchangeSnapshot.schema else { throw ExchangeError.unsupported }
        return snapshot
    }
    public func submit(_ request: ExchangeRequest) throws {
        try request.validate()
        try prepare()
        let data = try Self.encoder.encode(request)
        guard data.count <= ExchangeRequest.maximumBytes else { throw ExchangeError.invalid }
        // Written aside and renamed in, so the source never claims a partial file.
        let temporary = requests.appendingPathComponent("." + request.id.uuidString + ".tmp")
        try data.write(to: temporary, options: .withoutOverwriting)
        guard rename(temporary.path, requests.appendingPathComponent(request.id.uuidString + ".json").path) == 0 else {
            unlink(temporary.path); throw ExchangeError.unavailable
        }
    }
    /// True when the request was withdrawn before the source claimed it.
    public func cancel(_ id: UUID) -> Bool { unlink(requests.appendingPathComponent(id.uuidString + ".json").path) == 0 }
    public func isPending(_ id: UUID) -> Bool {
        [requests, processing].contains { FileManager.default.fileExists(atPath: $0.appendingPathComponent(id.uuidString + ".json").path) }
    }
    public func receipt(_ id: UUID) -> ExchangeReceipt? {
        guard let data = try? Self.bounded(receipts.appendingPathComponent(id.uuidString + ".json"), maximum: Self.maximumReceiptBytes) else { return nil }
        return try? Self.decoder.decode(ExchangeReceipt.self, from: data)
    }
    public func removeReceipt(_ id: UUID) { unlink(receipts.appendingPathComponent(id.uuidString + ".json").path) }

    // MARK: Shared

    /// ISO 8601 with fractional seconds, so dates survive a round trip unchanged.
    static let encoder: JSONEncoder = {
        let value = JSONEncoder(); value.outputFormatting = [.sortedKeys]
        value.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(date.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true)))
        }
        return value
    }()
    static let decoder: JSONDecoder = {
        let value = JSONDecoder()
        value.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            if let date = try? Date(text, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)) { return date }
            if let date = try? Date(text, strategy: Date.ISO8601FormatStyle()) { return date }
            throw ExchangeError.invalid
        }
        return value
    }()

    static func ids(in folder: URL, limit: Int) -> [UUID] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles])) ?? []
        return urls.filter { $0.pathExtension == "json" }
            .compactMap { url -> (UUID, Date)? in
                guard let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent) else { return nil }
                return (id, (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
            }
            .sorted { $0.1 == $1.1 ? $0.0.uuidString < $1.0.uuidString : $0.1 < $1.1 }
            .prefix(max(0, limit)).map(\.0)
    }

    static func bounded(_ url: URL, maximum: Int) throws -> Data {
        let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw ExchangeError.unavailable }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(), info.st_size <= maximum else { throw ExchangeError.invalid }
        let data = try handle.read(upToCount: maximum + 1) ?? Data()
        guard data.count <= maximum else { throw ExchangeError.invalid }
        return data
    }
}
