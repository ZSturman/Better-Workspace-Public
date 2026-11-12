import XCTest
import CloudKit
@testable import BetterWorkspaceCore

/// Explicit live acceptance only. Ordinary test runs cannot enable this path.
/// Each run owns one UUID zone and local stores; personal stores and the normal
/// transport zone are never opened. This tests actual networking on the host
/// device, not physical peer discovery or another device's UI.
@MainActor
final class WorkspaceLiveCloudTests: XCTestCase {
    func testReviewedJoinOfflineConflictAndReplayWithLiveTransport() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["BW_RUN_UNIFIED_CLOUD_ACCEPTANCE"] == "1",
                          "Requires the explicit signed live-cloud acceptance scheme")
        let run = UUID()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bw-live-cloud-" + run.uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let zoneName = "BWUnifiedAcceptance-" + run.uuidString
        // Persist the exact cleanup target before the first network operation.
        let receipt = try JSONSerialization.data(withJSONObject: ["zoneName": zoneName])
        try receipt.write(to: root.appendingPathComponent("cloud-zone.json"), options: .withoutOverwriting)
        let database = CKContainer(identifier: MobileCloudSchema.containerIdentifier).privateCloudDatabase
        let zone = CKRecordZone.ID(zoneName: zoneName, ownerName: CKCurrentUserDefaultName)
        func cleanup() async throws {
            do { _ = try await database.deleteRecordZone(withID: zone) }
            catch let error as CKError where error.code == .zoneNotFound || error.code == .unknownItem { }
            try FileManager.default.removeItem(at: root)
        }
        do {
            let session = try await WorkspaceSession.open(directory: root.appendingPathComponent("Local"), fixture: true)
            let local = try await session.save(content: .init(kind: .note, title: "Same name", body: "Synthetic local content"), expectedHeads: [])
            var remote = try WorkspaceReplica()
            let device = UUID(), source = remote.workspaceID
            let base = try remote.save(content: .init(kind: .note, title: "Same name", body: "Synthetic Mac content"), expectedHeads: [], deviceID: device, origin: .mac)
            let mac = WorkspaceCloudTransport(zoneName: zoneName)
            let client = WorkspaceCloudTransport(zoneName: zoneName)
            let scope = try await client.accountScope()
            func remotePayload() -> WorkspaceCloudPeer {
                .init(deviceID: device, sourceID: source, name: "Synthetic Mac", platform: "Mac", replica: remote, approvals: [])
            }
            _ = try await mac.exchange(remotePayload(), accountScope: scope)
            let delivery = try await client.exchange(session.payload(), accountScope: scope)
            try await session.receive(delivery.peers)
            XCTAssertEqual(session.records.count, 1, "A network delivery must not approve the initial merge")
            let peer = try XCTUnwrap(session.pendingPeers.first { $0.deviceID == device })
            _ = try await session.approve(peer, preview: session.review(peer))
            XCTAssertEqual(session.records.count, 2)
            XCTAssertEqual(Set(session.replica.displayTitles.values).count, 2, "Same-name unrelated notes must both remain visible")
            XCTAssertEqual(try session.checkpoints().count, 1)
            _ = try await client.exchange(session.payload(), accountScope: scope)

            // Save and reopen without exchanging: both edits descend from the
            // same baseline, so neither clock nor arrival order can pick a winner.
            var phoneEdit = base.content; phoneEdit.body = "Offline local edit"
            _ = try await session.save(recordID: base.recordID, content: phoneEdit, expectedHeads: [base.id])
            let reopened = try await WorkspaceSession.open(directory: root.appendingPathComponent("Local"), fixture: true)
            XCTAssertEqual(reopened.records.first { $0.id == base.recordID }?.resolved?.content.body, phoneEdit.body)
            var macEdit = base.content; macEdit.body = "Concurrent Mac edit"
            _ = try remote.save(recordID: base.recordID, content: macEdit, expectedHeads: [base.id], deviceID: device, origin: .mac)
            _ = try await mac.exchange(remotePayload(), accountScope: scope)
            try await reopened.receive(client.exchange(reopened.payload(), accountScope: scope).peers)
            let conflict = try XCTUnwrap(reopened.records.first { $0.id == base.recordID })
            XCTAssertTrue(conflict.isConflict)
            XCTAssertEqual(Set(conflict.heads.map { $0.content.body }), [phoneEdit.body, macEdit.body])
            XCTAssertEqual(reopened.records.first { $0.id == local.recordID }?.resolved?.content, local.content)

            let fingerprint = try reopened.replica.fingerprint
            let freshClient = WorkspaceCloudTransport(zoneName: zoneName)
            try await reopened.receive(freshClient.exchange(reopened.payload(), accountScope: scope).peers)
            XCTAssertEqual(try reopened.replica.fingerprint, fingerprint, "Fresh-client replay must not add revisions or drop either version")
            XCTAssertFalse(reopened.cloudEnabled, "The fixture never enables the normal application transport")
        } catch {
            do { try await cleanup() }
            catch { XCTFail("Owned cloud cleanup is unconfirmed; retain the exact receipt at \(root.path)") }
            throw error
        }
        try await cleanup()
    }
}
