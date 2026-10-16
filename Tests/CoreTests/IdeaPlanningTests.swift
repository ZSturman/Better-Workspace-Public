import XCTest
@testable import BetterWorkspaceCore

final class IdeaPlanningTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("bw-idea-planning-\(UUID().uuidString)")
        for area in ["Ideas", "Projects", "Features", "Milestones"] { try FileManager.default.createDirectory(at: root.appendingPathComponent(area), withIntermediateDirectories: true) }
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }
    private func idea(_ name: String = "Studio") throws -> MobileIdea {
        let url = root.appendingPathComponent("Ideas/" + name)
        try FileManager.default.createDirectory(at: url.appendingPathComponent("Media"), withIntermediateDirectories: true)
        try "Original media".write(to: url.appendingPathComponent("Media/Original.txt"), atomically: true, encoding: .utf8)
        let modified = try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        return MobileIdea(path: "Ideas/" + name, title: name, revision: 1, modifiedAt: modified, serviceID: "idea", planning: IdeaPlanning(priority: 5, ratings: ["qualityOfLife": 5], potential: .project))
    }
    func testPotentialTypeAndScoringRemainIdeaDataAndRankByPriorityThenScore() throws {
        let low = MobileIdea(path: "Ideas/Low", title: "Low", revision: 1, planning: IdeaPlanning(priority: 1, ratings: ["qualityOfLife": 5], potential: .project))
        let important = MobileIdea(path: "Ideas/Important", title: "Important", revision: 1, planning: IdeaPlanning(priority: 5, potential: .feature))
        XCTAssertTrue(IdeaRanking.comesFirst(important, low))
        let better = MobileIdea(path: "Ideas/Better", title: "Better", revision: 1, planning: IdeaPlanning(priority: 1, ratings: ["qualityOfLife": 5, "effort": 1], potential: .milestone))
        XCTAssertTrue(IdeaRanking.comesFirst(better, low))
        let snapshot = MobileWorkspaceSnapshot(ideas: [low, important, better])
        XCTAssertTrue(snapshot.entries.isEmpty); XCTAssertTrue(snapshot.workItems.isEmpty)
        XCTAssertEqual(try JSONDecoder().decode(MobileWorkspaceSnapshot.self, from: JSONEncoder().encode(snapshot)).ideas, snapshot.ideas)
    }
    func testIdeaPlanningSurvivesMobileProjectionAndOldAttachmentArraysStillDecode() throws {
        let original = try idea()
        let url = root.appendingPathComponent(original.path)
        let item = WorkspaceItem(url: url, name: "Studio", isDirectory: true, kind: .folder, identity: nil, byteSize: 0, createdAt: nil, rawModifiedAt: original.modifiedAt, contentModifiedAt: original.modifiedAt, immediateChildCount: 1)
        let input = MobileWorkspaceLocalSnapshot(itemsByArea: ["Ideas": [item]], workItems: [], tags: [], tagsByPath: [:], ideaDetailsByPath: [original.path: original])
        let candidate = try XCTUnwrap(MobileWorkspaceProjection.candidates(from: input, workspace: WorkspaceLocation(root: root)).compactMap { candidate -> MobileIdea? in if case .idea(let idea) = candidate { return idea }; return nil }.first)
        XCTAssertEqual(candidate.planning, original.planning)
        XCTAssertEqual(MobileIdeaEnvelope.decode(MobileIdeaEnvelope.encode(candidate))?.planning, original.planning)
        XCTAssertEqual(MobileIdeaEnvelope.decode(#"[{"path":"Ideas/P/Photo.png","name":"Photo.png","isDirectory":false}]"#)?.attachments.first?.name, "Photo.png")
    }
    func testPromotionMovesWholeFolderAndRetryNeverDuplicatesAttachments() throws {
        let original = try idea()
        let workspace = WorkspaceLocation(root: root)
        let checkpoint = try IdeaPromotionFiles.move(original, kind: .project, workspace: workspace, checkpoint: nil)
        try IdeaPromotionFiles.apply(checkpoint)
        try IdeaPromotionFiles.apply(checkpoint)
        let resumed = try IdeaPromotionFiles.move(original, kind: .project, workspace: workspace, checkpoint: checkpoint)
        XCTAssertEqual(resumed, checkpoint)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(original.path).path))
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("Projects/Studio/Media/Original.txt"), encoding: .utf8), "Original media")
    }
    func testFeatureAndMilestoneMovesRefuseExistingTargetsAndStaleSource() throws {
        let original = try idea()
        let workspace = WorkspaceLocation(root: root)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Features/Studio"), withIntermediateDirectories: false)
        XCTAssertThrowsError(try IdeaPromotionFiles.move(original, kind: .feature, workspace: workspace, checkpoint: nil))
        var stale = original
        stale = MobileIdea(path: original.path, title: original.title, revision: 1, modifiedAt: .distantPast)
        XCTAssertThrowsError(try IdeaPromotionFiles.move(stale, kind: .milestone, workspace: workspace, checkpoint: nil))
        let checkpoint = try IdeaPromotionFiles.move(original, kind: .milestone, workspace: workspace, checkpoint: nil)
        try IdeaPromotionFiles.apply(checkpoint)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("Milestones/Studio/Media/Original.txt").path))
    }
    func testPromotionRejectsSymlinksAndForeignMetadataPaths() throws {
        let original = try idea()
        let workspace = WorkspaceLocation(root: root)
        let link = root.appendingPathComponent("Ideas/Link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root.appendingPathComponent(original.path))
        let symlink = MobileIdea(path: "Ideas/Link", title: "Link", revision: 1, modifiedAt: original.modifiedAt)
        XCTAssertThrowsError(try IdeaPromotionFiles.move(symlink, kind: .project, workspace: workspace, checkpoint: nil))
        let foreign = MobileIdea(path: "Ideas/_audit", title: "Protected", revision: 1, modifiedAt: Date())
        XCTAssertThrowsError(try IdeaPromotionFiles.move(foreign, kind: .project, workspace: workspace, checkpoint: nil))
    }
    func testProjectDowngradeAndRePromotionRetainPrivateRatingsAndNestedTags() throws {
        let url = root.appendingPathComponent("Projects/Former project")
        try FileManager.default.createDirectory(at: url.appendingPathComponent("Media"), withIntermediateDirectories: true)
        try "Original".write(to: url.appendingPathComponent("Media/Photo.txt"), atomically: true, encoding: .utf8)
        let db = try Database(inMemory: true), projects = ProjectStore(database: db), tags = TagStore(database: db)
        let record = projects.register(url: url); projects.setRating(5, metricID: "qualityOfLife", for: record.id)
        let tag = try XCTUnwrap(tags.createTag(named: "Important"))
        tags.assign(tagID: tag.id, to: url.appendingPathComponent("Media/Photo.txt"), area: "Projects")
        let downgraded = root.appendingPathComponent("Ideas/Former project")
        try FileManager.default.moveItem(at: url, to: downgraded)
        XCTAssertEqual(projects.ratings(for: record.id)["qualityOfLife"], 5)
        let original = MobileIdea(path: "Ideas/Former project", title: "Former project", revision: 1, modifiedAt: try downgraded.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
        let checkpoint = try IdeaPromotionFiles.move(original, kind: .project, workspace: WorkspaceLocation(root: root), checkpoint: nil)
        try IdeaPromotionFiles.apply(checkpoint)
        XCTAssertEqual(projects.register(url: url).id, record.id)
        try tags.rebindKnownPaths(from: downgraded, to: url, area: "Projects")
        XCTAssertEqual(tags.tags(for: url.appendingPathComponent("Media/Photo.txt")).map(\.id), [tag.id])
    }
}
