import XCTest
@testable import BetterWorkspaceCore

final class ProjectRecordProfileTests: XCTestCase {
    private func source(_ id: String, _ kind: ProjectEntityKind, _ fields: [String: [String: Any]]) -> ProjectGraphSource {
        ProjectGraphSource(id: id, title: kind.title, kind: kind, schema: ProjectJSON(fields.mapValues { $0 as Any }))
    }
    private func relation(_ target: String) -> [String: Any] { ["type": "relation", "relation": ["data_source_id": target]] }

    private lazy var projects = source("projects", .projects, ["title": ["id": "title", "type": "title"]])
    private lazy var tasks = source("tasks", .tasks, [
        "task": ["id": "title", "type": "title"], "status": ["id": "s", "type": "status", "status": ["options": [["name": "Todo"], ["name": "Done"]]]],
        "Work Stage": ["id": "w", "type": "select", "select": ["options": [["name": "Next"]]]], "Agent": ["id": "a", "type": "select", "select": ["options": [["name": "Codex"]]]],
        "Features": ["id": "f"].merging(relation("features")) { $1 }, "milestones": ["id": "m"].merging(relation("milestones")) { $1 },
        "Blocked by": ["id": "b"].merging(relation("tasks")) { $1 }, "score": ["id": "sc", "type": "formula"]])
    private lazy var features = source("features", .features, [
        "Feature": ["id": "title", "type": "title"], "Outcome": ["id": "o", "type": "rich_text"], "Current Focus": ["id": "cf", "type": "rich_text"],
        "Success Criteria": ["id": "sc", "type": "rich_text"], "Status": ["id": "st", "type": "select", "select": ["options": [["name": "Active"]]]],
        "Phase": ["id": "ph", "type": "select", "select": ["options": []]], "Priority": ["id": "p", "type": "number"],
        "Milestones": ["id": "m"].merging(relation("milestones")) { $1 }, "Tasks": ["id": "t"].merging(relation("tasks")) { $1 },
        "Child Features": ["id": "c"].merging(relation("features")) { $1 }, "Parent Feature": ["id": "pf"].merging(relation("features")) { $1 },
        "Dependencies": ["id": "d"].merging(relation("features")) { $1 }, "Project": ["id": "pr"].merging(relation("projects")) { $1 }])
    private lazy var milestones = source("milestones", .milestones, [
        "milestone": ["id": "title", "type": "title"], "description": ["id": "d", "type": "rich_text"], "due date (manual)": ["id": "due", "type": "date"],
        "tasks": ["id": "t"].merging(relation("tasks")) { $1 }, "status": ["id": "s", "type": "formula"]])
    private var all: [ProjectGraphSource] { [projects, tasks, features, milestones] }

    func testFeatureLeadsWithOutcomeStatusMilestonesAndTasks() {
        let profile = ProjectRecordProfile.make(kind: .features, source: features, sources: all)
        XCTAssertEqual(profile.title, "Feature")
        XCTAssertEqual(profile.description?.name, "Outcome")
        XCTAssertEqual(profile.essentials.map(\.name), ["Status"])
        XCTAssertEqual(profile.relations.map(\.name), ["Milestones", "Tasks"])
        XCTAssertEqual(profile.relations.map(\.target), [.milestones, .tasks])
        // Child features and dependencies are uncommon: More Options, after its fields.
        XCTAssertEqual(profile.advanced, ["Current Focus", "Phase", "Priority", "Success Criteria",
                                          "Child Features", "Dependencies", "Parent Feature", "Project"])
        XCTAssertEqual(profile.label(for: "Success Criteria"), "Done when")
        XCTAssertEqual(profile.label(for: "Child Features"), "Sub-features")
    }

    func testEveryWritablePropertyStaysReachable() {
        for (kind, source) in [(ProjectEntityKind.features, features), (.tasks, tasks), (.milestones, milestones)] {
            let profile = ProjectRecordProfile.make(kind: kind, source: source, sources: all)
            let shown = Set([profile.title, profile.description?.name].compactMap { $0 } + profile.essentials.map(\.name)
                            + profile.relations.map(\.name) + profile.advanced + profile.computed)
            XCTAssertEqual(shown, Set(source.schema.object.keys), "\(kind)")
        }
    }

    func testTaskEssentialsAndComputedFields() {
        let profile = ProjectRecordProfile.make(kind: .tasks, source: tasks, sources: all)
        XCTAssertNil(profile.description)
        XCTAssertEqual(profile.essentials.map(\.label), ["Status", "When"])
        XCTAssertEqual(profile.relations.map(\.noun), ["Feature", "Milestone"])
        XCTAssertEqual(profile.computed, ["score"])
        XCTAssertTrue(profile.advanced.contains("Agent"))
        XCTAssertEqual(profile.label(for: "Blocked by"), "Waiting on")
    }

    func testMilestoneComputedStatusIsNotEditable() {
        let profile = ProjectRecordProfile.make(kind: .milestones, source: milestones, sources: all)
        XCTAssertEqual(profile.description?.name, "description")
        XCTAssertEqual(profile.essentials.map(\.label), ["Due"])
        XCTAssertEqual(profile.relations.map(\.name), ["tasks"])
        XCTAssertEqual(profile.computed, ["status"])
    }

    func testSingularNames() {
        XCTAssertEqual(ProjectEntityKind.features.singular, "Feature")
        XCTAssertEqual(ProjectEntityKind.workLogs.singular, "Work Log")
        XCTAssertEqual(ProjectEntityKind.tasks.singular, "Task")
    }
}
