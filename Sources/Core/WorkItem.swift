import Foundation

/// A portable planning record.  Work items are ordinary Markdown files, identified by
/// a small `better-workspace` front matter block rather than by their filename or a
/// private database row.  This makes a task useful in Finder, a text editor, git, and
/// other Markdown-aware tools even when Better Workspace is not running.
public enum WorkItemKind: String, CaseIterable, Codable, Sendable, Identifiable {
    case task, feature, milestone, goal

    public var id: String { rawValue }
    public var displayName: String { rawValue.capitalized }
    public var symbolName: String {
        switch self {
        case .task: return "checkmark.circle"
        case .feature: return "sparkles"
        case .milestone: return "flag.checkered"
        case .goal: return "target"
        }
    }
}

/// The small set of destinations that are unambiguous when a capture is made on a
/// phone.  An idea is deliberately not a `WorkItemKind`: Ideas are ordinary folders
/// in the workspace, while the other two land in configured work queues.
public enum CaptureClassificationKind: String, CaseIterable, Codable, Sendable, Identifiable {
    case idea, task, feature, milestone

    /// The work item a capture of this kind becomes; `nil` for an idea, which is a folder.
    public var workItemKind: WorkItemKind? {
        switch self {
        case .idea: return nil
        case .task: return .task
        case .feature: return .feature
        case .milestone: return .milestone
        }
    }

    public var id: String { rawValue }
    public var displayName: String { rawValue.capitalized }
    public var symbolName: String {
        switch self {
        case .idea: return "lightbulb"
        case .task: return "checkmark.circle"
        case .feature: return "sparkles"
        case .milestone: return "flag.checkered"
        }
    }
}

public enum WorkItemStatus: String, CaseIterable, Codable, Sendable, Identifiable {
    case open, inProgress = "in-progress", completed
    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .open: return "Open"
        case .inProgress: return "In Progress"
        case .completed: return "Completed"
        }
    }
}

/// A deliberately small execution ordering.  It feeds the recommendation UI without
/// pretending that every future To/For folder follows this workflow.
public enum WorkItemStage: String, CaseIterable, Codable, Sendable, Identifiable {
    case now, next, later
    public var id: String { rawValue }
    public var displayName: String { rawValue.capitalized }
    public var rank: Int { Self.allCases.firstIndex(of: self) ?? 99 }
}

public enum WorkItemPriority: String, CaseIterable, Codable, Sendable, Identifiable {
    case high, medium, low
    public var id: String { rawValue }
    public var rank: Int { Self.allCases.firstIndex(of: self) ?? 99 }
}

public struct WorkItem: Identifiable, Hashable, Sendable {
    public let id: String
    public var kind: WorkItemKind
    public var title: String
    public var status: WorkItemStatus
    public var stage: WorkItemStage
    public var priority: WorkItemPriority
    /// Workspace-relative project directory, e.g. `Projects/Better Workspace`.
    public var projectPath: String?
    /// The stable ID of a containing feature, milestone, or task.
    public var parentID: String?
    /// Other stable IDs this item relates to.  These are intentionally typed only by
    /// the target record; future relationships can be added without schema churn.
    public var relatedIDs: [String]
    public var parentIDs: [String]
    public var dependencyIDs: [String]
    public var featureIDs: [String]
    public var milestoneIDs: [String]
    public var notionPageID: String?
    /// Earlier portable imports retain this provenance in unknown front matter.
    public var importedNotionPageID: String? {
        notionPageID ?? extraFrontMatter.first { $0.hasPrefix("notion-id:") }.map { String($0.dropFirst("notion-id:".count)).trimmingCharacters(in: CharacterSet(charactersIn: " \"'")) }
    }
    public var dueDate: Date?
    public var completedAt: Date?
    public var body: String
    /// Front-matter lines this app does not model — another tool's fields, a person's
    /// own notes — kept verbatim and in order so that saving never deletes them.
    public var extraFrontMatter: [String]
    public let url: URL
    public let createdAt: Date?
    public let modifiedAt: Date?

    public init(
        id: String = UUID().uuidString,
        kind: WorkItemKind,
        title: String,
        status: WorkItemStatus = .open,
        stage: WorkItemStage = .next,
        priority: WorkItemPriority = .medium,
        projectPath: String? = nil,
        parentID: String? = nil,
        relatedIDs: [String] = [],
        parentIDs: [String] = [], dependencyIDs: [String] = [], featureIDs: [String] = [], milestoneIDs: [String] = [], notionPageID: String? = nil,
        dueDate: Date? = nil,
        completedAt: Date? = nil,
        body: String = "",
        extraFrontMatter: [String] = [],
        url: URL,
        createdAt: Date? = nil,
        modifiedAt: Date? = nil
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.status = status
        self.stage = stage
        self.priority = priority
        self.projectPath = projectPath
        self.parentID = parentID
        self.relatedIDs = relatedIDs
        self.parentIDs = parentIDs; self.dependencyIDs = dependencyIDs; self.featureIDs = featureIDs; self.milestoneIDs = milestoneIDs; self.notionPageID = notionPageID
        self.dueDate = dueDate
        self.completedAt = completedAt
        self.body = body
        self.extraFrontMatter = extraFrontMatter
        self.url = url
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
    }

    public var isOpen: Bool { status != .completed }
}

/// The narrow, explainable ordering used when the app can name one concrete next
/// action. `Later` is intentionally excluded: it is an explicit statement that the
/// item is not for current execution, not a weaker form of `Next`.
///
/// Optional private project scores rank eligible projects first; within a project,
/// designated work, stage and priority retain their existing order. No file is edited
/// to change the recommendation.
public enum WorkItemRecommendation {
    public static func nextAction(in items: [WorkItem], allItems: [WorkItem]? = nil,
                                  audience: WorkActionAudience = .all, capabilities: Set<String>? = nil, projectScores: [String: Double] = [:]) -> WorkItem? {
        let universe = allItems ?? items
        let completed = Set(universe.filter { !$0.isOpen }.flatMap { [$0.id, $0.importedNotionPageID].compactMap { $0 } })
        // Decode optional JSON once per item, then choose the best in one pass.
        // Sorting reparsed metadata for every comparison and stalled Overview on large queues.
        let candidates = items.compactMap { item -> (item: WorkItem, metadata: WorkItemActionMetadata?)? in
            guard item.isOpen, item.stage != .later,
                  item.dependencyIDs.allSatisfy({ completed.contains($0) }) else { return nil }
            let meta = item.actionMetadata
            if let meta {
                guard meta.blockedBy.isEmpty else { return nil }
                if let capabilities, !Set(meta.requirements).isSubset(of: capabilities) { return nil }
                switch audience {
                case .all: break
                case .agent: guard meta.isAgentReady else { return nil }
                case .user: guard meta.needsUser else { return nil }
                }
            } else if audience != .all { return nil }
            return (item, meta)
        }
        return candidates.min { lhs, rhs in
            let left = lhs.item.projectPath.flatMap { projectScores[$0] }.flatMap { $0.isFinite ? $0 : nil }
            let right = rhs.item.projectPath.flatMap { projectScores[$0] }.flatMap { $0.isFinite ? $0 : nil }
            if left != right { return (left ?? -.infinity) > (right ?? -.infinity) }
            func designated(_ meta: WorkItemActionMetadata?) -> Bool {
                guard let meta else { return false }
                switch audience { case .all: return meta.isNextWork; case .agent: return meta.isNextAgentAction; case .user: return meta.isNextUserAction }
            }
            if designated(lhs.metadata) != designated(rhs.metadata) { return designated(lhs.metadata) }
            if let a = lhs.metadata, let b = rhs.metadata, a.actionScore != b.actionScore { return a.actionScore > b.actionScore }
            return comesBefore(lhs.item, rhs.item)
        }?.item
    }

    private static func comesBefore(_ lhs: WorkItem, _ rhs: WorkItem) -> Bool {
        if lhs.stage != rhs.stage { return lhs.stage.rank < rhs.stage.rank }
        if lhs.priority != rhs.priority { return lhs.priority.rank < rhs.priority.rank }
        return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
    }
}

/// Reads and writes just the documented Better Workspace front matter.  It is not a
/// general YAML implementation: deliberately accepting only scalar fields here keeps
/// the on-disk contract small, inspectable, and dependency-free.
public final class WorkItemService: @unchecked Sendable {
    public static let markerKey = "better-workspace"
    public static let fileSuffix = ".bw.md"
    private let fm = FileManager.default
    public enum WorkItemError: LocalizedError {
        case changedOnDisk(URL)
        /// Moved or deleted since it was read. Saving would recreate it where it used to
        /// be, undoing someone's move or delete.
        case missing(URL)

        public var errorDescription: String? {
            switch self {
            case .changedOnDisk(let url):
                return "“\(url.lastPathComponent)” changed in Finder or another editor. Reload it before saving so no one’s edits are overwritten."
            case .missing(let url):
                return "“\(url.lastPathComponent)” was moved or deleted outside Better Workspace, so this change was not saved."
            }
        }
    }

    public init() {}

    /// Writes a new record under a name nobody holds.
    ///
    /// Checking for a free name and then writing left a gap in which another tool could
    /// create that name and have it overwritten. The record is now written to a
    /// temporary file and moved into place with a move that fails if the name exists;
    /// on that failure the next name is tried.
    public func create(_ item: WorkItem, in directory: URL) throws -> WorkItem {
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        var skip: Set<String> = []
        for _ in 0..<100 {
            let url = uniqueURL(in: directory, title: item.title, skipping: skip)
            let copy = WorkItem(id: item.id, kind: item.kind, title: item.title, status: item.status,
                                stage: item.stage, priority: item.priority, projectPath: item.projectPath,
                                parentID: item.parentID, relatedIDs: item.relatedIDs, parentIDs: item.parentIDs, dependencyIDs: item.dependencyIDs, featureIDs: item.featureIDs, milestoneIDs: item.milestoneIDs, notionPageID: item.notionPageID, dueDate: item.dueDate,
                                completedAt: item.completedAt, body: item.body,
                                extraFrontMatter: item.extraFrontMatter, url: url)
            let staged = try stage(render(copy), beside: url)
            do {
                try fm.moveItem(at: staged, to: url)
                return read(at: url) ?? copy
            } catch CocoaError.fileWriteFileExists {
                try? fm.removeItem(at: staged)
                skip.insert(url.lastPathComponent)
            } catch {
                try? fm.removeItem(at: staged)
                throw error
            }
        }
        throw CocoaError(.fileWriteFileExists)
    }

    public func read(at url: URL) -> WorkItem? {
        guard url.lastPathComponent.hasSuffix(Self.fileSuffix),
              let text = try? String(contentsOf: url, encoding: .utf8),
              let parsed = parse(text)
        else { return nil }
        // Fresh values: the editor re-reads through a URL it already holds, and a cached
        // modification date would make every save after "Use the Version on Disk"
        // report a conflict again.
        var fresh = url
        fresh.removeAllCachedResourceValues()
        let values = try? fresh.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
        // Never manufacture a UUID for a malformed record. Doing so made the same
        // file appear as a different task every refresh, breaking parent/related
        // links and potentially letting an import create a duplicate. A file with our
        // marker but no stable identity is corrupt, not a new task.
        guard let id = parsed.values["id"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              id.isEmpty == false,
              let kind = WorkItemKind(rawValue: parsed.values["kind"] ?? ""),
              let title = parsed.values["title"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              title.isEmpty == false
        else { return nil }
        return WorkItem(
            id: id,
            kind: kind,
            title: title,
            status: WorkItemStatus(rawValue: parsed.values["status"] ?? "") ?? .open,
            stage: WorkItemStage(rawValue: parsed.values["stage"] ?? "") ?? .next,
            priority: WorkItemPriority(rawValue: parsed.values["priority"] ?? "") ?? .medium,
            projectPath: parsed.values["project"], parentID: parsed.values["parent"],
            relatedIDs: parseList(parsed.values["related"]), parentIDs: parseList(parsed.values["parents"]), dependencyIDs: parseList(parsed.values["dependencies"]), featureIDs: parseList(parsed.values["features"]), milestoneIDs: parseList(parsed.values["milestones"]), notionPageID: parsed.values["notion-page-id"], dueDate: date(parsed.values["due"]),
            completedAt: date(parsed.values["completed"]), body: parsed.body,
            extraFrontMatter: parsed.extra, url: url.canonical, createdAt: values?.creationDate, modifiedAt: values?.contentModificationDate
        )
    }

    /// Scans only files bearing the explicit `.bw.md` suffix and marker.  Normal
    /// Markdown files are never reinterpreted as work items.
    /// Dependency trees, build output and VCS internals. These cannot hold a work item
    /// a person wrote, and they dominate the file count of any real workspace: pruning
    /// them takes a walk of this workspace from 1,165,664 files to 236,372.
    public static let prunedDirectoryNames: Set<String> = [
        ".git", ".svn", ".hg",
        "node_modules", ".venv", "venv", "__pycache__", ".tox",
        "build", ".build", "dist", "target", "DerivedData", "Pods",
        ".next", ".nuxt", ".gradle", ".cache",
    ]

    public func items(under root: URL, limit: Int = 20_000) -> [WorkItem] {
        scan(under: root, limit: limit)?.items ?? []
    }

    public struct Scan: Sendable {
        public var items: [WorkItem]
        public var complete: Bool
    }

    /// An unavailable or incomplete read must never replace a last-known-good index.
    public func scan(under root: URL, limit: Int = 20_000) -> Scan? {
        guard (try? root.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { return nil }
        var complete = true
        guard let enumerator = fm.enumerator(
            at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { _, _ in complete = false; return true }
        ) else { return nil }
        var result: [WorkItem] = []
        for case let url as URL in enumerator {
            if result.count >= limit || Task.isCancelled { complete = false; break }
            if Self.prunedDirectoryNames.contains(url.lastPathComponent) {
                enumerator.skipDescendants()
                continue
            }
            if NoiseFilter.isForeignMetadata(name: url.lastPathComponent)
                || NoiseFilter.foreignTopLevelDirectories.contains(url.lastPathComponent)
                || (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
                enumerator.skipDescendants()
                continue
            }
            guard url.lastPathComponent.hasSuffix(Self.fileSuffix),
                  (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
                  let item = read(at: url)
            else { continue }
            result.append(item)
        }
        return Scan(items: Self.indexed(result), complete: complete)
    }

    /// One record per id, in display order.
    ///
    /// A copied Markdown file can legitimately retain the original front-matter id.
    /// Keep one deterministic representative rather than handing SwiftUI two rows with
    /// the same identity (which causes selection and edits to target an arbitrary row).
    /// The files remain untouched for the person to resolve.
    public static func indexed(_ items: [WorkItem]) -> [WorkItem] {
        var unique: [String: WorkItem] = [:]
        for item in items {
            if let existing = unique[item.id] {
                if item.url.canonicalPath.localizedStandardCompare(existing.url.canonicalPath) == .orderedAscending {
                    unique[item.id] = item
                }
            } else {
                unique[item.id] = item
            }
        }
        return unique.values.sorted { lhs, rhs in
            if lhs.status != rhs.status { return lhs.isOpen }
            if lhs.stage != rhs.stage { return lhs.stage.rank < rhs.stage.rank }
            if lhs.priority != rhs.priority { return lhs.priority.rank < rhs.priority.rank }
            return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
        }
    }

    // MARK: Incremental updates

    /// What a batch of filesystem changes means for the known work items.
    public enum Reconciliation: Sendable {
        /// Re-read records to add or replace, and paths whose records are gone.
        case incremental(upserts: [WorkItem], removedPaths: Set<String>)
        /// A folder that held records moved or vanished; only a full walk can say where
        /// they went.
        case rescan
    }

    /// Works out what changed without walking the whole Workspace.
    ///
    /// A full walk is ~1–2 s on the real Workspace (168k entries after pruning), and it
    /// used to run for every change to any record — twice for a save in the app, once
    /// for the save and once for its file event. A changed record file is re-read on
    /// its own; a folder that appeared (moved or copied in) is scanned on its own; only
    /// a folder that *held* records moving or disappearing needs the full walk.
    ///
    /// A record that exists but does not parse is left as it was: another editor may be
    /// half-way through writing it, and "unreadable right now" is not "deleted".
    public func reconcile(changedPaths: [String], known: [WorkItem]) -> Reconciliation {
        var upserts: [WorkItem] = []
        var removed: Set<String> = []
        let knownPaths = known.map(\.url.canonicalPath)
        let paths = Set(changedPaths.filter { path in
            !URL(fileURLWithPath: path).pathComponents.contains { NoiseFilter.isForeignMetadata(name: $0) || NoiseFilter.foreignTopLevelDirectories.contains($0) }
        }.map { URL(fileURLWithPath: $0).canonicalPath })
        // FSEvents often names a folder and many descendants in one burst. Read each
        // subtree once rather than once per ancestor.
        let roots = paths.filter { path in
            var parent = URL(fileURLWithPath: path).deletingLastPathComponent()
            while parent.path != "/" {
                if paths.contains(parent.canonicalPath) { return false }
                parent.deleteLastPathComponent()
            }
            return true
        }
        for raw in roots {
            let url = URL(fileURLWithPath: raw)
            var isDirectory: ObjCBool = false
            let exists = fm.fileExists(atPath: raw, isDirectory: &isDirectory)
            if raw.hasSuffix(Self.fileSuffix) {
                if exists == false { removed.insert(raw) }
                else if let item = read(at: url) { upserts.append(item) }
                continue
            }
            // A folder that held records is gone (moved away, renamed, deleted): its
            // records are somewhere this batch did not name.
            if exists == false, knownPaths.contains(where: { $0.hasPrefix(raw + "/") }) {
                return .rescan
            }
            // A folder that is here may have just arrived carrying records, and a move
            // reports only the folder, not the files inside it.
            if exists, isDirectory.boolValue, url.pathComponents.contains(where: Self.prunedDirectoryNames.contains) == false {
                upserts.append(contentsOf: items(under: url))
            }
        }
        return .incremental(upserts: upserts, removedPaths: removed)
    }

    /// Applies a reconciliation to a known list.
    public static func merged(_ known: [WorkItem], upserting upserts: [WorkItem],
                              removingPaths removed: Set<String>) -> [WorkItem] {
        let replaced = Set(upserts.map(\.url.canonicalPath)).union(removed)
        // Also drop an older copy of an upserted id at another path only if that path
        // is gone; otherwise `indexed` keeps its deterministic representative.
        let kept = known.filter { replaced.contains($0.url.canonicalPath) == false }
        return indexed(kept + upserts)
    }

    public func update(_ item: WorkItem) throws -> WorkItem {
        var value = item
        if let previous = read(at: item.url), previous.priority != item.priority,
           var metadata = item.actionMetadata, metadata.legacyPriority != item.priority {
            metadata.priority = item.priority == .high ? "P1" : item.priority == .medium ? "P2" : "P3"
            value.actionMetadata = metadata
        }
        try write(value, expectedModificationDate: item.modifiedAt)
        return read(at: item.url) ?? item
    }

    public func complete(_ item: WorkItem, now: Date = Date()) throws -> WorkItem {
        var copy = item
        copy.status = .completed
        copy.completedAt = now
        return try update(copy)
    }

    /// Moves the record to the Trash — recoverable from Finder, never an unlink. Refuses
    /// a record changed on disk since it was read, exactly as a save does.
    ///
    /// `into` replaces the system Trash with a folder (an isolated test's sandbox), so a
    /// test never fills the person's real Trash.
    @discardableResult
    public func trash(_ item: WorkItem, into folder: URL? = nil) throws -> URL? {
        try ensureUnchanged(item)
        if let folder {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            let destination = folder.appendingPathComponent(UUID().uuidString + "-" + item.url.lastPathComponent)
            try fm.moveItem(at: item.url, to: destination)
            return destination
        }
        var trashed: NSURL?
        try fm.trashItem(at: item.url, resultingItemURL: &trashed)
        return trashed as URL?
    }

    /// Moves the single Markdown record; child/parent relationships use stable IDs so
    /// they do not break when a file is reorganized in Finder or in the app.
    public func move(_ item: WorkItem, to directory: URL) throws -> WorkItem {
        try ensureUnchanged(item)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = uniqueURL(in: directory, title: item.title)
        try fm.moveItem(at: item.url, to: destination)
        return read(at: destination) ?? item
    }

    /// Restores a record at its last known path after someone removed it outside the
    /// app. This is deliberately different from `create`: the original path is part of
    /// the user's choice, and a new filename would make the recovery look like a new
    /// task. It never replaces a file that appeared in the meantime.
    @discardableResult
    public func restore(_ item: WorkItem) throws -> WorkItem {
        guard fm.fileExists(atPath: item.url.path) == false else {
            throw CocoaError(.fileWriteFileExists)
        }
        try fm.createDirectory(at: item.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let staged = try stage(render(item), beside: item.url)
        do {
            try fm.moveItem(at: staged, to: item.url)
        } catch {
            try? fm.removeItem(at: staged)
            throw error
        }
        return read(at: item.url) ?? item
    }

    /// Replaces an existing record.
    ///
    /// Staged beside the file and swapped in with `replaceItemAt`, so the save is
    /// atomic *and* keeps the file's creation date and extended attributes. A plain
    /// atomic string write kept the first but dropped every extended attribute —
    /// quarantine, provenance, other tools' markers.
    private func write(_ item: WorkItem, expectedModificationDate: Date? = nil) throws {
        guard fm.fileExists(atPath: item.url.path) else { throw WorkItemError.missing(item.url) }
        if let expectedModificationDate { try ensureUnchanged(item, expectedModificationDate: expectedModificationDate) }
        let staged = try stage(render(item), beside: item.url)
        do {
            _ = try fm.replaceItemAt(item.url, withItemAt: staged)
        } catch {
            try? fm.removeItem(at: staged)
            throw error
        }
    }

    /// A temporary copy on the same volume as `url`, so the move or swap into place is
    /// a rename rather than a copy.
    ///
    /// Named `.bw-save-<UUID>.tmp`: a fixed shape nothing else produces, so a copy left
    /// behind by a crash can be recognised as this app's and nothing else's (see
    /// `cleanUpStaging`). The record's own name is deliberately not part of it — a long
    /// title made the old staging name exceed the 255-byte limit and every save fail.
    private func stage(_ content: String, beside url: URL) throws -> URL {
        let staged = url.deletingLastPathComponent()
            .appendingPathComponent(Self.stagingPrefix + UUID().uuidString + Self.stagingSuffix)
        try Data(content.utf8).write(to: staged, options: .withoutOverwriting)
        return staged
    }

    // MARK: Leftovers from an interrupted save

    public static let stagingPrefix = ".bw-save-"
    public static let stagingSuffix = ".tmp"

    /// True only for this app's staging names: the exact prefix, a UUID, the suffix.
    public static func isStagingName(_ name: String) -> Bool {
        guard name.hasPrefix(stagingPrefix), name.hasSuffix(stagingSuffix) else { return false }
        let middle = name.dropFirst(stagingPrefix.count).dropLast(stagingSuffix.count)
        return UUID(uuidString: String(middle)) != nil
    }

    public struct StagingCleanup: Sendable {
        public var removed: [URL] = []
        /// Records whose creation was interrupted, put in place under a visible name.
        public var recovered: [URL] = []
    }

    /// Clears what a crash during a save left behind, touching nothing it cannot prove
    /// is its own.
    ///
    /// A file is considered only if all of these hold: its name has the exact staging
    /// shape, it is a small regular file, its content parses as a Better Workspace
    /// record, and it is older than `minimumAge` (so a save in flight is never touched).
    /// Then:
    /// - a record with the same id exists → the save never completed and the record on
    ///   disk is intact; the leftover is removed;
    /// - no record has that id → a *create* was interrupted, and the leftover is the
    ///   only copy; it is moved into place under a visible name rather than deleted.
    public func cleanUpStaging(in directories: [URL], knownIDs: Set<String>,
                               minimumAge: TimeInterval = 600, now: Date = Date()) -> StagingCleanup {
        var result = StagingCleanup()
        var known = knownIDs
        for directory in Set(directories.map(\.canonicalPath)).map({ URL(fileURLWithPath: $0) }) {
            guard let names = try? fm.contentsOfDirectory(atPath: directory.path) else { continue }
            for name in names where Self.isStagingName(name) {
                let url = directory.appendingPathComponent(name)
                guard let attributes = try? fm.attributesOfItem(atPath: url.path),
                      attributes[.type] as? FileAttributeType == .typeRegular,
                      let size = attributes[.size] as? NSNumber, size.intValue < 5_000_000,
                      let modified = attributes[.modificationDate] as? Date,
                      now.timeIntervalSince(modified) >= minimumAge,
                      let text = try? String(contentsOf: url, encoding: .utf8)
                else { continue }
                guard let parsed = parse(text), let id = parsed.values["id"], id.isEmpty == false else {
                    // Cut off mid-write: empty, or this app's header and no more. Still
                    // provably ours by name and content, and nothing to recover.
                    if text.isEmpty || text.hasPrefix("---\n\(Self.markerKey): 1\n") {
                        if (try? fm.removeItem(at: url)) != nil { result.removed.append(url) }
                    }
                    continue
                }
                if known.contains(id) {
                    if (try? fm.removeItem(at: url)) != nil { result.removed.append(url) }
                } else {
                    let title = parsed.values["title"].flatMap { $0.isEmpty ? nil : $0 } ?? "Recovered work item"
                    let destination = uniqueURL(in: directory, title: title)
                    if (try? fm.moveItem(at: url, to: destination)) != nil {
                        result.recovered.append(destination)
                        known.insert(id)
                    }
                }
            }
        }
        return result
    }

    /// An editor keeps a snapshot while its sheet is open. Refuse to replace a file
    /// that changed since that snapshot was read; the Markdown file is authoritative
    /// and an explicit reload is safer than silently discarding an external edit.
    private func ensureUnchanged(_ item: WorkItem, expectedModificationDate: Date? = nil) throws {
        let expected = expectedModificationDate ?? item.modifiedAt
        guard let expected else { return }
        guard fm.fileExists(atPath: item.url.path) else { throw WorkItemError.missing(item.url) }
        // From the filesystem, not `item.url.resourceValues`: that caches per URL
        // instance, and a cached date would make an external edit look unchanged — the
        // one thing this check exists to catch.
        let actual = try fm.attributesOfItem(atPath: item.url.path)[.modificationDate] as? Date
        guard actual == expected else { throw WorkItemError.changedOnDisk(item.url) }
    }

    private func uniqueURL(in directory: URL, title: String, skipping taken: Set<String> = []) -> URL {
        let base = CaptureNaming.safeFilename(title)
        var candidate = directory.appendingPathComponent(base + Self.fileSuffix)
        var number = 2
        while fm.fileExists(atPath: candidate.path) || taken.contains(candidate.lastPathComponent) {
            candidate = directory.appendingPathComponent("\(base) \(number)" + Self.fileSuffix)
            number += 1
        }
        return candidate
    }

    private func render(_ item: WorkItem) -> String {
        var lines = [
            "---", "better-workspace: 1", "id: \(item.id)", "kind: \(item.kind.rawValue)",
            "title: \(quoted(item.title))", "status: \(item.status.rawValue)",
            "stage: \(item.stage.rawValue)", "priority: \(item.priority.rawValue)"
        ]
        if let projectPath = item.projectPath, projectPath.isEmpty == false { lines.append("project: \(quoted(projectPath))") }
        if let parentID = item.parentID, parentID.isEmpty == false { lines.append("parent: \(parentID)") }
        if item.relatedIDs.isEmpty == false { lines.append("related: [\(item.relatedIDs.joined(separator: ", "))]") }
        for (key, ids) in [("parents", item.parentIDs), ("dependencies", item.dependencyIDs), ("features", item.featureIDs), ("milestones", item.milestoneIDs)] where !ids.isEmpty { lines.append("\(key): [\(ids.joined(separator: ", "))]") }
        if let pageID = item.notionPageID { lines.append("notion-page-id: \(pageID)") }
        if let dueDate = item.dueDate { lines.append("due: \(dateString(dueDate))") }
        if let completedAt = item.completedAt { lines.append("completed: \(dateString(completedAt))") }
        lines.append(contentsOf: item.extraFrontMatter)
        lines.append("---")
        lines.append("")
        lines.append("# \(item.title)")
        if item.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            lines.append("")
            lines.append(item.body.trimmingCharacters(in: .newlines))
        }
        lines.append("")
        return lines.joined(separator: "\n")
    }

    /// The keys this app writes. Anything else in the front matter is kept as-is.
    private static let knownKeys: Set<String> = [
        markerKey, "id", "kind", "title", "status", "stage", "priority",
        "project", "parent", "related", "due", "completed", "parents", "dependencies", "features", "milestones", "notion-page-id",
    ]

    private func parse(_ text: String) -> (values: [String: String], body: String, extra: [String])? {
        guard text.hasPrefix("---\n") || text.hasPrefix("---\r\n") else { return nil }
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        let parts = normalized.components(separatedBy: "\n---\n")
        guard parts.count >= 2, parts[0].hasPrefix("---\n") else { return nil }
        let header = String(parts[0].dropFirst(4))
        var values: [String: String] = [:]
        var extra: [String] = []
        for line in header.split(separator: "\n", omittingEmptySubsequences: false) {
            // Indented lines continue the key above them (a YAML list, a folded string);
            // lines with no key are someone's comment. Both belong to someone else.
            guard let colon = line.firstIndex(of: ":"), line.first?.isWhitespace != true else {
                if line.isEmpty == false { extra.append(String(line)) }
                continue
            }
            let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            if Self.knownKeys.contains(key) == false {
                extra.append(String(line))
                continue
            }
            var value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("\"") && value.hasSuffix("\"") && value.count >= 2 {
                value.removeFirst(); value.removeLast()
                value = value.replacingOccurrences(of: "\\\"", with: "\"")
                    .replacingOccurrences(of: "\\\\", with: "\\")
            }
            values[key] = value
        }
        guard values[Self.markerKey] == "1" else { return nil }
        var body = parts.dropFirst().joined(separator: "\n---\n").trimmingCharacters(in: .newlines)
        let heading = "# \(values["title"] ?? "")"
        if body == heading { body = "" }
        else if body.hasPrefix(heading + "\n") {
            body = String(body.dropFirst(heading.count)).trimmingCharacters(in: .newlines)
        }
        return (values, body, extra)
    }

    private func quoted(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    private func parseList(_ raw: String?) -> [String] {
        guard let raw, raw.hasPrefix("["), raw.hasSuffix("]") else { return [] }
        return raw.dropFirst().dropLast().split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { $0.isEmpty == false }
    }

    private func date(_ raw: String?) -> Date? {
        guard let raw else { return nil }
        // A malformed optional date is unknown. The old fallback turned it into an
        // arbitrary calendar date, which could surface a corrupt record as overdue.
        return ISO8601DateFormatter().date(from: raw)
    }

    private func dateString(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }
}
