import XCTest
@testable import BetterWorkspaceCore

final class ProjectSyncHealthTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_900_000_000)

    private func item(_ id: String, fingerprint value: String = "a") -> ProjectSyncTriage.Item {
        var record = ProjectGraphRecord(id: id, pageID: id, sourceID: "s", kind: .projects)
        record.local = ["f": ProjectJSON(value)]
        return ProjectSyncTriage.Item(record: record, category: .conflict, bucket: .decision, fields: [
            .init(id: "f", name: "F", state: .conflict, local: ProjectJSON(value), notion: .null, newer: nil, recommended: nil, bucket: .decision, note: nil, mergeBlockedReason: nil)
        ], projectIDs: [], reason: "")
    }
    private func plan(attention: [ProjectSyncTriage.Item]) -> ProjectAutoSyncPlanner.Plan {
        var plan = ProjectAutoSyncPlanner.Plan(); plan.attention = attention; return plan
    }

    func testAQuietHealthyHistoryHasNoFindings() {
        var health = ProjectSyncHealth()
        for pass in 0..<10 { health.record(plan(attention: [item("a")]), report: .init(), at: start.addingTimeInterval(Double(pass) * 300)) }
        XCTAssertEqual(health.findings(now: start.addingTimeInterval(3000), automatic: true), [])
    }

    func testAGrowingReviewQueueIsReported() {
        var health = ProjectSyncHealth()
        health.record(plan(attention: (0..<10).map { item("\($0)") }), report: .init(), at: start)
        health.record(plan(attention: (0..<40).map { item("\($0)") }), report: .init(), at: start.addingTimeInterval(3600))
        XCTAssertEqual(health.findings(now: start.addingTimeInterval(3600), automatic: false), [.growing(from: 10, to: 40)])
    }

    func testOldSamplesLeaveTheGrowthWindow() {
        var health = ProjectSyncHealth()
        health.record(plan(attention: []), report: .init(), at: start)
        health.record(plan(attention: (0..<40).map { item("\($0)") }), report: .init(), at: start.addingTimeInterval(2 * 86_400))
        XCTAssertEqual(health.samples.count, 1)
        XCTAssertEqual(health.findings(now: start.addingTimeInterval(2 * 86_400), automatic: false), [])
    }

    func testARecordMovedOnEveryPassIsAFeedbackLoop() {
        var health = ProjectSyncHealth()
        var report = ProjectAutoSync.Report(); report.sent = ["echo"]
        for pass in 0..<3 { health.record(plan(attention: []), report: report, at: start.addingTimeInterval(Double(pass) * 300)) }
        XCTAssertEqual(health.findings(now: start.addingTimeInterval(600), automatic: false), [.loop(records: 1)])
        health.record(plan(attention: []), report: .init(), at: start.addingTimeInterval(900))
        XCTAssertEqual(health.findings(now: start.addingTimeInterval(900), automatic: false), [], "One quiet pass ends the loop")
    }

    func testADifferenceThatKeepsChangingWhileWaitingIsReported() {
        var health = ProjectSyncHealth()
        for (pass, value) in ["a", "b", "c", "d"].enumerated() {
            health.record(plan(attention: [item("day", fingerprint: value)]), report: .init(), at: start.addingTimeInterval(Double(pass) * 300))
        }
        XCTAssertEqual(health.findings(now: start.addingTimeInterval(900), automatic: false), [.recurring(records: 1)])
    }

    func testStalledAndFailingPassesAreReported() {
        var health = ProjectSyncHealth()
        var failed = ProjectAutoSync.Report(); failed.failed = ["x": "503"]
        // Fourteen five-minute passes, every one failing: over an hour without a clean pass.
        for pass in 0..<14 { health.record(plan(attention: []), report: failed, at: start.addingTimeInterval(Double(pass) * 300)) }
        let later = start.addingTimeInterval(2 * 3600)
        XCTAssertEqual(health.findings(now: later, automatic: true), [.stalled(since: start), .failing(passes: 14)])
        XCTAssertEqual(health.findings(now: later, automatic: false), [.failing(passes: 14)], "Manual mode is not stalled")
        health.record(plan(attention: []), report: .init(), at: later)
        XCTAssertEqual(health.findings(now: later, automatic: true), [], "A clean pass clears both")
    }

    func testSleepOrAQuitAppIsNotAStall() {
        var health = ProjectSyncHealth()
        health.record(plan(attention: []), report: .init(), at: start)
        XCTAssertEqual(health.findings(now: start.addingTimeInterval(12 * 3600), automatic: true), [], "No pass ran overnight; none failed")
    }

    func testARecordSettledOnEveryPassIsALoop() {
        var health = ProjectSyncHealth()
        for pass in 0..<3 { health.record(plan(attention: []), report: .init(), settled: ["respelled"], at: start.addingTimeInterval(Double(pass) * 300)) }
        XCTAssertEqual(health.findings(now: start.addingTimeInterval(600), automatic: false), [.loop(records: 1)])
    }

    func testHealthSurvivesStorage() throws {
        var health = ProjectSyncHealth()
        health.record(plan(attention: [item("a")]), report: .init(), at: start)
        let decoded = try JSONDecoder().decode(ProjectSyncHealth.self, from: JSONEncoder().encode(health))
        XCTAssertEqual(decoded, health)
    }

    func testPolicyDecodesFromAnOlderOrEmptyRecord() throws {
        XCTAssertEqual(try JSONDecoder().decode(ProjectSyncTriage.Policy.self, from: Data("{}".utf8)), .init())
        XCTAssertEqual(try JSONDecoder().decode(ProjectSyncTriage.Policy.self, from: Data(#"{"receiveNotionChanges":true}"#.utf8)), .init(receiveNotionChanges: true))
    }
}
