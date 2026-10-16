import Foundation

public struct ProjectMediaResolution: Sendable {
    public let url: URL?
    public let staleLocalPath: String?
    public let isPreview: Bool
    public let expiresAt: Date?
    public init(url: URL?, staleLocalPath: String?, isPreview: Bool, expiresAt: Date?) {
        self.url = url; self.staleLocalPath = staleLocalPath; self.isPreview = isPreview; self.expiresAt = expiresAt
    }
}
public enum ProjectMediaResolver {
    /// Remove expiring authorization while retaining content-selecting query values.
    public static func cacheIdentity(for url: URL) -> String {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url.absoluteString }
        let ephemeral: Set<String> = ["signature", "expires", "awsaccesskeyid", "policy", "key-pair-id"]
        if let items = parts.queryItems {
            let stable = items.filter { !ephemeral.contains($0.name.lowercased()) && !$0.name.lowercased().hasPrefix("x-amz-") }
            parts.queryItems = stable.isEmpty ? nil : stable
        }
        parts.fragment = nil
        return parts.string ?? url.absoluteString
    }
    /// Bounded explicit-path resolution; no directory crawl or filename search.
    public static func resolve(_ asset: ProjectGraphRecord, source: ProjectGraphSource,
                               workspaceRoot: URL, projectRoots: [String: URL], relatedProjectRoots: [URL] = [], now: Date = Date(), allowExpiredPreview: Bool = false) -> ProjectMediaResolution {
        let rawPath = asset.value("relative path", source: source).display
        let storage = asset.value("storage", source: source).display.lowercased()
        let owner = asset.value("storage project", source: source)["relation"].array.first?["id"].string
        let root = storage == "project" ? owner.flatMap { projectRoots[$0.replacingOccurrences(of: "-", with: "").lowercased()] } : workspaceRoot
        if !rawPath.isEmpty, let root {
            let path = rawPath.removingPercentEncoding ?? rawPath
            let candidates = [path, path.trimmingCharacters(in: CharacterSet(charactersIn: "'‘’\"“”"))]
            for path in candidates {
                let url: URL
                if path.hasPrefix("file://"), let parsed = URL(string: path) { url = parsed }
                else if path.hasPrefix("/") { url = URL(fileURLWithPath: path) }
                else { url = root.appendingPathComponent(path) }
                let canonical = url.canonicalPath, canonicalRoot = root.canonicalPath
                let resolved = url.resolvingSymlinksInPath().canonicalPath, resolvedRoot = root.resolvingSymlinksInPath().canonicalPath
                guard canonical == canonicalRoot || canonical.hasPrefix(canonicalRoot + "/"),
                      resolved == resolvedRoot || resolved.hasPrefix(resolvedRoot + "/"),
                      FileManager.default.fileExists(atPath: canonical) else { continue }
                return .init(url: URL(fileURLWithPath: canonical), staleLocalPath: nil, isPreview: false, expiresAt: nil)
            }
        }
        // Older Assets records predate the explicit storage fields and describe a
        // path beneath a former Workspace layout. Resolve only inside projects
        // named by their relationships; never search by filename across the disk.
        if !rawPath.isEmpty, storage.isEmpty || storage == "local" {
            let relatedIDs = ["storage project", "projects", "project thumbnail", "project banner", "project poster", "project icon", "project hero"]
                .flatMap { asset.value($0, source: source)["relation"].array.compactMap { $0["id"].string } }
            let roots = relatedProjectRoots + relatedIDs.compactMap { projectRoots[ProjectGraph.normalizedID($0)] }
            let path = (rawPath.removingPercentEncoding ?? rawPath).trimmingCharacters(in: CharacterSet(charactersIn: "'‘’\"“”"))
            let components = path.split(separator: "/").map(String.init)
            var matches: Set<String> = []
            func consider(_ candidate: URL, under root: URL) {
                var directory: ObjCBool = false
                if candidate.canonicalPath.hasPrefix(root.canonicalPath + "/"),
                   candidate.resolvingSymlinksInPath().canonicalPath.hasPrefix(root.resolvingSymlinksInPath().canonicalPath + "/"),
                   FileManager.default.fileExists(atPath: candidate.path, isDirectory: &directory), !directory.boolValue {
                    matches.insert(candidate.canonicalPath)
                }
            }
            for root in roots {
                let relative: String
                if let index = components.lastIndex(of: root.lastPathComponent), index + 1 < components.count {
                    relative = components.dropFirst(index + 1).joined(separator: "/")
                } else if !path.hasPrefix("/") && !path.hasPrefix("file:") { relative = path }
                else { continue }
                consider(root.appendingPathComponent(relative), under: root)
            }
            if matches.count == 1, let path = matches.first {
                return .init(url: URL(fileURLWithPath: path), staleLocalPath: nil, isPreview: false, expiresAt: nil)
            }
            // An explicitly linked current folder takes precedence over an old
            // category-tree copy. Conflicting linked folders still fail closed.
            if matches.isEmpty, !path.hasPrefix("/"), !path.hasPrefix("file:") {
                let projectsRoot = workspaceRoot.appendingPathComponent("Projects")
                var compatibility: [(URL, URL)] = [(projectsRoot.appendingPathComponent(path), projectsRoot)]
                if let category = components.first, ["Creative", "Technology", "Expository"].contains(category) {
                    compatibility.append((projectsRoot.appendingPathComponent(components.dropFirst().joined(separator: "/")), projectsRoot))
                }
                if components.first == "Assets" {
                    let mediaRoot = workspaceRoot.appendingPathComponent("Assets/Media")
                    compatibility.append((mediaRoot.appendingPathComponent(components.dropFirst().joined(separator: "/")), mediaRoot))
                }
                for (candidate, root) in compatibility {
                    consider(candidate, under: root)
                    if let path = matches.first { return .init(url: URL(fileURLWithPath: path), staleLocalPath: nil, isPreview: false, expiresAt: nil) }
                }
            }
        }
        for file in asset.value("preview", source: source)["files"].array {
            let type = file["type"].string ?? "file"
            if let raw = file[type]["url"].string, let url = URL(string: raw) {
                let expiry = file[type]["expiry_time"].string.flatMap { raw -> Date? in
                    let formatter = ISO8601DateFormatter()
                    if let date = formatter.date(from: raw) { return date }
                    formatter.formatOptions.insert(.withFractionalSeconds)
                    return formatter.date(from: raw)
                }
                if !allowExpiredPreview && expiry.map({ $0 <= now }) == true { continue }
                return .init(url: url, staleLocalPath: rawPath.isEmpty ? nil : rawPath, isPreview: true, expiresAt: expiry)
            }
        }
        for name in ["url", "userDefined:url"] {
            if let url = URL(string: asset.value(name, source: source).display), ["https", "http"].contains(url.scheme ?? "") {
                return .init(url: url, staleLocalPath: rawPath.isEmpty ? nil : rawPath, isPreview: true, expiresAt: nil)
            }
        }
        return .init(url: nil, staleLocalPath: rawPath.isEmpty ? nil : rawPath, isPreview: false, expiresAt: nil)
    }
}

public enum ProjectGraph {
    public static func normalizedID(_ id: String) -> String { id.lowercased().replacingOccurrences(of: "-", with: "") }
    public static func isCompleted(_ record: ProjectGraphRecord, source: ProjectGraphSource) -> Bool {
        if ["done", "complete", "completed", "archived"].contains(record.value("Status", source: source).display.lowercased()) { return true }
        if record.value("complete", source: source)["checkbox"].bool { return true }
        return record.kind == .milestones && !record.value("tasks", source: source)["relation"].array.isEmpty && record.value("all tasks complete?", source: source)["formula"]["boolean"].bool
    }
    public static func related(to pageID: String, in records: [ProjectGraphRecord]) -> [ProjectGraphRecord] {
        let target = normalizedID(pageID)
        let project = records.first { normalizedID($0.pageID ?? $0.id) == target }
        var selected = Set(records.filter { $0.relatedPageIDs.contains(target) }.map(\.id))
        selected.formUnion(records.filter { project?.relatedPageIDs.contains(normalizedID($0.pageID ?? $0.id)) == true }.map(\.id))
        // Collections attach both their items and their resources, including inverse links.
        for _ in 0..<3 {
            let containers = records.filter { selected.contains($0.id) && [.collections, .assets, .versions, .features, .milestones].contains($0.kind) }
            let outgoing = Set(containers.flatMap { $0.relatedPageIDs })
            let containerPages = Set(containers.map { normalizedID($0.pageID ?? $0.id) })
            selected.formUnion(records.filter { record in
                record.kind != .projects && (outgoing.contains(normalizedID(record.pageID ?? record.id)) || !record.relatedPageIDs.isDisjoint(with: containerPages))
            }.map(\.id))
        }
        return records.filter { selected.contains($0.id) && $0.pageID.map(normalizedID) != target }
    }
}

/// Build relationship adjacency once per snapshot rather than traversing thousands of
/// property envelopes for every visible cell or capability update.
public struct ProjectGraphIndex: Sendable {
    private let records: [String: ProjectGraphRecord]
    private let pageToRecord: [String: String]
    private let outgoing: [String: Set<String>]
    private let incoming: [String: Set<String>]
    public init(records: [ProjectGraphRecord], includingIncoming: Bool = false, readingIncoming: Bool = false) {
        let accepted = records.filter {
            if readingIncoming { return !$0.remoteArchived && !($0.acknowledgedArchived ?? false) }
            return includingIncoming || (!$0.local.isEmpty && !($0.acknowledgedArchived ?? false))
        }
        self.records = Dictionary(uniqueKeysWithValues: accepted.map { ($0.id, $0) })
        pageToRecord = Dictionary(accepted.map { (ProjectGraph.normalizedID($0.pageID ?? $0.id), $0.id) }, uniquingKeysWith: { first, _ in first })
        var forward: [String: Set<String>] = [:], reverse: [String: Set<String>] = [:]
        for record in accepted {
            let remote = includingIncoming ? Set(record.remote.values.filter { $0["type"].string == "relation" }.flatMap { $0["relation"].array.compactMap { $0["id"].string.map(ProjectGraph.normalizedID) } }) : []
            // Read-only media may display incoming records without accepting them.
            // Explicit local choices (including an empty relation) always win.
            let reading = readingIncoming ? Set(record.remote.merging(record.local) { _, local in local }.values
                .filter { $0["type"].string == "relation" }
                .flatMap { $0["relation"].array.compactMap { $0["id"].string.map(ProjectGraph.normalizedID) } }) : record.relatedPageIDs
            let references = reading.union(remote)
            forward[record.id] = references
            for page in references { reverse[page, default: []].insert(record.id) }
        }
        outgoing = forward; incoming = reverse
    }
    public func related(to project: ProjectGraphRecord) -> [ProjectGraphRecord] {
        let page = ProjectGraph.normalizedID(project.pageID ?? project.id)
        var selected = incoming[page] ?? []
        selected.formUnion((outgoing[project.id] ?? []).compactMap { pageToRecord[$0] })
        var expanded: Set<String> = []
        while true {
            let containers = selected.subtracting(expanded).filter { id in records[id].map { [.collections, .assets, .versions, .features, .milestones, .tasks].contains($0.kind) } ?? false }
            if containers.isEmpty { break }
            for id in containers {
                expanded.insert(id)
                let linked = (outgoing[id] ?? []).compactMap { pageToRecord[$0] }
                let reverse = incoming[ProjectGraph.normalizedID(records[id]?.pageID ?? id)] ?? []
                selected.formUnion((Set(linked).union(reverse)).filter { records[$0]?.kind != .projects || records[id]?.kind == .collections })
            }
        }
        selected.remove(project.id)
        return selected.compactMap { records[$0] }.sorted { $0.id < $1.id }
    }
}
