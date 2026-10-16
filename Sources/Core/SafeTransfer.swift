import Foundation

/// Moving something to another volume without ever leaving a half-filed copy.
///
/// On one volume a move is a rename: atomic, nothing in between. Across volumes
/// `FileManager.moveItem` copies and then deletes, and an interruption (a crash, a full
/// disk, a drive pulled mid-copy) could leave a partial copy under the *final* name —
/// looking filed — while the original was still in the inbox, or worse, gone.
///
/// Here the copy is made under a hidden staging name inside the destination folder,
/// checked against the original, and only then renamed into place with a rename that
/// refuses to overwrite. The original is removed last, and only after that. At every
/// moment either the destination has a complete item under its real name or it has
/// none, and the original exists until the copy is known good.
public enum SafeTransfer {

    public static let stagingPrefix = ".bw-filing-"
    /// Set on the staging folder *before* anything is copied into it, so even a copy
    /// cut off half-way is provably ours. Records where the item came from, what it was
    /// going to be called, and whether the copy was verified complete.
    public static let markerAttribute = "com.zacharysturman.betterworkspace.filing"

    struct Marker: Codable {
        let source: String
        let destinationName: String
        var verified: Bool
    }

    public enum TransferError: LocalizedError {
        case incomplete(String)

        public var errorDescription: String? {
            switch self {
            case .incomplete(let name):
                return "The copy of “\(name)” did not match the original, so nothing was filed and the original was kept."
            }
        }
    }

    /// Whether two locations are on different volumes, so that a move would be a copy.
    public static func crossesVolumes(_ source: URL, _ destinationDirectory: URL) -> Bool {
        func volume(_ url: URL) -> NSObject? {
            var fresh = url
            fresh.removeAllCachedResourceValues()
            return (try? fresh.resourceValues(forKeys: [.volumeIdentifierKey]))?.volumeIdentifier as? NSObject
        }
        guard let a = volume(source), let b = volume(destinationDirectory) else { return false }
        return a.isEqual(b) == false
    }

    /// Copies `source` to `destination` (whose name must be free) through a verified
    /// staging copy. On any failure nothing is left at `destination`, the staging copy
    /// is removed, and `source` is untouched. Does *not* remove `source`.
    ///
    /// - Parameter copy: the copying step; replaceable so tests can interrupt it.
    public static func copyIntoPlace(_ source: URL, to destination: URL,
                                     copy: (URL, URL) throws -> Void = { try FileManager.default.copyItem(at: $0, to: $1) }) throws {
        let fm = FileManager.default
        // A hidden, marked folder in the destination; the copy goes inside it.
        let staging = destination.deletingLastPathComponent()
            .appendingPathComponent(stagingPrefix + UUID().uuidString, isDirectory: true)
        let inner = staging.appendingPathComponent(destination.lastPathComponent)
        var marker = Marker(source: source.path, destinationName: destination.lastPathComponent, verified: false)
        do {
            try fm.createDirectory(at: staging, withIntermediateDirectories: false)
            setMarker(marker, on: staging)
            try copy(source, inner)
            guard summary(of: source) == summary(of: inner) else {
                throw TransferError.incomplete(source.lastPathComponent)
            }
            marker.verified = true
            setMarker(marker, on: staging)
            // Same volume as the destination, so a rename; fails rather than overwrite.
            try fm.moveItem(at: inner, to: destination)
            try? fm.removeItem(at: staging)
        } catch {
            try? fm.removeItem(at: staging)
            throw error
        }
    }

    /// Regular files and their total size, everything below `url` included.
    static func summary(of url: URL) -> Summary {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return Summary(files: -1, bytes: -1) }
        guard isDirectory.boolValue else {
            let size = (try? fm.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
            return Summary(files: 1, bytes: size)
        }
        var result = Summary(files: 0, bytes: 0)
        guard let walk = fm.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]) else {
            return result
        }
        for case let child as URL in walk {
            let values = try? child.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values?.isRegularFile == true else { continue }
            result.files += 1
            result.bytes += Int64(values?.fileSize ?? 0)
        }
        return result
    }

    struct Summary: Equatable {
        var files: Int
        var bytes: Int64
    }

    // MARK: Leftovers

    public struct Cleanup: Sendable {
        public var removed: [URL] = []
        public var recovered: [URL] = []
    }

    /// Deals with staging copies a crash or a pulled drive left in destination folders.
    ///
    /// Only a folder with the exact staging name *and* this app's marker is touched, and
    /// only once it is older than `minimumAge`.
    /// - Original still there: the copy is redundant; removed.
    /// - Original gone, copy verified: the copy is the only one left; put in place under
    ///   its intended name, or a free variant.
    /// - Original gone, copy not verified: possibly partial, but possibly all there is.
    ///   Never deleted; put in place visibly, marked "possibly incomplete".
    public static func cleanUpInterruptedFilings(in directories: [URL], minimumAge: TimeInterval = 3600,
                                                 now: Date = Date()) -> Cleanup {
        let fm = FileManager.default
        var result = Cleanup()
        for directory in directories {
            guard let names = try? fm.contentsOfDirectory(atPath: directory.path) else { continue }
            for name in names where name.hasPrefix(stagingPrefix) {
                guard UUID(uuidString: String(name.dropFirst(stagingPrefix.count))) != nil else { continue }
                let staging = directory.appendingPathComponent(name)
                guard let marker = readMarker(from: staging),
                      let modified = (try? fm.attributesOfItem(atPath: staging.path))?[.modificationDate] as? Date,
                      now.timeIntervalSince(modified) >= minimumAge
                else { continue }
                let inner = staging.appendingPathComponent(marker.destinationName)
                if fm.fileExists(atPath: marker.source) || fm.fileExists(atPath: inner.path) == false {
                    if (try? fm.removeItem(at: staging)) != nil { result.removed.append(staging) }
                } else {
                    let ext = (marker.destinationName as NSString).pathExtension
                    var base = (marker.destinationName as NSString).deletingPathExtension
                    if marker.verified == false { base += " (possibly incomplete)" }
                    var destination = directory.appendingPathComponent(ext.isEmpty ? base : "\(base).\(ext)")
                    var counter = 2
                    while fm.fileExists(atPath: destination.path) {
                        let name = ext.isEmpty ? "\(base) \(counter)" : "\(base) \(counter).\(ext)"
                        destination = directory.appendingPathComponent(name)
                        counter += 1
                    }
                    if (try? fm.moveItem(at: inner, to: destination)) != nil {
                        result.recovered.append(destination)
                        try? fm.removeItem(at: staging)
                    }
                }
            }
        }
        return result
    }

    // MARK: Marker

    static func setMarker(_ marker: Marker, on url: URL) {
        guard let data = try? JSONEncoder().encode(marker) else { return }
        _ = data.withUnsafeBytes { buffer in
            setxattr(url.path, markerAttribute, buffer.baseAddress, buffer.count, 0, XATTR_NOFOLLOW)
        }
    }

    static func readMarker(from url: URL) -> Marker? {
        let length = getxattr(url.path, markerAttribute, nil, 0, 0, XATTR_NOFOLLOW)
        guard length > 0 else { return nil }
        var data = Data(count: length)
        let read = data.withUnsafeMutableBytes { getxattr(url.path, markerAttribute, $0.baseAddress, length, 0, XATTR_NOFOLLOW) }
        guard read == length else { return nil }
        return try? JSONDecoder().decode(Marker.self, from: data)
    }

    static func removeMarker(from url: URL) {
        removexattr(url.path, markerAttribute, XATTR_NOFOLLOW)
    }
}
