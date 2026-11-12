import Foundation

/// A transient, private review of missing originals. Capturing it never writes or
/// scans directories. An unchanged path is insufficient: retain root/parent identity
/// and the exact app record, and recheck absence before either repair or forgetting.
public struct WorkspaceMissingWorkReview: Sendable {
    public struct Entry: Sendable {
        public let item: WorkItem
        public let relativePath: String
        public let parentIdentity: FileIdentity?
        public let parentCreatedAt: Date?
        public var key: String { item.id + "\0" + item.url.canonicalPath }
    }
    public let root: URL
    public let rootIdentity: FileIdentity
    public let rootCreatedAt: Date?
    public let entries: [Entry]
    public let graphRecords: [ProjectGraphRecord]
    public var keys: Set<String> { Set(entries.map(\.key)) }

    public static func capture(_ items: [WorkItem], graphRecords: [ProjectGraphRecord], workspace: WorkspaceLocation) throws -> Self {
        try WorkspaceLocalPathChecks.rejectSymlinks(to: workspace.root)
        guard let identity = FileIdentityResolver.identity(of: workspace.root),
              (try workspace.root.resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true else { throw WorkspaceReplicaError.changed }
        let entries = try items.map { item -> Entry in
            guard let path = MobileWorkspaceProjection.relativePath(of: item.url, workspace: workspace),
                  path.split(separator: "/").count >= 2, item.url.lastPathComponent.hasSuffix(WorkItemService.fileSuffix) else { throw WorkspaceReplicaError.changed }
            let url = try MobilePlanningFiles.resolve(path, workspace: workspace)
            try WorkspaceLocalPathChecks.rejectSymlinks(to: url)
            try requireMissing(url)
            let parent = url.deletingLastPathComponent()
            let parentID = FileIdentityResolver.identity(of: parent)
            let created: Date?
            if parentID != nil {
                let values = try parent.resourceValues(forKeys: [.isDirectoryKey, .creationDateKey])
                guard values.isDirectory == true else { throw WorkspaceReplicaError.changed }
                created = values.creationDate
            } else { created = nil }
            return .init(item: item, relativePath: path, parentIdentity: parentID, parentCreatedAt: created)
        }
        guard Set(entries.map(\.key)).count == entries.count else { throw WorkspaceReplicaError.changed }
        let owned = graphRecords.filter { record in
            items.contains { $0.id == record.id && $0.url.canonicalPath == record.localPath && record.kind.rawValue == $0.kind.rawValue + "s" }
        }
        return .init(root: workspace.root, rootIdentity: identity,
                     rootCreatedAt: try workspace.root.resourceValues(forKeys: [.creationDateKey]).creationDate,
                     entries: entries, graphRecords: owned)
    }

    public func validate(_ entry: Entry, current: WorkItem?, workspace: WorkspaceLocation, restoring: Bool = false) throws {
        guard current == entry.item, root.canonicalPath == workspace.root.canonicalPath else { throw WorkspaceReplicaError.changed }
        try WorkspaceLocalPathChecks.rejectSymlinks(to: root)
        var liveRoot = root; liveRoot.removeAllCachedResourceValues()
        guard FileIdentityResolver.identity(of: liveRoot) == rootIdentity,
              try liveRoot.resourceValues(forKeys: [.creationDateKey]).creationDate == rootCreatedAt else { throw WorkspaceReplicaError.changed }
        let url = try MobilePlanningFiles.resolve(entry.relativePath, workspace: workspace)
        try WorkspaceLocalPathChecks.rejectSymlinks(to: url)
        let parent = url.deletingLastPathComponent()
        guard FileIdentityResolver.identity(of: parent) == entry.parentIdentity else { throw WorkspaceReplicaError.changed }
        if entry.parentIdentity != nil {
            guard try parent.resourceValues(forKeys: [.creationDateKey]).creationDate == entry.parentCreatedAt else { throw WorkspaceReplicaError.changed }
        } else if restoring {
            throw WorkspaceReplicaError.invalid("Restore this item's parent folder in Finder first, then review its files again.")
        }
        try Self.requireMissing(url)
    }

    public func restore(_ entry: Entry, current: WorkItem?, workspace: WorkspaceLocation, service: WorkItemService = WorkItemService()) throws -> WorkItem {
        try validate(entry, current: current, workspace: workspace, restoring: true)
        // Reuse the fsynced, exclusive creator. Never manufacture parent directories
        // or overwrite a file that appeared after the absence check.
        return try service.createAtReviewedURL(entry.item)
    }

    private static func requireMissing(_ url: URL) throws {
        var info = stat()
        guard lstat(url.path, &info) != 0, errno == ENOENT else { throw WorkspaceReplicaError.changed }
    }
}
