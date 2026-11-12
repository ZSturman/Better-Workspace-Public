import Foundation

/// An explicitly indexed item or an existing private binding, never a recursive
/// search result. Idea folder descriptions are supplied by the existing service.
public struct WorkspaceMacFileCandidate: Sendable {
    public let relativePath: String
    public let kind: WorkspaceRecordContent.Kind
    public let title: String?
    public let description: String?
    public let serviceID: String?
    public init(relativePath: String, kind: WorkspaceRecordContent.Kind, title: String? = nil, description: String? = nil, serviceID: String? = nil) {
        self.relativePath = relativePath; self.kind = kind; self.title = title; self.description = description; self.serviceID = serviceID
    }
}

public struct WorkspaceMacFileSource: Sendable {
    public let id: UUID
    public let relativePath: String
    public let kind: WorkspaceRecordContent.Kind
    public let title: String
    public let body: String?
    public let isDirectory: Bool
    public let identity: FileIdentity
    public let createdAt: Date?
    public let modifiedAt: Date?
    public let serviceID: String?
    public var source: WorkspaceMacBinding.Source { kind == .idea ? .idea : kind == .folder ? .folder : .note }

    public static func read(_ candidate: WorkspaceMacFileCandidate, workspace: WorkspaceLocation,
                            bindings: [WorkspaceMacBinding], scope: UUID) throws -> Self {
        let url = try WorkspaceMacProjection.bounded(candidate.relativePath, workspace: workspace)
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isPackageKey, .creationDateKey, .contentModificationDateKey, .fileSizeKey, .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey])
        guard values.isPackage != true, let identity = FileIdentityResolver.identity(of: url),
              [.idea, .note, .folder].contains(candidate.kind) else { throw WorkspaceReplicaError.changed }
        let directory = values.isDirectory == true
        guard directory || values.isRegularFile == true else { throw WorkspaceReplicaError.invalid("Only ordinary folders and plain-text files can be included.") }
        if !directory && values.isUbiquitousItem == true {
            guard values.ubiquitousItemDownloadingStatus == .current || values.ubiquitousItemDownloadingStatus == .downloaded else { throw WorkspaceReplicaError.invalid("Download this original on the Mac before including it.") }
        }
        let marker = try WorkspaceContentIdentity.read(at: url)
        let old = bindings.first { [.project, .note, .idea, .folder].contains($0.source) && $0.fileIdentity == identity && ($0.sourceCreatedAt == nil || $0.sourceCreatedAt == values.creationDate) }
            ?? bindings.first { $0.relativePath == candidate.relativePath && $0.sourceCreatedAt != nil && $0.sourceCreatedAt == values.creationDate && [.note, .idea].contains($0.source) }
        // A physical move into Ideas takes precedence over an old marker/kind.
        // A project binding carries the same UUID into its new idea record.
        let movedIntoIdeas = candidate.relativePath.split(separator: "/").first == "Ideas"
        let kind: WorkspaceRecordContent.Kind = movedIntoIdeas ? .idea : marker?.kind ?? old.map { $0.source == .idea ? .idea : $0.source == .folder ? .folder : .note } ?? candidate.kind
        let id: UUID
        if let marker { id = marker.id }
        else if let old { id = old.recordID }
        else if let service = candidate.serviceID { id = WorkspaceMacProjection.recordID(source: .idea, sourceID: service) }
        else {
            struct Seed: Encodable { let scope: UUID; let identity: FileIdentity; let created: Date? }
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            id = WorkspaceStableIdentity.uuid(namespace: "BetterWorkspace.mac-file.v1", data: try encoder.encode(Seed(scope: scope, identity: identity, created: values.creationDate)))
        }
        var title = candidate.title ?? (directory ? url.lastPathComponent : url.deletingPathExtension().lastPathComponent)
        let body: String?
        if directory { body = kind == .idea ? candidate.description : "" }
        else {
            guard ["md", "markdown", "mdown", "txt"].contains(url.pathExtension.lowercased()),
                  !url.lastPathComponent.hasSuffix(WorkItemService.fileSuffix),
                  values.fileSize ?? Int.max <= MobilePlanningFiles.maximumTextBytes + 516 else { throw WorkspaceReplicaError.invalid("Only selected plain-text notes under 32 KB are included.") }
            let text = try TextDocumentService().read(at: url).text
            if marker != nil || kind == .idea {
                let parts = MobilePlanningFiles.splitIdeaText(text, fallbackTitle: title)
                guard parts.0.utf8.count <= 512, parts.1.utf8.count <= MobilePlanningFiles.maximumTextBytes else { throw WorkspaceReplicaError.invalid("This title or note is too large for portable editing.") }
                title = parts.0; body = parts.1
            } else {
                guard text.utf8.count <= MobilePlanningFiles.maximumTextBytes else { throw WorkspaceReplicaError.invalid("This note is too large for portable editing.") }
                body = text
            }
        }
        return .init(id: id, relativePath: candidate.relativePath, kind: kind, title: title, body: body, isDirectory: directory,
                     identity: identity, createdAt: values.creationDate, modifiedAt: values.contentModificationDate, serviceID: candidate.serviceID ?? old?.serviceID)
    }

    public static func readBound(_ binding: WorkspaceMacBinding, workspace: WorkspaceLocation, scope: UUID,
                                 title: String? = nil, description: String? = nil) throws -> Self {
        let kind: WorkspaceRecordContent.Kind = binding.source == .idea ? .idea : binding.source == .folder ? .folder : .note
        let value = try read(.init(relativePath: binding.relativePath, kind: kind, title: title, description: description, serviceID: binding.serviceID), workspace: workspace, bindings: [binding], scope: scope)
        guard value.id == binding.recordID else { throw WorkspaceReplicaError.changed }
        return value
    }
}
