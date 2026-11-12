import Foundation

public struct WorkspaceMacObservationReceipt: Codable, Equatable, Sendable {
    public let version: Int
    public let id: UUID
    public let sourceID: UUID
    public let workspaceID: UUID
    public let rootIdentity: FileIdentity
    public let bindings: [WorkspaceMacBinding]
}

/// Bounded source/observation receipts in Better Workspace's own SQLite database.
/// The graph is durable before a receipt advances. A crash/SQL failure therefore
/// leaves an old baseline that the projection can safely replay, never a receipt
/// referring to revisions that were not saved. No source file is modified here.
public final class WorkspaceMacReceiptStore: @unchecked Sendable {
    private let database: Database
    public init(database: Database) throws {
        self.database = database
        try database.execute("""
        CREATE TABLE IF NOT EXISTS workspace_mac_observations (
          source_id TEXT PRIMARY KEY, receipt TEXT NOT NULL
        );
        """)
    }

    /// An installation may browse more than one selected filesystem root. Keep
    /// their baselines separate without publishing local paths or volume identities.
    public static func sourceID(deviceID: UUID, sourceRoot: URL) throws -> UUID {
        try WorkspaceLocalPathChecks.rejectSymlinks(to: sourceRoot)
        guard let identity = FileIdentityResolver.identity(of: sourceRoot) else { throw WorkspaceReplicaError.missing }
        return try derive(deviceID: deviceID, identity: identity)
    }

    static func derive(deviceID: UUID, identity: FileIdentity) throws -> UUID {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return WorkspaceStableIdentity.uuid(namespace: "BetterWorkspace.mac-root." + deviceID.uuidString, data: try encoder.encode(identity))
    }

    /// The source this device already reviewed for this folder, if any; otherwise a new one.
    ///
    /// A root reviewed before volume identities became stable was named after a device
    /// number that changes across restarts, so its derived ID no longer matches. Without
    /// this, a restart made the Mac look unreviewed and silently stopped Finder changes
    /// from reaching other devices. Only a receipt this device derived from the same
    /// folder (same inode) is adopted.
    public static func sourceID(deviceID: UUID, sourceRoot: URL, database: Database) throws -> UUID {
        let current = try sourceID(deviceID: deviceID, sourceRoot: sourceRoot)
        let store = try WorkspaceMacReceiptStore(database: database)
        if try store.load(sourceID: current) != nil { return current }
        guard let identity = FileIdentityResolver.identity(of: sourceRoot) else { throw WorkspaceReplicaError.missing }
        let stored = try database.query("SELECT source_id FROM workspace_mac_observations", [], row: { $0.string(0) })
        for raw in stored {
            guard let id = UUID(uuidString: raw), let receipt = try? store.load(sourceID: id),
                  receipt.rootIdentity == identity else { continue }
            if receipt.rootIdentity.hasLegacyVolume {
                // Derived by this device from the identity it recorded.
                if try derive(deviceID: deviceID, identity: receipt.rootIdentity) == receipt.sourceID { return receipt.sourceID }
            } else if receipt.rootIdentity.volume == identity.volume, stored.count == 1 {
                // A receipt whose root an earlier build of this fix re-recorded in the
                // stable form: the only source this database has, for exactly this folder.
                return receipt.sourceID
            }
        }
        return current
    }

    public func load(sourceID: UUID) throws -> WorkspaceMacObservationReceipt? {
        guard let text = try database.query("SELECT receipt FROM workspace_mac_observations WHERE source_id=?", [.text(sourceID.uuidString)], row: { $0.string(0) }).first else { return nil }
        guard let data = text.data(using: .utf8), data.count <= 8 * 1_024 * 1_024 else { throw invalid("The Mac observation receipt is too large.") }
        let receipt = try JSONDecoder().decode(WorkspaceMacObservationReceipt.self, from: data)
        guard receipt.version == 1 else { throw WorkspaceReplicaError.unsupportedVersion }
        guard receipt.sourceID == sourceID else { throw invalid("The Mac observation belongs to another source.") }
        try WorkspaceMacProjection.validateBindings(receipt.bindings)
        return receipt
    }

    public func validateRoot(_ receipt: WorkspaceMacObservationReceipt, sourceRoot: URL) throws {
        try WorkspaceLocalPathChecks.rejectSymlinks(to: sourceRoot)
        var status = stat()
        guard lstat(sourceRoot.path, &status) == 0, (status.st_mode & S_IFMT) == S_IFDIR,
              FileIdentityResolver.identity(of: sourceRoot) == receipt.rootIdentity else {
            throw invalid("The selected Mac workspace root changed. Review its connection before applying file edits.")
        }
    }

    /// `expectedReceiptID` belongs to the baseline used to prepare this observation.
    /// Concurrent/stale preparations must reload and observe the current local index.
    /// Use fresh Mac index values here, not a CloudKit/cache snapshot from another peer.
    @discardableResult
    public func commit(_ observation: WorkspaceMacObservation, sourceID: UUID, sourceRoot: URL,
                       expectedReceiptID: UUID?, graph: WorkspaceReplicaStore) throws -> WorkspaceMacObservationReceipt {
        try database.transaction {
            let previous = try load(sourceID: sourceID)
            guard previous?.id == expectedReceiptID else { throw WorkspaceReplicaError.changed }
            try WorkspaceLocalPathChecks.rejectSymlinks(to: sourceRoot)
            var status = stat()
            guard lstat(sourceRoot.path, &status) == 0, (status.st_mode & S_IFMT) == S_IFDIR,
                  let identity = FileIdentityResolver.identity(of: sourceRoot) else { throw WorkspaceReplicaError.missing }
            guard previous == nil || previous!.rootIdentity == identity else {
                throw invalid("The selected Mac workspace root changed. Review its connection before continuing.")
            }
            let current = try graph.load()
            guard previous == nil || current.joinedWorkspaceIDs.contains(previous!.workspaceID) else { throw WorkspaceReplicaError.changed }
            try WorkspaceMacProjection.validateBindings(observation.bindings)
            let revisionOwners = Dictionary(uniqueKeysWithValues: observation.replica.revisions.map { ($0.id, $0.recordID) })
            guard observation.bindings.allSatisfy({ revisionOwners[$0.observedRevisionID] == $0.recordID }),
                  Set(previous?.bindings.map(\.recordID) ?? []).isSubset(of: Set(observation.bindings.map(\.recordID))) else {
                throw invalid("The observation would lose an existing source binding.")
            }
            // A receipt identifies a source baseline, not a polling attempt. Keep
            // an open review valid when only unrelated portable content changed.
            // The graph still becomes durable before returning this old baseline.
            if let previous, previous.workspaceID == observation.replica.workspaceID,
               previous.bindings.sorted(by: { $0.recordID.uuidString < $1.recordID.uuidString }) == observation.bindings.sorted(by: { $0.recordID.uuidString < $1.recordID.uuidString }) {
                if observation.replica != current { try graph.receive(observation.replica) }
                return previous
            }
            let receipt = WorkspaceMacObservationReceipt(version: 1, id: UUID(), sourceID: sourceID,
                // The reviewed root's recorded identity is part of how its source ID was
                // derived; keep it, so a restart-tolerant lookup can still find this source.
                workspaceID: observation.replica.workspaceID, rootIdentity: previous?.rootIdentity ?? identity, bindings: observation.bindings)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(receipt)
            guard data.count <= 8 * 1_024 * 1_024, let text = String(data: data, encoding: .utf8) else { throw invalid("The Mac observation receipt is too large.") }
            // receive checks canonical identity and refuses unapproved source joins.
            try graph.receive(observation.replica)
            try database.run("INSERT INTO workspace_mac_observations(source_id,receipt) VALUES(?,?) ON CONFLICT(source_id) DO UPDATE SET receipt=excluded.receipt", [.text(sourceID.uuidString), .text(text)])
            return receipt
        }
    }
    private func invalid(_ message: String) -> WorkspaceReplicaError { .invalid(message) }
}
