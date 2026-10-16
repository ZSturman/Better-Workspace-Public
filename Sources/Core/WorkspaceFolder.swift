import Foundation

/// One area: a visible folder directly under the Workspace root, as Better Workspace
/// currently presents it.
///
/// The folder name is the identity. `purposeBuilt` is set when this app has a dedicated
/// implementation for that name; `settings` is the resolved configuration every view
/// reads, whichever kind of area it is.
public struct WorkspaceFolder: Identifiable, Hashable, Sendable {
    public let url: URL
    public let name: String
    public let identity: String?
    public let purposeBuilt: WorkspaceArea?
    /// Personal settings only, before defaults — what the configuration sheet edits.
    public let personal: AreaConfiguration
    public let settings: AreaSettings

    public var id: String { name }
    /// True when someone has changed anything about this area.
    public var isCustomized: Bool { personal.isEmpty == false }
    /// True when neither this app nor its user has said anything about the folder: a
    /// folder made in Finder and not yet looked at.
    public var isUnfamiliar: Bool {
        purposeBuilt == nil && isCustomized == false && AreaDefaults.configuration(forFolderNamed: name).isEmpty
    }

    public init(url: URL, name: String, identity: String?, personal: AreaConfiguration) {
        self.url = url
        self.name = name
        self.identity = identity
        let purposeBuilt = WorkspaceArea(folderName: name)
        self.purposeBuilt = purposeBuilt
        self.personal = personal
        self.settings = AreaSettings(
            resolving: personal.layered(over: AreaDefaults.configuration(forFolderNamed: name)),
            purposeBuilt: purposeBuilt
        )
    }

    public var displayName: String { name }
}

public struct WorkspaceFolderDiscovery: Sendable {
    public init() {}

    /// Whether a root-level name could be an area at all. Hidden entries and other
    /// tools' metadata never are.
    public static func couldBeArea(_ name: String) -> Bool {
        name.hasPrefix(".") == false
            && NoiseFilter.isForeignMetadata(name: name) == false
            && NoiseFilter.foreignTopLevelDirectories.contains(name) == false
    }

    /// Immediate child directories only. Finder-created folders appear here on the next
    /// FSEvent refresh with no code change; a folder removed in Finder simply stops
    /// appearing, and its settings wait in case it returns.
    ///
    /// `nil` means the root could not be read — not that it is empty. Treating the two
    /// alike would drop every area from the sidebar and the phone on a transient error.
    public func folders(in workspace: WorkspaceLocation, store: AreaConfigurationStore) -> [WorkspaceFolder]? {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: workspace.root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        ) else { return nil }
        let found: [(url: URL, name: String, identity: String?)] = urls.compactMap { url in
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                  Self.couldBeArea(url.lastPathComponent)
            else { return nil }
            return (url.canonical, url.lastPathComponent, FileIdentityResolver.identity(of: url)?.key)
        }
        store.reconcile(discovered: found.map { ($0.name, $0.identity) })
        return found.map { folder in
            WorkspaceFolder(url: folder.url, name: folder.name, identity: folder.identity,
                            personal: store.entry(forFolderNamed: folder.name)?.configuration ?? AreaConfiguration())
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

/// Where work of a given kind is filed when no one has pointed at a folder: the phone
/// asking for a capture to become a task, or a Notion import.
///
/// Answered from area settings rather than folder names, so repurposing a folder as a
/// task queue — or renaming `To Do` — moves the routing with it.
public enum WorkQueueRouting {
    public static func folder(for kind: WorkItemKind, among folders: [WorkspaceFolder]) -> WorkspaceFolder? {
        let queues = folders.filter { $0.settings.layout == .workQueue && $0.settings.workItemKind == kind }
        return queues.min { lhs, rhs in
            // A queue offered first for ingest is the one someone files into most; then
            // the folder the defaults already route this kind to; then name order.
            let left = rank(lhs, kind), right = rank(rhs, kind)
            if left != right { return left < right }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    private static func rank(_ folder: WorkspaceFolder, _ kind: WorkItemKind) -> Int {
        if folder.settings.ingest == .primary { return 0 }
        if AreaDefaults.configuration(forFolderNamed: folder.name).workItemKind == kind { return 1 }
        return 2
    }
}
