import XCTest
@testable import BetterWorkspaceCore

final class WorkspaceStarterPlanTests: XCTestCase {
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bw-starter-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    func testPreviewPreservesExistingFoldersAndCreatesOnlySelectedMissingCategories() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let projects = root.appendingPathComponent("Projects")
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: false)
        let original = projects.appendingPathComponent("Keep.txt"), bytes = Data("Original content".utf8)
        try bytes.write(to: original)
        let plan = try WorkspaceStarterPlan.preview(root: root)
        XCTAssertEqual(plan.entries.first { $0.id == "Projects" }?.status, .reuse)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Ideas").path), "Preview must never create anything")
        let outcome = try plan.apply(selected: ["Ideas", "To Do"])
        XCTAssertNil(outcome.issue); XCTAssertEqual(Set(outcome.created), ["Ideas", "To Do"])
        XCTAssertEqual(try Data(contentsOf: original), bytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Features").path))
        let repeated = try WorkspaceStarterPlan.preview(root: root)
        XCTAssertEqual(repeated.entries.first { $0.id == "Ideas" }?.status, .reuse)
        XCTAssertThrowsError(try repeated.apply(selected: ["Ideas"]))
    }

    func testExistingFileAndMatchingNamesAreBlockedWithoutOverwriting() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("Ideas"), bytes = Data("Keep file".utf8)
        try bytes.write(to: file)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("projects"), withIntermediateDirectories: false)
        let plan = try WorkspaceStarterPlan.preview(root: root)
        XCTAssertEqual(plan.entries.first { $0.id == "Ideas" }?.status, .blocked)
        XCTAssertEqual(plan.entries.first { $0.id == "Projects" }?.status, .blocked)
        XCTAssertThrowsError(try plan.apply(selected: ["Ideas"]))
        XCTAssertThrowsError(try plan.apply(selected: ["../escape"]))
        XCTAssertEqual(try Data(contentsOf: file), bytes)
    }

    func testFileArrivingAfterPreviewIsRetainedAndNoOtherFolderIsCreated() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let plan = try WorkspaceStarterPlan.preview(root: root)
        let destination = root.appendingPathComponent("Projects"), bytes = Data("Arrived later".utf8)
        try bytes.write(to: destination)
        XCTAssertThrowsError(try plan.apply(selected: ["Projects", "Ideas"]))
        XCTAssertEqual(try Data(contentsOf: destination), bytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Ideas").path))
    }

    func testRootReplacementAndSymlinkDestinationsCannotReceiveWrites() throws {
        let parent = try fixture(); defer { try? FileManager.default.removeItem(at: parent) }
        let root = parent.appendingPathComponent("Workspace"), outside = parent.appendingPathComponent("Unselected")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        let plan = try WorkspaceStarterPlan.preview(root: root)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("Ideas"), withDestinationURL: outside)
        XCTAssertThrowsError(try plan.apply(selected: ["Projects", "Ideas"]))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: outside.path), [])
        XCTAssertEqual(try WorkspaceStarterPlan.preview(root: root).entries.first { $0.id == "Ideas" }?.status, .blocked)
        try FileManager.default.moveItem(at: root, to: parent.appendingPathComponent("Original"))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        XCTAssertThrowsError(try plan.apply(selected: ["Projects"]))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [])
        let link = parent.appendingPathComponent("RootLink")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root)
        XCTAssertThrowsError(try WorkspaceStarterPlan.preview(root: link))
    }
}
