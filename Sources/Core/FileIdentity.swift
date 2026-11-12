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

    /// Identities recorded before October 26, 2026 named the volume by its BSD device
    /// number, which macOS renumbers across restarts. Such a record still identifies the
    /// file by its inode on the one volume it was read from.
    public var hasLegacyVolume: Bool { !volume.isEmpty && volume.allSatisfy(\.isNumber) }

    /// Same file: same inode, on the same volume — or either side recorded with a legacy
    /// device number, which cannot be compared across a restart.
    public static func == (lhs: FileIdentity, rhs: FileIdentity) -> Bool {
        lhs.fileID == rhs.fileID && (lhs.volume == rhs.volume || lhs.hasLegacyVolume || rhs.hasLegacyVolume)
    }

    public func hash(into hasher: inout Hasher) { hasher.combine(fileID) }

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
        return FileIdentity(volume: volumeID(device: st.st_dev, url: url), fileID: UInt64(st.st_ino))
    }

    /// The volume's UUID, which survives restarts; the device number is not stable. A
    /// device number cannot change while this process runs, so each is looked up once.
    private static let volumeCache = VolumeCache()
    private final class VolumeCache: @unchecked Sendable {
        let lock = NSLock()
        var byDevice: [dev_t: String] = [:]
    }

    static func volumeID(device: dev_t, url: URL) -> String {
        volumeCache.lock.lock()
        if let known = volumeCache.byDevice[device] { volumeCache.lock.unlock(); return known }
        volumeCache.lock.unlock()
        var probe = url.standardizedFileURL
        probe.removeAllCachedResourceValues()
        let uuid = (try? probe.resourceValues(forKeys: [.volumeUUIDStringKey]))?.volumeUUIDString
        // Without a UUID (some network volumes), keep the device number: still correct
        // within this session, and compared leniently later.
        let value = uuid.map { "uuid-" + $0 } ?? String(device)
        volumeCache.lock.lock(); volumeCache.byDevice[device] = value; volumeCache.lock.unlock()
        return value
    }

    /// Where the object `identity` names is now, looked up on the volume holding `url`
    /// (`fsgetpath(2)`), or nil when it no longer exists there or cannot be checked.
    /// Anything in a Trash counts as gone: a folder replaced in Finder is moved there.
    public static func currentPath(of identity: FileIdentity, onVolumeOf url: URL) -> String? {
        if case .at(let path) = locate(identity, onVolumeOf: url) { return path }
        return nil
    }

    /// True only when the object is positively gone from that volume (or in a Trash);
    /// false when it exists or could not be checked.
    public static func isGone(_ identity: FileIdentity, onVolumeOf url: URL) -> Bool {
        if case .gone = locate(identity, onVolumeOf: url) { return true }
        return false
    }

    private enum Location { case at(String), gone, unknown }

    private static func locate(_ identity: FileIdentity, onVolumeOf url: URL) -> Location {
        guard let here = self.identity(of: url), identity.volume == here.volume || identity.hasLegacyVolume else { return .unknown }
        var info = statfs()
        guard statfs(url.standardizedFileURL.path, &info) == 0 else { return .unknown }
        var fsid = info.f_fsid
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fsgetpath(&buffer, buffer.count, &fsid, identity.fileID) > 0 else { return errno == ENOENT ? .gone : .unknown }
        let path = URL(fileURLWithPath: String(cString: buffer)).canonicalPath
        return path.contains("/.Trash/") || path.contains("/.Trashes/") ? .gone : .at(path)
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
