import Foundation
import UniformTypeIdentifiers

/// How a filesystem object should be treated in the UI.
public enum FileKind: String, Sendable, Codable, CaseIterable {
    case folder
    case markdown
    case document      // pdf, docx, pages, rtf, txt
    case spreadsheet   // xlsx, csv, numbers
    case image
    case video
    case audio
    case archive       // zip, dmg, gz
    case code
    case model3D       // stl, obj, blend
    case log
    case data          // json, db, sqlite
    case other

    public var symbolName: String {
        switch self {
        case .folder: return "folder"
        case .markdown: return "doc.richtext"
        case .document: return "doc.text"
        case .spreadsheet: return "tablecells"
        case .image: return "photo"
        case .video: return "film"
        case .audio: return "waveform"
        case .archive: return "archivebox"
        case .code: return "chevron.left.forwardslash.chevron.right"
        case .model3D: return "cube"
        case .log: return "text.alignleft"
        case .data: return "cylinder"
        case .other: return "doc"
        }
    }

    public var displayName: String {
        switch self {
        case .model3D: return "3D Model"
        case .markdown: return "Markdown"
        default: return rawValue.capitalized
        }
    }

    public var isVisualMedia: Bool { self == .image || self == .video }

    public static func classify(url: URL, isDirectory: Bool) -> FileKind {
        if isDirectory { return .folder }
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "md", "markdown", "mdown": return .markdown
        case "log", "out", "err": return .log
        case "json", "jsonl", "db", "sqlite", "sqlite3", "db-wal", "db-shm", "plist", "toml", "yaml", "yml":
            return .data
        case "stl", "obj", "blend", "blend1", "gcode", "3mf", "step": return .model3D
        case "csv", "tsv", "xlsx", "xlsm", "xls", "numbers": return .spreadsheet
        case "zip", "dmg", "gz", "tgz", "tar", "7z", "rar", "pkg": return .archive
        case "swift", "py", "js", "ts", "tsx", "jsx", "rb", "go", "rs", "c", "h", "m", "cpp", "sh", "lua":
            return .code
        default: break
        }
        guard let type = UTType(filenameExtension: ext) else {
            return ext.isEmpty ? .other : .other
        }
        if type.conforms(to: .image) { return .image }
        if type.conforms(to: .movie) || type.conforms(to: .video) { return .video }
        if type.conforms(to: .audio) { return .audio }
        if type.conforms(to: .archive) { return .archive }
        if type.conforms(to: .sourceCode) { return .code }
        if type.conforms(to: .spreadsheet) { return .spreadsheet }
        if type.conforms(to: .pdf) || type.conforms(to: .text) || type.conforms(to: .rtf) { return .document }
        if type.conforms(to: .presentation) { return .document }
        return .other
    }
}

/// Whether an iCloud-backed file's content is actually on this Mac.
///
/// With iCloud's storage optimisation, a file can be listed with its real name and
/// size while its content lives only in iCloud (on 2026-09-30, three of the four items
/// in the real inbox). Reading or moving such a file makes the system fetch it first,
/// synchronously — so nothing may do either without checking this.
public enum CloudStatus: String, Sendable, Codable {
    /// Content is here and up to date.
    case current
    /// Content is here but a newer version exists in iCloud.
    case stale
    /// Only a placeholder is here.
    case notDownloaded

    init?(_ status: URLUbiquitousItemDownloadingStatus?) {
        switch status {
        case .current?: self = .current
        case .downloaded?: self = .stale
        case .notDownloaded?: self = .notDownloaded
        default: return nil
        }
    }

    public var isLocal: Bool { self != .notDownloaded }
}

/// An immediate child of a Workspace root folder — the primary entity this
/// app organizes and tags.
///
/// Values here are a *snapshot* of the filesystem at scan time. Anything expensive
/// (recursive size, deep child counts, README text) lives in `ItemProbe` and is
/// computed lazily, because three areas are 56–73 GB.
public struct WorkspaceItem: Identifiable, Hashable, Sendable {

    public let url: URL
    public let name: String
    public let isDirectory: Bool
    public let kind: FileKind
    public let identity: FileIdentity?

    /// Byte size of the file itself. For directories this is *not* recursive — see
    /// `ItemProbe.recursiveSize`.
    public let byteSize: Int64
    public let createdAt: Date?
    /// Modification date of the object itself, straight from the filesystem.
    public let rawModifiedAt: Date?
    /// Best available "when did this really change" date. For directories this is the
    /// newest non-foreign immediate child, because other tools write metadata into
    /// these folders and push their directory mtime to today.
    public let contentModifiedAt: Date?
    /// Number of immediate children, excluding foreign metadata and dotfiles. `nil` for files.
    public let immediateChildCount: Int?
    /// `nil` for anything not stored in iCloud, which is always local.
    public let cloudStatus: CloudStatus?

    /// True when reading or moving the content will not first wait on a download.
    public var isContentLocal: Bool { cloudStatus?.isLocal ?? true }

    public var id: String { identity?.key ?? url.path }

    /// Name without extension, for display in title-led areas such as Ideas.
    public var displayTitle: String {
        isDirectory ? name : url.deletingPathExtension().lastPathComponent
    }

    public var fileExtension: String { url.pathExtension.lowercased() }

    public init(
        url: URL,
        name: String,
        isDirectory: Bool,
        kind: FileKind,
        identity: FileIdentity?,
        byteSize: Int64,
        createdAt: Date?,
        rawModifiedAt: Date?,
        contentModifiedAt: Date?,
        immediateChildCount: Int?,
        cloudStatus: CloudStatus? = nil
    ) {
        self.url = url
        self.name = name
        self.isDirectory = isDirectory
        self.kind = kind
        self.identity = identity
        self.byteSize = byteSize
        self.createdAt = createdAt
        self.rawModifiedAt = rawModifiedAt
        self.contentModifiedAt = contentModifiedAt
        self.immediateChildCount = immediateChildCount
        self.cloudStatus = cloudStatus
    }

    public static func == (lhs: WorkspaceItem, rhs: WorkspaceItem) -> Bool { lhs.id == rhs.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// A named container at the root of `Projects`, rather than a project in its own
/// right. These folders stay ordinary folders on disk; this only gives their existing
/// convention a useful meaning in the browser.
public enum ProjectFolderRole: String, Sendable, CaseIterable {
    case utilities
    case closed
    case collections
    case organizer

    public init?(folderName: String, isDirectory: Bool) {
        guard isDirectory, folderName.hasPrefix("_") else { return nil }
        switch folderName.lowercased() {
        case "_utilities": self = .utilities
        case "_closed": self = .closed
        case "_collections": self = .collections
        default: self = .organizer
        }
    }

    public var title: String {
        switch self {
        case .utilities: return "Utilities"
        case .closed: return "Closed work"
        case .collections: return "Collections"
        case .organizer: return "Project space"
        }
    }

    public var summary: String {
        switch self {
        case .utilities: return "Shared tools and building blocks"
        case .closed: return "Completed, superseded, and abandoned work"
        case .collections: return "Curated bodies of work"
        case .organizer: return "An organizational folder, not a project"
        }
    }

    public var symbolName: String {
        switch self {
        case .utilities: return "wrench.and.screwdriver"
        case .closed: return "archivebox"
        case .collections: return "square.stack.3d.up"
        case .organizer: return "folder.badge.gearshape"
        }
    }
}

public extension WorkspaceItem {
    /// Underscore-prefixed folders are project spaces, not rateable/linkable projects.
    var projectFolderRole: ProjectFolderRole? {
        ProjectFolderRole(folderName: name, isDirectory: isDirectory)
    }
}
