import XCTest
@testable import BetterWorkspaceCore

final class IdeaPromotionRecoveryTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("bw-promotion-recovery-\(UUID())")
        for area in ["Ideas", "Projects"] { try FileManager.default.createDirectory(at: root.appendingPathComponent(area), withIntermediateDirectories: true) }
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }
    private func checkpoint() throws -> IdeaPromotionCheckpoint {
        let source = root.appendingPathComponent("Ideas/Studio")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
        try "Original".write(to: source.appendingPathComponent("Note.txt"), atomically: true, encoding: .utf8)
        let idea = MobileIdea(path: "Ideas/Studio", title: "Studio", revision: 1, modifiedAt: try source.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
        return try IdeaPromotionFiles.move(idea, kind: .project, workspace: WorkspaceLocation(root: root), checkpoint: nil)
    }
    func testPersistedCheckpointResumesAfterRenameWithoutDuplicatingFolder() throws {
        let original = try checkpoint()
        let resumed = try JSONDecoder().decode(IdeaPromotionCheckpoint.self, from: JSONEncoder().encode(original))
        try IdeaPromotionFiles.apply(resumed)
        try IdeaPromotionFiles.apply(resumed)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("Projects/Studio/Note.txt")), "Original")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Ideas/Studio").path))
    }
    func testDestinationCreatedAfterReviewCannotBeOverwritten() throws {
        let move = try checkpoint(), destination = root.appendingPathComponent("Projects/Studio")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        try "Keep destination".write(to: destination.appendingPathComponent("Keep.txt"), atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try IdeaPromotionFiles.apply(move))
        XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("Keep.txt")), "Keep destination")
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("Ideas/Studio/Note.txt")), "Original")
    }
    func testChangedSourceAfterCheckpointIsRefused() throws {
        let move = try checkpoint(), source = root.appendingPathComponent("Ideas/Studio")
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(30)], ofItemAtPath: source.path)
        XCTAssertThrowsError(try IdeaPromotionFiles.apply(move))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.appendingPathComponent("Note.txt").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Projects/Studio").path))
    }
    func testAReplacementAtTheDestinationIsNotClaimedAsOurSuccessfulMove() throws {
        let move = try checkpoint(), destination = root.appendingPathComponent("Projects/Studio")
        try IdeaPromotionFiles.apply(move)
        try FileManager.default.moveItem(at: destination, to: root.appendingPathComponent("Projects/Renamed"))
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        XCTAssertThrowsError(try IdeaPromotionFiles.apply(move))
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("Projects/Renamed/Note.txt")), "Original")
    }
}
