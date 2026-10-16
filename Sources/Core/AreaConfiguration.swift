import Foundation

// MARK: - Vocabulary

/// How an area's contents are drawn.
///
/// `purposeBuilt` means "the dedicated view for this folder", and is only meaningful
/// when the folder has one (`WorkspaceArea`). Every other case is a generic renderer
/// any folder can choose, which is what makes a Finder-created folder configurable
/// without a code change.
public enum AreaLayout: String, CaseIterable, Codable, Sendable, Identifiable {
    case purposeBuilt
    case list
    case table
    case gallery
    case timeline
    case outline
    case workQueue

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .purposeBuilt: return "Purpose-built view"
        case .list: return "List"
        case .table: return "Table"
        case .gallery: return "Gallery"
        case .timeline: return "Timeline"
        case .outline: return "Outline"
        case .workQueue: return "Work queue"
        }
    }

    public var explanation: String {
        switch self {
        case .purposeBuilt: return "The dedicated view written for this folder."
        case .list: return "One row per item, with size, date and tags."
        case .table: return "Sortable columns for comparing many items."
        case .gallery: return "Thumbnails, for folders of images and video."
        case .timeline: return "Items by month, from when they were added or last changed."
        case .outline: return "Subfolders open in place, to see what is inside without leaving."
        case .workQueue: return "Better Workspace work items (.bw.md) filed in this folder."
        }
    }

    public var symbolName: String {
        switch self {
        case .purposeBuilt: return "star.square"
        case .list: return "list.bullet"
        case .table: return "tablecells"
        case .gallery: return "square.grid.2x2"
        case .timeline: return "calendar.day.timeline.left"
        case .outline: return "list.bullet.indent"
        case .workQueue: return "checklist"
        }
    }
}

public enum AreaSort: String, CaseIterable, Codable, Sendable, Identifiable {
    case name, newest, oldest, largest
    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .name: return "Name"
        case .newest: return "Newest first"
        case .oldest: return "Oldest first"
        case .largest: return "Largest first"
        }
    }
}

/// Where an area sits among ingest destinations.
///
/// Frequency is deliberately not inferred (see `DestinationOrder`): a folder's position
/// should be somewhere you learn once, so it only moves when you say so.
public enum AreaIngestRole: String, CaseIterable, Codable, Sendable, Identifiable {
    /// Offered first — where captures usually belong.
    case primary
    /// Offered in the ordinary alphabetical run.
    case ordinary
    /// Offered last: archives, feeds, folders written by other tools.
    case system
    /// Not offered as a destination at all. Finder can still put anything anywhere.
    case excluded

    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .primary: return "Offer first"
        case .ordinary: return "Offer normally"
        case .system: return "Offer last"
        case .excluded: return "Don't offer"
        }
    }
}

// MARK: - Configuration

/// How Better Workspace presents one top-level Workspace folder.
///
/// Every field is optional. `nil` means "inherit", which is what makes the layering
/// work: built-in defaults supply a value for folders this app already understands,
/// and a person's own settings override only the fields they actually changed. A
/// field someone never touched keeps following the defaults as they improve.
///
/// This is app-private configuration. It is never written into `~/Workspace`, and a
/// folder with no configuration at all is still a complete, usable area.
public struct AreaConfiguration: Codable, Hashable, Sendable {
    public var layout: AreaLayout?
    public var sort: AreaSort?
    public var symbol: String?
    public var subtitle: String?
    /// When set, "New …" in this area writes a work item of this kind into the folder.
    public var workItemKind: WorkItemKind?
    public var ingest: AreaIngestRole?
    public var hidden: Bool?
    /// Which date a timeline uses. `nil` lets the area's contents decide.
    public var dateBasis: AreaDateBasis?

    public init(layout: AreaLayout? = nil, sort: AreaSort? = nil, symbol: String? = nil,
                subtitle: String? = nil, workItemKind: WorkItemKind? = nil,
                ingest: AreaIngestRole? = nil, hidden: Bool? = nil, dateBasis: AreaDateBasis? = nil) {
        self.layout = layout
        self.sort = sort
        self.symbol = symbol
        self.subtitle = subtitle
        self.workItemKind = workItemKind
        self.ingest = ingest
        self.hidden = hidden
        self.dateBasis = dateBasis
    }

    public var isEmpty: Bool { self == AreaConfiguration() }

    /// `self` wins wherever it says something; `base` fills the rest.
    public func layered(over base: AreaConfiguration) -> AreaConfiguration {
        AreaConfiguration(
            layout: layout ?? base.layout,
            sort: sort ?? base.sort,
            symbol: symbol ?? base.symbol,
            subtitle: subtitle ?? base.subtitle,
            workItemKind: workItemKind ?? base.workItemKind,
            ingest: ingest ?? base.ingest,
            hidden: hidden ?? base.hidden,
            dateBasis: dateBasis ?? base.dateBasis
        )
    }
}

/// A fully resolved configuration: what an area actually looks like right now, after
/// defaults and personal settings are combined and checked against what the folder can
/// do. Views read this; they never interpret an `AreaConfiguration` themselves.
public struct AreaSettings: Hashable, Sendable {
    public var layout: AreaLayout
    public var sort: AreaSort
    public var symbol: String
    public var subtitle: String
    public var workItemKind: WorkItemKind
    public var ingest: AreaIngestRole
    public var hidden: Bool
    /// `nil`: automatic — `AreaCapabilities.preferredDateBasis` for the current contents.
    public var dateBasis: AreaDateBasis?
    /// A work-item kind was configured (by default or by hand), so this area is meant to
    /// hold work even while it is empty.
    public var isWorkQueue: Bool

    public init(resolving configuration: AreaConfiguration, purposeBuilt: WorkspaceArea?) {
        var layout = configuration.layout ?? (purposeBuilt == nil ? .list : .purposeBuilt)
        // A stale setting — say, a folder renamed away from its purpose-built binding —
        // falls back rather than pointing at a view that no longer applies.
        if layout == .purposeBuilt && purposeBuilt == nil { layout = .list }
        self.layout = layout
        sort = configuration.sort ?? .name
        symbol = configuration.symbol ?? "folder"
        subtitle = configuration.subtitle ?? ""
        workItemKind = configuration.workItemKind ?? .task
        ingest = configuration.ingest ?? .ordinary
        hidden = configuration.hidden ?? false
        dateBasis = configuration.dateBasis
        isWorkQueue = configuration.workItemKind != nil || layout == .workQueue
    }
}

// MARK: - Built-in defaults

/// What Better Workspace assumes about folders it already knows, by name.
///
/// This is data, not behavior: the same fields a person can set, pre-filled. It only
/// records what the real Workspace survey supports — a symbol and a one-line purpose
/// for most folders, and a work-queue layout for the folders that hold work items. An
/// empty folder gets no invented dashboard; it gets the plain list until it holds
/// something that argues for more. See DESIGN.md §2.
public enum AreaDefaults {

    public static func configuration(forFolderNamed name: String) -> AreaConfiguration {
        known[name] ?? AreaConfiguration()
    }

    private static let known: [String: AreaConfiguration] = [
        // Purpose-built. Layout is left nil so it resolves to the dedicated view.
        "Projects": .init(symbol: "hammer", subtitle: "Working directories", ingest: .primary),
        "Ideas": .init(symbol: "lightbulb", subtitle: "Titles as thoughts", ingest: .primary),
        "Logs": .init(symbol: "list.bullet.rectangle", subtitle: "Daily log streams", ingest: .system),
        "For Reference": .init(symbol: "book.closed", subtitle: "Reference material"),
        "For Inspiration": .init(symbol: "photo.on.rectangle.angled", subtitle: "Images and video"),
        "To Organize": .init(symbol: "tray.full", subtitle: "Unresolved backlog"),
        "Review": .init(symbol: "checkmark.seal", subtitle: "Awaiting a verdict"),
        "Social Posts": .init(sort: .newest, symbol: "text.bubble", subtitle: "Drafts and published posts",
                              ingest: .system),
        "Assets": .init(symbol: "shippingbox", subtitle: "Media and data libraries", ingest: .system),
        "Backups": .init(symbol: "externaldrive", subtitle: "Snapshots", ingest: .system),

        // Work queues: `NotionImport` and "New …" file work items here.
        "To Do": .init(layout: .workQueue, symbol: "checklist", subtitle: "Action queue",
                       workItemKind: .task, ingest: .primary),
        "Features": .init(layout: .workQueue, symbol: "sparkles", subtitle: "Product work",
                          workItemKind: .feature),
        "Milestones": .init(layout: .workQueue, symbol: "flag.checkered", subtitle: "Important outcomes",
                            workItemKind: .milestone),
        "To Refactor": .init(layout: .workQueue, symbol: "wrench.and.screwdriver",
                             subtitle: "Improvement queue", workItemKind: .task),

        // Known by name, generic in behavior until they hold something.
        "Analytics": .init(symbol: "chart.xyaxis.line", subtitle: "Portfolio and social metrics", ingest: .system),
        "Calendar": .init(sort: .newest, symbol: "calendar", subtitle: "Dates and plans", ingest: .system),
        // Not the Overview screen's symbol: both rows say "Overview" in the sidebar.
        "Overview": .init(symbol: "newspaper", subtitle: "Workspace summaries", ingest: .system),
        "Study": .init(symbol: "graduationcap", subtitle: "Learning material"),
        "To Look Up": .init(symbol: "magnifyingglass", subtitle: "Research queue"),
        "To Read": .init(symbol: "book", subtitle: "Reading queue"),
        "To Watch": .init(symbol: "play.rectangle", subtitle: "Watch queue"),
    ]
}

// MARK: - Persistence

/// Personal area settings, kept in one small JSON file beside this app's database.
///
/// Why a file and not the SQLite store: the database holds tags and this app's index.
/// Configuration is something a person may want to read, back up, diff, or edit by
/// hand — including for a folder that doesn't exist yet — and it has to stay useful
/// with no network and no Notion or iCloud account. A plain file is all of those.
///
/// Why not inside `~/Workspace`: no sidecars. The folders stay ordinary Finder folders.
///
/// Entries are keyed by folder name, because the name is what Finder, Shortcuts and
/// the rest of the Workspace tooling use. Each also remembers the folder's file
/// identity, so renaming a folder in Finder carries its settings with it.
public final class AreaConfigurationStore: @unchecked Sendable {

    public static let fileName = "Areas.json"

    public struct Entry: Codable, Hashable, Sendable {
        public var configuration: AreaConfiguration
        /// `FileIdentity.key` of the folder when last seen. Optional: an entry can be
        /// written for a folder that has not been created yet.
        public var identity: String?

        public init(configuration: AreaConfiguration, identity: String? = nil) {
            self.configuration = configuration
            self.identity = identity
        }
    }

    private struct Document: Codable {
        var version: Int
        var areas: [String: Entry]
    }

    public let url: URL
    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    /// Set when the file exists but could not be understood. Saving would replace
    /// someone's hand edit with an empty file, so the first save moves it aside.
    private var unreadable = false
    public private(set) var loadError: String?
    /// The file's modification date when this store last read or wrote it. A different
    /// date on disk means someone edited it by hand since.
    private var knownModificationDate: Date?

    public init(url: URL) {
        self.url = url
        reload()
    }

    /// Beside the tag database, wherever that is — including a UI test's isolated one.
    public static func defaultURL() -> URL {
        Database.preferredURL().deletingLastPathComponent().appendingPathComponent(fileName)
    }

    public func reload() {
        lock.lock(); defer { lock.unlock() }
        reloadLocked()
    }

    /// Re-reads the file if it changed on disk since this store last saw it. Returns
    /// true when it did, so the caller can re-resolve areas.
    @discardableResult
    public func reloadIfChangedOnDisk() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard modificationDateOnDisk() != knownModificationDate else { return false }
        reloadLocked()
        return true
    }

    /// Asked of the filesystem each time. `URL.resourceValues` caches its answer on
    /// the URL instance, and this store keeps one URL for its lifetime — so it went on
    /// reporting the first date it saw and never noticed a hand edit.
    private func modificationDateOnDisk() -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    /// Before any write: pick up a hand edit made since the last read, so the write
    /// applies one change on top of it instead of replacing the file with an old copy.
    private func refreshBeforeWriteLocked() {
        if modificationDateOnDisk() != knownModificationDate { reloadLocked() }
    }

    private func reloadLocked() {
        knownModificationDate = modificationDateOnDisk()
        loadError = nil
        unreadable = false
        guard let data = try? Data(contentsOf: url) else {
            entries = [:]
            return
        }
        do {
            entries = try JSONDecoder().decode(Document.self, from: data).areas
        } catch {
            // Keep the settings last read: a hand edit saved half-typed should not
            // send every area back to its defaults until the typo is fixed. (At launch
            // there is nothing earlier, so defaults it is.) The broken file is moved
            // aside, not overwritten, by the next save.
            unreadable = true
            loadError = "\(Self.fileName) could not be read (\(error.localizedDescription)). "
                + "Areas are using their defaults; the file is left as it is until a setting changes."
        }
    }

    public func entry(forFolderNamed name: String) -> Entry? {
        lock.lock(); defer { lock.unlock() }
        return entries[name]
    }

    public var allEntries: [String: Entry] {
        lock.lock(); defer { lock.unlock() }
        return entries
    }

    /// Replaces a folder's personal settings. An empty configuration removes the entry,
    /// which returns the folder to its defaults.
    public func set(_ configuration: AreaConfiguration, forFolderNamed name: String, identity: String?) throws {
        lock.lock(); defer { lock.unlock() }
        refreshBeforeWriteLocked()
        var next = entries
        if configuration.isEmpty {
            next.removeValue(forKey: name)
        } else {
            next[name] = Entry(configuration: configuration, identity: identity ?? entries[name]?.identity)
        }
        try write(next)
        entries = next
    }

    /// Follows Finder renames.
    ///
    /// An entry whose folder name no longer exists, but whose remembered identity now
    /// belongs to a folder with no settings of its own, moves to that folder's name.
    /// Identities are refreshed for the folders that kept their names. Returns true when
    /// anything changed. Never discards an entry: a folder that is simply gone keeps its
    /// settings in case it comes back.
    @discardableResult
    public func reconcile(discovered: [(name: String, identity: String?)]) -> Bool {
        lock.lock(); defer { lock.unlock() }
        refreshBeforeWriteLocked()
        var next = entries
        let presentNames = Set(discovered.map(\.name))
        let nameByIdentity = Dictionary(discovered.compactMap { folder in folder.identity.map { ($0, folder.name) } },
                                        uniquingKeysWith: { first, _ in first })
        for (name, entry) in entries where presentNames.contains(name) == false {
            guard let identity = entry.identity,
                  let newName = nameByIdentity[identity],
                  next[newName] == nil
            else { continue }
            next.removeValue(forKey: name)
            next[newName] = entry
        }
        for folder in discovered {
            guard let identity = folder.identity, var entry = next[folder.name], entry.identity != identity
            else { continue }
            entry.identity = identity
            next[folder.name] = entry
        }
        guard next != entries else { return false }
        // Best effort: a failed write only means the rename is re-detected next time.
        // Adopt the result in memory either way so this session shows the right thing.
        try? write(next)
        entries = next
        return true
    }

    private func write(_ areas: [String: Entry]) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if unreadable, FileManager.default.fileExists(atPath: url.path) {
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            let aside = directory.appendingPathComponent("Areas.unreadable-\(stamp).json")
            try FileManager.default.moveItem(at: url, to: aside)
            unreadable = false
            loadError = nil
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(Document(version: 1, areas: areas))
        try data.write(to: url, options: .atomic)
        knownModificationDate = modificationDateOnDisk()
    }
}
