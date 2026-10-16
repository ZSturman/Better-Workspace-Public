import XCTest
@testable import BetterWorkspaceCore

final class ProjectSyncReviewPlanTests: XCTestCase {
    private let source = ProjectGraphSource(id: "s", title: "Projects", kind: .projects, schema: ProjectJSON([
        "Status": ["id": "status", "type": "status"], "date completed": ["id": "completed", "type": "date"]]))
    private func record(_ id: String, kind: ProjectEntityKind = .projects, status: String = "", links: [String] = [], local: Bool = false) -> ProjectGraphRecord {
        var record = ProjectGraphRecord(id: id, pageID: id, sourceID: "s", kind: kind, remote: [
            "title": ProjectJSON(["type": "title", "title": [["type": "text", "text": ["content": id]]]]),
            "status": ProjectJSON(["type": "status", "status": ["name": status]]),
            "links": ProjectJSON(["type": "relation", "relation": links.map { ["id": $0] }])])
        if local { record.localProjectID = "local-\(id)" }
        return record
    }
    func testConflictsErrorsAndArchivesLeadAndAreNeverRecommended() {
        var conflict = record("conflict", status: "Active", local: true)
        conflict.local["title"] = ProjectJSON(["type": "title", "title": [["text": ["content": "Local title"]]]])
        var failed = record("failed"); failed.error = "permission lost"
        var archive = record("archive"); archive.archiveRequested = true
        var ambiguous = record("ambiguous"); ambiguous.ambiguousCreate = true
        let active = record("active", status: "Active", local: true)
        let records = [active, conflict, failed, archive, ambiguous]
        let plan = ProjectSyncReviewPlan(records: records, allRecords: records, sources: [source])
        XCTAssertEqual(plan.entries.prefix(4).map(\.group), Array(repeating: .attention, count: 4))
        XCTAssertEqual(plan.recommendedIDs, [active.id])
        XCTAssertEqual(plan.safeIDs, [active.id])
        XCTAssertEqual(plan.initialCount, 5)
    }
    func testRecentActiveLocalProjectsLeadRemoteProjectsAndHistory() {
        var olderLocal = record("local", status: "Active", local: true); olderLocal.editedAt = Date(timeIntervalSince1970: 10)
        var recentRemote = record("remote", status: "Active"); recentRemote.editedAt = Date(timeIntervalSince1970: 100)
        let complete = record("complete", status: "Completed", local: true)
        let paused = record("paused", status: "Paused", local: true)
        let log = record("recent log", kind: .workLogs, links: [olderLocal.id])
        let all = [log, complete, recentRemote, paused, olderLocal]
        let plan = ProjectSyncReviewPlan(records: all, allRecords: all, sources: [source])
        XCTAssertEqual(plan.entries.first?.id, olderLocal.id)
        XCTAssertEqual(plan.recommendedIDs, [olderLocal.id, recentRemote.id])
        XCTAssertEqual(plan.entries.first { $0.id == log.id }?.group, .history)
        XCTAssertEqual(plan.entries.first { $0.id == paused.id }?.group, .other)
        XCTAssertEqual(plan.entries.last?.group, .history)
    }
    func testMultiParentWorkMediaAndCollectionsFollowActiveProjectWithoutProjectHops() {
        let active = record("active", status: "Active", links: ["collection", "inactive"])
        let inactive = record("inactive", status: "Abandoned", links: ["unrelated"])
        let feature = record("feature", kind: .features, links: ["active", "task"])
        let otherFeature = record("other feature", kind: .features, links: ["inactive", "task"])
        let task = record("task", kind: .tasks, links: [feature.id, otherFeature.id])
        let collection = record("collection", kind: .collections, links: ["asset"])
        let asset = record("asset", kind: .assets, links: ["resource"])
        let resource = record("resource", kind: .resources)
        let unrelated = record("unrelated", kind: .notes)
        let records = [active, inactive, feature, otherFeature, task, collection, asset, resource, unrelated]
        let plan = ProjectSyncReviewPlan(records: records, allRecords: records, sources: [source])
        XCTAssertTrue(plan.recommendedIDs.isSuperset(of: [active.id, feature.id, task.id, collection.id, asset.id, resource.id]))
        XCTAssertFalse(plan.recommendedIDs.contains(unrelated.id))
        XCTAssertEqual(plan.entries.first { $0.id == task.id }?.projectIDs, [active.id, inactive.id])
        XCTAssertEqual(plan.projects.first?.id, active.id)
    }
    func testFirstImportCollapsesHistoryAndPreservesAll2781Records() {
        let active = record("active", status: "Active", local: true)
        let logs = (0..<1099).map { record("log-\($0)", kind: .workLogs, links: [active.id]) }
        let tasks = (0..<977).map { record("task-\($0)", kind: .tasks, status: "Done", links: [active.id]) }
        let other = (0..<704).map { record("resource-\($0)", kind: .resources) }
        let records = [active] + logs + tasks + other
        let plan = ProjectSyncReviewPlan(records: records, allRecords: records, sources: [source])
        XCTAssertEqual(plan.entries.count, 2781)
        XCTAssertEqual(plan.initialCount, 2781)
        XCTAssertEqual(plan.entries.filter { $0.group == .history }.count, 2076)
        XCTAssertEqual(plan.recommendedIDs, [active.id])
        XCTAssertEqual(plan.safeIDs.count, 2781)
        XCTAssertEqual(plan.entries.filter { $0.group == .other }.count, 704)
        XCTAssertTrue(records.allSatisfy { $0.local.isEmpty && $0.baseline.isEmpty })
    }
}
