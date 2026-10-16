import Foundation

/// Disposable private paths, never a second copy of portable records. Warm loads read
/// current file contents; a background walk repairs missing, moved and new paths.
public actor WorkItemPathIndex {
    private struct Manifest: Codable {
        var version = 1
        var root: String
        var paths: [String]
    }
    private let file: URL
    public init(file: URL) { self.file = file }

    public func load(under root: URL, service: WorkItemService = WorkItemService()) -> [WorkItem]? {
        guard let data = try? Data(contentsOf: file), data.count <= 8 * 1024 * 1024,
              let manifest = try? JSONDecoder().decode(Manifest.self, from: data),
              manifest.version == 1, manifest.root == root.canonicalPath,
              manifest.paths.count <= 20_000 else { return nil }
        return WorkItemService.indexed(manifest.paths.compactMap { path in
            guard Self.allowed(path, under: root) else { return nil }
            return service.read(at: root.appendingPathComponent(path))
        })
    }

    public func save(_ items: [WorkItem], under root: URL) throws {
        let prefix = root.canonicalPath + "/"
        let paths = items.compactMap { item -> String? in
            guard item.url.canonicalPath.hasPrefix(prefix) else { return nil }
            let path = String(item.url.canonicalPath.dropFirst(prefix.count))
            return Self.allowed(path, under: root) ? path : nil
        }
        let data = try JSONEncoder().encode(Manifest(root: root.canonicalPath, paths: Array(Set(paths)).sorted()))
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file, options: .atomic)
    }

    private static func allowed(_ path: String, under root: URL) -> Bool {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.hasPrefix("/"), path.hasSuffix(WorkItemService.fileSuffix),
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.hasPrefix(".")
                  && !WorkItemService.prunedDirectoryNames.contains(String($0))
                  && !NoiseFilter.isForeignMetadata(name: String($0))
                  && !NoiseFilter.foreignTopLevelDirectories.contains(String($0)) }) else { return false }
        var url = root
        for component in components {
            url.appendPathComponent(String(component))
            if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true { return false }
        }
        return url.canonicalPath.hasPrefix(root.canonicalPath + "/")
    }
}
