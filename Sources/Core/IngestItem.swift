import Foundation

public enum IngestSource: String, Sendable, Codable, CaseIterable {
    case quickCapture       // macOS menu-bar / global shortcut
    case desktopDrop        // drag & drop onto the app
    case desktopImport      // file picker
    case mobile             // iOS companion
    case external           // appeared in the inbox folder by some other means
    case unknown

    public var displayName: String {
        switch self {
        case .quickCapture: return "Quick Capture"
        case .desktopDrop: return "Dropped"
        case .desktopImport: return "Imported"
        case .mobile: return "iPhone"
        case .external: return "Added to folder"
        case .unknown: return "Unknown"
        }
    }

    public var symbolName: String {
        switch self {
        case .quickCapture: return "bolt"
        case .desktopDrop: return "hand.draw"
        case .desktopImport: return "square.and.arrow.down"
        case .mobile: return "iphone"
        case .external: return "folder.badge.plus"
        case .unknown: return "questionmark"
        }
    }
}

public enum IngestState: String, Sendable, Codable {
    case pending
    case deferred
}

/// An item sitting in the ingest inbox, awaiting classification.
///
/// The `item` is the real filesystem object — everything else is this app's private,
/// temporary metadata about it, discarded once the item is classified and moved.
public struct IngestItem: Identifiable, Sendable, Hashable {
    public let item: WorkspaceItem
    public var capturedAt: Date
    public var source: IngestSource
    public var title: String
    public var state: IngestState
    /// Name of the top-level Workspace folder last chosen for this capture.
    public var proposedDestination: String?
    /// 1 = low, 5 = high. Scheduling never changes the original capture.
    public var priority: Int
    public var reviewAfter: Date?
    public var isDue: Bool { reviewAfter.map { $0 <= Date() } ?? (state == .pending) }
    public static func comesFirst(_ lhs: IngestItem, _ rhs: IngestItem) -> Bool {
        if lhs.isDue != rhs.isDue { return lhs.isDue }
        if lhs.priority != rhs.priority { return lhs.priority > rhs.priority }
        if lhs.reviewAfter != rhs.reviewAfter { return (lhs.reviewAfter ?? .distantPast) < (rhs.reviewAfter ?? .distantPast) }
        if lhs.capturedAt != rhs.capturedAt { return lhs.capturedAt > rhs.capturedAt }
        return lhs.id < rhs.id
    }

    public var id: String { item.id }
    public var url: URL { item.url }
    public var kind: FileKind { item.kind }

    public init(
        item: WorkspaceItem,
        capturedAt: Date,
        source: IngestSource,
        title: String,
        state: IngestState = .pending,
        proposedDestination: String? = nil, priority: Int = 3, reviewAfter: Date? = nil
    ) {
        self.item = item
        self.capturedAt = capturedAt
        self.source = source
        self.title = title
        self.state = state
        self.proposedDestination = proposedDestination
        self.priority = min(5, max(1, priority)); self.reviewAfter = reviewAfter
    }
}

/// A capture that has left the inbox because it was filed.
///
/// Bookkeeping about this app's own action — what it filed, when, and into which
/// top-level folder — kept so a just-filed item stays reachable from Ingest for
/// follow-up tagging and editing. It is not a copy: `url` is the real, filed object.
public struct FiledIngestRecord: Identifiable, Sendable, Hashable {
    public let id: String
    public let title: String
    public let source: IngestSource
    public let capturedAt: Date
    public let filedAt: Date
    /// The top-level Workspace folder it was filed into.
    public let destinationName: String
    public let url: URL

    public init(id: String, title: String, source: IngestSource, capturedAt: Date, filedAt: Date,
                destinationName: String, url: URL) {
        self.id = id
        self.title = title
        self.source = source
        self.capturedAt = capturedAt
        self.filedAt = filedAt
        self.destinationName = destinationName
        self.url = url
    }
}
