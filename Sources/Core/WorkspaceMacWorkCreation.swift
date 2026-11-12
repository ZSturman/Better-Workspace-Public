import Foundation

/// Private, frozen request for a reviewed new portable file. Its UUID is the
/// portable record identity; its filename is only a collision-safe destination.
public struct WorkspaceMacWorkCreation: Codable, Equatable, Identifiable, Sendable {
    public var createsDirectory: Bool { [.project, .folder].contains(revision.content.kind) }
    public var createsContent: Bool { WorkItemKind(rawValue: revision.content.kind.rawValue) == nil }
    public var id: UUID { revision.recordID }
    public let version: Int
    public let revision: WorkspaceRecordRevision
    public let relativePath: String
    public let rootIdentity: FileIdentity
    public let directoryIdentity: FileIdentity
    public let project: WorkspaceMacBinding?
    public let projectDirectoryIdentity: FileIdentity?
    public let container: WorkspaceMacBinding?

    public static func prepare(recordID: UUID, in graph: WorkspaceReplica, bindings: [WorkspaceMacBinding],
                               workspace: WorkspaceLocation, directoryPath requestedDirectoryPath: String, reservedPaths: Set<String> = []) throws -> Self {
        try graph.validate()
        try WorkspaceMacProjection.validateBindings(bindings)
        guard !bindings.contains(where: { $0.recordID == recordID }),
              let revision = graph.records.first(where: { $0.id == recordID })?.resolved else { throw WorkspaceReplicaError.changed }
        try Self.validateContent(revision.content)
        var directoryPath = requestedDirectoryPath
        if revision.content.kind == .project {
            guard directoryPath == "Projects", revision.content.parentID == nil else { throw WorkspaceReplicaError.invalid("Create this project's Mac folder directly in Projects before organizing it further.") }
        }
        var project: WorkspaceMacBinding?
        var container: WorkspaceMacBinding?
        if let parent = revision.content.parentID {
            guard let parentContent = graph.records.first(where: { $0.id == parent })?.resolved?.content,
                  !parentContent.isDeleted,
                  let binding = bindings.first(where: { $0.recordID == parent && [.project, .folder, .idea].contains($0.source) }) else {
                throw WorkspaceReplicaError.invalid("Connect the parent folder or project to this Mac before creating nested items.")
            }
            if binding.source == .project { project = binding }
            if binding.source != .project || WorkItemKind(rawValue: revision.content.kind.rawValue) == nil {
                container = binding; directoryPath = binding.relativePath
            }
        }
        try WorkspaceLocalPathChecks.rejectSymlinks(to: workspace.root)
        let directory = try MobilePlanningFiles.resolve(directoryPath, workspace: workspace)
        try WorkspaceLocalPathChecks.rejectSymlinks(to: directory)
        guard (try directory.resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true,
              let rootID = FileIdentityResolver.identity(of: workspace.root),
              let directoryID = FileIdentityResolver.identity(of: directory) else { throw WorkspaceReplicaError.missing }
        let projectIdentity: FileIdentity?
        if let project {
            guard project.source == .project, project.recordID == revision.content.parentID else { throw WorkspaceReplicaError.changed }
            let url = try MobilePlanningFiles.resolve(project.relativePath, workspace: workspace)
            try WorkspaceLocalPathChecks.rejectSymlinks(to: url)
            guard (try url.resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true,
                  let identity = FileIdentityResolver.identity(of: url) else { throw WorkspaceReplicaError.missing }
            projectIdentity = identity
        } else { projectIdentity = nil }
        let base = CaptureNaming.safeFilename(revision.content.title)
        let reserved = Set(reservedPaths.map(key))
        for number in 0..<1000 {
            let suffix = number == 0 ? "" : "-" + revision.origin.rawValue + (number == 1 ? "" : "-\(number)")
            let ext = [.project, .folder].contains(revision.content.kind) ? "" : WorkItemKind(rawValue: revision.content.kind.rawValue) == nil ? ".md" : WorkItemService.fileSuffix
            let path = directoryPath + "/" + base + suffix + ext
            let url = try MobilePlanningFiles.resolve(path, workspace: workspace)
            // lstat also notices broken symlinks; those names are occupied.
            var info = stat()
            if !reserved.contains(key(path)), lstat(url.path, &info) != 0, errno == ENOENT {
                return Self(version: 1, revision: revision, relativePath: path, rootIdentity: rootID, directoryIdentity: directoryID, project: project, projectDirectoryIdentity: projectIdentity, container: container)
            }
        }
        throw WorkspaceReplicaError.invalid("Choose another title; too many work files already use this name.")
    }

    /// A stale preview must fail before a durable request is recorded. Once it is
    /// recorded, replay writes this exact revision even if a newer edit arrives.
    public func validateApproval(in graph: WorkspaceReplica, bindings: [WorkspaceMacBinding]) throws {
        guard graph.records.first(where: { $0.id == id })?.resolved == revision,
              !bindings.contains(where: { $0.recordID == id }) else { throw WorkspaceReplicaError.changed }
    }

    public func materialize(in graph: WorkspaceReplica, bindings: [WorkspaceMacBinding], workspace: WorkspaceLocation,
                            service: WorkItemService = WorkItemService()) throws -> (WorkItem, WorkspaceMacBinding) {
        guard version == 1 else { throw WorkspaceReplicaError.unsupportedVersion }
        guard !createsContent else { throw WorkspaceReplicaError.invalid("Use the reviewed content creation action.") }
        try Self.validateContent(revision.content)
        try WorkspaceMacProjection.validateBindings(bindings)
        guard graph.revisions.contains(revision), MobileDownloadBundle.safePath(relativePath),
              !bindings.contains(where: { $0.recordID == id && ($0.source != .work || $0.sourceID != id.uuidString || $0.relativePath != relativePath || $0.observedRevisionID != revision.id) }) else { throw WorkspaceReplicaError.changed }
        try WorkspaceLocalPathChecks.rejectSymlinks(to: workspace.root)
        let url = try MobilePlanningFiles.resolve(relativePath, workspace: workspace)
        try WorkspaceLocalPathChecks.rejectSymlinks(to: url)
        guard FileIdentityResolver.identity(of: workspace.root) == rootIdentity,
              FileIdentityResolver.identity(of: url.deletingLastPathComponent()) == directoryIdentity else { throw WorkspaceReplicaError.changed }
        if let project {
            guard project.source == .project, project.recordID == revision.content.parentID else { throw WorkspaceReplicaError.changed }
            guard bindings.contains(where: { $0.recordID == project.recordID && $0.source == .project && $0.sourceID == project.sourceID && $0.relativePath == project.relativePath }),
                  let parentContent = graph.records.first(where: { $0.id == project.recordID })?.resolved?.content,
                  parentContent.kind == .project, !parentContent.isDeleted else { throw WorkspaceReplicaError.changed }
            let parent = try MobilePlanningFiles.resolve(project.relativePath, workspace: workspace)
            try WorkspaceLocalPathChecks.rejectSymlinks(to: parent)
            guard (try parent.resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true,
                  projectDirectoryIdentity != nil, FileIdentityResolver.identity(of: parent) == projectDirectoryIdentity else { throw WorkspaceReplicaError.changed }
        } else if revision.content.parentID != nil && container == nil { throw WorkspaceReplicaError.changed }
        if let container {
            guard container.recordID == revision.content.parentID,
                  bindings.contains(where: { $0.recordID == container.recordID && $0.relativePath == container.relativePath }),
                  graph.records.first(where: { $0.id == container.recordID })?.resolved?.content.isDeleted == false,
                  relativePath.hasPrefix(container.relativePath + "/") else { throw WorkspaceReplicaError.changed }
        }
        let content = revision.content
        let draft = WorkItem(id: id.uuidString, kind: WorkItemKind(rawValue: content.kind.rawValue)!, title: content.title,
                             status: content.isComplete ? .completed : .open, stage: .next, priority: .medium,
                             projectPath: project?.relativePath, completedAt: content.isComplete ? revision.createdAt : nil,
                             body: content.body, extraFrontMatter: container.map { [WorkspaceMacProjection.folderParentKey + " " + $0.recordID.uuidString] } ?? [], url: url)
        let saved: WorkItem
        var info = stat()
        if lstat(url.path, &info) == 0 {
            // Replay only recognizes the planned UUID and exact selected content.
            // A same-name unrelated file, or an edited original, is never adopted.
            guard (info.st_mode & S_IFMT) == S_IFREG, let current = service.read(at: url),
                  current.id == draft.id, current.kind == draft.kind, current.title == draft.title,
                  current.body == MobilePlanningFiles.normalizedWorkBody(draft.body), current.status == draft.status,
                  current.projectPath == draft.projectPath, WorkspaceMacProjection.workspaceFolderID(in: current) == WorkspaceMacProjection.workspaceFolderID(in: draft) else { throw WorkspaceReplicaError.changed }
            saved = current
        } else {
            guard errno == ENOENT else { throw WorkspaceReplicaError.missing }
            saved = try service.createAtReviewedURL(draft)
        }
        return (saved, .init(recordID: id, source: .work, sourceID: id.uuidString, relativePath: relativePath, observedRevisionID: revision.id))
    }

    private static func validateContent(_ content: WorkspaceRecordContent) throws {
        guard !content.isDeleted,
              content.kind == .project || (content.projectMetadata == nil && content.projectLinks == nil),
              !content.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              content.title.utf8.count <= 512, content.title.rangeOfCharacter(from: .newlines) == nil,
              content.body.utf8.count <= MobilePlanningFiles.maximumTextBytes else {
            throw WorkspaceReplicaError.invalid("Use a title under 512 bytes and text under 32 KB for this Mac item.")
        }
        if let links = content.projectLinks { try ProjectProperties.validate(links) }
    }
    private static func key(_ path: String) -> String { path.precomposedStringWithCanonicalMapping.lowercased() }
}

/// Stored beside the existing root-scoped Mac write journal, never in a workspace
/// folder or cloud payload. An unconfirmed creation is retained for safe replay.
public final class WorkspaceMacCreationJournal: @unchecked Sendable {
    private let directory: URL
    public init(directory: URL) { self.directory = directory.appendingPathComponent("MacCreates") }
    public func pending() throws -> [WorkspaceMacWorkCreation] {
        try prepare()
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }.map { url in
                try WorkspaceLocalPathChecks.rejectSymlinks(to: url)
                guard (try url.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? Int.max <= 131_072 else { throw WorkspaceReplicaError.invalid("The creation receipt is too large.") }
                let request = try JSONDecoder().decode(WorkspaceMacWorkCreation.self, from: Data(contentsOf: url))
                guard request.version == 1, url.deletingPathExtension().lastPathComponent == request.id.uuidString else { throw WorkspaceReplicaError.unsupportedVersion }
                return request
            }
    }
    public func begin(_ request: WorkspaceMacWorkCreation) throws {
        try prepare()
        let data = try JSONEncoder().encode(request)
        guard data.count <= 131_072 else { throw WorkspaceReplicaError.invalid("This creation request is too large. Reduce its text or project properties.") }
        let url = file(request)
        try WorkspaceLocalPathChecks.rejectSymlinks(to: url)
        if FileManager.default.fileExists(atPath: url.path) {
            guard try JSONDecoder().decode(WorkspaceMacWorkCreation.self, from: Data(contentsOf: url)) == request else { throw WorkspaceReplicaError.changed }
        } else { try data.write(to: url, options: .withoutOverwriting) }
        let handle = try FileHandle(forWritingTo: url); defer { try? handle.close() }; try handle.synchronize()
    }
    public func finish(_ request: WorkspaceMacWorkCreation) throws {
        let url = file(request)
        try WorkspaceLocalPathChecks.rejectSymlinks(to: url)
        guard try JSONDecoder().decode(WorkspaceMacWorkCreation.self, from: Data(contentsOf: url)) == request else { throw WorkspaceReplicaError.changed }
        try FileManager.default.removeItem(at: url)
    }
    private func file(_ request: WorkspaceMacWorkCreation) -> URL { directory.appendingPathComponent(request.id.uuidString + ".json") }
    private func prepare() throws {
        try WorkspaceLocalPathChecks.rejectSymlinks(to: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
}
