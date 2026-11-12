import XCTest
@testable import BetterWorkspaceCore

/// Volume device numbers change across restarts; identities and the Mac's reviewed
/// source must not.
final class FileIdentityStabilityTests: XCTestCase {
    func testIdentityNamesTheVolumeByUUIDAndToleratesLegacyDeviceNumbers() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bw-identity-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let current = try XCTUnwrap(FileIdentityResolver.identity(of: root))
        XCTAssertTrue(current.volume.hasPrefix("uuid-"), "A stable volume identifier, not a device number")
        XCTAssertFalse(current.hasLegacyVolume)

        let legacy = FileIdentity(volume: "16777234", fileID: current.fileID)
        XCTAssertEqual(legacy, current, "A record from before a restart still names this folder")
        XCTAssertEqual(Set([legacy, current]).count, 1)
        XCTAssertNotEqual(FileIdentity(volume: "uuid-OTHER", fileID: current.fileID), current, "Another volume is another file")
        XCTAssertNotEqual(FileIdentity(volume: "16777234", fileID: current.fileID + 1), current)
        // Older stored JSON still decodes.
        let decoded = try JSONDecoder().decode(FileIdentity.self, from: Data(#"{"fileID":\#(current.fileID),"volume":"16777231"}"#.utf8))
        XCTAssertEqual(decoded, current)
    }

    func testMacSourceReviewedBeforeARestartIsStillFound() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bw-source-\(UUID().uuidString)")
        let workspace = root.appendingPathComponent("Workspace")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try Database(url: root.appendingPathComponent("private.sqlite"))
        let store = try WorkspaceMacReceiptStore(database: database)
        let device = UUID()
        let current = try XCTUnwrap(FileIdentityResolver.identity(of: workspace))
        // As recorded by an earlier build, before the Mac restarted.
        let legacyIdentity = FileIdentity(volume: "16777234", fileID: current.fileID)
        let legacyID = try WorkspaceMacReceiptStore.derive(deviceID: device, identity: legacyIdentity)
        let receipt = WorkspaceMacObservationReceipt(version: 1, id: UUID(), sourceID: legacyID, workspaceID: UUID(),
                                                     rootIdentity: legacyIdentity, bindings: [])
        try database.run("INSERT INTO workspace_mac_observations(source_id, receipt) VALUES(?, ?)",
                         [.text(legacyID.uuidString), .text(String(decoding: try JSONEncoder().encode(receipt), as: UTF8.self))])

        XCTAssertNotEqual(try WorkspaceMacReceiptStore.sourceID(deviceID: device, sourceRoot: workspace), legacyID)
        XCTAssertEqual(try WorkspaceMacReceiptStore.sourceID(deviceID: device, sourceRoot: workspace, database: database), legacyID)
        XCTAssertNoThrow(try store.validateRoot(try XCTUnwrap(store.load(sourceID: legacyID)), sourceRoot: workspace))
        // A later observation keeps the recorded root, so the source is found again.
        let reloaded = try XCTUnwrap(store.load(sourceID: legacyID))
        let graph = WorkspaceReplicaStore(directory: root.appendingPathComponent("graph"), initialWorkspaceID: receipt.workspaceID)
        _ = try? store.commit(.init(replica: try graph.load(), bindings: []), sourceID: legacyID, sourceRoot: workspace,
                              expectedReceiptID: reloaded.id, graph: graph)
        XCTAssertTrue(try XCTUnwrap(store.load(sourceID: legacyID)).rootIdentity.hasLegacyVolume)
        XCTAssertEqual(try WorkspaceMacReceiptStore.sourceID(deviceID: device, sourceRoot: workspace, database: database), legacyID)
        // Another device's receipt for the same folder is never adopted.
        XCTAssertNotEqual(try WorkspaceMacReceiptStore.sourceID(deviceID: UUID(), sourceRoot: workspace, database: database), legacyID)
    }
}
