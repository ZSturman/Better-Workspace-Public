import Foundation
import Darwin

/// Reads only the declared root, Projects listing and exact previously bound paths.
/// Never searches for a folder, moves an original or infers absence from a failed read.
public enum ProjectFinderReconciliation {
    public static func reconcile(store: ProjectGraphStore, workspace: WorkspaceLocation) throws {
        let root = workspace.root
        try WorkspaceLocalPathChecks.rejectSymlinks(to: root)
        guard let rootID = FileIdentityResolver.identity(of: root) else { return }
        let projects = workspace.url(for: .projects)
        try WorkspaceLocalPathChecks.rejectSymlinks(to: projects)
        guard let projectsID = FileIdentityResolver.identity(of: projects) else { return }
        _ = try FileManager.default.contentsOfDirectory(atPath: projects.path)
        guard let source = try store.read("sources", as: [ProjectGraphSource].self)?.first(where: { $0.kind == .projects }),
              let status = source.property(named: "Status"), source.writable(status.id),
              let type = status.definition["type"].string,
              let idea = status.definition[type]["options"].array.first(where: { $0["name"].display.caseInsensitiveCompare("Idea") == .orderedSame })?["name"].string else { return }
        let rootPrefix = root.canonicalPath + "/", projectsPrefix = projects.canonicalPath + "/"
        for prior in try store.records() where prior.kind == .projects && prior.sourceID == source.id
            && prior.pageID != nil && prior.localProjectID != nil && prior.locallyDeleted != true && !prior.remoteArchived {
            guard let path = prior.localPath, path.hasPrefix(rootPrefix) else { continue }
            let relative = String(path.dropFirst(rootPrefix.count))
            let parts = relative.split(separator: "/")
            guard parts.count >= 2, !parts.contains(where: { NoiseFilter.isHidden(name: String($0), showHidden: false) }),
                  parts.first != "Backups" else { continue }
            let url = URL(fileURLWithPath: path)
            guard (try? WorkspaceLocalPathChecks.rejectSymlinks(to: url)) != nil else { continue }
            var info = stat()
            let result = lstat(url.path, &info)
            let exists = result == 0
            let missing = result != 0 && errno == ENOENT
            guard exists || missing else { continue }
            // Only Projects absence counts; an unavailable other area is not a departure.
            guard path.hasPrefix(projectsPrefix) || exists else { continue }
            let departed = !path.hasPrefix(projectsPrefix) || missing
            guard FileIdentityResolver.identity(of: root) == rootID,
                  FileIdentityResolver.identity(of: projects) == projectsID else { return }
            try store.updateFinderProjectPresence(prior, departed: departed, idea: idea, source: source)
        }
    }
}
