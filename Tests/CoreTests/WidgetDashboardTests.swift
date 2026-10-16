import XCTest
@testable import BetterWorkspaceCore

final class WidgetDashboardTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func work(_ id: String, status: WorkItemStatus = .open, stage: WorkItemStage = .next,
                      due: Date? = nil, deps: [String] = []) -> MobileWorkItem {
        MobileWorkItem(id: id, path: "Projects/A/Work/\(id).bw.md", title: id, kind: .task, status: status,
            stage: stage, priority: .medium, projectPath: "Projects/A", dueDate: due, revision: 1, body: "Preserved notes", dependencyIDs: deps)
    }
    private func source(_ work: [MobileWorkItem], score: Double? = nil, coverage: Double? = nil) -> MobileWorkspaceSnapshot {
        MobileWorkspaceSnapshot(entries: [.init(path: "Projects/A", parentPath: "Projects", name: "Project A", isDirectory: true, revision: 1,
            projectDetails: .init(path: "Projects/A", projectID: "stable-a", serviceID: "legacy-a", manualScore: score, ratingCoverage: coverage))],
            workItems: work, fetchedAt: now)
    }
    func testCountsOnlyLinkedTasksAndKeepsUnratedProjectUnknown() {
        let snapshot = WorkspaceDashboardSnapshot.make(from: source([work("open"), work("done", status: .completed)]))
        XCTAssertEqual(snapshot.projects.first?.focus.total, 2)
        XCTAssertEqual(snapshot.projects.first?.focus.completed, 1)
        XCTAssertNil(snapshot.projects.first?.focus.score)
        XCTAssertNil(snapshot.work.first?.body)
        XCTAssertEqual(snapshot.project(id: "legacy-a")?.id, "stable-a")
        XCTAssertNil(snapshot.project(id: "missing"), "A missing pin must never select a different project")
    }
    func testRatingCoverageAndUnknownProgress() {
        XCTAssertNil(WorkspaceDashboardSnapshot.make(from: source([], score: 80, coverage: 0.49)).projects.first?.focus.score)
        XCTAssertEqual(WorkspaceDashboardSnapshot.make(from: source([], score: 80, coverage: 0.5)).projects.first?.focus.score, 80)
        XCTAssertEqual(WorkspaceDashboardSnapshot.make(from: source([])).projects.first?.focus.total, 0)
    }
    func testNextQueueExcludesLaterAndDependenciesResolveAgainstWholeUniverse() {
        let snapshot = WorkspaceDashboardSnapshot.make(from: source([
            work("later", stage: .later), work("blocked", deps: ["unknown"]), work("ready", deps: ["done"]), work("done", status: .completed)
        ]))
        XCTAssertEqual(snapshot.tasks(queue: .next, projectID: "stable-a").map(\.id), ["ready"])
        XCTAssertTrue(snapshot.tasks(queue: .next, projectID: "missing").isEmpty)
    }
    func testOverdueAndAttentionRemainExplainable() {
        let snapshot = WorkspaceDashboardSnapshot.make(from: source([work("late", due: now.addingTimeInterval(-86400)), work("blocked", deps: ["unknown"])]))
        XCTAssertEqual(snapshot.tasks(queue: .overdue, now: now).map(\.id), ["late"])
        XCTAssertEqual(snapshot.attentionItems(now: now).map(\.category), [.overdue, .blocked])
        XCTAssertTrue(snapshot.attentionItems(now: now).allSatisfy { !$0.reason.isEmpty })
    }
    func testLegacyDigestAndProjectDetailsStillDecode() throws {
        let digest = try JSONDecoder().decode(OverviewDigest.self, from: Data("{\"focusItems\":[]}".utf8))
        XCTAssertNil(digest.reviewItems)
        let details = try JSONDecoder().decode(MobileProjectDetails.self, from: Data("{\"path\":\"Projects/A\"}".utf8))
        XCTAssertNil(details.projectID)
        XCTAssertNil(details.ratingCoverage)
    }
    func testReviewQueueIsBoundedAndRouteRoundTripsSpecialCharacters() {
        let candidates = (0..<20).map { OverviewInboxItem(id: "\($0)", path: "To Read/\($0).md", title: "\($0)", category: "To Read", modified: now, size: 1) }
        XCTAssertEqual(OverviewDigest(reviewItems: candidates).reviewItems?.count, 8)
        let encoded = "{\"focusItems\":[],\"reviewItems\":" + String(data: try! JSONEncoder().encode(candidates), encoding: .utf8)! + "}"
        XCTAssertEqual(try? JSONDecoder().decode(OverviewDigest.self, from: Data(encoded.utf8)).reviewItems?.count, 8)
        for route in [WidgetRoute.project("UUID"), .task("task/id"), .idea("Ideas/A & B #1.md"), .capture("A + B.md"), .review("file:id")] {
            XCTAssertEqual(WidgetRoute(url: route.url(mobile: true)), route)
            XCTAssertEqual(WidgetRoute(url: route.url(mobile: false)), route)
        }
        XCTAssertNil(WidgetRoute(url: URL(string: "https://example.com/task?id=1")!))
    }
}
