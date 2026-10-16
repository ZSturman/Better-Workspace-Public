import XCTest
@testable import BetterWorkspaceCore

final class WorkspaceInboxReviewTests: XCTestCase {
    typealias Review = WorkspaceInboxReview
    private var root: URL!
    private var state: URL!

    override func setUpWithError() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("bw-review-\(UUID().uuidString)")
        root = base.appendingPathComponent("Workspace"); state = base.appendingPathComponent("State")
        for folder in Review.ReviewConfiguration.folderNames {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root.deletingLastPathComponent())
    }

    @discardableResult
    private func write(_ relative: String, _ text: String = "content") throws -> URL {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        return url
    }

    private func engine(choose: @escaping @Sendable ([Review.ReviewItem]) -> Review.ReviewItem? = { $0.first },
                        move: (@Sendable (URL, URL) throws -> Void)? = nil) throws -> Review.ReviewEngine {
        if let move {
            return try Review.ReviewEngine(configuration: .init(workspace: root), stateDirectory: state, chooseItem: choose, moveEffect: move)
        }
        return try Review.ReviewEngine(configuration: .init(workspace: root), stateDirectory: state, chooseItem: choose)
    }

    func testScanSkipsProtectedAutomationHiddenArchiveAndPartialFiles() async throws {
        for path in ["To Do/reminders.json", "To Study/flashcards.json", "To Read/.DS_Store", "To Watch/.hidden.md",
                     "To Watch/Archive/old.md", "To Look Up/movie.mp4.download", "To Check Out/partial.part",
                     "To Organize/.project-core/x", "To Organize/_audit/log"] {
            try write(path)
        }
        try write("To Do/Real task.md"); try write("To Study/Notes.md")
        let names = try await engine().snapshot().catalog.items.map(\.name).sorted()
        XCTAssertEqual(names, ["Notes.md", "Real task.md"])
    }

    func testSelectionRotatesFoldersAndSnoozeHidesUntilDue() async throws {
        try write("To Study/A.md"); try write("To Study/B.md"); try write("To Watch/C.md")
        let review = try engine()
        let now = Date()
        let first = try await review.selectNext(now: now)
        let second = try await review.selectNext(now: now)
        XCTAssertEqual(first?.category, "To Study")
        XCTAssertEqual(second?.category, "To Watch", "the next folder gets its turn before To Study repeats")
        let third = try await review.selectNext(now: now)
        XCTAssertEqual(third?.name, "B.md", "unseen items come before a repeat")

        let tomorrow = now.addingTimeInterval(86_400)
        for item in await review.snapshot().catalog.items { try await review.snooze(item, until: tomorrow) }
        let none = try await review.selectNext(now: now)
        XCTAssertNil(none)
        let due = try await review.selectNext(now: tomorrow)
        XCTAssertNotNil(due)
        // State is this engine's own and persists across a relaunch.
        let relaunched = try engine()
        let stillSnoozed = try await relaunched.selectNext(now: now)
        XCTAssertNil(stillSnoozed)
    }

    func testReviewPriorityPersistsAcrossRelaunchAndNeverOverridesSnooze() async throws {
        _ = try write("To Study/Ordinary.md")
        _ = try write("To Watch/Important.md")
        let review = try engine()
        let items = await review.snapshot().catalog.items
        let important = try XCTUnwrap(items.first { $0.name == "Important.md" })
        try await review.setPriority(5, for: important)
        let relaunched = try engine()
        let first = try await relaunched.selectNext()
        XCTAssertEqual(first?.id, important.id)
        try await relaunched.snooze(important, until: Date().addingTimeInterval(86_400))
        let ordinary = try await relaunched.selectNext()
        XCTAssertEqual(ordinary?.name, "Ordinary.md")
        let bytes = try String(contentsOf: important.url, encoding: .utf8)
        XCTAssertEqual(bytes, "content")
    }

    func testDoneMovesIntoReviewedAndRetryWithSameOperationIsIdempotent() async throws {
        let source = try write("To Watch/Talk.md", "https://example.com/talk")
        let review = try engine()
        let next = try await review.selectNext()
        let item = try XCTUnwrap(next)
        let fingerprint = try await review.fingerprint(item)
        let operation = UUID()
        let entry = try await review.perform(item, outcome: .done, expectedFingerprint: fingerprint, operationID: operation)
        let destination = root.appendingPathComponent("Reviewed/Done/To Watch/Talk.md")
        XCTAssertEqual(entry.destination?.lastPathComponent, "Talk.md")
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        // A phone retry after a lost receipt finds the committed entry and does nothing.
        let retried = try await review.perform(item, outcome: .done, expectedFingerprint: fingerprint, operationID: operation)
        XCTAssertEqual(retried.id, entry.id)

        _ = try await review.undo()
        XCTAssertEqual(try String(contentsOf: source, encoding: .utf8), "https://example.com/talk")
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testChangedFileIsRefusedAndNothingMoves() async throws {
        let source = try write("To Read/Article.md", "first")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("To Read"), withIntermediateDirectories: true)
        var configuration = Review.ReviewConfiguration(workspace: root)
        configuration.roots.append(Review.Paths.physical(root).appendingPathComponent("To Read"))
        let review = try Review.ReviewEngine(configuration: configuration, stateDirectory: state)
        let next = try await review.selectNext()
        let item = try XCTUnwrap(next)
        XCTAssertEqual(item.category, "To Read")
        let fingerprint = try await review.fingerprint(item)
        try Data("second, longer".utf8).write(to: source)
        do {
            _ = try await review.perform(item, outcome: .archive, expectedFingerprint: fingerprint)
            XCTFail("a changed file must not move")
        } catch {}
        XCTAssertEqual(try String(contentsOf: source, encoding: .utf8), "second, longer")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Reviewed").path))
    }

    func testCompletingABetterWorkspaceTaskRewritesOnlyItsStatusAndUndoRestoresBytes() async throws {
        let original = "---\nbetter-workspace: 1\nkind: task\nstatus: open\ntitle: Call\n---\nBody\n"
        let source = try write("To Do/Call.bw.md", original)
        let review = try engine()
        let next = try await review.selectNext()
        let item = try XCTUnwrap(next)
        let fingerprint = try await review.fingerprint(item)
        let entry = try await review.perform(item, outcome: .done, expectedFingerprint: fingerprint)
        let moved = try String(contentsOf: XCTUnwrap(entry.destination), encoding: .utf8)
        XCTAssertTrue(moved.contains("status: completed")); XCTAssertTrue(moved.contains("completed: "))
        XCTAssertTrue(moved.hasSuffix("---\nBody\n"))
        _ = try await review.undo()
        XCTAssertEqual(try String(contentsOf: source, encoding: .utf8), original)
    }

    func testTrashIsRecoverableAndUndoRefusesAnOccupiedOriginal() async throws {
        let source = try write("To Organize/Scan.pdf", "pdf")
        let bin = root.deletingLastPathComponent().appendingPathComponent("Trash")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let review = try engine()
        let next = try await review.selectNext()
        let item = try XCTUnwrap(next)
        let fingerprint = try await review.fingerprint(item)
        let entry = try await review.perform(item, outcome: .trash, expectedFingerprint: fingerprint, trash: { url in
            let to = bin.appendingPathComponent(url.lastPathComponent)
            try Review.Filesystem.move(url, to: to); return to
        })
        XCTAssertEqual(entry.destination?.deletingLastPathComponent().lastPathComponent, "Trash")
        try write("To Organize/Scan.pdf", "someone else")
        do { _ = try await review.undo(); XCTFail("undo must not overwrite") } catch {}
        XCTAssertEqual(try String(contentsOf: source, encoding: .utf8), "someone else")
        XCTAssertTrue(FileManager.default.fileExists(atPath: bin.appendingPathComponent("Scan.pdf").path))
    }

    func testMoveToChosenFolderAndRefuseDestinationInsideTheItem() async throws {
        try FileManager.default.createDirectory(at: root.appendingPathComponent("To Organize/Bundle"), withIntermediateDirectories: true)
        try write("To Organize/Bundle/inside.txt")
        let target = root.appendingPathComponent("Projects/Home")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let review = try engine()
        let next = try await review.selectNext()
        let item = try XCTUnwrap(next)
        let fingerprint = try await review.fingerprint(item)
        do {
            _ = try await review.perform(item, outcome: .move, expectedFingerprint: fingerprint,
                                         destinationDirectory: item.url)
            XCTFail("cannot move into itself")
        } catch {}
        _ = try await review.perform(item, outcome: .move, expectedFingerprint: fingerprint, destinationDirectory: target)
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.appendingPathComponent("Bundle/inside.txt").path))
    }

    func testAnInterruptedMoveIsRecoveredOnLaunchAndBlocksFurtherActionsOtherwise() async throws {
        let source = try write("To Look Up/Term.md", "term")
        struct Crash: Error {}
        let crashing = try engine(move: { _, _ in throw Crash() })
        let next = try await crashing.selectNext()
        let item = try XCTUnwrap(next)
        let fingerprint = try await crashing.fingerprint(item)
        do { _ = try await crashing.perform(item, outcome: .archive, expectedFingerprint: fingerprint); XCTFail() } catch {}
        // The failed move left the source untouched and the entry reconciled as failed.
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        let history = await crashing.history()
        XCTAssertEqual(history.first?.status, "failed")
        let snapshot = await crashing.snapshot()
        XCTAssertFalse(snapshot.undoAvailable)
        XCTAssertTrue(snapshot.recoveryWarnings.isEmpty)
    }

    func testStateLivesOnlyInTheGivenDirectory() async throws {
        try write("To Study/A.md")
        let review = try engine()
        _ = try await review.selectNext()
        let files = try FileManager.default.contentsOfDirectory(atPath: state.path).sorted()
        XCTAssertEqual(files, ["configuration.json", "state.json"])
        let permissions = try FileManager.default.attributesOfItem(atPath: state.path)[.posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o700)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("To Study").path), ["A.md"],
                       "nothing is written beside the user's files")
    }
}
