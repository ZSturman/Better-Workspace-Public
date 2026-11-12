import Foundation

/// What this app knows about a project directory beyond what the directory says.
///
/// The folder on disk is the project. This is a note about it.
public struct ProjectRecord: Identifiable, Hashable, Sendable {
    public let id: String
    /// `volumeID:inode` when it could be read. Survives a rename or a same-volume move.
    public var identityKey: String?
    public var lastPath: String
    public var name: String
    /// Optional. Better Workspace is fully usable without a Notion account; this is
    /// only set for someone who came from Notion and wants the link kept.
    public var notionPageID: String?
    /// Optional. Workspace Watcher's project id, so its sessions and measurements can
    /// be joined to this project.
    public var watcherID: String?
    /// Optional. Better Projects' document id, carried across so nothing is stranded.
    public var documentID: String?
    public var createdAt: Date
    public var updatedAt: Date

    public var url: URL { URL(fileURLWithPath: lastPath) }
    public var hasNotionLink: Bool { (notionPageID?.isEmpty == false) }

    /// The page a person would open. Notion accepts the id with the dashes removed.
    public var notionURL: URL? {
        guard let id = notionPageID?.replacingOccurrences(of: "-", with: ""),
              id.isEmpty == false else { return nil }
        return URL(string: "https://www.notion.so/\(id)")
    }
}

/// The one place project-level knowledge lives: identity, optional external links, and
/// manual ratings.
///
/// Resolution deliberately mirrors `TagStore`: match on inode first so a rename is
/// harmless, fall back to the last known path so an inode change is survivable, and
/// only then create. That is what lets a rating stay attached to a project the user
/// reorganizes in Finder.
public final class ProjectStore: @unchecked Sendable {

    public enum NotionLinkError: LocalizedError {
        case missingProject
        case projectAlreadyLinked
        case notionPageAlreadyLinked

        public var errorDescription: String? {
            switch self {
            case .missingProject:
                return "That local project is no longer available. Refresh and try again."
            case .projectAlreadyLinked:
                return "That local project is already linked to a different Notion project."
            case .notionPageAlreadyLinked:
                return "That Notion project is already linked to a different local project."
            }
        }
    }

    let db: Database
    let lock = NSRecursiveLock()

    public init(database: Database) {
        self.db = database
    }

    // MARK: - Identity

    /// Reserve the canonical portable UUID before publishing a newly created
    /// directory. Discovery may run immediately after the move; it must adopt this
    /// UUID rather than inventing another project identity. Existing rows/links
    /// are never reassigned by a reservation.
    public func reserveWorkspaceIdentity(_ id: UUID, for identity: FileIdentity, createdAt: Date) throws {
        lock.lock(); defer { lock.unlock() }
        try db.transaction {
            try db.execute("CREATE TABLE IF NOT EXISTS workspace_project_identity_reservations (identity_key TEXT PRIMARY KEY, project_id TEXT NOT NULL UNIQUE, created_at REAL NOT NULL)")
            guard all("WHERE id = ? OR identity_key = ?", [.text(id.uuidString), .text(identity.key)]).allSatisfy({ $0.id == id.uuidString && $0.identityKey == identity.key }) else { throw WorkspaceReplicaError.changed }
            let existing = try db.query("SELECT identity_key,project_id,created_at FROM workspace_project_identity_reservations WHERE identity_key=? OR project_id=?", [.text(identity.key), .text(id.uuidString)]) { ($0.string(0), $0.string(1), $0.double(2)) }
            guard existing.allSatisfy({ $0.0 == identity.key && $0.1 == id.uuidString && $0.2 == createdAt.timeIntervalSince1970 }) else { throw WorkspaceReplicaError.changed }
            try db.run("INSERT OR IGNORE INTO workspace_project_identity_reservations(identity_key,project_id,created_at) VALUES(?,?,?)", [.text(identity.key), .text(id.uuidString), .double(createdAt.timeIntervalSince1970)])
        }
    }

    /// Throwing readback for explicit canonical creation; normal registration keeps
    /// its existing compatibility behavior for previously discovered projects.
    public func registerWorkspaceProject(_ id: UUID, at url: URL) throws -> ProjectRecord {
        lock.lock(); defer { lock.unlock() }
        guard let identity = FileIdentityResolver.identity(of: url), let created = try url.resourceValues(forKeys: [.creationDateKey]).creationDate else { throw WorkspaceReplicaError.missing }
        try reserveWorkspaceIdentity(id, for: identity, createdAt: created)
        let record = register(url: url)
        guard record.id == id.uuidString, let saved = self.record(id: id.uuidString),
              saved.identityKey == identity.key, saved.lastPath == url.canonicalPath else { throw WorkspaceReplicaError.changed }
        return saved
    }

    public func initializeWorkspaceProject(_ content: WorkspaceRecordContent, id: UUID, at url: URL) throws {
        lock.lock(); defer { lock.unlock() }
        _ = try registerWorkspaceProject(id, at: url)
        try db.transaction {
            let metadata = content.projectMetadata ?? .init(), portfolio = content.projectLinks ?? .init()
            let description = ProjectDescription(summary: content.body).cleaned
            guard (self.metadata(for: id.uuidString).isEmpty || self.metadata(for: id.uuidString) == metadata),
                  (self.description(for: id.uuidString).isEmpty || self.description(for: id.uuidString) == description),
                  (portfolioDetails(for: id.uuidString).isEmpty || portfolioDetails(for: id.uuidString) == portfolio) else { throw WorkspaceReplicaError.changed }
            setMetadata(metadata, for: id.uuidString)
            setDescription(description, for: id.uuidString)
            try savePortfolioDetails(portfolio, for: id.uuidString)
            guard self.metadata(for: id.uuidString) == metadata, self.description(for: id.uuidString) == description,
                  portfolioDetails(for: id.uuidString) == portfolio else { throw WorkspaceReplicaError.changed }
        }
    }

    public func releaseUnpublishedWorkspaceIdentity(_ id: UUID, identity: FileIdentity) throws {
        lock.lock(); defer { lock.unlock() }
        guard record(id: id.uuidString) == nil else { return }
        try db.run("DELETE FROM workspace_project_identity_reservations WHERE project_id=? AND identity_key=?", [.text(id.uuidString), .text(identity.key)])
    }

    @discardableResult
    public func register(url: URL, name: String? = nil) -> ProjectRecord {
        lock.lock(); defer { lock.unlock() }
        let path = url.canonicalPath
        let displayName = name ?? url.lastPathComponent
        let fileIdentity = FileIdentityResolver.identity(of: url)
        let identity = fileIdentity?.key
        let reservedID = identity.flatMap { key in
            (try? db.query("SELECT project_id,created_at FROM workspace_project_identity_reservations WHERE identity_key=?", [.text(key)], row: { ($0.string(0), $0.double(1)) }))?.first.flatMap { value in
                (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate?.timeIntervalSince1970) == value.1 ? value.0 : nil
            }
        }
        let now = Date()

        if let fileIdentity, let existing = record(matching: fileIdentity, at: path) {
            if existing.lastPath != path || existing.name != displayName || existing.identityKey != identity {
                relocate(existing, to: path, name: displayName, identity: fileIdentity, at: now)
            }
            var updated = existing
            updated.lastPath = path
            updated.name = displayName
            updated.identityKey = identity
            return updated
        }

        if let existing = first("WHERE last_path = ?", [.text(path)]) {
            // A different folder at a known project's path is that project only when its
            // own folder is gone (restored from a backup, or copied and replaced). If it
            // still exists elsewhere — swapped in Finder — or this folder was reserved for
            // another identity, the earlier record keeps its links and follows its folder,
            // and this one is new. A silently ignored insert must never stand in for it.
            let elsewhere = folderElsewhere(existing, than: fileIdentity, at: url)
            if elsewhere != nil || (reservedID != nil && reservedID != existing.id) {
                let destination = elsewhere.flatMap { first("WHERE last_path = ?", [.text($0)]) == nil ? $0 : nil }
                    ?? (path as NSString).deletingLastPathComponent + "/.bw-superseded-" + existing.id
                _ = try? db.run("UPDATE projects SET last_path = ?, name = ?, updated_at = ? WHERE id = ?",
                                [.text(destination), .text(elsewhere.map { URL(fileURLWithPath: $0).lastPathComponent } ?? existing.name),
                                 .double(now.timeIntervalSince1970), .text(existing.id)])
                let record = ProjectRecord(
                    id: reservedID ?? UUID().uuidString, identityKey: identity, lastPath: path, name: displayName,
                    notionPageID: nil, watcherID: nil, documentID: nil, createdAt: now, updatedAt: now
                )
                insert(record)
                return record
            }
            if existing.identityKey != identity {
                _ = try? db.run(
                    "UPDATE projects SET identity_key = ?, updated_at = ? WHERE id = ?",
                    [identity.map { .text($0) } ?? .null, .double(now.timeIntervalSince1970), .text(existing.id)]
                )
            }
            var updated = existing
            updated.identityKey = identity
            return updated
        }

        let record = ProjectRecord(
            id: reservedID ?? UUID().uuidString, identityKey: identity, lastPath: path, name: displayName,
            notionPageID: nil, watcherID: nil, documentID: nil, createdAt: now, updatedAt: now
        )
        insert(record)
        return record
    }

    /// Finds the project at a URL, healing the stored path on the way.
    ///
    /// Not a pure read: when a project is found by inode at a path other than the one
    /// on file, the folder was renamed or moved outside this app and the stored path
    /// is simply wrong. Correcting it here is what keeps the fallback lookup — by path,
    /// for when an inode does not survive — from going stale and stranding the record.
    public func record(for url: URL) -> ProjectRecord? {
        lock.lock(); defer { lock.unlock() }
        let path = url.canonicalPath
        if let identity = FileIdentityResolver.identity(of: url),
           var found = record(matching: identity, at: path) {
            if found.lastPath != path || found.identityKey != identity.key {
                let name = found.lastPath != path ? url.lastPathComponent : found.name
                relocate(found, to: path, name: name, identity: identity, at: Date())
                found.lastPath = path
                found.name = name
                found.identityKey = identity.key
            }
            return found
        }
        return first("WHERE last_path = ?", [.text(path)]).flatMap { folderElsewhere($0, than: FileIdentityResolver.identity(of: url), at: url) == nil ? $0 : nil }
    }

    /// Where a record's own folder is now, when that is not `url`: the path names a
    /// different folder than the record's, and the record's folder still exists.
    private func folderElsewhere(_ record: ProjectRecord, than identity: FileIdentity?, at url: URL) -> String? {
        guard let recorded = record.identityKey.flatMap(FileIdentity.init(key:)), recorded.fileID != identity?.fileID,
              let path = FileIdentityResolver.currentPath(of: recorded, onVolumeOf: url), path != url.canonicalPath else { return nil }
        return path
    }

    public func record(id: String) -> ProjectRecord? {
        lock.lock(); defer { lock.unlock() }
        return first("WHERE id = ?", [.text(id)])
    }

    public func allRecords() -> [ProjectRecord] {
        lock.lock(); defer { lock.unlock() }
        return all("ORDER BY name COLLATE NOCASE", [])
    }

    // MARK: - External links

    /// Associates, or with `nil` disassociates, a Notion page. Purely additive: nothing
    /// else about the project depends on it.
    public func setNotionPageID(_ pageID: String?, for projectID: String) {
        lock.lock(); defer { lock.unlock() }
        _ = try? db.run(
            "UPDATE projects SET notion_page_id = ?, updated_at = ? WHERE id = ?",
            [pageID.map { .text($0) } ?? .null, .double(Date().timeIntervalSince1970), .text(projectID)]
        )
    }

    /// Records a person-confirmed Notion-to-local-project association.  This is kept in
    /// the private project store, not in the project directory.  Unlike the importer’s
    /// automatic matches, it refuses to replace either side of an established link;
    /// changing history should be an explicit future repair flow, never the result of
    /// selecting a similarly named folder in a review sheet.
    public func setExplicitNotionPageID(_ pageID: String, for projectID: String) throws {
        lock.lock(); defer { lock.unlock() }
        let normalized = pageID.replacingOccurrences(of: "-", with: "").lowercased()
        guard let project = first("WHERE id = ?", [.text(projectID)]) else {
            throw NotionLinkError.missingProject
        }
        if let existing = project.notionPageID,
           existing.replacingOccurrences(of: "-", with: "").lowercased() != normalized {
            throw NotionLinkError.projectAlreadyLinked
        }
        if let owner = first("WHERE LOWER(REPLACE(notion_page_id, '-', '')) = ? AND id != ?", [.text(normalized), .text(projectID)]), owner.id != projectID {
            throw NotionLinkError.notionPageAlreadyLinked
        }
        guard project.notionPageID != pageID else { return }
        try db.run(
            "UPDATE projects SET notion_page_id = ?, updated_at = ? WHERE id = ?",
            [.text(pageID), .double(Date().timeIntervalSince1970), .text(projectID)]
        )
    }

    public func setExternalIDs(watcherID: String?, documentID: String?, for projectID: String) {
        lock.lock(); defer { lock.unlock() }
        _ = try? db.run(
            "UPDATE projects SET watcher_id = ?, document_id = ?, updated_at = ? WHERE id = ?",
            [watcherID.map { .text($0) } ?? .null, documentID.map { .text($0) } ?? .null,
             .double(Date().timeIntervalSince1970), .text(projectID)]
        )
    }

    /// Joins projects to Workspace Watcher's ids by file identity, which both apps take
    /// from the same `stat` and which survives a rename on either side.
    ///
    /// Only fills a missing link. An existing one came from Better Projects' documents
    /// or an earlier pass and is never replaced, and an id already joined to another
    /// project is not handed out twice. Returns how many projects were linked.
    @discardableResult
    public func linkWatcherIDs(byIdentityKey watcherIDs: [String: String]) -> Int {
        lock.lock(); defer { lock.unlock() }
        guard watcherIDs.isEmpty == false else { return 0 }
        var taken = Set(all("WHERE watcher_id IS NOT NULL", []).compactMap(\.watcherID))
        var linked = 0
        for record in all("WHERE watcher_id IS NULL AND identity_key IS NOT NULL", []) {
            guard let key = record.identityKey, let watcherID = watcherIDs[key],
                  taken.contains(watcherID) == false
            else { continue }
            linked += (try? db.run(
                "UPDATE projects SET watcher_id = ?, updated_at = ? WHERE id = ? AND watcher_id IS NULL",
                [.text(watcherID), .double(Date().timeIntervalSince1970), .text(record.id)]
            )) ?? 0
            taken.insert(watcherID)
        }
        return linked
    }

    public func record(notionPageID: String) -> ProjectRecord? {
        lock.lock(); defer { lock.unlock() }
        return first("WHERE notion_page_id = ?", [.text(notionPageID)])
    }

    public func record(watcherID: String) -> ProjectRecord? {
        lock.lock(); defer { lock.unlock() }
        return first("WHERE watcher_id = ?", [.text(watcherID)])
    }

    /// Applies a group of changes as one transaction.
    ///
    /// Locks in the same order as every other method here — this store, then the
    /// database — so a batch cannot deadlock against an ordinary call.
    public func batch<T>(_ body: () throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        return try db.transaction(body)
    }

    // MARK: - Ratings

    public func ratings(for projectID: String) -> [String: Int] {
        lock.lock(); defer { lock.unlock() }
        let rows = (try? db.query(
            "SELECT metric_id, value FROM project_ratings WHERE project_id = ?",
            [.text(projectID)], row: { ($0.string(0), Int($0.int(1))) }
        )) ?? []
        return Dictionary(uniqueKeysWithValues: rows)
    }

    /// Records one answer. A `nil` value clears it, which is a real act — "I looked and
    /// decided not to say" is different from never having been asked, and only the
    /// absence of a row represents the latter.
    public func setRating(_ value: Int?, metricID: String, for projectID: String) {
        if value != nil { try? finishSetup(projectID) }
        lock.lock(); defer { lock.unlock() }
        guard let value else {
            _ = try? db.run("DELETE FROM project_ratings WHERE project_id = ? AND metric_id = ?",
                            [.text(projectID), .text(metricID)])
            return
        }
        let clamped = min(max(value, 1), 5)
        _ = try? db.run("""
            INSERT INTO project_ratings (project_id, metric_id, value, updated_at) VALUES (?,?,?,?)
            ON CONFLICT(project_id, metric_id) DO UPDATE SET value = excluded.value, updated_at = excluded.updated_at
            """, [.text(projectID), .text(metricID), .int(Int64(clamped)), .double(Date().timeIntervalSince1970)])
    }

    // MARK: - Description

    /// Read-only write times for this store's owned knowledge rows. These are
    /// upper bounds on field writes, not individual field edit timestamps. A
    /// newer row time alone does not prove a particular value was edited then.
    /// Missing rows intentionally have no inferred timestamp.
    public func knowledgeWriteTimes(for projectID: String) -> [String: Date] {
        lock.lock(); defer { lock.unlock() }
        var result: [String: Date] = [:]
        for (name, query) in [
            ("metadata", "SELECT updated_at FROM project_metadata WHERE project_id = ?"),
            ("description", "SELECT updated_at FROM project_descriptions WHERE project_id = ?")
        ] {
            if let raw = (try? db.query(query, [.text(projectID)], row: { $0.optionalDouble(0) }))?.first ?? nil {
                result[name] = Date(timeIntervalSince1970: raw)
            }
        }
        return result
    }

    /// A project's one-liner and summary, either of which may be absent.
    public func description(for projectID: String) -> ProjectDescription {
        lock.lock(); defer { lock.unlock() }
        let row = (try? db.query(
            "SELECT one_liner, summary FROM project_descriptions WHERE project_id = ?",
            [.text(projectID)], row: { ProjectDescription(oneLiner: $0.optionalString(0), summary: $0.optionalString(1)) }
        ))?.first
        return row ?? ProjectDescription()
    }

    /// Replaces a project's description. Blank text is stored as absent.
    public func setDescription(_ description: ProjectDescription, for projectID: String) {
        lock.lock(); defer { lock.unlock() }
        let cleaned = description.cleaned
        if !cleaned.isEmpty { try? finishSetup(projectID) }
        guard cleaned.isEmpty == false else {
            _ = try? db.run("DELETE FROM project_descriptions WHERE project_id = ?", [.text(projectID)])
            return
        }
        func value(_ text: String?) -> Database.Value { text.map { .text($0) } ?? .null }
        _ = try? db.run("""
            INSERT INTO project_descriptions (project_id, one_liner, summary, updated_at) VALUES (?,?,?,?)
            ON CONFLICT(project_id) DO UPDATE SET one_liner = excluded.one_liner, summary = excluded.summary,
                updated_at = excluded.updated_at
            """, [.text(projectID), value(cleaned.oneLiner), value(cleaned.summary), .double(Date().timeIntervalSince1970)])
    }

    /// Every project's ratings in one read, for the Projects table — which would
    /// otherwise issue one query per row across 383 projects.
    public func allRatings() -> [String: [String: Int]] {
        lock.lock(); defer { lock.unlock() }
        let rows = (try? db.query(
            "SELECT project_id, metric_id, value FROM project_ratings", [],
            row: { ($0.string(0), $0.string(1), Int($0.int(2))) }
        )) ?? []
        var out: [String: [String: Int]] = [:]
        for (project, metric, value) in rows { out[project, default: [:]][metric] = value }
        return out
    }

    public func score(for projectID: String) -> ProjectScore {
        ProjectScore(ratings: ratings(for: projectID))
    }

    /// Every project by identity, read once, for matching many folders (an Ideas refresh).
    /// The same rule as `record(matching:at:)`: an exact key, else the one record whose
    /// key carries a legacy device number for that inode and whose folder is no longer
    /// where it was recorded. Used to follow projects moved out of Projects after a
    /// restart changed `st_dev`.
    public struct IdentityIndex: Sendable {
        private let exact: [String: ProjectRecord]
        private let legacy: [UInt64: [ProjectRecord]]
        init(_ records: [ProjectRecord]) {
            exact = Dictionary(records.compactMap { record in record.identityKey.map { ($0, record) } }, uniquingKeysWith: { first, _ in first })
            legacy = Dictionary(grouping: records.filter { $0.identityKey.flatMap(FileIdentity.init(key:))?.hasLegacyVolume == true },
                                by: { FileIdentity(key: $0.identityKey!)!.fileID })
        }
        public func record(for identity: FileIdentity, at path: String) -> ProjectRecord? {
            if let match = exact[identity.key] { return match }
            let candidates = (legacy[identity.fileID] ?? []).filter { $0.lastPath == path || !FileManager.default.fileExists(atPath: $0.lastPath) }
            return candidates.count == 1 ? candidates[0] : nil
        }
    }

    public func identityIndex() -> IdentityIndex { IdentityIndex(allRecords()) }

    // MARK: - Private

    /// The record for the folder with this identity: the exact key, else the one record
    /// whose key was written with a legacy device number for the same inode
    /// (`FileIdentity.hasLegacyVolume`) and whose recorded folder is no longer there.
    /// Without the legacy match, a project renamed in Finder before its key was upgraded
    /// fell back to its path and either became a new project or claimed whichever
    /// record still held that path (Current State → Better Signals, October 2026).
    private func record(matching identity: FileIdentity, at path: String) -> ProjectRecord? {
        if let exact = first("WHERE identity_key = ?", [.text(identity.key)]) { return exact }
        let legacy = all("WHERE identity_key LIKE ?", [.text("%:\(identity.fileID)")]).filter { record in
            guard let recorded = record.identityKey.flatMap(FileIdentity.init(key:)),
                  recorded.hasLegacyVolume, recorded == identity else { return false }
            return record.lastPath == path || !FileManager.default.fileExists(atPath: record.lastPath)
        }
        return legacy.count == 1 ? legacy[0] : nil
    }

    /// Moves a record to the folder its identity was found at. Another record still
    /// naming that path is stale — the folder there is this one — so it is moved aside
    /// to a path that cannot exist, keeping its id, links, ratings and metadata. A
    /// silently failed update here once left two identities publishing one folder.
    private func relocate(_ record: ProjectRecord, to path: String, name: String, identity: FileIdentity, at now: Date) {
        _ = try? db.transaction {
            if record.lastPath != path, !record.lastPath.contains("/.bw-superseded-") {
                try recordAlias(record.lastPath, for: record.id)
            }
            if record.lastPath != path, let holder = first("WHERE last_path = ? AND id <> ?", [.text(path), .text(record.id)]) {
                let aside = (path as NSString).deletingLastPathComponent + "/.bw-superseded-" + holder.id
                try db.run("UPDATE projects SET last_path = ?, updated_at = ? WHERE id = ?",
                           [.text(aside), .double(now.timeIntervalSince1970), .text(holder.id)])
            }
            try db.run("UPDATE projects SET last_path = ?, name = ?, identity_key = ?, updated_at = ? WHERE id = ?",
                       [.text(path), .text(name), .text(identity.key), .double(now.timeIntervalSince1970), .text(record.id)])
        }
    }

    /// Paths projects have left in Finder (renames and moves), each with the one project
    /// that left it. Work files are never rewritten, so a `project:` line naming an old
    /// path still means that project. A path left by two different projects means neither.
    public func pathAliases() -> [String: String] {
        lock.lock(); defer { lock.unlock() }
        let rows = (try? db.query("SELECT path, project_id FROM project_path_aliases WHERE project_id <> ''", []) { ($0.string(0), $0.string(1)) }) ?? []
        return Dictionary(rows, uniquingKeysWith: { first, _ in first })
    }

    private func recordAlias(_ path: String, for projectID: String) throws {
        try db.execute("CREATE TABLE IF NOT EXISTS project_path_aliases (path TEXT PRIMARY KEY, project_id TEXT NOT NULL)")
        try db.run("""
            INSERT INTO project_path_aliases (path, project_id) VALUES (?, ?)
            ON CONFLICT(path) DO UPDATE SET project_id = CASE WHEN project_id = excluded.project_id THEN project_id ELSE '' END
            """, [.text(path), .text(projectID)])
    }

    private static let columns =
        "id, identity_key, last_path, name, notion_page_id, watcher_id, document_id, created_at, updated_at"

    private func all(_ clause: String, _ params: [Database.Value]) -> [ProjectRecord] {
        (try? db.query("SELECT \(Self.columns) FROM projects \(clause)", params) { row in
            ProjectRecord(
                id: row.string(0), identityKey: row.optionalString(1), lastPath: row.string(2),
                name: row.string(3), notionPageID: row.optionalString(4),
                watcherID: row.optionalString(5), documentID: row.optionalString(6),
                createdAt: row.date(7), updatedAt: row.date(8)
            )
        }) ?? []
    }

    private func first(_ clause: String, _ params: [Database.Value]) -> ProjectRecord? {
        all(clause + " LIMIT 1", params).first
    }

    private func insert(_ record: ProjectRecord) {
        _ = try? db.run("""
            INSERT OR IGNORE INTO projects (\(Self.columns)) VALUES (?,?,?,?,?,?,?,?,?)
            """, [
                .text(record.id),
                record.identityKey.map { .text($0) } ?? .null,
                .text(record.lastPath), .text(record.name),
                record.notionPageID.map { .text($0) } ?? .null,
                record.watcherID.map { .text($0) } ?? .null,
                record.documentID.map { .text($0) } ?? .null,
                .double(record.createdAt.timeIntervalSince1970),
                .double(record.updatedAt.timeIntervalSince1970),
            ])
    }
}

/// What a project is, in a person's words.
public struct ProjectDescription: Hashable, Sendable {
    public var oneLiner: String?
    public var summary: String?

    public init(oneLiner: String? = nil, summary: String? = nil) {
        self.oneLiner = oneLiner
        self.summary = summary
    }

    public var isEmpty: Bool { oneLiner == nil && summary == nil }

    var cleaned: ProjectDescription {
        func clean(_ text: String?) -> String? {
            guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), text.isEmpty == false else { return nil }
            return text
        }
        return ProjectDescription(oneLiner: clean(oneLiner), summary: clean(summary))
    }
}

/// Small portfolio-facing references imported only after an explicit review.  They
/// are intentionally a summary of relationships, not a second copy of the related
/// Notion databases or media files.
public struct ProjectPortfolioDetails: Hashable, Sendable, Codable {
    public var featured: Bool?
    public var inShowcase: Bool?
    public var isPublic: Bool?
    public var customLinks: [ProjectLink]?
    public var githubURL: String?
    public var websiteURL: String?
    public var resourceReferences: [String]
    public var collectionReferences: [String]
    public var mediaReferences: [String]
    /// These are source references only. Better Workspace keeps its own portable work
    /// records separately and never copies related Notion pages into a project folder.
    public var taskReferences: [String]
    public var featureReferences: [String]
    public var milestoneReferences: [String]
    public var workLogReferences: [String]

    private enum CodingKeys: String, CodingKey {
        case featured, inShowcase, isPublic, customLinks
        case githubURL, websiteURL, resourceReferences, collectionReferences, mediaReferences
        case taskReferences, featureReferences, milestoneReferences, workLogReferences
    }

    public init(githubURL: String? = nil, websiteURL: String? = nil,
                resourceReferences: [String] = [], collectionReferences: [String] = [],
                mediaReferences: [String] = [], taskReferences: [String] = [],
                featureReferences: [String] = [], milestoneReferences: [String] = [],
                workLogReferences: [String] = [], featured: Bool? = nil, inShowcase: Bool? = nil, isPublic: Bool? = nil) {
        self.featured = featured; self.inShowcase = inShowcase; self.isPublic = isPublic
        self.githubURL = Self.clean(githubURL)
        self.websiteURL = Self.clean(websiteURL)
        self.resourceReferences = Self.cleaned(resourceReferences)
        self.collectionReferences = Self.cleaned(collectionReferences)
        self.mediaReferences = Self.cleaned(mediaReferences)
        self.taskReferences = Self.cleaned(taskReferences)
        self.featureReferences = Self.cleaned(featureReferences)
        self.milestoneReferences = Self.cleaned(milestoneReferences)
        self.workLogReferences = Self.cleaned(workLogReferences)
    }

    public var isEmpty: Bool {
        featured == nil && inShowcase == nil && isPublic == nil && (customLinks ?? []).isEmpty
            && githubURL == nil && websiteURL == nil && resourceReferences.isEmpty
            && collectionReferences.isEmpty && mediaReferences.isEmpty && taskReferences.isEmpty
            && featureReferences.isEmpty && milestoneReferences.isEmpty && workLogReferences.isEmpty
    }

    /// Portfolio details live in private SQLite JSON. Decode old rows written before
    /// planning-reference counts existed instead of making a schema addition erase a
    /// person's reviewed links on first read.
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            githubURL: try values.decodeIfPresent(String.self, forKey: .githubURL),
            websiteURL: try values.decodeIfPresent(String.self, forKey: .websiteURL),
            resourceReferences: try values.decodeIfPresent([String].self, forKey: .resourceReferences) ?? [],
            collectionReferences: try values.decodeIfPresent([String].self, forKey: .collectionReferences) ?? [],
            mediaReferences: try values.decodeIfPresent([String].self, forKey: .mediaReferences) ?? [],
            taskReferences: try values.decodeIfPresent([String].self, forKey: .taskReferences) ?? [],
            featureReferences: try values.decodeIfPresent([String].self, forKey: .featureReferences) ?? [],
            milestoneReferences: try values.decodeIfPresent([String].self, forKey: .milestoneReferences) ?? [],
            workLogReferences: try values.decodeIfPresent([String].self, forKey: .workLogReferences) ?? []
        )
        featured = try values.decodeIfPresent(Bool.self, forKey: .featured)
        inShowcase = try values.decodeIfPresent(Bool.self, forKey: .inShowcase)
        isPublic = try values.decodeIfPresent(Bool.self, forKey: .isPublic)
        customLinks = try values.decodeIfPresent([ProjectLink].self, forKey: .customLinks)
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encodeIfPresent(featured, forKey: .featured)
        try values.encodeIfPresent(inShowcase, forKey: .inShowcase)
        try values.encodeIfPresent(isPublic, forKey: .isPublic)
        try values.encodeIfPresent(customLinks, forKey: .customLinks)
        try values.encodeIfPresent(githubURL, forKey: .githubURL)
        try values.encodeIfPresent(websiteURL, forKey: .websiteURL)
        try values.encode(resourceReferences, forKey: .resourceReferences)
        try values.encode(collectionReferences, forKey: .collectionReferences)
        try values.encode(mediaReferences, forKey: .mediaReferences)
        try values.encode(taskReferences, forKey: .taskReferences)
        try values.encode(featureReferences, forKey: .featureReferences)
        try values.encode(milestoneReferences, forKey: .milestoneReferences)
        try values.encode(workLogReferences, forKey: .workLogReferences)
    }

    private static func clean(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), trimmed.isEmpty == false else { return nil }
        return trimmed
    }

    private static func cleaned(_ values: [String]) -> [String] {
        Array(Set(values.compactMap(clean))).sorted()
    }
}

// MARK: - Portfolio metadata

/// The small, intentionally curated vocabulary Better Workspace owns about a
/// project.  It mirrors useful planning concepts without turning an optional Notion
/// database into a requirement or writing a sidecar into the project folder.
public struct ProjectMetadata: Hashable, Sendable, Codable {
    public var domain: String?
    public var status: String?
    public var phase: String?
    public var completionModel: String?
    public var maintenanceCadence: String?
    public var projectType: String?
    public var workModes: [String]
    public var currentWork: [String]
    public var nextWork: [String]
    public var recentWork: [String]
    public var blockers: [String]
    public var statusDetail: String?
    public var startedAt: Date?
    public var lastUpdateAt: Date?
    /// Imported as evidence only; the live Notion field is not a generic priority.
    public var trackingPriority: Double?
    /// A local, deliberate 1...5 portfolio triage signal.
    public var portfolioPriority: Int?

    public init(domain: String? = nil, status: String? = nil, phase: String? = nil,
                completionModel: String? = nil, maintenanceCadence: String? = nil,
                projectType: String? = nil, workModes: [String] = [], currentWork: [String] = [],
                nextWork: [String] = [], recentWork: [String] = [], blockers: [String] = [],
                statusDetail: String? = nil, startedAt: Date? = nil, lastUpdateAt: Date? = nil,
                trackingPriority: Double? = nil, portfolioPriority: Int? = nil) {
        self.domain = domain; self.status = status; self.phase = phase
        self.completionModel = completionModel; self.maintenanceCadence = maintenanceCadence
        self.projectType = projectType; self.workModes = workModes; self.currentWork = currentWork
        self.nextWork = nextWork; self.recentWork = recentWork; self.blockers = blockers
        self.statusDetail = statusDetail; self.startedAt = startedAt; self.lastUpdateAt = lastUpdateAt
        self.trackingPriority = trackingPriority; self.portfolioPriority = portfolioPriority
    }

    public var isEmpty: Bool {
        domain == nil && status == nil && phase == nil && completionModel == nil && maintenanceCadence == nil
            && projectType == nil && workModes.isEmpty && currentWork.isEmpty && nextWork.isEmpty
            && recentWork.isEmpty && blockers.isEmpty && statusDetail == nil && startedAt == nil
            && lastUpdateAt == nil && trackingPriority == nil && portfolioPriority == nil
    }

    public var isTerminal: Bool {
        let value = (status ?? "").lowercased()
        return ["complete", "archived", "abandoned", "deprecated"].contains { value.contains($0) }
    }

    public var isUnavailableForNextWork: Bool {
        let value = (status ?? "").lowercased()
        return isTerminal || value.contains("paused") || value.contains("blocked")
    }

    /// An intentionally local triage signal.  It is distinct from Notion's historic
    /// `tracking priority` and from a work item's execution priority.
    public var portfolioPriorityLabel: String {
        switch portfolioPriority {
        case 5: return "5 — Critical"
        case 4: return "4 — High"
        case 3: return "3 — Normal"
        case 2: return "2 — Low"
        case 1: return "1 — Someday"
        default: return "Untriaged"
        }
    }

    /// Untriaged projects are deliberately neutral in the recommendation ordering;
    /// this value is shown in the explanation rather than becoming an invisible rule.
    public var portfolioPriorityForRecommendation: Int { portfolioPriority ?? 3 }
}

public struct ProjectScoringPreferences: Hashable, Sendable, Codable {
    public var enabledMetricIDs: Set<String>
    public var enabledGroupIDs: Set<String>
    public var groupWeights: [String: Double]

    public init(enabledMetricIDs: Set<String> = Set(MetricDefinition.all.map(\.id)),
                enabledGroupIDs: Set<String> = Set(MetricGroup.allGroups.map(\.id)),
                groupWeights: [String: Double] = MetricGroup.defaultWeights) {
        self.enabledMetricIDs = enabledMetricIDs
        self.enabledGroupIDs = enabledGroupIDs
        self.groupWeights = groupWeights
    }
    private enum CodingKeys: String, CodingKey { case enabledMetricIDs, enabledGroupIDs, groupWeights }
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(enabledMetricIDs.sorted(), forKey: .enabledMetricIDs)
        try values.encode(enabledGroupIDs.sorted(), forKey: .enabledGroupIDs)
        try values.encode(groupWeights, forKey: .groupWeights)
    }
}

public extension ProjectStore {
    func portfolioDetails(for projectID: String) -> ProjectPortfolioDetails {
        lock.lock(); defer { lock.unlock() }
        guard let raw = (try? db.query("SELECT details_json FROM project_portfolio_details WHERE project_id = ?",
                                       [.text(projectID)]) { $0.string(0) })?.first,
              let data = raw.data(using: .utf8),
              let details = try? JSONDecoder().decode(ProjectPortfolioDetails.self, from: data)
        else { return .init() }
        return details
    }

    func setPortfolioDetails(_ details: ProjectPortfolioDetails, for projectID: String) {
        lock.lock(); defer { lock.unlock() }
        if details.isEmpty {
            _ = try? db.run("DELETE FROM project_portfolio_details WHERE project_id = ?", [.text(projectID)])
            return
        }
        guard let data = try? JSONEncoder().encode(details), let raw = String(data: data, encoding: .utf8) else { return }
        _ = try? db.run("""
            INSERT INTO project_portfolio_details (project_id,details_json,updated_at) VALUES (?,?,?)
            ON CONFLICT(project_id) DO UPDATE SET details_json=excluded.details_json, updated_at=excluded.updated_at
            """, [.text(projectID), .text(raw), .double(Date().timeIntervalSince1970)])
    }

    func savePortfolioDetails(_ details: ProjectPortfolioDetails, for projectID: String) throws {
        lock.lock(); defer { lock.unlock() }
        let data = try JSONEncoder().encode(details)
        try db.run("INSERT INTO project_portfolio_details(project_id,details_json,updated_at) VALUES (?,?,?) ON CONFLICT(project_id) DO UPDATE SET details_json=excluded.details_json,updated_at=excluded.updated_at", [.text(projectID), .text(String(decoding: data, as: UTF8.self)), .double(Date().timeIntervalSince1970)])
    }

    func metadata(for projectID: String) -> ProjectMetadata {
        lock.lock(); defer { lock.unlock() }
        guard let metadata = (try? db.query("""
            SELECT domain,status,phase,completion_model,maintenance_cadence,project_type,
                   work_modes_json,current_work_json,next_work_json,recent_work_json,blockers_json,
                   status_detail,started_at,last_update_at,tracking_priority,portfolio_priority
            FROM project_metadata WHERE project_id = ?
            """, [.text(projectID)]) { Self.metadata(from: $0) })?.first else { return ProjectMetadata() }
        return metadata
    }

    func allMetadata() -> [String: ProjectMetadata] {
        lock.lock(); defer { lock.unlock() }
        let rows = (try? db.query("""
            SELECT project_id,domain,status,phase,completion_model,maintenance_cadence,project_type,
                   work_modes_json,current_work_json,next_work_json,recent_work_json,blockers_json,
                   status_detail,started_at,last_update_at,tracking_priority,portfolio_priority
            FROM project_metadata
            """, []) { row -> (String, ProjectMetadata) in
                return (row.string(0), Self.metadata(withProjectIDRow: row))
            }) ?? []
        return Dictionary(uniqueKeysWithValues: rows)
    }

    func setMetadata(_ metadata: ProjectMetadata, for projectID: String) {
        try? saveMetadata(metadata, for: projectID)
    }

    func saveMetadata(_ metadata: ProjectMetadata, for projectID: String) throws {
        lock.lock(); defer { lock.unlock() }
        if metadata.isEmpty {
            _ = try db.run("DELETE FROM project_metadata WHERE project_id = ?", [.text(projectID)])
            return
        }
        func text(_ value: String?) -> Database.Value { value.map(Database.Value.text) ?? .null }
        func date(_ value: Date?) -> Database.Value { value.map { .double($0.timeIntervalSince1970) } ?? .null }
        func number(_ value: Double?) -> Database.Value { value.map(Database.Value.double) ?? .null }
        let priority = metadata.portfolioPriority.map { Database.Value.int(Int64(min(5, max(1, $0)))) } ?? .null
        _ = try db.run("""
            INSERT INTO project_metadata (project_id,domain,status,phase,completion_model,maintenance_cadence,project_type,
              work_modes_json,current_work_json,next_work_json,recent_work_json,blockers_json,status_detail,
              started_at,last_update_at,tracking_priority,portfolio_priority,updated_at)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            ON CONFLICT(project_id) DO UPDATE SET domain=excluded.domain,status=excluded.status,phase=excluded.phase,
              completion_model=excluded.completion_model,maintenance_cadence=excluded.maintenance_cadence,
              project_type=excluded.project_type,work_modes_json=excluded.work_modes_json,current_work_json=excluded.current_work_json,
              next_work_json=excluded.next_work_json,recent_work_json=excluded.recent_work_json,blockers_json=excluded.blockers_json,
              status_detail=excluded.status_detail,started_at=excluded.started_at,last_update_at=excluded.last_update_at,
              tracking_priority=excluded.tracking_priority,portfolio_priority=excluded.portfolio_priority,updated_at=excluded.updated_at
            """, [.text(projectID), text(metadata.domain), text(metadata.status), text(metadata.phase),
                    text(metadata.completionModel), text(metadata.maintenanceCadence), text(metadata.projectType),
                    .text(Self.json(metadata.workModes)), .text(Self.json(metadata.currentWork)), .text(Self.json(metadata.nextWork)),
                    .text(Self.json(metadata.recentWork)), .text(Self.json(metadata.blockers)), text(metadata.statusDetail),
                    date(metadata.startedAt), date(metadata.lastUpdateAt), number(metadata.trackingPriority), priority,
                    .double(Date().timeIntervalSince1970)])
    }

    func relatedProjectIDs(for projectID: String) -> Set<String> {
        let ids = (try? db.query("SELECT target_project_id FROM project_relationships WHERE source_project_id = ?", [.text(projectID)]) { $0.string(0) }) ?? []
        return Set(ids)
    }

    func setRelatedProjectIDs(_ targetIDs: Set<String>, for projectID: String) {
        lock.lock(); defer { lock.unlock() }
        try? db.transaction {
            try db.run("DELETE FROM project_relationships WHERE source_project_id = ?", [.text(projectID)])
            for target in targetIDs where target != projectID {
                try db.run("INSERT OR IGNORE INTO project_relationships (source_project_id,target_project_id,created_at) VALUES (?,?,?)",
                           [.text(projectID), .text(target), .double(Date().timeIntervalSince1970)])
            }
        }
    }

    func scoringPreferences() -> ProjectScoringPreferences {
        guard let raw = (try? db.query("SELECT value_json FROM project_scoring_preferences WHERE preference_key = 'portfolio'", []) { $0.string(0) })?.first,
              let data = raw.data(using: .utf8), let decoded = try? JSONDecoder().decode(ProjectScoringPreferences.self, from: data)
        else { return ProjectScoringPreferences() }
        return decoded
    }

    func setScoringPreferences(_ preferences: ProjectScoringPreferences) {
        guard let data = try? JSONEncoder().encode(preferences), let raw = String(data: data, encoding: .utf8) else { return }
        _ = try? db.run("""
            INSERT INTO project_scoring_preferences (preference_key,value_json,updated_at) VALUES ('portfolio',?,?)
            ON CONFLICT(preference_key) DO UPDATE SET value_json=excluded.value_json,updated_at=excluded.updated_at
            """, [.text(raw), .double(Date().timeIntervalSince1970)])
    }

    private static func json(_ values: [String]) -> String {
        let cleaned = Array(Set(values.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })).sorted()
        let data = (try? JSONEncoder().encode(cleaned)) ?? Data("[]".utf8)
        return String(data: data, encoding: .utf8) ?? "[]"
    }

    private static func strings(_ raw: String?) -> [String] {
        guard let raw, let data = raw.data(using: .utf8), let values = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return values
    }

    private static func metadata(from row: Database.Row) -> ProjectMetadata {
        ProjectMetadata(domain: row.optionalString(0), status: row.optionalString(1), phase: row.optionalString(2),
                        completionModel: row.optionalString(3), maintenanceCadence: row.optionalString(4), projectType: row.optionalString(5),
                        workModes: strings(row.optionalString(6)), currentWork: strings(row.optionalString(7)),
                        nextWork: strings(row.optionalString(8)), recentWork: strings(row.optionalString(9)), blockers: strings(row.optionalString(10)),
                        statusDetail: row.optionalString(11), startedAt: row.optionalDouble(12).map(Date.init(timeIntervalSince1970:)),
                        lastUpdateAt: row.optionalDouble(13).map(Date.init(timeIntervalSince1970:)),
                        trackingPriority: row.optionalDouble(14), portfolioPriority: row.optionalDouble(15).map { Int($0) })
    }

    private static func metadata(withProjectIDRow row: Database.Row) -> ProjectMetadata {
        // Column 0 belongs to the project id; the remaining positions mirror metadata(from:).
        ProjectMetadata(domain: row.optionalString(1), status: row.optionalString(2), phase: row.optionalString(3),
                        completionModel: row.optionalString(4), maintenanceCadence: row.optionalString(5), projectType: row.optionalString(6),
                        workModes: strings(row.optionalString(7)), currentWork: strings(row.optionalString(8)),
                        nextWork: strings(row.optionalString(9)), recentWork: strings(row.optionalString(10)), blockers: strings(row.optionalString(11)),
                        statusDetail: row.optionalString(12), startedAt: row.optionalDouble(13).map(Date.init(timeIntervalSince1970:)),
                        lastUpdateAt: row.optionalDouble(14).map(Date.init(timeIntervalSince1970:)),
                        trackingPriority: row.optionalDouble(15), portfolioPriority: row.optionalDouble(16).map { Int($0) })
    }
}
