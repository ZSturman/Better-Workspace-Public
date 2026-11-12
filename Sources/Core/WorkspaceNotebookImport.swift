import Foundation
import SwiftData

/// Additive upgrade adapter for the published standalone store. It reads through
/// SwiftData, preserves record UUIDs/project links, and never modifies the old store.
/// Repeated imports of the same source generate the same revision identities.
@MainActor
public enum WorkspaceNotebookImport {
    public static func preview(from context: ModelContext, workspaceID: UUID) throws -> WorkspaceReplica {
        let legacy = try context.fetch(FetchDescriptor<WorkspaceNotebookRecord>())
        var revisions: [UUID: WorkspaceRecordRevision] = [:]
        for item in legacy {
            let content = WorkspaceRecordContent(kind: kind(item.kind), title: item.title, body: item.body,
                parentID: item.projectID, isComplete: item.isComplete, isDeleted: item.isArchived)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            struct Source: Encodable {
                let id: UUID; let createdAt: Date; let modifiedAt: Date; let content: WorkspaceRecordContent
            }
            let bytes = try encoder.encode(Source(id: item.recordID, createdAt: item.createdAt, modifiedAt: item.modifiedAt, content: content))
            let id = WorkspaceStableIdentity.uuid(namespace: "BetterWorkspace.notebook-upgrade.v1", data: bytes)
            let revision = WorkspaceRecordRevision(id: id, recordID: item.recordID,
                deviceID: WorkspaceStableIdentity.uuid(namespace: "BetterWorkspace.notebook-origin.v1", data: Data(item.recordID.uuidString.utf8)),
                origin: .legacy, createdAt: item.modifiedAt, recordCreatedAt: item.createdAt, content: content)
            if let existing = revisions[id], existing != revision { throw WorkspaceReplicaError.revisionCollision }
            revisions[id] = revision
        }
        return try WorkspaceReplica(workspaceID: workspaceID, revisions: revisions.values.sorted { $0.id.uuidString < $1.id.uuidString })
    }

    private static func kind(_ value: WorkspaceNotebookKind) -> WorkspaceRecordContent.Kind {
        switch value { case .project: .project; case .task: .task; case .idea: .idea; case .document: .note }
    }

}
