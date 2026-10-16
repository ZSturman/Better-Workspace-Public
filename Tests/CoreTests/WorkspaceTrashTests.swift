import XCTest
@testable import BetterWorkspaceCore

final class WorkspaceTrashTests: XCTestCase {
    private func fixture(_ run: (WorkspaceLocation, URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bw-delete-\(UUID())")
        let workspace = WorkspaceLocation(root: root.appendingPathComponent("Workspace"))
        try FileManager.default.createDirectory(at: workspace.url(forArea: "Ideas"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workspace.url(forArea: "Projects"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try run(workspace, root.appendingPathComponent("Trash"))
    }

    private func date(_ url: URL) throws -> Date {
        try XCTUnwrap(url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
    }

    func testFolderDeletionPreservesContentsInTrashAndRetryDoesNotDuplicate() throws {
        try fixture { workspace, trash in
            let project = workspace.root.appendingPathComponent("Projects/Example")
            try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
            let note = project.appendingPathComponent("Plan.md")
            try "original".write(to: note, atomically: true, encoding: .utf8)
            let modified = try date(project)
            let destination = try XCTUnwrap(WorkspaceTrash.move(path: "Projects/Example", workspace: workspace,
                isDirectory: true, modifiedAt: modified, into: trash))
            XCTAssertFalse(FileManager.default.fileExists(atPath: project.path))
            XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("Plan.md")), "original")
            XCTAssertNil(try WorkspaceTrash.move(path: "Projects/Example", workspace: workspace, isDirectory: true, modifiedAt: modified, into: trash))
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: trash.path).count, 1)
        }
    }

    func testRejectsRootsForeignMetadataAndSymlinkAncestors() throws {
        try fixture { workspace, trash in
            for path in ["", "Ideas", "Projects", "../escape", "Ideas/../Projects/Example", "Ideas/watcher.item.toml", "Projects/Example/Project.betterproject", "Projects/Example/.git", "_audit/record"] {
                XCTAssertThrowsError(try WorkspaceTrash.resolve(path, workspace: workspace), path)
            }
            let outside = trash.deletingLastPathComponent().appendingPathComponent("Outside")
            try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
            try "keep".write(to: outside.appendingPathComponent("note.md"), atomically: true, encoding: .utf8)
            try FileManager.default.createSymbolicLink(at: workspace.root.appendingPathComponent("Ideas/Escape"), withDestinationURL: outside)
            XCTAssertThrowsError(try WorkspaceTrash.resolve("Ideas/Escape/note.md", workspace: workspace))
            XCTAssertEqual(try String(contentsOf: outside.appendingPathComponent("note.md")), "keep")
        }
    }

    func testStaleOrUnknownSnapshotCannotDeleteFile() throws {
        try fixture { workspace, trash in
            let note = workspace.root.appendingPathComponent("Ideas/Thought.md")
            try "keep".write(to: note, atomically: true, encoding: .utf8)
            let modified = try date(note)
            for expected in [nil, modified.addingTimeInterval(-10)] {
                XCTAssertThrowsError(try WorkspaceTrash.move(path: "Ideas/Thought.md", workspace: workspace,
                    isDirectory: false, modifiedAt: expected, into: trash))
            }
            XCTAssertThrowsError(try WorkspaceTrash.move(path: "Ideas/Thought.md", workspace: workspace,
                isDirectory: true, modifiedAt: modified, into: trash))
            XCTAssertEqual(try String(contentsOf: note), "keep")
        }
    }

    func testPackageIsDeletedAsOneDisplayedFileAndMissingWorkspaceFails() throws {
        try fixture { workspace, trash in
            let package = workspace.root.appendingPathComponent("Projects/Example.app")
            try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
            let modified = try date(package)
            XCTAssertNotNil(try WorkspaceTrash.move(path: "Projects/Example.app", workspace: workspace,
                isDirectory: false, modifiedAt: modified, into: trash))
            try FileManager.default.removeItem(at: workspace.root)
            XCTAssertThrowsError(try WorkspaceTrash.move(path: "Ideas/Thought.md", workspace: workspace,
                isDirectory: false, modifiedAt: modified, into: trash), "Unavailable is never a successful deletion")
        }
    }

    func testInboxTrashCannotTargetAnOrganizedFile() throws {
        try fixture { workspace, trash in
            let inbox = trash.deletingLastPathComponent().appendingPathComponent("Inbox")
            try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
            let db = try Database(inMemory: true)
            let service = IngestService(location: IngestLocation(inbox: inbox, backing: .local), database: db,
                tagStore: TagStore(database: db), workspace: workspace)
            func capture(_ url: URL) -> IngestItem {
                IngestItem(item: WorkspaceItem(url: url, name: url.lastPathComponent, isDirectory: false,
                    kind: .markdown, identity: nil, byteSize: 4, createdAt: nil, rawModifiedAt: nil,
                    contentModifiedAt: nil, immediateChildCount: nil), capturedAt: Date(), source: .unknown,
                    title: url.lastPathComponent)
            }
            let organized = workspace.root.appendingPathComponent("Ideas/Keep.md")
            try "keep".write(to: organized, atomically: true, encoding: .utf8)
            XCTAssertThrowsError(try service.trash(capture(organized), into: trash))
            let disposable = inbox.appendingPathComponent("Capture.md")
            try "recover".write(to: disposable, atomically: true, encoding: .utf8)
            try service.trash(capture(disposable), into: trash)
            XCTAssertFalse(FileManager.default.fileExists(atPath: disposable.path))
            XCTAssertEqual(try String(contentsOf: organized), "keep")
            let recovered = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: trash, includingPropertiesForKeys: nil).first)
            XCTAssertEqual(try String(contentsOf: recovered), "recover")
        }
    }

    func testDeletionCommandsRoundtripValidateAndWaitForAllChildProjections() throws {
        let project = MobileWorkspaceEntry(path: "Projects/Example", parentPath: "Projects", name: "Example",
            isDirectory: true, revision: 1, modifiedAt: Date())
        let edit = MobilePlanningEdit(operation: .trashProject, title: "Example", originalEntry: project)
        XCTAssertNoThrow(try MobilePlanningFiles.validate(edit))
        let decoded = try JSONDecoder().decode(MobilePlanningEdit.self, from: JSONEncoder().encode(edit))
        XCTAssertEqual(decoded, edit)
        let work = MobileWorkItem(id: "w", path: "Projects/Example/Work/Step.bw.md", title: "Step", kind: .task,
            status: .open, stage: .next, priority: .medium, revision: 1)
        XCTAssertFalse(MobilePlanningFiles.index(MobileWorkspaceSnapshot(entries: [project]), reflects: edit))
        XCTAssertFalse(MobilePlanningFiles.index(MobileWorkspaceSnapshot(workItems: [work]), reflects: edit))
        XCTAssertTrue(MobilePlanningFiles.index(MobileWorkspaceSnapshot(), reflects: edit))
        XCTAssertThrowsError(try MobilePlanningFiles.validate(MobilePlanningEdit(operation: .trashIdea, title: "Example", originalEntry: project)))
        XCTAssertThrowsError(try MobilePlanningFiles.validate(MobilePlanningEdit(operation: .trashEntry, title: "Projects",
            originalEntry: MobileWorkspaceEntry(path: "Projects", parentPath: nil, name: "Projects", isDirectory: true, revision: 1, modifiedAt: Date()))))
    }

    func testLocalDeletionRemovesUnsentRecordsAndKeepsRemotePageWithoutArchive() throws {
        let store = try ProjectGraphStore(database: Database(inMemory: true))
        let path = "/fixture/Projects/Example"
        var project = ProjectGraphRecord(pageID: "page", sourceID: "projects", kind: .projects)
        project.localPath = path
        var draft = ProjectGraphRecord(sourceID: "tasks", kind: .tasks)
        draft.localPath = path + "/Work/Draft.bw.md"
        var sibling = ProjectGraphRecord(sourceID: "projects", kind: .projects)
        sibling.localPath = path + " sibling"
        try store.save(project); try store.save(draft); try store.save(sibling)
        try store.recordLocalDeletion(path: path)
        let retained = try XCTUnwrap(store.record(id: project.id))
        XCTAssertTrue(retained.locallyDeleted == true)
        XCTAssertEqual(retained.pageID, "page")
        XCTAssertFalse(retained.archiveRequested)
        XCTAssertNil(try store.record(id: draft.id))
        XCTAssertNil(try store.record(id: sibling.id)?.locallyDeleted)
        try store.recordLocalDeletion(path: path)
        XCTAssertEqual(try store.records().count, 2)
    }
}
