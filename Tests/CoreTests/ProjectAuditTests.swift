import XCTest
@testable import BetterWorkspaceCore

final class ProjectAuditTests: XCTestCase {
    private func metadata(_ fingerprint: String = "audit:fixture", next: Bool = true) -> WorkItemActionMetadata {
        .init(fingerprint: fingerprint, priority: "P1", actionScore: 80, delegation: "USER + AGENT",
              tags: ["TESTING", "MACOS"], requirements: ["Coding Agent", "Mac", "Human Judgment"],
              agentExecutability: 75, humanInvolvement: 70, estimatedEffort: "30–60 minutes",
              category: "Validation", reason: "Verify the current fixture flow", evidence: ["Tests/fixture.swift:1"],
              agentSubtasks: ["Run the fixture assertions"], userSubtasks: ["Evaluate the fixture flow"], blockedBy: [],
              isNextWork: next, isNextAgentAction: next, isNextUserAction: next)
    }
    private func item(_ id: String, stage: WorkItemStage = .now) -> WorkItem {
        WorkItem(id: id, kind: .task, title: id, stage: stage, url: URL(fileURLWithPath: "/tmp/unused"))
    }
    func testRecommendationKeepsInputOrderForTiesAndScoresStillOverrideTitle() {
        var first = item("same"), second = item("same")
        first.actionMetadata = metadata(next: false)
        second.actionMetadata = metadata(next: false)
        first.body = "first"; second.body = "second"
        XCTAssertEqual(WorkItemRecommendation.nextAction(in: [first, second])?.body, "first")
        var higher = metadata(next: false); higher.actionScore = 99
        second.actionMetadata = higher
        XCTAssertEqual(WorkItemRecommendation.nextAction(in: [first, second])?.body, "second")
    }

    func testPortableMetadataRoundTripPreservesUnknownFieldsAndDescription() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var work = item("quoted"); work.body = "A person's original description\n\"quoted\""; work.extraFrontMatter = ["custom: keep-me"]
        var meta = metadata(); meta.reason = "Quote \" and backslash \\ and newline\n"; work.actionMetadata = meta
        let service = WorkItemService(); let saved = try service.create(work, in: root)
        XCTAssertEqual(saved.actionMetadata, meta); XCTAssertEqual(saved.body, work.body)
        XCTAssertTrue(saved.extraFrontMatter.contains("custom: keep-me"))
        let current = try service.update(saved)
        XCTAssertEqual(current.actionMetadata, meta)
        var edited = current; edited.priority = .low
        let low = try service.update(edited)
        XCTAssertEqual(low.actionMetadata?.priority, "P3")
        XCTAssertEqual(low.actionMetadata?.fingerprint, meta.fingerprint)
    }
    func testDesignationsBlockersCompletionAndOwnerSelection() {
        var alpha = item("Alpha"), next = item("Zulu", stage: .next)
        next.actionMetadata = metadata()
        XCTAssertEqual(WorkItemRecommendation.nextAction(in: [alpha, next])?.id, next.id)
        XCTAssertEqual(WorkItemRecommendation.nextAction(in: [alpha, next], audience: .agent)?.id, next.id)
        XCTAssertNil(WorkItemRecommendation.nextAction(in: [alpha, next], audience: .agent, capabilities: ["Coding Agent", "Mac"]))
        XCTAssertEqual(WorkItemRecommendation.nextAction(in: [alpha, next], audience: .agent, capabilities: ["Coding Agent", "Mac", "Human Judgment"])?.id, next.id)
        var blocked = metadata(); blocked.blockedBy = ["Credentials unavailable"]; next.actionMetadata = blocked
        XCTAssertEqual(WorkItemRecommendation.nextAction(in: [alpha, next])?.id, alpha.id)
        next.actionMetadata = metadata(); next.status = .completed
        XCTAssertEqual(WorkItemRecommendation.nextAction(in: [alpha, next])?.id, alpha.id)
        alpha.dependencyIDs = ["Zulu"]
        XCTAssertNil(WorkItemRecommendation.nextAction(in: [alpha]))
        XCTAssertEqual(WorkItemRecommendation.nextAction(in: [alpha], allItems: [alpha, next])?.id, alpha.id)
    }
    func testLegacyLaterAndUnsupportedMetadataRemainSafe() {
        XCTAssertNil(WorkItemRecommendation.nextAction(in: [item("Later", stage: .later)]))
        var work = item("Legacy"); work.extraFrontMatter = ["action-metadata: \"{\\\"version\\\":99}\""]
        XCTAssertNil(work.actionMetadata); XCTAssertEqual(WorkItemRecommendation.nextAction(in: [work])?.id, work.id)
    }
    func testMobileEnvelopeAndRecommendationAgreeWithoutCloudSchemaChanges() throws {
        let mobile = MobileWorkItem(id: "next", path: "To Do/Test.bw.md", title: "Zulu", kind: .task,
            status: .open, stage: .next, priority: .high, revision: 1, body: "Original text", actionMetadata: metadata(), dependencyIDs: [])
        let decoded = MobileActionProjection.decode(MobileActionProjection.encode(mobile))
        XCTAssertEqual(decoded.body, mobile.body); XCTAssertEqual(decoded.metadata, mobile.actionMetadata)
        XCTAssertEqual(MobileActionProjection.encode(mobile), MobileActionProjection.encode(mobile))
        let legacy = MobileWorkItem(id: "old", path: "To Do/Old.bw.md", title: "Alpha", kind: .task,
            status: .open, stage: .now, priority: .high, revision: 1)
        XCTAssertEqual(WorkItemRecommendation.nextMobileAction(in: [legacy, mobile])?.id, mobile.id)
        XCTAssertEqual(MobileActionProjection.decode("Plain description").body, "Plain description")
        var large = mobile; large.body = String(repeating: "z", count: MobilePlanningFiles.maximumTextBytes)
        let envelope = MobileActionProjection.decode(MobileActionProjection.encode(large))
        XCTAssertEqual(envelope.body, large.body); XCTAssertEqual(envelope.metadata, large.actionMetadata)
    }
    func testImporterResumesWithoutDuplicatesAndRejectsProjectSpaces() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = WorkspaceLocation(root: root), project = root.appendingPathComponent("Projects/Test")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let db = try Database(url: root.appendingPathComponent("private.sqlite"))
        let assessment = ProjectAuditAssessment(projectID: "", assessedAt: "2026-10-04", classification: "REVIEW REQUIRED", recommendation: "Validate the fixture", scores: Dictionary(uniqueKeysWithValues: ["FunctionalHealth", "Maintainability", "TestConfidence", "Documentation", "Completion", "CurrentUtility", "Uniqueness", "FuturePotential", "EaseOfProgress", "TechnicalRisk"].map { ($0, 5) }), workPriorityScore: 60, validationCoverage: "Fixture", confidence: "High", notes: [], commands: [])
        let todo = ProjectAuditTodoInput(id: "stable", title: "Validate Test", description: "Check the fixture", stage: .now, metadata: metadata())
        var input = ProjectAuditImportInput(projectPath: project.path, assessment: assessment, todos: [todo])
        let importer = ProjectAuditImporter(database: db, reuseDiscovery: true), queue = root.appendingPathComponent("To Do")
        let first = try importer.apply(input, workspace: workspace, queue: queue)
        let second = try importer.apply(input, workspace: workspace, queue: queue)
        XCTAssertTrue(first.writes[0].created); XCTAssertFalse(second.writes[0].created)
        XCTAssertEqual(ProjectStore(database: db).record(id: first.projectID)?.url.canonicalPath, project.canonicalPath)
        XCTAssertEqual(WorkItemService().items(under: root).count, 1)
        XCTAssertEqual(try ProjectAuditStore(database: db).assessment(for: first.projectID)?.nextWorkID, "stable")
        let originalBody = try XCTUnwrap(WorkItemService().items(under: root).first).body
        var clarified = todo; clarified.title = "Validate the fixture parser"; clarified.expectedAuditTitle = todo.title
        input.todos = [clarified]
        _ = try importer.apply(input, workspace: workspace, queue: queue)
        XCTAssertEqual(WorkItemService().items(under: root).first?.title, clarified.title)
        XCTAssertEqual(WorkItemService().items(under: root).first?.body, originalBody)
        var staleTitle = clarified; staleTitle.title = "Unexpected rename"; staleTitle.expectedAuditTitle = "A user's conflicting edit"
        input.todos = [staleTitle]
        XCTAssertThrowsError(try importer.apply(input, workspace: workspace, queue: queue))
        var changed = todo; changed.existingID = "stable"; changed.expectedModifiedAt = 1
        changed.metadata.reason = "Changed audit intent"
        input.todos = [changed]
        XCTAssertThrowsError(try importer.apply(input, workspace: workspace, queue: queue))
        XCTAssertEqual(WorkItemService().items(under: root).first?.actionMetadata?.reason, todo.metadata.reason)
        input.projectPath = root.appendingPathComponent("Projects/_Utilities").path
        XCTAssertThrowsError(try importer.apply(input, workspace: workspace, queue: queue))
    }

    func testReviewedNotionTasksUseCanonicalPageIDsAndPreserveStageAndRelationships() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = WorkspaceLocation(root: root), project = root.appendingPathComponent("Projects/Linked")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let db = try Database(url: root.appendingPathComponent("private.sqlite"))
        let projects = ProjectStore(database: db), record = projects.register(url: project)
        projects.setNotionPageID("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", for: record.id)
        let graph = try ProjectGraphStore(database: db)
        let source = ProjectGraphSource(id: "tasks", title: "Tasks", kind: .tasks, schema: ProjectJSON([
            "Name": ["id":"title", "type":"title"], "Project": ["id":"project", "type":"relation"],
            "Work Stage": ["id":"stage", "type":"select"], "Blocked By": ["id":"blocked", "type":"relation"]]))
        try graph.write("sources", [source])
        let row = ProjectGraphRecord(pageID: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb", sourceID: "tasks", kind: .tasks, local: [
            "title":ProjectJSON(["type":"title", "title":[["text":["content":"Retain the linked task"]]]]),
            "project":ProjectJSON(["type":"relation", "relation":[["id":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"]]]),
            "stage":ProjectJSON(["type":"select", "select":["name":"Later"]]),
            "blocked":ProjectJSON(["type":"relation", "relation":[["id":"cccccccccccccccccccccccccccccccc"]]])])
        try graph.save(row)
        let work = try XCTUnwrap(ProjectAuditLinkedWork.items(database: db, workspace: workspace, existing: []).first)
        XCTAssertEqual(work.id, "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb")
        XCTAssertEqual(work.projectPath, "Projects/Linked"); XCTAssertEqual(work.stage, .later)
        XCTAssertEqual(work.dependencyIDs, ["cccccccccccccccccccccccccccccccc"])
        XCTAssertTrue(work.extraFrontMatter.contains(where: { $0.hasPrefix("notion-project:") }))
    }
}
