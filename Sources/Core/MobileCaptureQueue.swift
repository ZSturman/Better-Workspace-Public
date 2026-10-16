import Foundation

/// A top-level Workspace folder the Mac has published as a filing destination. A
/// name and a workspace-relative path only: the phone never has the folder itself.
public struct MobileCaptureDestination: Codable, Hashable, Sendable, Identifiable {
    public let path: String
    public let name: String
    public var id: String { path }

    /// The work item a capture filed here becomes, for the folders known by name as
    /// work queues. The phone uses it to offer project/feature/milestone links; the Mac
    /// makes the work item whatever the phone guessed.
    public var workItemKind: WorkItemKind? {
        let configuration = AreaDefaults.configuration(forFolderNamed: name)
        return configuration.layout == .workQueue ? configuration.workItemKind : nil
    }

    public init(path: String, name: String) {
        self.path = path
        self.name = name
    }
}

/// The last tags and folders the Mac published, kept so App Intents and the Share
/// extension can offer them without waiting on CloudKit (or working without it).
public struct MobileCaptureCatalog: Codable, Equatable, Sendable {
    public var tags: [Tag]
    public var destinations: [MobileCaptureDestination]
    public var updatedAt: Date

    public init(tags: [Tag], destinations: [MobileCaptureDestination], updatedAt: Date = Date()) {
        self.tags = tags
        self.destinations = destinations
        self.updatedAt = updatedAt
    }

    /// Top-level folders from the Mac's published index.
    public static func destinations(from entries: [MobileWorkspaceEntry]) -> [MobileCaptureDestination] {
        entries.filter { $0.parentPath == nil && $0.isDirectory }
            .map { MobileCaptureDestination(path: $0.path, name: $0.name) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

/// The one way anything on the phone hands a saved capture to the Mac.
///
/// The app, its App Intents and the Share extension all save real files into the
/// shared iCloud Inbox with `MobileCaptureService`, then come here. This queues the
/// optional filing request (destination, idea, tags) as a CloudKit intent, records the
/// save for Recently Added, and keeps the catalog of tags and folders. Everything
/// lives in the app group, so a save from the Share extension is in the app's
/// Recently Added and its queued filing is sent by whichever process flushes next.
public final class MobileCaptureQueue: @unchecked Sendable {
    public static let outboxKey = "mobileCaptureIntentOutbox"
    public static let logKey = "recentCaptureLog"
    static let catalogKey = "mobileCaptureCatalog.v1"

    public let outbox: MobileIntentOutbox
    public let log: RecentCaptureLog
    private let defaults: UserDefaults

    public init(defaults: UserDefaults, outboxKey: String = MobileCaptureQueue.outboxKey,
                logKey: String = MobileCaptureQueue.logKey, ledger: WidgetCommandStore? = nil) {
        self.defaults = defaults
        self.outbox = MobileIntentOutbox(defaults: defaults, key: outboxKey, ledger: ledger, stream: "capture")
        self.log = RecentCaptureLog(defaults: defaults, key: logKey)
    }

    /// The app group's queue. The first time, a history and outbox the app kept in its
    /// own defaults (before the group held them) are moved across, never dropped.
    public static func shared(appGroup: String = WidgetAppGroup.mobile,
                              legacy: UserDefaults = .standard) -> MobileCaptureQueue {
        guard let group = UserDefaults(suiteName: appGroup) else {
            return MobileCaptureQueue(defaults: legacy)
        }
        migrate(from: legacy, to: group)
        let ledger = WidgetCommandStore.shared(appGroup: appGroup)
        try? ledger?.migrate(defaults: group, outboxKey: outboxKey, stream: "capture")
        return MobileCaptureQueue(defaults: group, ledger: ledger)
    }

    static func migrate(from legacy: UserDefaults, to group: UserDefaults) {
        for key in [outboxKey, logKey] {
            guard let data = legacy.data(forKey: key) else { continue }
            if group.data(forKey: key) == nil { group.set(data, forKey: key) }
            legacy.removeObject(forKey: key)
        }
    }

    // MARK: Catalog

    public func catalog() -> MobileCaptureCatalog? {
        guard let data = defaults.data(forKey: Self.catalogKey) else { return nil }
        return try? JSONDecoder().decode(MobileCaptureCatalog.self, from: data)
    }

    /// Saves only a catalog that has something in it: an empty answer from a CloudKit
    /// that is still waking up is not a reason to forget every folder and tag.
    public func saveCatalog(_ catalog: MobileCaptureCatalog) {
        guard catalog.tags.isEmpty == false || catalog.destinations.isEmpty == false,
              let data = try? JSONEncoder().encode(catalog) else { return }
        defaults.set(data, forKey: Self.catalogKey)
    }

    /// A tag that is new to the catalog: queued for the Mac to create with this id,
    /// and added to the local catalog so the next capture finds it.
    public func queueNewTag(_ tag: Tag) {
        outbox.append(.tagCreation(tag))
        // With no catalog yet (first run, CloudKit not answered), start one: the tag
        // must be findable by the next capture either way.
        var current = catalog() ?? MobileCaptureCatalog(tags: [], destinations: [])
        guard current.tags.contains(where: { $0.id == tag.id }) == false else { return }
        current.tags.append(tag)
        current.tags.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        saveCatalog(current)
    }

    /// Resolves typed tag names against the catalog — an existing tag of the same name
    /// is reused (TagMatching), anything else becomes a new tag.
    public func tags(named names: [String]) -> [Tag] {
        var known = catalog()?.tags ?? []
        var result: [Tag] = []
        for name in names {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.isEmpty == false else { continue }
            if let existing = TagMatching.equivalent(to: trimmed, in: known) {
                if result.contains(existing) == false { result.append(existing) }
                continue
            }
            let tag = Tag(name: trimmed, colorIndex: Tag.colorIndex(for: trimmed))
            queueNewTag(tag)
            known.append(tag)
            result.append(tag)
        }
        return result
    }

    // MARK: Saves

    /// Records one saved capture and queues its filing request, if it has one.
    ///
    /// `kind == .idea` asks the Mac to make it an idea (its own folder in Ideas). The
    /// capture is already safely in the Inbox before this is called; nothing here can
    /// lose it.
    @discardableResult
    public func record(savedURL url: URL, destination: MobileCaptureDestination?,
                       kind: CaptureClassificationKind? = nil, tagIDs: Set<String> = [],
                       links: WorkItemLinks? = nil, now: Date = Date()) -> [RecentCaptureRecord] {
        if destination != nil || kind != nil || tagIDs.isEmpty == false {
            outbox.append(.captureClassification(
                name: url.lastPathComponent, kind: kind, tagIDs: tagIDs,
                destinationPath: destination?.path,
                expectedChildren: MobileCaptureBundleReceipt.children(at: url) ?? [],
                links: links
            ))
        }
        let placement = destination ?? (kind == .idea ? Self.ideasDestination : nil)
        return log.recordSave(name: url.lastPathComponent, destinationPath: placement?.path,
                              destinationName: placement?.name, now: now)
    }

    /// Ideas are filed by kind, into a folder of their own under Ideas.
    public static let ideasDestination = MobileCaptureDestination(path: WorkspaceArea.ideas.directoryName,
                                                                  name: WorkspaceArea.ideas.directoryName)

    /// Widget filing shares the capture queue and the planning receipt protocol.
    @discardableResult
    public static func confirmWidgetFiling(store: WidgetCommandStore, scope: String, token: UUID) throws -> UUID {
        #if os(macOS)
        return try store.confirm(scope: scope, token: token, stream: "workspace")
        #else
        return try store.confirm(scope: scope, token: token, stream: "capture")
        #endif
    }

    /// Sends what is queued. Anything that cannot be sent stays queued for the next
    /// process that tries; the captures themselves are already in the Inbox.
    public func flush(using store: MobileCloudStore) async -> MobileOutboxFlush {
        await outbox.flush { intent in try await store.submit(intent) }
    }

    /// Says where a save went (shared by every entry point).
    public static func savedMessage(count: Int, destination: MobileCaptureDestination?,
                                    kind: CaptureClassificationKind? = nil) -> String {
        let name = destination?.name ?? (kind == .idea ? ideasDestination.name : nil)
        return RecentCaptureHistory.savedMessage(count: count, destinationName: name)
    }
}
