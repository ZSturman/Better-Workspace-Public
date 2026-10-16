import XCTest
@testable import BetterWorkspaceCore

final class ProjectPortfolioPersistenceTests: XCTestCase {
    func testMetadataAndRelationsSurviveProjectRename() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bw-portfolio-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = ProjectStore(database: try Database(url: root.appendingPathComponent("private.sqlite")))
        let original = root.appendingPathComponent("Original")
        let related = root.appendingPathComponent("Related")
        try FileManager.default.createDirectory(at: original, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: related, withIntermediateDirectories: true)

        let record = store.register(url: original)
        let relatedRecord = store.register(url: related)
        let metadata = ProjectMetadata(domain: "Product", status: "Active", phase: "Build",
                                       currentWork: ["Implementation"], blockers: ["Awaiting review"],
                                       portfolioPriority: 4)
        store.setMetadata(metadata, for: record.id)
        store.setRelatedProjectIDs([relatedRecord.id], for: record.id)

        let renamed = root.appendingPathComponent("Renamed")
        try FileManager.default.moveItem(at: original, to: renamed)
        let resolved = try XCTUnwrap(store.record(for: renamed))

        XCTAssertEqual(resolved.id, record.id)
        XCTAssertEqual(store.metadata(for: resolved.id), metadata)
        XCTAssertEqual(store.relatedProjectIDs(for: resolved.id), [relatedRecord.id])
    }

    func testEmptyMetadataDeletesItsPrivateRecord() throws {
        let store = ProjectStore(database: try Database(inMemory: true))
        let record = store.register(url: URL(fileURLWithPath: "/tmp/metadata-project"))
        store.setMetadata(ProjectMetadata(domain: "Personal"), for: record.id)
        XCTAssertEqual(store.metadata(for: record.id).domain, "Personal")
        store.setMetadata(ProjectMetadata(), for: record.id)
        XCTAssertEqual(store.metadata(for: record.id), ProjectMetadata())
    }

    func testPortfolioReferencesRoundTripWithoutTouchingProjectFiles() throws {
        let store = ProjectStore(database: try Database(inMemory: true))
        let record = store.register(url: URL(fileURLWithPath: "/tmp/portfolio-references"))
        let details = ProjectPortfolioDetails(
            githubURL: "https://github.com/example/project",
            websiteURL: "https://example.com/project",
            resourceReferences: ["resource-2", "resource-1"],
            collectionReferences: ["collection-1"], mediaReferences: ["media-1"]
        )
        store.setPortfolioDetails(details, for: record.id)
        XCTAssertEqual(store.portfolioDetails(for: record.id), details)
    }

    func testScoringPreferencesRoundTripWithoutChangingDefaultWeights() throws {
        let store = ProjectStore(database: try Database(inMemory: true))
        var preferences = ProjectScoringPreferences()
        preferences.enabledMetricIDs.remove(MetricDefinition.qualityOfLife.id)
        preferences.groupWeights[MetricGroup.personalValue.id] = 25
        store.setScoringPreferences(preferences)
        XCTAssertEqual(store.scoringPreferences(), preferences)
        XCTAssertEqual(ProjectScoringPreferences().groupWeights, MetricGroup.defaultWeights)
    }
}

final class ProjectPortfolioDecisionTests: XCTestCase {
    private let preferences = ProjectScoringPreferences()
    private let placeholder = URL(fileURLWithPath: "/tmp/portfolio-test.bw.md")

    private func candidate(_ id: String, name: String, status: String? = "Active",
                           stage: WorkItemStage = .next, priority: WorkItemPriority = .medium,
                           dueDate: Date? = nil, portfolioPriority: Int? = nil,
                           ratings: [String: Int] = [:]) -> ProjectPortfolio.Candidate {
        ProjectPortfolio.Candidate(
            id: id, name: name, metadata: ProjectMetadata(status: status, portfolioPriority: portfolioPriority),
            score: ProjectScore(ratings: ratings),
            nextAction: WorkItem(id: id + "-work", kind: .task, title: name + " work", stage: stage,
                                 priority: priority, dueDate: dueDate, url: placeholder),
            activityAgeDays: nil
        )
    }

    func testRecommendationUsesNowThenPriorityThenStableName() {
        let nowLow = candidate("a", name: "Alpha", stage: .now, priority: .low)
        let nowHigh = candidate("b", name: "Beta", stage: .now, priority: .high)
        let nextHigh = candidate("c", name: "Gamma", stage: .next, priority: .high)
        XCTAssertEqual(ProjectPortfolio.recommend([nextHigh, nowLow, nowHigh], preferences: preferences)?.candidate.id, "b")
    }

    func testRecommendationUsesEarlierDueDateBeforeScoresAndName() {
        let later = candidate("later", name: "Alpha", stage: .now, priority: .high,
                              dueDate: Date(timeIntervalSince1970: 200))
        let earlier = candidate("earlier", name: "Zulu", stage: .now, priority: .high,
                                dueDate: Date(timeIntervalSince1970: 100))
        let undated = candidate("undated", name: "Aardvark", stage: .now, priority: .high)

        XCTAssertEqual(ProjectPortfolio.recommend([later, undated, earlier], preferences: preferences)?.candidate.id, "earlier")
    }

    func testRecommendationExcludesBlockedAndCompletedProjects() {
        let blocked = candidate("blocked", name: "Blocked", status: "Blocked", stage: .now, priority: .high)
        let completed = candidate("done", name: "Done", status: "Completed", stage: .now, priority: .high)
        let eligible = candidate("eligible", name: "Eligible", stage: .next, priority: .low)
        XCTAssertEqual(ProjectPortfolio.recommend([blocked, completed, eligible], preferences: preferences)?.candidate.id, "eligible")
    }

    func testRecommendationExplainsUnavailableScoringWithoutInventingAValue() {
        let project = candidate("local", name: "Local", stage: .now, priority: .medium)
        let recommendation = try! XCTUnwrap(ProjectPortfolio.recommend([project], preferences: preferences))
        XCTAssertTrue(recommendation.factors.contains("Open Now work"))
        XCTAssertTrue(recommendation.factors.contains(where: { $0.contains("Do Next score unavailable") }))
        XCTAssertTrue(recommendation.factors.contains(where: { $0.contains("Ready Now score unavailable") }))
        XCTAssertTrue(recommendation.explanation.contains("stage → local portfolio priority → work-item priority → due date → Do Next → Ready Now → name"))
    }

    func testLensesExposeUnknownCoverageRatherThanFallbackScores() {
        let thin = candidate("thin", name: "Thin", ratings: [MetricDefinition.enjoyment.id: 5])
        let fullEnough = candidate("rated", name: "Rated", ratings: Dictionary(uniqueKeysWithValues: MetricDefinition.all.map { ($0.id, 3) }))
        let overall = try! XCTUnwrap(ProjectPortfolio.rankings([thin, fullEnough], preferences: preferences).first { $0.id == "overall" })
        XCTAssertEqual(overall.items.map { $0.candidate.id }, ["rated"])
    }

    func testDecisionSurfaceIncludesAllNineRankingLenses() {
        let ids = ProjectPortfolio.rankings([], preferences: preferences).map(\.id)
        XCTAssertEqual(ids, ["overall", "next", "exciting", "financial", "professional", "learning", "strategic", "ready", "risk"])
    }

    func testRecommendationUsesExplicitPortfolioPriorityBeforeWorkItemPriority() {
        let highWorkPriority = candidate("work", name: "Work priority", stage: .now, priority: .high, portfolioPriority: 2)
        let highPortfolioPriority = candidate("portfolio", name: "Portfolio priority", stage: .now, priority: .low, portfolioPriority: 5)
        let recommendation = ProjectPortfolio.recommend([highWorkPriority, highPortfolioPriority], preferences: preferences)
        XCTAssertEqual(recommendation?.candidate.id, "portfolio")
        XCTAssertTrue(recommendation?.factors.contains("Portfolio priority 5 — Critical") == true)
    }
}

final class ProjectMetadataImportTests: XCTestCase {
    private func page(_ properties: [String: NotionValue]) -> NotionPage {
        NotionPage(id: "notion-project", properties: properties)
    }

    func testMappedNotionValuesUseOnlyCuratedFields() {
        let values = ProjectMetadataImport.values(from: page([
            "Name": .title("Example"), "Domain": .choice("Technology"),
            "Status": .choice("Active"), "Phase": .choice("Build"),
            "Current Work": .choices(["Implementation"]),
            "tracking priority": .number(7), "Assets": .relations(["asset-1"]),
        ]))
        XCTAssertEqual(values.metadata.domain, "Technology")
        XCTAssertEqual(values.metadata.status, "Active")
        XCTAssertEqual(values.metadata.phase, "Build")
        XCTAssertEqual(values.metadata.currentWork, ["Implementation"])
        XCTAssertEqual(values.metadata.trackingPriority, 7)
        XCTAssertTrue(values.relatedNotionPageIDs.isEmpty)
    }

    func testMappedNotionPortfolioReferencesStayReferences() {
        let values = ProjectMetadataImport.values(from: page([
            "GitHub": .text("https://github.com/example/project"),
            "Website": .text("https://example.com/project"),
            "Resources": .relations(["resource-1"]),
            "Collections": .relations(["collection-1", "collection-2"]),
            "Media": .relations(["media-1"]),
        ]))
        XCTAssertEqual(values.portfolioDetails.githubURL, "https://github.com/example/project")
        XCTAssertEqual(values.portfolioDetails.websiteURL, "https://example.com/project")
        XCTAssertEqual(values.portfolioDetails.resourceReferences, ["resource-1"])
        XCTAssertEqual(values.portfolioDetails.collectionReferences, ["collection-1", "collection-2"])
        XCTAssertEqual(values.portfolioDetails.mediaReferences, ["media-1"])
    }

    func testLiveProjectsSchemaAliasesKeepGroupingAndPlanningReferences() {
        let values = ProjectMetadataImport.values(from: page([
            "domain": .choices(["Configuration", "Product"]),
            "Status": .text("Active"),
            "Phase": .choices(["Build"]),
            "repo link": .text("https://github.com/example/project"),
            "assets": .relations(["asset-1"]),
            "tasks": .relations(["task-1", "task-2"]),
            "Features": .relations(["feature-1"]),
            "milestones": .relations(["milestone-1"]),
            "work log": .relations(["log-1", "log-2"]),
        ]))

        XCTAssertEqual(values.metadata.domain, "Configuration, Product")
        XCTAssertEqual(values.metadata.status, "Active")
        XCTAssertEqual(values.metadata.phase, "Build")
        XCTAssertEqual(values.portfolioDetails.githubURL, "https://github.com/example/project")
        XCTAssertEqual(values.portfolioDetails.mediaReferences, ["asset-1"])
        XCTAssertEqual(values.portfolioDetails.taskReferences, ["task-1", "task-2"])
        XCTAssertEqual(values.portfolioDetails.featureReferences, ["feature-1"])
        XCTAssertEqual(values.portfolioDetails.milestoneReferences, ["milestone-1"])
        XCTAssertEqual(values.portfolioDetails.workLogReferences, ["log-1", "log-2"])
    }

    func testOldPortfolioReferenceRowsDecodeWithEmptyNewReferenceLists() throws {
        let old = Data("""
        {"githubURL":"https://github.com/example/project","resourceReferences":["resource-1"],"collectionReferences":[],"mediaReferences":[]}
        """.utf8)
        let decoded = try JSONDecoder().decode(ProjectPortfolioDetails.self, from: old)
        XCTAssertEqual(decoded.githubURL, "https://github.com/example/project")
        XCTAssertEqual(decoded.taskReferences, [])
        XCTAssertEqual(decoded.featureReferences, [])
        XCTAssertEqual(decoded.milestoneReferences, [])
        XCTAssertEqual(decoded.workLogReferences, [])
    }

    func testPreviewClassifiesBlankEqualAndConflictingValues() {
        let remote = page(["Domain": .choice("Technology"), "Status": .choice("Paused"), "Phase": .choice("Build")])
        let preview = ProjectMetadataImport.preview(
            projectID: "local", projectName: "Example", notionPageID: "notion-project",
            localMetadata: ProjectMetadata(status: "Active", phase: "Build"), localDescription: .init(),
            localRelatedProjectNames: [], page: remote
        )
        XCTAssertEqual(preview.changes.first { $0.field == .domain }?.state, .fill)
        XCTAssertEqual(preview.changes.first { $0.field == .status }?.state, .conflict)
        XCTAssertEqual(preview.changes.first { $0.field == .phase }?.state, .equal)
        XCTAssertEqual(preview.defaultFields, [.domain])
    }

    func testApplyingOnlySelectedFieldsNeverSilentlyOverwritesConflict() {
        let values = ProjectMetadataImport.values(from: page([
            "Domain": .choice("Technology"), "Status": .choice("Paused"),
            "One Liner": .text("From Notion"),
        ]))
        let applied = ProjectMetadataImport.applying([.domain, .oneLiner], values: values,
                                                     to: ProjectMetadata(status: "Active"), description: .init())
        XCTAssertEqual(applied.metadata.domain, "Technology")
        XCTAssertEqual(applied.metadata.status, "Active")
        XCTAssertEqual(applied.description.oneLiner, "From Notion")
    }
}
