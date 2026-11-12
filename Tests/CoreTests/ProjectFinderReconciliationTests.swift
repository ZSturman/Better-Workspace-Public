import XCTest
@testable import BetterWorkspaceCore

final class ProjectFinderReconciliationTests: XCTestCase {
    private func fixture() throws -> (WorkspaceLocation, ProjectGraphStore, ProjectGraphSource, ProjectGraphRecord) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bw-finder-presence-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Projects"), withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let source = ProjectGraphSource(id: "projects", title: "Projects", kind: .projects,
            schema: ProjectJSON(["Status": ["id": "status", "type": "select", "select": ["options": [["name": "Active"], ["name": "Idea"]]]]]))
        let store = try ProjectGraphStore(database: Database(inMemory: true))
        try store.write("sources", [source])
        var record = ProjectGraphRecord(pageID: "page", sourceID: source.id, kind: .projects)
        record.localPath = root.appendingPathComponent("Projects/Before").canonicalPath
        record.localProjectID = "local-project"
        record.set("Status", value: ProjectJSON(["name": "Active"]), source: source)
        record.remote = record.local; record.baseline = record.local
        try store.save(record)
        return (WorkspaceLocation(root: root), store, source, record)
    }

    func testConfirmedDepartureQueuesIdeaRetainingBindingAndBaseline() throws {
        let (workspace, store, source, record) = try fixture()
        try ProjectFinderReconciliation.reconcile(store: store, workspace: workspace)
        let updated = try XCTUnwrap(store.record(id: record.id))
        XCTAssertEqual(updated.finderProjectAbsent, true)
        XCTAssertEqual(updated.value("Status", source: source).display, "Idea")
        XCTAssertEqual(updated.localPath, record.localPath)
        XCTAssertEqual(updated.baseline, record.baseline)
        XCTAssertEqual(updated.remote, record.remote)
        try ProjectFinderReconciliation.reconcile(store: store, workspace: workspace)
        XCTAssertEqual(try store.record(id: record.id), updated, "Repeated observations must not invent new edit times")
    }

    func testUnavailableProjectsDoesNotImplyDeparture() throws {
        let (workspace, store, _, record) = try fixture()
        try FileManager.default.removeItem(at: workspace.url(for: .projects))
        try ProjectFinderReconciliation.reconcile(store: store, workspace: workspace)
        XCTAssertEqual(try store.record(id: record.id), record)
    }

    func testExistingProjectAndSymlinkNeverBecomeDepartures() throws {
        let (workspace, store, _, record) = try fixture()
        let url = URL(fileURLWithPath: try XCTUnwrap(record.localPath))
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try ProjectFinderReconciliation.reconcile(store: store, workspace: workspace)
        XCTAssertEqual(try store.record(id: record.id), record)
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: workspace.root.appendingPathComponent("Missing"))
        try ProjectFinderReconciliation.reconcile(store: store, workspace: workspace)
        XCTAssertEqual(try store.record(id: record.id), record)
    }

    func testKnownFolderOutsideProjectsBecomesIdeaWithoutMovingIt() throws {
        let (workspace, store, source, original) = try fixture()
        var record = original
        let url = workspace.root.appendingPathComponent("To Study/Example")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        record.localPath = url.canonicalPath; try store.save(record)
        try ProjectFinderReconciliation.reconcile(store: store, workspace: workspace)
        XCTAssertEqual(try store.record(id: record.id)?.value("Status", source: source).display, "Idea")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }
}
