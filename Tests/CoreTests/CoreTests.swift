import XCTest
import CloudKit
@testable import BetterWorkspaceCore

final class NamingTests: XCTestCase {

    func testTitleFromFirstLine() {
        XCTAssertEqual(CaptureNaming.title(fromFirstLine: "Look into building a local ESP32 control surface"),
                       "Look into building a local ESP32 control surface")
        XCTAssertEqual(CaptureNaming.title(fromFirstLine: "## Research alternatives to Tailscale Funnel"),
                       "Research alternatives to Tailscale Funnel")
        XCTAssertNil(CaptureNaming.title(fromFirstLine: "   "))
    }

    func testSafeFilenameStripsPathSeparators() {
        XCTAssertEqual(CaptureNaming.safeFilename("a/b:c"), "a b c")
        XCTAssertFalse(CaptureNaming.safeFilename(".hidden").hasPrefix("."))
        XCTAssertFalse(CaptureNaming.safeFilename("").isEmpty)
    }

    func testMarkdownBodyUsesFirstLineAsHeading() {
        let (heading, body) = CaptureNaming.markdownBody(for: "Build a thing\n\nwith details")
        XCTAssertEqual(heading, "Build a thing")
        XCTAssertTrue(body.hasPrefix("# Build a thing"))
        XCTAssertTrue(body.contains("with details"))
    }
}

final class NoiseFilterTests: XCTestCase {

    func testForeignMetadataIsFiltered() {
        // These belong to Workspace Watcher and Better Projects. They are hidden from
        // display and never read — an Ideas folder containing only watcher.item.toml
        // must read as empty.
        XCTAssertTrue(NoiseFilter.isForeignMetadata(name: "watcher.item.toml"))
        XCTAssertTrue(NoiseFilter.isForeignMetadata(name: "Project.betterproject"))
        XCTAssertTrue(NoiseFilter.isForeignMetadata(name: ".DS_Store"))
        XCTAssertFalse(NoiseFilter.isForeignMetadata(name: "README.md"))
        XCTAssertFalse(NoiseFilter.isForeignMetadata(name: "notes.toml"))
    }

    func testHiddenRespectsShowHidden() {
        XCTAssertTrue(NoiseFilter.isHidden(name: ".env", showHidden: false))
        XCTAssertFalse(NoiseFilter.isHidden(name: ".env", showHidden: true))
        XCTAssertTrue(NoiseFilter.isHidden(name: "watcher.item.toml", showHidden: true))
    }
}

final class FileKindTests: XCTestCase {

    func testClassificationCoversWhatTheWorkspaceActuallyHolds() {
        func kind(_ name: String, dir: Bool = false) -> FileKind {
            FileKind.classify(url: URL(fileURLWithPath: "/tmp/\(name)"), isDirectory: dir)
        }
        XCTAssertEqual(kind("x", dir: true), .folder)
        XCTAssertEqual(kind("notes.md"), .markdown)
        XCTAssertEqual(kind("hammerspoon-observability.log"), .log)
        XCTAssertEqual(kind("base.stl"), .model3D)
        XCTAssertEqual(kind("Dynamic Dataset.xlsx"), .spreadsheet)
        XCTAssertEqual(kind("Walking.jpg"), .image)
        XCTAssertEqual(kind("clip.mp4"), .video)
        XCTAssertEqual(kind("bundle.zip"), .archive)
        XCTAssertEqual(kind("script.py"), .code)
        XCTAssertEqual(kind("events.db"), .data)
        XCTAssertEqual(kind("paper.pdf"), .document)
    }
}

final class TextDocumentServiceTests: XCTestCase {
    private var root: URL!
    private let service = TextDocumentService()

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bw-text-editor-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testExplicitTextSaveReplacesOnlyTheOpenedVersion() throws {
        let note = root.appendingPathComponent("note.md")
        try "before\n".write(to: note, atomically: true, encoding: .utf8)
        let snapshot = try service.read(at: note)

        let saved = try service.save("after\n", at: note, expecting: snapshot)
        XCTAssertEqual(saved.text, "after\n")
        XCTAssertEqual(try String(contentsOf: note, encoding: .utf8), "after\n")
    }

    func testTextSaveRefusesAnExternalChange() throws {
        let note = root.appendingPathComponent("note.md")
        try "before\n".write(to: note, atomically: true, encoding: .utf8)
        let snapshot = try service.read(at: note)
        try "someone else\n".write(to: note, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try service.save("mine\n", at: note, expecting: snapshot)) { error in
            guard case TextDocumentService.Error.changedOnDisk = error else {
                return XCTFail("Expected changedOnDisk, got \(error)")
            }
        }
        XCTAssertEqual(try String(contentsOf: note, encoding: .utf8), "someone else\n")
    }

    func testOnlyPlainTextExtensionsAreEditable() {
        XCTAssertTrue(TextDocumentService.supportsEditing(root.appendingPathComponent("notes.md")))
        XCTAssertTrue(TextDocumentService.supportsEditing(root.appendingPathComponent("server.swift")))
        XCTAssertFalse(TextDocumentService.supportsEditing(root.appendingPathComponent("database.sqlite")))
        XCTAssertFalse(TextDocumentService.supportsEditing(root.appendingPathComponent("paper.pdf")))
    }
}

final class ProjectFolderRoleTests: XCTestCase {
    private func item(_ name: String, directory: Bool) -> WorkspaceItem {
        let url = URL(fileURLWithPath: "/tmp/Projects/\(name)")
        return WorkspaceItem(url: url, name: name, isDirectory: directory,
                             kind: FileKind.classify(url: url, isDirectory: directory),
                             identity: nil, byteSize: 0, createdAt: nil, rawModifiedAt: nil,
                             contentModifiedAt: nil, immediateChildCount: directory ? 0 : nil)
    }

    func testUnderscoreProjectFoldersAreOrganizationSpaces() {
        XCTAssertEqual(item("_Utilities", directory: true).projectFolderRole, .utilities)
        XCTAssertEqual(item("_Closed", directory: true).projectFolderRole, .closed)
        XCTAssertEqual(item("_Collections", directory: true).projectFolderRole, .collections)
        XCTAssertEqual(item("_Later", directory: true).projectFolderRole, .organizer)
    }

    func testOnlyUnderscoreDirectoriesBecomeProjectSpaces() {
        XCTAssertNil(item("Utilities", directory: true).projectFolderRole)
        XCTAssertNil(item("_Utilities.md", directory: false).projectFolderRole)
    }
}

final class FileIdentityTests: XCTestCase {

    func testIdentitySurvivesRenameAndMove() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bw-identity-\(UUID().uuidString)")
        let a = root.appendingPathComponent("a", isDirectory: true)
        let b = root.appendingPathComponent("b", isDirectory: true)
        try FileManager.default.createDirectory(at: a, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: b, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let file = a.appendingPathComponent("note.md")
        try "hello".write(to: file, atomically: true, encoding: .utf8)
        let before = FileIdentityResolver.identity(of: file)
        XCTAssertNotNil(before)

        let moved = b.appendingPathComponent("Renamed Note.md")
        try FileManager.default.moveItem(at: file, to: moved)
        let after = FileIdentityResolver.identity(of: moved)

        XCTAssertEqual(before, after, "Same-volume move must preserve the APFS file ID")
        XCTAssertEqual(before?.key, after?.key)
        XCTAssertEqual(FileIdentity(key: before!.key), before)
    }
}

final class WorkItemTests: XCTestCase {

    func testRecommendationUsesOnlyOpenNowAndNextItems() {
        let placeholder = URL(fileURLWithPath: "/tmp/placeholder.bw.md")
        let later = WorkItem(kind: .task, title: "Explicitly later", stage: .later,
                             priority: .high, url: placeholder)
        let completed = WorkItem(kind: .task, title: "Done", status: .completed,
                                 stage: .now, priority: .high, url: placeholder)
        let next = WorkItem(kind: .feature, title: "Next high", stage: .next,
                            priority: .high, url: placeholder)
        let nowLow = WorkItem(kind: .task, title: "Now low", stage: .now,
                              priority: .low, url: placeholder)
        let nowHigh = WorkItem(kind: .task, title: "Now high", stage: .now,
                               priority: .high, url: placeholder)

        XCTAssertEqual(WorkItemRecommendation.nextAction(in: [later, completed, next, nowLow, nowHigh])?.id,
                       nowHigh.id)
        XCTAssertNil(WorkItemRecommendation.nextAction(in: [later, completed]))
    }

    func testMarkdownWorkItemRoundTripsAndRemainsHumanReadable() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bw-work-items-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = WorkItemService()
        let draft = WorkItem(kind: .task, title: "Ship portable task files", stage: .now,
                             priority: .high, projectPath: "Projects/Better Workspace",
                             body: "Keep the record useful outside the app.", url: root.appendingPathComponent("placeholder"))

        let saved = try service.create(draft, in: root)
        XCTAssertTrue(saved.url.lastPathComponent.hasSuffix(".bw.md"))
        let markdown = try String(contentsOf: saved.url, encoding: .utf8)
        XCTAssertTrue(markdown.contains("better-workspace: 1"))
        XCTAssertTrue(markdown.contains("# Ship portable task files"))
        XCTAssertEqual(saved.projectPath, "Projects/Better Workspace")
        XCTAssertEqual(saved.body, "Keep the record useful outside the app.")

        let completed = try service.complete(saved)
        XCTAssertEqual(completed.status, .completed)
        XCTAssertNotNil(completed.completedAt)
    }

    func testRelationshipsSurviveMovingTheSingleFile() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bw-work-items-\(UUID().uuidString)", isDirectory: true)
        let source = root.appendingPathComponent("To Do", isDirectory: true)
        let destination = root.appendingPathComponent("Projects/Better Workspace", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = WorkItemService()
        let featureID = UUID().uuidString
        let draft = WorkItem(kind: .milestone, title: "Foundation", parentID: featureID,
                             relatedIDs: [UUID().uuidString], url: source.appendingPathComponent("placeholder"))
        let saved = try service.create(draft, in: source)
        let moved = try service.move(saved, to: destination)

        XCTAssertFalse(FileManager.default.fileExists(atPath: saved.url.path))
        XCTAssertEqual(moved.parentID, featureID)
        XCTAssertEqual(moved.relatedIDs, draft.relatedIDs)
        XCTAssertEqual(service.items(under: root).map(\.id), [moved.id])
    }

    func testMalformedWorkItemNeverInventsAnUnstableIdentityOrDate() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bw-malformed-work-item-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let service = WorkItemService()

        let missingID = root.appendingPathComponent("missing-id.bw.md")
        try "---\nbetter-workspace: 1\nkind: task\ntitle: \\\"Broken\\\"\n---\n".write(to: missingID, atomically: true, encoding: .utf8)
        XCTAssertNil(service.read(at: missingID))

        let dated = root.appendingPathComponent("bad-date.bw.md")
        try "---\nbetter-workspace: 1\nid: stable\nkind: task\ntitle: \\\"Bad date\\\"\ndue: definitely-not-a-date\n---\n".write(to: dated, atomically: true, encoding: .utf8)
        XCTAssertNil(service.read(at: dated)?.dueDate)
    }

    func testDuplicateWorkItemIDsHaveADeterministicSingleRepresentative() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bw-duplicate-work-item-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let service = WorkItemService()
        _ = try service.create(WorkItem(id: "copied-id", kind: .task, title: "Z copy", url: root.appendingPathComponent("placeholder")), in: root)
        let first = root.appendingPathComponent("A copy.bw.md")
        try "---\nbetter-workspace: 1\nid: copied-id\nkind: task\ntitle: \\\"A copy\\\"\nstatus: open\nstage: next\npriority: medium\n---\n".write(to: first, atomically: true, encoding: .utf8)

        let indexed = service.items(under: root)
        XCTAssertEqual(indexed.count, 1)
        XCTAssertEqual(indexed.first?.url.canonicalPath, first.canonicalPath)
    }

    func testUpdateRefusesToOverwriteAnExternalEdit() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bw-work-item-conflict-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let service = WorkItemService()
        let original = try service.create(WorkItem(kind: .task, title: "Keep edits", body: "original", url: root.appendingPathComponent("placeholder")), in: root)
        try "external editor wins".write(to: original.url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_900_000_000)], ofItemAtPath: original.url.path)

        var attempted = original
        attempted.body = "app edit"
        XCTAssertThrowsError(try service.update(attempted)) { error in
            XCTAssertTrue(error is WorkItemService.WorkItemError)
        }
        XCTAssertEqual(try String(contentsOf: original.url, encoding: .utf8), "external editor wins")
    }

    func testFolderDiscoveryFindsFinderCreatedFoldersWithoutACodeChange() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bw-folders-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["To Do", "Client Notes", "Projects", "_audit", ".project-core"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        try "x".write(to: root.appendingPathComponent("loose.txt"), atomically: true, encoding: .utf8)
        let store = AreaConfigurationStore(url: root.appendingPathComponent("private/Areas.json"))
        let folders = try XCTUnwrap(WorkspaceFolderDiscovery().folders(in: WorkspaceLocation(root: root), store: store))

        XCTAssertEqual(folders.map(\.name), ["Client Notes", "Projects", "To Do"])
        let notes = try XCTUnwrap(folders.first { $0.name == "Client Notes" })
        XCTAssertNil(notes.purposeBuilt)
        XCTAssertTrue(notes.isUnfamiliar)
        XCTAssertEqual(notes.settings.layout, .list)
        XCTAssertEqual(notes.settings.ingest, .ordinary)

        let projects = try XCTUnwrap(folders.first { $0.name == "Projects" })
        XCTAssertEqual(projects.purposeBuilt, .projects)
        XCTAssertEqual(projects.settings.layout, .purposeBuilt)

        let toDo = try XCTUnwrap(folders.first { $0.name == "To Do" })
        XCTAssertNil(toDo.purposeBuilt, "a work queue is configuration, not a hardcoded area")
        XCTAssertEqual(toDo.settings.layout, .workQueue)
        XCTAssertEqual(toDo.settings.workItemKind, .task)
        XCTAssertFalse(toDo.isUnfamiliar)

        // Configuring an area writes only the private file, never the folder.
        try store.set(AreaConfiguration(layout: .table), forFolderNamed: "Client Notes", identity: notes.identity)
        let configured = try XCTUnwrap(WorkspaceFolderDiscovery().folders(in: WorkspaceLocation(root: root), store: store)?
            .first { $0.name == "Client Notes" })
        XCTAssertEqual(configured.settings.layout, .table)
        XCTAssertFalse(configured.isUnfamiliar)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: notes.url.path), [])
    }

    func testDiscoveryReportsAnUnreadableRootAsUnknownNotEmpty() {
        let missing = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("bw-missing-\(UUID().uuidString)")
        let store = AreaConfigurationStore(url: missing.appendingPathComponent("Areas.json"))
        XCTAssertNil(WorkspaceFolderDiscovery().folders(in: WorkspaceLocation(root: missing), store: store))
    }

    /// A dependency tree can hold a file whose name ends in `.bw.md` — a fixture, a
    /// vendored document — and walking into it is what made indexing the real
    /// workspace cost 1.16 million files instead of 236 thousand.
    func testIndexingSkipsDependencyAndBuildDirectories() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bw-prune-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let service = WorkItemService()

        let real = root.appendingPathComponent("Projects/Thing")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        _ = try service.create(WorkItem(kind: .task, title: "Real work", url: real), in: real)

        for buried in ["node_modules/pkg", "build/artifacts", ".git/objects", "Projects/Thing/.venv/lib"] {
            let directory = root.appendingPathComponent(buried)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            _ = try service.create(WorkItem(kind: .task, title: "Buried", url: directory), in: directory)
        }

        let found = service.items(under: root)
        XCTAssertEqual(found.map(\.title), ["Real work"])
    }
}

final class TagStoreTests: XCTestCase {

    private func makeStore() throws -> (Database, TagStore, URL) {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bw-tags-\(UUID().uuidString).sqlite")
        let db = try Database(url: url)
        return (db, TagStore(database: db), url)
    }

    func testOneSharedTagAcrossAreas() throws {
        let (_, store, dbURL) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dbURL) }

        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bw-areas-\(UUID().uuidString)")
        let idea = root.appendingPathComponent("Ideas/Foo", isDirectory: true)
        let project = root.appendingPathComponent("Projects/Bar", isDirectory: true)
        try FileManager.default.createDirectory(at: idea, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let tag = try XCTUnwrap(store.createTag(named: "AI"))
        // Same name, different case, must not create a second tag.
        XCTAssertEqual(store.createTag(named: "ai")?.id, tag.id)
        XCTAssertEqual(store.allTags().count, 1)

        store.assign(tagID: tag.id, to: idea, area: "Ideas")
        store.assign(tagID: tag.id, to: project, area: "Projects")

        XCTAssertEqual(store.tags(for: idea).map(\.name), ["AI"])
        XCTAssertEqual(store.tags(for: project).map(\.name), ["AI"])
        XCTAssertEqual(store.objects(withTagID: tag.id).count, 2)
        XCTAssertEqual(Set(store.objects(withTagID: tag.id).compactMap(\.area)), ["Ideas", "Projects"])

        store.unassign(tagID: tag.id, from: idea)
        XCTAssertTrue(store.tags(for: idea).isEmpty)
        XCTAssertEqual(store.objects(withTagID: tag.id).count, 1)
    }

    func testSpellingVariantsOfATagNameNeverBecomeASecondTag() throws {
        let (_, store, dbURL) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dbURL) }

        let tag = try XCTUnwrap(store.createTag(named: "Raspberry Pi"))
        for variant in ["raspberry pi", "RaspberryPi", "raspberry-pi"] {
            XCTAssertEqual(store.createTag(named: variant)?.id, tag.id, variant)
        }
        let phoneVariant = Tag(id: "phone-raspberrypi", name: "raspberrypi")
        XCTAssertEqual(store.createTag(phoneVariant)?.id, tag.id, "A phone-made variant resolves to the Mac's tag")
        XCTAssertEqual(store.allTags().map(\.name), ["Raspberry Pi"])

        let other = try XCTUnwrap(store.createTag(named: "Hardware"))
        store.renameTag(id: other.id, to: "RASPBERRY PI")
        XCTAssertEqual(store.allTags().map(\.name), ["Hardware", "Raspberry Pi"],
                       "Renaming into another tag's name is refused")
        store.renameTag(id: tag.id, to: "raspberry pi")
        XCTAssertEqual(store.allTags().map(\.name), ["Hardware", "raspberry pi"], "Re-casing its own name is fine")
    }

    func testPhoneCreatedTagRetainsItsIdentityOnTheMac() throws {
        let (_, store, dbURL) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dbURL) }

        let phoneTag = Tag(id: "phone-tag-id", name: "Field Notes", colorIndex: 6,
                           createdAt: Date(timeIntervalSince1970: 1_000))
        let created = try XCTUnwrap(store.createTag(phoneTag))

        XCTAssertEqual(created.id, phoneTag.id)
        XCTAssertEqual(created.name, "Field Notes")
        XCTAssertEqual(created.colorIndex, 6)
        XCTAssertEqual(store.createTag(phoneTag)?.id, phoneTag.id,
                       "Replayed tag-creation commands must stay idempotent.")
    }

    func testMissingFilesAreUncountedUntilExplicitlyForgotten() throws {
        let (_, store, dbURL) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dbURL) }
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let kept = root.appendingPathComponent("kept.md")
        let gone = root.appendingPathComponent("gone.md")
        try "kept".write(to: kept, atomically: true, encoding: .utf8)
        try "gone".write(to: gone, atomically: true, encoding: .utf8)
        let tag = try XCTUnwrap(store.createTag(named: "Fixture"))
        store.assign(tagID: tag.id, to: kept, area: "Ideas")
        store.assign(tagID: tag.id, to: gone, area: "Ideas")
        XCTAssertEqual(store.tagUsageCounts()[tag.id], 2)
        try FileManager.default.removeItem(at: gone)
        XCTAssertEqual(store.tagUsageCounts()[tag.id], 1)
        XCTAssertEqual(store.objects(withTagID: tag.id).count, 2)
        XCTAssertEqual(store.forgetMissingObjects(withTagID: tag.id), 1)
        XCTAssertEqual(store.objects(withTagID: tag.id).count, 1)
        XCTAssertEqual(try String(contentsOf: kept), "kept")
    }

    func testTagsSurviveAMove() throws {
        let (_, store, dbURL) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dbURL) }

        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bw-move-\(UUID().uuidString)")
        let inbox = root.appendingPathComponent("Inbox", isDirectory: true)
        let ideas = root.appendingPathComponent("Ideas", isDirectory: true)
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: ideas, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let captured = inbox.appendingPathComponent("some-note.md")
        try "# Some Note".write(to: captured, atomically: true, encoding: .utf8)

        let tag = try XCTUnwrap(store.createTag(named: "Hardware"))
        store.assign(tagID: tag.id, to: captured, area: nil)
        let oldKey = store.identityKey(for: captured)

        let destination = ideas.appendingPathComponent("Some Note.md")
        try FileManager.default.moveItem(at: captured, to: destination)
        store.rebindObject(fromIdentityKey: oldKey, to: destination, area: "Ideas")

        XCTAssertEqual(store.tags(for: destination).map(\.name), ["Hardware"])
        let objects = store.objects(withTagID: tag.id)
        XCTAssertEqual(objects.count, 1)
        XCTAssertEqual(objects.first?.area, "Ideas")
        XCTAssertEqual(objects.first?.lastPath, destination.canonicalPath)
    }
}

final class IngestServiceTests: XCTestCase {

    private struct Harness {
        let root: URL
        let workspace: WorkspaceLocation
        let ingest: IngestService
        let tagStore: TagStore
    }

    private func makeHarness() throws -> Harness {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bw-ingest-\(UUID().uuidString)")
        let workspaceRoot = root.appendingPathComponent("Workspace", isDirectory: true)
        for area in WorkspaceArea.allCases {
            try FileManager.default.createDirectory(
                at: workspaceRoot.appendingPathComponent(area.directoryName), withIntermediateDirectories: true)
        }
        let inbox = root.appendingPathComponent("Inbox", isDirectory: true)
        let db = try Database(url: root.appendingPathComponent("db.sqlite"))
        let tagStore = TagStore(database: db)
        let workspace = WorkspaceLocation(root: workspaceRoot)
        let ingest = IngestService(
            location: IngestLocation(inbox: inbox, backing: .local),
            database: db, tagStore: tagStore, workspace: workspace
        )
        return Harness(root: root, workspace: workspace, ingest: ingest, tagStore: tagStore)
    }

    /// A sync provider replaces a file by removing and re-adding it. A scan that lands
    /// in between must not throw away the capture's private title.
    func testACaptureBrieflyMissingKeepsItsTitle() async throws {
        let h = try makeHarness()
        defer { try? FileManager.default.removeItem(at: h.root) }
        let fs = FilesystemService()
        let item = try h.ingest.captureText("Original words")
        h.ingest.setTitle("A title I chose", for: item)
        let text = try String(contentsOf: item.url, encoding: .utf8)

        try FileManager.default.removeItem(at: item.url)
        let during = await h.ingest.pendingItems(fsService: fs)
        XCTAssertEqual(during?.count, 0)

        // Back, as a new file at the same path.
        try text.write(to: item.url, atomically: true, encoding: .utf8)
        let after = await h.ingest.pendingItems(fsService: fs)
        XCTAssertEqual(after?.first?.title, "A title I chose", "The title survives one missed scan")

        // Gone for two scans running: really gone, and forgotten.
        try FileManager.default.removeItem(at: item.url)
        _ = await h.ingest.pendingItems(fsService: fs)
        _ = await h.ingest.pendingItems(fsService: fs)
        try text.write(to: item.url, atomically: true, encoding: .utf8)
        let reborn = await h.ingest.pendingItems(fsService: fs)
        XCTAssertEqual(reborn?.first?.title, "Original words", "A file gone for two scans starts afresh")
    }

    /// Capturing never replaces a file already in the inbox.
    func testCapturingNeverOverwritesAnInboxFile() throws {
        let h = try makeHarness()
        defer { try? FileManager.default.removeItem(at: h.root) }
        let first = try h.ingest.captureText("Same note")
        let second = try h.ingest.captureText("Same note")
        XCTAssertNotEqual(first.url, second.url)
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.url.path))
    }

    func testTypedTextBecomesARealMarkdownFile() throws {
        let h = try makeHarness()
        defer { try? FileManager.default.removeItem(at: h.root) }

        let item = try h.ingest.captureText("Look into building a local ESP32 control surface")
        XCTAssertEqual(item.url.pathExtension, "md")
        XCTAssertTrue(FileManager.default.fileExists(atPath: item.url.path),
                      "Capture must exist on disk, not only in the database")
        let contents = try String(contentsOf: item.url, encoding: .utf8)
        XCTAssertTrue(contents.hasPrefix("# Look into building a local ESP32 control surface"))
    }

    func testDeletingAnInboxItemRemovesOnlyTheCapture() async throws {
        let h = try makeHarness()
        defer { try? FileManager.default.removeItem(at: h.root) }
        let item = try h.ingest.captureText("Disposable capture")
        let workspaceFile = h.workspace.url(for: .ideas).appendingPathComponent("Keep.md")
        try "keep".write(to: workspaceFile, atomically: true, encoding: .utf8)

        try h.ingest.delete(item)

        XCTAssertFalse(FileManager.default.fileExists(atPath: item.url.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: workspaceFile.path))
        let remaining = await h.ingest.pendingItems(fsService: FilesystemService())
        XCTAssertTrue(remaining?.isEmpty == true)
    }

    func testUntitledCaptureStillGetsAFilename() throws {
        let h = try makeHarness()
        defer { try? FileManager.default.removeItem(at: h.root) }
        let item = try h.ingest.captureText("   \n\n#\n")
        XCTAssertTrue(FileManager.default.fileExists(atPath: item.url.path))
        XCTAssertEqual(item.url.pathExtension, "md")
    }

    func testEmptyCaptureIsRejected() throws {
        let h = try makeHarness()
        defer { try? FileManager.default.removeItem(at: h.root) }
        XCTAssertThrowsError(try h.ingest.captureText("   "))
    }

    func testClassifyMovesTheFileAndKeepsTags() async throws {
        let h = try makeHarness()
        defer { try? FileManager.default.removeItem(at: h.root) }

        let item = try h.ingest.captureText("Research alternatives to Tailscale Funnel")
        let tag = try XCTUnwrap(h.tagStore.createTag(named: "Research"))
        h.tagStore.assign(tagID: tag.id, to: item.url, area: nil)

        let pending = await h.ingest.pendingItems(fsService: FilesystemService()) ?? []
        XCTAssertEqual(pending.count, 1)

        let destination = try h.ingest.classify(pending[0], into: .ideas, renamingTo: "Tailscale Alternatives")

        XCTAssertFalse(FileManager.default.fileExists(atPath: item.url.path), "Source must be gone")
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertEqual(destination.deletingLastPathComponent().lastPathComponent, "Ideas")
        XCTAssertEqual(destination.lastPathComponent, "Tailscale Alternatives.md")
        XCTAssertEqual(h.tagStore.tags(for: destination).map(\.name), ["Research"],
                       "Tags must survive the classification move")

        let after = await h.ingest.pendingItems(fsService: FilesystemService()) ?? []
        XCTAssertTrue(after.isEmpty, "Classified items leave the inbox")
    }

    func testClassifyCanUseAnExistingToOrForSubfolder() async throws {
        let h = try makeHarness()
        defer { try? FileManager.default.removeItem(at: h.root) }
        let toRead = h.workspace.root.appendingPathComponent("To Read", isDirectory: true)
        try FileManager.default.createDirectory(at: toRead, withIntermediateDirectories: true)

        let item = try h.ingest.captureText("Read the automation notes")
        let tag = try XCTUnwrap(h.tagStore.createTag(named: "Reading"))
        h.tagStore.assign(tagID: tag.id, to: item.url, area: nil)
        let pendingItems = await h.ingest.pendingItems(fsService: FilesystemService()) ?? []
        let pending = try XCTUnwrap(pendingItems.first)
        let destination = try h.ingest.classify(pending, intoDirectory: toRead, renamingTo: nil)

        XCTAssertEqual(destination.deletingLastPathComponent().canonicalPath, toRead.canonicalPath)
        XCTAssertEqual(h.tagStore.tags(for: destination).map(\.name), ["Reading"])
    }

    func testFolderMovesIntactIntoProjects() async throws {
        let h = try makeHarness()
        defer { try? FileManager.default.removeItem(at: h.root) }

        let source = h.root.appendingPathComponent("SomeProject", isDirectory: true)
        try FileManager.default.createDirectory(at: source.appendingPathComponent("src"), withIntermediateDirectories: true)
        try "# Readme".write(to: source.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try "print()".write(to: source.appendingPathComponent("src/main.py"), atomically: true, encoding: .utf8)

        _ = try h.ingest.importItem(at: source, source: .desktopDrop)
        let pending = await h.ingest.pendingItems(fsService: FilesystemService()) ?? []
        XCTAssertEqual(pending.count, 1)
        XCTAssertTrue(pending[0].item.isDirectory)

        let destination = try h.ingest.classify(pending[0], into: .projects, renamingTo: "Some Project")
        XCTAssertEqual(destination.lastPathComponent, "Some Project")
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.appendingPathComponent("README.md").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.appendingPathComponent("src/main.py").path),
                      "Folder must move intact, including nested contents")
    }

    func testExternallyAddedFileBecomesAPendingItem() async throws {
        let h = try makeHarness()
        defer { try? FileManager.default.removeItem(at: h.root) }

        h.ingest.location.ensureExists()
        let dropped = h.ingest.location.inbox.appendingPathComponent("dropped-by-finder.txt")
        try "hello".write(to: dropped, atomically: true, encoding: .utf8)

        let pending = await h.ingest.pendingItems(fsService: FilesystemService()) ?? []
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending[0].source, .external,
                       "Anything that appears in the inbox by other means is still an ingest item")
    }

    func testClassifyRefusesToOverwrite() async throws {
        let h = try makeHarness()
        defer { try? FileManager.default.removeItem(at: h.root) }

        let existing = h.workspace.url(for: .ideas).appendingPathComponent("Taken.md")
        try "already here".write(to: existing, atomically: true, encoding: .utf8)

        _ = try h.ingest.captureText("Taken")
        let pending = await h.ingest.pendingItems(fsService: FilesystemService()) ?? []
        XCTAssertThrowsError(try h.ingest.classify(pending[0], into: .ideas, renamingTo: "Taken"))
        XCTAssertEqual(try String(contentsOf: existing, encoding: .utf8), "already here",
                       "An existing Workspace item must never be overwritten")
    }

    func testCaptureNeverCollides() throws {
        let h = try makeHarness()
        defer { try? FileManager.default.removeItem(at: h.root) }
        let a = try h.ingest.captureText("Same title")
        let b = try h.ingest.captureText("Same title")
        XCTAssertNotEqual(a.url, b.url)
        XCTAssertTrue(FileManager.default.fileExists(atPath: a.url.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: b.url.path))
    }

    /// The data-loss case this guards: a failed inbox read used to arrive as an empty
    /// inbox, and every private row was then deleted as an orphan.
    func testAnUnreadableInboxKeepsTheQueueAndItsPrivateMetadata() async throws {
        let h = try makeHarness()
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: h.ingest.location.inbox.path)
            try? FileManager.default.removeItem(at: h.root)
        }
        try h.ingest.captureText("Something I do not want to lose")
        let before = await h.ingest.pendingItems(fsService: FilesystemService())
        let original = try XCTUnwrap(before?.first)
        h.ingest.setTitle("Renamed in Better Workspace", for: original)
        h.ingest.setState(.deferred, for: original)

        try FileManager.default.setAttributes(
            [.posixPermissions: 0], ofItemAtPath: h.ingest.location.inbox.path)
        let stalled = await h.ingest.pendingItems(fsService: FilesystemService())
        XCTAssertNil(stalled, "An unreadable inbox must report as stalled, not as empty")

        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: h.ingest.location.inbox.path)
        let after = await h.ingest.pendingItems(fsService: FilesystemService())
        XCTAssertEqual(after?.count, 1)
        XCTAssertEqual(after?.first?.title, "Renamed in Better Workspace")
        XCTAssertEqual(after?.first?.state, .deferred)
    }

    func testInPlaceReplacementKeepsPrivateIngestMetadata() async throws {
        let h = try makeHarness()
        defer { try? FileManager.default.removeItem(at: h.root) }
        let captured = try h.ingest.captureText("Keep my ingest state")
        let initialItems = await h.ingest.pendingItems(fsService: FilesystemService())
        let original = try XCTUnwrap(initialItems?.first)
        h.ingest.setTitle("Renamed in Better Workspace", for: original)
        h.ingest.setState(.deferred, for: original)

        // Atomic writes replace the inode while keeping the path, exactly as iCloud
        // hydration and many editors do.
        try "replacement content".write(to: captured.url, atomically: true, encoding: .utf8)
        let reconciledItems = await h.ingest.pendingItems(fsService: FilesystemService())
        let reconciled = try XCTUnwrap(reconciledItems?.first)
        XCTAssertEqual(reconciled.title, "Renamed in Better Workspace")
        XCTAssertEqual(reconciled.state, .deferred)
    }
}

final class FilesystemServiceTests: XCTestCase {

    /// An empty directory and an unreadable one are different answers, and the ingest
    /// queue's private metadata depends on the difference: a failure that arrived as
    /// "no items" made `pendingItems` treat every capture's title and deferred state as
    /// an orphaned row and delete it.
    func testAnUnreadableDirectoryIsNilWhileAnEmptyOneIsEmpty() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("bw-unreadable-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
            try? FileManager.default.removeItem(at: root)
        }

        let empty = await FilesystemService.items(inDirectory: root, timeout: .seconds(5))
        XCTAssertEqual(empty?.isEmpty, true, "A directory that was read and holds nothing is empty")

        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: root.path)
        let unreadable = await FilesystemService.items(inDirectory: root, timeout: .seconds(5))
        XCTAssertNil(unreadable, "A directory that could not be read is unknown, not empty")
    }

    /// A directory that is not there holds nothing; that really is an answer.
    func testAMissingDirectoryListsAsEmptyRatherThanAsAFailure() async {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("bw-absent-\(UUID().uuidString)", isDirectory: true)
        let items = await FilesystemService.items(inDirectory: missing, timeout: .seconds(5))
        XCTAssertEqual(items?.isEmpty, true)
    }

    func testTimedDirectorySetupCreatesALocalDirectory() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("bw-ensure-directory-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let created = await FilesystemService.ensureDirectory(root, timeout: .seconds(1))
        XCTAssertTrue(created)
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
    }

    func testListingHidesForeignMetadataSoEmptyIdeasReadAsEmpty() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bw-fs-\(UUID().uuidString)")
        let ideas = root.appendingPathComponent("Ideas", isDirectory: true)
        let idea = ideas.appendingPathComponent("An Idea", isDirectory: true)
        try FileManager.default.createDirectory(at: idea, withIntermediateDirectories: true)
        // Exactly what the real Workspace looks like: the folder holds nothing but
        // another application's metadata.
        try "id = 1".write(to: idea.appendingPathComponent("watcher.item.toml"), atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: root) }

        let fs = FilesystemService()
        let items = try await fs.items(inDirectory: ideas)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].name, "An Idea")
        XCTAssertEqual(items[0].immediateChildCount, 0,
                       "watcher.item.toml must not count as content")

        let inside = try await fs.items(inDirectory: idea)
        XCTAssertTrue(inside.isEmpty)
    }

    func testMissingDirectoryReturnsEmptyRatherThanThrowing() async throws {
        let fs = FilesystemService()
        let items = try await fs.items(inDirectory: URL(fileURLWithPath: "/nope/does/not/exist"))
        XCTAssertTrue(items.isEmpty)
    }
}

final class DatabaseTests: XCTestCase {

    private func makeDatabase() throws -> Database {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("DatabaseTests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("store.sqlite")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        return try Database(url: url)
    }

    func testATransactionCommitsEverythingItWrote() throws {
        let db = try makeDatabase()
        let store = TagStore(database: db)
        try db.transaction {
            for name in ["AI", "Hardware", "Writing"] { store.createTag(named: name) }
        }
        XCTAssertEqual(store.allTags().map(\.name), ["AI", "Hardware", "Writing"])
    }

    /// The reason an import runs in one: a migration that stops halfway leaves a project
    /// rated on three metrics out of eight, which reads as a judgement rather than as an
    /// interrupted import.
    func testAFailedTransactionLeavesTheStoreAsItWas() throws {
        let db = try makeDatabase()
        let store = TagStore(database: db)
        store.createTag(named: "Kept")

        struct Interrupted: Error {}
        XCTAssertThrowsError(try db.transaction {
            store.createTag(named: "Half written")
            throw Interrupted()
        })
        XCTAssertEqual(store.allTags().map(\.name), ["Kept"])
    }

    func testATransactionHandsBackItsValue() throws {
        let db = try makeDatabase()
        let count = try db.transaction { 41 + 1 }
        XCTAssertEqual(count, 42)
    }

    /// The ordinary case, so the recovery path cannot quietly become the normal one.
    func testAHealthyStoreOpensWhereItWasAsked() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("DatabaseTests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("store.sqlite")
        addTeardownBlock { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let first = Database.opened(preferring: url)
        XCTAssertEqual(first.backing, .file(url))
        TagStore(database: first.database).createTag(named: "Kept across opens")

        let second = Database.opened(preferring: url)
        XCTAssertEqual(second.backing, .file(url))
        XCTAssertEqual(TagStore(database: second.database).allTags().map(\.name), ["Kept across opens"])
    }

    /// A store that cannot be opened must not take the app down, and must not be
    /// deleted either: it may still be recoverable, and that is not this app's call.
    func testAnUnopenableStoreIsMovedAsideRatherThanLostOrFatal() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("DatabaseTests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("store.sqlite")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        // A directory where a file is expected: sqlite cannot open it, however it is asked.
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)

        let opened = Database.opened(preferring: url)
        guard case .recovered(let movedAside) = opened.backing else {
            return XCTFail("Expected a recovered store, got \(opened.backing)")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: movedAside.path),
                      "The unreadable store has to be kept, not deleted")
        // And the fresh store works, at the place it belongs.
        let store = TagStore(database: opened.database)
        store.createTag(named: "Written after recovery")
        XCTAssertEqual(store.allTags().map(\.name), ["Written after recovery"])
    }

    /// The last resort. It has to work with no filesystem, permissions or free space,
    /// because it is what keeps the app from trapping at launch.
    func testAnInMemoryStoreWorksAndKeepsNothing() throws {
        let db = try Database(inMemory: true)
        let store = TagStore(database: db)
        store.createTag(named: "This session only")
        XCTAssertEqual(store.allTags().map(\.name), ["This session only"])
        // A second in-memory store shares nothing with the first.
        XCTAssertTrue(TagStore(database: try Database(inMemory: true)).allTags().isEmpty)
    }

    func testRatingsImportedInOneBatchAllLand() throws {
        let db = try makeDatabase()
        let store = ProjectStore(database: db)
        let project = store.register(url: URL(fileURLWithPath: "/tmp/bw-batch-project"), name: "Batched")
        try store.batch {
            store.setRating(5, metricID: "clarity", for: project.id)
            store.setRating(3, metricID: "momentum", for: project.id)
        }
        XCTAssertEqual(store.ratings(for: project.id), ["clarity": 5, "momentum": 3])
    }
}

final class WorkspaceLocationTests: XCTestCase {

    func testAreaContainment() {
        let location = WorkspaceLocation(root: URL(fileURLWithPath: "/tmp/W"))
        XCTAssertEqual(location.area(containing: URL(fileURLWithPath: "/tmp/W/Ideas/Foo")), .ideas)
        XCTAssertEqual(location.area(containing: URL(fileURLWithPath: "/tmp/W/Projects/Bar/baz.txt")), .projects)
        XCTAssertNil(location.area(containing: URL(fileURLWithPath: "/tmp/W/Something")))
        XCTAssertNil(location.area(containing: URL(fileURLWithPath: "/tmp/Other/Ideas")))
    }

    func testAreaNameIsTheTopLevelFolderForAnyFolder() {
        let location = WorkspaceLocation(root: URL(fileURLWithPath: "/tmp/W"))
        XCTAssertEqual(location.areaName(containing: URL(fileURLWithPath: "/tmp/W/Client Work/a/b.md")), "Client Work")
        XCTAssertEqual(location.areaName(containing: URL(fileURLWithPath: "/tmp/W/To Do")), "To Do")
        XCTAssertNil(location.areaName(containing: URL(fileURLWithPath: "/tmp/W")))
        XCTAssertNil(location.areaName(containing: URL(fileURLWithPath: "/tmp/Wx/To Do")))
        XCTAssertNil(location.area(containing: URL(fileURLWithPath: "/tmp/W/Client Work/a")))
    }

    func testEveryPurposeBuiltAreaResolvesToItsOwnView() {
        for area in WorkspaceArea.allCases {
            let settings = AreaSettings(resolving: AreaDefaults.configuration(forFolderNamed: area.directoryName),
                                        purposeBuilt: area)
            XCTAssertEqual(settings.layout, .purposeBuilt, area.rawValue)
            XCTAssertNotEqual(settings.symbol, "folder", "\(area.rawValue) should have its own symbol")
        }
    }
}

final class AreaConfigurationTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("bw-areas-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private var fileURL: URL { directory.appendingPathComponent("Areas.json") }

    func testPersonalSettingsOverrideOnlyTheFieldsTheySet() {
        let defaults = AreaDefaults.configuration(forFolderNamed: "To Do")
        let personal = AreaConfiguration(sort: .newest, symbol: "star")
        let settings = AreaSettings(resolving: personal.layered(over: defaults), purposeBuilt: nil)
        XCTAssertEqual(settings.symbol, "star")
        XCTAssertEqual(settings.sort, .newest)
        // Untouched fields keep following the defaults.
        XCTAssertEqual(settings.layout, .workQueue)
        XCTAssertEqual(settings.ingest, .primary)
        XCTAssertEqual(settings.subtitle, "Action queue")
    }

    func testAPurposeBuiltLayoutWithNothingToBuildFallsBackToAList() {
        let settings = AreaSettings(resolving: AreaConfiguration(layout: .purposeBuilt), purposeBuilt: nil)
        XCTAssertEqual(settings.layout, .list)
    }

    func testSettingsRoundTripThroughThePrivateFile() throws {
        let store = AreaConfigurationStore(url: fileURL)
        try store.set(AreaConfiguration(layout: .gallery, ingest: .excluded), forFolderNamed: "To Watch", identity: "1:2")
        let reopened = AreaConfigurationStore(url: fileURL)
        XCTAssertEqual(reopened.entry(forFolderNamed: "To Watch")?.configuration.layout, .gallery)
        XCTAssertEqual(reopened.entry(forFolderNamed: "To Watch")?.configuration.ingest, .excluded)
        XCTAssertEqual(reopened.entry(forFolderNamed: "To Watch")?.identity, "1:2")

        // Returning to defaults removes the entry rather than storing an empty one.
        try reopened.set(AreaConfiguration(), forFolderNamed: "To Watch", identity: nil)
        XCTAssertNil(AreaConfigurationStore(url: fileURL).entry(forFolderNamed: "To Watch"))
    }

    /// The file is meant to be readable and editable by hand, so what it looks like is
    /// part of the contract.
    func testTheFileIsReadableJSONKeyedByFolderName() throws {
        let store = AreaConfigurationStore(url: fileURL)
        try store.set(AreaConfiguration(layout: .table), forFolderNamed: "Client Work", identity: nil)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: fileURL)) as? [String: Any])
        XCTAssertEqual(json["version"] as? Int, 1)
        let areas = try XCTUnwrap(json["areas"] as? [String: Any])
        let entry = try XCTUnwrap(areas["Client Work"] as? [String: Any])
        XCTAssertEqual((entry["configuration"] as? [String: Any])?["layout"] as? String, "table")
    }

    func testAHandEditedFileIsHonored() throws {
        try #"{"version":1,"areas":{"Study":{"configuration":{"layout":"gallery","hidden":true}}}}"#
            .write(to: fileURL, atomically: true, encoding: .utf8)
        let store = AreaConfigurationStore(url: fileURL)
        XCTAssertNil(store.loadError)
        XCTAssertEqual(store.entry(forFolderNamed: "Study")?.configuration.layout, .gallery)
        XCTAssertEqual(store.entry(forFolderNamed: "Study")?.configuration.hidden, true)
    }

    func testAnUnreadableFileIsReportedAndMovedAsideRatherThanOverwritten() throws {
        try "{ not json".write(to: fileURL, atomically: true, encoding: .utf8)
        let store = AreaConfigurationStore(url: fileURL)
        XCTAssertNotNil(store.loadError)
        XCTAssertNil(store.entry(forFolderNamed: "Anything"))
        // Reading alone never touches it.
        XCTAssertEqual(try String(contentsOf: fileURL, encoding: .utf8), "{ not json")

        try store.set(AreaConfiguration(layout: .table), forFolderNamed: "Study", identity: nil)
        let aside = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasPrefix("Areas.unreadable-") }
        XCTAssertEqual(aside.count, 1)
        XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent(aside[0]), encoding: .utf8), "{ not json")
        XCTAssertEqual(AreaConfigurationStore(url: fileURL).entry(forFolderNamed: "Study")?.configuration.layout, .table)
    }

    func testSettingsFollowAFolderRenamedInFinder() throws {
        let workspace = directory.appendingPathComponent("Workspace")
        let original = workspace.appendingPathComponent("Clients")
        try FileManager.default.createDirectory(at: original, withIntermediateDirectories: true)
        let store = AreaConfigurationStore(url: fileURL)
        let location = WorkspaceLocation(root: workspace)
        let before = try XCTUnwrap(WorkspaceFolderDiscovery().folders(in: location, store: store)?.first)
        try store.set(AreaConfiguration(layout: .table, symbol: "star"), forFolderNamed: "Clients", identity: before.identity)

        try FileManager.default.moveItem(at: original, to: workspace.appendingPathComponent("Client Work"))
        let after = try XCTUnwrap(WorkspaceFolderDiscovery().folders(in: location, store: store)?.first)
        XCTAssertEqual(after.name, "Client Work")
        XCTAssertEqual(after.settings.layout, .table)
        XCTAssertEqual(after.settings.symbol, "star")
        XCTAssertNil(store.entry(forFolderNamed: "Clients"))
        XCTAssertNotNil(AreaConfigurationStore(url: fileURL).entry(forFolderNamed: "Client Work"))
    }

    /// A folder that is simply gone keeps its settings, in case it comes back.
    func testSettingsForAMissingFolderAreKept() throws {
        let store = AreaConfigurationStore(url: fileURL)
        try store.set(AreaConfiguration(layout: .gallery), forFolderNamed: "Away", identity: "9:9")
        store.reconcile(discovered: [("Elsewhere", "1:1")])
        XCTAssertEqual(store.entry(forFolderNamed: "Away")?.configuration.layout, .gallery)
    }

    func testExcludedFoldersAreNotOfferedForIngestAndPromotedOnesLead() throws {
        let root = directory.appendingPathComponent("Workspace")
        for name in ["Projects", "Logs", "Client Work", "Scratch", "Ideas"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        let store = AreaConfigurationStore(url: fileURL)
        try store.set(AreaConfiguration(ingest: .excluded), forFolderNamed: "Scratch", identity: nil)
        try store.set(AreaConfiguration(ingest: .primary), forFolderNamed: "Client Work", identity: nil)
        let folders = try XCTUnwrap(WorkspaceFolderDiscovery().folders(in: WorkspaceLocation(root: root), store: store))
        XCTAssertEqual(DestinationOrder.destinations(folders).map(\.name), ["Projects", "Ideas", "Client Work", "Logs"])
    }
}

final class ProjectStoreTests: XCTestCase {

    private func makeStore() throws -> (ProjectStore, URL) {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bw-projects-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let db = try Database(url: root.appendingPathComponent("private.sqlite"))
        return (ProjectStore(database: db), root)
    }

    func testRatingsSurviveRenamingTheProjectFolder() throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let before = root.appendingPathComponent("Beatboxd")
        try FileManager.default.createDirectory(at: before, withIntermediateDirectories: true)

        let record = store.register(url: before)
        store.setRating(4, metricID: MetricDefinition.enjoyment.id, for: record.id)
        store.setNotionPageID("33baec94-4d3c-8016-a557-ffd72e8895e6", for: record.id)

        let after = root.appendingPathComponent("Beatboxd Renamed")
        try FileManager.default.moveItem(at: before, to: after)

        let found = try XCTUnwrap(store.record(for: after))
        XCTAssertEqual(found.id, record.id)
        XCTAssertEqual(store.ratings(for: found.id)[MetricDefinition.enjoyment.id], 4)
        XCTAssertEqual(found.notionPageID, "33baec94-4d3c-8016-a557-ffd72e8895e6")
        XCTAssertEqual(found.lastPath, after.canonicalPath)
    }

    func testPersonConfirmedNotionLinkIsStoredWithoutReplacingExistingHistory() throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let firstURL = root.appendingPathComponent("First")
        let secondURL = root.appendingPathComponent("Second")
        try FileManager.default.createDirectory(at: firstURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondURL, withIntermediateDirectories: true)
        let first = store.register(url: firstURL)
        let second = store.register(url: secondURL)

        try store.setExplicitNotionPageID("project-1", for: first.id)
        XCTAssertEqual(store.record(id: first.id)?.notionPageID, "project-1")
        XCTAssertThrowsError(try store.setExplicitNotionPageID("project-1", for: second.id))
        XCTAssertThrowsError(try store.setExplicitNotionPageID("another-project", for: first.id))
        XCTAssertEqual(store.record(id: first.id)?.notionPageID, "project-1")
        XCTAssertNil(store.record(id: second.id)?.notionPageID)
    }

    /// A project made after Better Projects' documents were imported has no Watcher id,
    /// and without one it never shows a measurement or a session.
    func testNewProjectsJoinWatcherByFileIdentityWithoutDisturbingExistingLinks() throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        func project(_ name: String) throws -> (ProjectRecord, String) {
            let url = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return (store.register(url: url), try XCTUnwrap(FileIdentityResolver.identity(of: url)?.key))
        }
        let (fresh, freshKey) = try project("Private AI Gateway")
        let (imported, importedKey) = try project("Beatboxd")
        store.setExternalIDs(watcherID: "from-document", documentID: "doc-1", for: imported.id)
        let (clash, clashKey) = try project("Clash")

        let linked = store.linkWatcherIDs(byIdentityKey: [
            freshKey: "w-fresh",
            importedKey: "w-other",        // never replaces an imported link
            clashKey: "from-document",     // never hands out an id twice
        ])

        XCTAssertEqual(linked, 1)
        XCTAssertEqual(store.record(id: fresh.id)?.watcherID, "w-fresh")
        XCTAssertEqual(store.record(id: imported.id)?.watcherID, "from-document")
        XCTAssertEqual(store.record(id: imported.id)?.documentID, "doc-1")
        XCTAssertNil(store.record(id: clash.id)?.watcherID)
    }

    func testWatcherProjectIdentitiesUseTheSameKeyAsFileIdentity() throws {
        let json = """
        {"schema_version": 1, "data": [
          {"id": "w1", "path": "Projects/A", "device": 16777229, "inode": 51833116, "status": "active"},
          {"id": "w2", "path": "Projects/B", "device": 16777229, "inode": 42, "status": "deleted"},
          {"id": "w3", "path": "Projects/C", "device": null, "inode": null, "status": "active"}
        ]}
        """
        let identities = try MeasurementService.decodeProjectIdentities(Data(json.utf8))
        XCTAssertEqual(identities, [FileIdentity(volume: "16777229", fileID: 51833116).key: "w1"])
    }

    /// Better Workspace has to be completely usable by someone who has never had a
    /// Notion account, so nothing may require the association to be present.
    func testAProjectIsFullyUsableWithNoNotionAssociation() throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("Local Only")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let record = store.register(url: directory)
        XCTAssertNil(record.notionPageID)
        XCTAssertFalse(record.hasNotionLink)
        XCTAssertNil(record.notionURL)

        store.setRating(5, metricID: MetricDefinition.qualityOfLife.id, for: record.id)
        store.setRating(2, metricID: MetricDefinition.effort.id, for: record.id)
        let score = store.score(for: record.id)
        XCTAssertEqual(score.answeredCount, 2)
        XCTAssertNotNil(score.projectScore)
    }

    func testClearingARatingIsDistinctFromNeverAnswering() throws {
        let (store, root) = try makeStore()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("P")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let record = store.register(url: directory)

        XCTAssertNil(store.ratings(for: record.id)[MetricDefinition.urgency.id])
        store.setRating(3, metricID: MetricDefinition.urgency.id, for: record.id)
        XCTAssertEqual(store.ratings(for: record.id)[MetricDefinition.urgency.id], 3)
        store.setRating(nil, metricID: MetricDefinition.urgency.id, for: record.id)
        XCTAssertNil(store.ratings(for: record.id)[MetricDefinition.urgency.id])
    }
}

final class ProjectScoreTests: XCTestCase {

    /// Reproduces a project from the real Better Projects cache. Scoring it here must
    /// give what that app gave, or ported ratings would silently change meaning.
    func testMatchesBetterProjectsArithmeticOnAFullyRatedProject() {
        let ratings = [
            "effort": 3, "costSavings": 1, "ongoingBurden": 1, "personalImportance": 1,
            "financialCost": 1, "demonstrationValue": 1, "readiness": 1, "explorationValue": 2,
            "incomePotential": 1, "enjoyment": 3, "qualityOfLife": 1, "leverage": 1,
            "abandonmentCost": 1, "skillDevelopment": 2, "opportunityPotential": 1,
            "careerRelevance": 2, "goalAlignment": 1, "outcomeUncertainty": 2, "urgency": 1,
            "dependencyImportance": 1, "knowledgeGain": 2,
        ]
        let score = ProjectScore(ratings: ratings)
        XCTAssertEqual(score.answeredCount, 21)
        XCTAssertEqual(score.coverage, 1.0, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(score.ratedScore), 22.1, accuracy: 0.1)
        // Full coverage means the project score is the rated score, undiscounted.
        XCTAssertEqual(try XCTUnwrap(score.projectScore), 22.1, accuracy: 0.1)
    }

    func testCostMetricsInvertSoHigherAlwaysMeansBetter() {
        XCTAssertEqual(MetricDefinition.enjoyment.desirability(for: 5), 100)
        XCTAssertEqual(MetricDefinition.enjoyment.desirability(for: 1), 0)
        // Effort is a cost: a 5 is a lot of effort, which is not desirable.
        XCTAssertEqual(MetricDefinition.effort.desirability(for: 5), 0)
        XCTAssertEqual(MetricDefinition.effort.desirability(for: 1), 100)
    }

    /// One optimistic answer out of twenty-one must not read as an excellent project.
    func testThinCoverageIsPulledTowardTheMiddle() {
        let score = ProjectScore(ratings: ["qualityOfLife": 5])
        XCTAssertEqual(try XCTUnwrap(score.ratedScore), 100, accuracy: 0.001)
        let project = try! XCTUnwrap(score.projectScore)
        XCTAssertGreaterThan(project, 50)
        XCTAssertLessThan(project, 55)
    }

    func testNothingAnsweredIsUnknownRatherThanZero() {
        let score = ProjectScore(ratings: [:])
        XCTAssertNil(score.ratedScore)
        XCTAssertNil(score.projectScore)
    }

    func testTaxonomyIsTwentyOneMetricsInSevenGroups() {
        XCTAssertEqual(MetricDefinition.all.count, 21)
        XCTAssertEqual(MetricGroup.allGroups.count, 7)
        XCTAssertEqual(Set(MetricDefinition.all.map(\.id)).count, 21)
        for metric in MetricDefinition.all {
            XCTAssertEqual(metric.anchors.count, 5, "\(metric.id) must explain all five ratings")
            XCTAssertNotNil(MetricGroup.find(id: metric.groupID), "\(metric.id) has no group")
        }
        XCTAssertEqual(MetricGroup.defaultWeights.values.reduce(0, +), 100, accuracy: 0.001)
    }
}

final class WidgetSnapshotStoreTests: XCTestCase {

    func testIngestSnapshotRoundTripsAndMissingStoreIsEmpty() {
        let suite = "WidgetSnapshotStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = WidgetSnapshotStore(defaults: defaults)

        XCTAssertNil(store.ingestSnapshot())
        let expected = IngestWidgetSnapshot(
            state: .ready,
            inboxCount: 4,
            newestCapture: IngestWidgetCapture(name: "A thought.md", modifiedAt: Date(timeIntervalSince1970: 42)),
            updatedAt: Date(timeIntervalSince1970: 43)
        )
        store.save(expected)
        XCTAssertEqual(store.ingestSnapshot(), expected)
    }

    /// Resolving the inbox fails transiently on a cold launch. The widget must keep
    /// showing the last real count instead of falling back to "set up your Inbox".
    func testSetupStateDoesNotEraseAUsefulIngestSnapshot() {
        let suite = "WidgetSnapshotStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = WidgetSnapshotStore(defaults: defaults)

        let good = IngestWidgetSnapshot(
            state: .ready,
            inboxCount: 7,
            newestCapture: IngestWidgetCapture(name: "A thought.md", modifiedAt: Date(timeIntervalSince1970: 10))
        )
        store.save(good)

        let wrote = store.savePreservingLastKnownGood(
            IngestWidgetSnapshot(state: .needsInbox, inboxCount: 0, newestCapture: nil))
        XCTAssertFalse(wrote, "A transient setup state must not be written over a ready snapshot")
        XCTAssertEqual(store.ingestSnapshot(), good)

        // A ready snapshot always wins, including one that legitimately reports zero.
        let emptied = IngestWidgetSnapshot(state: .ready, inboxCount: 0, newestCapture: nil)
        XCTAssertTrue(store.savePreservingLastKnownGood(emptied))
        XCTAssertEqual(store.ingestSnapshot(), emptied)
    }

    /// A first run has nothing cached, so the setup state is the only honest answer.
    func testSetupStateIsWrittenWhenNothingIsCached() {
        let suite = "WidgetSnapshotStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = WidgetSnapshotStore(defaults: defaults)

        let setup = IngestWidgetSnapshot(state: .needsInbox, inboxCount: 0, newestCapture: nil)
        XCTAssertTrue(store.savePreservingLastKnownGood(setup))
        XCTAssertEqual(store.ingestSnapshot()?.state, .needsInbox)

        // And once it is the cached value it may be replaced by another setup state.
        XCTAssertTrue(store.savePreservingLastKnownGood(setup))
    }

    /// The widget's reload kind has to match the extension's, across two targets.
    func testWidgetKindsAreStable() {
        XCTAssertEqual(WidgetKind.ingestInbox, "IngestInboxWidget")
        XCTAssertEqual(WidgetKind.nextWork, "NextWorkWidget")
        XCTAssertEqual(WidgetKind.recentIdeas, "RecentIdeasWidget")
    }

    func testRecentIdeasAreCappedAndUndatedIdeasSortLast() {
        let now = Date(timeIntervalSince1970: 5_000)
        let snapshot = MobileWorkspaceSnapshot(
            ideas: [
                MobileIdea(path: "Ideas/Undated.md", title: "Undated", revision: 1, modifiedAt: nil),
                MobileIdea(path: "Ideas/A.md", title: "A", revision: 1, modifiedAt: now),
                MobileIdea(path: "Ideas/B.md", title: "B", revision: 1, modifiedAt: now.addingTimeInterval(-1)),
                MobileIdea(path: "Ideas/C.md", title: "C", revision: 1, modifiedAt: now.addingTimeInterval(-2)),
                MobileIdea(path: "Ideas/D.md", title: "D", revision: 1, modifiedAt: now.addingTimeInterval(-3)),
            ],
            fetchedAt: now
        )

        let result = WorkspaceWidgetSnapshot.make(from: snapshot)
        XCTAssertEqual(result.recentIdeas.map(\.title), ["A", "B", "C"])
        XCTAssertNil(result.nextWorkItem)
        XCTAssertEqual(result.openWorkCount, 0)
    }

    /// The initialiser caps the list too, so a hand-built snapshot cannot overflow the
    /// three rows the widget draws.
    func testSnapshotInitialiserCapsIdeasAndClampsCounts() {
        let many = (0..<9).map { WorkspaceWidgetIdea(title: "Idea \($0)", modifiedAt: nil) }
        let snapshot = WorkspaceWidgetSnapshot(nextWorkItem: nil, openWorkCount: -4,
                                               inProgressWorkCount: -1, recentIdeas: many,
                                               fetchedAt: Date(timeIntervalSince1970: 1))
        XCTAssertEqual(snapshot.recentIdeas.count, 3)
        XCTAssertEqual(snapshot.openWorkCount, 0)
        XCTAssertEqual(snapshot.inProgressWorkCount, 0)
        XCTAssertEqual(IngestWidgetSnapshot(state: .ready, inboxCount: -3, newestCapture: nil).inboxCount, 0)
    }

    func testWorkspaceSummaryUsesDeterministicNextWorkAndRecentIdeas() {
        let now = Date(timeIntervalSince1970: 1_000)
        let snapshot = MobileWorkspaceSnapshot(
            workItems: [
                MobileWorkItem(id: "later", path: "To Do/later.bw.md", title: "Later item", kind: .task,
                               status: .open, stage: .later, priority: .high, revision: 1),
                MobileWorkItem(id: "next", path: "To Do/next.bw.md", title: "Next item", kind: .task,
                               status: .open, stage: .next, priority: .high, revision: 1),
                MobileWorkItem(id: "now-medium", path: "To Do/now-medium.bw.md", title: "Medium now", kind: .task,
                               status: .open, stage: .now, priority: .medium, revision: 1),
                MobileWorkItem(id: "now-high", path: "To Do/now-high.bw.md", title: "High now", kind: .feature,
                               status: .inProgress, stage: .now, priority: .high,
                               projectPath: "Projects/Better Workspace", revision: 1),
                MobileWorkItem(id: "done", path: "To Do/done.bw.md", title: "Completed", kind: .task,
                               status: .completed, stage: .now, priority: .high, revision: 1),
            ],
            ideas: [
                MobileIdea(path: "Ideas/Old.md", title: "Old", revision: 1, modifiedAt: now.addingTimeInterval(-20)),
                MobileIdea(path: "Ideas/New.md", title: "New", revision: 1, modifiedAt: now),
                MobileIdea(path: "Ideas/Middle.md", title: "Middle", revision: 1, modifiedAt: now.addingTimeInterval(-10)),
                MobileIdea(path: "Ideas/Extra.md", title: "Extra", revision: 1, modifiedAt: now.addingTimeInterval(-30)),
            ],
            fetchedAt: now
        )

        let result = WorkspaceWidgetSnapshot.make(from: snapshot)
        XCTAssertEqual(result.nextWorkItem?.title, "High now")
        XCTAssertEqual(result.nextWorkItem?.projectName, "Better Workspace")
        XCTAssertEqual(result.openWorkCount, 4)
        XCTAssertEqual(result.inProgressWorkCount, 1)
        XCTAssertEqual(result.recentIdeas.map(\.title), ["New", "Middle", "Old"])
    }
}

final class MeasurementTests: XCTestCase {

    /// Shaped exactly like a real `/v1/scoring/projects` reply, including the two
    /// forms `raw_value` takes and a dimension the backend could not measure.
    private let payload = """
    {"schema_version": 1, "data": {"contract_version": "1.1", "projects": [
      {"id": "watcher-1", "name": "Workspace Watcher", "dimensions": {
        "investment_observed": {"value": 13.1, "raw_value": 6.03, "unit": "hours",
          "state": "provisional", "source": "core.db:completed sessions",
          "explanation": "Observed hours, not lifetime labor.", "formula_version": "1.1"},
        "activity_7d": {"value": 10.3, "raw_value": {"observed_hours": 1.2, "bins": 7},
          "unit": "score", "state": "provisional", "formula_version": "1.1"},
        "activity_age": {"value": 0.9, "raw_value": 0.9, "unit": "days", "state": "provisional"},
        "importance": {"value": null, "raw_value": null, "unit": "score", "state": "unknown",
          "explanation": "Requires Personal Importance, Goal Alignment and Dependency Importance."}
      }},
      {"id": "watcher-2", "name": "Never Touched", "dimensions": {
        "investment_observed": {"value": null, "raw_value": null, "unit": "hours", "state": "unknown"}
      }}
    ]}}
    """.data(using: .utf8)!

    func testLowerBoundAgeIsFlaggedAndOddWindowsDoNotFailTheDecode() throws {
        let data = """
        {"schema_version": 1, "data": {"projects": [
          {"id": "a", "name": "Unobserved", "dimensions": {
            "activity_age": {"value": 26.2, "raw_value": 26.2, "unit": "days", "state": "provisional",
              "window": {"unobserved_since": "2026-09-18T00:00:00+00:00", "bound": "lower"}},
            "consistency_84d": {"value": 10, "raw_value": {"weeks": 12}, "state": "provisional", "window": "unexpected"}}},
          {"id": "b", "name": "Observed", "dimensions": {
            "activity_age": {"value": 2, "raw_value": 2, "unit": "days", "state": "known", "window": {"last_observed": "x"}}}}
        ]}}
        """.data(using: .utf8)!
        let decoded = try MeasurementService.decode(data)
        XCTAssertEqual(decoded["a"]?.measurement(.activityAge)?.isLowerBound, true)
        XCTAssertEqual(decoded["b"]?.measurement(.activityAge)?.isLowerBound, false)
        XCTAssertNotNil(decoded["a"]?.dimensions["consistency_84d"])
    }

    func testUnknownIsNeverReadAsZero() throws {
        let decoded = try MeasurementService.decode(payload)
        let untouched = try XCTUnwrap(decoded["watcher-2"])
        let effort = try XCTUnwrap(untouched.measurement(.investmentObserved))
        XCTAssertNil(effort.value, "A project nobody has worked on has no effort, not zero effort")
        XCTAssertEqual(effort.state, .unknown)
        XCTAssertFalse(effort.isKnown)

        let watcher = try XCTUnwrap(decoded["watcher-1"])
        let importance = try XCTUnwrap(watcher.dimensions["importance"])
        XCTAssertNil(importance.value)
        XCTAssertEqual(importance.state, .unknown)
        XCTAssertEqual(importance.explanation,
                       "Requires Personal Importance, Goal Alignment and Dependency Importance.")
    }

    func testProvisionalSurvivesTheTripFromTheBackend() throws {
        let decoded = try MeasurementService.decode(payload)
        let effort = try XCTUnwrap(decoded["watcher-1"]?.measurement(.investmentObserved))
        XCTAssertEqual(effort.state, .provisional)
        XCTAssertTrue(effort.isProvisional)
        XCTAssertEqual(effort.value, 13.1)
        XCTAssertEqual(effort.rawValue, 6.03)
        XCTAssertEqual(effort.unit, "hours")
        XCTAssertEqual(effort.formulaVersion, "1.1")
        XCTAssertEqual(effort.explanation, "Observed hours, not lifetime labor.")
    }

    /// Windowed dimensions send a breakdown object where the others send a number.
    /// That must not fail the decode or lose the neighbouring dimensions.
    func testAStructuredRawValueDoesNotBreakTheResponse() throws {
        let decoded = try MeasurementService.decode(payload)
        let activity = try XCTUnwrap(decoded["watcher-1"]?.measurement(.activity7d))
        XCTAssertEqual(activity.value, 10.3)
        XCTAssertNil(activity.rawValue, "A breakdown object is not a scalar and is dropped, not guessed")
        XCTAssertEqual(decoded["watcher-1"]?.dimensions.count, 4)
    }

    func testEveryMeasurementKnowsWhichDimensionItIs() throws {
        let decoded = try MeasurementService.decode(payload)
        for (key, measurement) in try XCTUnwrap(decoded["watcher-1"]).dimensions {
            XCTAssertEqual(measurement.dimension, key)
        }
    }

    func testAgeIsInDaysAndTheRestAreScores() {
        XCTAssertTrue(MeasurementDimension.activityAge.isDuration)
        for dimension in MeasurementDimension.allCases where dimension != .activityAge {
            XCTAssertFalse(dimension.isDuration, "\(dimension.rawValue) should be a 0-100 score")
        }
    }
}

final class NotionClientRetryTests: XCTestCase {

    /// Being rate-limited partway through five paginated databases is ordinary, and
    /// failing the whole import for it discards everything already fetched.
    func testARateLimitIsWaitedOutUsingNotionsOwnNumber() {
        XCTAssertEqual(NotionClient.retryDelay(forStatus: 429, retryAfter: 3, attempt: 1), .seconds(3))
    }

    func testAServerErrorBacksOffWhenNotionGivesNoNumber() {
        let first = NotionClient.retryDelay(forStatus: 503, retryAfter: nil, attempt: 1)
        let second = NotionClient.retryDelay(forStatus: 503, retryAfter: nil, attempt: 2)
        XCTAssertNotNil(first)
        XCTAssertNotNil(second)
        XCTAssertTrue(second! > first!, "Later attempts have to wait longer")
    }

    /// Honor the server's wait rather than retrying before a rate limit clears.
    func testTheServerWaitIsRespectedAndZeroCannotSpin() {
        XCTAssertEqual(NotionClient.retryDelay(forStatus: 429, retryAfter: 86_400, attempt: 1), .seconds(86_400))
        XCTAssertEqual(NotionClient.retryDelay(forStatus: 429, retryAfter: 0, attempt: 1), .seconds(0.5))
    }

    /// A rejected token and a database that was never shared will answer identically in
    /// ten seconds, so there is nothing to wait for.
    func testAnAnswerThatWillNotChangeIsNotRetried() {
        for code in [400, 401, 403, 404] {
            XCTAssertNil(NotionClient.retryDelay(forStatus: code, retryAfter: 5, attempt: 1),
                         "\(code) must not be retried")
        }
    }

    func testRetryingStopsRatherThanGoingOnForever() {
        XCTAssertNil(NotionClient.retryDelay(forStatus: 429, retryAfter: 1,
                                             attempt: NotionClient.maxAttempts))
    }
}

final class NotionImportTests: XCTestCase {

    private func page(_ id: String, title: String, _ extra: [String: NotionValue] = [:]) -> NotionPage {
        var properties: [String: NotionValue] = ["Name": .title(title)]
        properties.merge(extra) { _, new in new }
        return NotionPage(id: id, url: URL(string: "https://notion.so/\(id)"), properties: properties)
    }

    private func destinations(_ root: URL) -> NotionImport.Destinations {
        NotionImport.Destinations(
            tasks: root.appendingPathComponent("To Do"),
            milestones: root.appendingPathComponent("Milestones"),
            features: root.appendingPathComponent("Features"),
            ideas: root.appendingPathComponent("Ideas")
        )
    }

    private func tempRoot() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("bw-notion-\(UUID().uuidString)")
    }

    /// A thousand finished tasks is not a default anyone should be given.
    func testCompletedTasksAreLeftBehindUnlessAskedFor() {
        var source = NotionImport.Source()
        source.tasks = [
            page("aaa", title: "Still open"),
            page("bbb", title: "Long done", ["complete": .flag(true)]),
            page("ccc", title: "Marked done by status", ["status": .choice("Done")]),
        ]
        let root = tempRoot()

        var options = NotionImport.Options()
        let lean = NotionImport.plan(from: source, options: options, destinations: destinations(root),
                                     projectsByNotionID: [:], existingWorkItems: [], existingIdeaNames: [])
        XCTAssertEqual(lean.tasks.map(\.item.title), ["Still open"])

        options.includeCompletedTasks = true
        let full = NotionImport.plan(from: source, options: options, destinations: destinations(root),
                                     projectsByNotionID: [:], existingWorkItems: [], existingIdeaNames: [])
        XCTAssertEqual(full.tasks.count, 3)
        XCTAssertEqual(full.completedTaskCount, 2)
        XCTAssertEqual(full.openTaskCount, 1)
    }

    /// Running the import twice must not produce two of everything.
    func testReimportingRecognizesWhatIsAlreadyThere() {
        var source = NotionImport.Source()
        source.tasks = [page("aaa-bbb", title: "Already imported"), page("ccc", title: "New one")]
        let root = tempRoot()
        let existing = WorkItem(kind: .task, title: "Already imported",
                                url: root.appendingPathComponent("To Do/x.bw.md"))
        // The work item keeps the Notion id as its own, which is what makes this work.
        let stored = WorkItem(id: NotionImport.normalizedID("aaa-bbb"), kind: .task,
                              title: "Already imported", url: existing.url)

        let plan = NotionImport.plan(from: source, options: NotionImport.Options(),
                                     destinations: destinations(root), projectsByNotionID: [:],
                                     existingWorkItems: [stored], existingIdeaNames: [])
        XCTAssertEqual(plan.tasks.count, 2)
        XCTAssertEqual(plan.newWorkItemCount, 1)
        XCTAssertEqual(plan.tasks.first(where: { $0.item.title == "Already imported" })?.alreadyPresent, true)
        XCTAssertEqual(plan.tasks.first(where: { $0.item.title == "New one" })?.alreadyPresent, false)
    }

    /// A finished milestone imported as open would come back as current work, and the
    /// feature → milestone → task chain is the only structure the planning data has.
    func testMilestonesKeepTheirStatusAndTheirPlaceInTheHierarchy() {
        var source = NotionImport.Source()
        source.milestones = [
            page("m1", title: "Shipped", ["status": .choice("Complete"), "feature": .relations(["f-1"]),
                                              "project": .relations(["p-1"])]),
            page("m2", title: "Underway", ["Status": .choice("In Progress"), "Project": .relations(["p-1"])]),
        ]
        source.tasks = [page("t1", title: "Step", ["Milestone": .relations(["m-2"])]),
                        page("t2", title: "Sub-step", ["parent task": .relations(["t-1"]),
                                                       "milestone": .relations(["m-2"])])]

        let project = ProjectRecord(id: "local-project", identityKey: nil, lastPath: "/W/Projects/Example",
                                    name: "Example", notionPageID: "p-1", watcherID: nil, documentID: nil,
                                    createdAt: Date(), updatedAt: Date())
        let plan = NotionImport.plan(from: source, options: NotionImport.Options(),
                                     destinations: destinations(tempRoot()), projectsByNotionID: ["p1": project],
                                     existingWorkItems: [], existingIdeaNames: [])
        let shipped = plan.milestones.first { $0.item.title == "Shipped" }?.item
        XCTAssertEqual(shipped?.status, .completed)
        XCTAssertEqual(shipped?.parentID, "f1")
        XCTAssertEqual(plan.milestones.first { $0.item.title == "Underway" }?.item.status, .inProgress,
                       "Underway work stays underway rather than being reset to open")
        XCTAssertEqual(plan.tasks.first { $0.item.title == "Step" }?.item.parentID, "m2")
        XCTAssertEqual(plan.tasks.first { $0.item.title == "Sub-step" }?.item.parentID, "t1")
    }

    func testATaskFindsItsProjectThroughTheLocalNotionAssociation() {
        var source = NotionImport.Source()
        source.tasks = [page("t1", title: "Wire the thing", ["project": .relations(["proj-1"])]),
                        page("t2", title: "Orphan task")]
        let record = ProjectRecord(id: "local-1", identityKey: nil,
                                   lastPath: "/W/Projects/Better Workspace", name: "Better Workspace",
                                   notionPageID: "proj-1", watcherID: nil, documentID: nil,
                                   createdAt: Date(), updatedAt: Date())
        let plan = NotionImport.plan(from: source, options: NotionImport.Options(),
                                     destinations: destinations(tempRoot()),
                                     projectsByNotionID: ["proj1": record],
                                     existingWorkItems: [], existingIdeaNames: [])
        XCTAssertEqual(plan.tasks.first(where: { $0.item.title == "Wire the thing" })?.item.projectPath,
                       "/W/Projects/Better Workspace")
        XCTAssertNil(plan.tasks.first(where: { $0.item.title == "Orphan task" })?.item.projectPath)
        XCTAssertTrue(plan.warnings.contains { $0.contains("1 tasks have no project") })
    }

    func testWorkspaceImportWritesPortableProjectPaths() {
        var source = NotionImport.Source()
        source.tasks = [page("t1", title: "Portable link", ["project": .relations(["proj-1"])])]
        let root = tempRoot()
        let workspace = WorkspaceLocation(root: root)
        let record = ProjectRecord(id: "local-1", identityKey: nil,
                                   lastPath: root.appendingPathComponent("Projects/Example").path, name: "Example",
                                   notionPageID: "proj-1", watcherID: nil, documentID: nil,
                                   createdAt: Date(), updatedAt: Date())
        let plan = NotionImport.plan(from: source, options: NotionImport.Options(),
                                     destinations: .init(workspace: workspace), projectsByNotionID: ["proj1": record],
                                     existingWorkItems: [], existingIdeaNames: [])
        XCTAssertEqual(plan.tasks.first?.item.projectPath, "Projects/Example")
    }

    /// The thirty Notion ideas already have folders. The import must enrich, not double.
    func testIdeasAlreadyOnDiskAreNotDuplicated() {
        var source = NotionImport.Source()
        source.ideas = [page("i1", title: "Offline-First Notion Cache Layer"),
                        page("i2", title: "A brand new idea")]
        source.projects = [page("p1", title: "Narrative Science Book", ["Status": .choice("Idea")]),
                           page("p2", title: "An actual project", ["Status": .choice("Active")])]

        let plan = NotionImport.plan(from: source, options: NotionImport.Options(),
                                     destinations: destinations(tempRoot()), projectsByNotionID: [:],
                                     existingWorkItems: [],
                                     existingIdeaNames: ["Offline-First Notion Cache Layer"])
        XCTAssertEqual(plan.ideas.count, 3, "Only the project whose status is Idea should come across")
        XCTAssertEqual(plan.newIdeaCount, 2)
        XCTAssertEqual(plan.ideas.first { $0.title == "Offline-First Notion Cache Layer" }?.alreadyPresent, true)
        XCTAssertEqual(plan.ideas.first { $0.title == "Narrative Science Book" }?.fromProjectsDatabase, true)
        XCTAssertNil(plan.ideas.first { $0.title == "An actual project" })
    }

    func testApplyWritesFilesAndLeavesExistingOnesAlone() throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        var source = NotionImport.Source()
        source.tasks = [page("t1", title: "Write the importer")]
        source.features = [page("f1", title: "Notion import", ["Project": .relations(["proj-1"]),
                                                               "Success Criteria": .text("It runs twice safely")])]
        source.ideas = [page("i1", title: "An idea worth keeping")]

        let project = ProjectRecord(id: "local-project", identityKey: nil, lastPath: "/W/Projects/Example",
                                    name: "Example", notionPageID: "proj-1", watcherID: nil, documentID: nil,
                                    createdAt: Date(), updatedAt: Date())
        let plan = NotionImport.plan(from: source, options: NotionImport.Options(),
                                     destinations: destinations(root), projectsByNotionID: ["proj1": project],
                                     existingWorkItems: [], existingIdeaNames: [])
        let result = NotionImport.apply(plan)
        XCTAssertEqual(result.workItemsCreated, 2)
        XCTAssertEqual(result.ideasCreated, 1)
        XCTAssertTrue(result.failures.isEmpty)

        let service = WorkItemService()
        let written = service.items(under: root)
        XCTAssertEqual(Set(written.map(\.title)), ["Write the importer", "Notion import"])
        XCTAssertTrue(try XCTUnwrap(written.first { $0.kind == .feature }).body.contains("It runs twice safely"))

        let ideaNote = root.appendingPathComponent("Ideas/An idea worth keeping/An idea worth keeping.md")
        XCTAssertTrue(FileManager.default.fileExists(atPath: ideaNote.path))

        // Second run: the ids are already on disk, so nothing is written again.
        let secondPlan = NotionImport.plan(from: source, options: NotionImport.Options(),
                                           destinations: destinations(root), projectsByNotionID: ["proj1": project],
                                           existingWorkItems: written,
                                           existingIdeaNames: ["An idea worth keeping"])
        let second = NotionImport.apply(secondPlan)
        XCTAssertEqual(second.workItemsCreated, 0)
        XCTAssertEqual(second.ideasCreated, 0)
        XCTAssertEqual(second.skippedExisting, 3)
        XCTAssertEqual(service.items(under: root).count, 2, "Re-importing must not duplicate")
    }

    func testNotionValueFlattensTheShapesTheImportActuallyReads() throws {
        let json: [String: Any] = [
            "title": ["type": "title", "title": [["plain_text": "A task"]]],
            "note": ["type": "rich_text", "rich_text": [["plain_text": "Some "], ["plain_text": "text"]]],
            "state": ["type": "status", "status": ["name": "In progress"]],
            "labels": ["type": "multi_select", "multi_select": [["name": "a"], ["name": "b"]]],
            "score": ["type": "number", "number": 4.0],
            "done": ["type": "checkbox", "checkbox": true],
            "when": ["type": "date", "date": ["start": "2026-09-29"]],
            "links": ["type": "relation", "relation": [["id": "abc"]]],
            "empty": ["type": "select", "select": NSNull()],
        ]
        let page = try XCTUnwrap(NotionPage(json: ["id": "p1", "properties": json]))
        XCTAssertEqual(page.title, "A task")
        XCTAssertEqual(page.text("note"), "Some text")
        XCTAssertEqual(page.choice("state"), "In progress")
        XCTAssertEqual(page.choices("labels"), ["a", "b"])
        XCTAssertEqual(page.number("score"), 4)
        XCTAssertTrue(page.flag("done"))
        XCTAssertEqual(page.date("when"), "2026-09-29")
        XCTAssertEqual(page.relations("links"), ["abc"])
        XCTAssertNil(page.choice("empty"), "An unset select is absent, not an empty string")
    }
}

final class AttentionTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func daysAgo(_ days: Double) -> Date { now.addingTimeInterval(-days * 86_400) }

    private func project(_ name: String, touched: Double? = nil, score: Double? = nil,
                         rated: Int = 0, session: Double? = nil, hours: Double? = nil) -> Attention.Input.Project {
        Attention.Input.Project(
            name: name, path: "/W/Projects/\(name)",
            contentModifiedAt: touched.map(daysAgo), score: score, ratedCount: rated,
            lastSessionAt: session.map(daysAgo), observedHours: hours
        )
    }

    private func input(_ projects: [Attention.Input.Project] = [], ideas: [Attention.Input.Idea] = [],
                       inbox: Int = 0, emptyFolders: [String] = []) -> Attention.Input {
        var input = Attention.Input()
        input.now = now
        input.projects = projects
        input.ideas = ideas
        input.pendingIngestCount = inbox
        input.emptyTopLevelFolders = emptyFolders
        return input
    }

    /// The whole point: a surfaced thing explains itself.
    func testEverySurfacedItemCarriesItsReasons() {
        let items = Attention.evaluate(input(
            [project("Dropped", touched: 12, session: 12, hours: 3.5)],
            inbox: 2
        ))
        XCTAssertFalse(items.isEmpty)
        for item in items {
            XCTAssertFalse(item.reasons.isEmpty, "\(item.title) was surfaced with no reason")
            XCTAssertFalse(item.explanation.isEmpty)
        }
        let dropped = try? XCTUnwrap(items.first { $0.title == "Dropped" })
        XCTAssertTrue(dropped?.explanation.contains("then dropped") == true)
        XCTAssertTrue(dropped?.explanation.contains("observed work") == true,
                      "Effort should enrich the reason, not replace it")
    }

    /// Several rules pointing at one project should read as one richer line.
    func testReasonsFromDifferentRulesMergeOntoOneItem() {
        let items = Attention.evaluate(input([
            project("Both", touched: 40, score: 80, rated: 21, session: 10)
        ]))
        XCTAssertEqual(items.count, 1)
        let item = items[0]
        XCTAssertEqual(item.reasons.count, 2, "Dropped and rated-but-cold should combine")
        XCTAssertTrue(item.explanation.contains("then dropped"))
        XCTAssertTrue(item.explanation.contains("you rated this 80"))
    }

    func testNothingToSayProducesNothingRatherThanFiller() {
        XCTAssertTrue(Attention.evaluate(input([project("Quiet", touched: 200)])).isEmpty)
    }

    /// Overview is a decision aid, not a second backlog.
    func testTheListStaysShortEvenWithAPortfolioFullOfCandidates() {
        let many = (1...40).map { project("P\($0)", touched: 12, session: 12) }
        XCTAssertEqual(Attention.evaluate(input(many)).count, 4)
        XCTAssertEqual(Attention.evaluate(input(many), limit: 2).count, 2)
    }

    func testAProjectActiveThisWeekIsNotReportedAsDropped() {
        let items = Attention.evaluate(input([project("Current", touched: 1, session: 1, hours: 4)]))
        XCTAssertFalse(items.contains { $0.explanation.contains("then dropped") })
    }

    /// A file timestamp is not the same evidence as a Watcher session. The screen may
    /// surface both, but must not call the former "active" or "worked on".
    func testRecentlyChangedProjectIsNotCalledActiveWithoutAnObservedSession() {
        let changedOnly = Attention.evaluate(input([project("Synced", touched: 1)]))
        XCTAssertEqual(changedOnly.first?.reasons.first, .recentlyChangedButUnrated)
        XCTAssertFalse(changedOnly.first?.explanation.contains("active but") == true)
        XCTAssertFalse(changedOnly.first?.explanation.contains("worked on") == true)

        let observed = Attention.evaluate(input([project("Worked", touched: 1, session: 1)]))
        XCTAssertEqual(observed.first?.reasons.first, .activeButUnrated)
        XCTAssertTrue(observed.first?.explanation.contains("worked on") == true)
    }

    func testAHandfulOfBareIdeasIsWorthMentioningButOneIsNot() {
        let one = [Attention.Input.Idea(name: "A", hasContent: false)]
        XCTAssertTrue(Attention.evaluate(input(ideas: one)).isEmpty)

        let several = (1...29).map { Attention.Input.Idea(name: "Idea \($0)", hasContent: false) }
        let items = Attention.evaluate(input(ideas: several))
        XCTAssertEqual(items.first?.target, .ideas)
        XCTAssertTrue(try XCTUnwrap(items.first).explanation.contains("29 ideas"))
    }

    func testRulesCanBeReplacedWithoutTouchingTheEngine() {
        let onlyInbox = Attention.defaultRules.filter { $0.id == "inbox" }
        let items = Attention.evaluate(input([project("Dropped", touched: 12, session: 12)], inbox: 1),
                                       rules: onlyInbox)
        XCTAssertEqual(items.map(\.target), [.ingest])
    }

    // MARK: - Resume

    private func session(_ project: String, endedDaysAgo: Double, seconds: Double,
                         files: [String] = [], subject: String? = nil,
                         projectID: String = "p") -> WorkSession {
        WorkSession(id: UUID().uuidString, projectID: projectID, projectName: project,
                    startedAt: daysAgo(endedDaysAgo + 0.1), endedAt: daysAgo(endedDaysAgo),
                    activeSeconds: seconds, files: files, gitBranch: "main", gitSubject: subject)
    }

    /// A one-minute blip is not where you left off.
    func testResumeIgnoresSessionsTooShortToBeRealWork() {
        let sessions = [session("Blip", endedDaysAgo: 0.1, seconds: 45),
                        session("Real", endedDaysAgo: 2, seconds: 3_600, subject: "Wire the importer")]
        let point = Attention.resumePoint(sessions: sessions,
                                          input: input([project("Real", touched: 2)]), now: now)
        XCTAssertEqual(point?.projectName, "Real")
        XCTAssertEqual(point?.evidence, .session)
        XCTAssertEqual(point?.gitSubject, "Wire the importer")
        XCTAssertEqual(point?.projectPath, "/W/Projects/Real")
    }

    /// Without the daemon there are no sessions, and a timestamp is still better than
    /// nothing — but the claim being made is weaker and must be labelled as such.
    func testResumeFallsBackToFileChangesWhenThereAreNoSessions() {
        let point = Attention.resumePoint(
            sessions: [], input: input([project("Old", touched: 9), project("Newest", touched: 1)]), now: now
        )
        XCTAssertEqual(point?.projectName, "Newest")
        XCTAssertEqual(point?.evidence, .filesystem)
        XCTAssertNil(point?.activeHours, "There is no observed duration to claim")
    }

    func testResumeNamesTheFilesYouWereInNotOtherToolsBookkeeping() {
        let sessions = [session("Real", endedDaysAgo: 0.2, seconds: 900,
                                files: ["Projects/Real/App.swift",
                                        "Projects/Real/Project.betterproject",
                                        "Projects/Real/.DS_Store"])]
        let point = Attention.resumePoint(sessions: sessions, input: input([project("Real")]), now: now)
        XCTAssertEqual(point?.files, ["App.swift"])
    }

    func testResumeUsesWatcherIdentityWhenProjectNamesAreAmbiguous() {
        let olderMatch = Attention.Input.Project(
            name: "Duplicate", path: "/W/Projects/Old", contentModifiedAt: daysAgo(3),
            score: nil, ratedCount: 0, lastSessionAt: nil, observedHours: nil, watcherID: "old-id"
        )
        let actualMatch = Attention.Input.Project(
            name: "Duplicate", path: "/W/Projects/Current", contentModifiedAt: daysAgo(1),
            score: nil, ratedCount: 0, lastSessionAt: nil, observedHours: nil, watcherID: "current-id"
        )
        let point = Attention.resumePoint(
            sessions: [session("Duplicate", endedDaysAgo: 0.2, seconds: 600, projectID: "current-id")],
            input: input([olderMatch, actualMatch]), now: now
        )
        XCTAssertEqual(point?.projectPath, "/W/Projects/Current")
    }

    func testNoEvidenceAtAllMeansNoResumePoint() {
        XCTAssertNil(Attention.resumePoint(sessions: [], input: input(), now: now))
    }
}

final class DestinationOrderTests: XCTestCase {

    func testPrimaryDestinationsLeadInTheOrderTheyWereChosen() {
        let sorted = DestinationOrder.sorted(
            ["Analytics", "To Do", "Ideas", "Logs", "Projects", "For Reference"]) { $0 }
        XCTAssertEqual(Array(sorted.prefix(3)), ["Projects", "Ideas", "To Do"])
    }

    func testSystemFoldersSinkAndOrdinaryOnesSitBetween() {
        let sorted = DestinationOrder.sorted(["Logs", "Features", "Backups", "To Read", "Projects"]) { $0 }
        XCTAssertEqual(sorted.first, "Projects")
        XCTAssertEqual(Array(sorted.suffix(2)), ["Backups", "Logs"])
        XCTAssertEqual(Array(sorted.dropFirst().prefix(2)), ["Features", "To Read"])
    }

    /// A folder made in Finder must land somewhere visible, never silently last.
    func testAnUnknownFolderIsOrdinaryNotBuried() {
        XCTAssertEqual(DestinationOrder.tier(for: "Client Work"), .ordinary)
        let sorted = DestinationOrder.sorted(["Logs", "Client Work", "Projects"]) { $0 }
        XCTAssertEqual(sorted, ["Projects", "Client Work", "Logs"])
    }

    func testToDoIsPrimaryButItsSiblingsAreNot() {
        XCTAssertEqual(DestinationOrder.tier(for: "To Do"), .primary)
        XCTAssertEqual(DestinationOrder.tier(for: "To Watch"), .ordinary)
    }
}

final class MobileCaptureServiceTests: XCTestCase {

    private var inbox: URL!

    override func setUpWithError() throws {
        inbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("MobileCaptureServiceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: inbox)
    }

    func testCapturedTextBecomesAMarkdownFileAndIsCounted() throws {
        let service = MobileCaptureService(inbox: inbox)
        let url = try service.captureText("# Build a control surface\n\nNotes follow.")
        XCTAssertEqual(url.pathExtension, "md")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

        let overview = service.recentCaptureOverview()
        XCTAssertEqual(overview?.totalCount, 1)
        XCTAssertEqual(overview?.urls.map(\.lastPathComponent), [url.lastPathComponent])
    }

    func testBundleKeepsNoteAndAttachmentsInOneInboxFolder() throws {
        let service = MobileCaptureService(inbox: inbox)
        let staged = inbox.deletingLastPathComponent().appendingPathComponent("camera-\(UUID().uuidString).jpg")
        try Data([0, 1, 2]).write(to: staged)
        defer { try? FileManager.default.removeItem(at: staged) }

        let bundle = try service.captureBundle(note: "Study this image", attachmentURLs: [staged])
        XCTAssertTrue((try bundle.resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true)
        XCTAssertEqual(try String(contentsOf: bundle.appendingPathComponent("Note.md")), "# Study this image\n\n")
        XCTAssertEqual(try Data(contentsOf: bundle.appendingPathComponent(staged.lastPathComponent)), Data([0, 1, 2]))
        XCTAssertEqual(MobileCaptureBundleReceipt.children(at: bundle), ["Note.md", staged.lastPathComponent])
        XCTAssertTrue(MobileCaptureBundleReceipt.hasAllChildren(["Note.md", staged.lastPathComponent], at: bundle))
        XCTAssertEqual(service.recentCaptureOverview()?.urls.map(\.canonicalPath), [bundle.canonicalPath])
        XCTAssertEqual(SourceMarker.read(from: bundle), .mobile)
    }

    func testDeletingMobileCaptureIsLimitedToItsInbox() throws {
        let service = MobileCaptureService(inbox: inbox)
        let capture = try service.captureText("Discard me")
        let outside = inbox.deletingLastPathComponent().appendingPathComponent("Keep.md")
        try "keep".write(to: outside, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: outside) }

        try service.deleteCapture(at: capture)

        XCTAssertFalse(FileManager.default.fileExists(atPath: capture.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path))
        XCTAssertThrowsError(try service.deleteCapture(at: outside))
    }

    /// Other tools' metadata is not the user's capture, so it must not reach the list or
    /// the count the widget shows.
    func testForeignMetadataIsExcludedFromBothTheListAndTheCount() throws {
        let service = MobileCaptureService(inbox: inbox)
        try service.captureText("A real capture")
        try Data("x".utf8).write(to: inbox.appendingPathComponent("watcher.item.toml"))
        try Data("x".utf8).write(to: inbox.appendingPathComponent("Project.betterproject"))

        let overview = service.recentCaptureOverview()
        XCTAssertEqual(overview?.totalCount, 1, "Foreign metadata must not inflate the inbox count")
        XCTAssertEqual(overview?.urls.count, 1)
        XCTAssertEqual(overview?.urls.contains { $0.lastPathComponent == "watcher.item.toml" }, false)
    }

    /// The widget reports the whole inbox while the app lists a capped page of it, so the
    /// count must not be the page size.
    func testTotalCountCoversTheWholeInboxWhileTheListIsCapped() throws {
        let service = MobileCaptureService(inbox: inbox)
        for index in 0..<7 {
            try Data("x".utf8).write(to: inbox.appendingPathComponent("capture-\(index).md"))
        }
        let overview = service.recentCaptureOverview(limit: 3)
        XCTAssertEqual(overview?.urls.count, 3)
        XCTAssertEqual(overview?.totalCount, 7)
    }

    func testRecentCapturesAreNewestFirst() throws {
        let service = MobileCaptureService(inbox: inbox)
        let old = inbox.appendingPathComponent("older.md")
        let new = inbox.appendingPathComponent("newer.md")
        try Data("x".utf8).write(to: old)
        try Data("x".utf8).write(to: new)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_000)], ofItemAtPath: old.path)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 2_000)], ofItemAtPath: new.path)

        XCTAssertEqual(service.recentCaptureOverview()?.urls.map(\.lastPathComponent),
                       ["newer.md", "older.md"])
    }

    func testCaptureWithNoInboxFailsRatherThanWritingSomewhereElse() {
        let service = MobileCaptureService(inbox: nil)
        XCTAssertThrowsError(try service.captureText("nowhere to go"))
        XCTAssertNil(service.recentCaptureOverview(),
                     "No inbox is unknown, not empty; a zero here becomes a wrong widget count")
    }

    /// An inbox that cannot be listed must not read as an inbox holding nothing.
    func testAnUnreadableInboxIsReportedAsUnknownRatherThanEmpty() throws {
        let service = MobileCaptureService(inbox: inbox)
        try service.captureText("A real capture")
        XCTAssertEqual(service.recentCaptureOverview()?.totalCount, 1)

        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: inbox.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: inbox.path) }
        XCTAssertNil(service.recentCaptureOverview())
    }

    func testAnInboxThatDoesNotExistYetIsUnknownRatherThanEmpty() {
        let missing = inbox.appendingPathComponent("not-created-yet", isDirectory: true)
        XCTAssertNil(MobileCaptureService(inbox: missing).recentCaptureOverview())
    }
}

final class MobileSnapshotCacheTests: XCTestCase {

    private var fileURL: URL!

    override func setUp() {
        fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("MobileSnapshotCacheTests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("snapshot.json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent())
    }

    private func snapshot(entryCount: Int, fetchedAt: Date = Date(timeIntervalSince1970: 1_000)) -> MobileWorkspaceSnapshot {
        MobileWorkspaceSnapshot(
            tags: [Tag(id: "t1", name: "AI")],
            entries: (0..<entryCount).map {
                MobileWorkspaceEntry(path: "Ideas/Entry \($0)", parentPath: "Ideas",
                                     name: "Entry \($0)", isDirectory: false, revision: 3,
                                     tagIDs: ["t1"], modifiedAt: fetchedAt)
            },
            workItems: [MobileWorkItem(id: "w1", path: "To Do/One.bw.md", title: "One", kind: .task,
                                       status: .open, stage: .now, priority: .high, revision: 2)],
            ideas: [MobileIdea(path: "Ideas/Spark", title: "Spark", revision: 1)],
            fetchedAt: fetchedAt
        )
    }

    func testNothingIsCachedUntilSomethingIsSaved() {
        XCTAssertNil(MobileSnapshotCache(fileURL: fileURL).load())
    }

    /// The whole point: a phone with no CloudKit still opens on what it last received.
    func testASavedSnapshotComesBackWithItsTagsEntriesAndWork() {
        let cache = MobileSnapshotCache(fileURL: fileURL)
        XCTAssertTrue(cache.save(snapshot(entryCount: 2)))

        let restored = MobileSnapshotCache(fileURL: fileURL).load()
        XCTAssertEqual(restored?.entries.map(\.path), ["Ideas/Entry 0", "Ideas/Entry 1"])
        XCTAssertEqual(restored?.entries.first?.tagIDs, ["t1"])
        XCTAssertEqual(restored?.tags.map(\.name), ["AI"])
        XCTAssertEqual(restored?.workItems.map(\.title), ["One"])
        XCTAssertEqual(restored?.ideas.map(\.title), ["Spark"])
        XCTAssertEqual(restored?.fetchedAt, Date(timeIntervalSince1970: 1_000))
    }

    func testOptimisticTagStateStaysConsistentAcrossPhoneViews() {
        var value = MobileWorkspaceSnapshot(
            entries: [MobileWorkspaceEntry(path: "Ideas/Spark", parentPath: "Ideas", name: "Spark",
                                             isDirectory: false, revision: 1)],
            workItems: [MobileWorkItem(id: "work", path: "Ideas/Spark", title: "Spark", kind: .task,
                                       status: .open, stage: .next, priority: .medium, revision: 1)],
            ideas: [MobileIdea(path: "Ideas/Spark", title: "Spark", revision: 1)]
        )

        value.setTag("focus", onPath: "Ideas/Spark", isPresent: true)
        XCTAssertEqual(value.entries.first?.tagIDs, ["focus"])
        XCTAssertEqual(value.workItems.first?.tagIDs, ["focus"])
        XCTAssertEqual(value.ideas.first?.tagIDs, ["focus"])

        value.setTag("focus", onPath: "Ideas/Spark", isPresent: false)
        XCTAssertTrue(value.entries.first?.tagIDs.isEmpty == true)
        XCTAssertTrue(value.workItems.first?.tagIDs.isEmpty == true)
        XCTAssertTrue(value.ideas.first?.tagIDs.isEmpty == true)
    }

    /// A publisher mid-run, or a query that matched nothing because of a schema mistake,
    /// both look like "the workspace is empty". Neither is worth a real index for.
    func testAnEmptySnapshotDoesNotReplaceARealOne() {
        let cache = MobileSnapshotCache(fileURL: fileURL)
        XCTAssertTrue(cache.save(snapshot(entryCount: 3)))
        XCTAssertFalse(cache.save(MobileWorkspaceSnapshot(fetchedAt: Date(timeIntervalSince1970: 9_000))))
        XCTAssertEqual(cache.load()?.entries.count, 3)
    }

    func testAnEmptySnapshotIsCachedWhenThereIsNothingToLose() {
        let cache = MobileSnapshotCache(fileURL: fileURL)
        XCTAssertTrue(cache.save(MobileWorkspaceSnapshot(fetchedAt: Date(timeIntervalSince1970: 5))))
        XCTAssertEqual(cache.load()?.entries.count, 0)
    }

    /// A half-written file and a missing one mean the same thing to a caller, so neither
    /// needs a repair path.
    func testACorruptCacheReadsAsNothingRatherThanThrowing() throws {
        let cache = MobileSnapshotCache(fileURL: fileURL)
        XCTAssertTrue(cache.save(snapshot(entryCount: 1)))
        try Data("{ not json".utf8).write(to: fileURL)
        XCTAssertNil(cache.load())
        // And it recovers on the next successful refresh.
        XCTAssertTrue(cache.save(snapshot(entryCount: 1)))
        XCTAssertEqual(cache.load()?.entries.count, 1)
    }

    func testClearRemovesTheCache() {
        let cache = MobileSnapshotCache(fileURL: fileURL)
        XCTAssertTrue(cache.save(snapshot(entryCount: 1)))
        cache.clear()
        XCTAssertNil(cache.load())
    }

    func testStalenessIsMeasuredFromWhenCloudKitAnswered() {
        let fetched = Date(timeIntervalSince1970: 1_000_000)
        let cached = snapshot(entryCount: 1, fetchedAt: fetched)
        XCTAssertFalse(MobileSnapshotCache.isStale(cached, now: fetched.addingTimeInterval(60)))
        XCTAssertTrue(MobileSnapshotCache.isStale(
            cached, now: fetched.addingTimeInterval(MobileSnapshotCache.staleAfter + 1)))
    }
}

final class MobileIntentOutboxTests: XCTestCase {

    private var defaults: UserDefaults!
    private var suite: String!

    override func setUp() {
        suite = "MobileIntentOutboxTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
    }

    private func makeOutbox() -> MobileIntentOutbox {
        MobileIntentOutbox(defaults: defaults, key: "outbox")
    }

    private func tagChange(_ path: String) -> MobileWorkspaceIntent {
        .tagChange(path: path, baseRevision: 1, adding: ["t1"], removing: [])
    }

    func testAQueuedIntentSurvivesANewOutboxOverTheSameDefaults() {
        makeOutbox().append(tagChange("Ideas/One"))
        XCTAssertEqual(makeOutbox().queued().map(\.targetPath), ["Ideas/One"])
    }

    func testTheSameIntentIsNeverQueuedTwice() {
        let outbox = makeOutbox()
        let intent = tagChange("Ideas/One")
        outbox.append(intent)
        outbox.append(intent)
        XCTAssertEqual(outbox.count, 1)
    }

    func testTheQueueIsBoundedAndSaysWhenItHadToDropSomething() {
        let outbox = makeOutbox()
        for index in 0..<MobileIntentOutbox.capacity {
            XCTAssertFalse(outbox.append(tagChange("Ideas/\(index)")))
        }
        XCTAssertEqual(outbox.count, MobileIntentOutbox.capacity)
        XCTAssertTrue(outbox.append(tagChange("Ideas/overflow")),
                      "A full queue has to report that it dropped something")
        XCTAssertEqual(outbox.count, MobileIntentOutbox.capacity)
        XCTAssertEqual(outbox.queued().first?.targetPath, "Ideas/1", "The oldest is the one dropped")
        XCTAssertEqual(outbox.queued().last?.targetPath, "Ideas/overflow")
    }

    func testAFlushThatSucceedsEmptiesTheQueue() async {
        let outbox = makeOutbox()
        outbox.append(tagChange("Ideas/One"))
        outbox.append(tagChange("Ideas/Two"))

        let result = await outbox.flush { _ in }
        XCTAssertEqual(result.delivered, 2)
        XCTAssertEqual(result.discarded, 0)
        XCTAssertEqual(result.remaining, 0)
        XCTAssertTrue(result.isComplete)
        XCTAssertTrue(outbox.queued().isEmpty)
    }

    /// Order is the only thing keeping two changes to one path sensible, so a retryable
    /// failure stops the flush and leaves everything after it queued.
    func testARetryableFailureStopsTheFlushAndKeepsEverythingQueued() async {
        let outbox = makeOutbox()
        outbox.append(tagChange("Ideas/One"))
        outbox.append(tagChange("Ideas/Two"))

        let result = await outbox.flush { _ in throw MobileCloudError.unavailable("offline") }
        XCTAssertEqual(result.delivered, 0)
        XCTAssertEqual(result.remaining, 2)
        XCTAssertEqual(result.blockedBy, .unavailable("offline"))
        XCTAssertEqual(outbox.queued().count, 2)
    }

    /// A refusal CloudKit will repeat has to be dropped, or the queue can never drain
    /// past it and the "queued" badge never clears.
    func testARefusedIntentIsDiscardedSoTheQueueCanDrain() async {
        let outbox = makeOutbox()
        let doomed = tagChange("Ideas/Refused")
        outbox.append(doomed)
        outbox.append(tagChange("Ideas/Fine"))

        let result = await outbox.flush { intent in
            if intent.id == doomed.id { throw MobileCloudError.rejected("invalid arguments") }
        }
        XCTAssertEqual(result.discarded, 1)
        XCTAssertEqual(result.delivered, 1)
        XCTAssertEqual(result.remaining, 0)
        XCTAssertTrue(result.isComplete)
    }

    /// A tag tapped while the flush was in flight must not be removed unsent.
    func testAnIntentQueuedDuringAFlushIsNotDropped() async {
        let outbox = makeOutbox()
        outbox.append(tagChange("Ideas/One"))

        let result = await outbox.flush { [outbox] _ in
            outbox.append(self.tagChange("Ideas/ArrivedLate"))
        }
        XCTAssertEqual(result.delivered, 1)
        XCTAssertEqual(outbox.queued().map(\.targetPath), ["Ideas/ArrivedLate"])
    }

    func testOnlyRetryableFailuresAreWorthQueueing() {
        XCTAssertTrue(MobileCloudError.turnedOff.isRetryable)
        XCTAssertTrue(MobileCloudError.noAccount.isRetryable)
        XCTAssertTrue(MobileCloudError.unavailable("network").isRetryable)
        XCTAssertTrue(MobileCloudError.configuration("missing recordName index").isRetryable)
        XCTAssertFalse(MobileCloudError.rejected("bad container").isRetryable)
        XCTAssertFalse(MobileCloudError.malformedRecord("BWTag").isRetryable)
    }

    func testAConfigurationFailureStaysQueuedWithItsReason() async {
        let outbox = makeOutbox()
        outbox.append(tagChange("Ideas/NeedsDashboardSetup"))

        let result = await outbox.flush { _ in
            throw MobileCloudError.configuration("Field recordName is not marked queryable")
        }

        XCTAssertEqual(result.delivered, 0)
        XCTAssertEqual(result.discarded, 0)
        XCTAssertEqual(result.remaining, 1)
        XCTAssertEqual(result.blockedBy, .configuration("Field recordName is not marked queryable"))
        XCTAssertEqual(outbox.count, 1)
    }

    /// Nothing CloudKit-shaped may be built while a model initialises, so the store has
    /// to be able to answer this without one.
    func testTheStoreKnowsItIsTurnedOffWithoutTouchingCloudKit() async {
        defaults.set(true, forKey: MobileCloudStore.disabledDefaultsKey)
        let store = MobileCloudStore(defaults: defaults)
        let enabled = await store.isEnabled
        XCTAssertFalse(enabled)
        do {
            _ = try await store.fetchSnapshot()
            XCTFail("A disabled store must refuse rather than reach CloudKit")
        } catch {
            XCTAssertEqual(error as? MobileCloudError, .turnedOff)
        }
    }
}

final class MobileCloudProjectionTests: XCTestCase {
    func testDestinationChangeRepublishesLegacyStateAndRetriesOnlyUnacknowledgedRecords() throws {
        let database = try Database(inMemory: true)
        let candidates = ["one", "two"].map { MobileCloudPublicationCandidate.tag(Tag(id: $0, name: $0)) }
        let legacy = MobileCloudProjectionState(database: database)
        for record in try legacy.prepare(candidates).records { try legacy.markPublished(record) }
        try legacy.markInitialReconciled()
        let intent = MobileWorkspaceIntent.tagChange(path: "Ideas/One", baseRevision: 1, adding: ["one"], removing: [])
        try legacy.markHandled(intent)
        let production = MobileCloudProjectionState(database: database, destination: "container:Production")
        XCTAssertTrue(try production.needsInitialReconciliation())
        let migration = try production.prepare(candidates)
        XCTAssertTrue(migration.records.allSatisfy(\.changed))
        XCTAssertEqual(migration.records.map(\.revision), [2, 2])
        try production.markPublished(migration.records[0]) // Interrupted after one success.
        let retry = MobileCloudProjectionState(database: database, destination: "container:Production")
        XCTAssertEqual(try retry.prepare(candidates).records.map(\.changed), [false, true])
        XCTAssertTrue(try retry.isHandled(intent.id), "Environment repair must not replay applied phone commands")
        try retry.markInitialReconciled()
        XCTAssertFalse(try retry.needsInitialReconciliation())
        let development = MobileCloudProjectionState(database: database, destination: "container:Development")
        XCTAssertTrue(try development.needsInitialReconciliation())
        XCTAssertTrue(try development.prepare(candidates).records.allSatisfy(\.changed))
        XCTAssertTrue(try MobileCloudProjectionState(database: database, destination: "another:Production").needsInitialReconciliation())
    }


    func testEveryCloudKitQueryChannelIsListedForSchemaIndexing() {
        XCTAssertEqual(
            Set(MobileCloudSchema.queryableRecordTypes),
            Set([
                MobileCloudSchema.tagRecordType,
                MobileCloudSchema.indexRecordType,
                MobileCloudSchema.workItemRecordType,
                MobileCloudSchema.ideaRecordType,
                MobileCloudSchema.tagAssignmentChangeRecordType,
                MobileCloudSchema.captureIntentRecordType,
            ])
        )
        XCTAssertEqual(MobileCloudSchema.queryableRecordTypes.count, 6,
                       "A duplicate here would conceal an unindexed record type.")
    }

    func testUnknownRecordTypeIsOnlyTreatedAsAnEmptyBootstrapQuery() {
        XCTAssertTrue(MobileCloudSchema.isMissingRecordType(CKError(.unknownItem)))
        XCTAssertFalse(MobileCloudSchema.isMissingRecordType(CKError(.networkUnavailable)))
    }

    private func item(_ url: URL, directory: Bool = false) -> WorkspaceItem {
        WorkspaceItem(url: url, name: url.lastPathComponent, isDirectory: directory,
                      kind: directory ? .folder : .markdown, identity: nil, byteSize: 0,
                      createdAt: nil, rawModifiedAt: nil, contentModifiedAt: Date(timeIntervalSince1970: 123),
                      immediateChildCount: directory ? 0 : nil)
    }

    func testProjectionOnlyIncludesImmediateFilesystemEntriesAndFiltersForeignMetadata() {
        let root = URL(fileURLWithPath: "/tmp/MobileCloudProjectionTests-\(UUID().uuidString)")
        let workspace = WorkspaceLocation(root: root)
        let idea = item(root.appendingPathComponent("Ideas/Read later.md"))
        let foreign = item(root.appendingPathComponent("Ideas/watcher.item.toml"))
        let work = WorkItem(id: "portable-id", kind: .task, title: "Ship", status: .open,
                            stage: .next, priority: .medium, projectPath: "Projects/Better Workspace",
                            url: root.appendingPathComponent("To Do/ship.bw.md"))
        let tag = Tag(id: "reading", name: "Reading")
        let candidates = MobileWorkspaceProjection.candidates(from: .init(
            itemsByArea: ["Ideas": [idea, foreign], "Client Work": []], workItems: [work], tags: [tag],
            tagsByPath: [idea.url.canonicalPath: [tag], work.url.canonicalPath: [tag]]
        ), workspace: workspace)

        let entries = candidates.compactMap { candidate -> MobileWorkspaceEntry? in
            if case .entry(let entry) = candidate { return entry }; return nil
        }
        XCTAssertTrue(entries.contains(where: { $0.path == "Ideas" && $0.parentPath == nil }))
        // A folder with no purpose-built view, and nothing in it, still reaches the phone.
        XCTAssertTrue(entries.contains(where: { $0.path == "Client Work" && $0.parentPath == nil }))
        // Only discovered folders: nothing is published for areas that aren't on disk.
        XCTAssertFalse(entries.contains(where: { $0.path == "Projects" }))
        XCTAssertTrue(entries.contains(where: { $0.path == "Ideas/Read later.md" && $0.tagIDs == ["reading"] }))
        XCTAssertFalse(entries.contains(where: { $0.path.contains("watcher.item.toml") }))
        let projectedWork = candidates.compactMap { candidate -> MobileWorkItem? in
            if case .workItem(let item) = candidate { return item }; return nil
        }
        XCTAssertEqual(projectedWork.first?.id, "portable-id")
        XCTAssertEqual(projectedWork.first?.path, "To Do/ship.bw.md")
        XCTAssertEqual(projectedWork.first?.tagIDs, ["reading"])
    }

    func testProjectionRecordNamesAreStableAndBoundedForLongUserPaths() {
        let candidate = MobileCloudPublicationCandidate.entry(.init(
            path: "Ideas/" + String(repeating: "a", count: 4_000), parentPath: "Ideas",
            name: "long", isDirectory: false, revision: 0
        ))
        XCTAssertEqual(candidate.recordName, candidate.recordName)
        XCTAssertLessThan(candidate.recordName.utf8.count, 100)
        XCTAssertFalse(candidate.recordName.contains("Ideas"))
    }

    /// A replayed intent must not be applied twice. Tag assignment happens to be
    /// idempotent, but classification is not: applying it again moves a file that has
    /// already moved, which fails and — before expiry existed — retried forever.
    func testAnAlreadyHandledIntentIsRecognisedAcrossRelaunches() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MobileCloudReplay-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let database = try Database(url: root.appendingPathComponent("private.sqlite"))
        let state = MobileCloudProjectionState(database: database)

        let intent = MobileWorkspaceIntent.captureClassification(
            name: "Phone capture.md", kind: .task, tagIDs: ["t1"])
        XCTAssertFalse(try state.isHandled(intent.id))
        try state.markHandled(intent)
        XCTAssertTrue(try state.isHandled(intent.id))
        // Marking twice is what a redelivery does, and must stay harmless.
        try state.markHandled(intent)
        XCTAssertTrue(try MobileCloudProjectionState(database: database).isHandled(intent.id),
                      "The ledger has to survive a relaunch or every queued intent replays")
    }

    /// Two changes to one path have to be replayed in the order the phone made them.
    /// Sorting by record name sorted by mutation UUID, so a tag removed and then
    /// re-added could be applied the other way round and the Mac would end up with the
    /// opposite of what the phone last showed.
    func testIntentsForOnePathReplayInTheOrderTheyWereMade() {
        let path = "Ideas/Contested.md"
        let base = Date(timeIntervalSince1970: 1_000)
        // Names chosen so record-name order is the reverse of chronological order.
        let first = MobileWorkspaceIntent(
            id: UUID(uuidString: "FFFFFFFF-0000-0000-0000-000000000001")!, kind: .tagAssignment,
            targetPath: path, baseRevision: 3, tagIDs: [], addTagIDs: ["t1"], removeTagIDs: [],
            captureName: nil, captureKind: nil, createdAt: base)
        let second = MobileWorkspaceIntent(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!, kind: .tagAssignment,
            targetPath: path, baseRevision: 3, tagIDs: [], addTagIDs: [], removeTagIDs: ["t1"],
            captureName: nil, captureKind: nil, createdAt: base.addingTimeInterval(5))

        let ordered = [second, first]
            .map { MobileCloudInboundIntent(recordName: $0.id.uuidString, intent: $0) }
            .sorted { lhs, rhs in
                let left = lhs.intent?.createdAt ?? .distantFuture
                let right = rhs.intent?.createdAt ?? .distantFuture
                if left != right { return left < right }
                return lhs.recordName < rhs.recordName
            }

        XCTAssertEqual(ordered.map { $0.intent?.addTagIDs.isEmpty == false }, [true, false],
                       "The earlier addition has to be applied before the later removal")
        XCTAssertTrue(ordered.first!.recordName > ordered.last!.recordName,
                      "This case is only meaningful when record-name order disagrees")
    }

    /// CloudKit cannot infer a list field's element type from an empty array and
    /// rejects the whole record. Most work items carry no tags, so writing `[]` stopped
    /// the entire work-item projection from ever starting on a fresh container — the
    /// phone's Work tab stayed empty with no visible cause. Found end to end against
    /// the real Development container, not by a unit test.
    func testAnEmptyListIsLeftOutOfACloudKitRecordEntirely() {
        let record = CKRecord(recordType: "BWWorkItem", recordID: CKRecord.ID(recordName: "bw.test"))

        MobileCloudPublisher.setList([], forKey: "tagIDs", on: record)
        XCTAssertNil(record["tagIDs"], "An empty list must not be written at all")
        XCTAssertFalse(record.allKeys().contains("tagIDs"))

        MobileCloudPublisher.setList(["b", "a"], forKey: "tagIDs", on: record)
        XCTAssertEqual(record["tagIDs"] as? [String], ["b", "a"])

        // And emptying it again removes the key rather than writing `[]`.
        MobileCloudPublisher.setList([], forKey: "tagIDs", on: record)
        XCTAssertNil(record["tagIDs"])
    }

    /// Every reader on both sides has to treat a missing list exactly like an empty one,
    /// which is what makes leaving the field out safe.
    func testAMissingListReadsAsEmptyOnBothSides() {
        let record = CKRecord(recordType: MobileCloudSchema.indexRecordType,
                              recordID: CKRecord.ID(recordName: "bw.entry.test"))
        XCTAssertEqual(Set(record["tagIDs"] as? [String] ?? []), [])
        XCTAssertEqual(Set(record["addTagIDs"] as? [String] ?? []), [])
        XCTAssertEqual(Set(record["removeTagIDs"] as? [String] ?? []), [])
    }

    /// An intent the Mac cannot apply has to stop being retried eventually, or the
    /// command channel accumulates records every sync pass re-reads forever.
    func testAnUnappliedIntentExpiresSoTheChannelCanDrain() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let fresh = MobileWorkspaceIntent.captureClassification(name: "Just arrived.md", kind: .task, tagIDs: [])
        XCTAssertFalse(MobileIntentLifetime.hasExpired(fresh, now: fresh.createdAt))
        XCTAssertFalse(MobileIntentLifetime.hasExpired(
            fresh, now: fresh.createdAt.addingTimeInterval(MobileIntentLifetime.retryWindow - 1)),
            "iCloud can deliver a classification before its capture; it must keep retrying")
        XCTAssertTrue(MobileIntentLifetime.hasExpired(
            fresh, now: fresh.createdAt.addingTimeInterval(MobileIntentLifetime.retryWindow + 1)))

        let ancient = MobileWorkspaceIntent(
            id: UUID(), kind: .captureClassification, targetPath: nil, baseRevision: nil,
            tagIDs: [], addTagIDs: [], removeTagIDs: [], captureName: "Deleted on the phone.md",
            captureKind: .task, createdAt: now.addingTimeInterval(-MobileIntentLifetime.retryWindow * 2))
        XCTAssertTrue(MobileIntentLifetime.hasExpired(ancient, now: now))
    }

    /// The retry-safety the publisher depends on: a batch is non-atomic and each
    /// record's row advances on its own result, so a partial failure republishes only
    /// what did not land — and republishes it at the same revision, not a new one.
    func testAPartiallyPublishedBatchRepublishesOnlyWhatDidNotLand() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MobileCloudPartial-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let state = MobileCloudProjectionState(database: try Database(url: root.appendingPathComponent("private.sqlite")))

        let landed = MobileCloudPublicationCandidate.tag(Tag(id: "a", name: "Landed"))
        let lost = MobileCloudPublicationCandidate.tag(Tag(id: "b", name: "Lost"))
        let plan = try state.prepare([landed, lost])
        XCTAssertEqual(plan.records.count, 2)
        // Only one of the two saves succeeded.
        try state.markPublished(try XCTUnwrap(plan.records.first { $0.candidate.recordKey == "a" }))

        let retry = try state.prepare([landed, lost])
        let byKey = Dictionary(uniqueKeysWithValues: retry.records.map { ($0.candidate.recordKey, $0) })
        XCTAssertEqual(byKey["a"]?.changed, false, "A published record must not be sent again")
        XCTAssertEqual(byKey["b"]?.changed, true)
        XCTAssertEqual(byKey["b"]?.revision, 1, "A retry is the same version, not a newer one")
    }

    /// A record the workspace no longer contains is reported once, and stops being
    /// reported after its delete is recorded — including when CloudKit had already
    /// forgotten it.
    func testAStaleProjectionIsForgottenOnceItsDeleteIsRecorded() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MobileCloudStale-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let state = MobileCloudProjectionState(database: try Database(url: root.appendingPathComponent("private.sqlite")))

        let removed = MobileCloudPublicationCandidate.idea(MobileIdea(path: "Ideas/Gone", title: "Gone", revision: 0))
        try state.markPublished(try XCTUnwrap(state.prepare([removed]).records.first))

        let afterDeletion = try state.prepare([])
        XCTAssertTrue(afterDeletion.records.isEmpty)
        XCTAssertEqual(afterDeletion.stale.map(\.recordKey), ["Ideas/Gone"])

        try state.markDeleted(scope: "idea", recordKey: "Ideas/Gone")
        XCTAssertTrue(try state.prepare([]).stale.isEmpty)
    }

    /// Reconciliation is a one-time checkpoint, so a later failure cannot make the next
    /// pass re-delete and re-upload the whole projection.
    func testReconciliationHappensOnceEvenIfAPublishFailsAfterwards() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MobileCloudReconcile-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let database = try Database(url: root.appendingPathComponent("private.sqlite"))
        let state = MobileCloudProjectionState(database: database)

        XCTAssertTrue(try state.needsInitialReconciliation())
        try state.markInitialReconciled()
        XCTAssertFalse(try state.needsInitialReconciliation())
        XCTAssertFalse(try MobileCloudProjectionState(database: database).needsInitialReconciliation(),
                       "The checkpoint has to survive a relaunch")
    }

    func testProjectionStateRetainsRevisionAndHandledIntentAcrossNewInstances() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MobileCloudState-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let database = try Database(url: root.appendingPathComponent("private.sqlite"))
        let candidate = MobileCloudPublicationCandidate.tag(Tag(id: "tag", name: "One"))

        let first = MobileCloudProjectionState(database: database)
        let prepared = try XCTUnwrap(first.prepare([candidate]).records.first)
        XCTAssertTrue(prepared.changed)
        XCTAssertEqual(prepared.revision, 1)
        try first.markPublished(prepared)

        let restored = MobileCloudProjectionState(database: database)
        let unchanged = try XCTUnwrap(restored.prepare([candidate]).records.first)
        XCTAssertFalse(unchanged.changed)
        XCTAssertEqual(unchanged.revision, 1)
        let changed = MobileCloudPublicationCandidate.tag(Tag(id: "tag", name: "Renamed"))
        XCTAssertEqual(try XCTUnwrap(restored.prepare([changed]).records.first).revision, 2)

        let intent = MobileWorkspaceIntent.tagChange(path: "Ideas/One", baseRevision: 1, adding: ["tag"], removing: [])
        XCTAssertFalse(try restored.isHandled(intent.id))
        try restored.markHandled(intent)
        XCTAssertTrue(try MobileCloudProjectionState(database: database).isHandled(intent.id))
    }
}

final class WorkQueueRoutingTests: XCTestCase {

    private func folder(_ name: String, _ configuration: AreaConfiguration = .init()) -> WorkspaceFolder {
        WorkspaceFolder(url: URL(fileURLWithPath: "/tmp/W/\(name)"), name: name, identity: nil, personal: configuration)
    }

    func testTasksGoToTheDefaultTaskQueueEvenWithASiblingTaskQueue() {
        let folders = [folder("To Refactor"), folder("To Do"), folder("Ideas")]
        XCTAssertEqual(WorkQueueRouting.folder(for: .task, among: folders)?.name, "To Do")
        XCTAssertEqual(WorkQueueRouting.folder(for: .milestone, among: folders)?.name, nil)
    }

    func testRoutingFollowsConfigurationNotFolderNames() {
        // `To Do` renamed to `Actions` in Finder: its settings moved with it.
        let renamed = folder("Actions", AreaConfiguration(layout: .workQueue, workItemKind: .task, ingest: .primary))
        XCTAssertEqual(WorkQueueRouting.folder(for: .task, among: [folder("To Refactor"), renamed])?.name, "Actions")
        // And a folder turned back into a plain list is no longer a queue.
        let demoted = folder("To Do", AreaConfiguration(layout: .list))
        XCTAssertEqual(WorkQueueRouting.folder(for: .task, among: [demoted, folder("To Refactor")])?.name, "To Refactor")
    }

    func testNotionImportUsesTheConfiguredQueues() {
        let workspace = WorkspaceLocation(root: URL(fileURLWithPath: "/tmp/W"))
        let queue = folder("Roadmap", AreaConfiguration(layout: .workQueue, workItemKind: .milestone))
        let destinations = NotionImport.Destinations(workspace: workspace, folders: [queue, folder("To Do")])
        XCTAssertEqual(destinations.milestones.lastPathComponent, "Roadmap")
        XCTAssertEqual(destinations.tasks.lastPathComponent, "To Do")
        XCTAssertEqual(destinations.features.lastPathComponent, "Features", "falls back to the default name")
    }
}
