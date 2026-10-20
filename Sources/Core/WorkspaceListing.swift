import Foundation

/// Underscore folders organize files on disk, but do not add a level to browsing.
/// Returned URLs always retain their real filesystem location and identity.
public enum WorkspaceListing {
    public static func children(of directory: URL, keys: [URLResourceKey] = [], showHidden: Bool = false) throws -> [URL] {
        try children(of: directory, keys: keys, showHidden: showHidden, depth: 0)
    }

    private static func children(of directory: URL, keys: [URLResourceKey], showHidden: Bool, depth: Int) throws -> [URL] {
        guard depth < 64 else { throw CocoaError(.fileReadUnknown) }
        let urls = try FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: Array(Set(keys + [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey])), options: [])
        var result: [URL] = []
        for url in urls {
            let name = url.lastPathComponent
            guard !NoiseFilter.isHidden(name: name, showHidden: showHidden) else { continue }
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey])
            if name.hasPrefix("_"), values.isSymbolicLink == true { continue }
            if name.hasPrefix("_"), values.isDirectory == true, values.isPackage != true {
                // Never follow a wrapper symlink into another location.
                guard values.isSymbolicLink != true else { continue }
                result += try children(of: url, keys: keys, showHidden: showHidden, depth: depth + 1)
            } else {
                result.append(url)
            }
        }
        return result.sorted { $0.canonicalPath.localizedStandardCompare($1.canonicalPath) == .orderedAscending }
    }

    /// Whether a real path is a direct *visible* child of an area. Only transparent
    /// containers may occur between the area and the item; ordinary nesting is kept.
    public static func isAreaChild(_ path: String, area: String) -> Bool {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 2, parts.first == area,
              parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.hasPrefix(".")
                  && !NoiseFilter.isForeignMetadata(name: $0) && !NoiseFilter.foreignTopLevelDirectories.contains($0) }) else { return false }
        return parts.dropFirst().dropLast().allSatisfy { $0.hasPrefix("_") }
    }
}
