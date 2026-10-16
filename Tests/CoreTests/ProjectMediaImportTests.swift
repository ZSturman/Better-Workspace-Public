import XCTest
@testable import BetterWorkspaceCore

final class ProjectMediaImportTests: XCTestCase {
    private let source = ProjectGraphSource(id: "assets", title: "Assets", kind: .assets, schema: ProjectJSON([
        "Name": ["id": "name", "type": "title"],
        "relative path": ["id": "path", "type": "rich_text"],
        "storage": ["id": "storage", "type": "select"],
        "storage project": ["id": "root", "type": "relation", "relation": ["data_source_id": "projects"]],
        "projects": ["id": "related", "type": "relation", "relation": ["data_source_id": "projects"]],
        "type": ["id": "type", "type": "select"], "preview": ["id": "preview", "type": "files"]]))
    private func fixture() throws -> (URL, URL, ProjectGraphStore, ProjectGraphRecord) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bw-media-import-\(UUID())")
        let folder = root.appendingPathComponent("Projects/Example/Media")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let file = folder.appendingPathComponent("flow.png")
        try Data([1, 2, 3]).write(to: file)
        let store = try ProjectGraphStore(database: Database(url: root.appendingPathComponent("test.sqlite")))
        var project = ProjectGraphRecord(pageID: "project-page", sourceID: "projects", kind: .projects)
        project.localPath = root.appendingPathComponent("Projects/Example").path
        try store.save(project)
        return (root, file, store, project)
    }
    func testRegistrationIsRelatedResolvableAndIdempotentWithoutAcceptingIncoming() throws {
        let (root, file, store, project) = try fixture()
        let incoming = ProjectGraphRecord(pageID: "incoming", sourceID: source.id, kind: .assets,
            remote: ["name": ProjectJSON(["type": "title", "title": [["text": ["content": "Unaccepted"]]]])])
        try store.save(incoming)
        let asset = try ProjectMediaImport.register(file: file, project: project, sources: [source], store: store, workspaceRoot: root)
        let again = try ProjectMediaImport.register(file: file, project: project, sources: [source], store: store, workspaceRoot: root)
        XCTAssertEqual(asset.id, again.id)
        XCTAssertEqual(try store.records().count, 3)
        XCTAssertEqual(try store.record(id: incoming.id), incoming)
        XCTAssertTrue(ProjectGraphIndex(records: try store.records(), readingIncoming: true).related(to: project).contains { $0.id == asset.id })
        XCTAssertEqual(ProjectMediaResolver.resolve(asset, source: source, workspaceRoot: root,
            projectRoots: [ProjectGraph.normalizedID(project.pageID!): URL(fileURLWithPath: project.localPath!)]).url?.canonicalPath, file.canonicalPath)
        XCTAssertEqual(asset.pendingUploads?.first?.byteCount, 3)
        XCTAssertNil(asset.pageID)
        XCTAssertEqual(try Data(contentsOf: file), Data([1, 2, 3]))
    }
    func testEscapingSymlinkAndUnrelatedSchemaRejectedWithoutCreatingAsset() throws {
        let (root, file, store, project) = try fixture()
        let outside = root.appendingPathComponent("outside.png")
        try Data([4]).write(to: outside)
        let link = file.deletingLastPathComponent().appendingPathComponent("escape.png")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        XCTAssertThrowsError(try ProjectMediaImport.register(file: link, project: project, sources: [source], store: store, workspaceRoot: root))
        let unrelated = ProjectGraphSource(id: "other", title: "Assets", kind: .assets,
            schema: ProjectJSON(["preview": ["id": "preview", "type": "files"]]))
        XCTAssertThrowsError(try ProjectMediaImport.register(file: file, project: project, sources: [unrelated], store: store, workspaceRoot: root))
        XCTAssertEqual(try store.records().count, 1)
    }
}
