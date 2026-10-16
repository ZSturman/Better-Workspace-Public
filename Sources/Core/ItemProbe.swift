import Foundation

/// What kind of working directory a Projects item is.
///
/// Derived from the real survey: of 385 projects, 22 are Xcode, 3 SwiftPM, 18 Node,
/// 40 Python — and 174 are prose/documentation only. That last number is why "Notes"
/// is a first-class kind rather than a fallback.
public enum ProjectKind: String, Sendable, CaseIterable {
    case xcode = "Xcode"
    case swiftPackage = "Swift Package"
    case node = "Node"
    case python = "Python"
    case web = "Web"
    case notes = "Notes"
    case media = "Media"
    case empty = "Empty"
    case folder = "Folder"

    public var symbolName: String {
        switch self {
        case .xcode: return "swift"
        case .swiftPackage: return "shippingbox"
        case .node: return "hexagon"
        case .python: return "chevron.left.forwardslash.chevron.right"
        case .web: return "globe"
        case .notes: return "doc.richtext"
        case .media: return "photo.stack"
        case .empty: return "circle.dotted"
        case .folder: return "folder"
        }
    }
}

/// Expensive, per-item detail computed on demand — never during a directory listing.
public struct ItemDetail: Sendable {
    public var projectKind: ProjectKind = .folder
    public var isGitRepository: Bool = false
    public var gitBranch: String?
    public var readmeURL: URL?
    public var readmeExcerpt: String?
    public var immediateNames: [String] = []
    public var kindBreakdown: [FileKind: Int] = [:]
    public var recursiveFileCount: Int?
    public var recursiveByteSize: Int64?
    public var representativeImage: URL?
}

public actor ItemProbe {

    public static let shared = ItemProbe()
    private let fm = FileManager.default
    private var cache: [String: ItemDetail] = [:]

    public init() {}

    public func detail(for item: WorkspaceItem, deep: Bool = false) -> ItemDetail {
        let key = item.url.path + (deep ? "#deep" : "")
        if let cached = cache[key] { return cached }

        var detail = ItemDetail()
        guard item.isDirectory else {
            detail.projectKind = .folder
            cache[key] = detail
            return detail
        }

        let entries = (try? fm.contentsOfDirectory(at: item.url, includingPropertiesForKeys: [.isDirectoryKey], options: []))
            ?? []
        let visible = entries.filter { NoiseFilter.isHidden(name: $0.lastPathComponent, showHidden: false) == false }
        detail.immediateNames = visible
            .map(\.lastPathComponent)
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }

        let allNames = Set(entries.map(\.lastPathComponent))
        detail.isGitRepository = allNames.contains(".git")
        if detail.isGitRepository { detail.gitBranch = readGitBranch(at: item.url) }

        var breakdown: [FileKind: Int] = [:]
        for e in visible {
            let isDir = (try? e.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            let k = FileKind.classify(url: e, isDirectory: isDir)
            breakdown[k, default: 0] += 1
        }
        detail.kindBreakdown = breakdown
        detail.projectKind = classifyProject(names: allNames, visible: visible, breakdown: breakdown)

        if let readme = visible.first(where: { $0.lastPathComponent.lowercased().hasPrefix("readme") })
            ?? visible.first(where: { ["md", "markdown"].contains($0.pathExtension.lowercased()) }) {
            detail.readmeURL = readme
            detail.readmeExcerpt = readExcerpt(at: readme)
        }

        cache[key] = detail
        return detail
    }

    /// Second pass for the surfaces that genuinely need recursive numbers
    /// (Review cards, Assets buckets, Backups manifests).
    public func deepDetail(for item: WorkspaceItem, fs: FilesystemService) async -> ItemDetail {
        var detail = detail(for: item)
        let key = item.url.path + "#deep"
        if let cached = cache[key], cached.recursiveFileCount != nil { return cached }
        detail.recursiveFileCount = await fs.recursiveFileCount(of: item.url)
        detail.recursiveByteSize = await fs.recursiveSize(of: item.url)
        detail.representativeImage = await fs.representativeImage(in: item.url)
        cache[key] = detail
        return detail
    }

    public func invalidate() { cache.removeAll() }

    /// Drops only what a change could have made stale: entries for a changed path and
    /// for every folder above it (a recursive count or size includes it). Wiping the
    /// whole cache on every event meant a line appended to a log re-walked every
    /// project the next time one was inspected.
    public func invalidate(affectedBy changed: [String]) {
        let changed = changed.map { URL(fileURLWithPath: $0).canonicalPath }
        for key in cache.keys {
            let path = key.hasSuffix("#deep") ? String(key.dropLast(5)) : key
            if CacheInvalidation.isAffected(path, by: changed) { cache.removeValue(forKey: key) }
        }
    }
    public func invalidate(path: String) {
        cache.removeValue(forKey: path)
        cache.removeValue(forKey: path + "#deep")
    }

    // MARK: - Private

    private func classifyProject(names: Set<String>, visible: [URL], breakdown: [FileKind: Int]) -> ProjectKind {
        if visible.contains(where: { $0.pathExtension == "xcodeproj" || $0.pathExtension == "xcworkspace" }) {
            return .xcode
        }
        if names.contains("Package.swift") { return .swiftPackage }
        if names.contains("package.json") { return .node }
        if names.contains("requirements.txt") || names.contains("pyproject.toml") || names.contains("setup.py") {
            return .python
        }
        if visible.contains(where: { $0.pathExtension.lowercased() == "py" }) { return .python }
        if names.contains("index.html") { return .web }
        if visible.isEmpty { return .empty }

        let total = breakdown.values.reduce(0, +)
        let docs = (breakdown[.markdown] ?? 0) + (breakdown[.document] ?? 0)
        let media = (breakdown[.image] ?? 0) + (breakdown[.video] ?? 0)
        if total > 0, Double(media) / Double(total) >= 0.6 { return .media }
        if docs > 0, breakdown[.code] == nil, (breakdown[.folder] ?? 0) <= docs { return .notes }
        return .folder
    }

    private func readGitBranch(at repo: URL) -> String? {
        let head = repo.appendingPathComponent(".git/HEAD")
        guard let text = try? String(contentsOf: head, encoding: .utf8) else { return nil }
        let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if line.hasPrefix("ref: refs/heads/") {
            return String(line.dropFirst("ref: refs/heads/".count))
        }
        return line.isEmpty ? nil : String(line.prefix(7))
    }

    private func readExcerpt(at url: URL, maxBytes: Int = 64 * 1024) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: maxBytes) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}
