import Foundation

/// Publish reviewed projects, folders and text notes using an exclusive same-volume
/// move. A private durable proof records the actual identity before publication;
/// retries never adopt an unrelated item because its name matches.
public enum WorkspaceMacDirectoryCreation {
    private struct Proof: Codable {
        let version: Int
        let request: WorkspaceMacWorkCreation
        let replacementDirectory: URL
        let stagedIdentity: FileIdentity
        let stagedCreatedAt: Date
        let containerIdentity: FileIdentity
    }

    public static func materialize(_ request: WorkspaceMacWorkCreation, in graph: WorkspaceReplica,
                                   bindings: [WorkspaceMacBinding], workspace: WorkspaceLocation,
                                   journalDirectory: URL, projects: ProjectStore) throws -> (URL, WorkspaceMacBinding) {
        let kind = request.revision.content.kind
        let source: WorkspaceMacBinding.Source = kind == .project ? .project : kind == .folder ? .folder : kind == .idea ? .idea : .note
        guard request.version == 1, request.createsContent, graph.revisions.contains(request.revision),
              !bindings.contains(where: { $0.recordID == request.id && ($0.source != source || $0.sourceID != request.id.uuidString || $0.relativePath != request.relativePath || $0.observedRevisionID != request.revision.id) }) else { throw WorkspaceReplicaError.changed }
        try WorkspaceLocalPathChecks.rejectSymlinks(to: workspace.root)
        let destination = try MobilePlanningFiles.resolve(request.relativePath, workspace: workspace)
        try WorkspaceLocalPathChecks.rejectSymlinks(to: destination)
        guard FileIdentityResolver.identity(of: workspace.root) == request.rootIdentity,
              FileIdentityResolver.identity(of: destination.deletingLastPathComponent()) == request.directoryIdentity else { throw WorkspaceReplicaError.changed }
        if kind == .project {
            guard request.revision.content.parentID == nil, request.project == nil,
                  request.relativePath.split(separator: "/").count == 2, request.relativePath.hasPrefix("Projects/") else { throw WorkspaceReplicaError.changed }
        } else if let parent = request.container {
            guard parent.recordID == request.revision.content.parentID,
                  bindings.contains(parent), graph.records.first(where: { $0.id == parent.recordID })?.resolved?.content.isDeleted == false,
                  destination.deletingLastPathComponent().canonicalPath == (try MobilePlanningFiles.resolve(parent.relativePath, workspace: workspace)).canonicalPath,
                  parent.fileIdentity == nil || parent.fileIdentity == request.directoryIdentity else { throw WorkspaceReplicaError.changed }
        } else {
            guard request.revision.content.parentID == nil,
                  request.relativePath.split(separator: "/").count == 2 else { throw WorkspaceReplicaError.changed }
        }
        let stagedName = request.createsDirectory ? "Content" : "Content.md"
        let proofDirectory = journalDirectory.appendingPathComponent("DirectoryCreates")
        try WorkspaceLocalPathChecks.rejectSymlinks(to: proofDirectory)
        try FileManager.default.createDirectory(at: proofDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let receipt = proofDirectory.appendingPathComponent(request.id.uuidString + ".json")
        try WorkspaceLocalPathChecks.rejectSymlinks(to: receipt)
        let proof: Proof
        if FileManager.default.fileExists(atPath: receipt.path) {
            guard (try receipt.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? Int.max <= 262_144 else { throw WorkspaceReplicaError.changed }
            proof = try JSONDecoder().decode(Proof.self, from: Data(contentsOf: receipt))
            guard proof.version == 1, proof.request == request else { throw WorkspaceReplicaError.changed }
        } else {
            var info = stat()
            guard lstat(destination.path, &info) != 0, errno == ENOENT else { throw WorkspaceReplicaError.changed }
            let replacement = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: destination.deletingLastPathComponent(), create: true)
            let container = replacement.appendingPathComponent("BetterWorkspace-" + request.id.uuidString)
            try FileManager.default.createDirectory(at: container, withIntermediateDirectories: false)
            let staged = container.appendingPathComponent(stagedName)
            try WorkspaceLocalPathChecks.rejectSymlinks(to: replacement)
            if request.createsDirectory { try FileManager.default.createDirectory(at: staged, withIntermediateDirectories: false) }
            else { try TextDocumentService().create(MobilePlanningFiles.ideaText(title: request.revision.content.title, description: request.revision.content.body), at: staged) }
            if kind != .project { try WorkspaceContentIdentity.write(.init(id: request.id, kind: kind), at: staged) }
            guard let identity = FileIdentityResolver.identity(of: staged), identity.volume == request.directoryIdentity.volume,
                  let created = try staged.resourceValues(forKeys: [.creationDateKey]).creationDate,
                  let containerID = FileIdentityResolver.identity(of: container) else { throw WorkspaceReplicaError.changed }
            proof = Proof(version: 1, request: request, replacementDirectory: container, stagedIdentity: identity, stagedCreatedAt: created, containerIdentity: containerID)
            try JSONEncoder().encode(proof).write(to: receipt, options: .withoutOverwriting)
            let handle = try FileHandle(forWritingTo: receipt); defer { try? handle.close() }; try handle.synchronize()
        }
        let staged = proof.replacementDirectory.appendingPathComponent(stagedName)
        try WorkspaceLocalPathChecks.rejectSymlinks(to: staged)
        // Reserve before the visible move; Finder discovery can race its readback.
        guard proof.replacementDirectory.lastPathComponent == "BetterWorkspace-" + request.id.uuidString,
              FileIdentityResolver.identity(of: proof.replacementDirectory) == proof.containerIdentity else { throw WorkspaceReplicaError.changed }
        if kind == .project { try projects.reserveWorkspaceIdentity(request.id, for: proof.stagedIdentity, createdAt: proof.stagedCreatedAt) }
        if FileIdentityResolver.identity(of: destination) != proof.stagedIdentity {
            guard FileIdentityResolver.identity(of: staged) == proof.stagedIdentity,
                  FileIdentityResolver.identity(of: destination.deletingLastPathComponent()) == request.directoryIdentity else { throw WorkspaceReplicaError.changed }
            guard renameatx_np(AT_FDCWD, staged.path, AT_FDCWD, destination.path, UInt32(RENAME_EXCL)) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        }
        let properties = try destination.resourceValues(forKeys: [.isDirectoryKey, .creationDateKey])
        guard FileIdentityResolver.identity(of: destination) == proof.stagedIdentity,
              properties.isDirectory == request.createsDirectory, properties.creationDate == proof.stagedCreatedAt else { throw WorkspaceReplicaError.changed }
        if kind == .project { try projects.initializeWorkspaceProject(request.revision.content, id: request.id, at: destination) }
        else {
            guard try WorkspaceContentIdentity.read(at: destination) == .init(id: request.id, kind: kind) else { throw WorkspaceReplicaError.changed }
            if !request.createsDirectory {
                let actual = try TextDocumentService().read(at: destination).text
                guard actual == MobilePlanningFiles.ideaText(title: request.revision.content.title, description: request.revision.content.body) else { throw WorkspaceReplicaError.changed }
            }
        }
        return (destination, .init(recordID: request.id, source: source, sourceID: request.id.uuidString,
                                   relativePath: request.relativePath, observedRevisionID: request.revision.id, fileIdentity: proof.stagedIdentity, sourceCreatedAt: proof.stagedCreatedAt))
    }

    public static func cancel(_ request: WorkspaceMacWorkCreation, journalDirectory: URL, projects: ProjectStore) throws {
        let receipt = journalDirectory.appendingPathComponent("DirectoryCreates/" + request.id.uuidString + ".json")
        try WorkspaceLocalPathChecks.rejectSymlinks(to: receipt)
        guard FileManager.default.fileExists(atPath: receipt.path) else { return }
        let proof = try JSONDecoder().decode(Proof.self, from: Data(contentsOf: receipt))
        guard proof.version == 1, proof.request == request, proof.replacementDirectory.lastPathComponent == "BetterWorkspace-" + request.id.uuidString else { throw WorkspaceReplicaError.changed }
        let staged = proof.replacementDirectory.appendingPathComponent(request.createsDirectory ? "Content" : "Content.md")
        try WorkspaceLocalPathChecks.rejectSymlinks(to: staged)
        guard FileIdentityResolver.identity(of: proof.replacementDirectory) == proof.containerIdentity else { throw WorkspaceReplicaError.changed }
        if FileManager.default.fileExists(atPath: staged.path) {
            guard FileIdentityResolver.identity(of: staged) == proof.stagedIdentity else { throw WorkspaceReplicaError.changed }
            if request.createsDirectory {
                guard try FileManager.default.contentsOfDirectory(atPath: staged.path).isEmpty else { throw WorkspaceReplicaError.changed }
            } else {
                guard try WorkspaceContentIdentity.read(at: staged) == .init(id: request.id, kind: request.revision.content.kind),
                      try TextDocumentService().read(at: staged).text == MobilePlanningFiles.ideaText(title: request.revision.content.title, description: request.revision.content.body) else { throw WorkspaceReplicaError.changed }
            }
            try FileManager.default.removeItem(at: staged)
        }
        if request.revision.content.kind == .project { try projects.releaseUnpublishedWorkspaceIdentity(request.id, identity: proof.stagedIdentity) }
        guard try FileManager.default.contentsOfDirectory(atPath: proof.replacementDirectory.path).isEmpty else { throw WorkspaceReplicaError.changed }
        try FileManager.default.removeItem(at: proof.replacementDirectory)
        try FileManager.default.removeItem(at: receipt)
    }
}
