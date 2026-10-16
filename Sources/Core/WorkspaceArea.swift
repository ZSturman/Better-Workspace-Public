import Foundation

/// The top-level Workspace folders that have a purpose-built implementation.
///
/// This is deliberately *not* the list of areas. Every visible folder directly under
/// the Workspace root is an area — see `WorkspaceFolderDiscovery` — and one this enum
/// has never heard of gets the configurable experience described by
/// `AreaConfiguration`. A case belongs here only when the folder's real contents
/// justified a dedicated view (DESIGN.md §2): a gallery for the image folder, a stream
/// reader for dated logs, the project table. Adding a case is a code change; adding a
/// folder is not.
public enum WorkspaceArea: String, CaseIterable, Codable, Sendable, Identifiable {
    case analytics = "Analytics"
    case assets = "Assets"
    case backups = "Backups"
    case inspiration = "For Inspiration"
    case references = "For Reference"
    case ideas = "Ideas"
    case logs = "Logs"
    case projects = "Projects"
    case review = "Review"
    case socialPosts = "Social Posts"
    case organize = "To Organize"

    public var id: String { rawValue }

    /// Directory name under the workspace root. The folder name is an area's identity,
    /// so a purpose-built view attaches to whichever folder currently carries it.
    public var directoryName: String { rawValue }

    public var displayName: String { rawValue }

    /// The purpose-built area a folder name binds to, if any.
    public init?(folderName: String) {
        self.init(rawValue: folderName)
    }

    public var symbolName: String {
        AreaDefaults.configuration(forFolderNamed: directoryName).symbol ?? "folder"
    }

    public var subtitle: String {
        AreaDefaults.configuration(forFolderNamed: directoryName).subtitle ?? ""
    }
}
