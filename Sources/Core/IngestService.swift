import Foundation

/// Capture first, organize later.
///
/// This is the only component in the app permitted to mutate `~/Workspace`, and it
/// does so only from `classify(_:into:renamingTo:)`, which is always driven by an
/// explicit user confirmation.
public final class IngestService: @unchecked Sendable {

    public enum IngestError: Error, LocalizedError {
        case inboxUnavailable
        case destinationExists(String)
        case emptyText
        case moveFailed(String)
        /// Only an iCloud placeholder is here. A download has been started.
        case notDownloaded(String)
        case attachmentFailed(String, String)

        public var errorDescription: String? {
            switch self {
            case .inboxUnavailable: return "The ingest inbox folder could not be created."
            case .destinationExists(let name): return "“\(name)” already exists in that folder."
            case .emptyText: return "Nothing to capture."
            case .moveFailed(let m): return "Move failed: \(m)"
            case .notDownloaded(let name):
                return "“\(name)” is still in iCloud. It is downloading now; file it once it has arrived."
            case .attachmentFailed(let name, let reason):
                return "Couldn’t add “\(name)”. \(reason) Download it in Finder if it is in iCloud, or choose it again with Files."
            }
        }
    }

    /// Settable because the real location is resolved off the main thread after launch;
    /// see `IngestLocation.provisional()`.
    public private(set) var location: IngestLocation
    private let db: Database
    private let tagStore: TagStore
    private let workspace: WorkspaceLocation
    private let fs = FileManager.default
    private let ideaFilingLock = NSLock()
    /// Metadata rows whose file was absent from the last inbox listing.
    private var missingLastScan: Set<String> = []
    private let orphanLock = NSLock()

    public init(location: IngestLocation, database: Database, tagStore: TagStore, workspace: WorkspaceLocation) {
        self.location = location
        self.db = database
        self.tagStore = tagStore
        self.workspace = workspace
        // Deliberately does *not* create the inbox here. The inbox lives in iCloud
        // Drive, and a `createDirectory` against a cold file provider can block long
        // enough that an app constructing this during launch never gets a window.
        // Every method that needs the directory calls `ensureExists()` itself.
    }

    public func updateLocation(_ newLocation: IngestLocation) {
        guard newLocation.inbox != location.inbox else { return }
        location = newLocation
    }

    // MARK: - Capture

    /// Turns typed text into a real Markdown file in the inbox.
    ///
    /// The text is *never* left only in the database. The first non-empty line becomes
    /// the title and the H1; if there is no usable title, the filename falls back to a
    /// timestamp so the capture is never blocked on naming something.
    @discardableResult
    public func captureText(_ text: String, source: IngestSource = .quickCapture) throws -> IngestItem {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { throw IngestError.emptyText }
        guard location.ensureExists() else { throw IngestError.inboxUnavailable }

        let (heading, body) = CaptureNaming.markdownBody(for: trimmed)
        let url = try writeNew(Data(body.utf8), in: location.inbox, base: CaptureNaming.safeFilename(heading), extension: "md")
        return try record(url: url, source: source, title: heading)
    }

    /// Copies (or moves) an existing file or folder into the inbox.
    ///
    /// Defaults to copying so that dragging something in from elsewhere on disk never
    /// removes the user's original without them asking for it.
    @discardableResult
    public func importItem(at sourceURL: URL, source: IngestSource = .desktopDrop, moveOriginal: Bool = false, title: String? = nil) throws -> IngestItem {
        guard location.ensureExists() else { throw IngestError.inboxUnavailable }
        let ext = sourceURL.pathExtension
        let base = title.flatMap { $0.isEmpty ? nil : Self.safeFilename($0) } ?? sourceURL.deletingPathExtension().lastPathComponent
        let destination = uniqueURL(in: location.inbox, base: base, extension: ext)

        if moveOriginal {
            try fs.moveItem(at: sourceURL, to: destination)
        } else {
            try fs.copyItem(at: sourceURL, to: destination)
        }
        return try record(url: destination, source: source, title: base)
    }

    /// Writes raw data (a pasted image, a shared attachment) into the inbox.
    @discardableResult
    public func importData(_ data: Data, preferredName: String, extension ext: String, source: IngestSource = .desktopDrop) throws -> IngestItem {
        guard location.ensureExists() else { throw IngestError.inboxUnavailable }
        let base = preferredName.isEmpty ? Self.timestampName() : preferredName
        let url = try writeNew(data, in: location.inbox, base: Self.safeFilename(base), extension: ext)
        return try record(url: url, source: source, title: base)
    }

    /// An idea draft becomes one Inbox item already in the idea layout: `<title>.md`
    /// with every image and file under `Attachments/` (see `IdeaFolderLayout`).
    public func captureIdea(title: String, note: CaptureDraftEntry?, attachments: [CaptureDraftEntry]) throws -> IngestItem {
        let document = try note?.document
        guard document != nil || !attachments.isEmpty else { throw IngestError.emptyText }
        guard location.ensureExists() else { throw IngestError.inboxUnavailable }
        let explicitTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = document?.name ?? (explicitTitle.isEmpty ? attachments.first?.title ?? "" : explicitTitle)
        let base = Self.safeFilename(name)
        let destination = uniqueURL(in: location.inbox, base: base, extension: "")
        var files: [IdeaFolderLayout.Attachment] = []
        for entry in attachments {
            if let attachment = try entry.document {
                files.append(.init(name: attachment.name, ext: attachment.ext) { try attachment.data.write(to: $0, options: .withoutOverwriting) })
            } else if case .file(let source) = entry.content {
                let name = entry.title.isEmpty ? source.deletingPathExtension().lastPathComponent : entry.title
                files.append(.init(name: name, ext: source.pathExtension) { destination in
                    // Finder clipboard URLs may be file-provider items. Coordinate
                    // the selected original rather than copying a cold placeholder.
                    let scoped = source.startAccessingSecurityScopedResource()
                    defer { if scoped { source.stopAccessingSecurityScopedResource() } }
                    var coordinationError: NSError?
                    var copyError: Swift.Error?
                    NSFileCoordinator().coordinate(readingItemAt: source, options: .withoutChanges, error: &coordinationError) { readable in
                        do { try FileManager.default.copyItem(at: readable, to: destination) }
                        catch { copyError = error }
                    }
                    if let error = copyError ?? coordinationError {
                        throw IngestError.attachmentFailed(source.lastPathComponent, error.localizedDescription)
                    }
                })
            }
        }
        let markdown = document.map { String(decoding: $0.data, as: UTF8.self) }
        try IdeaFileService.publishFolder(at: destination) { folder in
            try IdeaFolderLayout.build(in: folder, base: base, title: base, markdown: markdown, attachments: files)
        }
        return try record(url: destination, source: .quickCapture, title: name.isEmpty ? base : name)
    }

    // MARK: - Inbox

    /// Everything currently sitting in the inbox.
    ///
    /// The filesystem is authoritative: items that appeared by any other means (Finder,
    /// iCloud sync from the phone, a shell command) are picked up here and given a
    /// private metadata row on first sight. Rows for files that are gone are dropped.
    /// `nil` from the scan means the inbox could not be read in time — almost always an
    /// asleep iCloud file provider. Callers keep showing the last known queue.
    public func pendingItems(fsService: FilesystemService,
                             timeout: Duration = .seconds(8)) async -> [IngestItem]? {
        // Directory creation against an iCloud provider can block just like a scan.
        // Do it off the caller and treat a timeout as unavailable, never as inbox zero.
        guard await FilesystemService.ensureDirectory(location.inbox, timeout: timeout) else { return nil }
        guard let items = await FilesystemService.items(
            inDirectory: location.inbox, timeout: timeout
        ) else { return nil }
        var metadata = storedMetadata()
        var out: [IngestItem] = []

        for item in items {
            let key = item.identity?.key ?? "path:" + item.url.canonicalPath
            var meta = metadata[key]
            if meta == nil, let byPath = metadata.values.first(where: { $0.path == item.url.canonicalPath }) {
                // iCloud and coordinated writers can replace a file in place. Its
                // path is still the same capture, but its inode has changed. Carry
                // over the private title/deferred state instead of treating the old
                // row as orphaned and recreating a fresh pending item.
                if byPath.key != key {
                    _ = try? db.run(
                        "UPDATE ingest_items SET identity_key = ?, last_path = ? WHERE identity_key = ?",
                        [.text(key), .text(item.url.canonicalPath), .text(byPath.key)]
                    )
                    metadata.removeValue(forKey: byPath.key)
                    meta = StoredIngestMetadata(
                        key: key, path: item.url.canonicalPath, capturedAt: byPath.capturedAt,
                        source: byPath.source, title: byPath.title, state: byPath.state,
                        destination: byPath.destination, priority: byPath.priority, reviewAfter: byPath.reviewAfter
                    )
                } else {
                    meta = byPath
                }
            }
            if meta == nil {
                // Written by the iOS companion as an extended attribute; falls back to
                // `.external` for anything that arrived by Finder, shell or sync.
                let source: IngestSource = SourceMarker.read(from: item.url) ?? .external
                let created = item.createdAt ?? Date()
                insertMetadata(key: key, path: item.url.canonicalPath, capturedAt: created,
                               source: source, title: item.displayTitle, state: .pending)
                meta = StoredIngestMetadata(key: key, path: item.url.canonicalPath, capturedAt: created,
                                            source: source, title: item.displayTitle,
                                            state: .pending, destination: nil)
            }
            guard let meta else { continue }
            if meta.path != item.url.canonicalPath || meta.key != key {
                _ = try? db.run("UPDATE ingest_items SET last_path = ? WHERE identity_key = ?",
                            [.text(item.url.canonicalPath), .text(meta.key)])
            }
            out.append(IngestItem(
                item: item,
                capturedAt: meta.capturedAt,
                source: meta.source,
                title: meta.title ?? item.displayTitle,
                state: meta.reviewAfter.map { $0 <= Date() ? .pending : .deferred } ?? meta.state,
                proposedDestination: meta.destination, priority: meta.priority, reviewAfter: meta.reviewAfter
            ))
            metadata.removeValue(forKey: key)
        }

        // Anything left in the table was not in this listing. Forget it only if it was
        // missing from the previous listing too: iCloud and coordinated writers replace
        // a file by removing and re-adding it, and a scan landing in that gap deleted the
        // capture's private title and deferred state for good.
        orphanLock.lock()
        let missingBefore = missingLastScan
        missingLastScan = Set(metadata.keys)
        orphanLock.unlock()
        for orphan in metadata.values where missingBefore.contains(orphan.key) {
            _ = try? db.run("DELETE FROM ingest_items WHERE identity_key = ?", [.text(orphan.key)])
        }

        return out.sorted(by: IngestItem.comesFirst)
    }

    public func setTitle(_ title: String, for item: IngestItem) {
        _ = try? db.run("UPDATE ingest_items SET title = ? WHERE identity_key = ?",
                    [.text(title), .text(item.id)])
    }

    public func setProposedDestination(folderNamed folderName: String?, for item: IngestItem) {
        _ = try? db.run("UPDATE ingest_items SET destination = ? WHERE identity_key = ?",
                    [folderName.map { .text($0) } ?? .null, .text(item.id)])
    }

    public func schedule(_ item: IngestItem, priority: Int, until: Date?) throws {
        guard (1...5).contains(priority) else { throw MobilePlanningFiles.Error.invalid("Choose a priority from 1 to 5.") }
        let changed = try db.run("UPDATE ingest_items SET priority = ?, review_after = ?, state = ?, deferred_at = ? WHERE identity_key = ? AND last_path = ?",
            [.int(Int64(priority)), until.map { .double($0.timeIntervalSince1970) } ?? .null,
             .text(until == nil ? IngestState.pending.rawValue : IngestState.deferred.rawValue),
             until.map { _ in .double(Date().timeIntervalSince1970) } ?? .null, .text(item.id), .text(item.url.canonicalPath)])
        guard changed == 1 else { throw MobilePlanningFiles.Error.conflict }
    }

    public func setState(_ state: IngestState, for item: IngestItem) {
        _ = try? db.run("UPDATE ingest_items SET state = ?, deferred_at = ?, review_after = NULL WHERE identity_key = ?",
                    [.text(state.rawValue),
                     state == .deferred ? .double(Date().timeIntervalSince1970) : .null,
                     .text(item.id)])
    }

    /// Explicitly removes an inbox capture and only its private bookkeeping. This never
    /// reaches into an organized workspace area; it is the same scoped operation as
    /// removing a draft from an email outbox.
    public func delete(_ item: IngestItem) throws {
        try fs.removeItem(at: item.url)
        _ = try? db.run("DELETE FROM ingest_items WHERE identity_key = ?", [.text(item.id)])
    }

    /// Like `delete`, but recoverable: to the Trash, or to `folder` in an isolated test
    /// run. Used once a capture's text has become a work item.
    public func trash(_ item: IngestItem, into folder: URL? = nil) throws {
        guard item.url.deletingLastPathComponent().canonicalPath == location.inbox.canonicalPath,
              !NoiseFilter.isHidden(name: item.url.lastPathComponent, showHidden: false),
              (try item.url.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink != true else {
            throw CocoaError(.fileWriteNoPermission)
        }
        if let folder {
            try fs.createDirectory(at: folder, withIntermediateDirectories: true)
            try fs.moveItem(at: item.url, to: folder.appendingPathComponent(UUID().uuidString + "-" + item.url.lastPathComponent))
        } else {
            try fs.trashItem(at: item.url, resultingItemURL: nil)
        }
        _ = try? db.run("DELETE FROM ingest_items WHERE identity_key = ?", [.text(item.id)])
    }

    // MARK: - Classification

    /// Moves an inbox item into its chosen Workspace area.
    ///
    /// This is the explicit filesystem mutation the ingest workflow exists for. Tag
    /// assignments are carried across by rebinding this app's object record from the
    /// pre-move identity to the post-move identity — so they survive regardless of
    /// whether the inode was preserved by the move.
    @discardableResult
    public func classify(_ ingestItem: IngestItem, into area: WorkspaceArea, renamingTo newName: String?) throws -> URL {
        try classify(ingestItem, intoDirectory: workspace.url(for: area), area: area.directoryName, renamingTo: newName)
    }

    /// Classification into a Finder-discovered directory. The caller chooses one
    /// explicit root folder; this method never invents a nested destination.
    @discardableResult
    public func classify(_ ingestItem: IngestItem, intoDirectory directory: URL,
                         renamingTo newName: String?) throws -> URL {
        try classify(ingestItem, intoDirectory: directory, area: workspace.areaName(containing: directory), renamingTo: newName)
    }

    /// What filing did. `originalKept` means the item is filed but the inbox copy could
    /// not be removed afterwards — nothing is lost, there are just two.
    public struct Filed: Sendable {
        public let destination: URL
        public let originalKept: Bool
    }

    /// The copying step of a cross-volume filing; replaceable so tests can interrupt it.
    var copyItem: @Sendable (URL, URL) throws -> Void = { try FileManager.default.copyItem(at: $0, to: $1) }
    /// Whether filing from `source` into `directory` crosses volumes; replaceable so the
    /// copy path can be exercised on one disk.
    var crossesVolumes: @Sendable (URL, URL) -> Bool = SafeTransfer.crossesVolumes

    @discardableResult
    public func file(_ ingestItem: IngestItem, intoDirectory directory: URL, renamingTo newName: String?) throws -> Filed {
        try file(ingestItem, intoDirectory: directory, area: workspace.areaName(containing: directory), renamingTo: newName)
    }

    private func classify(_ ingestItem: IngestItem, intoDirectory directory: URL,
                          area: String?, renamingTo newName: String?) throws -> URL {
        try file(ingestItem, intoDirectory: directory, area: area, renamingTo: newName).destination
    }

    private func file(_ ingestItem: IngestItem, intoDirectory directory: URL,
                      area: String?, renamingTo newName: String?) throws -> Filed {
        let areaURL = directory.canonical
        guard fs.fileExists(atPath: areaURL.path) else {
            throw IngestError.moveFailed("Destination does not exist at \(areaURL.path)")
        }

        let sourceURL = ingestItem.url
        let isIdea = areaURL.canonicalPath == workspace.url(for: .ideas).canonicalPath
        if isIdea { ideaFilingLock.lock() }
        defer { if isIdea { ideaFilingLock.unlock() } }
        // Asked fresh, not from the listing: it may have arrived since. Moving a
        // placeholder out of iCloud makes the move wait on the download — on the main
        // thread, offline, indefinitely — so it is refused and the download started.
        var fresh = sourceURL
        fresh.removeAllCachedResourceValues()
        let status = try? fresh.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey])
        if status?.isUbiquitousItem == true, status?.ubiquitousItemDownloadingStatus == .notDownloaded {
            startDownloading(ingestItem)
            throw IngestError.notDownloaded(sourceURL.lastPathComponent)
        }
        let ext = sourceURL.pathExtension
        let requested = (newName?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
        let base = Self.safeFilename(requested ?? sourceURL.deletingPathExtension().lastPathComponent)
        if isIdea {
            try WorkspaceLocalPathChecks.rejectSymlinks(to: areaURL)
            try WorkspaceLocalPathChecks.rejectSymlinks(to: sourceURL)
            guard sourceURL.deletingLastPathComponent().canonicalPath == location.inbox.canonicalPath,
                  let identity = FileIdentityResolver.identity(of: sourceURL),
                  ingestItem.item.identity == nil || ingestItem.item.identity == identity else {
                throw IngestError.moveFailed("This capture changed or is no longer in the Inbox.")
            }
            if !ingestItem.item.isDirectory {
                return try fileIdeaDocument(ingestItem, in: areaURL, base: base,
                                            title: requested ?? ingestItem.title, sourceIdentity: identity)
            }
            if IdeaFolderLayout.isCaptureBundle(sourceURL) {
                let name = Self.safeFilename(requested ?? sourceURL.lastPathComponent)
                return try fileIdeaBundle(ingestItem, in: areaURL, base: name,
                                          title: requested ?? ingestItem.title, sourceIdentity: identity)
            }
        }
        var destination = areaURL.appendingPathComponent(base)
        if isIdea {
            destination = uniqueURL(in: areaURL, base: Self.safeFilename(requested ?? sourceURL.lastPathComponent), extension: "")
        } else if ingestItem.item.isDirectory == false, ext.isEmpty == false {
            destination = areaURL.appendingPathComponent(base).appendingPathExtension(ext)
        }
        if fs.fileExists(atPath: destination.path) {
            throw IngestError.destinationExists(destination.lastPathComponent)
        }

        var originalKept = false
        if crossesVolumes(sourceURL, areaURL) {
            // A move here would be copy-then-delete with nothing in between protecting
            // either side. See `SafeTransfer`.
            do {
                try SafeTransfer.copyIntoPlace(sourceURL, to: destination, copy: copyItem)
            } catch {
                throw IngestError.moveFailed(error.localizedDescription)
            }
            // Only now, with a verified copy in place, does the original go.
            do { try fs.removeItem(at: sourceURL) } catch { originalKept = true }
        } else {
            do {
                try fs.moveItem(at: sourceURL, to: destination)
            } catch {
                throw IngestError.moveFailed(error.localizedDescription)
            }
        }

        // The capture marker is ingest bookkeeping; organized content carries nothing
        // belonging to this app.
        SourceMarker.clear(from: destination)
        MobileCaptureBundleReceipt.clear(from: destination)
        return finishFiling(ingestItem, at: destination, title: requested ?? ingestItem.title,
                            area: area, originalKept: originalKept)
    }

    /// A single captured file becomes `<base>/<base>.md`; anything that is not Markdown
    /// goes under `Attachments/` and the note links it (see `IdeaFolderLayout`).
    private func fileIdeaDocument(_ item: IngestItem, in directory: URL, base: String,
                                  title: String, sourceIdentity: FileIdentity) throws -> Filed {
        let ext = item.url.pathExtension
        let isMarkdown = ["md", "markdown", "mdown"].contains(ext.lowercased())
        return try fileIdea(item, in: directory, base: base, title: title, sourceIdentity: sourceIdentity) { staged in
            if isMarkdown {
                let child = staged.appendingPathComponent(base).appendingPathExtension("md")
                try SafeTransfer.copyIntoPlace(item.url, to: child, copy: copyItem)
                SourceMarker.clear(from: child)
            } else {
                let source = item.url
                try IdeaFolderLayout.build(in: staged, base: base, title: title, markdown: nil, attachments: [
                    .init(name: source.deletingPathExtension().lastPathComponent, ext: ext) { target in
                        try SafeTransfer.copyIntoPlace(source, to: target, copy: self.copyItem)
                        SourceMarker.clear(from: target)
                    }])
            }
        }
    }

    /// A phone capture bundle (`Note.md` plus photos and files) is rebuilt in the idea
    /// layout: its note becomes `<base>.md` and every other file an attachment.
    private func fileIdeaBundle(_ item: IngestItem, in directory: URL, base: String,
                                title: String, sourceIdentity: FileIdentity) throws -> Filed {
        let source = item.url
        let names = try fs.contentsOfDirectory(atPath: source.path).filter { !$0.hasPrefix(".") }.sorted()
        let noteURL = source.appendingPathComponent(IdeaFolderLayout.bundleNoteName)
        let markdown = names.contains(IdeaFolderLayout.bundleNoteName)
            ? try String(contentsOf: noteURL, encoding: .utf8) : nil
        let files = names.filter { $0 != IdeaFolderLayout.bundleNoteName }.map { source.appendingPathComponent($0) }
        return try fileIdea(item, in: directory, base: base, title: title, sourceIdentity: sourceIdentity) { staged in
            try IdeaFolderLayout.build(in: staged, base: base, title: title, markdown: markdown, attachments: files.map { file in
                .init(name: file.deletingPathExtension().lastPathComponent, ext: file.pathExtension) { target in
                    try SafeTransfer.copyIntoPlace(file, to: target, copy: self.copyItem)
                    SourceMarker.clear(from: target)
                }
            })
        }
    }

    /// Builds the idea folder from a copy, publishes it under a free name, and removes
    /// the Inbox original only if it did not change meanwhile; otherwise both are kept.
    private func fileIdea(_ item: IngestItem, in directory: URL, base: String, title: String,
                          sourceIdentity: FileIdentity, build: (URL) throws -> Void) throws -> Filed {
        let destination = uniqueURL(in: directory, base: base, extension: "")
        let before = contentStamp(of: item.url)
        func sourceIsUnchanged() -> Bool {
            FileIdentityResolver.identity(of: item.url) == sourceIdentity && before != nil && contentStamp(of: item.url) == before
        }
        try IdeaFileService.publishFolder(at: destination) { staged in
            try build(staged)
            guard sourceIsUnchanged() else {
                throw IngestError.moveFailed("This capture changed during filing.")
            }
        }
        var originalKept = true
        if sourceIsUnchanged() {
            do { try fs.removeItem(at: item.url); originalKept = false } catch {}
        }
        return finishFiling(item, at: destination, title: title,
                            area: WorkspaceArea.ideas.directoryName, originalKept: originalKept)
    }

    /// Size and modification date of a file, or of each direct child of a folder.
    private func contentStamp(of url: URL) -> [String]? {
        func stamp(_ url: URL) -> String? {
            guard let attributes = try? fs.attributesOfItem(atPath: url.path) else { return nil }
            let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSinceReferenceDate ?? 0
            return "\(url.lastPathComponent)|\((attributes[.size] as? NSNumber)?.int64Value ?? -1)|\(modified)"
        }
        var isDirectory: ObjCBool = false
        guard fs.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return nil }
        guard isDirectory.boolValue else { return stamp(url).map { [$0] } }
        guard let names = try? fs.contentsOfDirectory(atPath: url.path) else { return nil }
        let children = names.sorted().map { stamp(url.appendingPathComponent($0)) }
        return children.contains(where: { $0 == nil }) ? nil : children.compactMap { $0 }
    }

    private func finishFiling(_ item: IngestItem, at destination: URL, title: String,
                              area: String?, originalKept: Bool) -> Filed {
        tagStore.rebindObject(fromIdentityKey: item.id, to: destination, area: area)
        if originalKept == false {
            _ = try? db.run("DELETE FROM ingest_items WHERE identity_key = ?", [.text(item.id)])
        }
        recordFiling(of: item, at: destination, title: title,
                     destinationName: area ?? destination.deletingLastPathComponent().lastPathComponent)
        return Filed(destination: destination, originalKept: originalKept)
    }

    // MARK: - Recently filed

    /// How long a filed capture stays listed under Ingest's Recently Filed.
    public static let filedRetention: TimeInterval = 14 * 24 * 60 * 60
    static let filedState = "filed"

    /// Keyed apart from every inbox identity so an inbox scan can never match, adopt
    /// or orphan-delete it.
    private func recordFiling(of item: IngestItem, at destination: URL, title: String, destinationName: String) {
        let key = "filed:" + (FileIdentityResolver.identity(of: destination)?.key ?? UUID().uuidString)
        _ = try? db.run("""
            INSERT OR REPLACE INTO ingest_items
            (identity_key, last_path, captured_at, source, title, state, destination, deferred_at, filed_at)
            VALUES (?,?,?,?,?,?,?,NULL,?)
            """,
            [.text(key), .text(destination.canonicalPath), .double(item.capturedAt.timeIntervalSince1970),
             .text(item.source.rawValue), .text(title), .text(Self.filedState), .text(destinationName),
             .double(Date().timeIntervalSince1970)]
        )
    }

    /// Captures filed in the last `window`, newest first. Records past the window are
    /// forgotten here. Whether each one is still where it was filed is for the caller
    /// to check against the filesystem; this is only what was done.
    public func recentlyFiled(within window: TimeInterval = IngestService.filedRetention,
                              now: Date = Date(), limit: Int = 30) -> [FiledIngestRecord] {
        let cutoff = now.addingTimeInterval(-window).timeIntervalSince1970
        _ = try? db.run("DELETE FROM ingest_items WHERE state = ? AND filed_at < ?",
                        [.text(Self.filedState), .double(cutoff)])
        return (try? db.query("""
            SELECT identity_key, last_path, captured_at, source, title, destination, filed_at
            FROM ingest_items WHERE state = ? ORDER BY filed_at DESC LIMIT ?
            """, [.text(Self.filedState), .int(Int64(limit))], row: { r in
                let url = URL(fileURLWithPath: r.string(1))
                return FiledIngestRecord(
                    id: r.string(0), title: r.optionalString(4) ?? url.lastPathComponent,
                    source: IngestSource(rawValue: r.string(3)) ?? .unknown,
                    capturedAt: r.date(2), filedAt: r.date(6),
                    destinationName: r.optionalString(5) ?? url.deletingLastPathComponent().lastPathComponent,
                    url: url
                )
            })) ?? []
    }

    /// Asks iCloud to bring an item's content to this Mac. Returns at once; the
    /// inbox poll sees the file become local.
    public func startDownloading(_ item: IngestItem) {
        try? fs.startDownloadingUbiquitousItem(at: item.url)
    }

    // MARK: - Private metadata

    struct StoredIngestMetadata {
        let key: String
        let path: String
        let capturedAt: Date
        let source: IngestSource
        let title: String?
        let state: IngestState
        let destination: String?
        var priority: Int = 3
        var reviewAfter: Date? = nil
    }

    private func storedMetadata() -> [String: StoredIngestMetadata] {
        let rows = (try? db.query("""
            SELECT identity_key, last_path, captured_at, source, title, state, destination, priority, review_after
            FROM ingest_items WHERE state != ?
            """, [.text(Self.filedState)], row: { r in
                StoredIngestMetadata(
                    key: r.string(0), path: r.string(1), capturedAt: r.date(2),
                    source: IngestSource(rawValue: r.string(3)) ?? .unknown,
                    title: r.optionalString(4),
                    state: IngestState(rawValue: r.string(5)) ?? .pending,
                    destination: r.optionalString(6), priority: Int(r.int(7)), reviewAfter: r.optionalDouble(8).map(Date.init(timeIntervalSince1970:))
                )
            })) ?? []
        return Dictionary(rows.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
    }

    private func insertMetadata(key: String, path: String, capturedAt: Date, source: IngestSource,
                                title: String, state: IngestState) {
        _ = try? db.run("""
            INSERT OR REPLACE INTO ingest_items
            (identity_key, last_path, captured_at, source, title, state, destination, deferred_at)
            VALUES (?,?,?,?,?,?,NULL,NULL)
            """,
            [.text(key), .text(path), .double(capturedAt.timeIntervalSince1970),
             .text(source.rawValue), .text(title), .text(state.rawValue)]
        )
    }

    private func record(url rawURL: URL, source: IngestSource, title: String) throws -> IngestItem {
        let url = rawURL.canonical
        SourceMarker.write(source, to: url)
        let key = FileIdentityResolver.identity(of: url)?.key ?? "path:" + url.canonicalPath
        let now = Date()
        insertMetadata(key: key, path: url.canonicalPath, capturedAt: now, source: source,
                       title: title, state: .pending)
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .creationDateKey])
        let isDir = values?.isDirectory ?? false
        let item = WorkspaceItem(
            url: url, name: url.lastPathComponent, isDirectory: isDir,
            kind: FileKind.classify(url: url, isDirectory: isDir),
            identity: FileIdentityResolver.identity(of: url),
            byteSize: Int64(values?.fileSize ?? 0),
            createdAt: values?.creationDate, rawModifiedAt: values?.contentModificationDate,
            contentModifiedAt: values?.contentModificationDate, immediateChildCount: nil
        )
        return IngestItem(item: item, capturedAt: now, source: source, title: title)
    }

    // MARK: - Naming

    /// Delegated to `CaptureNaming` so a note typed on the Mac and one typed on the
    /// phone are named by identical rules.
    static func titleFromText(_ line: String) -> String? { CaptureNaming.title(fromFirstLine: line) }
    static func safeFilename(_ name: String) -> String { CaptureNaming.safeFilename(name) }
    static func timestampName() -> String { CaptureNaming.timestampName() }
    static func humanTimestamp() -> String { CaptureNaming.humanTimestamp() }

    /// Writes a new file under a free name, and never over an existing one.
    ///
    /// Picking a free name and then writing with overwrite allowed left a gap in which
    /// a capture synced from the phone under the same name could be replaced. The write
    /// is exclusive (`O_EXCL`); if the name was taken meanwhile, the next is tried. No
    /// staged temporary file: in the iCloud inbox that would itself be synced.
    func writeNew(_ data: Data, in directory: URL, base: String, extension ext: String) throws -> URL {
        var taken: Set<String> = []
        for _ in 0..<100 {
            let url = uniqueURL(in: directory, base: base, extension: ext, skipping: taken)
            do {
                try data.write(to: url, options: .withoutOverwriting)
                return url
            } catch CocoaError.fileWriteFileExists {
                taken.insert(url.lastPathComponent)
            }
        }
        throw CocoaError(.fileWriteFileExists)
    }

    /// Appends ` 2`, ` 3`, … rather than overwriting anything.
    func uniqueURL(in directory: URL, base: String, extension ext: String, skipping taken: Set<String> = []) -> URL {
        func make(_ name: String) -> URL {
            ext.isEmpty ? directory.appendingPathComponent(name)
                        : directory.appendingPathComponent(name).appendingPathExtension(ext)
        }
        var candidate = make(base)
        var counter = 2
        while fs.fileExists(atPath: candidate.path) || taken.contains(candidate.lastPathComponent) {
            candidate = make("\(base) \(counter)")
            counter += 1
        }
        return candidate
    }
}
