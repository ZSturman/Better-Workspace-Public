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
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode([String: ProjectJSON].self) { self = .object(v) }
        else { self = .array(try c.decode([ProjectJSON].self)) }
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
    public init(id: String, title: String, kind: ProjectEntityKind, schema: ProjectJSON) {
        self.id = id; self.title = title; self.kind = kind; self.schema = schema
    }
    public func property(named name: String) -> (id: String, definition: ProjectJSON)? {
        func key(_ value: String) -> String { String(value.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }) }
        guard let value = schema.object.first(where: { $0.key.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(name) == .orderedSame })
            ?? schema.object.first(where: { key($0.key) == key(name) }) else { return nil }
        return (value.value["id"].string ?? value.key, value.value)
    }
    public func name(for id: String) -> String {
        schema.object.first { ($0.value["id"].string ?? $0.key) == id }?.key ?? id
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
    public func snapshot() throws -> ProjectGraphSnapshot {
        let rows = try db.query("""
            SELECT 0, id, payload FROM project_graph_records
            UNION ALL SELECT 1, key, payload FROM project_graph_state
            WHERE key IN ('sources', 'report', '\(ProjectAutoSync.deferredKey)', '\(ProjectAutoSync.failuresKey)',
                          '\(ProjectAutoSync.reportKey)', '\(ProjectAutoSync.actionReportKey)',
                          '\(ProjectAutoSync.lastMergesKey)', '\(ProjectAutoSync.lastChangesKey)')
            """) { ($0.int(0), $0.string(1), $0.string(2)) }
        let decoder = JSONDecoder()
        let records = try rows.filter { $0.0 == 0 }.map { try decoder.decode(ProjectGraphRecord.self, from: Data($0.2.utf8)) }
        let state = Dictionary(rows.filter { $0.0 == 1 }.map { ($0.1, $0.2) }, uniquingKeysWith: { first, _ in first })
        return try ProjectGraphSnapshot(records: records, state: state)
    }
    public func records() throws -> [ProjectGraphRecord] {
        try db.query("SELECT payload FROM project_graph_records") { $0.string(0) }.map { try JSONDecoder().decode(ProjectGraphRecord.self, from: Data($0.utf8)) }
    }
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
                    try db.run("DELETE FROM project_graph_records WHERE id=?", [.text(record.id)])
                } else {
                    record.locallyDeleted = true
                    try save(record)
                }
            }
        }
    }

    /// Forgets a local planning record that was never sent to Notion (no page id), so
    /// a deleted work item cannot be created remotely later. A sent record is kept.
    public func removeUnsent(localPath: String) throws {
        for record in try records() where record.pageID == nil && record.localPath == localPath {
            try db.run("DELETE FROM project_graph_records WHERE id=?", [.text(record.id)])
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
                var record = try record(pageID: pageID) ?? ProjectGraphRecord(sourceID: source.id, kind: source.kind)
                record.pageID = pageID; record.remote = fields
                record.editedAt = page["last_edited_time"].string.flatMap { ProjectDates.parse($0) }
                record.remoteArchived = page["in_trash"].bool
                try save(record)
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
        guard var record = try record(id: id), record.local == expected.local, record.remote == expected.remote,
              record.baseline == expected.baseline else { return false }
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
        let missing = try unresolvedReferences()
        let sourceMap = Dictionary(sources.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var grouped: [String: Set<String>] = [:]
        for record in try records() {
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
        return grouped.mapValues(\.count)
    }
    public func unresolvedReferences() throws -> Set<String> {
        let records = try records()
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
