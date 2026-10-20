import Foundation

public struct MobileDownloadFile: Codable, Sendable {
    public var path: String
    public var data: Data
    public init(path: String, data: Data) { self.path = path; self.data = data }
}

/// A bounded binary property list transferred as one private CloudKit asset. It is
/// separate from the lightweight index; ordinary refresh never reads original files.
public struct MobileDownloadBundle: Codable, Sendable {
    public var version = 1
    public var path: String
    public var title: String
    public var generatedAt: Date
    public var directories: [String]
    public var files: [MobileDownloadFile]
    public static let maximumBytes = 50 * 1024 * 1024
    public static let maximumFiles = 500
    public static let maximumArchiveBytes = maximumBytes + 2 * 1024 * 1024

    public init(path: String, title: String, generatedAt: Date = Date(), directories: [String] = [], files: [MobileDownloadFile]) {
        self.path = path; self.title = title; self.generatedAt = generatedAt; self.directories = directories; self.files = files
    }
    public func validate() throws {
        guard version == 1, Self.safePath(path), title.utf8.count <= 512,
              files.count <= Self.maximumFiles, directories.count <= 2000,
              files.reduce(0, { $0 + $1.data.count }) <= Self.maximumBytes,
              Set(files.map(\.path)).count == files.count,
              Set(directories).count == directories.count,
              Set(files.map(\.path)).isDisjoint(with: Set(directories)),
              files.allSatisfy({ Self.safePath($0.path) }), directories.allSatisfy(Self.safePath) else {
            throw MobilePlanningFiles.Error.invalid("This download is invalid or exceeds 500 files / 50 MB. Choose a smaller folder.")
        }
    }
    public static func safePath(_ path: String) -> Bool {
        !path.contains("\0") && MobileWorkspacePath.normalizedRelative(path) == path && path.utf8.count <= 4096
            && !path.split(separator: "/").contains { $0.hasPrefix(".") || NoiseFilter.isForeignMetadata(name: String($0)) || NoiseFilter.foreignTopLevelDirectories.contains(String($0)) || WorkItemService.prunedDirectoryNames.contains(String($0)) }
    }

    /// Called off the main actor only after an explicit download request. Traversal
    /// prunes metadata, dependency/build folders and symlinks before reading contents.
    public static func prepare(_ entry: MobileWorkspaceEntry, workspace: WorkspaceLocation) throws -> Self {
        let root = try MobilePlanningFiles.resolve(entry.path, workspace: workspace)
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey, .contentModificationDateKey, .isPackageKey, .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey]
        let initial = try root.resourceValues(forKeys: keys)
        if !entry.isDirectory, let expected = entry.modifiedAt, let actual = initial.contentModificationDate,
           abs(expected.timeIntervalSince(actual)) >= 0.001 { throw MobilePlanningFiles.Error.conflict }
        guard initial.isDirectory == entry.isDirectory || (initial.isPackage == true && !entry.isDirectory) else { throw MobilePlanningFiles.Error.conflict }
        var bundle = Self(path: entry.path, title: entry.name, files: [])
        var total = 0, visited = 0
        func visit(_ url: URL, relative: String, depth: Int) throws {
            visited += 1
            guard depth <= 32, visited <= 5000 else { throw MobilePlanningFiles.Error.invalid("Choose a smaller folder for offline access.") }
            guard Self.safePath(relative) else { return }
            let safe = try MobilePlanningFiles.resolve(entry.path + (url == root ? "" : "/" + relative), workspace: workspace)
            let values = try safe.resourceValues(forKeys: keys)
            guard values.isSymbolicLink != true else { return }
            if values.isDirectory == true {
                if url != root { bundle.directories.append(relative) }
                let children = try FileManager.default.contentsOfDirectory(at: safe, includingPropertiesForKeys: Array(keys))
                for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                    let name = child.lastPathComponent
                    guard !NoiseFilter.isHidden(name: name, showHidden: false), !WorkItemService.prunedDirectoryNames.contains(name),
                          (try child.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink != true else { continue }
                    try visit(child, relative: url == root ? name : relative + "/" + name, depth: depth + 1)
                }
            } else if values.isRegularFile == true {
                guard values.isUbiquitousItem != true || CloudStatus(values.ubiquitousItemDownloadingStatus)?.isLocal == true else {
                    throw MobilePlanningFiles.Error.invalid("Download \(url.lastPathComponent) on the Mac first, then update this offline copy.")
                }
                guard bundle.files.count < Self.maximumFiles, (values.fileSize ?? 0) <= Self.maximumBytes - total else {
                    throw MobilePlanningFiles.Error.invalid("This folder exceeds 500 files / 50 MB. Choose a smaller folder.")
                }
                let handle = try FileHandle(forReadingFrom: safe)
                defer { try? handle.close() }
                let data = try handle.read(upToCount: Self.maximumBytes - total + 1) ?? Data()
                guard data.count <= Self.maximumBytes - total,
                      try safe.resourceValues(forKeys: keys).contentModificationDate == values.contentModificationDate else { throw MobilePlanningFiles.Error.conflict }
                total += data.count
                bundle.files.append(.init(path: relative, data: data))
            }
        }
        try visit(root, relative: root.lastPathComponent, depth: 0)
        try bundle.validate()
        return bundle
    }
    public func write(to url: URL) throws {
        try validate()
        let encoder = PropertyListEncoder(); encoder.outputFormat = .binary
        let data = try encoder.encode(self)
        guard data.count <= Self.maximumArchiveBytes else { throw MobilePlanningFiles.Error.invalid("Choose a smaller offline download.") }
        try data.write(to: url, options: .atomic)
    }
    public static func read(from url: URL) throws -> Self {
        guard let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= maximumArchiveBytes else { throw MobilePlanningFiles.Error.invalid("The offline download is too large.") }
        let bundle = try PropertyListDecoder().decode(Self.self, from: Data(contentsOf: url))
        try bundle.validate(); return bundle
    }
}

public struct MobileOfflineCopy: Codable, Identifiable, Sendable {
    public let id: UUID
    public let path: String
    public let title: String
    public let generatedAt: Date
    public let files: [String]
    public let directories: [String]
}

public actor MobileDownloadCache {
    public let root: URL
    public init(root: URL) { self.root = root }
    public func load(_ id: UUID) -> MobileOfflineCopy? {
        guard let data = try? Data(contentsOf: root.appendingPathComponent(id.uuidString + "/manifest.json")), data.count <= 1_000_000,
              let value = try? JSONDecoder().decode(MobileOfflineCopy.self, from: data), value.id == id,
              value.files.count <= MobileDownloadBundle.maximumFiles,
              value.files.allSatisfy(MobileDownloadBundle.safePath), value.directories.allSatisfy(MobileDownloadBundle.safePath) else { return nil }
        return value
    }
    public func install(asset: URL, id: UUID, expectedPath: String) throws -> MobileOfflineCopy {
        let bundle = try MobileDownloadBundle.read(from: asset)
        guard bundle.path == expectedPath else { throw MobilePlanningFiles.Error.conflict }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let staging = root.appendingPathComponent(".staging-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: staging) }
        let content = staging.appendingPathComponent("files")
        try FileManager.default.createDirectory(at: content, withIntermediateDirectories: false)
        for path in bundle.directories { try FileManager.default.createDirectory(at: content.appendingPathComponent(path), withIntermediateDirectories: true) }
        for file in bundle.files {
            let destination = content.appendingPathComponent(file.path)
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try file.data.write(to: destination, options: .withoutOverwriting)
        }
        let copy = MobileOfflineCopy(id: id, path: bundle.path, title: bundle.title, generatedAt: bundle.generatedAt,
            files: bundle.files.map(\.path), directories: bundle.directories)
        try JSONEncoder().encode(copy).write(to: staging.appendingPathComponent("manifest.json"), options: .atomic)
        let destination = root.appendingPathComponent(id.uuidString)
        // Each update has a fresh ID; the previous usable copy is kept until install succeeds.
        guard !FileManager.default.fileExists(atPath: destination.path) else { throw MobilePlanningFiles.Error.conflict }
        try FileManager.default.moveItem(at: staging, to: destination)
        return copy
    }
    public func remove(_ id: UUID) throws { try FileManager.default.removeItem(at: root.appendingPathComponent(id.uuidString)) }
    public nonisolated func fileURL(copy: MobileOfflineCopy, path: String) -> URL? {
        guard copy.files.contains(path), MobileDownloadBundle.safePath(path) else { return nil }
        return root.appendingPathComponent(copy.id.uuidString + "/files/" + path)
    }
}
