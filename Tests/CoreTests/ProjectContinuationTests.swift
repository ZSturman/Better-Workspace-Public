import XCTest
@testable import BetterWorkspaceCore

final class ProjectContinuationTests: XCTestCase {
    private func logs() throws -> [WorkLogEntry] {
        let payload: [String: Any] = ["active_minutes": 20, "elapsed_minutes": 35, "session_count": 1,
            "summary": "Reviewed the sync queue.", "start": "2026-10-21T10:00:00Z", "end": "2026-10-21T10:35:00Z",
            "sessions": [["session_id": "session-1", "start": "2026-10-21T10:00:00Z", "end": "2026-10-21T10:35:00Z",
                          "active_seconds": 1200, "files": ["Sources/View.swift", ".project-core"],
                          "git": ["head_subject": "Improve sync", "branch": "main"]]]]
        let row: [String: Any] = ["id": "log-1", "project_id": "service-1", "project_name": "Same name",
            "date_key": "2026-10-21", "status": "prepared", "session_ids_json": "[\"session-1\"]",
            "payload_json": String(decoding: try JSONSerialization.data(withJSONObject: payload), as: UTF8.self)]
        return try BackgroundServiceClient.decodeWorkLogs(JSONSerialization.data(withJSONObject: ["data": [row]]))
    }

    func testHistoryUsesStableServiceIdentityAndRetainsDailySessionRelationships() throws {
        let entries = try logs()
        let history = ProjectWorkHistory(serviceID: "service-1", logs: entries, sessions: [])
        XCTAssertEqual(history.totalLogs, 1); XCTAssertEqual(history.totalSessions, 1)
        XCTAssertEqual(history.sessions(for: history.logs[0]).map(\.id), ["session-1"])
        XCTAssertEqual(history.sessions[0].interestingFiles, ["View.swift"])
        XCTAssertEqual(history.sessions[0].gitSubject, "Improve sync")
        XCTAssertEqual(history.logs[0].endedAt?.timeIntervalSince(history.logs[0].startedAt!), 2100)
        XCTAssertTrue(ProjectWorkHistory(serviceID: "another-project-with-the-same-name", logs: entries, sessions: []).logs.isEmpty)
        XCTAssertTrue(ProjectWorkHistory(serviceID: nil, logs: entries, sessions: []).sessions.isEmpty)
        let details = MobileProjectDetails(path: "Projects/P", projectID: "p", ratings: [:], history: history)
        XCTAssertEqual(MobileProjectEnvelope.decode(MobileProjectEnvelope.encode(details)), details)
        let command = MobileProjectEdit(original: details, ratings: [:], oneLiner: "", summary: "")
        XCTAssertNil(command.original.history, "Read-only history must not inflate edit commands")
        let entry = MobileWorkspaceEntry(path: details.path, parentPath: "Projects", name: "P", isDirectory: true, revision: 9, projectDetails: details)
        let preview = MobilePlanningEdit(operation: .previewProject, title: "P", originalEntry: entry)
        XCTAssertNil(preview.originalEntry?.projectDetails?.history)
        XCTAssertEqual(preview.originalEntry?.projectDetails?.projectID, details.projectID)
        XCTAssertEqual(preview.originalEntry?.revision, 9)
        let legacy = try JSONDecoder().decode(MobileProjectDetails.self, from: Data(#"{"path":"Projects/P"}"#.utf8))
        XCTAssertNil(legacy.history)
    }

    func testHistoryBoundsAndDeduplicatesFactsWithoutDiscardingTotals() throws {
        let log = try logs()[0]
        let original = try XCTUnwrap(log.sessions?.first)
        let sessions = (0..<80).map { index in
            WorkSession(id: "s-\(index)", projectID: original.projectID, projectName: original.projectName,
                startedAt: original.startedAt.addingTimeInterval(Double(index)), endedAt: original.endedAt,
                activeSeconds: 60, files: ["some/private/path/View.swift"], gitBranch: nil, gitSubject: nil)
        }
        let history = ProjectWorkHistory(serviceID: "service-1", logs: [log], sessions: sessions + [original])
        XCTAssertEqual(history.totalSessions, 81); XCTAssertEqual(history.sessions.count, 60)
        XCTAssertTrue(history.sessions.allSatisfy { $0.files == ["View.swift"] })
    }

    func testNotionLinkCoalescesLocalDraftWithoutRemoteWritesOrLostState() throws {
        let db = try Database(inMemory: true), projects = ProjectStore(database: db)
        let local = projects.register(url: URL(fileURLWithPath: "/tmp/link-fixture"))
        let graph = try ProjectGraphStore(database: db)
        let baseline = ProjectServiceBridge.text("Remote description")
        var page = ProjectGraphRecord(id: "imported", pageID: "page-1", sourceID: "projects", kind: .projects)
        page.remote = ["summary": baseline]; page.baseline = page.remote; page.local = page.remote
        var draft = ProjectGraphRecord(id: "draft", sourceID: "projects", kind: .projects)
        draft.localProjectID = local.id; draft.localPath = local.lastPath
        draft.local = ["summary": ProjectServiceBridge.text("My existing draft")]
        draft.localFieldEditedAt = ["summary": Date(timeIntervalSince1970: 10)]
        try graph.save(page); try graph.save(draft)
        try graph.linkLocalProject(local, page: page, draft: draft, projectStore: projects)
        let linked = try XCTUnwrap(graph.record(id: draft.id))
        XCTAssertEqual(linked.pageID, "page-1"); XCTAssertEqual(linked.remote, page.remote)
        XCTAssertEqual(linked.baseline, page.baseline); XCTAssertEqual(linked.local, draft.local)
        XCTAssertEqual(linked.localFieldEditedAt, draft.localFieldEditedAt)
        XCTAssertEqual(projects.record(id: local.id)?.notionPageID, "page-1")
        XCTAssertNil(try graph.record(id: page.id)); XCTAssertEqual(try graph.records().count, 1)
    }

    func testNotionLinkRejectsStaleOrAmbiguousDraftWithoutPartialChanges() throws {
        let db = try Database(inMemory: true), projects = ProjectStore(database: db)
        let local = projects.register(url: URL(fileURLWithPath: "/tmp/stale-link-fixture"))
        let graph = try ProjectGraphStore(database: db)
        let page = ProjectGraphRecord(id: "imported", pageID: "page-1", sourceID: "projects", kind: .projects)
        var draft = ProjectGraphRecord(id: "draft", sourceID: "projects", kind: .projects)
        draft.localProjectID = local.id; draft.ambiguousCreate = true
        try graph.save(page); try graph.save(draft)
        XCTAssertThrowsError(try graph.linkLocalProject(local, page: page, draft: draft, projectStore: projects))
        XCTAssertNil(projects.record(id: local.id)?.notionPageID)
        XCTAssertEqual(try graph.records().count, 2)
        var stale = page; stale.remoteArchived = true; try graph.save(stale)
        XCTAssertThrowsError(try graph.linkLocalProject(local, page: page, draft: draft, projectStore: projects))
        XCTAssertEqual(try graph.record(id: draft.id), draft)
    }

    func testLinkPreservesPopulatedLocalDecisionsAgainstLaterRemoteProjection() throws {
        let db = try Database(inMemory: true), projects = ProjectStore(database: db)
        let local = projects.register(url: URL(fileURLWithPath: "/tmp/local-values-link-fixture"))
        projects.setMetadata(.init(domain: "Art"), for: local.id)
        let graph = try ProjectGraphStore(database: db)
        let source = ProjectGraphSource(id: "projects", title: "Projects", kind: .projects,
            schema: ProjectJSON(["domain": ["id": "domain-id", "type": "select"]]))
        try graph.write("sources", [source])
        let remote = ProjectJSON(["type": "select", "select": ["name": "Technology"]])
        let page = ProjectGraphRecord(id: "imported", pageID: "page-1", sourceID: source.id, kind: .projects,
            local: ["domain-id": remote], baseline: ["domain-id": remote], remote: ["domain-id": remote])
        try graph.save(page)
        try graph.linkLocalProject(local, page: page, draft: nil, projectStore: projects)
        let linked = try XCTUnwrap(graph.record(id: page.id))
        XCTAssertEqual(linked.value("domain", source: source).display, "Art")
        XCTAssertEqual(linked.baseline["domain-id"], remote)
        XCTAssertEqual(linked.remote["domain-id"], remote)
        XCTAssertEqual(projects.metadata(for: local.id).domain, "Art")
        XCTAssertEqual(linked.changes.first?.state, .outgoing)
    }

    func testNotionLinkWaitsForAnInFlightSync() throws {
        let db = try Database(inMemory: true), projects = ProjectStore(database: db)
        let local = projects.register(url: URL(fileURLWithPath: "/tmp/busy-link-fixture"))
        let graph = try ProjectGraphStore(database: db)
        let page = ProjectGraphRecord(id: "imported", pageID: "page-1", sourceID: "projects", kind: .projects)
        try graph.save(page)
        XCTAssertTrue(try graph.acquire(owner: "another-active-sync"))
        XCTAssertThrowsError(try graph.linkLocalProject(local, page: page, draft: nil, projectStore: projects))
        XCTAssertNil(projects.record(id: local.id)?.notionPageID)
        try graph.release(owner: "another-active-sync")
        try graph.linkLocalProject(local, page: page, draft: nil, projectStore: projects)
        XCTAssertEqual(projects.record(id: local.id)?.notionPageID, "page-1")
    }

    func testNotionPageOwnershipNormalizesHyphensAndCaseAndSurvivesRename() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bw-link-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let before = root.appendingPathComponent("Before"), after = root.appendingPathComponent("After")
        try FileManager.default.createDirectory(at: before, withIntermediateDirectories: true)
        let store = ProjectStore(database: try Database(inMemory: true))
        let first = store.register(url: before), other = store.register(url: root.appendingPathComponent("Other"))
        try store.setExplicitNotionPageID("ABCD-EF01", for: first.id)
        XCTAssertThrowsError(try store.setExplicitNotionPageID("abcdef01", for: other.id))
        try FileManager.default.moveItem(at: before, to: after)
        XCTAssertEqual(store.record(for: after)?.id, first.id)
        XCTAssertEqual(store.record(for: after)?.notionPageID, "ABCD-EF01")
    }

    func testAttentionKeepsUnscoredProjectsAfterScoredProjectsAndRespectsPriority() {
        var input = Attention.Input()
        input.now = Date(timeIntervalSince1970: 1_000_000_000)
        func project(_ path: String, score: Double?, priority: Int? = nil) -> Attention.Input.Project {
            .init(name: path, path: path, contentModifiedAt: input.now, score: score, ratedCount: score == nil ? 0 : 1,
                  lastSessionAt: input.now.addingTimeInterval(-10 * 86_400), observedHours: nil, priority: priority)
        }
        input.projects = [project("A unscored", score: nil), project("Z scored", score: 10), project("Y scored", score: 80)]
        XCTAssertEqual(Attention.evaluate(input, limit: 10).map(\.title), ["Y scored", "Z scored", "A unscored"])
        input.projects[0] = project("A unscored", score: nil, priority: 5)
        XCTAssertEqual(Attention.evaluate(input).first?.title, "A unscored")
    }
}
