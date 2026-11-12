import Foundation
import CloudKit
import CryptoKit

/// A reviewed join can be acknowledged on another device only while that device
/// still has the exact base the person approved. Later offline edits need a new review.
public struct WorkspaceJoinApproval: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let roots: Set<UUID>
    public let baseFingerprints: Set<String>
    public let authorDeviceID: UUID
    public init(local: WorkspaceReplica, incoming: WorkspaceReplica, authorDeviceID: UUID) throws {
        id = UUID(); roots = local.joinedWorkspaceIDs.union(incoming.joinedWorkspaceIDs)
        baseFingerprints = try [local.fingerprint, incoming.fingerprint]
        self.authorDeviceID = authorDeviceID
    }
    public func authorizes(local: WorkspaceReplica, incoming: WorkspaceReplica) throws -> Bool {
        baseFingerprints.contains(try local.fingerprint)
            && roots == local.joinedWorkspaceIDs.union(incoming.joinedWorkspaceIDs)
            && incoming.joinedWorkspaceIDs.isSuperset(of: roots)
    }
}

public struct WorkspaceCloudPeer: Codable, Sendable, Identifiable {
    public var id: UUID { deviceID }
    public let deviceID: UUID
    public let sourceID: UUID
    public let name: String
    public let platform: String
    public let replica: WorkspaceReplica
    public let approvals: [WorkspaceJoinApproval]
    public init(deviceID: UUID, sourceID: UUID, name: String, platform: String, replica: WorkspaceReplica, approvals: [WorkspaceJoinApproval]) {
        self.deviceID = deviceID; self.sourceID = sourceID; self.name = name; self.platform = platform
        self.replica = replica; self.approvals = approvals
    }
    public func validate() throws {
        try replica.validate()
        guard name.utf8.count <= 256, platform.utf8.count <= 64, approvals.count <= 256,
              replica.joinedWorkspaceIDs.contains(sourceID),
              Set(approvals.map(\.id)).count == approvals.count,
              approvals.allSatisfy({ $0.roots.count <= 256 && $0.baseFingerprints.count == 2 && $0.baseFingerprints.allSatisfy(Self.validFingerprint) && $0.roots.isSubset(of: replica.joinedWorkspaceIDs) }) else {
            throw WorkspaceReplicaError.invalid("The device's workspace identity or merge approval is invalid.")
        }
    }
    private static func validFingerprint(_ value: String) -> Bool {
        // Replica fingerprints include approved root identities before the hash.
        let parts = value.split(separator: ":", omittingEmptySubsequences: false)
        guard value.utf8.count <= 9_600, parts.count == 2, parts[1].count == 64,
              parts[1].allSatisfy({ $0.isHexDigit }) else { return false }
        let roots = parts[0].split(separator: ",", omittingEmptySubsequences: false)
        return !roots.isEmpty && roots.count <= 256 && roots.allSatisfy { UUID(uuidString: String($0)) != nil }
    }

}

public struct WorkspaceCloudExchange: Sendable {
    public let accountScope: String
    public let peers: [WorkspaceCloudPeer]
    public let uploaded: Bool
}

/// One bounded graph asset per installation in a dedicated private zone. Revisions
/// inside the asset are immutable and unioned by identity. Filesystem directories,
/// service databases and credentials never enter this transport. Zone change tokens
/// avoid repeatedly downloading unchanged peers; no query indexes are required.
public actor WorkspaceCloudTransport {
    public static let recordType = "BWUnifiedWorkspace"
    public static let zoneName = "BetterWorkspace.Unified.v1"
    private let zoneID: CKRecordZone.ID
    private let containerID: String
    private var token: CKServerChangeToken?
    private var peers: [String: WorkspaceCloudPeer] = [:]
    private var account: String?
    private var uploadedFingerprint: String?
    /// The last replica fingerprinted, so an unchanged journal is not encoded again
    /// on every exchange.
    private var fingerprinted: (replica: WorkspaceReplica, value: String)?
    private func replicaFingerprint(_ replica: WorkspaceReplica) throws -> String {
        if let fingerprinted, fingerprinted.replica == replica { return fingerprinted.value }
        let value = try replica.fingerprint
        fingerprinted = (replica, value)
        return value
    }
    private var zoneReady = false
    public init(containerID: String = MobileCloudSchema.containerIdentifier, zoneName: String = WorkspaceCloudTransport.zoneName) {
        self.containerID = containerID; zoneID = CKRecordZone.ID(zoneName: zoneName, ownerName: CKCurrentUserDefaultName)
    }

    public static func userMessage(for error: Error) -> String {
        guard let error = error as? CKError else { return error.localizedDescription }
        switch error.code {
        case .networkUnavailable, .networkFailure, .serviceUnavailable, .requestRateLimited, .zoneBusy:
            return "iCloud could not be reached. Your changes are saved on this device and synchronization will retry. Check your connection and iCloud availability."
        case .notAuthenticated:
            return "Sign in to iCloud in system Settings to connect devices. Your local workspace is retained."
        case .missingEntitlement, .badContainer, .permissionFailure, .invalidArguments:
            return "Workspace synchronization needs a configuration update. Your records remain on this device. Contact support before relying on synchronization."
        default: return error.localizedDescription
        }
    }

    public func accountScope() async throws -> String {
        let container = CKContainer(identifier: containerID)
        guard try await container.accountStatus() == .available else {
            throw WorkspaceReplicaError.invalid("Sign in to iCloud in system Settings to connect devices. You can keep working on this device.")
        }
        let user = try await container.userRecordID().recordName
        return SHA256.hash(data: Data(user.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    public func exchange(_ local: WorkspaceCloudPeer, accountScope expected: String?) async throws -> WorkspaceCloudExchange {
        try local.validate()
        let container = CKContainer(identifier: containerID)
        guard try await container.accountStatus() == .available else {
            throw WorkspaceReplicaError.invalid("Saved on this device. Sign in to iCloud to synchronize; a Mac is optional.")
        }
        let user = try await container.userRecordID().recordName
        let scope = SHA256.hash(data: Data(user.utf8)).map { String(format: "%02x", $0) }.joined()
        guard expected == nil || expected == scope else {
            throw WorkspaceReplicaError.invalid("Your iCloud account changed. Synchronization is paused so these records are not sent to another account. Your local workspace is retained.")
        }
        if account != scope { account = scope; token = nil; peers = [:]; uploadedFingerprint = nil; zoneReady = false }
        let database = container.privateCloudDatabase
        if !zoneReady { _ = try await database.save(CKRecordZone(zoneID: zoneID)); zoneReady = true }
        do { try await fetch(database) }
        catch let error as CKError where error.code == .changeTokenExpired {
            token = nil; peers = [:]; try await fetch(database)
        } catch let error as CKError where error.code == .zoneNotFound {
            token = nil; peers = [:]; uploadedFingerprint = nil; zoneReady = false; throw error
        }
        let ownName = "device-" + local.deviceID.uuidString
        var outgoing = local
        if let old = peers[ownName] {
            // A restored device identity must not replace the only cloud copy of an
            // independently created workspace. Return it for explicit recovery review.
            guard old.replica.joinedWorkspaceIDs.isSubset(of: local.replica.joinedWorkspaceIDs) else {
                return .init(accountScope: scope, peers: Array(peers.values), uploaded: false)
            }
            outgoing = try Self.combined(local, with: old)
        }
        var fingerprint = try replicaFingerprint(outgoing.replica) + outgoing.approvals.map { $0.id.uuidString }.sorted().joined() + outgoing.name
        var uploaded = false
        if uploadedFingerprint != fingerprint {
            let id = CKRecord.ID(recordName: ownName, zoneID: zoneID)
            let record: CKRecord
            do { record = try await database.record(for: id) }
            catch let error as CKError where error.code == .unknownItem { record = CKRecord(recordType: Self.recordType, recordID: id) }
            // A second copy of this installation could have saved between the
            // zone fetch and this record fetch. Union that exact version before
            // writing with its change tag; a subsequent conflict is retried later.
            if let asset = record["snapshot"] as? CKAsset, let url = asset.fileURL {
                let latest = try Self.decode(at: url)
                guard latest.deviceID == local.deviceID, latest.replica.joinedWorkspaceIDs.isSubset(of: local.replica.joinedWorkspaceIDs) else {
                    peers[ownName] = latest
                    return .init(accountScope: scope, peers: Array(peers.values), uploaded: false)
                }
                outgoing = try Self.combined(outgoing, with: latest)
            } else if record.recordChangeTag != nil { throw WorkspaceReplicaError.invalid("The cloud workspace has an incomplete asset. Its previous data was retained.") }
            try outgoing.validate()
            fingerprint = try replicaFingerprint(outgoing.replica) + outgoing.approvals.map { $0.id.uuidString }.sorted().joined() + outgoing.name
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            let bytes = try encoder.encode(outgoing)
            guard bytes.count <= 64 * 1_024 * 1_024 else { throw WorkspaceReplicaError.invalid("This workspace exceeds the synchronization size limit.") }
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("bw-unified-upload-" + UUID().uuidString + ".json")
            try bytes.write(to: file, options: .withoutOverwriting)
            defer { try? FileManager.default.removeItem(at: file) }
            record["snapshot"] = CKAsset(fileURL: file)
            record["deviceID"] = local.deviceID.uuidString as CKRecordValue
            _ = try await database.save(record)
            peers[ownName] = outgoing; uploadedFingerprint = fingerprint; uploaded = true
        }
        return .init(accountScope: scope, peers: Array(peers.values), uploaded: uploaded)
    }

    /// Diagnostics only: every device's published workspace, read from a fresh zone fetch.
    /// Never creates the zone, uploads or changes the stored change token.
    public func publishedPeers() async throws -> [WorkspaceCloudPeer] {
        let container = CKContainer(identifier: containerID)
        guard try await container.accountStatus() == .available else { throw WorkspaceReplicaError.invalid("Sign in to iCloud to read device workspaces.") }
        let (savedToken, savedPeers) = (token, peers)
        defer { token = savedToken; peers = savedPeers }
        token = nil; peers = [:]
        try await fetch(container.privateCloudDatabase)
        return Array(peers.values)
    }

    static func combined(_ local: WorkspaceCloudPeer, with other: WorkspaceCloudPeer) throws -> WorkspaceCloudPeer {
        try local.validate(); try other.validate()
        guard local.deviceID == other.deviceID, other.replica.joinedWorkspaceIDs.isSubset(of: local.replica.joinedWorkspaceIDs) else { throw WorkspaceReplicaError.changed }
        let normalized = try WorkspaceReplica(workspaceID: local.replica.workspaceID, revisions: other.replica.revisions, joinedWorkspaceIDs: local.replica.joinedWorkspaceIDs)
        var grants = Dictionary(uniqueKeysWithValues: local.approvals.map { ($0.id, $0) })
        for grant in other.approvals {
            if let old = grants[grant.id], old != grant { throw WorkspaceReplicaError.revisionCollision }
            grants[grant.id] = grant
        }
        let result = WorkspaceCloudPeer(deviceID: local.deviceID, sourceID: local.sourceID, name: local.name, platform: local.platform,
            replica: try local.replica.merging(normalized), approvals: grants.values.sorted { $0.id.uuidString < $1.id.uuidString })
        try result.validate(); return result
    }
    private static func decode(at url: URL) throws -> WorkspaceCloudPeer {
        guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) <= 64 * 1_024 * 1_024 else { throw WorkspaceReplicaError.invalid("A device workspace exceeds the download size limit.") }
        let peer = try JSONDecoder().decode(WorkspaceCloudPeer.self, from: Data(contentsOf: url))
        try peer.validate(); return peer
    }

    private func fetch(_ database: CKDatabase) async throws {
        var candidate = peers, cursor = token, more = true, pages = 0
        while more {
            pages += 1
            guard pages <= 100 else { throw WorkspaceReplicaError.invalid("The device list exceeds its synchronization limit.") }
            let page = try await database.recordZoneChanges(inZoneWith: zoneID, since: cursor, resultsLimit: 50)
            for (id, result) in page.modificationResultsByID {
                let record = try result.get().record
                guard record.recordType == Self.recordType else { continue }
                guard let asset = record["snapshot"] as? CKAsset, let file = asset.fileURL else {
                    throw WorkspaceReplicaError.invalid("A device workspace could not be downloaded completely. The last local copy is retained.")
                }
                let peer = try Self.decode(at: file)
                guard id.recordName == "device-" + peer.deviceID.uuidString else { throw WorkspaceReplicaError.revisionCollision }
                candidate[id.recordName] = peer
            }
            // Removing a device advertisement never deletes its merged records.
            for deleted in page.deletions { candidate.removeValue(forKey: deleted.recordID.recordName) }
            cursor = page.changeToken; more = page.moreComing
        }
        guard candidate.count <= 50 else { throw WorkspaceReplicaError.invalid("Review the connected device list before adding more devices.") }
        peers = candidate; token = cursor
    }
}
