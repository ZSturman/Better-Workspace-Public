import Foundation

/// An explicit deletion of one displayed item. Never deletes area roots, follows
/// symlinks, crawls directories, or permanently unlinks user content.
public enum WorkspaceTrash {
    public static func resolve(_ path: String, workspace: WorkspaceLocation) throws -> URL {
        guard MobileWorkspacePath.normalizedRelative(path) == path,
              path.split(separator: "/").count >= 2 else {
            throw MobilePlanningFiles.Error.invalid("Workspace and area folders cannot be deleted here.")
        }
        var root = workspace.root
        root.removeAllCachedResourceValues()
        guard try root.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
            throw MobilePlanningFiles.Error.invalid("The Workspace is unavailable. Reconnect it before deleting items.")
        }
        return try MobilePlanningFiles.resolve(path, workspace: workspace)
    }

    @discardableResult
    public static func move(path: String, workspace: WorkspaceLocation, isDirectory: Bool,
                            modifiedAt: Date?, into folder: URL? = nil) throws -> URL? {
        var url = try resolve(path, workspace: workspace)
        url.removeAllCachedResourceValues()
        let values: URLResourceValues
        do { values = try url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey, .contentModificationDateKey]) }
        catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
            return nil // A retried command after a lost receipt is already done.
        }
        let displayedAsDirectory = values.isDirectory == true && values.isPackage != true
        guard let modifiedAt, displayedAsDirectory == isDirectory,
              values.contentModificationDate == modifiedAt else { throw MobilePlanningFiles.Error.conflict }
        if let folder {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let destination = folder.appendingPathComponent(UUID().uuidString + "-" + url.lastPathComponent)
            try FileManager.default.moveItem(at: url, to: destination)
            return destination
        }
        var result: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &result)
        return result as URL?
    }
}
