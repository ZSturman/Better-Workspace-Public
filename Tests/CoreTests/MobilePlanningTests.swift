import XCTest
@testable import BetterWorkspaceCore

final class MobilePlanningTests: XCTestCase {
    private func withWorkspace(_ body: (WorkspaceLocation) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bw-planning-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for area in ["Ideas", "Projects"] { try FileManager.default.createDirectory(at: root.appendingPathComponent(area), withIntermediateDirectories: false) }
        try body(WorkspaceLocation(root: root))
    }
    func testTrustBoundaryRejectsTraversalForeignMetadataAndEscapingSymlinks() throws {
        try withWorkspace { workspace in
            for path in ["Ideas/../secret", ".project-core/index", "_audit/log", "Ideas/watcher.item.toml", "Ideas/Project.betterproject"] {
                XCTAssertThrowsError(try MobilePlanningFiles.resolve(path, workspace: workspace), path)
            }
            let link = workspace.root.appendingPathComponent("Ideas/Escape")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: workspace.root.deletingLastPathComponent())
            XCTAssertThrowsError(try MobilePlanningFiles.resolve("Ideas/Escape/file.md", workspace: workspace))
        }
    }
    func testIdeaCreationIsRetryableWithoutOverwritingOrClaimingAnExistingIdea() throws {
        try withWorkspace { workspace in
            let edit = MobilePlanningEdit(operation: .createIdea, title: "Original thought", description: "The detail.")
            let first = try MobilePlanningFiles.createIdea(edit, workspace: workspace)
            XCTAssertEqual(first, try MobilePlanningFiles.createIdea(edit, workspace: workspace))
            let text = try String(contentsOf: first, encoding: .utf8)
            let parts = MobilePlanningFiles.splitIdeaText(text, fallbackTitle: "Fallback")
            XCTAssertEqual(parts.0, edit.title); XCTAssertEqual(parts.1, edit.description)
            try "Someone else's edit".write(to: first, atomically: true, encoding: .utf8)
            XCTAssertThrowsError(try MobilePlanningFiles.createIdea(edit, workspace: workspace))
            XCTAssertEqual(try String(contentsOf: first, encoding: .utf8), "Someone else's edit")
        }
    }
    func testProjectCreationPreservesExistingProjectAndRetriesSameDirectory() throws {
        try withWorkspace { workspace in
            let original = workspace.root.appendingPathComponent("Projects/Existing")
            try FileManager.default.createDirectory(at: original, withIntermediateDirectories: false)
            let edit = MobilePlanningEdit(operation: .createProject, title: "Existing", description: "Plan")
            let created = try MobilePlanningFiles.createProject(edit, workspace: workspace)
            XCTAssertNotEqual(created.canonicalPath, original.canonicalPath)
            XCTAssertEqual(created.canonicalPath, try MobilePlanningFiles.createProject(edit, workspace: workspace).canonicalPath)
            XCTAssertTrue(FileManager.default.fileExists(atPath: original.path))
        }
    }
    func testWorkUpdateComparesEditableFieldsAndDescription() {
        var file = WorkItem(id: "w", kind: .feature, title: "Plan", stage: .next, projectPath: "Projects/P", body: "Original", url: URL(fileURLWithPath: "/unused"))
        let original = MobileWorkItem(id: "w", path: "Projects/P/Plan.bw.md", title: "Plan", kind: .feature, status: .open,
            stage: .next, priority: .medium, projectPath: "Projects/P", revision: 1, body: "Original")
        XCTAssertTrue(MobilePlanningFiles.matches(file, original: original))
        file.body = "Changed elsewhere"
        XCTAssertFalse(MobilePlanningFiles.matches(file, original: original))
        file.body = "Original"; file.stage = .now
        XCTAssertFalse(MobilePlanningFiles.matches(file, original: original))
    }
    func testPortableRoundtripDoesNotTurnAQueuedSaveIntoAFalseConflict() throws {
        try withWorkspace { workspace in
            let due = Date(timeIntervalSince1970: 1_700_000_000.75)
            let service = WorkItemService()
            let folder = workspace.root.appendingPathComponent("Projects/P/Work")
            let draft = WorkItem(id: "roundtrip", kind: .task, title: "Plan", projectPath: workspace.root.appendingPathComponent("Projects/P").canonicalPath,
                                 dueDate: due, body: "\nOriginal\n", url: folder.appendingPathComponent("unused"))
            let saved = try service.create(draft, in: folder)
            let original = MobileWorkItem(id: draft.id, path: "Projects/P/Work/Plan.bw.md", title: draft.title, kind: draft.kind,
                status: draft.status, stage: draft.stage, priority: draft.priority, projectPath: "Projects/P", dueDate: due, revision: 1, body: draft.body)
            XCTAssertTrue(MobilePlanningFiles.matches(saved, original: original, workspace: workspace))
        }
    }
    func testOldProjectionsDecodeAndDraftsSurviveRelaunch() throws {
        let workJSON = #"{"id":"w","path":"To Do/Work.bw.md","title":"Work","kind":"task","status":"open","stage":"next","priority":"medium","revision":1,"tagIDs":[]}"#
        let work = try JSONDecoder().decode(MobileWorkItem.self, from: Data(workJSON.utf8))
        XCTAssertNil(work.body)
        let ideaJSON = #"{"path":"Ideas/Thought.md","title":"Thought","revision":1,"tagIDs":[]}"#
        let idea = try JSONDecoder().decode(MobileIdea.self, from: Data(ideaJSON.utf8))
        XCTAssertNil(idea.description); XCTAssertNil(idea.attachments)
        let suite = "bw-planning-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let edit = MobilePlanningEdit(operation: .saveWork, title: work.title, work: work, originalWork: work)
        MobilePlanningDraftStore(defaults: defaults).save([edit])
        XCTAssertEqual(MobilePlanningDraftStore(defaults: defaults).load(), [edit])
        let roundtrip = try JSONDecoder().decode(MobileWorkspaceIntent.self, from: JSONEncoder().encode(MobileWorkspaceIntent.planning(edit)))
        XCTAssertEqual(roundtrip.planningEdit, edit)
    }

    private func mobile(_ item: WorkItem, path: String) -> MobileWorkItem {
        MobileWorkItem(id: item.id, path: path, title: item.title, kind: item.kind, status: item.status,
            stage: item.stage, priority: item.priority, projectPath: "Projects/P", dueDate: item.dueDate, revision: 1, body: item.body)
    }
    private func makeWork(in workspace: WorkspaceLocation, id: String = UUID().uuidString) throws -> WorkItem {
        let folder = workspace.root.appendingPathComponent("Projects/P/Work")
        let draft = WorkItem(id: id, kind: .task, title: "Phone task", projectPath: workspace.root.appendingPathComponent("Projects/P").canonicalPath,
                             body: "Detail", url: folder.appendingPathComponent("unused"))
        return try WorkItemService().create(draft, in: folder)
    }
    func testPhoneDeleteMovesTheRecordToTheTrashAndIsSafeToRetry() throws {
        try withWorkspace { workspace in
            let service = WorkItemService()
            let saved = try makeWork(in: workspace)
            let trash = workspace.root.deletingLastPathComponent().appendingPathComponent("bw-trash-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: trash) }
            let original = mobile(saved, path: "Projects/P/Work/" + saved.url.lastPathComponent)
            let edit = MobilePlanningEdit(operation: .trashWork, title: saved.title, originalWork: original)
            let trashed = try MobilePlanningFiles.trashWork(edit, among: [saved], workspace: workspace, service: service, into: trash)
            XCTAssertEqual(trashed?.id, saved.id)
            XCTAssertFalse(FileManager.default.fileExists(atPath: saved.url.path), "The record leaves the Workspace")
            let recovered = try FileManager.default.contentsOfDirectory(atPath: trash.path)
            XCTAssertEqual(recovered.count, 1, "and is recoverable from the Trash, never unlinked")
            // A retry after a lost receipt finds nothing to do rather than failing.
            XCTAssertNil(try MobilePlanningFiles.trashWork(edit, among: [], workspace: workspace, service: service, into: trash))
        }
    }
    func testPhoneDeleteRefusesARecordChangedOnTheMac() throws {
        try withWorkspace { workspace in
            let service = WorkItemService()
            var saved = try makeWork(in: workspace)
            let original = mobile(saved, path: "Projects/P/Work/" + saved.url.lastPathComponent)
            saved.title = "Renamed on the Mac"
            saved = try service.update(saved)
            let edit = MobilePlanningEdit(operation: .trashWork, title: original.title, originalWork: original)
            XCTAssertThrowsError(try MobilePlanningFiles.trashWork(edit, among: [saved], workspace: workspace, service: service,
                                                                   into: workspace.root.appendingPathComponent("unused-trash")))
            XCTAssertTrue(FileManager.default.fileExists(atPath: saved.url.path), "A changed record is never deleted")
        }
    }
    func testAnEditToAPhoneCreatedTaskFindsItByIdentityAfterItLandsInItsProject() throws {
        try withWorkspace { workspace in
            let service = WorkItemService()
            let saved = try makeWork(in: workspace)
            // The phone showed its own placeholder path for the new task; the Mac filed it
            // in the project's Work folder. The follow-up edit still names the placeholder.
            let original = mobile(saved, path: "To Do/\(saved.id).bw.md")
            let located = try MobilePlanningFiles.locateWork(original, among: [saved], workspace: workspace, service: service)
            XCTAssertEqual(located?.url.canonicalPath, saved.url.canonicalPath)
            XCTAssertTrue(MobilePlanningFiles.matches(try XCTUnwrap(located), original: original, workspace: workspace))
            XCTAssertNil(try MobilePlanningFiles.locateWork(original, among: [], workspace: workspace, service: service))
        }
    }
    func testTrashEditsSurviveTheIntentRoundtrip() throws {
        let work = MobileWorkItem(id: "w", path: "To Do/W.bw.md", title: "W", kind: .task, status: .open,
            stage: .next, priority: .medium, revision: 1)
        let edit = MobilePlanningEdit(operation: .trashWork, title: "W", originalWork: work)
        let decoded = try JSONDecoder().decode(MobileWorkspaceIntent.self, from: JSONEncoder().encode(MobileWorkspaceIntent.planning(edit)))
        XCTAssertEqual(decoded.planningEdit, edit)
        XCTAssertNoThrow(try MobilePlanningFiles.validate(edit))
    }
    func testProgressCountsSplitOpenWorkByStageAndCountCompletedSeparately() {
        func item(_ status: WorkItemStatus, _ stage: WorkItemStage) -> MobileWorkItem {
            MobileWorkItem(id: UUID().uuidString, path: "p", title: "t", kind: .task, status: status, stage: stage, priority: .medium, revision: 1)
        }
        let counts = WorkProgressCounts([item(.open, .now), item(.inProgress, .now), item(.completed, .now),
                                         item(.open, .later), item(.completed, .next)])
        XCTAssertEqual(counts, WorkProgressCounts(now: 2, next: 0, later: 1, completed: 2), "Completed work is not open work")
        XCTAssertEqual(counts.open, 3)
        XCTAssertEqual(counts.fractionDone, 0.4, accuracy: 0.0001)
        XCTAssertEqual(WorkProgressCounts([MobileWorkItem]()).fractionDone, 0, "No work is not 100% done")
    }
    func testWeeklyCountsKeepEmptyWeeksAndIgnoreDatesOutsideTheWindow() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let day: TimeInterval = 86_400
        let weekly = WeeklyCounts(dates: [now, now - day * 0.5, now - day * 14, now - day * 400], weeks: 4, now: now, calendar: calendar)
        XCTAssertEqual(weekly.weeks.count, 4)
        XCTAssertEqual(weekly.total, 3, "A date a year ago is outside the window")
        XCTAssertEqual(weekly.weeks.map(\.count).filter { $0 == 0 }.count, 2, "Quiet weeks are present as zero")
        XCTAssertEqual(weekly.weeks.map(\.start), weekly.weeks.map(\.start).sorted(), "Oldest first")
    }
    func testAnAppliedEditIsSettledOnlyOnceTheDownloadedIndexShowsIt() {
        let original = MobileWorkItem(id: "w", path: "To Do/W.bw.md", title: "W", kind: .task, status: .open,
            stage: .next, priority: .medium, revision: 1)
        var completed = original; completed.status = .completed
        let edit = MobilePlanningEdit(operation: .saveWork, title: "W", work: completed, originalWork: original)
        // CloudKit queries lag: the receipt can arrive while the index still has the original.
        XCTAssertFalse(MobilePlanningFiles.index(MobileWorkspaceSnapshot(workItems: [original]), reflects: edit))
        XCTAssertTrue(MobilePlanningFiles.index(MobileWorkspaceSnapshot(workItems: [completed]), reflects: edit))
        var reopened = completed; reopened.status = .open; reopened.title = "W again"
        XCTAssertTrue(MobilePlanningFiles.index(MobileWorkspaceSnapshot(workItems: [reopened]), reflects: edit),
                      "A later edit has overtaken this one; the index has caught up past it")
        XCTAssertTrue(MobilePlanningFiles.index(MobileWorkspaceSnapshot(), reflects: edit),
                      "An applied update to a record deleted since must not bring it back")
        let trash = MobilePlanningEdit(operation: .trashWork, title: "W", originalWork: original)
        XCTAssertFalse(MobilePlanningFiles.index(MobileWorkspaceSnapshot(workItems: [original]), reflects: trash))
        XCTAssertTrue(MobilePlanningFiles.index(MobileWorkspaceSnapshot(), reflects: trash))
        let created = MobilePlanningEdit(id: UUID(), operation: .saveWork, title: "New",
            work: MobileWorkItem(id: "n", path: "To Do/n.bw.md", title: "New", kind: .task, status: .open, stage: .next, priority: .medium, revision: 0))
        XCTAssertFalse(MobilePlanningFiles.index(MobileWorkspaceSnapshot(), reflects: created))
    }
}
