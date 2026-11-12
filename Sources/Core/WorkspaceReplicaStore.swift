import Foundation

public struct WorkspaceMergePreview: Equatable, Sendable {
    public let localFingerprint: String
    public let incomingFingerprint: String
    public let addedRevisionCount: Int
    public let conflictRecordIDs: [UUID]
    public let pendingRevisionCount: Int
    public let displayTitles: [UUID: String]
    public let locationIssues: [UUID: WorkspaceReplica.LocationIssue]
    public let resultWorkspaceID: UUID
    public let joinedWorkspaceIDs: Set<UUID>

    public init(local: WorkspaceReplica, incoming: WorkspaceReplica) throws {
        localFingerprint = try local.fingerprint; incomingFingerprint = try incoming.fingerprint
        let combined = try local.joining(incoming)
        resultWorkspaceID = combined.workspaceID; joinedWorkspaceIDs = combined.joinedWorkspaceIDs
        addedRevisionCount = combined.revisions.count - local.revisions.count
        conflictRecordIDs = combined.records.filter(\.isConflict).map(\.id)
        pendingRevisionCount = combined.pendingRevisionCount
        displayTitles = combined.displayTitles
        locationIssues = combined.locationIssues
    }
}

/// Private journal transactions use the same process-shared locking pattern as the
/// widget dashboard. A second window/process always rereads the latest store under
/// the lock. Neither a failed read nor an incompatible format creates a replacement.
public final class WorkspaceReplicaStore: @unchecked Sendable {
    public let directory: URL
    private let initialWorkspaceID: UUID
    private let processLock = NSLock()
    private let manager = FileManager.default
    private static let byteLimit = 64 * 1_024 * 1_024

    /// The caller supplies an app-owned directory, never a user's Workspace root.
    /// There is deliberately no live default until the filesystem/cloud adapters pass
    /// the phase-one acceptance gate.
    public init(directory: URL, initialWorkspaceID: UUID) {
        self.directory = directory; self.initialWorkspaceID = initialWorkspaceID
    }

    public func load() throws -> WorkspaceReplica {
        try locked { try read() }
    }

    @discardableResult
    public func save(recordID: UUID = UUID(), content: WorkspaceRecordContent, expectedHeads: Set<UUID>,
                     deviceID: UUID, origin: WorkspaceRecordRevision.Origin,
                     resolvingConflict: Bool = false) throws -> WorkspaceRecordRevision {
        try locked {
            var replica = try read()
            let revision = try replica.save(recordID: recordID, content: content, expectedHeads: expectedHeads,
                deviceID: deviceID, origin: origin, resolvingConflict: resolvingConflict)
            try write(replica)
            return revision
        }
    }

    public func previewMerge(_ incoming: WorkspaceReplica) throws -> WorkspaceMergePreview {
        try locked { try WorkspaceMergePreview(local: read(), incoming: incoming) }
    }

    /// Call only after presenting this exact preview and receiving approval. The
    /// checkpoint is durable before the merged store is installed. It contains only
    /// this app's records and is never written into an organized content folder.
    @discardableResult
    public func applyReviewedMerge(_ incoming: WorkspaceReplica, approved preview: WorkspaceMergePreview) throws -> URL {
        try locked {
            let local = try read()
            guard try WorkspaceMergePreview(local: local, incoming: incoming) == preview else { throw WorkspaceReplicaError.changed }
            let candidate = try local.joining(incoming)
            let checkpoint = directory.appendingPathComponent("merge-" + UUID().uuidString + ".json")
            try writeCheckpoint(encoded(local), to: checkpoint)
            try write(candidate)
            return checkpoint
        }
    }

    /// A reviewed initial merge is the only operation allowed to join independently
    /// created workspace IDs. Routine synchronization must name the adopted workspace.
    public func receive(_ incoming: WorkspaceReplica) throws {
        try locked {
            let local = try read()
            guard incoming.workspaceID == local.workspaceID,
                  incoming.joinedWorkspaceIDs.isSubset(of: local.joinedWorkspaceIDs) else {
                throw WorkspaceReplicaError.invalid("Review the initial workspace merge before synchronizing these workspaces.")
            }
            let candidate = try local.merging(incoming)
            if candidate != local { try write(candidate) }
        }
    }

    private var storeURL: URL { directory.appendingPathComponent("workspace.json") }

    private func read() throws -> WorkspaceReplica {
        try rejectSymlinks(to: storeURL)
        guard manager.fileExists(atPath: storeURL.path) else {
            let initial = try WorkspaceReplica(workspaceID: initialWorkspaceID)
            try write(initial)
            return initial
        }
        let size = try storeURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= Self.byteLimit else { throw WorkspaceReplicaError.invalid("The workspace journal exceeds its size limit.") }
        // The Mac reads the journal several times in each 25-second pass. Every write
        // replaces the file atomically (a new inode), so an unchanged file identity
        // means unchanged bytes; any other process's write is a different file.
        let identity = Self.identity(of: storeURL)
        if let identity, let cached, cached.identity == identity { return cached.replica }
        let replica = try JSONDecoder().decode(WorkspaceReplica.self, from: Data(contentsOf: storeURL))
        cached = identity.map { (identity: $0, replica: replica) }
        return replica
    }

    /// Only touched under `processLock`, like every read and write.
    private var cached: (identity: FileStamp, replica: WorkspaceReplica)?
    private struct FileStamp: Equatable { let device: Int32, inode: UInt64, size: Int64, seconds: Int, nanoseconds: Int }
    private static func identity(of url: URL) -> FileStamp? {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return nil }
        return FileStamp(device: info.st_dev, inode: info.st_ino, size: info.st_size,
                         seconds: info.st_mtimespec.tv_sec, nanoseconds: info.st_mtimespec.tv_nsec)
    }

    private func encoded(_ replica: WorkspaceReplica) throws -> Data {
        try replica.validate()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(replica)
        guard data.count <= Self.byteLimit else { throw WorkspaceReplicaError.invalid("The workspace journal exceeds its size limit.") }
        return data
    }

    private func write(_ replica: WorkspaceReplica) throws {
        try rejectSymlinks(to: storeURL)
        cached = nil
        try encoded(replica).write(to: storeURL, options: .atomic)
    }

    private func writeCheckpoint(_ data: Data, to url: URL) throws {
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw WorkspaceReplicaError.invalid("The pre-merge checkpoint could not be created.") }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            try file.write(contentsOf: data)
            try file.synchronize()
            try file.close()
        } catch {
            try? file.close()
            try? manager.removeItem(at: url)
            throw error
        }
    }

    private func locked<T>(_ body: () throws -> T) throws -> T {
        try SuspensionProtection.run("Workspace journal") { try lockedUnprotected(body) }
    }

    private func lockedUnprotected<T>(_ body: () throws -> T) throws -> T {
        processLock.lock(); defer { processLock.unlock() }
        try rejectSymlinks(to: directory)
        try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let lockURL = directory.appendingPathComponent("workspace.lock")
        let descriptor = open(lockURL.path, O_CREAT | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw WorkspaceReplicaError.invalid("The workspace journal could not be locked.") }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw WorkspaceReplicaError.invalid("The workspace journal is busy.") }
        defer { flock(descriptor, LOCK_UN) }
        return try body()
    }

    private func rejectSymlinks(to url: URL) throws {
        try WorkspaceLocalPathChecks.rejectSymlinks(to: url)
    }
}

enum WorkspaceLocalPathChecks {
    static func rejectSymlinks(to url: URL) throws {
        // Foundation returns /var even after resolving /private/var. Accept only
        // Apple's exact system aliases, with their actual link destinations checked.
        // Every caller-controlled component, including the journal, remains bounded.
        var current = url.path
        while current != "/" && !current.isEmpty {
            var status = stat()
            if lstat(current, &status) == 0, (status.st_mode & S_IFMT) == S_IFLNK {
                let allowed = ["/var": "/private/var", "/tmp": "/private/tmp"]
                let destination = try FileManager.default.destinationOfSymbolicLink(atPath: current)
                let absolute = destination.hasPrefix("/") ? destination : "/" + destination
                guard allowed[current] == absolute else {
                    throw WorkspaceReplicaError.invalid("Workspace access cannot follow symbolic links.")
                }
            }
            current = (current as NSString).deletingLastPathComponent
        }
    }
}
