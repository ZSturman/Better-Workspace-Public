import XCTest
@testable import BetterWorkspaceCore

final class ProjectControlTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("bw-project-control-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Projects/P"), withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { if let root { try FileManager.default.removeItem(at: root) } }

    func testMobileProjectSavePersistsRatingsAndDescriptionWithIdempotentRetry() throws {
        let dbURL = root.appendingPathComponent("private.sqlite")
        let db = try Database(url: dbURL), store = ProjectStore(database: db)
        let record = store.register(url: root.appendingPathComponent("Projects/P"))
        store.markDiscovered(record.id)
        let original = MobileProjectDetails(path: "Projects/P", projectID: record.id, ratings: [:])
        let change = MobileProjectEdit(original: original, ratings: ["qualityOfLife": 5, "effort": 1], oneLiner: "A useful plan", summary: "Longer notes")
        try store.saveMobileProject(change)
        try store.saveMobileProject(change)
        let reloaded = ProjectStore(database: try Database(url: dbURL))
        XCTAssertEqual(reloaded.ratings(for: record.id), change.ratings)
        XCTAssertEqual(reloaded.description(for: record.id).oneLiner, change.oneLiner)
        XCTAssertFalse(reloaded.needsSetup(record.id))
        reloaded.markDiscovered(record.id)
        XCTAssertFalse(reloaded.needsSetup(record.id), "Completed setup must not reappear after relaunch")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("Projects/P").path), [], "Project originals remain untouched")
    }

    func testConcurrentMacEditRefusesEntireMobileSaveWithoutLosingRatings() throws {
        let store = ProjectStore(database: try Database(inMemory: true))
        let record = store.register(url: root.appendingPathComponent("Projects/P"))
        store.markDiscovered(record.id)
        let original = MobileProjectDetails(path: "Projects/P", projectID: record.id, ratings: [:])
        store.setDescription(ProjectDescription(oneLiner: "Changed on Mac", summary: nil), for: record.id)
        let change = MobileProjectEdit(original: original, ratings: ["qualityOfLife": 5], oneLiner: "Phone", summary: "")
        XCTAssertThrowsError(try store.saveMobileProject(change))
        XCTAssertEqual(store.description(for: record.id).oneLiner, "Changed on Mac")
        XCTAssertTrue(store.ratings(for: record.id).isEmpty)
    }

    func testRatingsCanBeClearedAndInvalidOrForeignProjectChangesAreRejected() throws {
        let store = ProjectStore(database: try Database(inMemory: true))
        let record = store.register(url: root.appendingPathComponent("Projects/P"))
        store.setRating(4, metricID: "qualityOfLife", for: record.id)
        let original = MobileProjectDetails(path: "Projects/P", projectID: record.id, ratings: ["qualityOfLife": 4])
        try store.saveMobileProject(MobileProjectEdit(original: original, ratings: [:], oneLiner: "", summary: ""))
        XCTAssertTrue(store.ratings(for: record.id).isEmpty)
        XCTAssertThrowsError(try MobileProjectEdit(original: original, ratings: ["qualityOfLife": 6], oneLiner: "", summary: "").validate())
        XCTAssertThrowsError(try MobileProjectEdit(original: original, ratings: ["invented": 3], oneLiner: "", summary: "").validate())
        let foreign = MobileProjectDetails(path: "Ideas/P", projectID: record.id, ratings: [:])
        XCTAssertThrowsError(try store.saveMobileProject(MobileProjectEdit(original: foreign, ratings: [:], oneLiner: "", summary: "")))
    }

    func testProjectEnvelopeCarriesScoresPreviewsAndSetupThroughExistingCloudField() throws {
        let details = MobileProjectDetails(path: "Projects/P", oneLiner: "Readable by old phones", projectID: "p", ratings: ["qualityOfLife": 5],
            scoringPreferences: ProjectScoringPreferences(), needsSetup: true,
            previews: [MobileFilePreview(path: "Projects/P/README.md", name: "README.md", text: "Actual excerpt", jpeg: Data([1,2,3]))])
        XCTAssertEqual(MobileProjectEnvelope.decode(MobileProjectEnvelope.encode(details)), details)
        let encoded = try XCTUnwrap(MobileProjectEnvelope.encode(details))
        for _ in 0..<5 { XCTAssertEqual(MobileProjectEnvelope.encode(try XCTUnwrap(MobileProjectEnvelope.decode(encoded))), encoded, "Set iteration must not cause unchanged CloudKit records to republish") }
        let old = try JSONDecoder().decode(MobileProjectDetails.self, from: Data(#"{"path":"Projects/P","oneLiner":"Old"}"#.utf8))
        XCTAssertNil(old.ratings); XCTAssertNil(old.previews); XCTAssertNil(old.needsSetup)
        XCTAssertNil(MobileProjectEnvelope.decode(OverviewDigest().encoded))
        XCTAssertNil(MobileProjectEnvelope.decode("broken JSON"))
    }

    func testHighestScoredActionableProjectWinsOnBothPlatformsAndWidgets() {
        let low = WorkItem(id: "low", kind: .task, title: "Low now", stage: .now, priority: .high, projectPath: "Projects/Low", url: root.appendingPathComponent("low"))
        let high = WorkItem(id: "high", kind: .task, title: "High next", stage: .next, priority: .low, projectPath: "Projects/High", url: root.appendingPathComponent("high"))
        let scores = ["Projects/High": 90.0, "Projects/Low": 60.0]
        XCTAssertEqual(WorkItemRecommendation.nextAction(in: [low, high], projectScores: scores)?.id, "high")
        let phone = [low, high].map { item in MobileWorkItem(id: item.id, path: item.id, title: item.title, kind: .task, status: item.status, stage: item.stage, priority: item.priority, projectPath: item.projectPath, revision: 1) }
        XCTAssertEqual(WorkItemRecommendation.nextMobileAction(in: phone, projectScores: scores)?.id, "high")
        let entries = scores.map { path, score in MobileWorkspaceEntry(path: path, parentPath: "Projects", name: path, isDirectory: true, revision: 1,
            projectDetails: MobileProjectDetails(path: path, manualScore: score, ratingCoverage: 0.1)) }
        let dashboard = WorkspaceDashboardSnapshot.make(from: MobileWorkspaceSnapshot(entries: entries, workItems: phone))
        XCTAssertEqual(dashboard.tasks(queue: .next).map(\.id), ["high", "low"], "Even partial scores must have the same priority on the widget")
    }

    func testScoreRankingStillRespectsLaterCompletionDependenciesAndBlocks() {
        var high = WorkItem(id: "high", kind: .task, title: "High", stage: .next, priority: .high, projectPath: "Projects/High", url: root.appendingPathComponent("high"))
        let low = WorkItem(id: "low", kind: .task, title: "Low", stage: .now, projectPath: "Projects/Low", url: root.appendingPathComponent("low"))
        let scores = ["Projects/High": 99.0, "Projects/Low": 50.0]
        high.stage = .later
        XCTAssertEqual(WorkItemRecommendation.nextAction(in: [low, high], projectScores: scores)?.id, "low")
        high.stage = .next; high.status = .completed
        XCTAssertEqual(WorkItemRecommendation.nextAction(in: [low, high], projectScores: scores)?.id, "low")
        high.status = .open; high.dependencyIDs = ["missing"]
        XCTAssertEqual(WorkItemRecommendation.nextAction(in: [low, high], projectScores: scores)?.id, "low")
        high.dependencyIDs = ["done"]
        let done = WorkItem(id: "done", kind: .task, title: "Done", status: .completed, url: root.appendingPathComponent("done"))
        XCTAssertEqual(WorkItemRecommendation.nextAction(in: [low, high], allItems: [low, high, done], projectScores: scores)?.id, "high")
        high.actionMetadata = WorkItemActionMetadata(fingerprint: "fixture", priority: "P1", actionScore: 90, delegation: "USER", tags: ["test"], requirements: [], agentExecutability: 0, humanInvolvement: 100, estimatedEffort: "Small", category: "Test", reason: "Waiting", evidence: ["Fixture"], agentSubtasks: [], userSubtasks: ["Review"], blockedBy: ["Waiting"], isNextWork: true, isNextAgentAction: false, isNextUserAction: true)
        XCTAssertEqual(WorkItemRecommendation.nextAction(in: [low, high], allItems: [low, high, done], projectScores: scores)?.id, "low")
    }

    func testNewProjectNoticeSurvivesRestartAndRanksAheadOfOldActivity() throws {
        let dbURL = root.appendingPathComponent("private.sqlite")
        let store = ProjectStore(database: try Database(url: dbURL))
        let record = store.register(url: root.appendingPathComponent("Projects/P")); store.markDiscovered(record.id)
        XCTAssertTrue(ProjectStore(database: try Database(url: dbURL)).needsSetup(record.id))
        var input = Attention.Input()
        input.projects = [Attention.Input.Project(name: "New P", path: "Projects/P", contentModifiedAt: nil, score: nil, ratedCount: 0, lastSessionAt: nil, observedHours: nil, needsSetup: true)]
        input.pendingIngestCount = 8
        let first = Attention.evaluate(input).first
        XCTAssertEqual(first?.target, .project(path: "Projects/P"))
        XCTAssertTrue(first?.explanation.contains("new project created") == true)
        store.setRating(5, metricID: "qualityOfLife", for: record.id)
        XCTAssertFalse(store.needsSetup(record.id))
    }

    func testIngestScheduleAndPrioritySurviveRefreshAndBecomeDueWithoutFileEdits() async throws {
        let inbox = root.appendingPathComponent("Inbox")
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        let db = try Database(inMemory: true), tags = TagStore(database: db)
        let service = IngestService(location: IngestLocation(inbox: inbox, backing: .local), database: db, tagStore: tags, workspace: WorkspaceLocation(root: root))
        let first = try service.captureText("First", source: .quickCapture)
        let second = try service.captureText("Second", source: .quickCapture)
        let bytes = try Data(contentsOf: first.url)
        try service.schedule(first, priority: 5, until: Date().addingTimeInterval(86_400))
        try service.schedule(second, priority: 1, until: nil)
        let fs = FilesystemService()
        let listed = await service.pendingItems(fsService: fs)
        let items = try XCTUnwrap(listed)
        XCTAssertEqual(items.first?.id, second.id, "A future high-priority capture must stay behind due work")
        let scheduled = try XCTUnwrap(items.first { $0.id == first.id })
        XCTAssertEqual(scheduled.priority, 5); XCTAssertFalse(scheduled.isDue)
        try service.schedule(scheduled, priority: 5, until: Date().addingTimeInterval(-1))
        let listedDue = await service.pendingItems(fsService: fs)
        let due = try XCTUnwrap(listedDue)
        XCTAssertEqual(due.first?.id, first.id); XCTAssertTrue(due.first?.isDue == true)
        XCTAssertEqual(try Data(contentsOf: first.url), bytes)
        XCTAssertThrowsError(try service.schedule(first, priority: 6, until: nil))
    }
}
