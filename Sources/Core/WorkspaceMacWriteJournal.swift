import Foundation

/// Before an asynchronous source write, persist its exact intended revision. A
/// newer incoming edit cannot be mistaken for the revision actually written.
public struct WorkspaceMacWriteRequest: Codable, Equatable, Sendable {
    public let version: Int
    public let binding: WorkspaceMacBinding
    public let revisionID: UUID

    public init(binding: WorkspaceMacBinding, revisionID: UUID) {
        version = 1; self.binding = binding; self.revisionID = revisionID
    }

    public func selectedReplica(in graph: WorkspaceReplica) throws -> WorkspaceReplica {
        guard version == 1 else { throw WorkspaceReplicaError.unsupportedVersion }
        try WorkspaceMacProjection.validateBindings([binding])
        let known = Dictionary(uniqueKeysWithValues: graph.revisions.map { ($0.id, $0) })
        guard known[revisionID]?.recordID == binding.recordID else { throw WorkspaceReplicaError.missing }
        var selected: Set<UUID> = [], pending = [revisionID]
        while let id = pending.popLast() {
            guard selected.insert(id).inserted, let revision = known[id], revision.recordID == binding.recordID else { continue }
            pending.append(contentsOf: revision.parents)
        }
        guard selected.contains(binding.observedRevisionID) else { throw WorkspaceReplicaError.changed }
        return try WorkspaceReplica(workspaceID: graph.workspaceID,
            revisions: graph.revisions.filter { $0.recordID != binding.recordID || selected.contains($0.id) }, joinedWorkspaceIDs: graph.joinedWorkspaceIDs)
    }

    /// A rejected save preserves the source as a competing version, including when
    /// it still contains the baseline. The user can resolve toward either version;
    /// repeated failures never silently strand the file queue or discard their edit.
    public func rejectionRevision(in graph: WorkspaceReplica, currentBinding: WorkspaceMacBinding, source: WorkspaceRecordContent, deviceID: UUID) throws -> WorkspaceRecordRevision {
        _ = try selectedReplica(in: graph)
        guard currentBinding.recordID == binding.recordID, currentBinding.source == binding.source,
              currentBinding.sourceID == binding.sourceID, currentBinding.relativePath == binding.relativePath,
              let baseline = graph.revisions.first(where: { $0.id == currentBinding.observedRevisionID && $0.recordID == binding.recordID }),
              let selected = graph.revisions.first(where: { $0.id == revisionID }) else { throw WorkspaceReplicaError.changed }
        struct Seed: Encodable { let request: WorkspaceMacWriteRequest; let baseline: UUID; let source: WorkspaceRecordContent; let device: UUID }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let id = WorkspaceStableIdentity.uuid(namespace: "BetterWorkspace.mac-write-rejected.v1", data: try encoder.encode(Seed(request: self, baseline: baseline.id, source: source, device: deviceID)))
        return .init(id: id, recordID: binding.recordID, parents: [baseline.id], deviceID: deviceID, origin: .mac,
                     createdAt: selected.createdAt, recordCreatedAt: baseline.recordCreatedAt, content: source)
    }

    /// Call after rereading the file with `prepareWorkSave` against selectedReplica
    /// and receiving `.unchanged`. The receipt advances to this exact revision,
    /// even when a newer remote head arrived while the source writer was suspended.
    public func acknowledgedBindings(_ bindings: [WorkspaceMacBinding]) throws -> [WorkspaceMacBinding] {
        guard let current = bindings.first(where: { $0.recordID == binding.recordID }), current == binding || (current.observedRevisionID == revisionID && current.source == binding.source && current.sourceID == binding.sourceID && current.relativePath == binding.relativePath) else { throw WorkspaceReplicaError.changed }
        return bindings.map { value in
            guard value.recordID == binding.recordID else { return value }
            return .init(recordID: value.recordID, source: value.source, sourceID: value.sourceID,
                         relativePath: value.relativePath, observedRevisionID: revisionID, fileIdentity: value.fileIdentity, sourceCreatedAt: value.sourceCreatedAt, serviceID: value.serviceID)
        }
    }
}

public final class WorkspaceMacWriteJournal: @unchecked Sendable {
    private let directory: URL
    public init(directory: URL) { self.directory = directory.appendingPathComponent("MacWrites") }
    public func pending() throws -> [WorkspaceMacWriteRequest] {
        try prepareDirectory()
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }.map { url in
                guard let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent) else { throw WorkspaceReplicaError.invalid("The Mac write journal needs review.") }
                try WorkspaceLocalPathChecks.rejectSymlinks(to: url)
                guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) <= 16_384 else { throw WorkspaceReplicaError.invalid("The Mac write receipt is too large.") }
                let request = try JSONDecoder().decode(WorkspaceMacWriteRequest.self, from: Data(contentsOf: url))
                guard request.version == 1, request.binding.recordID == id else { throw WorkspaceReplicaError.unsupportedVersion }
                return request
            }
    }
    public func begin(_ request: WorkspaceMacWriteRequest) throws {
        try prepareDirectory()
        let url = file(request)
        try WorkspaceLocalPathChecks.rejectSymlinks(to: url)
        if FileManager.default.fileExists(atPath: url.path) {
            guard try JSONDecoder().decode(WorkspaceMacWriteRequest.self, from: Data(contentsOf: url)) == request else { throw WorkspaceReplicaError.changed }
            return
        }
        try JSONEncoder().encode(request).write(to: url, options: .withoutOverwriting)
        let handle = try FileHandle(forWritingTo: url); defer { try? handle.close() }; try handle.synchronize()
    }
    public func finish(_ request: WorkspaceMacWriteRequest) throws {
        let url = file(request)
        try WorkspaceLocalPathChecks.rejectSymlinks(to: url)
        guard try JSONDecoder().decode(WorkspaceMacWriteRequest.self, from: Data(contentsOf: url)) == request else { throw WorkspaceReplicaError.changed }
        try FileManager.default.removeItem(at: url)
    }
    private func file(_ request: WorkspaceMacWriteRequest) -> URL { directory.appendingPathComponent(request.binding.recordID.uuidString + ".json") }
    private func prepareDirectory() throws {
        try WorkspaceLocalPathChecks.rejectSymlinks(to: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
}
