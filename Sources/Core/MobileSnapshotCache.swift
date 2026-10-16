import Foundation

/// The last snapshot CloudKit successfully answered, kept on the phone.
///
/// This is a cache of a cache. The Workspace itself lives on the Mac and the CloudKit
/// records are already described as disposable; this is one step further out, so that a
/// phone with no signal, no account, or no CloudKit at all still opens on the index it
/// last saw instead of an empty list. Delete the file and nothing is lost but a cold
/// first screen.
///
/// Deliberately a single JSON file rather than a database: it is written whole, read
/// whole, and there is exactly one of it. A half-written file is unreadable, which is
/// handled the same way as a missing one, so no migration or repair path is needed.
public final class MobileSnapshotCache: @unchecked Sendable {

    /// A cached snapshot is old news, not a lie — but past this it is old enough that
    /// presenting it as the workspace would be misleading, so callers are told.
    public static let staleAfter: TimeInterval = 7 * 24 * 60 * 60

    /// Enough to keep a curated index; beyond this something is publishing a mirror of
    /// the workspace rather than an index of it, and the phone should not store it.
    public static let byteLimit = 8 * 1024 * 1024

    private let fileURL: URL
    private let lock = NSLock()

    /// Writes inside the app group when there is one, so a future widget could read the
    /// same file, and falls back to Application Support when there is not.
    public init?(appGroup: String? = nil, fileName: String = "mobile-snapshot.json") {
        let directory: URL?
        if let appGroup {
            directory = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)
        } else {
            directory = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                     appropriateFor: nil, create: true)
        }
        guard let directory else { return nil }
        let base = directory.appendingPathComponent("BetterWorkspace", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        fileURL = base.appendingPathComponent(fileName)
    }

    public init(fileURL: URL) {
        self.fileURL = fileURL
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
    }

    /// The cached snapshot, or nil when there is none, it cannot be read, or it was
    /// written by a version whose shape no longer decodes. All three mean the same
    /// thing to a caller: there is nothing to show yet.
    public func load() -> MobileWorkspaceSnapshot? {
        lock.lock(); defer { lock.unlock() }
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(MobileWorkspaceSnapshot.self, from: data)
    }

    /// Replaces the cache. Returns whether it was written.
    ///
    /// An empty snapshot is never cached over a non-empty one. A publisher that has not
    /// finished its first run, or a query that answered nothing because of a schema
    /// mistake, both look like "the workspace is empty", and neither is worth losing a
    /// real index for.
    @discardableResult
    public func save(_ snapshot: MobileWorkspaceSnapshot) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let data = try? JSONEncoder().encode(snapshot), data.count <= Self.byteLimit else { return false }
        if Self.isEmpty(snapshot), let existing = try? Data(contentsOf: fileURL),
           let previous = try? JSONDecoder().decode(MobileWorkspaceSnapshot.self, from: existing),
           Self.isEmpty(previous) == false {
            return false
        }
        // Atomic: a snapshot is only useful whole, and the phone can be killed the
        // instant it is backgrounded.
        do { try data.write(to: fileURL, options: .atomic) } catch { return false }
        return true
    }

    public func clear() {
        lock.lock(); defer { lock.unlock() }
        try? FileManager.default.removeItem(at: fileURL)
    }

    public static func isStale(_ snapshot: MobileWorkspaceSnapshot, now: Date = Date()) -> Bool {
        now.timeIntervalSince(snapshot.fetchedAt) > staleAfter
    }

    public static func isEmpty(_ snapshot: MobileWorkspaceSnapshot) -> Bool {
        snapshot.entries.isEmpty && snapshot.workItems.isEmpty
            && snapshot.ideas.isEmpty && snapshot.tags.isEmpty
    }
}
