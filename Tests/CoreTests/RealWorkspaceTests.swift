import XCTest
@testable import BetterWorkspaceCore

/// Integration tests against the user's actual `~/Workspace` and the actual ingest
/// inbox, using the same code paths the app uses.
///
/// Opt in with BW_RUN_PERSONAL_WORKSPACE_TESTS=1. These are personal installation
/// diagnostics, not isolated release acceptance. The tests create named inbox/probe
/// items and remove only their own items; ordinary test runs must not touch this data.
final class RealWorkspaceTests: XCTestCase {

    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["BW_RUN_PERSONAL_WORKSPACE_TESTS"] == "1",
                          "Personal workspace diagnostics require explicit opt-in; release tests use isolated fixtures")
    }

    private let location = WorkspaceLocation(root: WorkspaceLocation.defaultRoot)
    private let fs = FilesystemService()

    private func skipIfNoWorkspace() throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: location.root.path),
                          "No ~/Workspace on this machine")
    }

    // MARK: - Every discovered area loads real content

    func testEveryAreaListsItsRealImmediateChildren() async throws {
        try skipIfNoWorkspace()
        // Discovery, not a compiled list: whatever folders are really there. The
        // configuration store points at a scratch file so this reads nothing private.
        let scratch = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("bw-real-areas-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let folders = try XCTUnwrap(WorkspaceFolderDiscovery().folders(in: location, store: AreaConfigurationStore(url: scratch)))
        XCTAssertFalse(folders.contains { $0.name == "_audit" || $0.name.hasPrefix(".") },
                       "Other tools' top-level metadata is never an area")
        XCTAssertFalse(FileManager.default.fileExists(atPath: scratch.path), "Discovery alone writes no settings")
        var summary: [String] = []
        for folder in folders {
            let area = folder
            let items = try await fs.items(inArea: folder.name, location: location)
            summary.append("\(area.displayName): \(items.count)")

            XCTAssertFalse(items.contains { $0.name == ".DS_Store" },
                           "\(area.displayName) must not surface .DS_Store")
            XCTAssertFalse(items.contains { $0.name == "watcher.item.toml" },
                           "\(area.displayName) must not surface Workspace Watcher metadata")
            XCTAssertFalse(items.contains { $0.name.hasSuffix(".betterproject") },
                           "\(area.displayName) must not surface Better Projects metadata")
            for item in items {
                XCTAssertNotNil(item.identity, "Every real item must resolve a file identity")
            }
        }
        print("REAL AREA COUNTS — " + summary.joined(separator: ", "))
        XCTAssertGreaterThan(summary.count, 0, "At least one established area should be discoverable")
    }

    func testIdeasAreMostlyEmptyFoldersWhoseNameIsTheIdea() async throws {
        try skipIfNoWorkspace()
        let items = try await fs.items(in: .ideas, location: location)
        try XCTSkipIf(items.isEmpty)
        let empty = items.filter { ($0.immediateChildCount ?? 0) == 0 }
        print("REAL IDEAS — \(items.count) items, \(empty.count) with no content of their own")
        XCTAssertGreaterThan(Double(empty.count) / Double(items.count), 0.5,
                             "The survey found Ideas folders are overwhelmingly empty; the "
                             + "title-led interface depends on that still being true")
    }

    func testProjectKindDetectionMatchesTheSurvey() async throws {
        try skipIfNoWorkspace()
        let items = try await fs.items(in: .projects, location: location)
        try XCTSkipIf(items.isEmpty)
        let probe = ItemProbe()
        var counts: [ProjectKind: Int] = [:]
        var gitRepos = 0
        for item in items {
            let detail = await probe.detail(for: item)
            counts[detail.projectKind, default: 0] += 1
            if detail.isGitRepository { gitRepos += 1 }
        }
        print("REAL PROJECTS — \(items.count) items, \(gitRepos) git repos, kinds: "
              + counts.sorted { $0.value > $1.value }.map { "\($0.key.rawValue)=\($0.value)" }.joined(separator: " "))
        XCTAssertGreaterThan(gitRepos, 0)
        XCTAssertGreaterThan(counts.count, 2, "Projects should resolve into several distinct kinds")
    }

    func testInspirationIsDominatedByVisualMedia() async throws {
        try skipIfNoWorkspace()
        let root = location.url(for: .inspiration)
        try XCTSkipUnless(FileManager.default.fileExists(atPath: root.path))
        let media = await fs.media(under: root)
        print("REAL INSPIRATION — flattened to \(media.count) media files")
        XCTAssertGreaterThan(media.count, 0, "The gallery's Flatten mode must find real media")
        XCTAssertTrue(media.allSatisfy { $0.kind.isVisualMedia })
    }

    func testLogsHaveTheDayFolderShapeTheViewerAssumes() async throws {
        try skipIfNoWorkspace()
        let days = try await fs.items(in: .logs, location: location)
        try XCTSkipIf(days.isEmpty)
        let dated = days.filter { $0.name.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil }
        print("REAL LOGS — \(days.count) entries, \(dated.count) date folders")
        XCTAssertGreaterThan(dated.count, 0, "The log viewer's date sidebar needs date folders")

        if let day = dated.first {
            let files = try await fs.items(inDirectory: day.url)
            if let logFile = files.first(where: { $0.kind == .log }) {
                let tail = await fs.readTail(at: logFile.url)
                XCTAssertNotNil(tail, "Log tail must be readable")
            }
        }
    }

    func testLargeAreasNeverComputeRecursiveSizeDuringAListing() async throws {
        try skipIfNoWorkspace()
        // Projects is 73 GB. A listing that walked it would take minutes.
        let start = Date()
        _ = try await fs.items(in: .projects, location: location)
        let elapsed = Date().timeIntervalSince(start)
        print("REAL PROJECTS LISTING — \(String(format: "%.2f", elapsed))s")
        XCTAssertLessThan(elapsed, 20, "Listing must stay shallow")
    }

    // MARK: - Ingest end-to-end against the real inbox

    func testEndToEndCaptureTagAndClassifyAgainstTheRealFilesystem() async throws {
        try skipIfNoWorkspace()

        // A dedicated inbox on local disk. The *destinations* are the user's real
        // `~/Workspace/Ideas` and `~/Workspace/Projects`, which is the part that matters;
        // the source folder is local so the test can't be wedged by a sleeping iCloud
        // file provider. `testRealICloudInboxIsReadable` covers the real inbox.
        let inbox = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bw-real-inbox-\(UUID().uuidString)", isDirectory: true)
        let ingestLocation = IngestLocation(inbox: inbox, backing: .local)
        XCTAssertTrue(ingestLocation.ensureExists())
        defer { try? FileManager.default.removeItem(at: inbox) }

        // Use the app's real private database so this exercises production storage.
        let db = try Database(url: try Database.defaultURL())
        let tagStore = TagStore(database: db)
        let ingest = IngestService(location: ingestLocation, database: db,
                                   tagStore: tagStore, workspace: location)

        let marker = "BW Probe \(UUID().uuidString.prefix(8))"

        // 1. Typed text becomes a real .md file in the real inbox.
        let captured = try ingest.captureText("\(marker)\n\nCreated by an automated test.")
        XCTAssertTrue(FileManager.default.fileExists(atPath: captured.url.path))
        XCTAssertEqual(captured.url.pathExtension, "md")
        XCTAssertEqual(captured.url.deletingLastPathComponent().canonicalPath,
                       ingestLocation.inbox.canonicalPath)

        // 2. A folder dropped into the inbox.
        let scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("\(marker) Folder", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch.appendingPathComponent("src"),
                                                withIntermediateDirectories: true)
        try "# probe".write(to: scratch.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        let droppedFolder = try ingest.importItem(at: scratch, source: .desktopDrop)
        try? FileManager.default.removeItem(at: scratch)

        // 3. Binary/media data capture.
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        let droppedImage = try ingest.importData(png, preferredName: "\(marker) Image",
                                                 extension: "png", source: .desktopDrop)

        // 4. Something that arrived by other means — Finder, a shell, iCloud from the phone.
        let external = ingestLocation.inbox.appendingPathComponent("\(marker) External.txt")
        try "arrived outside the app".write(to: external, atomically: true, encoding: .utf8)

        // The inbox is read from the filesystem, so all four are pending.
        var pending = await ingest.pendingItems(fsService: fs) ?? []
        let mine = pending.filter { $0.url.lastPathComponent.contains(marker) }
        XCTAssertEqual(mine.count, 4, "All four capture routes must appear in the inbox")
        XCTAssertEqual(mine.first { $0.url.canonicalPath == external.canonicalPath }?.source, .external)

        // 5. Tags assigned *before* classification, from the shared repository.
        let aiTag = try XCTUnwrap(tagStore.createTag(named: "AI"))
        let hardwareTag = try XCTUnwrap(tagStore.createTag(named: "Hardware"))
        let notePending = try XCTUnwrap(pending.first { $0.url.canonicalPath == captured.url.canonicalPath })
        tagStore.assign(tagID: aiTag.id, to: notePending.url, area: nil)
        tagStore.assign(tagID: hardwareTag.id, to: notePending.url, area: nil)
        XCTAssertEqual(Set(tagStore.tags(for: notePending.url).map(\.name)), ["AI", "Hardware"])

        let folderPending = try XCTUnwrap(pending.first { $0.url.canonicalPath == droppedFolder.url.canonicalPath })
        tagStore.assign(tagID: aiTag.id, to: folderPending.url, area: nil)

        // 6. Classify the note as an Idea — a real move into ~/Workspace/Ideas.
        let ideasBefore = try await fs.items(in: .ideas, location: location).count
        let ideaDestination = try ingest.classify(notePending, into: .ideas, renamingTo: marker)
        XCTAssertTrue(FileManager.default.fileExists(atPath: ideaDestination.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: captured.url.path))
        XCTAssertEqual(ideaDestination.deletingLastPathComponent().lastPathComponent, "Ideas")
        let ideasAfter = try await fs.items(in: .ideas, location: location).count
        XCTAssertEqual(ideasAfter, ideasBefore + 1)

        // Tags survived the move, and the item now reports as living in Ideas.
        XCTAssertEqual(Set(tagStore.tags(for: ideaDestination).map(\.name)), ["AI", "Hardware"],
                       "Tags must survive classification")
        let aiObjects = tagStore.objects(withTagID: aiTag.id)
        XCTAssertTrue(aiObjects.contains { $0.lastPath == ideaDestination.canonicalPath
                                            && $0.area == "Ideas" })

        // 7. Classify the folder as a Project — must arrive intact.
        let projectDestination = try ingest.classify(folderPending, into: .projects,
                                                     renamingTo: "\(marker) Project")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: projectDestination.appendingPathComponent("src").path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: projectDestination.appendingPathComponent("README.md").path))
        XCTAssertEqual(tagStore.tags(for: projectDestination).map(\.name), ["AI"])

        // 8. The same tag now spans two different areas — one repository, not nine.
        let spread = Set(tagStore.objects(withTagID: aiTag.id).compactMap(\.area))
        XCTAssertTrue(spread.isSuperset(of: ["Ideas", "Projects"]),
                      "One tag must be reusable across areas; got \(spread)")

        // 9. Next-item flow: two remain pending, classified ones are gone.
        pending = await ingest.pendingItems(fsService: fs) ?? []
        let remaining = pending.filter { $0.url.lastPathComponent.contains(marker) }
        XCTAssertEqual(remaining.count, 2)
        XCTAssertFalse(remaining.contains { $0.url.canonicalPath == captured.url.canonicalPath })

        // 10. Deferring keeps an item but moves it behind pending ones.
        if let first = remaining.first {
            ingest.setState(.deferred, for: first)
            let after = await ingest.pendingItems(fsService: fs) ?? []
            XCTAssertEqual(after.first { $0.id == first.id }?.state, .deferred)
        }

        // --- Clean up everything this test created. ---
        try? FileManager.default.removeItem(at: ideaDestination)
        try? FileManager.default.removeItem(at: projectDestination)
        try? FileManager.default.removeItem(at: droppedImage.url)
        try? FileManager.default.removeItem(at: external)
        for tag in [aiTag, hardwareTag] where tagStore.objects(withTagID: tag.id).isEmpty {
            tagStore.deleteTag(id: tag.id)
        }
        _ = tagStore.pruneMissingObjects()

        XCTAssertFalse(FileManager.default.fileExists(atPath: ideaDestination.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: projectDestination.path))
        let leftovers = await ingest.pendingItems(fsService: fs) ?? []
            .filter { $0.url.lastPathComponent.contains(marker) }
        XCTAssertTrue(leftovers.isEmpty, "Test left items behind: \(leftovers.map(\.title))")
    }

    func testClassifyingNeverTouchesNeighbouringWorkspaceItems() async throws {
        try skipIfNoWorkspace()
        let inbox = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bw-neighbour-\(UUID().uuidString)", isDirectory: true)
        let ingestLocation = IngestLocation(inbox: inbox, backing: .local)
        ingestLocation.ensureExists()
        defer { try? FileManager.default.removeItem(at: inbox) }
        let db = try Database(url: try Database.defaultURL())
        let ingest = IngestService(location: ingestLocation, database: db,
                                   tagStore: TagStore(database: db), workspace: location)

        func manifest() throws -> [String] {
            let url = self.location.url(for: .ideas)
            return try FileManager.default.contentsOfDirectory(atPath: url.path).sorted()
        }

        let before = try manifest()
        let marker = "BW Neighbour \(UUID().uuidString.prefix(6))"
        _ = try ingest.captureText(marker)
        let pending = await ingest.pendingItems(fsService: fs) ?? []
        let mine = try XCTUnwrap(pending.first { $0.title.contains(marker) })
        let destination = try ingest.classify(mine, into: .ideas, renamingTo: marker)

        let during = try manifest()
        XCTAssertEqual(Set(during).subtracting(before), [destination.lastPathComponent],
                       "Classifying must add exactly one item and disturb nothing else")

        try? FileManager.default.removeItem(at: destination)
        XCTAssertEqual(try manifest(), before, "Ideas must be byte-for-byte as we found it")
    }

    // MARK: - The real iCloud-backed inbox

    /// Exercises the actual configured inbox — the one the shipping app and the iOS
    /// companion share.
    ///
    /// Skips rather than fails when iCloud's file provider doesn't answer, because that
    /// is an environment condition, not a defect. The app handles the same condition by
    /// showing a waiting state.
    func testRealICloudInboxIsReadable() async throws {
        try skipIfNoWorkspace()
        let location = IngestLocation.resolve()
        XCTAssertTrue(location.ensureExists())
        print("REAL INBOX — \(location.inbox.path) [\(location.backingDescription)]")

        let items = await FilesystemService.items(inDirectory: location.inbox, timeout: .seconds(20))
        try XCTSkipIf(items == nil, "iCloud file provider did not answer within 20s")
        print("REAL INBOX — \(items!.count) items waiting")

        let db = try Database(url: try Database.defaultURL())
        let ingest = IngestService(location: location, database: db,
                                   tagStore: TagStore(database: db), workspace: self.location)

        let marker = "BW iCloud Probe \(UUID().uuidString.prefix(6))"
        let captured = try ingest.captureText(marker)
        XCTAssertTrue(FileManager.default.fileExists(atPath: captured.url.path),
                      "Capture must be a real file in the real iCloud inbox")
        XCTAssertEqual(captured.url.pathExtension, "md")
        XCTAssertEqual(SourceMarker.read(from: captured.url), .quickCapture,
                       "Source is recorded as an xattr, not a sidecar file")

        let after = await ingest.pendingItems(fsService: fs, timeout: .seconds(20))
        if let after {
            XCTAssertTrue(after.contains { $0.url.lastPathComponent.contains(marker) })
        }

        try? FileManager.default.removeItem(at: captured.url)
        XCTAssertFalse(FileManager.default.fileExists(atPath: captured.url.path))
    }

    // MARK: - Migrating out of Better Projects

    /// Runs the real migration over the real `Project.betterproject` files in preview
    /// mode. Nothing is written anywhere: not to the sidecars, which this app must
    /// never modify, and not to a store, because `apply` is false.
    func testLegacyDocumentImportPreviewsTheRealSidecarsWithoutTouchingThem() throws {
        try skipIfNoWorkspace()
        let projectsRoot = location.url(for: .projects)
        try XCTSkipUnless(FileManager.default.fileExists(atPath: projectsRoot.path))

        let documents = LegacyImport.scanDocuments(in: projectsRoot)
        try XCTSkipIf(documents.isEmpty, "No Better Projects documents in this Workspace")

        let fingerprint = { (document: LegacyImport.Document) -> String? in
            guard let data = try? Data(contentsOf: document.fileURL) else { return nil }
            let date = (try? document.fileURL.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
            return "\(data.count):\(String(describing: date))"
        }
        let before = documents.map(fingerprint)

        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bw-legacy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProjectStore(database: try Database(url: root.appendingPathComponent("p.sqlite")))

        let report = LegacyImport.importDocuments(documents, into: store, apply: false)

        XCTAssertEqual(report.discovered, documents.count)
        XCTAssertTrue(report.conflicts.isEmpty, "A first import into an empty store cannot conflict")
        XCTAssertEqual(report.notionLinksRecovered,
                       documents.filter { $0.notionProjectID != nil && $0.directoryExists }.count)
        XCTAssertTrue(store.allRecords().isEmpty, "Preview must not write to the store")
        XCTAssertEqual(documents.map(fingerprint), before, "Sidecars must be byte-for-byte untouched")

        print("REAL LEGACY IMPORT PREVIEW — \(report.discovered) documents, "
              + "\(report.imported) importable, \(report.notionLinksRecovered) Notion links recoverable, "
              + "\(report.skippedMissingDirectory.count) missing directories")
    }

    /// Every project this app can see should be registerable and get a stable id,
    /// whether or not it has ever been near Notion.
    func testEveryRealProjectRegistersAndKeepsItsIdentity() async throws {
        try skipIfNoWorkspace()
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bw-identity-real-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProjectStore(database: try Database(url: root.appendingPathComponent("p.sqlite")))

        let projects = try await fs.items(in: .projects, location: location)
        try XCTSkipIf(projects.isEmpty, "No projects in this Workspace")

        let ids = projects.map { store.register(url: $0.url).id }
        XCTAssertEqual(Set(ids).count, projects.count, "Every project needs its own id")
        // Registering again must find the same rows, not duplicate them.
        let second = projects.map { store.register(url: $0.url).id }
        XCTAssertEqual(ids, second)
        XCTAssertEqual(store.allRecords().count, projects.count)
        XCTAssertTrue(store.allRecords().allSatisfy { $0.notionPageID == nil },
                      "Registration alone must never invent a Notion association")
    }


    // MARK: - Measurements from the live Workspace Watcher

    /// Reads the real daemon if it happens to be running, and skips if it is not.
    ///
    /// Skipping is the point as much as passing: Better Workspace has to be completely
    /// usable with the daemon down, so this must never be a required dependency.
    func testLiveMeasurementsJoinToProjectsByWatcherIdentity() async throws {
        try skipIfNoWorkspace()
        let service = MeasurementService()
        let reachable = await service.refresh(timeout: 8)
        try XCTSkipUnless(reachable, "Workspace Watcher is not running — measurements are unknown, which is allowed")

        let count = await service.projectCount
        XCTAssertGreaterThan(count, 0, "A reachable daemon should describe at least one project")

        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bw-measure-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ProjectStore(database: try Database(url: root.appendingPathComponent("p.sqlite")))
        let documents = LegacyImport.scanDocuments(in: location.url(for: .projects))
        try XCTSkipIf(documents.isEmpty, "No project documents to join against")
        LegacyImport.importDocuments(documents, into: store, apply: true)

        let withWatcherID = store.allRecords().filter { $0.watcherID != nil }
        try XCTSkipIf(withWatcherID.isEmpty, "No Watcher identities were imported")

        var joined = 0
        var measured = 0
        for record in withWatcherID {
            guard let measurements = await service.measurements(watcherID: record.watcherID) else { continue }
            joined += 1
            if measurements.measurement(.investmentObserved)?.value != nil { measured += 1 }
        }
        XCTAssertEqual(joined, withWatcherID.count,
                       "Every project carrying a Watcher id should be findable in the measurement set")

        // Whatever the daemon could not measure must arrive as unknown, never as zero.
        for record in withWatcherID.prefix(40) {
            guard let effort = await service.measurement(.investmentObserved, watcherID: record.watcherID) else { continue }
            if effort.state == .unknown { XCTAssertNil(effort.value, "\(record.name): unknown must not carry a value") }
            if effort.value != nil { XCTAssertNotEqual(effort.state, .unknown) }
        }

        print("LIVE MEASUREMENTS — \(joined) projects joined, \(measured) with observed effort")
    }

}
