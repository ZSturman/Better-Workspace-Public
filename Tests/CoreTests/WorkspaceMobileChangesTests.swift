import XCTest
@testable import BetterWorkspaceCore

final class WorkspaceMobileChangesTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("bw-mobile-changes-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }
    private func directory(_ path: String) throws -> URL {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true); return url
    }
    @discardableResult private func file(_ path: String, _ content: String = "Original") throws -> URL {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8); return url
    }
    func testTransparentFoldersPreserveRealPathsEmptyFoldersAndUnderscoreFiles() async throws {
        let projects = try directory("Projects")
        try file("Projects/Folder-A/File-1.txt")
        try file("Projects/_Folder-B/_Nested/Subfolder-A/File-5.txt")
        try directory("Projects/_Folder-B/Subfolder-B")
        try file("Projects/_File.txt")
        try file("Projects/_audit/do-not-read/secret.txt")
        try file("Projects/_Folder-B/.project-core/secret.txt")
        try FileManager.default.createSymbolicLink(at: projects.appendingPathComponent("_Link"), withDestinationURL: root)
        let items = try await FilesystemService().items(inDirectory: projects)
        XCTAssertEqual(Set(items.map(\.name)), ["Folder-A", "Subfolder-A", "Subfolder-B", "_File.txt"])
        XCTAssertEqual(items.first { $0.name == "Subfolder-A" }?.url.canonicalPath,
            root.appendingPathComponent("Projects/_Folder-B/_Nested/Subfolder-A").canonicalPath)
        XCTAssertEqual(items.first { $0.name == "Subfolder-B" }?.immediateChildCount, 0)
        let normalChildren = try await FilesystemService().items(inDirectory: projects.appendingPathComponent("Folder-A"))
        XCTAssertEqual(normalChildren.map(\.name), ["File-1.txt"])
    }
    func testWrapperPathsAuthorizeOnlyVisibleAreaChildrenAndPromotionIsRetryable() throws {
        XCTAssertTrue(WorkspaceListing.isAreaChild("Projects/_Group/_Sub/Project", area: "Projects"))
        XCTAssertTrue(WorkspaceListing.isAreaChild("Ideas/_File.md", area: "Ideas"))
        for path in ["Projects/Normal/Project", "Projects/_audit/Project", "Projects/_Group/../Project", "/Projects/Project"] {
            XCTAssertFalse(WorkspaceListing.isAreaChild(path, area: "Projects"), path)
        }
        let source = try directory("Ideas/_Group/_Sub/Studio")
        try file("Ideas/_Group/_Sub/Studio/Note.txt")
        try directory("Projects")
        let idea = MobileIdea(path: "Ideas/_Group/_Sub/Studio", title: "Studio", revision: 1,
            modifiedAt: try source.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, serviceID: "studio")
        XCTAssertNoThrow(try MobilePlanningFiles.validate(.init(operation: .previewIdea, title: "Studio", originalIdea: idea)))
        let checkpoint = try IdeaPromotionFiles.move(idea, kind: .project, workspace: .init(root: root), checkpoint: nil)
        try IdeaPromotionFiles.apply(checkpoint); try IdeaPromotionFiles.apply(checkpoint)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("Projects/Studio/Note.txt")), "Original")
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
    }
    func testIndependentIdeaGroupingAndSortingUseCreationDatesAndKeepUnknownsLast() throws {
        let a = MobileIdea(path: "Ideas/A", title: "A", revision: 1, modifiedAt: Date(timeIntervalSince1970: 900),
            planning: IdeaPlanning(priority: 1, ratings: ["qualityOfLife": 5], potential: .project,
                project: .init(metadata: .init(domain: "Design"))), createdAt: Date(timeIntervalSince1970: 100))
        let b = MobileIdea(path: "Ideas/B", title: "B", revision: 1, modifiedAt: Date(timeIntervalSince1970: 50),
            planning: IdeaPlanning(priority: 5, ratings: ["qualityOfLife": 1], potential: .project,
                project: .init(metadata: .init(domain: "Design"))), createdAt: Date(timeIntervalSince1970: 200))
        let unknown = MobileIdea(path: "Ideas/C", title: "C", revision: 1, planning: IdeaPlanning(potential: .project))
        var query = MobileBrowseQuery(); query.group = .potential; query.sort = .score
        XCTAssertEqual(query.ideas([b, unknown, a]).first?.items.map(\.title), ["A", "B", "C"], "Score sorting must not silently use priority")
        query.group = .domain; query.sort = .dateAdded; query.domain = "Design"
        XCTAssertEqual(query.ideas([a, unknown, b]).first?.title, "Design")
        XCTAssertEqual(query.ideas([a, unknown, b]).first?.items.map(\.title), ["B", "A"])
        query.domain = ""; query.group = .none; query.ascending = true
        XCTAssertEqual(query.ideas([unknown, b, a]).first?.items.map(\.title), ["A", "B", "C"])
        let envelope = MobileIdeaEnvelope.decode(MobileIdeaEnvelope.encode(a))
        XCTAssertEqual(envelope?.createdAt, a.createdAt)
        XCTAssertNil(MobileIdeaEnvelope.decode("[]")?.createdAt)
    }
    func testDownloadsExcludeMetadataDependenciesAndSymlinksAndPreserveEmptyFolders() async throws {
        try file("Projects/Example/_Notes/Readme.md", "Offline bytes")
        try directory("Projects/Example/Empty")
        try file("Projects/Example/node_modules/package/index.js")
        try file("Projects/Example/.git/private")
        try file("Projects/Example/_audit/private")
        try file("Projects/Example/watcher.item.toml")
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("Projects/Example/Escape"), withDestinationURL: root)
        let entry = MobileWorkspaceEntry(path: "Projects/Example", parentPath: "Projects", name: "Example", isDirectory: true, revision: 1)
        let bundle = try MobileDownloadBundle.prepare(entry, workspace: .init(root: root))
        XCTAssertEqual(bundle.files.map(\.path), ["_Notes/Readme.md"])
        XCTAssertTrue(bundle.directories.contains("Empty"))
        let archive = root.appendingPathComponent("bundle.plist"); try bundle.write(to: archive)
        let cache = MobileDownloadCache(root: root.appendingPathComponent("PrivateDownloads"))
        let id = UUID(), copy = try await cache.install(asset: archive, id: id, expectedPath: entry.path)
        let reopened = await cache.load(id)
        XCTAssertEqual(reopened?.files, copy.files)
        let fileURL = try XCTUnwrap(cache.fileURL(copy: copy, path: "_Notes/Readme.md"))
        XCTAssertEqual(try Data(contentsOf: fileURL), Data("Offline bytes".utf8))
        XCTAssertNil(cache.fileURL(copy: copy, path: "../Outside"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("Projects/Example/watcher.item.toml").path))
    }
    func testDownloadValidationRejectsEscapesCollisionsAndOversizedFileCounts() throws {
        for path in ["../Outside", "/Outside", "A//B", "A/.git/config", "A/_audit/private", "A/watcher.item.toml", "A/\0B"] {
            XCTAssertThrowsError(try MobileDownloadBundle(path: "Ideas/A", title: "A", files: [.init(path: path, data: Data())]).validate(), path)
        }
        XCTAssertThrowsError(try MobileDownloadBundle(path: "Ideas/A", title: "A", files: [
            .init(path: "Same", data: Data()), .init(path: "Same", data: Data())]).validate())
        XCTAssertThrowsError(try MobileDownloadBundle(path: "Ideas/A", title: "A", directories: ["Same"], files: [.init(path: "Same", data: Data())]).validate())
        XCTAssertThrowsError(try MobileDownloadBundle(path: "Ideas/A", title: "A", files: (0...500).map { .init(path: "File\($0)", data: Data()) }).validate())
    }
    func testMobilePropertySavePreservesOtherMetadataAndRejectsConcurrentChanges() throws {
        let folder = try directory("Projects/_Group/Example")
        let store = ProjectStore(database: try Database(url: root.appendingPathComponent("private.sqlite")))
        let record = store.register(url: folder)
        store.setMetadata(.init(domain: "Design", status: "Active", phase: "Plan", completionModel: "Maintained", currentWork: ["Keep this"], portfolioPriority: 4), for: record.id)
        let original = MobileProjectDetails(path: "Projects/_Group/Example", domain: "Design", status: "Active", phase: "Plan", projectID: record.id, ratings: [:])
        var properties = MobileProjectProperties(original); properties.domain = "Research"; properties.status = "Paused"
        let change = MobileProjectEdit(original: original, ratings: ["qualityOfLife": 4], oneLiner: "Offline edit", summary: "", properties: properties)
        try store.saveMobileProject(change); try store.saveMobileProject(change)
        XCTAssertEqual(store.metadata(for: record.id).domain, "Research")
        XCTAssertEqual(store.metadata(for: record.id).completionModel, "Maintained")
        XCTAssertEqual(store.metadata(for: record.id).currentWork, ["Keep this"])
        XCTAssertEqual(store.metadata(for: record.id).portfolioPriority, 4)
        var concurrent = store.metadata(for: record.id); concurrent.phase = "New phase"
        store.setMetadata(concurrent, for: record.id)
        try store.saveMobileProject(change)
        XCTAssertEqual(store.metadata(for: record.id).phase, "New phase", "An unrelated property edit is retained")
        concurrent.domain = "New domain"; store.setMetadata(concurrent, for: record.id)
        XCTAssertThrowsError(try store.saveMobileProject(change))
        XCTAssertEqual(store.metadata(for: record.id).domain, "New domain")
        var refreshed = original; refreshed.domain = "Research"; refreshed.status = "Paused"; refreshed.phase = "New phase"
        XCTAssertTrue(properties.isReflected(in: refreshed, from: original))
        XCTAssertEqual(store.ratings(for: record.id), ["qualityOfLife": 4])
    }
}
