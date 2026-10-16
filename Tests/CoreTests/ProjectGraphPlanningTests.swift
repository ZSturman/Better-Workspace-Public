import XCTest
@testable import BetterWorkspaceCore

/// The Hue Light Control case: a task completed in the app kept its Notion draft at
/// "Todo · Next", and the draft was promoted as the project's next action.
final class ProjectGraphPlanningTests: XCTestCase {
    private let tasks = ProjectGraphSource(id: "tasks", title: "Tasks", kind: .tasks, schema: ProjectJSON([
        "task": ["id": "title", "type": "title"],
        "status": ["id": "status", "type": "status", "status": ["options": [["name": "Todo"], ["name": "In Progress"], ["name": "Done"], ["name": "Duplicate"]]]],
        "complete": ["id": "complete", "type": "checkbox"],
        "Work Stage": ["id": "stage", "type": "select", "select": ["options": [["name": "Recent"], ["name": "Current"], ["name": "Next"], ["name": "Backlog"]]]],
        "Blocked by": ["id": "blocked", "type": "relation", "relation": ["data_source_id": "tasks"]],
    ]))

    private func task(_ title: String, id: String = UUID().uuidString, pageID: String? = nil, status: String = "Todo",
                      stage: String = "Next", blockedBy: [String] = [], localPath: String? = nil) -> ProjectGraphRecord {
        var record = ProjectGraphRecord(id: id, pageID: pageID, sourceID: "tasks", kind: .tasks, local: [
            "title": ProjectJSON(["id": "title", "type": "title", "title": [["type": "text", "text": ["content": title]]]]),
            "status": ProjectJSON(["id": "status", "type": "status", "status": ["name": status]]),
            "complete": ProjectJSON(["id": "complete", "type": "checkbox", "checkbox": false]),
            "stage": ProjectJSON(["id": "stage", "type": "select", "select": ["name": stage]]),
            "blocked": ProjectJSON(["id": "blocked", "type": "relation", "relation": blockedBy.map { ["id": $0] }]),
        ])
        record.localPath = localPath
        return record
    }

    private func work(_ title: String, path: String, status: WorkItemStatus) -> WorkItem {
        WorkItem(kind: .task, title: title, status: status, url: URL(fileURLWithPath: path))
    }

    private func next(_ records: [ProjectGraphRecord], work: [WorkItem] = []) -> ProjectGraphRecord? {
        let byPath = Dictionary(uniqueKeysWithValues: work.map { ($0.url.canonicalPath, $0) })
        return ProjectGraphPlanning.nextAction(among: records, allRecords: records, source: { _ in self.tasks }, workByPath: byPath)
    }

    func testCompletedWorkFileOverridesItsStaleDraft() {
        let path = URL(fileURLWithPath: "/tmp/Make the dial turn the other way.bw.md").canonicalPath
        let draft = task("Make the dial turn the other way", localPath: path)
        let file = work(draft.title, path: path, status: .completed)
        XCTAssertFalse(ProjectGraph.isCompleted(draft, source: tasks), "precondition: the draft itself still says Todo")
        XCTAssertTrue(ProjectGraphPlanning.isCompleted(draft, source: tasks, localWork: file))
        XCTAssertNil(next([draft], work: [file]))
    }

    func testDraftOfAnOpenWorkFileIsLeftToTheWorkRecommendation() {
        // Otherwise the same task fills both the work and the planning next-action card.
        let path = URL(fileURLWithPath: "/tmp/Open.bw.md").canonicalPath
        let draft = task("Open", localPath: path)
        XCTAssertNil(next([draft], work: [work("Open", path: path, status: .open)]))
    }

    func testDraftWhoseFileIsGoneIsJudgedOnItsOwn() {
        let draft = task("Notion only", localPath: "/tmp/missing.bw.md")
        XCTAssertEqual(next([draft])?.id, draft.id)
    }

    func testCurrentStageComesBeforeNextAndOthersAreNotRecommended() {
        let current = task("Zed", stage: "Current"), nextUp = task("Alpha", stage: "Next")
        let backlog = task("Backlog", stage: "Backlog"), recent = task("Recent", stage: "Recent")
        XCTAssertEqual(next([nextUp, backlog, current, recent])?.id, current.id)
        XCTAssertNil(next([backlog, recent]))
    }

    func testDoneDuplicateBlockedAndUnfinishedDependenciesAreSkipped() {
        let dependency = task("First", pageID: "dep", stage: "Backlog")
        let waiting = task("Waits on first", blockedBy: ["dep"])
        let done = task("Done", status: "Done"), duplicate = task("Dupe", status: "Duplicate")
        XCTAssertNil(next([dependency, waiting, done, duplicate]))
        let finished = task("First", pageID: "dep", status: "Done", stage: "Backlog")
        XCTAssertEqual(next([finished, waiting])?.id, waiting.id)
    }

    func testDependencyCompletedThroughItsWorkFileUnblocks() {
        let path = URL(fileURLWithPath: "/tmp/Dep.bw.md").canonicalPath
        let dependency = task("Dep", pageID: "dep", localPath: path)
        let waiting = task("Waits", blockedBy: ["dep"])
        XCTAssertNil(next([dependency, waiting], work: [work("Dep", path: path, status: .open)]))
        XCTAssertEqual(next([dependency, waiting], work: [work("Dep", path: path, status: .completed)])?.id, waiting.id)
    }
}
