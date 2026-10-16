import Foundation

public struct WidgetCommandRecord: Identifiable, Sendable {
    public enum State: String, Codable, Sendable { case queued, sending, delivered, applied, rejected, cancelled }
    public let intent: MobileWorkspaceIntent
    public let stream: String
    public let state: State
    public let message: String?
    public let appliedAt: Date?
    public let workModifiedAt: Date?
    public let settled: Bool
    public var id: UUID { intent.id }
    public var edit: MobilePlanningEdit? { intent.planningEdit }
    public var target: String { WidgetCommandStore.target(intent) }
    public var pending: Bool { state == .queued || state == .sending || (state == .delivered && edit != nil) }
    public var label: String {
        switch state {
        case .queued: return "Saved · waiting to send"
        case .sending: return "Sending to Mac"
        case .delivered: return "Waiting for Mac"
        case .applied: return "Applied on Mac"
        case .rejected: return message ?? "Mac refused this change"
        case .cancelled: return "Cancelled"
        }
    }
}

public struct WidgetConfirmation: Codable, Sendable {
    public var id: UUID
    public var scope: String
    public var edit: MobilePlanningEdit
    public var expiresAt: Date
}

public enum WidgetCommandError: LocalizedError {
    case message(String), waitingForCapture, waitingForIdeaService
    public var errorDescription: String? {
        switch self {
        case .message(let text): return text
        case .waitingForIdeaService: return "The folder moved. Waiting for the updated idea service to acknowledge its metadata."
        case .waitingForCapture: return "Waiting for the complete capture to arrive on Mac."
        }
    }
}

/// WAL transactions serialize app and extension writes. The ledger holds explicit
/// commands/drafts only; it never becomes an index of organized user content.
public final class WidgetCommandStore: @unchecked Sendable {
    private let database: Database
    public let directory: URL
    public static func shared(appGroup: String) -> WidgetCommandStore? {
        guard let directory = DashboardWidgetStore.directory(appGroup: appGroup) else { return nil }
        return try? WidgetCommandStore(directory: directory)
    }
    public init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        database = try Database(url: directory.appendingPathComponent("commands.sqlite"))
        try database.execute("""
        CREATE TABLE IF NOT EXISTS widget_commands (
          id TEXT PRIMARY KEY, stream TEXT NOT NULL, target TEXT NOT NULL, payload TEXT NOT NULL,
          state TEXT NOT NULL, message TEXT, created REAL NOT NULL, applied REAL, work_modified REAL, settled INTEGER NOT NULL DEFAULT 0
        );
        CREATE TABLE IF NOT EXISTS widget_state (key TEXT PRIMARY KEY, value TEXT NOT NULL);
        CREATE INDEX IF NOT EXISTS widget_command_queue ON widget_commands(stream, state, created);
        """)
        try ensureResultColumn()
    }
    private func ensureResultColumn() throws {
        let columns = try database.query("PRAGMA table_info(widget_commands)", row: { $0.string(1) })
        if !columns.contains("work_modified") { try database.execute("ALTER TABLE widget_commands ADD COLUMN work_modified REAL") }
    }
    public static func target(_ intent: MobileWorkspaceIntent) -> String {
        if let edit = intent.planningEdit {
            if let item = edit.inboxReview?.item { return "review:\(item.id)" }
            if let idea = edit.originalIdea, edit.operation == .saveIdeaPlanning || edit.operation == .promoteIdea { return "idea:" + (idea.serviceID ?? idea.path) }
            if let project = edit.projectEdit?.original { return "project:\(project.projectID ?? project.path)" }
            if let capture = edit.captureReview?.capture { return "capture:\(capture.name)" }
            if let capture = edit.captureFiling?.capture { return "capture:\(capture.name)" }
            if let work = edit.work ?? edit.originalWork { return "task:\(work.id)" }
            return "draft:\(edit.id)"
        }
        return intent.captureName.map { "capture:\($0)" } ?? "intent:\(intent.id)"
    }
    public func records(stream: String? = nil) throws -> [WidgetCommandRecord] {
        let sql = "SELECT payload,stream,state,message,applied,settled,work_modified FROM widget_commands" + (stream == nil ? "" : " WHERE stream=?") + " ORDER BY created,id"
        return try database.query(sql, stream.map { [.text($0)] } ?? []) { row -> WidgetCommandRecord? in
            guard let data = row.string(0).data(using: .utf8), let intent = try? JSONDecoder().decode(MobileWorkspaceIntent.self, from: data),
                  let state = WidgetCommandRecord.State(rawValue: row.string(2)) else { return nil }
            return WidgetCommandRecord(intent: intent, stream: row.string(1), state: state, message: row.optionalString(3),
                appliedAt: row.optionalDouble(4).map(Date.init(timeIntervalSince1970:)), workModifiedAt: row.optionalDouble(6).map(Date.init(timeIntervalSinceReferenceDate:)), settled: row.int(5) != 0)
        }.compactMap { $0 }
    }
    @discardableResult
    public func append(_ intent: MobileWorkspaceIntent, stream: String = "workspace", coalesce: Bool = false) throws -> UUID {
        if let edit = intent.planningEdit { try MobilePlanningFiles.validate(edit) }
        return try database.transaction {
            try database.run("DELETE FROM widget_commands WHERE settled=1 AND state IN ('delivered','applied','rejected','cancelled') AND created<?", [.double(Date().addingTimeInterval(-14 * 86400).timeIntervalSince1970)])
            if try records().contains(where: { $0.id == intent.id }) { return intent.id }
            if coalesce, let existing = try records().first(where: { $0.target == Self.target(intent) && $0.pending }) { return existing.id }
            guard try records().filter({ $0.pending }).count < MobileIntentOutbox.capacity else { throw WidgetCommandError.message("Let the Mac apply your waiting changes before adding more.") }
            let data = try JSONEncoder().encode(intent)
            guard data.count < 256 * 1024, let json = String(data: data, encoding: .utf8) else { throw WidgetCommandError.message("This command is too large.") }
            try database.run("INSERT OR IGNORE INTO widget_commands(id,stream,target,payload,state,created) VALUES(?,?,?,?,?,?)",
                [.text(intent.id.uuidString), .text(stream), .text(Self.target(intent)), .text(json), .text("queued"), .double(intent.createdAt.timeIntervalSince1970)])
            return intent.id
        }
    }
    public func delivered(_ ids: Set<UUID>) throws {
        try database.transaction {
            let all = try records()
            for id in ids {
                let settled = all.first { $0.id == id }?.edit == nil
                try database.run("UPDATE widget_commands SET state='delivered',settled=? WHERE id=? AND state IN ('queued','sending')", [.int(settled ? 1 : 0), .text(id.uuidString)])
            }
        }
    }
    public func beginDelivery(stream: String) throws -> Bool {
        guard try claim("delivery:" + stream, seconds: 60) else { return false }
        try database.run("UPDATE widget_commands SET state='queued' WHERE stream=? AND state='sending'", [.text(stream)])
        return true
    }
    public func beginSending(_ id: UUID) throws -> Bool {
        try database.run("UPDATE widget_commands SET state='sending' WHERE id=? AND state='queued'", [.text(id.uuidString)]) > 0
    }
    public func retry(_ id: UUID) throws {
        try database.run("UPDATE widget_commands SET state='queued' WHERE id=? AND state='sending'", [.text(id.uuidString)])
    }
    public func receipt(id: UUID, applied: Bool, message: String? = nil, workModifiedAt: Date? = nil, now: Date = Date()) throws {
        try database.run("UPDATE widget_commands SET state=?,message=?,applied=COALESCE(applied,?),work_modified=COALESCE(?,work_modified) WHERE id=? AND state!='cancelled'",
            [.text(applied ? "applied" : "rejected"), message.map(Database.Value.text) ?? .null,
             applied ? .double(now.timeIntervalSince1970) : .null, workModifiedAt.map { .double($0.timeIntervalSinceReferenceDate) } ?? .null, .text(id.uuidString)])
    }
    public func settle(_ ids: Set<UUID>) throws {
        try database.transaction {
            for id in ids { try database.run("UPDATE widget_commands SET settled=1 WHERE id=?", [.text(id.uuidString)]) }
        }
    }
    /// Stop overlaying an applied command once its own source has caught up. Review
    /// timestamps come from Mac; a fetch time alone does not prove a fresh queue.
    public func reconcile(_ source: WorkspaceDashboardSnapshot) throws {
        try database.transaction {
            var ids = Set<UUID>()
            for record in try records() where record.state == .applied && !record.settled {
                guard let applied = record.appliedAt, source.updatedAt >= applied, let edit = record.edit else { continue }
                if edit.inboxReview != nil, let checked = source.reviewCheckedAt, checked >= applied {
                    ids.insert(record.id)
                } else if let filing = edit.captureFiling, let checked = source.captureUpdatedAt, checked >= applied,
                          !source.captures.contains(where: { $0.name == filing.capture.name && $0.modified == filing.capture.modified }) {
                    ids.insert(record.id)
                } else if let original = edit.originalWork, edit.operation == .saveWork,
                          !source.work.contains(where: { $0.id == original.id && $0.modifiedAt == original.modifiedAt }) {
                    ids.insert(record.id)
                }
            }
            for id in ids { try database.run("UPDATE widget_commands SET settled=1 WHERE id=?", [.text(id.uuidString)]) }
        }
    }
    public func cancelUnsent(_ id: UUID) throws -> Bool {
        try database.run("UPDATE widget_commands SET state='cancelled',settled=1 WHERE id=? AND state='queued'", [.text(id.uuidString)]) > 0
    }
    public func value<Value: Decodable>(_ key: String, as type: Value.Type) throws -> Value? {
        guard let string = try database.query("SELECT value FROM widget_state WHERE key=?", [.text(key)], row: { $0.string(0) }).first,
              let data = string.data(using: .utf8) else { return nil }
        return try JSONDecoder().decode(type, from: data)
    }
    public func set<Value: Encodable>(_ key: String, _ value: Value) throws {
        let json = String(data: try JSONEncoder().encode(value), encoding: .utf8)!
        try database.run("INSERT INTO widget_state(key,value) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", [.text(key), .text(json)])
    }
    public func clear(_ key: String) throws { try database.run("DELETE FROM widget_state WHERE key=?", [.text(key)]) }
    public func claim(_ key: String, seconds: TimeInterval = 30, now: Date = Date()) throws -> Bool {
        try database.transaction {
            let deadline = try value("lease:" + key, as: Date.self) ?? .distantPast
            guard deadline <= now else { return false }
            try set("lease:" + key, now.addingTimeInterval(seconds)); return true
        }
    }
    public func release(_ key: String) throws { try clear("lease:" + key) }
    @discardableResult
    public func stage(scope: String, edit: MobilePlanningEdit, now: Date = Date()) throws -> WidgetConfirmation {
        try MobilePlanningFiles.validate(edit)
        if let review = edit.inboxReview, review.action != .snooze, review.action != .prioritize, review.item.fingerprint?.isEmpty != false {
            throw WidgetCommandError.message("Refresh the review preview on Mac before deciding this item.")
        }
        let confirmation = WidgetConfirmation(id: UUID(), scope: scope, edit: edit, expiresAt: now.addingTimeInterval(300))
        try set("confirmation:" + scope, confirmation); return confirmation
    }
    public func confirmation(scope: String, now: Date = Date()) throws -> WidgetConfirmation? {
        guard let value = try value("confirmation:" + scope, as: WidgetConfirmation.self), value.expiresAt > now else { return nil }
        return value
    }
    /// Comparing the token prevents a delayed tap from confirming a newly shown item.
    @discardableResult
    public func confirm(scope: String, token: UUID, now: Date = Date(), stream: String = "workspace") throws -> UUID {
        // append uses its own immediate transaction; perform insertion here directly.
        try database.transaction {
            guard let confirmation = try confirmation(scope: scope, now: now), confirmation.id == token else {
                throw WidgetCommandError.message("This preview expired or changed. Choose the action again.")
            }
            let intent = MobileWorkspaceIntent.planning(confirmation.edit)
            let pending = try records().filter { $0.pending }
            let id: UUID
            if let existing = pending.first(where: { $0.target == Self.target(intent) }) { id = existing.id }
            else {
                guard pending.count < MobileIntentOutbox.capacity else { throw WidgetCommandError.message("The action queue is full.") }
                let json = String(data: try JSONEncoder().encode(intent), encoding: .utf8)!
                try database.run("INSERT OR IGNORE INTO widget_commands(id,stream,target,payload,state,created) VALUES(?,?,?,?,?,?)", [.text(intent.id.uuidString), .text(stream), .text(Self.target(intent)), .text(json), .text("queued"), .double(now.timeIntervalSince1970)])
                id = intent.id
            }
            try clear("confirmation:" + scope); return id
        }
    }
    public func migrate(defaults: UserDefaults, outboxKey: String, stream: String, planning: Bool = false) throws {
        let marker = "migration:" + stream
        try database.transaction {
            guard try value(marker, as: Bool.self) != true else { return }
            var intents = defaults.data(forKey: outboxKey).flatMap { try? JSONDecoder().decode([MobileWorkspaceIntent].self, from: $0) } ?? []
            let drafts = planning ? defaults.data(forKey: "BWMobilePlanningDrafts").flatMap { try? JSONDecoder().decode([MobilePlanningEdit].self, from: $0) } ?? [] : []
            let queued = Set(intents.map(\.id))
            intents += drafts.filter { !queued.contains($0.id) }.map(MobileWorkspaceIntent.planning)
            let errors = defaults.dictionary(forKey: "BWMobilePlanningErrors") as? [String: String] ?? [:]
            let applied = defaults.dictionary(forKey: "BWPlanningAppliedAt") as? [String: Double] ?? [:]
            for intent in intents {
                let json = String(data: try JSONEncoder().encode(intent), encoding: .utf8)!
                try database.run("INSERT OR IGNORE INTO widget_commands(id,stream,target,payload,state,message,created,applied) VALUES(?,?,?,?,?,?,?,?)", [.text(intent.id.uuidString), .text(stream), .text(Self.target(intent)), .text(json),
                    .text(errors[intent.id.uuidString] != nil ? "rejected" : applied[intent.id.uuidString] != nil ? "applied" : "queued"),
                    errors[intent.id.uuidString].map(Database.Value.text) ?? .null, .double(intent.createdAt.timeIntervalSince1970), applied[intent.id.uuidString].map(Database.Value.double) ?? .null])
            }
            try set(marker, true)
        }
        // Leave legacy bytes intact as a recovery source; the marker prevents replay.
    }
    public func overlay(_ source: WorkspaceDashboardSnapshot) throws -> WorkspaceDashboardSnapshot {
        var snapshot = source
        for record in try records() where !record.settled && record.state != .rejected && record.state != .cancelled {
            guard let edit = record.edit else { continue }
            if let command = edit.inboxReview {
                if record.state == .applied && command.action == .snooze && (command.until ?? .distantFuture) <= Date() { continue }
                let before = snapshot.reviewItems.count
                snapshot.reviewItems.removeAll { $0.id == command.item.id }
                if let count = snapshot.reviewCount { snapshot.reviewCount = max(0, count - before + snapshot.reviewItems.count) }
            }
            if let filing = edit.captureFiling {
                let before = snapshot.captures.count
                snapshot.captures.removeAll { $0.name == filing.capture.name && $0.modified == filing.capture.modified }
                if let count = snapshot.captureCount { snapshot.captureCount = max(0, count - before + snapshot.captures.count) }
            }
            if let work = edit.work, let original = edit.originalWork,
               let index = snapshot.work.firstIndex(where: { $0.id == work.id }),
               snapshot.work[index].modifiedAt == original.modifiedAt, MobilePlanningFiles.sameWidgetFields(snapshot.work[index], original) {
                snapshot.work[index] = work
            }
        }
        for index in snapshot.projects.indices {
            let path = snapshot.projects[index].path
            let tasks = snapshot.work.filter { $0.kind == .task && $0.projectPath == path }
            snapshot.projects[index].focus.completed = tasks.filter { $0.status == .completed }.count
            snapshot.projects[index].nextTask = WorkItemRecommendation.nextMobileAction(in: tasks, allItems: snapshot.work)
        }
        let projectFocus = Dictionary(uniqueKeysWithValues: snapshot.projects.map { ($0.path, $0.focus) })
        snapshot.focusItems = snapshot.focusItems.map { $0.kind == .projects ? projectFocus[$0.path] ?? $0 : $0 }
        return snapshot
    }
}

extension MobilePlanningFiles {
    public static func sameWidgetFields(_ lhs: MobileWorkItem, _ rhs: MobileWorkItem) -> Bool {
        lhs.id == rhs.id && lhs.title == rhs.title && lhs.kind == rhs.kind && lhs.status == rhs.status && lhs.stage == rhs.stage
            && lhs.priority == rhs.priority && lhs.projectPath == rhs.projectPath && lhs.dueDate == rhs.dueDate
            && lhs.featureIDs == rhs.featureIDs && lhs.milestoneIDs == rhs.milestoneIDs && lhs.actionMetadata == rhs.actionMetadata
    }
}
