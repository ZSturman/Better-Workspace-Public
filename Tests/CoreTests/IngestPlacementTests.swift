import XCTest
@testable import BetterWorkspaceCore

/// Typing a tag finds the existing one first; the shared Mac/phone ranking.
final class TagMatchingTests: XCTestCase {
    private let tags = ["Programming", "Projects", "Improvement", "Cooking", "Machine Learning", "Bus"]
        .map { Tag(id: $0, name: $0) }

    private func names(_ tags: [Tag]) -> [String] { tags.map(\.name) }

    func testTypingNarrowsToMatchingTagsBestFirst() {
        XCTAssertEqual(names(TagMatching.ranked("pro", in: tags)), ["Programming", "Projects", "Improvement"],
                       "Names that start with the text come before names that merely contain it")
        XCTAssertEqual(names(TagMatching.ranked("PROJ", in: tags)), ["Projects"])
        XCTAssertEqual(names(TagMatching.ranked("learn", in: tags)), ["Machine Learning"],
                       "A later word that starts with the text is a match")
        XCTAssertEqual(TagMatching.ranked("", in: tags).count, tags.count, "No text lists every tag")
        XCTAssertTrue(TagMatching.ranked("zzz", in: tags).isEmpty)
    }

    func testSpellingVariantsAreTheSameTag() {
        XCTAssertEqual(TagMatching.equivalent(to: "project", in: tags)?.name, "Projects")
        XCTAssertEqual(TagMatching.equivalent(to: " machine-learning ", in: tags)?.name, "Machine Learning")
        XCTAssertEqual(TagMatching.equivalent(to: "Cöoking", in: tags)?.name, "Cooking")
        XCTAssertEqual(TagMatching.equivalent(to: "bus", in: tags)?.name, "Bus")
        XCTAssertNil(TagMatching.equivalent(to: "bu", in: tags), "A short word is not a plural")
        XCTAssertNil(TagMatching.equivalent(to: "Program", in: tags))
    }

    func testSpacingAndCaseNeverMakeASecondTag() {
        let tags = ["Raspberry Pi", "Next.js", "Tailwind CSS"].map { Tag(id: $0, name: $0) }
        for typed in ["raspberry pi", "RaspberryPi", "raspberrypi", "RASPBERRY-PI", "raspberry_pi", "Raspberry  Pi"] {
            XCTAssertEqual(TagMatching.equivalent(to: typed, in: tags)?.name, "Raspberry Pi", typed)
            XCTAssertEqual(TagMatching.resolve(typed, in: tags), .existing(tags[0]), typed)
        }
        XCTAssertEqual(TagMatching.equivalent(to: "nextjs", in: tags)?.name, "Next.js")
        XCTAssertEqual(TagMatching.equivalent(to: "TailwindCSS", in: tags)?.name, "Tailwind CSS")
        XCTAssertEqual(names(TagMatching.ranked("raspberryp", in: tags)), ["Raspberry Pi"],
                       "A half-typed name finds the tag whether or not the space was typed")
        XCTAssertEqual(names(TagMatching.ranked("rasp", in: tags)), ["Raspberry Pi"])
        XCTAssertNil(TagMatching.equivalent(to: "Raspberry", in: tags), "A prefix is a different name")
    }

    func testReturnPrefersAnExistingTagAndOtherwiseCreates() {
        XCTAssertEqual(TagMatching.resolve("pro", in: tags), .existing(tags[0]))
        XCTAssertEqual(TagMatching.resolve("project", in: tags), .existing(tags[1]),
                       "The same name, singular, must not become a duplicate")
        XCTAssertEqual(TagMatching.resolve("learning", in: tags), .existing(tags[4]))
        XCTAssertEqual(TagMatching.resolve("prov", in: tags), .create("prov"),
                       "Text found only mid-word is not a good enough match to replace a new tag")
        XCTAssertEqual(TagMatching.resolve("  Gardening ", in: tags), .create("Gardening"))
        XCTAssertEqual(TagMatching.resolve("   ", in: tags), .nothing)
    }
}

/// Recently Added: one row per capture, each saying where it actually is.
final class RecentCaptureHistoryTests: XCTestCase {
    private let inboxDir = URL(fileURLWithPath: "/tmp/Inbox", isDirectory: true)
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func inboxFile(_ name: String, minutesAgo: Double = 1) -> (url: URL, modified: Date) {
        (inboxDir.appendingPathComponent(name), now.addingTimeInterval(-minutesAgo * 60))
    }

    private func record(_ name: String, minutesAgo: Double = 1, to destination: String? = nil) -> RecentCaptureRecord {
        RecentCaptureRecord(name: name, savedAt: now.addingTimeInterval(-minutesAgo * 60),
                            destinationPath: destination, destinationName: destination)
    }

    private func entry(_ path: String, parent: String?) -> MobileWorkspaceEntry {
        MobileWorkspaceEntry(path: path, parentPath: parent, name: (path as NSString).lastPathComponent,
                             isDirectory: parent == nil, revision: 1)
    }

    private func placement(of name: String, in rows: [RecentCaptureRow]) -> RecentCapturePlacement? {
        rows.first { $0.name == name }?.placement
    }

    func testEachRowShowsWhereItsCaptureIs() {
        let records = [
            record("Waiting.md", minutesAgo: 1),
            record("On its way.md", minutesAgo: 2, to: "For Reference"),
            record("Article Name.md", minutesAgo: 3, to: "For Reference"),
            record("Not indexed yet.md", minutesAgo: 4, to: "For Reference"),
        ]
        let inbox = [inboxFile("Waiting.md"), inboxFile("On its way.md", minutesAgo: 2),
                     inboxFile("From the Mac.md", minutesAgo: 5)]
        let entries = [entry("For Reference", parent: nil), entry("For Reference/Article Name.md", parent: "For Reference")]

        let rows = RecentCaptureHistory.rows(records: records, inbox: inbox, entries: entries)

        XCTAssertEqual(rows.map(\.name), ["Waiting.md", "On its way.md", "Article Name.md",
                                          "Not indexed yet.md", "From the Mac.md"], "Newest first, one row each")
        XCTAssertEqual(placement(of: "Waiting.md", in: rows), .needsFiling)
        XCTAssertEqual(placement(of: "On its way.md", in: rows), .filing(destination: "For Reference"))
        XCTAssertEqual(placement(of: "Article Name.md", in: rows),
                       .filed(destination: "For Reference", path: "For Reference/Article Name.md"))
        XCTAssertEqual(placement(of: "Not indexed yet.md", in: rows), .filed(destination: "For Reference", path: nil))
        XCTAssertEqual(placement(of: "From the Mac.md", in: rows), .needsFiling,
                       "Inbox content this phone did not save still needs filing")
        XCTAssertFalse(placement(of: "On its way.md", in: rows)!.isPlaced,
                       "Asked for, but not yet placed")
        XCTAssertNotNil(rows.first { $0.name == "Waiting.md" }?.inboxURL)
        XCTAssertNil(rows.first { $0.name == "Article Name.md" }?.inboxURL)
    }

    func testACaptureFiledOnTheMacIsFoundOnlyWhenUnambiguous() {
        let entries = [entry("To Read", parent: nil), entry("To Read/Essay.md", parent: "To Read"),
                       entry("Ideas", parent: nil), entry("Ideas/Note.md", parent: "Ideas"),
                       entry("To Read/Note.md", parent: "To Read")]
        let rows = RecentCaptureHistory.rows(records: [record("Essay.md"), record("Note.md"), record("Gone.md")],
                                             inbox: [], entries: entries)
        XCTAssertEqual(placement(of: "Essay.md", in: rows), .filed(destination: "To Read", path: "To Read/Essay.md"))
        XCTAssertEqual(placement(of: "Note.md", in: rows), .filedOnMac, "Two candidates name neither")
        XCTAssertEqual(placement(of: "Gone.md", in: rows), .filedOnMac)
    }

    func testAReusedInboxNameBelongsToTheNewestSave() {
        let rows = RecentCaptureHistory.rows(
            records: [record("Note.md", minutesAgo: 60, to: "Ideas"), record("Note.md", minutesAgo: 1)],
            inbox: [inboxFile("Note.md")], entries: [])
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].placement, .needsFiling)
        XCTAssertEqual(rows[1].placement, .filed(destination: "Ideas", path: nil))
    }

    func testSavedMessageNamesTheActualDestination() {
        XCTAssertEqual(RecentCaptureHistory.savedMessage(count: 1, destinationName: "For Reference"),
                       "Added to For Reference")
        XCTAssertEqual(RecentCaptureHistory.savedMessage(count: 1, destinationName: nil), "Added to Inbox")
        XCTAssertEqual(RecentCaptureHistory.savedMessage(count: 3, destinationName: "Ideas"), "Added 3 files to Ideas")
    }

    func testLogKeepsOnlyRecentRecordsAndUpdatesInPlace() throws {
        let suite = "RecentCaptureLogTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let log = RecentCaptureLog(defaults: defaults, key: "log")

        log.recordSave(name: "Old.md", destinationPath: nil, destinationName: nil,
                       now: now.addingTimeInterval(-15 * 24 * 60 * 60))
        log.recordSave(name: "Note.md", destinationPath: nil, destinationName: nil, now: now)
        var records = log.setDestination(name: "Note.md", savedAt: now, destinationPath: "Ideas",
                                         destinationName: "Ideas", now: now)
        XCTAssertEqual(records.map(\.name), ["Note.md"], "Past the retention window is forgotten")
        XCTAssertEqual(records.first?.destinationName, "Ideas", "Filing updates the save, never adds a second")

        records = log.setDestination(name: "Elsewhere.md", savedAt: now.addingTimeInterval(-60),
                                     destinationPath: "To Read", destinationName: "To Read", now: now)
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(log.forget(name: "Note.md", now: now).map(\.name), ["Elsewhere.md"])
    }
}

/// Filing leaves a record of where the capture went, separate from the inbox queue.
final class IngestRecentlyFiledTests: XCTestCase {
    private var root: URL!
    private var inbox: URL!
    private var workspace: WorkspaceLocation!
    private var dbURL: URL!
    private var ingest: IngestService!
    private var tagStore: TagStore!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("bw-filed-\(UUID().uuidString)")
        inbox = root.appendingPathComponent("Inbox", isDirectory: true)
        let workspaceRoot = root.appendingPathComponent("Workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workspaceRoot.appendingPathComponent("For Reference"),
                                                withIntermediateDirectories: true)
        workspace = WorkspaceLocation(root: workspaceRoot)
        dbURL = root.appendingPathComponent("db.sqlite")
        try open()
    }

    override func tearDownWithError() throws {
        ingest = nil
        tagStore = nil
        try? FileManager.default.removeItem(at: root)
    }

    private func open() throws {
        let db = try Database(url: dbURL)
        tagStore = TagStore(database: db)
        ingest = IngestService(location: IngestLocation(inbox: inbox, backing: .local),
                               database: db, tagStore: tagStore, workspace: workspace)
    }

    private var forReference: URL { workspace.root.appendingPathComponent("For Reference", isDirectory: true) }

    func testFilingRecordsTheDestinationAndLeavesTheQueue() async throws {
        let captured = try ingest.captureText("Article Name\n\nWorth keeping.")
        let tag = try XCTUnwrap(tagStore.createTag(named: "Reference"))
        tagStore.assign(tagID: tag.id, to: captured.url, area: nil)
        let pending = try await XCTUnwrapAsync(await ingest.pendingItems(fsService: FilesystemService()))
        XCTAssertEqual(pending.count, 1)

        let filed = try ingest.classify(pending[0], intoDirectory: forReference, renamingTo: nil)

        let afterFiling = try await XCTUnwrapAsync(await ingest.pendingItems(fsService: FilesystemService()))
        XCTAssertTrue(afterFiling.isEmpty, "A filed capture no longer needs filing")
        // Twice: a scan forgets inbox rows missing from two consecutive listings. A
        // filed record is not an inbox row and must survive that.
        _ = await ingest.pendingItems(fsService: FilesystemService())

        let recent = ingest.recentlyFiled()
        XCTAssertEqual(recent.count, 1)
        XCTAssertEqual(recent.first?.destinationName, "For Reference")
        XCTAssertEqual(recent.first?.title, "Article Name")
        XCTAssertEqual(recent.first?.url.canonicalPath, filed.canonicalPath, "The real filed object, not a copy")
        XCTAssertTrue(FileManager.default.fileExists(atPath: filed.path))
        XCTAssertEqual(tagStore.tags(for: filed).map(\.name), ["Reference"], "Tags follow the capture")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: forReference.path), [filed.lastPathComponent],
                       "Nothing but the capture is written beside it")
    }

    func testFiledRecordsExpire() async throws {
        _ = try ingest.captureText("Short lived")
        let pending = try await XCTUnwrapAsync(await ingest.pendingItems(fsService: FilesystemService()))
        try ingest.classify(pending[0], intoDirectory: forReference, renamingTo: nil)
        XCTAssertEqual(ingest.recentlyFiled().count, 1)
        XCTAssertTrue(ingest.recentlyFiled(now: Date().addingTimeInterval(IngestService.filedRetention + 60)).isEmpty)
        XCTAssertTrue(ingest.recentlyFiled().isEmpty, "Expired records are forgotten, not just hidden")
    }

    func testAnOlderDatabaseGainsTheFiledColumn() throws {
        ingest = nil
        tagStore = nil
        try FileManager.default.removeItem(at: dbURL)
        do {
            let old = try Database(url: dbURL)
            try old.execute("ALTER TABLE ingest_items DROP COLUMN filed_at;")
        }
        try open()
        XCTAssertTrue(ingest.recentlyFiled().isEmpty)
        let db = try Database(url: dbURL)
        let columns = try db.query("PRAGMA table_info(ingest_items)") { $0.string(1) }
        XCTAssertTrue(columns.contains("filed_at"))
    }
}

private func XCTUnwrapAsync<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) async throws -> T {
    try XCTUnwrap(value, file: file, line: line)
}

/// The queue every phone entry point (app, App Intents, Share extension) saves through.
final class MobileCaptureQueueTests: XCTestCase {
    private var suite: String!
    private var defaults: UserDefaults!
    private var queue: MobileCaptureQueue!
    private let inbox = URL(fileURLWithPath: "/tmp/Inbox", isDirectory: true)

    override func setUpWithError() throws {
        suite = "MobileCaptureQueueTests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        queue = MobileCaptureQueue(defaults: defaults)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
    }

    private let reference = MobileCaptureDestination(path: "For Reference", name: "For Reference")

    func testAPlainInboxSaveQueuesNothingButIsRecorded() {
        let records = queue.record(savedURL: inbox.appendingPathComponent("Thought.md"), destination: nil)
        XCTAssertTrue(queue.outbox.queued().isEmpty, "Nothing to tell the Mac about a capture that stays in the Inbox")
        XCTAssertEqual(records.map(\.name), ["Thought.md"])
        XCTAssertNil(records.first?.destinationName)
    }

    func testAFolderSaveQueuesItsFilingAndRecordsTheDestination() throws {
        let records = queue.record(savedURL: inbox.appendingPathComponent("Article.md"), destination: reference,
                                   tagIDs: ["t1"])
        let intent = try XCTUnwrap(queue.outbox.queued().first)
        XCTAssertEqual(intent.kind, .captureClassification)
        XCTAssertEqual(intent.captureName, "Article.md")
        XCTAssertEqual(intent.captureDestinationPath, "For Reference")
        XCTAssertEqual(intent.tagIDs, ["t1"])
        XCTAssertEqual(records.first?.destinationName, "For Reference")
    }

    func testAnIdeaIsFiledByKindAndShownAsIdeas() throws {
        let records = queue.record(savedURL: inbox.appendingPathComponent("Idea.md"), destination: nil, kind: .idea)
        let intent = try XCTUnwrap(queue.outbox.queued().first)
        XCTAssertEqual(intent.captureKind, .idea)
        XCTAssertNil(intent.captureDestinationPath, "The Mac makes an idea its own folder; it is not a destination path")
        XCTAssertEqual(records.first?.destinationName, "Ideas")
        XCTAssertEqual(MobileCaptureQueue.savedMessage(count: 1, destination: nil, kind: .idea), "Added to Ideas")
        XCTAssertEqual(MobileCaptureQueue.savedMessage(count: 2, destination: reference), "Added 2 files to For Reference")
    }

    func testTypedTagNamesReuseExistingTagsAndQueueOnlyNewOnes() {
        let projects = Tag(id: "p", name: "Projects")
        queue.saveCatalog(MobileCaptureCatalog(tags: [projects], destinations: [reference]))
        let tags = queue.tags(named: ["project", "Brand New", " "])
        XCTAssertEqual(tags.first, projects, "“project” is the existing Projects")
        XCTAssertEqual(tags.map(\.name), ["Projects", "Brand New"])
        let creations = queue.outbox.queued().filter { $0.kind == .tagCreation }
        XCTAssertEqual(creations.compactMap(\.createdTag?.name), ["Brand New"])
        XCTAssertEqual(queue.catalog()?.tags.map(\.name), ["Brand New", "Projects"], "The next capture finds it")
        XCTAssertEqual(queue.tags(named: ["brand-new"]).first?.id, tags[1].id, "and does not create it twice")
    }

    func testAnEmptyCatalogNeverReplacesAKnownOne() {
        queue.saveCatalog(MobileCaptureCatalog(tags: [], destinations: [reference]))
        queue.saveCatalog(MobileCaptureCatalog(tags: [], destinations: []))
        XCTAssertEqual(queue.catalog()?.destinations, [reference])
    }

    func testTheAppsOwnHistoryAndOutboxMoveIntoTheGroupOnce() throws {
        let legacySuite = "MobileCaptureQueueTests.legacy.\(UUID().uuidString)"
        let legacy = try XCTUnwrap(UserDefaults(suiteName: legacySuite))
        defer { legacy.removePersistentDomain(forName: legacySuite) }
        let old = MobileCaptureQueue(defaults: legacy)
        old.record(savedURL: inbox.appendingPathComponent("Before.md"), destination: reference)

        MobileCaptureQueue.migrate(from: legacy, to: defaults)

        XCTAssertEqual(queue.log.load().map(\.name), ["Before.md"])
        XCTAssertEqual(queue.outbox.queued().count, 1, "A queued filing survives the move")
        XCTAssertNil(legacy.data(forKey: MobileCaptureQueue.logKey))
        XCTAssertNil(legacy.data(forKey: MobileCaptureQueue.outboxKey))
    }

    func testDestinationsAreTheTopLevelFoldersOnly() {
        let entries = [
            MobileWorkspaceEntry(path: "To Read", parentPath: nil, name: "To Read", isDirectory: true, revision: 1),
            MobileWorkspaceEntry(path: "For Reference", parentPath: nil, name: "For Reference", isDirectory: true, revision: 1),
            MobileWorkspaceEntry(path: "To Read/A.md", parentPath: "To Read", name: "A.md", isDirectory: false, revision: 1),
        ]
        XCTAssertEqual(MobileCaptureCatalog.destinations(from: entries).map(\.name), ["For Reference", "To Read"])
    }
}

extension MobileCaptureQueueTests {
    func testANewTagIsKeptEvenBeforeAnyCatalogArrives() {
        XCTAssertNil(queue.catalog())
        let tag = queue.tags(named: ["Gardening"]).first
        XCTAssertEqual(queue.catalog()?.tags.map(\.name), ["Gardening"])
        XCTAssertEqual(queue.tags(named: ["gardening"]).first?.id, tag?.id)
    }
}

/// A tag tapped on the phone stays shown across refreshes until the Mac's index has it.
final class PendingTagChangesTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func snapshot(tags: Set<String>) -> MobileWorkspaceSnapshot {
        MobileWorkspaceSnapshot(entries: [MobileWorkspaceEntry(path: "Ideas/Note.md", parentPath: "Ideas", name: "Note.md",
                                                               isDirectory: false, revision: 1, tagIDs: tags)])
    }

    func testARefreshThatPredatesTheMacKeepsTheTap() {
        var pending = PendingTagChanges()
        pending.record(tagID: "ai", onPath: "Ideas/Note.md", isPresent: true, now: now)
        var stale = snapshot(tags: [])
        pending.reconcile(&stale, now: now.addingTimeInterval(5))
        XCTAssertEqual(stale.entries[0].tagIDs, ["ai"], "Still checked while the Mac catches up")
        XCTAssertFalse(pending.isEmpty)
    }

    func testOnceTheMacAgreesTheChangeIsForgotten() {
        var pending = PendingTagChanges()
        pending.record(tagID: "ai", onPath: "Ideas/Note.md", isPresent: true, now: now)
        var caughtUp = snapshot(tags: ["ai"])
        pending.reconcile(&caughtUp, now: now.addingTimeInterval(5))
        XCTAssertTrue(pending.isEmpty)
        var removedOnMac = snapshot(tags: [])
        pending.reconcile(&removedOnMac, now: now.addingTimeInterval(10))
        XCTAssertEqual(removedOnMac.entries[0].tagIDs, [], "Later Mac changes are not overridden")
    }

    func testTheLatestTapWinsAndOldTapsExpire() {
        var pending = PendingTagChanges()
        pending.record(tagID: "ai", onPath: "Ideas/Note.md", isPresent: true, now: now)
        pending.record(tagID: "ai", onPath: "Ideas/Note.md", isPresent: false, now: now.addingTimeInterval(1))
        var tagged = snapshot(tags: ["ai"])
        pending.reconcile(&tagged, now: now.addingTimeInterval(2))
        XCTAssertEqual(tagged.entries[0].tagIDs, [], "The untick is what shows")
        var later = snapshot(tags: ["ai"])
        pending.reconcile(&later, now: now.addingTimeInterval(PendingTagChanges.lifetime + 10))
        XCTAssertEqual(later.entries[0].tagIDs, ["ai"], "An expired tap no longer overrides the Mac")
        XCTAssertTrue(pending.isEmpty)
    }
}

/// Optional links between work, and what a captured note becomes in a work queue.
final class WorkItemLinksTests: XCTestCase {
    private let root = URL(fileURLWithPath: "/tmp/Features", isDirectory: true)

    func testUnplacedFeaturesAndMilestonesNeedAttentionButTasksDoNot() {
        func item(_ kind: WorkItemKind, project: String? = nil, status: WorkItemStatus = .open) -> WorkItem {
            WorkItem(kind: kind, title: "x", status: status, projectPath: project, url: root.appendingPathComponent("x.bw.md"))
        }
        XCTAssertTrue(item(.feature).needsAttention)
        XCTAssertTrue(item(.milestone).needsAttention)
        XCTAssertFalse(item(.task).needsAttention, "A task is complete without a project")
        XCTAssertFalse(item(.feature, project: "Projects/A").needsAttention)
        XCTAssertFalse(item(.feature, status: .completed).needsAttention, "Finished work is not a to-do")
    }

    func testLinksAreTrimmedToWhatAKindCanHold() {
        let links = WorkItemLinks(projectPath: " Projects/A ", featureIDs: ["f"], milestoneIDs: ["m"])
        XCTAssertEqual(links.projectPath, "Projects/A")
        XCTAssertEqual(links.applicable(to: .task), links)
        XCTAssertEqual(links.applicable(to: .feature).featureIDs, [], "A feature does not belong to a feature")
        XCTAssertEqual(links.applicable(to: .milestone).milestoneIDs, [])
        XCTAssertNil(WorkItemLinks(projectPath: "  ").projectPath)
        XCTAssertEqual(WorkItemLinks.decode(links.encoded), links)
        XCTAssertNil(WorkItemLinks.none.encoded, "Nothing to carry is carried as nothing")
    }

    func testOnlyLooseTextNotesAreStranded() {
        XCTAssertTrue(StrandedQueueNotes.isStranded(root.appendingPathComponent("Idea.md")))
        XCTAssertTrue(StrandedQueueNotes.isStranded(root.appendingPathComponent("Idea.txt")))
        XCTAssertFalse(StrandedQueueNotes.isStranded(root.appendingPathComponent("Idea.bw.md")), "Already a work item")
        XCTAssertFalse(StrandedQueueNotes.isStranded(root.appendingPathComponent(".bw-save-1.tmp")))
        XCTAssertFalse(StrandedQueueNotes.isStranded(root.appendingPathComponent(".hidden.md")))
        XCTAssertFalse(StrandedQueueNotes.isStranded(root.appendingPathComponent("photo.png")))
    }

    func testAPromotedNoteKeepsItsTextWithoutRepeatingTheTitle() {
        XCTAssertEqual(WorkItemPromotion.body("# Bridge\n\nUse the Pi.", title: "Bridge"), "Use the Pi.")
        XCTAssertEqual(WorkItemPromotion.body("# Other\nText", title: "Bridge"), "# Other\nText")
        XCTAssertEqual(WorkItemPromotion.body("Make it so the raspberry pi is the bridge", title: "Make it so"),
                       "Make it so the raspberry pi is the bridge", "A first line that is not a heading stays")
    }

    func testPhoneCaptureLinksSurviveTheIntent() throws {
        let links = WorkItemLinks(projectPath: "Projects/A", featureIDs: ["f1"])
        let intent = MobileWorkspaceIntent.captureClassification(name: "n.md", kind: .feature, tagIDs: [], links: links)
        let decoded = try JSONDecoder().decode(MobileWorkspaceIntent.self, from: JSONEncoder().encode(intent))
        XCTAssertEqual(decoded.captureLinks, links)
        XCTAssertEqual(decoded.captureKind?.workItemKind, .feature)
        XCTAssertNil(MobileWorkspaceIntent.captureClassification(name: "n.md", kind: .task, tagIDs: [], links: .none).captureLinks)
    }
}
