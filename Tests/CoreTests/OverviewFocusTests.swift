import XCTest
@testable import BetterWorkspaceCore

final class OverviewFocusTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func item(_ id: String, kind: OverviewContent = .projects, score: Double? = nil, done: Int = 0, of total: Int = 0,
                      worked: Double? = nil, changed: Double? = nil, terminal: Bool = false, blocked: Bool = false) -> OverviewFocusItem {
        OverviewFocusItem(id: id, path: "Projects/\(id)", title: id, kind: kind, score: score, completed: done, total: total,
                          lastWorked: worked.map { now.addingTimeInterval(-$0 * 86_400) },
                          lastChanged: changed.map { now.addingTimeInterval(-$0 * 86_400) }, terminal: terminal, blocked: blocked)
    }

    func testAlmostDoneNeedsStartedUnfinishedUnblockedWorkAndRanksByFraction() {
        let items = [item("Half", done: 2, of: 4), item("Nearly", done: 9, of: 10), item("Untouched", done: 0, of: 3),
                     item("Finished", done: 3, of: 3), item("Stuck", done: 4, of: 5, blocked: true),
                     item("Closed", done: 4, of: 5, terminal: true), item("Close", done: 3, of: 4)]
        XCTAssertEqual(OverviewRanking.items(items, kind: .projects, focus: .almostDone).map(\.id), ["Nearly", "Close", "Half"])
    }

    func testHighestRatedIgnoresUnscoredAndOtherKinds() {
        let items = [item("Low", score: 40), item("High", score: 91), item("None"), item("Idea", kind: .ideas, score: 99),
                     item("Done", score: 100, terminal: true)]
        XCTAssertEqual(OverviewRanking.items(items, kind: .projects, focus: .highestRated).map(\.id), ["High", "Low"])
    }

    func testRevisitPrefersRecordedWorkAndNeverTreatsUnknownAsStale() {
        let items = [item("Recent", worked: 2), item("Old", worked: 40, changed: 1), item("Files", changed: 20), item("Unknown")]
        let ranked = OverviewRanking.items(items, kind: .projects, focus: .revisit)
        XCTAssertEqual(ranked.map(\.id), ["Old", "Files", "Recent"])
        XCTAssertEqual(ranked[0].reason(.revisit, now: now), "Worked on 40 days ago")
        XCTAssertEqual(ranked[1].reason(.revisit, now: now), "Files changed 20 days ago")
        XCTAssertEqual(item("Today", changed: 0).reason(.revisit, now: now), "Files changed today")
    }

    func testDigestRoundTripsAndIsStableForThePublisher() throws {
        let inbox = OverviewInboxItem(id: "1:2", path: "To Read/Article.md", title: "Article.md", category: "To Read",
                                      modified: Date(timeIntervalSince1970: 1_700_000_000.123456789), size: 12,
                                      preview: "Body", link: URL(string: "https://example.com"))
        let digest = OverviewDigest(focusItems: [item("A", score: 50)], inboxItem: inbox, inboxCheckedAt: now)
        let encoded = try XCTUnwrap(digest.encoded)
        XCTAssertEqual(OverviewDigest.decode(encoded), digest)
        XCTAssertEqual(digest.encoded, encoded)
        // The Mac compares modification dates exactly before acting on a phone decision.
        XCTAssertEqual(OverviewDigest.decode(encoded)?.inboxItem?.modified, inbox.modified)
        XCTAssertNil(OverviewDigest.decode("not json"))
    }

    func testSnapshotLiftsTheDigestOutOfBrowsableEntries() {
        let digest = OverviewDigest(focusItems: [item("A")])
        let snapshot = MobileWorkspaceSnapshot(entries: [
            MobileWorkspaceEntry(path: "Projects", parentPath: nil, name: "Projects", isDirectory: true, revision: 1),
            MobileWorkspaceEntry(path: OverviewDigest.path, parentPath: nil, name: "Overview focus", isDirectory: false, revision: 0, overview: digest)
        ])
        XCTAssertEqual(snapshot.entries.map(\.path), ["Projects"])
        XCTAssertEqual(snapshot.overview, digest)
    }

    func testInboxDecisionValidationKeepsMacOnlyOperationsOnTheMac() {
        let item = OverviewInboxItem(id: "1:2", path: "To Study/Notes.md", title: "Notes.md", category: "To Study",
                                     modified: now, size: 10)
        XCTAssertNoThrow(try MobilePlanningFiles.validate(review(item, .done)))
        XCTAssertNoThrow(try MobilePlanningFiles.validate(review(item, .snooze, until: now)))
        XCTAssertThrowsError(try MobilePlanningFiles.validate(review(item, .snooze)), "a snooze needs an end")
        var organize = item; organize.category = "To Organize"; organize.path = "To Organize/Notes.md"
        XCTAssertThrowsError(try MobilePlanningFiles.validate(review(organize, .archive)), "To Organize needs Move/Trash on Mac")
        var escaping = item; escaping.path = "To Study/../Projects/x"
        XCTAssertThrowsError(try MobilePlanningFiles.validate(review(escaping, .done)))
        XCTAssertThrowsError(try MobilePlanningFiles.validate(MobilePlanningEdit(operation: .reviewInbox, title: "Missing")))
    }

    func testPendingDecisionSurvivesRelaunchAndSettlesOnlyWhenTheDigestMovesOn() throws {
        let item = OverviewInboxItem(id: "1:2", path: "To Watch/Talk.webloc", title: "Talk.webloc", category: "To Watch",
                                     modified: now, size: 10, link: URL(string: "https://example.com/talk"))
        let edit = review(item, .archive)
        let restored = try JSONDecoder().decode(MobilePlanningEdit.self, from: JSONEncoder().encode(edit))
        XCTAssertEqual(restored, edit)

        // CloudKit lag: an older digest still offers the same item, so the draft stays.
        XCTAssertFalse(MobilePlanningFiles.index(MobileWorkspaceSnapshot(overview: OverviewDigest(inboxItem: item)), reflects: edit))
        var next = item; next.id = "1:3"
        XCTAssertTrue(MobilePlanningFiles.index(MobileWorkspaceSnapshot(overview: OverviewDigest(inboxItem: next)), reflects: edit))
        XCTAssertTrue(MobilePlanningFiles.index(MobileWorkspaceSnapshot(overview: OverviewDigest()), reflects: edit))
    }

    func testPrimaryDecisionFollowsTheFolder() {
        XCTAssertEqual(WorkspaceInboxReview.ReviewActions(category: "To Study").title, "Studied?")
        XCTAssertEqual(WorkspaceInboxReview.ReviewActions(category: "To Watch").title, "Watched?")
        XCTAssertEqual(WorkspaceInboxReview.ReviewActions(category: "To Look Up").title, "Looked up?")
        XCTAssertEqual(WorkspaceInboxReview.ReviewActions(category: "To Do").title, "Complete?")
        XCTAssertEqual(WorkspaceInboxReview.ReviewActions(category: "To Check Out").title, "Checked out?")
        XCTAssertEqual(WorkspaceInboxReview.ReviewActions(category: "To Read").title, "Read?")
        let organize = WorkspaceInboxReview.ReviewActions(category: "To Organize")
        XCTAssertEqual(organize.primary, .move); XCTAssertTrue(organize.showsDelete)
        for category in ["To Study", "To Watch", "To Look Up", "To Do", "To Check Out", "To Read", "To Organize"] {
            let item = OverviewInboxItem(id: "", path: "", title: "", category: category, modified: now, size: 0)
            XCTAssertEqual(item.decision, WorkspaceInboxReview.ReviewActions(category: category).title, category)
        }
    }

    private func review(_ item: OverviewInboxItem, _ action: OverviewInboxCommand.Action, until: Date? = nil) -> MobilePlanningEdit {
        MobilePlanningEdit(operation: .reviewInbox, title: item.title, inboxReview: OverviewInboxCommand(item: item, action: action, until: until))
    }
}
