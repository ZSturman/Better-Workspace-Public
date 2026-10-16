import XCTest
@testable import BetterWorkspaceCore

/// The numbers behind Projects → Insights, the recent-folders row, and moving a task
/// to the Trash from the Next Action card.
final class ProjectProgressTests: XCTestCase {
    private var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()
    // A Wednesday.
    private let now = ISO8601DateFormatter().date(from: "2026-10-07T12:00:00Z")!

    private func day(_ offset: Int) -> Date { calendar.date(byAdding: .day, value: offset, to: now)! }

    private func item(created: Int, completed: Int? = nil) -> WorkItem {
        WorkItem(kind: .task, title: "T", status: completed == nil ? .open : .completed,
                 completedAt: completed.map(day), url: URL(fileURLWithPath: "/tmp/t.bw.md"),
                 createdAt: day(created))
    }

    func testWeeklyHistoryCountsOpenCompletedAndCreated() {
        let items = [item(created: -30), item(created: -20, completed: -10), item(created: -2, completed: -1),
                     item(created: -1)]
        let progress = ProjectProgress.make(items, now: now, weeks: 6, calendar: calendar)
        XCTAssertEqual(progress.weeks.count, 6)
        XCTAssertEqual(progress.open, 2)
        XCTAssertEqual(progress.completed, 2)
        let thisWeek = progress.weeks.last!
        XCTAssertEqual(thisWeek.created, 2)
        XCTAssertEqual(thisWeek.completed, 1)
        XCTAssertEqual(thisWeek.open, 2, "Open at the end of the week: the -30 item and the -1 item")
        XCTAssertEqual(progress.weeks.map(\.completed).reduce(0, +), 2)
    }

    func testForecastFollowsTheRecentCompletionRate() throws {
        // Six completions spread over the last six weeks: one a week; three open.
        var items = (0..<6).map { item(created: -60, completed: -$0 * 7) }
        items += (0..<3).map { _ in item(created: -5) }
        let progress = ProjectProgress.make(items, now: now, weeks: 12, rateWindow: 6, calendar: calendar)
        let forecast = try XCTUnwrap(progress.forecast)
        XCTAssertEqual(forecast.remaining, 3)
        XCTAssertEqual(forecast.weeklyRate, 1, accuracy: 0.01)
        XCTAssertEqual(calendar.dateComponents([.day], from: now, to: forecast.finish).day, 21)
    }

    func testNoRecentCompletionsMeansNoForecast() {
        let progress = ProjectProgress.make([item(created: -90, completed: -80), item(created: -3)],
                                            now: now, weeks: 12, rateWindow: 6, calendar: calendar)
        XCTAssertNil(progress.forecast, "A zero rate predicts nothing honest")
        XCTAssertNil(ProjectProgress.make([item(created: -3, completed: -1)], now: now, calendar: calendar).forecast,
                     "Nothing open, nothing to forecast")
    }
}

final class RecentDestinationsTests: XCTestCase {
    private var suite: String!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        suite = "RecentDestinationsTests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    }

    override func tearDown() { defaults.removePersistentDomain(forName: suite) }

    func testRecentlyUsedFoldersLeadThenTheStableOrderFillsIn() {
        let ordered = ["Projects", "Ideas", "To Do", "For Reference", "To Read", "To Watch", "Assets"]
        let recent = RecentDestinations(defaults: defaults)
        XCTAssertEqual(recent.leading(ordered, limit: 3, name: { $0 }), ["Projects", "Ideas", "To Do"],
                       "A new install shows the usual top folders")
        recent.record("To Watch")
        recent.record("For Reference")
        recent.record("To Watch")
        XCTAssertEqual(recent.names, ["To Watch", "For Reference"], "Most recent first, no duplicates")
        XCTAssertEqual(recent.leading(ordered, limit: 4, name: { $0 }), ["To Watch", "For Reference", "Projects", "Ideas"])
        XCTAssertEqual(recent.leading(["Ideas", "Assets"], limit: 3, name: { $0 }), ["Ideas", "Assets"],
                       "A remembered folder that no longer exists is skipped")
    }

    func testOnlyTheLastFewAreRemembered() {
        let recent = RecentDestinations(defaults: defaults)
        for index in 0..<20 { recent.record("Folder \(index)") }
        XCTAssertEqual(recent.names.count, RecentDestinations.remembered)
        XCTAssertEqual(recent.names.first, "Folder 19")
    }
}

final class WorkItemTrashTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("bw-trash-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("To Do"), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    func testTrashMovesTheRecordAndRefusesOneChangedOnDisk() throws {
        let service = WorkItemService()
        let created = try service.create(WorkItem(kind: .task, title: "Throw away", url: root.appendingPathComponent("x")),
                                         in: root.appendingPathComponent("To Do"))
        let trash = root.appendingPathComponent("Trash")
        let moved = try XCTUnwrap(try service.trash(created, into: trash))
        XCTAssertFalse(FileManager.default.fileExists(atPath: created.url.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: moved.path), "Recoverable, never unlinked")

        let edited = try service.create(WorkItem(kind: .task, title: "Edited elsewhere", url: root.appendingPathComponent("y")),
                                        in: root.appendingPathComponent("To Do"))
        Thread.sleep(forTimeInterval: 1.1)
        try "changed".write(to: edited.url, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try service.trash(edited, into: trash), "A record changed since it was read is not deleted")
        XCTAssertTrue(FileManager.default.fileExists(atPath: edited.url.path))
    }
}
