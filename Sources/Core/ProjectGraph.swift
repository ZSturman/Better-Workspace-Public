import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Lossless Notion envelopes. Rich text, unsupported properties and date ranges survive editing.
public indirect enum ProjectJSON: Codable, Hashable, Sendable {
    case object([String: ProjectJSON]), array([ProjectJSON]), string(String), number(Double), bool(Bool), null
    public init(_ value: Any) {
        switch value {
        case let value as [String: Any]: self = .object(value.mapValues(ProjectJSON.init))
        case let value as [Any]: self = .array(value.map(ProjectJSON.init))
        case let value as String: self = .string(value)
        case let value as NSNumber:
            if CFGetTypeID(value) == CFBooleanGetTypeID() { self = .bool(value.boolValue) }
            else { self = .number(value.doubleValue) }
        default: self = .null
        }
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        // Most likely first: every failed attempt builds and discards a DecodingError,
        // and Notion pages are mostly objects and strings. Bool stays ahead of Double so
        // a `true` can never be read as 1.
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([String: ProjectJSON].self) { self = .object(v) }
        else if let v = try? c.decode([ProjectJSON].self) { self = .array(v) }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else { self = .number(try c.decode(Double.self)) }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }
    public var object: [String: ProjectJSON] { if case .object(let v) = self { return v }; return [:] }
    public var array: [ProjectJSON] { if case .array(let v) = self { return v }; return [] }
    public var string: String? { if case .string(let v) = self { return v }; return nil }
    public var bool: Bool { if case .bool(let v) = self { return v }; return false }
    public subscript(_ key: String) -> ProjectJSON { object[key] ?? .null }
    public var display: String {
        switch self {
        case .string(let v): return v
        case .number(let v): return v.formatted()
        case .bool(let v): return v ? "Yes" : "No"
        case .array(let v): return v.map(\.display).filter { !$0.isEmpty }.joined(separator: ", ")
        case .object(let v):
            if let name = v["name"]?.string { return name }
            if let text = v["plain_text"]?.string { return text }
            if let text = v["text"]?["content"].string { return text }
            if let start = v["start"]?.string { return start }
            if let type = v["type"]?.string, let value = v[type] {
                if type == "title" || type == "rich_text" { return value.array.map(\.display).joined() }
                return value.display
            }
            if let url = v["url"]?.string { return url }
            if let id = v["id"]?.string { return id }
            return ""
        case .null: return ""
        }
    }
    /// Temporary signed URLs are transport state, not edited content.
    public var comparable: ProjectJSON {
        switch self {
        case .object(let fields):
            if let type = fields["type"]?.string, let value = fields[type],
               ["title", "rich_text", "select", "status", "multi_select", "relation", "number", "date", "url", "files"].contains(type),
               value == .null || (["title", "rich_text", "multi_select", "relation", "files"].contains(type) && value.array.isEmpty) || (type == "url" && value.string == "") { return .null }
            if let type = fields["type"]?.string, ["select", "status"].contains(type), let value = fields[type] {
                return .object(["type": .string(type), type: value == .null ? .null : .object(["name": value["name"]])])
            }
            if fields["type"]?.string == "relation" {
                return .object(["type": .string("relation"), "relation": .array((fields["relation"] ?? .null).array.map { ProjectJSON(["id": $0["id"].string.map(ProjectGraph.normalizedID) ?? ""]) }.sorted { $0.display < $1.display })])
            }
            if fields["type"]?.string == "multi_select" {
                return .object(["type": .string("multi_select"), "multi_select": .array((fields["multi_select"] ?? .null).array.map { .object(["name": $0["name"]]) }.sorted { $0.display < $1.display })])
            }
            if fields["type"]?.string == "file", let url = fields["file"]?["url"].string,
               let parsed = URL(string: url) {
                var value: [String: ProjectJSON] = ["type": .string("file"), "file": .object(["url": .string(ProjectMediaResolver.cacheIdentity(for: parsed))])]
                if let name = fields["name"] { value["name"] = name }
                return .object(value)
            }
            var value = fields.filter { !["expiry_time", "last_edited_time", "last_edited_by", "plain_text", "href", "has_more"].contains($0.key) }.mapValues(\.comparable)
            if let type = fields["type"]?.string, fields[type] != nil { value.removeValue(forKey: "id") }
            if let annotations = value["annotations"] {
                let meaningful = annotations.object.filter { $0.value != .bool(false) && $0.value != .string("default") }
                if meaningful.isEmpty { value.removeValue(forKey: "annotations") } else { value["annotations"] = .object(meaningful) }
            }
            return .object(value)
        case .array(let values): return .array(values.map(\.comparable))
        default: return self
        }
    }
}
import CoreFoundation

public enum ProjectEntityKind: String, CaseIterable, Codable, Sendable, Identifiable {
    case projects, tasks, features, milestones, assets, resources, collections, versions, notes, ideas, posts, workLogs
    public var id: String { rawValue }
    public var title: String { self == .workLogs ? "Work Logs" : rawValue.capitalized }
    /// One record of this kind: "Feature", "Work Log".
    public var singular: String { self == .workLogs ? "Work Log" : String(title.dropLast()) }
    public static func matching(_ title: String) -> Self? {
        let name = title.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if name.contains("archived") || name.contains("automation") { return nil }
        if name == "work log" || name == "work logs" { return .workLogs }
        return allCases.first { name == $0.rawValue.lowercased() || (name.hasSuffix($0.rawValue.lowercased()) && name.count < $0.rawValue.count + 5) }
    }
}

public struct ProjectGraphSource: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let title: String
    public let kind: ProjectEntityKind
    public let schema: ProjectJSON
    /// Built once per source: the Projects table looks up dozens of properties for each
    /// of hundreds of rows, and each lookup used to normalise every schema key again.
    private let lookup: Lookup
    public init(id: String, title: String, kind: ProjectEntityKind, schema: ProjectJSON) {
        self.id = id; self.title = title; self.kind = kind; self.schema = schema
        lookup = Lookup(schema)
    }
    private enum CodingKeys: String, CodingKey { case id, title, kind, schema }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try c.decode(String.self, forKey: .id), title: try c.decode(String.self, forKey: .title),
                  kind: try c.decode(ProjectEntityKind.self, forKey: .kind), schema: try c.decode(ProjectJSON.self, forKey: .schema))
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id); try c.encode(title, forKey: .title); try c.encode(kind, forKey: .kind); try c.encode(schema, forKey: .schema)
    }
    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id && lhs.title == rhs.title && lhs.kind == rhs.kind && lhs.schema == rhs.schema }
    public func hash(into hasher: inout Hasher) { hasher.combine(id); hasher.combine(title); hasher.combine(kind); hasher.combine(schema) }

    private final class Lookup: @unchecked Sendable {
        /// Trimmed, case-folded names; then names reduced to letters and digits.
        let exact: [String: String], loose: [String: String], names: [String: String]
        static func folded(_ value: String) -> String { value.trimmingCharacters(in: .whitespaces).lowercased() }
        static func loose(_ value: String) -> String { String(value.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }) }
        init(_ schema: ProjectJSON) {
            var exact: [String: String] = [:], loose: [String: String] = [:], names: [String: String] = [:]
            // Sorted so a name two keys share resolves the same way every launch.
            for (key, value) in schema.object.sorted(by: { $0.key < $1.key }) {
                if exact[Self.folded(key)] == nil { exact[Self.folded(key)] = key }
                if loose[Self.loose(key)] == nil { loose[Self.loose(key)] = key }
                let id = value["id"].string ?? key
                if names[id] == nil { names[id] = key }
            }
            self.exact = exact; self.loose = loose; self.names = names
        }
    }
    public func property(named name: String) -> (id: String, definition: ProjectJSON)? {
        guard let key = lookup.exact[name.lowercased()] ?? lookup.loose[Lookup.loose(name)],
              let value = schema.object[key] else { return nil }
        return (value["id"].string ?? key, value)
    }
    public func name(for id: String) -> String {
        lookup.names[id] ?? id
    }
    public func writable(_ id: String) -> Bool {
        guard let property = schema.object.first(where: { ($0.value["id"].string ?? $0.key) == id })?.value else { return false }
        return ["title", "rich_text", "select", "status", "multi_select", "number", "checkbox", "date", "url", "relation", "files", "people"].contains(property["type"].string ?? "")
    }
}

public struct ProjectGraphRecord: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var pageID: String?
    public var sourceID: String
    public var kind: ProjectEntityKind
    public var local: [String: ProjectJSON]
    public var baseline: [String: ProjectJSON]
    public var remote: [String: ProjectJSON]
    public var localProjectID: String?
    public var localPath: String?
    /// Bounded Finder evidence that this bound project has left Projects. Keeps its
    /// original binding for recovery; it never authorizes moving/restoring a folder.
    public var finderProjectAbsent: Bool?
    /// Notion page edit time; never a local observation time.
    public var editedAt: Date?
    /// Known local field edits. Older/imported fields intentionally have no timestamp.
    public var localFieldEditedAt: [String: Date]?
    public var remoteArchived = false
    public var acknowledgedArchived: Bool?
    public var archiveRequested = false
    /// Local deletion leaves the remote page intact and suppresses its local projection.
    public var locallyDeleted: Bool?
    public var error: String?
    public var ambiguousCreate = false
    public var pendingUploads: [ProjectPendingUpload]?
    public var serviceRecordID: String?
    public var serviceSnapshot: [String: ProjectJSON]?
    public var serviceAcknowledgementPending: Bool?
    public init(id: String = UUID().uuidString, pageID: String? = nil, sourceID: String, kind: ProjectEntityKind,
                local: [String: ProjectJSON] = [:], baseline: [String: ProjectJSON] = [:], remote: [String: ProjectJSON] = [:]) {
        self.id = id; self.pageID = pageID; self.sourceID = sourceID; self.kind = kind
        self.local = local; self.baseline = baseline; self.remote = remote
    }
    public var title: String {
        let value = local.values.first { $0["type"].string == "title" } ?? remote.values.first { $0["type"].string == "title" }
        let text = value?.display ?? ""
        return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Untitled" : text
    }
    public func value(_ name: String, source: ProjectGraphSource) -> ProjectJSON {
        guard let key = source.property(named: name)?.id else { return .null }
        return local[key] ?? remote[key] ?? .null
    }
    public var relatedPageIDs: Set<String> {
        Set(local.values.filter { $0["type"].string == "relation" }.flatMap { $0["relation"].array.compactMap { $0["id"].string?.lowercased().replacingOccurrences(of: "-", with: "") } })
    }
    public var changes: [ProjectFieldChange] {
        Set(local.keys).union(remote.keys).union(baseline.keys).sorted().compactMap { key in
            let l = local[key] ?? .null, r = remote[key] ?? .null, b = baseline[key] ?? .null
            let lc = l.comparable != b.comparable, rc = r.comparable != b.comparable
            guard lc || rc else { return nil }
            return ProjectFieldChange(id: key, baseline: b, local: l, remote: r,
                                      state: l.comparable == r.comparable ? .equal : lc && rc ? .conflict : lc ? .outgoing : .incoming)
        }
    }
}
public struct ProjectPendingUpload: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let propertyID: String
    public let path: String
    public let filename: String
    public let contentType: String
    public let byteCount: Int
    public let modifiedAt: Date?
    public init(propertyID: String, url: URL, contentType: String, byteCount: Int, modifiedAt: Date?) {
        id = UUID().uuidString; self.propertyID = propertyID; path = url.path; filename = url.lastPathComponent
        self.contentType = contentType; self.byteCount = byteCount; self.modifiedAt = modifiedAt
    }
}
public struct ProjectFieldChange: Identifiable, Sendable, Hashable {
    public enum State: String, Sendable { case equal, outgoing, incoming, conflict }
    public let id: String
    public let baseline: ProjectJSON
    public let local: ProjectJSON
    public let remote: ProjectJSON
    public let state: State
}

/// Decoded graph records shared by every `ProjectGraphStore` over one connection.
///
/// The graph is thousands of Notion pages (64 MB of JSON on the owner's Mac), and a sync
/// pass, the Projects table and triage each asked for all of it. Decoding it every time
/// kept a core busy (November 9 profile). A record is decoded again only when its stored
/// bytes change; the database stays the only source of truth, and nothing is written.
///
/// Rows are read before this lock is taken, never under it: a writer inside
/// `Database.transaction` holds the database lock and may call `records()`.
final class ProjectGraphRecordCache: @unchecked Sendable {
    private struct Entry { let length: Int; let digest: Int; let record: ProjectGraphRecord }
    private let lock = NSLock()
    private var stamp: Database.ChangeStamp?
    private var entries: [String: Entry] = [:]
    private var ordered: [ProjectGraphRecord] = []
    private var generation = 0
    private var snapshotGeneration: Int?
    private var snapshotState: [String: String] = [:]
    private var lastSnapshot: ProjectGraphSnapshot?
    private static let counterLock = NSLock()
    nonisolated(unsafe) private static var counter = 0

    static func nextContentID() -> Int {
        counterLock.lock(); defer { counterLock.unlock() }
        counter += 1
        return counter
    }

    /// The cached records when nothing in the database has changed since they were read.
    func records(at stamp: Database.ChangeStamp) -> [ProjectGraphRecord]? {
        lock.lock(); defer { lock.unlock() }
        return stamp.provisional == false && self.stamp == stamp ? ordered : nil
    }

    /// `stamp` must be read before `rows`, so a write in between only causes a recheck.
    func resolve(_ rows: [(String, Data)], stamp: Database.ChangeStamp) throws -> (records: [ProjectGraphRecord], generation: Int) {
        lock.lock(); defer { lock.unlock() }
        let decoder = JSONDecoder()
        var next: [String: Entry] = [:], records: [ProjectGraphRecord] = []
        next.reserveCapacity(rows.count); records.reserveCapacity(rows.count)
        var decoded = 0
        for (id, payload) in rows {
            var hasher = Hasher()
            payload.withUnsafeBytes { hasher.combine(bytes: $0) }
            let digest = hasher.finalize()
            let entry: Entry
            if let known = entries[id], known.length == payload.count, known.digest == digest {
                entry = known
            } else {
                entry = Entry(length: payload.count, digest: digest, record: try decoder.decode(ProjectGraphRecord.self, from: payload))
                decoded += 1
            }
            next[id] = entry; records.append(entry.record)
        }
        if decoded > 0 || next.count != entries.count || records.map(\.id) != ordered.map(\.id) { generation += 1 }
        // Rows read inside a transaction stay checkable by their bytes, never by stamp.
        entries = next; ordered = records; self.stamp = stamp.provisional ? nil : stamp
        return (records, generation)
    }

    func snapshot(generation: Int, state: [String: String]) -> ProjectGraphSnapshot? {
        lock.lock(); defer { lock.unlock() }
        return snapshotGeneration == generation && snapshotState == state ? lastSnapshot : nil
    }

    func remember(_ snapshot: ProjectGraphSnapshot, generation: Int, state: [String: String]) {
        lock.lock(); defer { lock.unlock() }
        snapshotGeneration = generation; snapshotState = state; lastSnapshot = snapshot
    }
}

/// Private graph storage: network checks update only the incoming snapshot, never user decisions.
public final class ProjectGraphStore: @unchecked Sendable {
    private let db: Database
    public init(database: Database) throws {
        db = database
        try db.execute("""
        CREATE TABLE IF NOT EXISTS project_graph_records(id TEXT PRIMARY KEY, page_id TEXT UNIQUE, payload TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS project_graph_state(key TEXT PRIMARY KEY, payload TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS project_graph_lease(key TEXT PRIMARY KEY, owner TEXT NOT NULL, expires REAL NOT NULL);
        """)
    }
    /// A single SELECT captures records and state at the same SQLite revision.
    /// Decode and comparison happen after the database lock has been released.
    /// Unchanged rows reuse their decoded records, and an unchanged graph returns the
    /// snapshot already built (same `contentID`), so callers can skip republishing it.
    public func snapshot() throws -> ProjectGraphSnapshot {
        let stamp = try db.changeStamp()
        let rows = try db.query("""
            SELECT 0, id, payload FROM project_graph_records
            UNION ALL SELECT 1, key, payload FROM project_graph_state
            WHERE key IN ('sources', 'report', '\(ProjectAutoSync.deferredKey)', '\(ProjectAutoSync.failuresKey)',
                          '\(ProjectAutoSync.reportKey)', '\(ProjectAutoSync.actionReportKey)',
                          '\(ProjectAutoSync.lastMergesKey)', '\(ProjectAutoSync.lastChangesKey)',
                          '\(ProjectSyncTriage.Policy.key)', '\(ProjectSyncHealth.key)')
            """) { ($0.int(0), $0.string(1), $0.data(2)) }
        let resolved = try cache.resolve(rows.filter { $0.0 == 0 }.map { ($0.1, $0.2) }, stamp: stamp)
        let state = Dictionary(rows.filter { $0.0 == 1 }.map { ($0.1, String(decoding: $0.2, as: UTF8.self)) }, uniquingKeysWith: { first, _ in first })
        if let reused = cache.snapshot(generation: resolved.generation, state: state) { return reused }
        var snapshot = try ProjectGraphSnapshot(records: resolved.records, state: state)
        snapshot.contentID = ProjectGraphRecordCache.nextContentID()
        cache.remember(snapshot, generation: resolved.generation, state: state)
        return snapshot
    }
    /// Every record, decoded once per change of its stored bytes (see `ProjectGraphRecordCache`).
    public func records() throws -> [ProjectGraphRecord] {
        let stamp = try db.changeStamp()
        if let current = cache.records(at: stamp) { return current }
        let rows = try db.query("SELECT id, payload FROM project_graph_records") { ($0.string(0), $0.data(1)) }
        return try cache.resolve(rows, stamp: stamp).records
    }
    private var cache: ProjectGraphRecordCache { db.memo.slot("projectGraphRecords") { ProjectGraphRecordCache() } }
    public func record(id: String) throws -> ProjectGraphRecord? {
        guard let raw = try db.query("SELECT payload FROM project_graph_records WHERE id=?", [.text(id)], row: { $0.string(0) }).first else { return nil }
        return try JSONDecoder().decode(ProjectGraphRecord.self, from: Data(raw.utf8))
    }
    public func record(pageID: String) throws -> ProjectGraphRecord? {
        guard let raw = try db.query("SELECT payload FROM project_graph_records WHERE page_id=?", [.text(pageID)], row: { $0.string(0) }).first else { return nil }
        return try JSONDecoder().decode(ProjectGraphRecord.self, from: Data(raw.utf8))
    }
    public func save(_ record: ProjectGraphRecord) throws {
        let json = String(decoding: try JSONEncoder().encode(record), as: UTF8.self)
        try db.run("INSERT INTO project_graph_records(id,page_id,payload) VALUES(?,?,?) ON CONFLICT(id) DO UPDATE SET page_id=excluded.page_id,payload=excluded.payload",
                   [.text(record.id), record.pageID.map(Database.Value.text) ?? .null, .text(json)])
    }
    /// Forgets unsent records and hides linked records for this path and its contents.
    /// Retained identities prevent background sync from recreating deleted local work.
    public func recordLocalDeletion(path: String, pageID: String? = nil, pageIDs: Set<String> = []) throws {
        let deletedPages = Set((Array(pageIDs) + [pageID].compactMap { $0 }).map(ProjectGraph.normalizedID))
        try db.transaction {
            for var record in try records() where record.localPath == path
                || record.localPath?.hasPrefix(path + "/") == true
                || record.pageID.map(ProjectGraph.normalizedID).map(deletedPages.contains) == true {
                if record.pageID == nil {
                    // A timed-out create may already exist remotely. Keep its
                    // reconciliation state visible instead of treating it as unsent.
                    if !record.ambiguousCreate { try db.run("DELETE FROM project_graph_records WHERE id=?", [.text(record.id)]) }
                } else {
                    record.locallyDeleted = true
                    try save(record)
                }
            }
        }
    }

    /// Forgets a local planning record that was never sent to Notion (no page id), so
    /// a deleted work item cannot be created remotely later. Sent and uncertain
    /// creates are retained. Read/check/delete share a transaction with other writers.
    public func removeUnsent(localPath: String, reviewed: [ProjectGraphRecord]) throws {
        try removeUnsent(localPaths: [localPath], reviewed: reviewed)
    }
    public func removeUnsent(localPaths: Set<String>, reviewed: [ProjectGraphRecord]) throws {
        try db.transaction {
            for expected in reviewed where expected.pageID == nil && !expected.ambiguousCreate && expected.localPath.map(localPaths.contains) == true {
                guard let current = try record(id: expected.id) else { continue }
                guard current == expected else { throw NotionProjectSync.SyncError.stale }
                try db.run("DELETE FROM project_graph_records WHERE id=?", [.text(expected.id)])
            }
        }
    }
    /// Forgets a record that was never sent to Notion. Anything that exists in Notion, or
    /// may (an ambiguous create), is refused.
    @discardableResult
    public func discardDraft(_ id: String) throws -> Bool {
        guard let record = try record(id: id), record.pageID == nil, !record.ambiguousCreate else { return false }
        try db.run("DELETE FROM project_graph_records WHERE id=?", [.text(id)])
        return true
    }
    public func removeUnaccepted(_ id: String) throws {
        guard let record = try record(id: id), record.local.isEmpty else { return }
        try db.run("DELETE FROM project_graph_records WHERE id=?", [.text(id)])
    }

    /// Explicitly link an imported page without creating a second remote project.
    /// Keep the local draft's identity (and its incoming child references). Archive
    /// both reviewed records privately before coalescing a clean imported record.
    public func linkLocalProject(_ local: ProjectRecord, page expected: ProjectGraphRecord,
                                 draft: ProjectGraphRecord?, projectStore: ProjectStore) throws {
        guard db === projectStore.db else { throw NotionProjectSync.SyncError.stale }
        // Match ProjectStore's lock order before entering SQLite, and exclude any
        // sync whose network request may still return with the old binding.
        projectStore.lock.lock(); defer { projectStore.lock.unlock() }
        let owner = "pid:\(getpid()):\(UUID().uuidString)"
        guard try acquire(owner: owner) else { throw NotionProjectSync.SyncError.busy }
        defer { try? release(owner: owner) }
        try db.transaction {
            guard let currentLocal = projectStore.record(id: local.id),
                  currentLocal.lastPath == local.lastPath, currentLocal.identityKey == local.identityKey,
                  currentLocal.notionPageID == local.notionPageID,
                  let page = try record(id: expected.id), page == expected,
                  page.kind == .projects, let pageID = page.pageID,
                  !page.remoteArchived, !page.archiveRequested, page.locallyDeleted != true,
                  page.localProjectID == nil || page.localProjectID == local.id else { throw NotionProjectSync.SyncError.stale }
            let associated = try records().filter { $0.kind == .projects && $0.localProjectID == local.id && $0.id != page.id }
            guard associated.count == (draft == nil ? 0 : 1),
                  associated.first == draft else { throw NotionProjectSync.SyncError.stale }
            var linked = page
            if let draft {
                guard draft.pageID == nil, !draft.ambiguousCreate, !draft.archiveRequested,
                      draft.locallyDeleted != true, draft.sourceID == page.sourceID,
                      draft.baseline.isEmpty, draft.remote.isEmpty,
                      !page.changes.contains(where: { [.outgoing, .conflict].contains($0.state) }),
                      (page.pendingUploads ?? []).isEmpty, page.serviceRecordID == nil else {
                    throw NotionProjectSync.SyncError.unsupported("This page or draft has pending changes or uncertain creation. Resolve them in Sync Center before linking.")
                }
                linked = draft
                linked.pageID = pageID; linked.remote = page.remote; linked.baseline = page.baseline
                linked.editedAt = page.editedAt; linked.acknowledgedArchived = page.acknowledgedArchived
                linked.local = page.local.merging(draft.local) { _, local in local }
                try db.run("DELETE FROM project_graph_records WHERE id=?", [.text(page.id)])
            }
            try write("project-link-checkpoint:\(UUID().uuidString)", [page] + [draft].compactMap { $0 })
            // A linked page must not later project its old remote metadata over
            // populated local decisions merely because an unrelated field syncs.
            // Retain explicit graph drafts first; seed only other populated fields.
            if let source = try read("sources", as: [ProjectGraphSource].self)?.first(where: { $0.id == linked.sourceID }) {
                let metadata = projectStore.metadata(for: local.id), description = projectStore.description(for: local.id)
                let portfolio = projectStore.portfolioDetails(for: local.id)
                let pending = Set(page.changes.filter { [.outgoing, .conflict].contains($0.state) }.map(\.id)).union(draft?.local.keys.map { $0 } ?? [])
                func seed(_ name: String, _ value: ProjectJSON) {
                    guard let field = source.property(named: name), !pending.contains(field.id) else { return }
                    linked.set(name, value: value, source: source, changedAt: nil)
                }
                for (name, value) in [("domain", metadata.domain), ("Status", metadata.status), ("Phase", metadata.phase), ("Completion Model", metadata.completionModel), ("Maintenance Cadence", metadata.maintenanceCadence), ("Type", metadata.projectType)] {
                    if let value, !value.isEmpty {
                        seed(name, name == "Type" ? ProjectJSON(ProjectProperties.types(value).map { ["name": $0] }) : ProjectJSON(["name": value]))
                    }
                }
                for (name, values) in [("Current Work", metadata.currentWork), ("Next Work", metadata.nextWork),
                                       ("Recent Work", metadata.recentWork), ("Work Mode", metadata.workModes), ("Blocked By", metadata.blockers)] where !values.isEmpty {
                    seed(name, ProjectJSON(values.map { ["name": $0] }))
                }
                for (name, date) in [("started at", metadata.startedAt), ("last update at", metadata.lastUpdateAt)] {
                    if let date { seed(name, ProjectJSON(["start": ISO8601DateFormatter().string(from: date)])) }
                }
                for (name, value) in [("one liner", description.oneLiner), ("summary", description.summary), ("status details", metadata.statusDetail)] {
                    if let value, !value.isEmpty { seed(name, ProjectServiceBridge.text(value)) }
                }
                for (name, value) in [("Featured", portfolio.featured), ("In Showcase", portfolio.inShowcase), ("Public", portfolio.isPublic)] {
                    if let value { seed(name, .bool(value)) }
                }
                for (aliases, value) in [(["GitHub", "Github", "Repo Link", "Repository URL", "Repository", "Repo"], portfolio.githubURL),
                                         (["Website", "Project URL", "URL", "Live URL", "Download URL"], portfolio.websiteURL)] {
                    if let value, !value.isEmpty, let name = aliases.first(where: { source.property(named: $0)?.definition["type"].string == "url" }) { seed(name, .string(value)) }
                }
                for (id, rating) in projectStore.ratings(for: local.id) {
                    if let metric = MetricDefinition.find(id: id) { seed(metric.displayName, .number(Double(rating))) }
                }
            }
            try projectStore.setExplicitNotionPageID(pageID, for: local.id)
            linked.localProjectID = local.id; linked.localPath = local.lastPath
            try save(linked)
        }
    }
    public func read<T: Decodable>(_ key: String, as: T.Type) throws -> T? {
        guard let raw = try db.query("SELECT payload FROM project_graph_state WHERE key=?", [.text(key)], row: { $0.string(0) }).first else { return nil }
        return try JSONDecoder().decode(T.self, from: Data(raw.utf8))
    }
    public func write<T: Encodable>(_ key: String, _ value: T) throws {
        let json = String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
        try db.run("INSERT INTO project_graph_state(key,payload) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET payload=excluded.payload", [.text(key), .text(json)])
    }
    public func acquire(owner: String, now: Date = Date()) throws -> Bool {
        try db.transaction {
            let leases = try db.query("SELECT owner,expires FROM project_graph_lease") { ($0.string(0), $0.double(1)) }
            for (holder, expiry) in leases {
                let components = holder.split(separator: ":")
                if components.count == 3, components[0] == "pid", let pid = Int32(components[1]) {
                    // A terminated headless checker must not block the next check for
                    // an hour. Keep a live process locked even across a long sync.
                    if kill(pid, 0) != 0 && errno == ESRCH { try db.run("DELETE FROM project_graph_lease WHERE owner=?", [.text(holder)]) }
                } else if expiry < now.timeIntervalSince1970 { try db.run("DELETE FROM project_graph_lease WHERE owner=?", [.text(holder)]) }
            }
            return try db.run("INSERT OR IGNORE INTO project_graph_lease(key,owner,expires) VALUES('sync',?,?)", [.text(owner), .double(now.addingTimeInterval(3600).timeIntervalSince1970)]) == 1
        }
    }
    public func release(owner: String) throws { try db.run("DELETE FROM project_graph_lease WHERE owner=?", [.text(owner)]) }
    public func ingest(pages: [ProjectJSON], source: ProjectGraphSource) throws {
        // Looks up only the pages being ingested. Decoding every record (24 MB of
        // JSON for ~3,300 pages) on each call made a routine background check
        // hold a core for three minutes every fifteen.
        try db.transaction {
            for page in pages {
                guard let pageID = page["id"].string else { continue }
                let fields = Dictionary(uniqueKeysWithValues: page["properties"].object.map { name, value in (value["id"].string ?? source.property(named: name)?.id ?? name, value) })
                let existing = try record(pageID: pageID)
                var record = existing ?? ProjectGraphRecord(sourceID: source.id, kind: source.kind)
                record.pageID = pageID; record.remote = fields
                record.editedAt = page["last_edited_time"].string.flatMap { ProjectDates.parse($0) }
                record.remoteArchived = page["in_trash"].bool
                // A page read again unchanged (every page, on a full check) is not
                // rewritten: the write would change nothing but its stored bytes.
                if record != existing { try save(record) }
            }
        }
    }
    /// Settles chosen fields on this Mac only; nothing is sent. `.notion` makes the local
    /// value Notion's (and acknowledges it); `.local` acknowledges Notion's value as seen,
    /// so this Mac's value goes out on the next send. Returns false when the record has
    /// changed since `expected` was read, and then changes nothing. Merge stages an
    /// additive union against the reviewed Notion baseline for the next send.
    @discardableResult
    public func resolve(_ id: String, choices: [String: ProjectSyncTriage.Side], expected: ProjectGraphRecord) throws -> Bool {
        guard var record = try record(id: id), record == expected else { return false }
        for (field, side) in choices {
            let remote = record.remote[field] ?? .null
            switch side {
            case .notion:
                record.local[field] = remote == .null ? nil : remote
                record.baseline[field] = remote == .null ? nil : remote
                record.localFieldEditedAt?[field] = nil
            case .local:
                record.baseline[field] = remote == .null ? nil : remote
            case .merge:
                guard let merged = ProjectSyncTriage.mergedValue(local: record.local[field] ?? .null, notion: remote) else {
                    throw NotionProjectSync.SyncError.unsupported("This field cannot be merged. Choose This Mac or Notion instead.")
                }
                record.local[field] = merged
                record.baseline[field] = remote == .null ? nil : remote
                if record.localFieldEditedAt == nil { record.localFieldEditedAt = [:] }
                record.localFieldEditedAt?[field] = Date()
            }
        }
        try save(record)
        return true
    }

    public func acceptIncoming(_ id: String, resolutions: [String: Bool] = [:]) throws {
        guard var record = try record(id: id) else { return }
        for change in record.changes {
            switch change.state {
            case .incoming, .equal: record.local[change.id] = change.remote; record.baseline[change.id] = change.remote
            case .conflict:
                if let useLocal = resolutions[change.id] {
                    if !useLocal { record.local[change.id] = change.remote }
                    record.baseline[change.id] = change.remote
                }
            case .outgoing: break
            }
        }
        // Empty initial properties still need an acknowledged baseline. Otherwise
        // an empty page would remain pending forever and never become browsable.
        for (key, value) in record.remote where record.baseline[key] == nil && value.comparable == .null && (record.local[key] ?? .null).comparable == .null {
            record.local[key] = value; record.baseline[key] = value
        }
        record.acknowledgedArchived = record.remoteArchived
        try save(record)
    }
    public func referenceDetails(sources: [ProjectGraphSource]) throws -> [String: Int] {
        try referenceSummary(sources: sources).details
    }

    func referenceSummary(sources: [ProjectGraphSource]) throws -> (unresolved: Int, details: [String: Int]) {
        let records = try records()
        let missing = unresolvedReferences(in: records)
        let sourceMap = Dictionary(sources.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var grouped: [String: Set<String>] = [:]
        for record in records {
            guard let source = sourceMap[record.sourceID] else { continue }
            for (key, value) in record.local.merging(record.remote, uniquingKeysWith: { local, remote in
                local["type"].string == "relation" ? ProjectJSON(["type": "relation", "relation": (local["relation"].array + remote["relation"].array).map(\.foundationObject)]) : remote
            }) where value["type"].string == "relation" {
                let field = source.schema.object.first { $0.value["id"].string == key }
                let target = field?.value["relation"]["data_source_id"].string.flatMap { sourceMap[$0] }
                let name = target.map { "Missing \($0.title) records" } ?? "External: \(field?.key ?? source.name(for: key))"
                for id in value["relation"].array.compactMap({ $0["id"].string }).map(ProjectGraph.normalizedID) where missing.contains(id) { grouped[name, default: []].insert(id) }
            }
        }
        return (missing.count, grouped.mapValues(\.count))
    }
    public func unresolvedReferences() throws -> Set<String> {
        unresolvedReferences(in: try records())
    }

    private func unresolvedReferences(in records: [ProjectGraphRecord]) -> Set<String> {
        let known = Set((records.compactMap(\.pageID) + records.map(\.id)).map(ProjectGraph.normalizedID))
        let references = records.flatMap { record in
            (Array(record.local.values) + Array(record.remote.values)).filter { $0["type"].string == "relation" }.flatMap { $0["relation"].array.compactMap { $0["id"].string }.map(ProjectGraph.normalizedID) }
        }
        return Set(references).subtracting(known)
    }
}

public extension ProjectJSON {
    var foundationObject: [String: Any] { object.mapValues { $0.foundationValue } }
    var foundationValue: Any {
        switch self {
        case .object(let v): return v.mapValues { $0.foundationValue }
        case .array(let v): return v.map { $0.foundationValue }
        case .string(let v): return v
        case .number(let v): return v
        case .bool(let v): return v
        case .null: return NSNull()
        }
    }
}

public extension ProjectGraphRecord {
    func notionPage(source: ProjectGraphSource, incoming: Bool = false) -> NotionPage? {
        let properties = (incoming ? remote : local).reduce(into: [String: ProjectJSON]()) { $0[source.name(for: $1.key)] = $1.value }
        return NotionPage(json: ProjectJSON(["id": pageID ?? id, "properties": ProjectJSON.object(properties).foundationObject]).foundationObject)
    }
    /// Initial import preserves existing local decisions. Differing populated
    /// values become reviewed conflicts; empty remote fields remain local fills.
    mutating func seedInitialLocalState(_ values: [String: ProjectJSON], source: ProjectGraphSource) {
        guard local.isEmpty, baseline.isEmpty else { return }
        for (name, value) in values where value != .null {
            set(name, value: value, source: source, changedAt: nil)
            if let field = source.property(named: name), ["title", "rich_text"].contains(field.definition["type"].string ?? ""),
               local[field.id]?.display == remote[field.id]?.display { local[field.id] = remote[field.id] }
            if let field = source.property(named: name), field.definition["type"].string == "date",
               let incoming = remote[field.id]?["date"]["start"].string, let proposed = local[field.id]?["date"]["start"].string,
               let date = ProjectDates.parse(incoming), date == ProjectDates.parse(proposed) { local[field.id] = remote[field.id] }
        }
    }
    mutating func set(_ name: String, value: ProjectJSON, source: ProjectGraphSource, changedAt: Date? = Date()) {
        guard let property = source.property(named: name), source.writable(property.id), let type = property.definition["type"].string else { return }
        var envelope = (local[property.id] ?? remote[property.id] ?? .null).object
        envelope["id"] = .string(property.id); envelope["type"] = .string(type); envelope[type] = value
        let next = ProjectJSON.object(envelope)
        if (local[property.id] ?? .null).comparable != next.comparable {
            if localFieldEditedAt == nil { localFieldEditedAt = [:] }
            localFieldEditedAt?[property.id] = changedAt
        }
        local[property.id] = next
    }
}

/// Notion supplies a page timestamp, not field timestamps. This is an explicit
/// heuristic; unknown or tied dates require a manual choice.
public extension ProjectGraphRecord {
    func newestConflictChoice(for fieldID: String) -> Bool? {
        guard changes.contains(where: { $0.id == fieldID && $0.state == .conflict }),
              let localDate = localFieldEditedAt?[fieldID], let remoteDate = editedAt,
              localDate != remoteDate else { return nil }
        return localDate > remoteDate
    }
}

extension ProjectGraphStore {
    /// Queue only a positively identified Finder move/rename on an existing linked
    /// page. Keep all remote values, baselines, unrelated drafts and recovery state.
    public func reflectFinderProjectLocation(projectID: String, path: String, title: String,
                                             renamed: Bool, isIdea: Bool, source: ProjectGraphSource) throws {
        try db.transaction {
            for var record in try records() where record.kind == .projects && record.sourceID == source.id && record.localProjectID == projectID
                && record.pageID != nil && record.locallyDeleted != true {
                let original = record
                record.localPath = path
                if let field = source.property(named: "Local Directory"), source.writable(field.id) {
                    let value: ProjectJSON = field.definition["type"].string == "url"
                        ? .string(URL(fileURLWithPath: path).absoluteString) : ProjectServiceBridge.text(path)
                    if record.value("Local Directory", source: source).display != value.display {
                        record.set("Local Directory", value: value, source: source)
                    }
                }
                if renamed {
                    for (name, schema) in source.schema.object where schema["type"].string == "title" && source.writable(schema["id"].display) {
                        if record.value(name, source: source).display != title { record.set(name, value: ProjectServiceBridge.text(title), source: source) }
                    }
                }
                if isIdea, let field = source.property(named: "Status"), source.writable(field.id),
                   let type = field.definition["type"].string,
                   let idea = field.definition[type]["options"].array.first(where: { $0["name"].display.lowercased() == "idea" })?["name"].string,
                   record.value("Status", source: source).display != idea {
                    record.set("Status", value: ProjectJSON(["name": idea]), source: source)
                }
                if record != original { try save(record) }
            }
        }
    }
}

extension ProjectGraphStore {
    func updateFinderProjectPresence(_ prior: ProjectGraphRecord, departed: Bool, idea: String, source: ProjectGraphSource) throws {
        try db.transaction {
        // Resolve through the ordinary graph, retaining remote values, drafts and baseline.
        guard var current = try record(id: prior.id), current == prior else { return }
        current.finderProjectAbsent = departed ? true : nil
        if departed, current.value("Status", source: source).display != idea {
            current.set("Status", value: ProjectJSON(["name": idea]), source: source)
        }
        if current != prior { try save(current) }
        }
    }
}
