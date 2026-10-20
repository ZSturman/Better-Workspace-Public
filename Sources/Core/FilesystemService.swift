import Foundation

/// The single point of filesystem access for the whole app.
///
/// Read-only by design. The one component allowed to move things is `IngestService`,
/// and only on an explicit, confirmed classification.
public actor FilesystemService {

    public static let shared = FilesystemService()

    private let fm = FileManager.default
    private var contentDateCache: [String: Date] = [:]
    private var sizeCache: [String: Int64] = [:]

    public init() {}

    private static let resourceKeys: [URLResourceKey] = [
        .isDirectoryKey, .fileSizeKey, .contentModificationDateKey,
        .creationDateKey, .isSymbolicLinkKey, .isPackageKey,
        // Metadata only: asking for the status never triggers a download.
        .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey,
    ]

    // MARK: - Listing

    /// Immediate children of a Workspace area — the primary taggable entities.
    public func items(in area: WorkspaceArea, location: WorkspaceLocation, showHidden: Bool = false) throws -> [WorkspaceItem] {
        try items(inArea: area.directoryName, location: location, showHidden: showHidden)
    }

    public func items(inArea folderName: String, location: WorkspaceLocation, showHidden: Bool = false) throws -> [WorkspaceItem] {
        try items(inDirectory: location.url(forArea: folderName), showHidden: showHidden)
    }

    /// Immediate children of any directory.
    public func items(inDirectory directory: URL, showHidden: Bool = false) throws -> [WorkspaceItem] {
        let contents: [URL]
        do {
            contents = try WorkspaceListing.children(of: directory, keys: Self.resourceKeys, showHidden: showHidden)
        } catch {
            // A directory that is not there holds nothing — that is an answer, not a
            // failure. Anything else (permissions, I/O, a wedged provider) is thrown,
            // so a caller is never told an unreadable directory is empty.
            if (error as NSError).code == NSFileReadNoSuchFileError, !fm.fileExists(atPath: directory.path) { return [] }
            throw error
        }

        var result: [WorkspaceItem] = []
        result.reserveCapacity(contents.count)
        for url in contents {
            let name = url.lastPathComponent
            if NoiseFilter.isHidden(name: name, showHidden: showHidden) { continue }
            // Straight from the listing: its prefetched values are current.
            if let item = makeItem(url: url, prefetched: true) { result.append(item) }
        }
        return result.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Builds a snapshot for a single URL. Returns nil if it vanished mid-scan, which
    /// happens routinely while other tools write into the same tree.
    public func makeItem(url: URL, prefetched: Bool = false) -> WorkspaceItem? {
        // Resource values are cached on a URL instance. A caller re-snapshotting an item
        // it already holds (a selection after a change) would otherwise get the old size
        // and dates back. A listing's own URLs carry values fetched a moment ago.
        var fresh = url
        if prefetched == false { fresh.removeAllCachedResourceValues() }
        let values = try? fresh.resourceValues(forKeys: Set(Self.resourceKeys))
        guard let values else { return nil }
        // A package (.xcodeproj, .app) is a directory on disk but a single thing to a person.
        let isPackage = values.isPackage ?? false
        let isDirectory = (values.isDirectory ?? false) && !isPackage
        let url = url.canonical
        let name = url.lastPathComponent
        let kind = FileKind.classify(url: url, isDirectory: isDirectory)

        var childCount: Int?
        var contentModified = values.contentModificationDate
        if isDirectory {
            let shallow = shallowSummary(of: url)
            childCount = shallow.count
            // Other tools touch these directories constantly; trust the newest real
            // child over the directory's own mtime when we have one.
            if let newest = shallow.newest {
                contentModified = max(newest, values.contentModificationDate ?? .distantPast)
                if let raw = values.contentModificationDate, raw.timeIntervalSince(newest) > 60 {
                    contentModified = newest
                }
            }
        }

        return WorkspaceItem(
            url: url,
            name: name,
            isDirectory: isDirectory,
            kind: kind,
            identity: FileIdentityResolver.identity(of: url),
            byteSize: Int64(values.fileSize ?? 0),
            createdAt: values.creationDate,
            rawModifiedAt: values.contentModificationDate,
            contentModifiedAt: contentModified,
            immediateChildCount: childCount,
            cloudStatus: values.isUbiquitousItem == true ? CloudStatus(values.ubiquitousItemDownloadingStatus) : nil
        )
    }

    /// Counts real children and finds the newest real modification date, one level deep.
    private func shallowSummary(of directory: URL) -> (count: Int, newest: Date?) {
        guard let entries = try? WorkspaceListing.children(of: directory, keys: [.contentModificationDateKey]) else { return (0, nil) }

        var count = 0
        var newest: Date?
        for entry in entries {
            let name = entry.lastPathComponent
            if NoiseFilter.isHidden(name: name, showHidden: false) { continue }
            count += 1
            if let d = try? entry.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate {
                if newest == nil || d > newest! { newest = d }
            }
        }
        return (count, newest)
    }

    // MARK: - Reading a provider-backed directory

    /// Lists a directory without letting an unresponsive file provider wedge the app.
    ///
    /// The ingest inbox lives in iCloud Drive. `contentsOfDirectory(at:includingPropertiesForKeys:)`
    /// on a file-provider directory goes out to `fileproviderd`, and when that daemon is
    /// asleep or busy the call blocks indefinitely — observed in testing, where a single
    /// inbox read hung for over ten minutes.
    ///
    /// So this runs the scan off the actor, in a detached task, and gives up after
    /// `timeout`. `nil` means "could not read", which callers show as a waiting state
    /// rather than as an empty inbox.
    ///
    /// A read that *fails* answers `nil` too, and that distinction matters: turning an
    /// unreadable directory into an empty one told `IngestService.pendingItems` that
    /// every capture had gone, and it then deleted the private titles and deferred
    /// states of the whole queue as orphans. An empty array means the directory was
    /// read and holds nothing.
    public nonisolated static func items(
        inDirectory directory: URL,
        showHidden: Bool = false,
        timeout: Duration
    ) async -> [WorkspaceItem]? {
        let winner = FirstResult()
        return await withCheckedContinuation { continuation in
            // The scan. Detached, because a blocked file-provider call cannot be
            // cancelled — it is stuck inside a syscall — and must not hold up the actor.
            Task.detached(priority: .userInitiated) {
                let service = FilesystemService()
                let items = try? await service.items(inDirectory: directory, showHidden: showHidden)
                if await winner.claim() { continuation.resume(returning: items) }
            }
            // The deadline. Whichever finishes first resumes; the loser is discarded.
            Task.detached(priority: .utility) {
                try? await Task.sleep(for: timeout)
                if await winner.claim() { continuation.resume(returning: nil) }
            }
        }
    }

    /// Creates a directory without letting a cold file provider hold the caller.
    ///
    /// `createDirectory` is usually local and cheap, but an iCloud-backed Inbox can
    /// block inside fileproviderd just like a listing. A timeout deliberately reports
    /// failure rather than claiming the inbox is empty; the next poll may succeed.
    public nonisolated static func ensureDirectory(_ directory: URL, timeout: Duration) async -> Bool {
        let winner = FirstResult()
        return await withCheckedContinuation { continuation in
            Task.detached(priority: .utility) {
                let didCreate: Bool
                do {
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    didCreate = true
                } catch {
                    didCreate = false
                }
                if await winner.claim() { continuation.resume(returning: didCreate) }
            }
            Task.detached(priority: .utility) {
                try? await Task.sleep(for: timeout)
                if await winner.claim() { continuation.resume(returning: false) }
            }
        }
    }

    // MARK: - Lazy, expensive probes

    /// Recursive byte size. Cached, because Projects/Assets/Organize are 56–73 GB and
    /// this must never run as part of a listing.
    ///
    /// The walk runs off this actor. Every listing in the app goes through it, and a
    /// single project can hold a hundred thousand files (all of Projects is ~580k), so
    /// walking here kept each area refresh queued behind whichever folder the inspector
    /// or To Organize happened to be measuring.
    public func recursiveSize(of url: URL) async -> Int64 {
        let key = url.path
        if let cached = sizeCache[key] { return cached }
        let total = await Task.detached(priority: .utility) { Self.walkSize(url) }.value
        sizeCache[key] = total
        return total
    }

    private nonisolated static func walkSize(_ url: URL) -> Int64 {
        var total: Int64 = 0
        let fm = FileManager()
        if let e = fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
                                 options: [.skipsHiddenFiles]) {
            for case let child as URL in e {
                let v = try? child.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                if v?.isRegularFile == true { total += Int64(v?.fileSize ?? 0) }
            }
        } else {
            total = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
        return total
    }

    /// Total number of files anywhere beneath `url`. Off this actor, as above.
    public func recursiveFileCount(of url: URL, limit: Int = 100_000) async -> Int {
        await Task.detached(priority: .utility) { Self.walkCount(url, limit: limit) }.value
    }

    private nonisolated static func walkCount(_ url: URL, limit: Int) -> Int {
        var count = 0
        guard let e = FileManager().enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey],
                                               options: [.skipsHiddenFiles]) else { return 0 }
        for case let child as URL in e {
            if (try? child.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
                count += 1
                if count >= limit { break }
            }
        }
        return count
    }

    /// Recursive sizes for a changed path and the folders above it; see
    /// `ItemProbe.invalidate(affectedBy:)`.
    public func invalidateCaches(affectedBy changed: [String]) {
        let changed = changed.map { URL(fileURLWithPath: $0).canonicalPath }
        for key in sizeCache.keys where CacheInvalidation.isAffected(key, by: changed) {
            sizeCache.removeValue(forKey: key)
        }
        for key in contentDateCache.keys where CacheInvalidation.isAffected(key, by: changed) {
            contentDateCache.removeValue(forKey: key)
        }
    }

    public func invalidateCaches() {
        contentDateCache.removeAll()
        sizeCache.removeAll()
    }

    public func invalidateCache(for url: URL) {
        sizeCache.removeValue(forKey: url.path)
        contentDateCache.removeValue(forKey: url.path)
    }

    // MARK: - Reading

    /// Reads a text file, capped so a 400 MB log cannot wedge the UI.
    public func readText(at url: URL, maxBytes: Int = 512 * 1024) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: maxBytes), data.isEmpty == false else { return nil }
        return String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
    }

    /// `readText` for a file that may live in iCloud: off this actor and bounded.
    ///
    /// Reading a file whose content is not yet downloaded makes the system fetch it
    /// before the read returns, and offline that can take indefinitely. On the actor it
    /// held up every listing in the app; here it gives up after `timeout` and answers
    /// `nil`, which callers show as "not available yet", never as empty.
    public nonisolated static func readText(at url: URL, maxBytes: Int = 512 * 1024,
                                            timeout: Duration) async -> String? {
        let winner = FirstResult()
        return await withCheckedContinuation { continuation in
            Task.detached(priority: .userInitiated) {
                var text: String?
                if let handle = try? FileHandle(forReadingFrom: url) {
                    if let data = try? handle.read(upToCount: maxBytes), data.isEmpty == false {
                        text = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
                    }
                    try? handle.close()
                }
                if await winner.claim() { continuation.resume(returning: text) }
            }
            Task.detached(priority: .utility) {
                try? await Task.sleep(for: timeout)
                if await winner.claim() { continuation.resume(returning: nil) }
            }
        }
    }

    /// Reads the tail of a text file — the useful end of a log.
    public func readTail(at url: URL, maxBytes: Int = 256 * 1024) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let start = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
        try? handle.seek(toOffset: start)
        guard let data = try? handle.readToEnd(), data.isEmpty == false else { return nil }
        var text = String(decoding: data, as: UTF8.self)
        if start > 0, let nl = text.firstIndex(of: "\n") { text = String(text[text.index(after: nl)...]) }
        return text
    }

    /// First Markdown file directly inside a folder, preferring a README.
    public func primaryDocument(in directory: URL) -> URL? {
        guard let entries = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            return nil
        }
        let visible = entries.filter { NoiseFilter.isHidden(name: $0.lastPathComponent, showHidden: false) == false }
        if let readme = visible.first(where: { $0.lastPathComponent.lowercased().hasPrefix("readme") }) {
            return readme
        }
        return visible.first(where: { ["md", "markdown", "txt"].contains($0.pathExtension.lowercased()) })
    }

    /// First image directly inside a folder — used as a collection's cover.
    public func representativeImage(in directory: URL, depth: Int = 2) -> URL? {
        var frontier = [(directory, 0)]
        while let (dir, level) = frontier.first {
            frontier.removeFirst()
            guard level <= depth,
                  let entries = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey],
                                                            options: [.skipsHiddenFiles])
            else { continue }
            let sorted = entries.sorted { $0.lastPathComponent < $1.lastPathComponent }
            for e in sorted {
                let isDir = (try? e.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                if isDir { frontier.append((e, level + 1)); continue }
                let kind = FileKind.classify(url: e, isDirectory: false)
                if kind == .image { return e }
            }
        }
        return nil
    }

    /// Flattens media files beneath a directory — used by the Inspiration gallery so
    /// that images buried in subfolders are browsable alongside loose ones.
    public func media(under directory: URL, maxDepth: Int = 3, limit: Int = 2000) -> [WorkspaceItem] {
        var results: [WorkspaceItem] = []
        var frontier: [(URL, Int)] = [(directory, 0)]
        while frontier.isEmpty == false, results.count < limit {
            let (dir, level) = frontier.removeFirst()
            guard let entries = try? fm.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: Self.resourceKeys, options: [])
            else { continue }
            for e in entries.sorted(by: { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }) {
                if NoiseFilter.isHidden(name: e.lastPathComponent, showHidden: false) { continue }
                let isDir = (try? e.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                if isDir {
                    if level < maxDepth { frontier.append((e, level + 1)) }
                    continue
                }
                let kind = FileKind.classify(url: e, isDirectory: false)
                guard kind.isVisualMedia else { continue }
                if let item = makeItem(url: e) { results.append(item) }
                if results.count >= limit { break }
            }
        }
        return results
    }
}

/// Single-use latch so a race between two detached tasks resumes its continuation
/// exactly once.
private actor FirstResult {
    private var claimed = false
    func claim() -> Bool {
        if claimed { return false }
        claimed = true
        return true
    }
}

/// Which cached answers a filesystem change can have made stale.
public enum CacheInvalidation {
    /// True when `cachedPath` is a changed path or contains one. A change inside a
    /// folder alters that folder's recursive size, and its parent's, all the way up —
    /// but nothing beside it.
    public static func isAffected(_ cachedPath: String, by canonicalChanged: [String]) -> Bool {
        let key = URL(fileURLWithPath: cachedPath).canonicalPath
        return canonicalChanged.contains { $0 == key || $0.hasPrefix(key + "/") }
    }
}
