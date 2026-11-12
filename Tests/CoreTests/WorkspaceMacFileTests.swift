import XCTest
@testable import BetterWorkspaceCore

final class WorkspaceMacFileTests: XCTestCase {
    private final class Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bw-files-" + UUID().uuidString)
        let scope = UUID()
        let projects: ProjectStore
        var workspace: WorkspaceLocation { .init(root: root.appendingPathComponent("Workspace")) }
        var journal: URL { root.appendingPathComponent("Private") }
        init() throws {
            for name in ["For Reference", "Ideas", "Projects", "To Do"] {
                try FileManager.default.createDirectory(at: root.appendingPathComponent("Workspace/" + name), withIntermediateDirectories: true)
            }
            projects = ProjectStore(database: try Database(url: root.appendingPathComponent("Private.sqlite")))
        }
        func remove() { try? FileManager.default.removeItem(at: root) }
        func create(_ revision: WorkspaceRecordRevision, graph: WorkspaceReplica, bindings: [WorkspaceMacBinding] = []) throws -> (URL, WorkspaceMacBinding) {
            let request = try WorkspaceMacWorkCreation.prepare(recordID: revision.recordID, in: graph, bindings: bindings, workspace: workspace, directoryPath: revision.content.kind == .idea ? "Ideas" : "For Reference")
            let result = try WorkspaceMacDirectoryCreation.materialize(request, in: graph, bindings: bindings, workspace: workspace, journalDirectory: journal, projects: projects)
            XCTAssertEqual(try WorkspaceMacDirectoryCreation.materialize(request, in: graph, bindings: bindings, workspace: workspace, journalDirectory: journal, projects: projects).1, result.1)
            return result
        }
    }

    func testNoteAndIdeaCreationPreserveCollisionsAndRejectChangedReplay() throws {
        let f = try Fixture(); defer { f.remove() }
        for kind in [WorkspaceRecordContent.Kind.note, .idea] {
            let area = kind == .idea ? "Ideas" : "For Reference"
            let original = f.workspace.root.appendingPathComponent(area + "/Same.md")
            let bytes = Data("Existing original".utf8); try bytes.write(to: original)
            var graph = try WorkspaceReplica()
            let revision = try graph.save(content: .init(kind: kind, title: "Same", body: "Offline body"), expectedHeads: [], deviceID: UUID(), origin: .iOS)
            let (url, binding) = try f.create(revision, graph: graph)
            XCTAssertEqual(url.lastPathComponent, "Same-iOS.md")
            XCTAssertEqual(try Data(contentsOf: original), bytes)
            let source = try WorkspaceMacFileSource.readBound(binding, workspace: f.workspace, scope: f.scope)
            XCTAssertEqual(source.id, revision.recordID); XCTAssertEqual(source.title, "Same"); XCTAssertEqual(source.body, "Offline body")
            let observed = try WorkspaceMacProjection.observe(.init(), in: graph, bindings: [binding], deviceID: UUID(), files: [source])
            XCTAssertEqual(try observed.replica.fingerprint, try graph.fingerprint)
            try Data("Changed by another editor".utf8).write(to: url)
            XCTAssertThrowsError(try f.create(revision, graph: graph))
            XCTAssertEqual(try String(contentsOf: url), "Changed by another editor")
        }
    }

    func testMaximumPortableBodyRemainsReadableAfterAddingTitle() throws {
        let f = try Fixture(); defer { f.remove() }
        var graph = try WorkspaceReplica()
        let body = String(repeating: "A", count: MobilePlanningFiles.maximumTextBytes)
        let revision = try graph.save(content: .init(kind: .note, title: "Limit", body: body), expectedHeads: [], deviceID: UUID(), origin: .iOS)
        let (_, binding) = try f.create(revision, graph: graph)
        XCTAssertEqual(try WorkspaceMacFileSource.readBound(binding, workspace: f.workspace, scope: f.scope).body, body)
    }

    func testFoldersNestedNotesAndWorkRetainParentsAndCanonicalIdentities() throws {
        let f = try Fixture(); defer { f.remove() }
        var graph = try WorkspaceReplica()
        let folder = try graph.save(content: .init(kind: .folder, title: "Plans", body: "Private folder description"), expectedHeads: [], deviceID: UUID(), origin: .iOS)
        let (_, folderBinding) = try f.create(folder, graph: graph)
        let note = try graph.save(content: .init(kind: .note, title: "Nested", body: "Text", parentID: folder.recordID), expectedHeads: [], deviceID: UUID(), origin: .iOS)
        let (_, noteBinding) = try f.create(note, graph: graph, bindings: [folderBinding])
        let task = try graph.save(content: .init(kind: .task, title: "Nested task", body: "Do this", parentID: folder.recordID), expectedHeads: [], deviceID: UUID(), origin: .iOS)
        let request = try WorkspaceMacWorkCreation.prepare(recordID: task.recordID, in: graph, bindings: [folderBinding, noteBinding], workspace: f.workspace, directoryPath: "To Do")
        let (work, workBinding) = try request.materialize(in: graph, bindings: [folderBinding, noteBinding], workspace: f.workspace)
        XCTAssertEqual(WorkspaceMacProjection.workspaceFolderID(in: work), folder.recordID)
        let candidates = MobileWorkspaceProjection.candidates(from: .init(itemsByArea: [:], workItems: [work], tags: [], tagsByPath: [:]), workspace: f.workspace)
        let mobile = try XCTUnwrap(candidates.compactMap { if case .workItem(let value) = $0 { return value }; return nil }.first)
        XCTAssertEqual(mobile.workspaceFolderID, folder.recordID)
        let bindings = [folderBinding, noteBinding, workBinding]
        let files = try [folderBinding, noteBinding].map { try WorkspaceMacFileSource.readBound($0, workspace: f.workspace, scope: f.scope) }
        let observed = try WorkspaceMacProjection.observe(.init(workItems: [mobile]), in: graph, bindings: bindings, deviceID: UUID(), files: files)
        XCTAssertEqual(try observed.replica.fingerprint, try graph.fingerprint)
        guard case .unchanged = try WorkspaceMacProjection.prepareWorkSave(recordID: task.recordID, in: graph, bindings: bindings, workspace: f.workspace) else { return XCTFail("Nested work was changed by observation") }
        let save = try WorkspaceMacFileSave.prepare(binding: folderBinding, in: graph, bindings: bindings, workspace: f.workspace, scope: f.scope)
        XCTAssertNil(save.replacementText); XCTAssertEqual(save.source.body, folder.content.body)
    }

    func testUnmarkedNoteImportsWithoutMutatingOriginalAndExplicitEditKeepsIdentity() throws {
        let f = try Fixture(); defer { f.remove() }
        let url = f.workspace.root.appendingPathComponent("For Reference/Original.md")
        let text = "# Existing heading\n\nOriginal text"; try Data(text.utf8).write(to: url)
        let source = try WorkspaceMacFileSource.read(.init(relativePath: "For Reference/Original.md", kind: .note), workspace: f.workspace, bindings: [], scope: f.scope)
        XCTAssertNil(try WorkspaceContentIdentity.read(at: url)); XCTAssertEqual(source.body, text)
        let observation = try WorkspaceMacProjection.observe(.init(), in: WorkspaceReplica(), bindings: [], deviceID: UUID(), files: [source])
        var graph = observation.replica; let binding = try XCTUnwrap(observation.bindings.first)
        var desired = try XCTUnwrap(graph.records.first?.resolved?.content); desired.title = "Edited title"; desired.body = "Changed offline"; desired.isComplete = true
        _ = try graph.save(recordID: binding.recordID, content: desired, expectedHeads: [binding.observedRevisionID], deviceID: UUID(), origin: .iOS)
        let save = try WorkspaceMacFileSave.prepare(binding: binding, in: graph, bindings: [binding], workspace: f.workspace, scope: f.scope)
        _ = try TextDocumentService().save(try XCTUnwrap(save.replacementText), at: url, expecting: try XCTUnwrap(save.snapshot))
        try WorkspaceContentIdentity.write(.init(id: binding.recordID, kind: .note), at: url)
        let check = try WorkspaceMacFileSave.prepare(binding: binding, in: graph, bindings: [binding], workspace: f.workspace, scope: f.scope)
        XCTAssertNil(check.replacementText); XCTAssertEqual(check.original.id, source.id)
        let request = WorkspaceMacWriteRequest(binding: binding, revisionID: try XCTUnwrap(graph.records.first?.resolved?.id))
        let acknowledged = try XCTUnwrap(request.acknowledgedBindings([binding]).first)
        XCTAssertEqual(acknowledged.fileIdentity, binding.fileIdentity)
        XCTAssertEqual(acknowledged.sourceCreatedAt, binding.sourceCreatedAt)
        let renamed = url.deletingLastPathComponent().appendingPathComponent("Renamed.md"); try FileManager.default.moveItem(at: url, to: renamed)
        let moved = try WorkspaceMacFileSource.read(.init(relativePath: "For Reference/Renamed.md", kind: .note), workspace: f.workspace, bindings: [binding], scope: f.scope)
        XCTAssertEqual(moved.id, source.id); XCTAssertEqual(moved.title, "Edited title")
    }

    func testConcurrentSourceEditIsPreservedAndUnsafeSourcesRefused() throws {
        let f = try Fixture(); defer { f.remove() }
        var graph = try WorkspaceReplica()
        let base = try graph.save(content: .init(kind: .note, title: "Note", body: "Before"), expectedHeads: [], deviceID: UUID(), origin: .iOS)
        let (url, binding) = try f.create(base, graph: graph)
        var desired = base.content; desired.body = "Phone edit"
        _ = try graph.save(recordID: base.recordID, content: desired, expectedHeads: [base.id], deviceID: UUID(), origin: .iOS)
        let external = "# Note\n\nConcurrent Mac edit"; try Data(external.utf8).write(to: url)
        XCTAssertThrowsError(try WorkspaceMacFileSave.prepare(binding: binding, in: graph, bindings: [binding], workspace: f.workspace, scope: f.scope))
        XCTAssertEqual(try String(contentsOf: url), external)
        let link = f.workspace.root.appendingPathComponent("For Reference/Link.md"); try FileManager.default.createSymbolicLink(at: link, withDestinationURL: url)
        XCTAssertThrowsError(try WorkspaceMacFileSource.read(.init(relativePath: "For Reference/Link.md", kind: .note), workspace: f.workspace, bindings: [], scope: f.scope))
        let pipe = f.workspace.root.appendingPathComponent("For Reference/Pipe.md")
        XCTAssertEqual(mkfifo(pipe.path, 0o600), 0)
        XCTAssertThrowsError(try WorkspaceMacFileSource.read(.init(relativePath: "For Reference/Pipe.md", kind: .note), workspace: f.workspace, bindings: [], scope: f.scope))
        let large = f.workspace.root.appendingPathComponent("For Reference/Large.md"); try Data(repeating: 65, count: MobilePlanningFiles.maximumTextBytes + 1).write(to: large)
        XCTAssertThrowsError(try WorkspaceMacFileSource.read(.init(relativePath: "For Reference/Large.md", kind: .note), workspace: f.workspace, bindings: [], scope: f.scope))
        let directory = f.workspace.root.appendingPathComponent("Ideas/Service unavailable"); try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let unknown = try WorkspaceMacFileSource.read(.init(relativePath: "Ideas/Service unavailable", kind: .idea), workspace: f.workspace, bindings: [], scope: f.scope)
        let deferred = try WorkspaceMacProjection.observe(.init(), in: graph, bindings: [binding], deviceID: UUID(), files: [unknown])
        XCTAssertEqual(deferred.deferredSourceIDs.count, 1); XCTAssertEqual(try deferred.replica.fingerprint, try graph.fingerprint)
    }
}
