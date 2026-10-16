import Foundation

/// A stable identity for a filesystem object that does not depend on its path.
///
/// Backed by the APFS file ID (inode) plus the volume identifier. This survives
/// renames and moves *within* a volume, which is exactly the ingest case:
/// `iCloud Drive/Better Workspace/Inbox/note.md` → `~/Workspace/Ideas/Note.md`
/// are the same volume on this machine.
///
/// It is deliberately *not* the only thing tag assignments hang off. See
/// `TagStore` — every assignment stores both an identity and a last-known path, and
/// `IngestService` explicitly rebinds identity across a move rather than assuming the
/// inode survived. So tags are safe even when the identity mechanism fails.
public struct FileIdentity: Hashable, Sendable, Codable, CustomStringConvertible {

    /// Opaque volume identifier, rendered as a string.
    public let volume: String
    /// File ID / inode within that volume.
    public let fileID: UInt64

    public init(volume: String, fileID: UInt64) {
        self.volume = volume
        self.fileID = fileID
    }

    /// Canonical string form used as the database key: `"<volume>:<fileID>"`.
    public var key: String { "\(volume):\(fileID)" }

    public var description: String { key }

    public init?(key: String) {
        guard let sep = key.lastIndex(of: ":") else { return nil }
        let vol = String(key[key.startIndex..<sep])
        guard let fid = UInt64(key[key.index(after: sep)...]) else { return nil }
        self.init(volume: vol, fileID: fid)
    }
}

public enum FileIdentityResolver {

    /// Reads the identity of the object currently at `url`.
    ///
    /// Uses `stat(2)` via `URLResourceValues` where available and falls back to a raw
    /// `stat` call, because `fileResourceIdentifierKey` is opaque and not persistable.
    public static func identity(of url: URL) -> FileIdentity? {
        var st = stat()
        guard lstat(url.standardizedFileURL.path, &st) == 0 else { return nil }
        return FileIdentity(volume: String(st.st_dev), fileID: UInt64(st.st_ino))
    }

    /// True when both URLs currently resolve to the same filesystem object.
    public static func sameObject(_ a: URL, _ b: URL) -> Bool {
        guard let ia = identity(of: a), let ib = identity(of: b) else { return false }
        return ia == ib
    }
}

public extension URL {
    /// The single canonical form used whenever a URL is stored, compared or used as a
    /// key.
    ///
    /// `contentsOfDirectory(at:)` hands back symlink-resolved URLs (`/private/var/…`)
    /// while a URL built with `appendingPathComponent` keeps the unresolved form
    /// (`/var/…`). Those are the same file and must compare equal, so everything is
    /// normalized here rather than at each call site.
    var canonical: URL { standardizedFileURL }

    /// Canonical path string — what goes into the database.
    var canonicalPath: String { standardizedFileURL.path }
}
