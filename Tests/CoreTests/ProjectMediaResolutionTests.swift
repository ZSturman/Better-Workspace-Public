import XCTest
@testable import BetterWorkspaceCore

final class ProjectMediaResolutionTests: XCTestCase {
    private let source = ProjectGraphSource(id: "assets", title: "Assets", kind: .assets, schema: ProjectJSON([
        "relative path": ["id": "path", "type": "rich_text"],
        "preview": ["id": "preview", "type": "files"],
        "project banner": ["id": "project", "type": "relation"]]))
    private func text(_ value: String) -> ProjectJSON { ProjectJSON(["type": "rich_text", "rich_text": [["text": ["content": value]]]]) }
    private func relation(_ ids: [String]) -> ProjectJSON { ProjectJSON(["type": "relation", "relation": ids.map { ["id": $0] }]) }
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bw-media-resolution-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    private func file(_ root: URL, _ path: String) throws -> URL {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: url)
        return url
    }
    func testLegacyAssetUsesOnlyItsRelatedProjectAndKeepsIncomingUnaccepted() throws {
        let root = try fixture(), project = root.appendingPathComponent("Projects/Coloring Book")
        let image = try file(project, "FolioAssets/banner.png")
        let asset = ProjectGraphRecord(sourceID: "assets", kind: .assets, remote: [
            "path": text("FormerRoot/Coloring Book/FolioAssets/banner.png"), "project": relation(["project-page"])])
        let resolved = ProjectMediaResolver.resolve(asset, source: source, workspaceRoot: root,
            projectRoots: ["projectpage": project])
        XCTAssertEqual(resolved.url?.canonicalPath, image.canonicalPath)
        XCTAssertFalse(resolved.isPreview)
        XCTAssertTrue(asset.local.isEmpty)
        XCTAssertTrue(asset.baseline.isEmpty)
        XCTAssertEqual(asset.changes.count, 2)
    }
    func testInverseProjectRelationshipCanSupplyLegacyRoot() throws {
        let root = try fixture(), project = root.appendingPathComponent("Projects/Coloring Book")
        let image = try file(project, "FolioAssets/thumbnail.png")
        let asset = ProjectGraphRecord(sourceID: "assets", kind: .assets, remote: ["path": text("FormerRoot/Coloring Book/FolioAssets/thumbnail.png")])
        XCTAssertNil(ProjectMediaResolver.resolve(asset, source: source, workspaceRoot: root, projectRoots: [:]).url)
        XCTAssertEqual(ProjectMediaResolver.resolve(asset, source: source, workspaceRoot: root,
            projectRoots: [:], relatedProjectRoots: [project]).url?.canonicalPath, image.canonicalPath)
    }
    func testLegacyCollectionPathUsesExactProjectsPrefixWithoutPageBinding() throws {
        let root = try fixture()
        let video = try file(root, "Projects/_Collections/Animation Collection/Film/Film.mov")
        let asset = ProjectGraphRecord(sourceID: "assets", kind: .assets, remote: ["path": text("_Collections/Animation Collection/Film/Film.mov")])
        let result = ProjectMediaResolver.resolve(asset, source: source, workspaceRoot: root, projectRoots: [:])
        XCTAssertEqual(result.url?.canonicalPath, video.canonicalPath)
        XCTAssertFalse(result.isPreview)
    }
    func testKnownLegacyCategoriesAndMediaRootUseExactPaths() throws {
        let root = try fixture()
        for category in ["Creative", "Technology", "Expository"] {
            let image = try file(root, "Projects/\(category) project/FolioAssets/image.png")
            let asset = ProjectGraphRecord(sourceID: "assets", kind: .assets, remote: ["path": text("\(category)/\(category) project/FolioAssets/image.png")])
            XCTAssertEqual(ProjectMediaResolver.resolve(asset, source: source, workspaceRoot: root, projectRoots: [:]).url?.canonicalPath, image.canonicalPath)
        }
        let media = try file(root, "Assets/Media/library/banner.png")
        let asset = ProjectGraphRecord(sourceID: "assets", kind: .assets, remote: ["path": text("Assets/library/banner.png")])
        XCTAssertEqual(ProjectMediaResolver.resolve(asset, source: source, workspaceRoot: root, projectRoots: [:]).url?.canonicalPath, media.canonicalPath)
    }
    func testLinkedCurrentFolderWinsOverOldCategoryCopy() throws {
        let root = try fixture(), current = root.appendingPathComponent("Projects/Coloring Book")
        let image = try file(current, "FolioAssets/banner.png")
        _ = try file(root, "Projects/Creative/Coloring Book/FolioAssets/banner.png")
        let asset = ProjectGraphRecord(sourceID: "assets", kind: .assets, remote: [
            "path": text("Creative/Coloring Book/FolioAssets/banner.png"), "project": relation(["current-page"])])
        XCTAssertEqual(ProjectMediaResolver.resolve(asset, source: source, workspaceRoot: root,
            projectRoots: ["currentpage": current]).url?.canonicalPath, image.canonicalPath)
    }
    func testAmbiguousLegacyFilesUseUploadedPreview() throws {
        let root = try fixture(), first = root.appendingPathComponent("A/Project"), second = root.appendingPathComponent("B/Project")
        _ = try file(first, "FolioAssets/image.png"); _ = try file(second, "FolioAssets/image.png")
        let asset = ProjectGraphRecord(sourceID: "assets", kind: .assets, remote: ["path": text("Old/Project/FolioAssets/image.png"),
            "preview": ProjectJSON(["type": "files", "files": [["type": "external", "external": ["url": "https://example.com/image.png"]]]])])
        let resolved = ProjectMediaResolver.resolve(asset, source: source, workspaceRoot: root, projectRoots: [:], relatedProjectRoots: [first, second])
        XCTAssertEqual(resolved.url?.absoluteString, "https://example.com/image.png")
        XCTAssertTrue(resolved.isPreview)
    }
    func testLegacyResolutionRejectsEscapingSymlink() throws {
        let root = try fixture(), project = root.appendingPathComponent("Projects/Project")
        let outside = try file(root, "outside.png")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: project.appendingPathComponent("image.png"), withDestinationURL: outside)
        let asset = ProjectGraphRecord(sourceID: "assets", kind: .assets, remote: ["path": text("Old/Project/image.png")])
        XCTAssertNil(ProjectMediaResolver.resolve(asset, source: source, workspaceRoot: root, projectRoots: [:], relatedProjectRoots: [project]).url)
    }
    func testReadingIncomingRelationshipsDoesNotAcceptThemOrOverrideLocalChoice() {
        var project = ProjectGraphRecord(id: "project", pageID: "project-page", sourceID: "projects", kind: .projects,
            local: ["description": text("Local text")], remote: ["thumbnail": relation(["asset-page"])])
        let asset = ProjectGraphRecord(id: "asset", pageID: "asset-page", sourceID: "assets", kind: .assets, remote: ["path": text("image.png")])
        XCTAssertTrue(ProjectGraphIndex(records: [project, asset]).related(to: project).isEmpty)
        let read = ProjectGraphIndex(records: [project, asset], readingIncoming: true).related(to: project)
        XCTAssertEqual(read, [asset]); XCTAssertTrue(read[0].local.isEmpty)
        project.local["thumbnail"] = relation([])
        XCTAssertTrue(ProjectGraphIndex(records: [project, asset], readingIncoming: true).related(to: project).isEmpty)
        var archived = asset; archived.remoteArchived = true
        XCTAssertTrue(ProjectGraphIndex(records: [project, archived], readingIncoming: true).related(to: project).isEmpty)
    }
    func testUnsupportedControlsRemainInLosslessContent() {
        let blocks = [ProjectJSON(["type": "synced_block", "_children": [["type": "unsupported"], ["type": "paragraph", "paragraph": ["rich_text": [["text": ["content": "Story"]]]]]]])]
        let content = NotionPageContent(pageID: "page", editedAt: nil, blocks: blocks)
        XCTAssertEqual(NotionPageContent.unsupportedBlockCount(content.blocks), 1)
        XCTAssertEqual(content.blocks, blocks)
        XCTAssertTrue(content.plainText.contains("Story"))
    }
}
