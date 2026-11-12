import Foundation

/// Frozen optimistic edit over one bounded, already bound original. Folder notes
/// and completion belong to the portable graph; folder title/location changes
/// require a separate reviewed filesystem action.
public struct WorkspaceMacFileSave: Sendable {
    public let original: WorkspaceMacFileSource
    public let source: WorkspaceRecordContent
    public let desired: WorkspaceRecordContent
    public let snapshot: TextDocumentService.Snapshot?
    public let replacementText: String?

    public static func sourceContent(_ file: WorkspaceMacFileSource, binding: WorkspaceMacBinding,
                                     in graph: WorkspaceReplica, bindings: [WorkspaceMacBinding]) throws -> WorkspaceRecordContent {
        guard file.id == binding.recordID, let body = file.body,
              let baseline = graph.revisions.first(where: { $0.id == binding.observedRevisionID && $0.recordID == binding.recordID }) else { throw WorkspaceReplicaError.changed }
        let parentPath = file.relativePath.split(separator: "/").dropLast().joined(separator: "/")
        let containers = bindings.filter { $0.relativePath == parentPath && [.folder, .idea, .project].contains($0.source) }
        guard containers.count <= 1 else { throw WorkspaceReplicaError.changed }
        return .init(kind: file.kind,
            title: file.kind == .folder && file.relativePath == binding.relativePath ? baseline.content.title : file.title,
            body: file.kind == .folder ? baseline.content.body : body,
            parentID: containers.first?.recordID, isComplete: baseline.content.isComplete)
    }

    public static func prepare(binding: WorkspaceMacBinding, in graph: WorkspaceReplica, bindings: [WorkspaceMacBinding],
                               workspace: WorkspaceLocation, scope: UUID, ideaTitle: String? = nil, ideaDescription: String? = nil) throws -> Self {
        guard [.note, .idea, .folder].contains(binding.source),
              let baseline = graph.revisions.first(where: { $0.id == binding.observedRevisionID && $0.recordID == binding.recordID }),
              let target = graph.records.first(where: { $0.id == binding.recordID })?.resolved,
              WorkspaceMacProjection.descends(target, from: baseline.id, in: graph), !target.content.isDeleted else { throw WorkspaceReplicaError.changed }
        let file = try WorkspaceMacFileSource.readBound(binding, workspace: workspace, scope: scope, title: ideaTitle, description: ideaDescription)
        let source = try sourceContent(file, binding: binding, in: graph, bindings: bindings)
        var expected = baseline.content, actual = source, desired = target.content
        // These fields are app-owned, without a filesystem representation.
        actual.isComplete = desired.isComplete; expected.isComplete = desired.isComplete
        if file.kind == .folder { actual.body = desired.body; expected.body = desired.body }
        expected.body = MobilePlanningFiles.normalizedWorkBody(expected.body)
        actual.body = MobilePlanningFiles.normalizedWorkBody(actual.body)
        desired.body = MobilePlanningFiles.normalizedWorkBody(desired.body)
        guard desired.kind == baseline.content.kind, desired.parentID == source.parentID,
              file.kind != .folder || desired.title == source.title else {
            throw WorkspaceReplicaError.invalid("Review this item's rename or move in the Mac filesystem before applying it.")
        }
        guard actual == expected || actual == desired else { throw WorkspaceReplicaError.changed }
        guard target.content.title.utf8.count <= 512, target.content.title.rangeOfCharacter(from: .newlines) == nil,
              target.content.body.utf8.count <= MobilePlanningFiles.maximumTextBytes else { throw WorkspaceReplicaError.invalid("Use a single-line title under 512 bytes and text under 32 KB.") }
        var snapshot: TextDocumentService.Snapshot?, replacement: String?
        if !file.isDirectory {
            let url = try WorkspaceMacProjection.bounded(binding.relativePath, workspace: workspace)
            snapshot = try TextDocumentService().read(at: url)
            // Source and snapshot must describe the same bytes; an editor may run
            // between the first bounded read and this optimistic snapshot.
            let check = try WorkspaceMacFileSource.readBound(binding, workspace: workspace, scope: scope)
            guard check.identity == file.identity, check.title == file.title, check.body == file.body else { throw WorkspaceReplicaError.changed }
            if actual != desired { replacement = MobilePlanningFiles.ideaText(title: target.content.title, description: target.content.body) }
        }
        return .init(original: file, source: source, desired: target.content, snapshot: snapshot, replacementText: replacement)
    }
}
