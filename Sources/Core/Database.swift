import Foundation
import SQLite3

/// Minimal SQLite wrapper over the system `libsqlite3`.
///
/// Chosen over SwiftData/Core Data for this prototype because the store is tiny,
/// the schema is three tables, and a plain file with no framework migration machinery
/// is the easiest thing to reason about, inspect and throw away. `libsqlite3` is a
/// system library, so this adds no third-party dependency.
public final class Database: @unchecked Sendable {

    public enum DBError: Error, CustomStringConvertible {
        case open(String)
        case prepare(String)
        case step(String)
        public var description: String {
            switch self {
            case .open(let m): return "sqlite open failed: \(m)"
            case .prepare(let m): return "sqlite prepare failed: \(m)"
            case .step(let m): return "sqlite step failed: \(m)"
            }
        }
    }

    private var handle: OpaquePointer?
    private let lock = NSRecursiveLock()
    public let url: URL

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    /// `~/Library/Application Support/BetterWorkspace/betterworkspace.sqlite`
    ///
    /// This app's private storage. Nothing here is ever written into `~/Workspace`.
    public static func defaultURL() throws -> URL {
        #if DEBUG
        // Launch-only override for isolated UI tests; never persisted to preferences.
        if let path = ProcessInfo.processInfo.environment["BW_TEST_DATABASE_PATH"] {
            return URL(fileURLWithPath: path)
        }
        #endif
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        ).appendingPathComponent("BetterWorkspace", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("betterworkspace.sqlite")
    }

    /// The same location, answered without throwing, so opening the store is never
    /// blocked on being able to *ask* where it goes.
    public static func preferredURL() -> URL {
        if let url = try? defaultURL() { return url }
        return URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent("Library/Application Support/BetterWorkspace", isDirectory: true)
            .appendingPathComponent("betterworkspace.sqlite")
    }

    /// Where the store ended up, which is not always where it was asked to go.
    public enum Backing: Sendable, Equatable {
        case file(URL)
        /// The file on disk could not be opened, so it was moved aside and a new store
        /// started in its place. The old file is kept: it may still be recoverable, and
        /// deleting someone's tags to get the app open is not this app's call.
        case recovered(movedAside: URL)
        /// Nothing on disk could be opened at all. Tags and ratings last for this
        /// session only, and the app has to say so.
        case memory
    }

    /// Opens the store, and keeps the app openable when it cannot.
    ///
    /// Three steps, in order of how much is kept: open the real file; if that fails,
    /// move it aside and start a fresh one in the same place, so everything from here on
    /// is saved where it belongs; and only if even that fails, run in memory. This
    /// replaces a force-unwrapped temp-file fallback that turned an unopenable store
    /// into a launch crash, and that — when it did work — wrote tags into a directory
    /// the system is free to empty.
    public static func opened(preferring url: URL) -> (database: Database, backing: Backing) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        if let database = try? Database(url: url) { return (database, .file(url)) }

        let movedAside = url.deletingLastPathComponent().appendingPathComponent(
            url.lastPathComponent + ".unreadable-" + Self.stamp())
        if (try? FileManager.default.moveItem(at: url, to: movedAside)) != nil,
           let database = try? Database(url: url) {
            return (database, .recovered(movedAside: movedAside))
        }

        // `try!` is safe here in the way the previous fallback was not: an in-memory
        // database needs no filesystem, no permissions and no free space.
        return (try! Database(inMemory: true), .memory)
    }

    private static func stamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return formatter.string(from: Date())
    }

    public convenience init(url: URL) throws {
        try self.init(path: url.path, url: url)
    }

    /// A store that exists only while the app is running. The last resort, and the one
    /// thing that cannot fail for an environmental reason.
    public convenience init(inMemory: Bool) throws {
        try self.init(path: ":memory:", url: URL(fileURLWithPath: "/dev/null"))
    }

    private init(path: String, url: URL) throws {
        self.url = url
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &db, flags, nil) == SQLITE_OK, let db else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "could not open \(path)"
            if let db { sqlite3_close_v2(db) }
            throw DBError.open(message)
        }
        handle = db
        // WAL needs a file to write beside; an in-memory store stays in its default
        // journal mode, which is exactly right for something with nothing to recover.
        if path != ":memory:" { try execute("PRAGMA journal_mode=WAL;") }
        try execute("PRAGMA foreign_keys=ON;")
        // A UI test runs its own copy of the app while this one may still be shutting
        // down, and WAL lets a reader and a writer overlap but not two writers. Without
        // a busy timeout the loser fails instantly and the write is silently dropped by
        // the `try?` at the call site.
        try execute("PRAGMA busy_timeout=3000;")
        try migrate()
    }

    deinit { if let handle { sqlite3_close_v2(handle) } }

    // MARK: - Schema

    private func migrate() throws {
        try execute("""
        CREATE TABLE IF NOT EXISTS tags (
            id          TEXT PRIMARY KEY,
            name        TEXT NOT NULL,
            color_index INTEGER NOT NULL DEFAULT 0,
            created_at  REAL NOT NULL
        );
        CREATE UNIQUE INDEX IF NOT EXISTS idx_tags_name ON tags (name COLLATE NOCASE);

        -- One row per filesystem object this app has ever been asked to remember.
        -- `identity_key` is "<volumeID>:<inode>"; `last_path` is a hint used to
        -- recover identity when the inode changes (e.g. a copy-on-move across a
        -- file provider boundary).
        CREATE TABLE IF NOT EXISTS objects (
            identity_key TEXT PRIMARY KEY,
            last_path    TEXT NOT NULL,
            display_name TEXT NOT NULL,
            area         TEXT,
            updated_at   REAL NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_objects_path ON objects (last_path);

        CREATE TABLE IF NOT EXISTS assignments (
            object_key TEXT NOT NULL REFERENCES objects(identity_key) ON DELETE CASCADE ON UPDATE CASCADE,
            tag_id     TEXT NOT NULL REFERENCES tags(id) ON DELETE CASCADE,
            created_at REAL NOT NULL,
            PRIMARY KEY (object_key, tag_id)
        );
        CREATE INDEX IF NOT EXISTS idx_assignments_tag ON assignments (tag_id);

        -- Private, temporary metadata about items sitting in the ingest inbox.
        -- The captured content itself is always a real file on disk; this table only
        -- augments it. Once the item is classified its inbox row is discarded and a
        -- `filed` row records where this app put it, for Ingest's Recently Filed; those
        -- rows expire after two weeks.
        CREATE TABLE IF NOT EXISTS ingest_items (
            identity_key TEXT PRIMARY KEY,
            last_path    TEXT NOT NULL,
            captured_at  REAL NOT NULL,
            source       TEXT NOT NULL,
            title        TEXT,
            state        TEXT NOT NULL,
            destination  TEXT,
            deferred_at  REAL,
            filed_at     REAL
        );

        -- What this app knows about a project directory, beyond what the directory
        -- itself says. The row is not the project: the folder is. Delete this table
        -- and the Workspace is untouched; every column is recoverable or re-enterable.
        --
        -- `id` is this app's own. A Notion page id is a nullable *attribute*, never the
        -- key, because Better Workspace has to be completely usable by someone who has
        -- never had a Notion account. `watcher_id` and `document_id` are likewise
        -- optional, carried across from the systems this one absorbs so their existing
        -- data can be joined rather than stranded.
        CREATE TABLE IF NOT EXISTS projects (
            id             TEXT PRIMARY KEY,
            identity_key   TEXT,
            last_path      TEXT NOT NULL,
            name           TEXT NOT NULL,
            notion_page_id TEXT,
            watcher_id     TEXT,
            document_id    TEXT,
            created_at     REAL NOT NULL,
            updated_at     REAL NOT NULL
        );
        CREATE UNIQUE INDEX IF NOT EXISTS idx_projects_path ON projects (last_path);
        CREATE INDEX IF NOT EXISTS idx_projects_identity ON projects (identity_key);
        CREATE INDEX IF NOT EXISTS idx_projects_notion ON projects (notion_page_id);

        -- What a project is, in a person's words: a one-liner and a longer summary.
        -- Carried over from Better Projects (which mirrored Notion's Projects database)
        -- and editable here. Hangs off the project row, like ratings, so it survives a
        -- rename or a move.
        CREATE TABLE IF NOT EXISTS project_descriptions (
            project_id TEXT PRIMARY KEY REFERENCES projects(id) ON DELETE CASCADE ON UPDATE CASCADE,
            one_liner  TEXT,
            summary    TEXT,
            updated_at REAL NOT NULL
        );

        -- A compact, imported portfolio projection. It deliberately stores only
        -- external links and relation references, never a mirror of Notion pages or
        -- project files. This lets a project workspace explain its associated media,
        -- collections, and resources while keeping those systems authoritative.
        CREATE TABLE IF NOT EXISTS project_portfolio_details (
            project_id   TEXT PRIMARY KEY REFERENCES projects(id) ON DELETE CASCADE ON UPDATE CASCADE,
            details_json TEXT NOT NULL,
            updated_at   REAL NOT NULL
        );

        -- One answered metric. Ratings are local, authoritative, and survive the
        -- project being renamed or moved because they hang off the project row rather
        -- than a path. Retired metric ids are kept here and simply not counted.
        CREATE TABLE IF NOT EXISTS project_ratings (
            project_id TEXT NOT NULL REFERENCES projects(id) ON DELETE CASCADE ON UPDATE CASCADE,
            metric_id  TEXT NOT NULL,
            value      INTEGER NOT NULL,
            updated_at REAL NOT NULL,
            PRIMARY KEY (project_id, metric_id)
        );

        -- Curated, local-first project metadata.  These are notes *about* a folder,
        -- never a second copy of its contents; every field remains useful without
        -- Notion and no row is written beside a project on disk.
        CREATE TABLE IF NOT EXISTS project_metadata (
            project_id           TEXT PRIMARY KEY REFERENCES projects(id) ON DELETE CASCADE ON UPDATE CASCADE,
            domain               TEXT,
            status               TEXT,
            phase                TEXT,
            completion_model     TEXT,
            maintenance_cadence  TEXT,
            project_type         TEXT,
            work_modes_json      TEXT NOT NULL DEFAULT '[]',
            current_work_json    TEXT NOT NULL DEFAULT '[]',
            next_work_json       TEXT NOT NULL DEFAULT '[]',
            recent_work_json     TEXT NOT NULL DEFAULT '[]',
            blockers_json        TEXT NOT NULL DEFAULT '[]',
            status_detail        TEXT,
            started_at           REAL,
            last_update_at       REAL,
            tracking_priority    REAL,
            portfolio_priority   INTEGER,
            updated_at           REAL NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_project_metadata_domain ON project_metadata(domain);
        CREATE INDEX IF NOT EXISTS idx_project_metadata_status ON project_metadata(status);
        CREATE INDEX IF NOT EXISTS idx_project_metadata_phase ON project_metadata(phase);

        -- Local relationships only.  A Notion relation is imported only when both
        -- endpoints are known local project records; opaque remote ids stay remote.
        CREATE TABLE IF NOT EXISTS project_relationships (
            source_project_id TEXT NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
            target_project_id TEXT NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
            created_at        REAL NOT NULL,
            PRIMARY KEY (source_project_id, target_project_id),
            CHECK (source_project_id != target_project_id)
        );

        -- Portfolio scoring is a person-level preference, not project content.
        CREATE TABLE IF NOT EXISTS project_scoring_preferences (
            preference_key TEXT PRIMARY KEY,
            value_json     TEXT NOT NULL,
            updated_at     REAL NOT NULL
        );

        -- Private bookkeeping for the disposable mobile CloudKit projection. These
        -- rows never own Workspace content: they only retain record revisions and
        -- intent acknowledgements so retries cannot replay a local mutation.
        CREATE TABLE IF NOT EXISTS mobile_cloud_projection (
            scope       TEXT NOT NULL,
            record_key  TEXT NOT NULL,
            fingerprint TEXT NOT NULL,
            revision    INTEGER NOT NULL,
            updated_at  REAL NOT NULL,
            PRIMARY KEY (scope, record_key)
        );
        CREATE TABLE IF NOT EXISTS mobile_cloud_handled_intents (
            mutation_id TEXT PRIMARY KEY,
            kind        TEXT NOT NULL,
            handled_at  REAL NOT NULL
        );
        CREATE TABLE IF NOT EXISTS mobile_cloud_sync_state (
            state_key   TEXT PRIMARY KEY,
            updated_at  REAL NOT NULL
        );
        """)
        try execute("""
        CREATE TABLE IF NOT EXISTS project_setup (project_id TEXT PRIMARY KEY, discovered_at REAL NOT NULL, completed INTEGER NOT NULL DEFAULT 0);
        CREATE TABLE IF NOT EXISTS mobile_project_previews (project_id TEXT PRIMARY KEY, payload TEXT NOT NULL, updated_at REAL NOT NULL);
        """)
        try addColumnIfMissing(table: "project_setup", column: "completed", definition: "INTEGER NOT NULL DEFAULT 0")
        try addColumnIfMissing(table: "ingest_items", column: "priority", definition: "INTEGER NOT NULL DEFAULT 3")
        try addColumnIfMissing(table: "ingest_items", column: "review_after", definition: "REAL")
        try addColumnIfMissing(table: "ingest_items", column: "filed_at", definition: "REAL")
    }

    /// `CREATE TABLE IF NOT EXISTS` leaves an existing table as it was.
    private func addColumnIfMissing(table: String, column: String, definition: String) throws {
        let columns = try query("PRAGMA table_info(\(table))") { $0.string(1) }
        guard columns.contains(column) == false else { return }
        try execute("ALTER TABLE \(table) ADD COLUMN \(column) \(definition);")
    }

    // MARK: - Primitives

    public func execute(_ sql: String) throws {
        lock.lock(); defer { lock.unlock() }
        var errorMessage: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(handle, sql, nil, nil, &errorMessage) != SQLITE_OK {
            let message = errorMessage.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(errorMessage)
            throw DBError.step(message)
        }
    }

    public enum Value {
        case text(String)
        case int(Int64)
        case double(Double)
        case null
    }

    @discardableResult
    public func run(_ sql: String, _ params: [Value] = []) throws -> Int {
        lock.lock(); defer { lock.unlock() }
        let statement = try prepare(sql, params)
        defer { sqlite3_finalize(statement) }
        let result = sqlite3_step(statement)
        guard result == SQLITE_DONE || result == SQLITE_ROW else {
            throw DBError.step(String(cString: sqlite3_errmsg(handle)))
        }
        return Int(sqlite3_changes(handle))
    }

    public func query<T>(_ sql: String, _ params: [Value] = [], row: (Row) -> T) throws -> [T] {
        lock.lock(); defer { lock.unlock() }
        let statement = try prepare(sql, params)
        defer { sqlite3_finalize(statement) }
        var out: [T] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            out.append(row(Row(statement: statement)))
        }
        return out
    }

    /// Runs `body` inside one transaction, rolling back if it throws.
    ///
    /// Used where a group of rows only makes sense together — importing 155 projects'
    /// Notion links, or a rating set — so an interrupted import leaves the store as it
    /// was rather than half converted. It is also much faster: each `run` outside a
    /// transaction is its own commit and its own fsync.
    ///
    /// The lock is recursive, so `body` may use `run` and `query` freely; nothing else
    /// can interleave a write while it holds it.
    public func transaction<T>(_ body: () throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        try execute("BEGIN IMMEDIATE;")
        do {
            let value = try body()
            try execute("COMMIT;")
            return value
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }

    private func prepare(_ sql: String, _ params: [Value]) throws -> OpaquePointer? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DBError.prepare(String(cString: sqlite3_errmsg(handle)) + " — " + sql)
        }
        for (i, p) in params.enumerated() {
            let idx = Int32(i + 1)
            switch p {
            case .text(let s): sqlite3_bind_text(statement, idx, s, -1, Self.transient)
            case .int(let v): sqlite3_bind_int64(statement, idx, v)
            case .double(let v): sqlite3_bind_double(statement, idx, v)
            case .null: sqlite3_bind_null(statement, idx)
            }
        }
        return statement
    }

    public struct Row {
        let statement: OpaquePointer?
        public func string(_ i: Int32) -> String {
            guard let c = sqlite3_column_text(statement, i) else { return "" }
            return String(cString: c)
        }
        public func optionalString(_ i: Int32) -> String? {
            guard sqlite3_column_type(statement, i) != SQLITE_NULL else { return nil }
            return string(i)
        }
        public func int(_ i: Int32) -> Int64 { sqlite3_column_int64(statement, i) }
        public func double(_ i: Int32) -> Double { sqlite3_column_double(statement, i) }
        public func optionalDouble(_ i: Int32) -> Double? {
            guard sqlite3_column_type(statement, i) != SQLITE_NULL else { return nil }
            return double(i)
        }
        public func date(_ i: Int32) -> Date { Date(timeIntervalSince1970: double(i)) }
    }
}
