// Adapted from the local Inbox Review core (2026-10-07).
// Independent Better Workspace state; never reads Inbox Review private stores.
import Foundation

public enum WorkspaceInboxReview {}

// Shared with the phone, so both name a folder's decision the same way.
extension WorkspaceInboxReview {
/// Folder intent determines the review decision. Completion reuses the journaled
/// Done operation; organizing must choose a destination instead of completing.
public struct ReviewActions: Sendable {
    public enum PrimaryAction: Sendable, Equatable { case resolve, move }
    public let title: String
    public let primary: PrimaryAction
    public let purpose: String
    public let retireTitle: String
    public var showsDelete: Bool { primary == .move }

    public init(category: String) {
        switch category {
        case "To Study":
            title = "Studied?"; primary = .resolve; purpose = "Learning material"; retireTitle = "Stop studying"
        case "To Watch":
            title = "Watched?"; primary = .resolve; purpose = "Watch queue"; retireTitle = "No longer interested"
        case "To Look Up":
            title = "Looked up?"; primary = .resolve; purpose = "Research queue"; retireTitle = "No longer needed"
        case "To Do":
            title = "Complete?"; primary = .resolve; purpose = "Action queue"; retireTitle = "Drop task"
        case "To Check Out":
            title = "Checked out?"; primary = .resolve; purpose = "Saved links to explore"; retireTitle = "Not interested"
        case "To Read":
            title = "Read?"; primary = .resolve; purpose = "Reading list"; retireTitle = "No longer interested"
        case "To Organize":
            title = "Move to…"; primary = .move; purpose = "Files awaiting a home"; retireTitle = "Set aside"
        default:
            title = "Reviewed?"; primary = .resolve; purpose = "Review queue"; retireTitle = "Set aside"
        }
    }
}
}

#if os(macOS)
import CryptoKit
import Darwin

extension WorkspaceInboxReview {

public struct ReviewConfiguration: Codable, Sendable {
    public static let folderNames = ["To Study", "To Watch", "To Organize", "To Look Up", "To Do", "To Check Out"]
    public var roots: [URL]
    public var archive: URL
    public init(workspace: URL, archive: URL? = nil) {
        let workspace = Paths.physical(workspace)
        roots = Self.folderNames.map { workspace.appendingPathComponent($0, isDirectory: true) }
        self.archive = archive ?? workspace.appendingPathComponent("Reviewed", isDirectory: true)
    }
    public func validate() throws {
        guard !roots.isEmpty, Set(roots.map { Paths.lexical($0).path }).count == roots.count else {
            throw ReviewError.message("Configuration must contain distinct source folders.")
        }
        for root in roots where Paths.contains(root, archive) || Paths.contains(archive, root) {
            throw ReviewError.message("The archive must be outside the source folders.")
        }
    }
}

public enum ReviewError: Error, LocalizedError {
    case message(String)
    public var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}
public enum ItemKind: String, Codable, Sendable { case folder, file, symlink }
public struct ReviewItem: Identifiable, Hashable, Sendable, Codable {
    public let id: String
    public let url: URL
    public let root: URL
    public let kind: ItemKind
    public let created: Date
    public let modified: Date
    public let size: Int64
    public var name: String { url.lastPathComponent }
    public var category: String { root.lastPathComponent }
    public var relativePath: String { String(url.path.dropFirst(root.path.count + 1)) }
}
public struct ReviewRecord: Codable, Sendable {
    public var lastShown: Date?
    public var snoozedUntil: Date?
    public var shownCount: Int = 0
    public var priority: Int?
    public init() {}
}
public struct ReviewState: Codable, Sendable {
    public var version = 1
    public var nextRoot = 0
    public var records: [String: ReviewRecord] = [:]
    public var resolvedCount = 0
    public init() {}
}
public struct Catalog: Sendable {
    public var items: [ReviewItem]
    public var warnings: [String]
}
public enum Outcome: String, Codable, CaseIterable, Sendable { case done = "Done", archive = "Archive", retire = "Retired", move = "Moved", trash = "Trash" }
public struct ContentDocument: Sendable {
    public var source: String
    public var body: String
    public var metadata: [(String, String)]
    public var links: [URL]
    public var warning: String?
    public init(source: String = "", body: String = "", metadata: [(String, String)] = [], links: [URL] = [], warning: String? = nil) {
        self.source = source; self.body = body; self.metadata = metadata; self.links = links; self.warning = warning
    }
}
public enum Paths {
    // Foundation deliberately retains some system aliases (notably /var).
    // Resolve the existing ancestor with POSIX realpath, then append missing tails.
    public static func physical(_ url: URL) -> URL {
        var ancestor = lexical(url)
        var tail: [String] = []
        while true {
            if let pointer = realpath(ancestor.path, nil) {
                defer { free(pointer) }
                var result = URL(fileURLWithPath: String(cString: pointer))
                for part in tail.reversed() { result.appendPathComponent(part) }
                return result
            }
            if ancestor.path == "/" { return lexical(url) }
            tail.append(ancestor.lastPathComponent); ancestor.deleteLastPathComponent()
        }
    }
    public static func lexical(_ url: URL) -> URL {
        var parts: [String] = []
        for part in url.path.split(separator: "/") {
            if part == "." { continue }
            if part == ".." { if !parts.isEmpty { parts.removeLast() }; continue }
            parts.append(String(part))
        }
        return URL(fileURLWithPath: "/" + parts.joined(separator: "/"))
    }
    public static func itemURL(_ url: URL) -> URL {
        let url = lexical(url)
        return physical(url.deletingLastPathComponent()).appendingPathComponent(url.lastPathComponent)
    }
    public static func contains(_ parent: URL, _ child: URL) -> Bool {
        let p = lexical(parent).path, c = lexical(child).path
        return c == p || c.hasPrefix(p + "/")
    }
    public static func excluded(_ url: URL, root: URL) -> Bool {
        let relative = String(url.path.dropFirst(root.path.count + 1))
        let parts = relative.split(separator: "/").map(String.init)
        if parts.contains(where: { $0.hasPrefix(".") || $0.lowercased() == "archive" || NoiseFilter.isForeignMetadata(name: $0) || NoiseFilter.foreignTopLevelDirectories.contains($0) }) { return true }
        let name = url.lastPathComponent.lowercased()
        if [".tmp", ".download", ".crdownload", ".part", ".icloud"].contains(where: name.hasSuffix) { return true }
        return (root.lastPathComponent == "To Do" && relative == "reminders.json")
            || (root.lastPathComponent == "To Study" && relative == "flashcards.json")
    }
}

public enum Filesystem {
    public static func info(_ url: URL, root: URL) throws -> ReviewItem {
        var value = stat()
        guard lstat(url.path, &value) == 0 else { throw ReviewError.message("Cannot inspect \(url.path): \(String(cString: strerror(errno)))") }
        let mode = value.st_mode & S_IFMT
        let kind: ItemKind = mode == S_IFLNK ? .symlink : (mode == S_IFDIR ? .folder : .file)
        // Inode identity survives renames. History contains paths only in operation journals.
        let id = "\(value.st_dev):\(value.st_ino)"
        return ReviewItem(id: id, url: Paths.itemURL(url), root: Paths.itemURL(root), kind: kind,
                          created: Date(timeIntervalSince1970: Double(value.st_birthtimespec.tv_sec) + Double(value.st_birthtimespec.tv_nsec) / 1e9),
                          modified: Date(timeIntervalSince1970: Double(value.st_mtimespec.tv_sec) + Double(value.st_mtimespec.tv_nsec) / 1e9), size: value.st_size)
    }
    public static func exists(_ url: URL) -> Bool { var s = stat(); return lstat(url.path, &s) == 0 }
    public static func scan(_ config: ReviewConfiguration) -> Catalog {
        var items: [ReviewItem] = [], warnings: [String] = []
        for root in config.roots {
            guard exists(root) else { continue }
            do {
                guard try info(root, root: root).kind == .folder else { throw ReviewError.message("Source is not a real folder: \(root.path)") }
                items += try children(root, root: root)
            } catch { warnings.append(error.localizedDescription) }
        }
        return Catalog(items: items, warnings: warnings)
    }
    public static func children(_ folder: URL, root: URL) throws -> [ReviewItem] {
        guard try info(folder, root: root).kind == .folder else { return [] }
        return try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { !Paths.excluded($0, root: root) }.map { try info($0, root: root) }.filter { item in
                guard item.kind != .symlink else { return false }
                let values = try? item.url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey])
                return values?.ubiquitousItemDownloadingStatus == nil || values?.ubiquitousItemDownloadingStatus == .current
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    public static func validateSource(_ item: ReviewItem, configuration: ReviewConfiguration) throws {
        guard configuration.roots.contains(where: { Paths.itemURL($0) == item.root }), item.url != item.root,
              Paths.contains(item.root, item.url), !Paths.excluded(item.url, root: item.root) else {
            throw ReviewError.message("That item is outside the eligible inbox contents.")
        }
        var parent = item.url.deletingLastPathComponent()
        while Paths.contains(item.root, parent) {
            guard try info(parent, root: item.root).kind == .folder else { throw ReviewError.message("An ancestor was replaced or is a symlink. Refresh first.") }
            if parent == item.root { break }
            parent.deleteLastPathComponent()
        }
        let current = try info(item.url, root: item.root)
        guard current.id == item.id, current.modified == item.modified, current.size == item.size, current.kind == item.kind else {
            throw ReviewError.message("The item changed on disk. Refresh before acting.")
        }
    }
    public static func fingerprint(_ url: URL) throws -> String {
        var hash = SHA256()
        func visit(_ path: URL, relative: String) throws {
            try Task.checkCancellation()
            if path != url, Paths.excluded(path, root: url) { throw ReviewError.message("This folder contains protected content. Review its ordinary files individually instead.") }
            let item = try info(path, root: url)
            var attributes = stat()
            guard lstat(path.path, &attributes) == 0 else { throw ReviewError.message("Cannot inspect file attributes.") }
            // Directory allocation size differs across volumes; its entries are hashed below.
            let size = item.kind == .folder ? 0 : item.size
            hash.update(data: Data("\(relative)|\(item.kind.rawValue)|\(size)|\(item.modified.timeIntervalSince1970)|\(attributes.st_mode)|\(attributes.st_uid)|\(attributes.st_gid)\n".utf8))
            let nameCount = listxattr(path.path, nil, 0, XATTR_NOFOLLOW)
            if nameCount < 0 { throw ReviewError.message("Cannot inspect extended attributes: \(path.path)") }
            if nameCount > 0 {
                var names = [CChar](repeating: 0, count: nameCount)
                guard listxattr(path.path, &names, names.count, XATTR_NOFOLLOW) == nameCount else { throw ReviewError.message("Extended attributes changed during preview.") }
                let keys = names.split(separator: 0).map { String(decoding: $0.map { UInt8(bitPattern: $0) }, as: UTF8.self) }.sorted()
                for key in keys {
                    let count = getxattr(path.path, key, nil, 0, 0, XATTR_NOFOLLOW)
                    guard count >= 0 else { throw ReviewError.message("Cannot inspect extended attribute: \(key)") }
                    var bytes = [UInt8](repeating: 0, count: count)
                    guard getxattr(path.path, key, &bytes, count, 0, XATTR_NOFOLLOW) == count else { throw ReviewError.message("Extended attributes changed during preview.") }
                    hash.update(data: Data((key + "\0").utf8)); hash.update(data: Data(bytes))
                }
            }
            switch item.kind {
            case .symlink:
                hash.update(data: Data(try FileManager.default.destinationOfSymbolicLink(atPath: path.path).utf8))
            case .folder:
                for child in try FileManager.default.contentsOfDirectory(at: path, includingPropertiesForKeys: nil).sorted(by: { $0.path < $1.path }) {
                    try visit(child, relative: relative + "/" + child.lastPathComponent)
                }
            case .file:
                guard let stream = InputStream(url: path) else { throw ReviewError.message("Cannot read \(path.path)") }
                stream.open(); defer { stream.close() }
                var bytes = [UInt8](repeating: 0, count: 65536)
                while true {
                    try Task.checkCancellation()
                    let count = stream.read(&bytes, maxLength: bytes.count)
                    if count < 0 { throw stream.streamError ?? ReviewError.message("Read failed: \(path.path)") }
                    if count == 0 { break }
                    hash.update(data: Data(bytes.prefix(count)))
                }
            }
        }
        try visit(url, relative: "")
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    public static func uniqueDestination(_ desired: URL) -> URL {
        if !exists(desired) { return desired }
        let ext = desired.pathExtension
        let stem = ext.isEmpty ? desired.lastPathComponent : desired.deletingPathExtension().lastPathComponent
        var number = 2
        while true {
            let name = ext.isEmpty ? "\(stem) \(number)" : "\(stem) \(number).\(ext)"
            let next = desired.deletingLastPathComponent().appendingPathComponent(name)
            if !exists(next) { return next }; number += 1
        }
    }
    // Darwin's exclusive move refuses an existing target and preserves Finder metadata.
    // Cross-volume moves use copyfile(COPYFILE_ALL), verify bytes, then remove the source.
    public static func move(_ source: URL, to destination: URL) throws {
        guard !exists(destination) else { throw ReviewError.message("Destination already exists: \(destination.path)") }
        if renamex_np(source.path, destination.path, UInt32(RENAME_EXCL)) == 0 { return }
        guard errno == EXDEV else { throw ReviewError.message("Move failed: \(String(cString: strerror(errno)))") }
        let flags = copyfile_flags_t(COPYFILE_ALL | COPYFILE_RECURSIVE | COPYFILE_EXCL | COPYFILE_NOFOLLOW_SRC)
        guard copyfile(source.path, destination.path, nil, flags) == 0 else {
            throw ReviewError.message("Cross-volume copy failed; original retained. Check \(destination.path): \(String(cString: strerror(errno)))")
        }
        let original = try fingerprint(source)
        guard try fingerprint(destination) == original else { throw ReviewError.message("Copy verification failed; original retained. Check \(destination.path).") }
        // Do not delete a concurrently modified original.
        guard try fingerprint(source) == original else { throw ReviewError.message("Source changed while copying; original retained.") }
        try FileManager.default.removeItem(at: source)
    }
    // Replace bytes in-place, retaining inode, creation date, extended attributes, and mode.
    // The prepared journal holds the original bytes before this is called.
    public static func replaceBytes(_ data: Data, at url: URL) throws {
        let handle = try FileHandle(forWritingTo: url); defer { try? handle.close() }
        try handle.seek(toOffset: 0); try handle.write(contentsOf: data); try handle.truncate(atOffset: UInt64(data.count)); try handle.synchronize()
    }
}

public enum ContentParser {
    public static let textExtensions: Set<String> = ["md", "txt", "json", "csv", "tsv", "swift", "lua", "py", "js", "ts", "html", "css", "yaml", "yml", "toml", "log", "sh", "ics", "xml"]
    public static func parse(_ source: String) -> ContentDocument {
        let normalized = source.replacingOccurrences(of: "\r\n", with: "\n")
        var body = source, metadata: [(String, String)] = []
        if normalized.hasPrefix("---\n"), let end = normalized.range(of: "\n---\n", range: normalized.index(normalized.startIndex, offsetBy: 4)..<normalized.endIndex) {
            let header = String(normalized[normalized.index(normalized.startIndex, offsetBy: 4)..<end.lowerBound])
            body = String(normalized[end.upperBound...])
            for line in header.split(separator: "\n") {
                guard let colon = line.firstIndex(of: ":") else { continue }
                let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
                let raw = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                var value = raw
                if let data = raw.data(using: .utf8), let decoded = try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed) as? String { value = decoded }
                else if raw.hasPrefix("'"), raw.hasSuffix("'") { value = String(raw.dropFirst().dropLast()) }
                metadata.append((key, value))
            }
        }
        var links: [URL] = []
        func append(_ raw: String) {
            if let url = URL(string: raw), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil, !links.contains(url) { links.append(url) }
        }
        if let primary = metadata.first(where: { $0.0 == "url" }) { append(primary.1) }
        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
            for match in detector.matches(in: body, range: NSRange(body.startIndex..., in: body)) {
                if let url = match.url { append(url.absoluteString) }
            }
        }
        for (key, value) in metadata where key.hasSuffix("url") && key != "url" { append(value) }
        return ContentDocument(source: source, body: body, metadata: metadata, links: links)
    }
    public static func load(_ item: ReviewItem) throws -> ContentDocument {
        if item.kind == .symlink {
            return ContentDocument(body: "Symbolic link → " + (try FileManager.default.destinationOfSymbolicLink(atPath: item.url.path)))
        }
        guard item.kind == .file else { return ContentDocument() }
        guard item.size <= 32_768 else { return ContentDocument(warning: "Open this file on Mac to preview its full contents.") }
        let ext = item.url.pathExtension.lowercased()
        if ext == "webloc" {
            let data = try Data(contentsOf: item.url)
            let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
            if let raw = plist?["URL"] as? String { return parse(raw) }; return ContentDocument(warning: "This web link has no URL.")
        }
        if ext == "url" {
            let source = try String(contentsOf: item.url, encoding: .utf8)
            let raw = source.components(separatedBy: .newlines).first(where: { $0.uppercased().hasPrefix("URL=") }).map { String($0.dropFirst(4)) } ?? source
            var document = parse(raw); document.source = source; return document
        }
        guard textExtensions.contains(ext) || ext.isEmpty else { return ContentDocument() }
        // Large content is streamed only by its default app. Never silently truncate notes.
        guard item.size <= 8 * 1024 * 1024 else { return ContentDocument(warning: "Text exceeds the 8 MB preview limit. Open the complete file in its default app.") }
        let data = try Data(contentsOf: item.url)
        guard let text = String(data: data, encoding: .utf8) else { return ContentDocument(warning: "This file is not UTF-8 text. Open it in its default app.") }
        return parse(text)
    }
    public static func completedTask(_ data: Data, now: Date) throws -> Data {
        guard let text = String(data: data, encoding: .utf8) else { throw ReviewError.message("Task is not UTF-8.") }
        let newline = text.contains("\r\n") ? "\r\n" : "\n"
        var lines = text.components(separatedBy: newline)
        guard lines.first == "---", let end = lines.dropFirst().firstIndex(of: "---"),
              lines[1..<end].contains(where: { $0 == "better-workspace: 1" }),
              lines[1..<end].contains(where: { $0 == "kind: task" }) else {
            throw ReviewError.message("This .bw.md file is not a supported Better Workspace task. Use Archive instead.")
        }
        let statusIndices = (1..<end).filter { lines[$0].hasPrefix("status:") }
        let completedIndices = (1..<end).filter { lines[$0].hasPrefix("completed:") }
        guard statusIndices.count == 1, completedIndices.count <= 1 else { throw ReviewError.message("Task has missing or ambiguous status metadata. Use Archive instead.") }
        lines[statusIndices[0]] = "status: completed"
        let timestamp = ISO8601DateFormatter().string(from: now)
        if let index = completedIndices.first { lines[index] = "completed: \(timestamp)" }
        else { lines.insert("completed: \(timestamp)", at: end) }
        return Data(lines.joined(separator: newline).utf8)
    }
}

public struct OperationEntry: Codable, Sendable, Identifiable {
    public var id = UUID()
    public var outcome: Outcome
    public var source: URL
    public var destination: URL?
    public var sourceID: String
    public var beforeFingerprint: String
    public var afterFingerprint: String?
    public var originalTask: Data?
    public var completedTask: Data?
    public var status = "prepared"
    public var timestamp = Date()
    public var message: String?
}
public struct EngineSnapshot: Sendable {
    public var catalog: Catalog
    public var state: ReviewState
    public var undoAvailable: Bool
    public var recoveryWarnings: [String]
}
public actor ReviewEngine {
    public let configuration: ReviewConfiguration
    private let stateDirectory: URL
    private var state: ReviewState
    private var journal: [OperationEntry]
    private var busy = false
    private var cachedCatalog: Catalog?
    private var catalogAt = Date.distantPast
    public func invalidateCatalog() { catalogAt = .distantPast }
    private func catalog() -> Catalog {
        if let cachedCatalog, Date().timeIntervalSince(catalogAt) < 30 { return cachedCatalog }
        let fresh = Filesystem.scan(configuration)
        // A failed read retains the last successful queue.
        guard fresh.warnings.isEmpty else { return Catalog(items: cachedCatalog?.items ?? fresh.items, warnings: fresh.warnings) }
        cachedCatalog = fresh; catalogAt = Date(); return fresh
    }
    private let moveEffect: @Sendable (URL, URL) throws -> Void
    private let chooseItem: @Sendable ([ReviewItem]) -> ReviewItem?
    public init(configuration: ReviewConfiguration, stateDirectory: URL,
                chooseItem: @escaping @Sendable ([ReviewItem]) -> ReviewItem? = { $0.randomElement() },
                moveEffect: @escaping @Sendable (URL, URL) throws -> Void = { try Filesystem.move($0, to: $1) }) throws {
        self.moveEffect = moveEffect
        self.chooseItem = chooseItem
        try configuration.validate()
        self.configuration = configuration; self.stateDirectory = stateDirectory
        let fm = FileManager.default
        try fm.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: stateDirectory.path)
        let configURL = stateDirectory.appendingPathComponent("configuration.json")
        if !fm.fileExists(atPath: configURL.path) { try Self.encode(configuration, to: configURL) }
        state = try Self.read(ReviewState.self, at: stateDirectory.appendingPathComponent("state.json")) ?? ReviewState()
        guard state.version == 1 else { throw ReviewError.message("Unsupported state version; preserve state.json and reinstall a compatible app.") }
        journal = try Self.read([OperationEntry].self, at: stateDirectory.appendingPathComponent("operations.json")) ?? []
    }
    public static func loadConfiguration(workspace: URL, stateDirectory: URL) throws -> ReviewConfiguration {
        let config = try read(ReviewConfiguration.self, at: stateDirectory.appendingPathComponent("configuration.json")) ?? ReviewConfiguration(workspace: workspace)
        try config.validate(); return config
    }
    private static func read<T: Decodable>(_ type: T.Type, at url: URL) throws -> T? {
        guard Filesystem.exists(url) else { return nil }
        do { return try JSONDecoder().decode(type, from: Data(contentsOf: url)) }
        catch { throw ReviewError.message("Cannot read \(url.lastPathComponent). It has been preserved: \(error.localizedDescription)") }
    }
    private static func encode<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    private func saveState() throws { try Self.encode(state, to: stateDirectory.appendingPathComponent("state.json")) }
    private func saveJournal() throws { try Self.encode(journal, to: stateDirectory.appendingPathComponent("operations.json")) }
    public func snapshot() -> EngineSnapshot {
        var shownState = state
        shownState.resolvedCount = journal.filter { entry in
            guard entry.status == "committed" else { return false }
            if entry.outcome == .move, let destination = entry.destination,
               configuration.roots.contains(where: { Paths.contains($0, destination) }) { return false }
            return true
        }.count
        return EngineSnapshot(catalog: catalog(), state: shownState,
                              undoAvailable: journal.last(where: { $0.status == "committed" }) != nil,
                              recoveryWarnings: journal.filter { $0.status == "needsAttention" }.map { $0.message ?? "Interrupted operation: \($0.source.path)" })
    }
    public func selectNext(now: Date = Date()) throws -> ReviewItem? {
        let catalog = catalog()
        let count = configuration.roots.count
        let highestPriority = catalog.items.filter { (state.records[$0.id]?.snoozedUntil ?? .distantPast) <= now }
            .map { state.records[$0.id]?.priority ?? 3 }.max()
        for offset in 0..<count {
            let index = (max(0, state.nextRoot) + offset) % count
            let root = configuration.roots[index]
            let candidates = catalog.items.filter { item in
                item.root == root && (state.records[item.id]?.snoozedUntil ?? .distantPast) <= now
                    && (state.records[item.id]?.priority ?? 3) == highestPriority
            }.sorted { $0.url.path < $1.url.path }
            // Randomize ties among least-recently-shown items. New content gets
            // a turn before repeats, while folder rotation stays fair.
            let oldest = candidates.map { state.records[$0.id]?.lastShown ?? .distantPast }.min()
            let pool = candidates.filter { (state.records[$0.id]?.lastShown ?? .distantPast) == oldest }
            if let item = chooseItem(pool), pool.contains(item) {
                state.nextRoot = (index + 1) % count
                try markShown(item, now: now); return item
            }
        }
        return nil
    }
    public func markShown(_ item: ReviewItem, now: Date = Date()) throws {
        var record = state.records[item.id] ?? ReviewRecord()
        record.lastShown = now; record.shownCount += 1
        state.records[item.id] = record; try saveState()
    }
    public func setPriority(_ priority: Int, for item: ReviewItem) throws {
        guard (1...5).contains(priority) else { throw ReviewError.message("Choose a priority from 1 to 5.") }
        try Filesystem.validateSource(item, configuration: configuration)
        var record = state.records[item.id] ?? ReviewRecord()
        record.priority = priority; state.records[item.id] = record; try saveState()
    }
    public func snooze(_ item: ReviewItem, until: Date) throws {
        var record = state.records[item.id] ?? ReviewRecord()
        record.snoozedUntil = until; state.records[item.id] = record; try saveState()
    }
    public func unsnooze(_ item: ReviewItem) throws {
        var record = state.records[item.id] ?? ReviewRecord(); record.snoozedUntil = nil
        state.records[item.id] = record; try saveState()
    }
    public func content(_ item: ReviewItem) throws -> ContentDocument { try ContentParser.load(item) }
    public func children(_ item: ReviewItem) throws -> [ReviewItem] { try Filesystem.children(item.url, root: item.root) }
    public func fingerprint(_ item: ReviewItem) async throws -> String {
        let configuration = configuration
        let work = Task.detached {
            try Filesystem.validateSource(item, configuration: configuration)
            let value = try Filesystem.fingerprint(item.url)
            try Filesystem.validateSource(item, configuration: configuration)
            return value
        }
        return try await withTaskCancellationHandler(operation: { try await work.value }, onCancel: { work.cancel() })
    }
    private func begin() throws {
        guard !busy else { throw ReviewError.message("Another operation is still running.") }
        guard !journal.contains(where: { ["prepared", "undoing", "needsAttention"].contains($0.status) }) else {
            throw ReviewError.message("An interrupted operation needs recovery. Check History and operations.json before moving more files.")
        }
        busy = true
    }
    public func perform(_ item: ReviewItem, outcome: Outcome, expectedFingerprint: String,
                        destinationDirectory: URL? = nil,
                        trash: (@Sendable (URL) async throws -> URL)? = nil, operationID: UUID = UUID()) async throws -> OperationEntry {
        if let prior = journal.first(where: { $0.id == operationID && $0.status == "committed" }) { return prior }
        try begin(); defer { busy = false; invalidateCatalog() }
        try Filesystem.validateSource(item, configuration: configuration)
        guard try Filesystem.fingerprint(item.url) == expectedFingerprint else { throw ReviewError.message("The contents changed since preview. Refresh first.") }
        let desired: URL?
        if outcome == .trash { desired = nil }
        else if outcome == .move {
            guard let directory = destinationDirectory else { throw ReviewError.message("Choose a destination folder.") }
            let resolved = Paths.physical(directory)
            guard !Paths.contains(item.url, resolved), resolved != item.url.deletingLastPathComponent() else { throw ReviewError.message("Choose a different destination outside this item.") }
            guard try Filesystem.info(resolved, root: resolved).kind == .folder else { throw ReviewError.message("Destination is not a folder.") }
            desired = resolved.appendingPathComponent(item.name)
        } else {
            desired = configuration.archive.appendingPathComponent(outcome.rawValue).appendingPathComponent(item.category).appendingPathComponent(item.relativePath)
        }
        if let desired {
            guard !Paths.contains(item.url, desired) else { throw ReviewError.message("Destination is inside the source.") }
            try FileManager.default.createDirectory(at: desired.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        var entry = OperationEntry(outcome: outcome, source: item.url,
                                   destination: desired.map(Filesystem.uniqueDestination), sourceID: item.id, beforeFingerprint: expectedFingerprint)
        if outcome == .done, item.kind == .file, item.name.lowercased().hasSuffix(".bw.md") {
            let original = try Data(contentsOf: item.url)
            entry.originalTask = original; entry.completedTask = try ContentParser.completedTask(original, now: entry.timestamp)
        }
        entry.id = operationID
        journal.append(entry); let index = journal.count - 1; try saveJournal()
        do {
            // Recheck after preparation, before any effect.
            try Filesystem.validateSource(item, configuration: configuration)
            guard try Filesystem.fingerprint(item.url) == expectedFingerprint else { throw ReviewError.message("The contents changed during preparation.") }
            if let completed = entry.completedTask {
                try Filesystem.replaceBytes(completed, at: item.url)
                journal[index].afterFingerprint = try Filesystem.fingerprint(item.url); try saveJournal()
            } else { journal[index].afterFingerprint = expectedFingerprint; try saveJournal() }
            if outcome == .trash {
                guard let trash else { throw ReviewError.message("Trash is unavailable.") }
                journal[index].destination = try await trash(item.url)
            } else if let destination = entry.destination { try moveEffect(item.url, destination) }
            guard let destination = journal[index].destination else { throw ReviewError.message("No resulting destination was reported.") }
            journal[index].afterFingerprint = try Filesystem.fingerprint(destination)
            journal[index].status = "committed"; try saveJournal()
            return journal[index]
        } catch {
            let failure = error
            // The recovery routine handles a moved item, a rewritten task, or an untouched source.
            do { try recoverEntry(index) } catch {
                journal[index].status = "needsAttention"
                journal[index].message = "\(failure.localizedDescription). Recovery: \(error.localizedDescription). Original task bytes are in operations.json."
                try? saveJournal()
            }
            throw failure
        }
    }
    // Called before displaying any actionable UI; no ambiguous file is overwritten.
    public func recover() throws {
        guard !busy else { return }
        for index in journal.indices where journal[index].status == "prepared" || journal[index].status == "undoing" {
            do { try recoverEntry(index) }
            catch {
                journal[index].status = "needsAttention"; journal[index].message = error.localizedDescription
                try saveJournal()
            }
        }
    }
    private func recoverEntry(_ index: Int) throws {
        let entry = journal[index]
        if Filesystem.exists(entry.source) {
            let current = try Filesystem.info(entry.source, root: entry.source)
            let signature = try Filesystem.fingerprint(entry.source)
            if entry.status == "undoing", let original = entry.originalTask, try Data(contentsOf: entry.source) == original {
                journal[index].status = "undone"; try saveJournal(); return
            }
            if entry.status == "undoing", signature == entry.afterFingerprint {
                if let original = entry.originalTask { try Filesystem.replaceBytes(original, at: entry.source) }
                journal[index].status = "undone"; try saveJournal(); return
            }
            if signature == entry.beforeFingerprint {
                if let destination = entry.destination, Filesystem.exists(destination), entry.status != "undoing" {
                    throw ReviewError.message("The original is retained but a destination also exists. Inspect both before continuing: \(destination.path)")
                }
                journal[index].status = entry.status == "undoing" ? "undone" : "failed"; try saveJournal(); return
            }
            if let original = entry.originalTask, let completed = entry.completedTask,
               current.id == entry.sourceID, try Data(contentsOf: entry.source) == completed {
                try Filesystem.replaceBytes(original, at: entry.source)
                journal[index].status = entry.status == "undoing" ? "undone" : "failed"; try saveJournal(); return
            }
            throw ReviewError.message("Interrupted action: source changed; no files overwritten. Inspect \(entry.source.path) and the operation journal.")
        }
        if let destination = entry.destination, Filesystem.exists(destination),
           let expected = entry.afterFingerprint, try Filesystem.fingerprint(destination) == expected {
            try FileManager.default.createDirectory(at: entry.source.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Filesystem.move(destination, to: entry.source)
            if let original = entry.originalTask { try Filesystem.replaceBytes(original, at: entry.source) }
            journal[index].status = entry.status == "undoing" ? "undone" : "failed"; try saveJournal(); return
        }
        throw ReviewError.message("Interrupted action cannot be reconciled safely. Inspect \(entry.source.path), its destination, and operations.json; originals are preserved wherever found.")
    }
    public func undo() throws -> OperationEntry {
        try begin(); defer { busy = false; invalidateCatalog() }
        guard let index = journal.lastIndex(where: { $0.status == "committed" }), let destination = journal[index].destination else { throw ReviewError.message("Nothing to undo.") }
        let entry = journal[index]
        guard !Filesystem.exists(entry.source), let expected = entry.afterFingerprint, try Filesystem.fingerprint(destination) == expected else {
            throw ReviewError.message("Undo refused: the original path is occupied or the moved item changed.")
        }
        // Validate source parents without following a symlink created after the move.
        var parent = entry.source.deletingLastPathComponent()
        while parent.path != "/" {
            if Filesystem.exists(parent), try Filesystem.info(parent, root: parent).kind != .folder { throw ReviewError.message("Undo refused: an original parent is a symlink or file.") }
            parent.deleteLastPathComponent()
        }
        journal[index].status = "undoing"; try saveJournal()
        do {
            try recoverEntry(index)
            if journal[index].status != "undone" { throw ReviewError.message("Undo did not complete.") }
            return journal[index]
        } catch {
            journal[index].status = "needsAttention"; journal[index].message = error.localizedDescription; try? saveJournal(); throw error
        }
    }
    public func history() -> [OperationEntry] { journal.reversed() }
}
}
#endif
