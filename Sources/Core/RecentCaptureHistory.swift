import Foundation

/// What the phone remembers about one of its own saves: the Inbox filename it wrote and
/// the filing it asked for. Never the content — the capture is a real file, first in the
/// shared Inbox and then wherever the Mac files it.
public struct RecentCaptureRecord: Codable, Hashable, Sendable, Identifiable {
    public let id: UUID
    /// The capture's filename in the shared Inbox.
    public let name: String
    public let savedAt: Date
    /// Workspace-relative top-level folder the phone asked the Mac to file it into.
    public var destinationPath: String?
    public var destinationName: String?

    public init(id: UUID = UUID(), name: String, savedAt: Date,
                destinationPath: String? = nil, destinationName: String? = nil) {
        self.id = id
        self.name = name
        self.savedAt = savedAt
        self.destinationPath = destinationPath
        self.destinationName = destinationName
    }
}

/// Where a recent capture is now. The distinction the Ingest screen exists to keep:
/// something still waiting to be placed versus something already placed.
public enum RecentCapturePlacement: Hashable, Sendable {
    /// In the Inbox with no destination: still needs filing.
    case needsFiling
    /// In the Inbox, with a destination chosen; the Mac moves it on its next sync.
    case filing(destination: String)
    /// Placed. `path` is its workspace-relative path once the Mac's published index
    /// shows it there, which is what lets the phone tag it afterwards.
    case filed(destination: String, path: String?)
    /// Left the Inbox without a destination from this phone — filed on the Mac — and
    /// not (yet) found in the Mac's published index.
    case filedOnMac

    public var isPlaced: Bool {
        switch self {
        case .filed, .filedOnMac: return true
        case .needsFiling, .filing: return false
        }
    }
}

public struct RecentCaptureRow: Identifiable, Hashable, Sendable {
    public let name: String
    public let date: Date
    public let placement: RecentCapturePlacement
    /// The Inbox file, while it is still there.
    public let inboxURL: URL?

    public var id: String { inboxURL?.path ?? "placed:\(name):\(date.timeIntervalSince1970)" }

    public init(name: String, date: Date, placement: RecentCapturePlacement, inboxURL: URL?) {
        self.name = name
        self.date = date
        self.placement = placement
        self.inboxURL = inboxURL
    }
}

/// Recently Added: the phone's recent saves wherever they went, plus anything else
/// sitting in the shared Inbox. One row per capture — nothing is listed twice and
/// nothing is copied to make it appear here.
public enum RecentCaptureHistory {
    public static let retention: TimeInterval = 14 * 24 * 60 * 60
    public static let recordLimit = 60

    /// Says where a save went. A capture filed straight into a folder was not "added to
    /// the Inbox", even though the Inbox is how it reaches the Mac.
    public static func savedMessage(count: Int, destinationName: String?) -> String {
        let place = destinationName ?? "Inbox"
        return count == 1 ? "Added to \(place)" : "Added \(count) files to \(place)"
    }

    /// Drops records past the retention window and keeps the newest `recordLimit`.
    public static func pruned(_ records: [RecentCaptureRecord], now: Date = Date()) -> [RecentCaptureRecord] {
        let cutoff = now.addingTimeInterval(-retention)
        return Array(records.filter { $0.savedAt >= cutoff }
            .sorted { $0.savedAt > $1.savedAt }
            .prefix(recordLimit))
    }

    /// Resolves each record against the last successful Inbox listing and the Mac's
    /// published index.
    ///
    /// - Parameters:
    ///   - inbox: The Inbox's current children. Pass the last *successful* listing: an
    ///     unreadable Inbox is not an empty one, and treating it as empty would
    ///     announce every pending capture as filed.
    ///   - entries: The Mac-published index (area roots and their direct children).
    public static func rows(records: [RecentCaptureRecord],
                            inbox: [(url: URL, modified: Date)],
                            entries: [MobileWorkspaceEntry],
                            limit: Int = 30) -> [RecentCaptureRow] {
        var unclaimed = Dictionary(inbox.map { ($0.url.lastPathComponent, $0) }, uniquingKeysWith: { a, _ in a })
        let entryPaths = Set(entries.map(\.path))
        var rows: [RecentCaptureRow] = []

        // Newest first, so a reused filename belongs to the newest save.
        for record in records.sorted(by: { $0.savedAt > $1.savedAt }) {
            if let file = unclaimed.removeValue(forKey: record.name) {
                let placement: RecentCapturePlacement = record.destinationName.map { .filing(destination: $0) }
                    ?? .needsFiling
                rows.append(RecentCaptureRow(name: record.name, date: record.savedAt,
                                             placement: placement, inboxURL: file.url))
                continue
            }
            rows.append(RecentCaptureRow(name: record.name, date: record.savedAt,
                                         placement: placement(leftInbox: record, entries: entries,
                                                              entryPaths: entryPaths),
                                         inboxURL: nil))
        }
        // Inbox content this phone did not save (the Mac, another device, Finder) still
        // needs filing and belongs in the list.
        for file in unclaimed.values {
            rows.append(RecentCaptureRow(name: file.url.lastPathComponent, date: file.modified,
                                         placement: .needsFiling, inboxURL: file.url))
        }
        return Array(rows.sorted { $0.date > $1.date }.prefix(limit))
    }

    private static func placement(leftInbox record: RecentCaptureRecord,
                                  entries: [MobileWorkspaceEntry],
                                  entryPaths: Set<String>) -> RecentCapturePlacement {
        if let destinationPath = record.destinationPath, let destinationName = record.destinationName {
            let path = destinationPath + "/" + record.name
            return .filed(destination: destinationName, path: entryPaths.contains(path) ? path : nil)
        }
        // Filed on the Mac. Name it only when the index has exactly one candidate; a
        // common name is not evidence of where this capture went.
        let candidates = entries.filter { $0.name == record.name && $0.parentPath != nil }
        if candidates.count == 1, let found = candidates.first, let area = found.parentPath {
            let areaName = entries.first(where: { $0.path == area })?.name ?? area
            return .filed(destination: areaName, path: found.path)
        }
        return .filedOnMac
    }
}

/// The phone's record of its own recent saves, kept in its own defaults.
public final class RecentCaptureLog: @unchecked Sendable {
    private let defaults: UserDefaults
    private let key: String

    public init(defaults: UserDefaults = .standard, key: String) {
        self.defaults = defaults
        self.key = key
    }

    public func load(now: Date = Date()) -> [RecentCaptureRecord] {
        guard let data = defaults.data(forKey: key),
              let records = try? JSONDecoder().decode([RecentCaptureRecord].self, from: data)
        else { return [] }
        return RecentCaptureHistory.pruned(records, now: now)
    }

    public func save(_ records: [RecentCaptureRecord], now: Date = Date()) {
        guard let data = try? JSONEncoder().encode(RecentCaptureHistory.pruned(records, now: now)) else { return }
        defaults.set(data, forKey: key)
    }

    /// Records a new save. The Inbox gives every capture a unique name while it is
    /// there, so this is always a new record.
    @discardableResult
    public func recordSave(name: String, destinationPath: String?, destinationName: String?,
                           now: Date = Date()) -> [RecentCaptureRecord] {
        var records = load(now: now)
        records.append(RecentCaptureRecord(name: name, savedAt: now,
                                           destinationPath: destinationPath, destinationName: destinationName))
        save(records, now: now)
        return load(now: now)
    }

    /// Records the filing later chosen for an Inbox capture: the newest record with
    /// that filename, or a new one dated `savedAt` for a capture this phone did not save.
    @discardableResult
    public func setDestination(name: String, savedAt: Date, destinationPath: String, destinationName: String,
                               now: Date = Date()) -> [RecentCaptureRecord] {
        var records = load(now: now)
        if let index = records.firstIndex(where: { $0.name == name }) {
            records[index].destinationPath = destinationPath
            records[index].destinationName = destinationName
        } else {
            records.append(RecentCaptureRecord(name: name, savedAt: savedAt,
                                               destinationPath: destinationPath, destinationName: destinationName))
        }
        save(records, now: now)
        return load(now: now)
    }

    @discardableResult
    public func forget(name: String, now: Date = Date()) -> [RecentCaptureRecord] {
        var records = load(now: now)
        if let index = records.firstIndex(where: { $0.name == name }) { records.remove(at: index) }
        save(records, now: now)
        return load(now: now)
    }
}
