import XCTest
@testable import BetterWorkspaceCore

final class WorkspaceMacDirectoryCreationTests: XCTestCase {
    private final class Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bw-directory-" + UUID().uuidString)
        let database: Database
        let projects: ProjectStore
        var workspace: WorkspaceLocation { .init(root: root.appendingPathComponent("Workspace")) }
        var journal: URL { root.appendingPathComponent("PrivateJournal") }
        init() throws {
            try FileManager.default.createDirectory(at: root.appendingPathComponent("Workspace/Projects"), withIntermediateDirectories: true)
            database = try Database(url: root.appendingPathComponent("Private.sqlite")); projects = ProjectStore(database: database)
        }
        func remove() { try? FileManager.default.removeItem(at: root) }
        func request(_ graph: WorkspaceReplica, _ record: UUID) throws -> WorkspaceMacWorkCreation {
            try .prepare(recordID: record, in: graph, bindings: [], workspace: workspace, directoryPath: "Projects")
        }
        func apply(_ request: WorkspaceMacWorkCreation, graph: WorkspaceReplica) throws -> (URL, WorkspaceMacBinding) {
            try WorkspaceMacDirectoryCreation.materialize(request, in: graph, bindings: [], workspace: workspace, journalDirectory: journal, projects: projects)
        }
    }

    func testCanonicalProjectCollisionPropertiesAndReplayDoNotAddGraphBranches() throws {
        let f = try Fixture(); defer { f.remove() }
        let existing = f.workspace.root.appendingPathComponent("Projects/Same name")
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: false)
        let sentinel = existing.appendingPathComponent("Keep.txt"); try Data("Unrelated original".utf8).write(to: sentinel)
        var links = ProjectPortfolioDetails(githubURL: "https://github.com/example/project"); links.featured = true
        let metadata = ProjectMetadata(domain: "Art", status: "Active", projectType: "Animation")
        var graph = try WorkspaceReplica()
        let base = try graph.save(content: .init(kind: .project, title: "Same name", body: "Description\n", projectMetadata: metadata, projectLinks: links), expectedHeads: [], deviceID: UUID(), origin: .iOS)
        let request = try f.request(graph, base.recordID)
        XCTAssertEqual(request.relativePath, "Projects/Same name-iOS")
        let (url, binding) = try f.apply(request, graph: graph)
        XCTAssertEqual(f.projects.register(url: url).id, base.recordID.uuidString)
        XCTAssertEqual(f.projects.metadata(for: base.recordID.uuidString), metadata)
        XCTAssertEqual(f.projects.portfolioDetails(for: base.recordID.uuidString), links)
        XCTAssertEqual(f.projects.description(for: base.recordID.uuidString).summary, "Description")
        let identity = FileIdentityResolver.identity(of: url)
        XCTAssertEqual(try f.apply(request, graph: graph).1, binding)
        XCTAssertEqual(FileIdentityResolver.identity(of: url), identity)
        XCTAssertEqual(try String(contentsOf: sentinel), "Unrelated original")
        let entry = MobileWorkspaceEntry(path: request.relativePath, parentPath: "Projects", name: url.lastPathComponent, isDirectory: true, revision: 0, projectDetails: .init(path: request.relativePath, summary: "Description", domain: "Art", status: "Active", projectID: base.recordID.uuidString, projectType: "Animation", portfolio: links))
        let observation = try WorkspaceMacProjection.observe(.init(entries: [entry]), in: graph, bindings: [binding], deviceID: UUID())
        XCTAssertEqual(try observation.replica.fingerprint, try graph.fingerprint)
        var next = base.content; next.body = "Later offline edit"
        _ = try graph.save(recordID: base.recordID, content: next, expectedHeads: [base.id], deviceID: UUID(), origin: .iOS)
        XCTAssertEqual(try WorkspaceMacProjection.prepareProjectSave(binding: binding, in: graph, current: entry)?.summary, next.body)
    }

    func testInterruptedAfterVisibleMoveRetainsUUIDAndPreservesConcurrentMetadata() throws {
        let f = try Fixture(); defer { f.remove() }
        var graph = try WorkspaceReplica()
        let base = try graph.save(content: .init(kind: .project, title: "Interrupted", body: "Intended summary"), expectedHeads: [], deviceID: UUID(), origin: .iOS)
        let request = try f.request(graph, base.recordID)
        try f.database.execute("CREATE TRIGGER reject_owned_description BEFORE INSERT ON project_descriptions BEGIN SELECT RAISE(ABORT,'owned interruption'); END;")
        XCTAssertThrowsError(try f.apply(request, graph: graph))
        let url = f.workspace.root.appendingPathComponent(request.relativePath)
        let identity = try XCTUnwrap(FileIdentityResolver.identity(of: url))
        // Simulates discovery after the move but before the writer's receipt.
        XCTAssertEqual(f.projects.register(url: url).id, base.recordID.uuidString)
        try f.database.execute("DROP TRIGGER reject_owned_description")
        _ = try f.apply(request, graph: graph)
        XCTAssertEqual(FileIdentityResolver.identity(of: url), identity)
        f.projects.setDescription(.init(summary: "Changed in the Mac editor"), for: base.recordID.uuidString)
        XCTAssertThrowsError(try f.apply(request, graph: graph))
        XCTAssertEqual(f.projects.description(for: base.recordID.uuidString).summary, "Changed in the Mac editor")
    }

    func testInterruptedStageThenOccupiedTargetCanCancelAndReplanWithoutOverwrite() throws {
        let f = try Fixture(); defer { f.remove() }
        var graph = try WorkspaceReplica()
        let base = try graph.save(content: .init(kind: .project, title: "Race"), expectedHeads: [], deviceID: UUID(), origin: .iOS)
        let request = try f.request(graph, base.recordID)
        try f.database.execute("CREATE TABLE workspace_project_identity_reservations (identity_key TEXT PRIMARY KEY, project_id TEXT NOT NULL UNIQUE, created_at REAL NOT NULL)")
        try f.database.execute("CREATE TRIGGER reject_owned_reservation BEFORE INSERT ON workspace_project_identity_reservations BEGIN SELECT RAISE(ABORT,'owned interruption'); END;")
        XCTAssertThrowsError(try f.apply(request, graph: graph))
        let occupied = f.workspace.root.appendingPathComponent(request.relativePath)
        XCTAssertFalse(FileManager.default.fileExists(atPath: occupied.path))
        try FileManager.default.createDirectory(at: occupied, withIntermediateDirectories: false)
        let sentinel = occupied.appendingPathComponent("Keep.txt"); try Data("Keep".utf8).write(to: sentinel)
        try f.database.execute("DROP TRIGGER reject_owned_reservation")
        XCTAssertThrowsError(try f.apply(request, graph: graph))
        try WorkspaceMacDirectoryCreation.cancel(request, journalDirectory: f.journal, projects: f.projects)
        XCTAssertEqual(try String(contentsOf: sentinel), "Keep")
        let next = try f.request(graph, base.recordID)
        XCTAssertEqual(next.relativePath, "Projects/Race-iOS")
        let created = try f.apply(next, graph: graph).0
        XCTAssertEqual(f.projects.record(for: created)?.id, base.recordID.uuidString)
        XCTAssertEqual(try String(contentsOf: sentinel), "Keep")
    }

    func testOccupiedOrReplacedDirectoryIsNeverAdopted() throws {
        let f = try Fixture(); defer { f.remove() }
        var graph = try WorkspaceReplica()
        let base = try graph.save(content: .init(kind: .project, title: "Owned"), expectedHeads: [], deviceID: UUID(), origin: .mac)
        let request = try f.request(graph, base.recordID)
        let created = try f.apply(request, graph: graph).0
        try FileManager.default.moveItem(at: created, to: created.deletingLastPathComponent().appendingPathComponent("Owned original"))
        try FileManager.default.createDirectory(at: created, withIntermediateDirectories: false)
        let identity = FileIdentityResolver.identity(of: created)
        XCTAssertThrowsError(try f.apply(request, graph: graph))
        XCTAssertEqual(FileIdentityResolver.identity(of: created), identity)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: created.path).isEmpty)
    }
}
