import XCTest
@testable import BetterWorkspaceCore

final class WorkItemPathIndexTests: XCTestCase {
    private var fixture: URL!
    private var root: URL!
    private var file: URL!
    private let service = WorkItemService()
    override func setUpWithError() throws {
        fixture = FileManager.default.temporaryDirectory.appendingPathComponent("bw-index-\(UUID())")
        root = fixture.appendingPathComponent("Workspace")
        file = fixture.appendingPathComponent("private/paths.json")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: fixture) }
    private func create(_ title: String, in directory: URL? = nil) throws -> WorkItem {
        try service.create(WorkItem(kind: .task, title: title, url: root), in: directory ?? root)
    }

    func testWarmLoadReadsCurrentContentsAndBackgroundScanFindsNewAndMovedRecords() async throws {
        let index = WorkItemPathIndex(file: file)
        var first = try create("First")
        let moved = try create("Moved"), deleted = try create("Deleted")
        try await index.save([first, moved, deleted], under: root)
        first.title = "Changed externally"
        _ = try service.update(first)
        let folder = root.appendingPathComponent("New folder")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: moved.url, to: folder.appendingPathComponent(moved.url.lastPathComponent))
        try FileManager.default.removeItem(at: deleted.url)
        let new = try create("New")
        let loaded = await index.load(under: root)
        let warm = try XCTUnwrap(loaded)
        XCTAssertEqual(warm.map(\.title), ["Changed externally"])
        let scan = try XCTUnwrap(service.scan(under: root))
        XCTAssertTrue(scan.complete)
        XCTAssertEqual(Set(scan.items.map(\.id)), [first.id, moved.id, new.id])
        try await index.save(scan.items, under: root)
        let reopened = await WorkItemPathIndex(file: file).load(under: root)
        XCTAssertEqual(Set(reopened?.map(\.id) ?? []), [first.id, moved.id, new.id])
    }

    func testMissingCorruptAndDifferentRootIndexesFallBackToDiscovery() async throws {
        let index = WorkItemPathIndex(file: file)
        let missing = await index.load(under: root)
        XCTAssertNil(missing)
        let item = try create("Keep")
        try await index.save([item], under: root)
        let other = await index.load(under: fixture)
        XCTAssertNil(other)
        try Data("broken JSON".utf8).write(to: file)
        let corrupt = await index.load(under: root)
        XCTAssertNil(corrupt)
        XCTAssertEqual(service.items(under: root).map(\.id), [item.id])
    }

    func testIndexRejectsEscapesForeignMetadataAndSymlinks() async throws {
        let outside = try create("Outside", in: fixture.appendingPathComponent("Outside"))
        let foreign = try create("Foreign", in: root.appendingPathComponent("_audit"))
        let allowed = try create("Allowed")
        let link = root.appendingPathComponent("linked.bw.md")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside.url)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: ["version": 1, "root": root.canonicalPath,
            "paths": ["../Outside/" + outside.url.lastPathComponent, foreign.url.path.replacingOccurrences(of: root.path + "/", with: ""), link.lastPathComponent, allowed.url.lastPathComponent]])
        try data.write(to: file)
        let warm = await WorkItemPathIndex(file: file).load(under: root)
        XCTAssertEqual(warm?.map(\.id), [allowed.id])
        XCTAssertEqual(service.items(under: root).map(\.id), [allowed.id])
    }

    func testMissingRootAndLimitedScanCannotReplaceCompleteIndex() throws {
        _ = try create("A"); _ = try create("B")
        XCTAssertFalse(try XCTUnwrap(service.scan(under: root, limit: 1)).complete)
        XCTAssertNil(service.scan(under: fixture.appendingPathComponent("missing")))
    }

    func testDirectoryEventsFindMovedRecordsAndRespectPruning() throws {
        let item = try create("Before")
        let destination = root.appendingPathComponent("Moved folder")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let moved = destination.appendingPathComponent(item.url.lastPathComponent)
        try FileManager.default.moveItem(at: item.url, to: moved)
        guard case let .incremental(upserts, removed) = service.reconcile(changedPaths: [item.url.path, destination.path, moved.path], known: [item]) else { return XCTFail("Expected incremental discovery") }
        XCTAssertEqual(upserts.map(\.id), [item.id]); XCTAssertTrue(removed.contains(item.url.canonicalPath))
    }
}
