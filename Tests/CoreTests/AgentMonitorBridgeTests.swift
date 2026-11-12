import XCTest
@testable import BetterWorkspaceCore

/// The Local AI Agent Completion Monitor's write path: every change is conflict-checked,
/// idempotent and reversible, and a person's newer edit always wins.
final class AgentMonitorBridgeTests: XCTestCase {
    private var root: URL!
    private var queue: URL { root.appendingPathComponent("To Do") }
    private var trash: URL { root.appendingPathComponent(".trash-for-test") }
    private var workspace: WorkspaceLocation { WorkspaceLocation(root: root) }
    private let project = "Projects/Demo App"

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("bw-agent-monitor-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent(project), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: queue, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func metadata(_ fingerprint: String, delegation: String = "USER") -> WorkItemActionMetadata {
        .init(fingerprint: fingerprint, priority: "P1", actionScore: 80, delegation: delegation, tags: ["Agent follow-up"],
              requirements: [], agentExecutability: 10, humanInvolvement: 90, estimatedEffort: "Small",
              category: "Verification", reason: "Needs a person", evidence: ["Codex: try the corner drag"],
              agentSubtasks: [], userSubtasks: ["Test window resizing"], blockedBy: [],
              isNextWork: false, isNextAgentAction: false, isNextUserAction: false)
    }

    private func existing(_ id: String, title: String, extra: [String] = []) throws -> WorkItem {
        try WorkItemService().create(WorkItem(id: id, kind: .task, title: title, stage: .now, priority: .high, projectPath: project,
                                              body: "A person's description.", extraFrontMatter: extra,
                                              url: queue.appendingPathComponent("x")), in: queue)
    }

    private func apply(_ manifest: AgentMonitorBridge.Manifest) throws -> AgentMonitorBridge.Response {
        try AgentMonitorBridge.apply(manifest, workspace: workspace, queues: [queue], taskQueue: queue, trash: trash)
    }

    private func manifest(create: [AgentMonitorBridge.Create] = [], complete: [AgentMonitorBridge.Update] = [],
                          progress: [AgentMonitorBridge.Update] = [], revert: [AgentMonitorBridge.Revert] = []) -> AgentMonitorBridge.Manifest {
        .init(version: 1, projectPath: project, source: nil, create: create, complete: complete, progress: progress, revert: revert)
    }

    func testCreatesTaskWithResponsibilityAndReplayDoesNotDuplicate() throws {
        let create = AgentMonitorBridge.Create(id: "NEW-1", title: "Test window resizing", body: "Try a corner drag.",
                                               stage: "now", priority: "high", due: "2026-11-02", actionMetadata: metadata("monitor:a"))
        let first = try apply(manifest(create: [create]))
        XCTAssertEqual(first.receipts.map(\.result), ["applied"])
        let saved = try XCTUnwrap(WorkItemService().read(at: URL(fileURLWithPath: try XCTUnwrap(first.receipts[0].path))))
        XCTAssertEqual(saved.responsibilityLabel, "Me")
        XCTAssertEqual(saved.projectPath, project)
        XCTAssertNotNil(saved.dueDate)
        XCTAssertEqual(first.project.nextAction?.id, "NEW-1")
        XCTAssertEqual(first.project.highOpen, 1)

        // Same id, or a different id with the same fingerprint: never a second copy.
        var other = create; other.id = "NEW-2"
        let replay = try apply(manifest(create: [create, other]))
        XCTAssertEqual(replay.receipts.map(\.result), ["exists", "exists"])
        XCTAssertEqual(WorkItemService().items(under: queue).count, 1)
    }

    func testCompletionAppendsNoteKeepsUnknownFieldsAndRefusesStaleRecords() throws {
        let task = try existing("T1", title: "Fix sync retry", extra: ["custom: keep-me"])
        let expected = try XCTUnwrap(task.modifiedAt?.timeIntervalSince1970)
        let done = try apply(manifest(complete: [.init(id: "T1", path: task.url.path, expectedModifiedAt: expected,
                                                         note: "**Completed (Codex):** retry test passed", markInProgress: nil)]))
        XCTAssertEqual(done.receipts.first?.result, "applied")
        XCTAssertNotNil(done.receipts.first?.previousContent)
        let saved = try XCTUnwrap(WorkItemService().read(at: task.url))
        XCTAssertEqual(saved.status, .completed)
        XCTAssertNotNil(saved.completedAt)
        XCTAssertTrue(saved.body.hasPrefix("A person's description."))
        XCTAssertTrue(saved.body.hasSuffix("retry test passed"))
        XCTAssertTrue(saved.extraFrontMatter.contains("custom: keep-me"))

        // The analysis saw an older version: a newer edit wins and nothing is written.
        let other = try existing("T2", title: "Document sync")
        let seen = try XCTUnwrap(other.modifiedAt?.timeIntervalSince1970)
        var edited = other; edited.body = "Edited in Finder"; _ = try WorkItemService().update(edited)
        let stale = try apply(manifest(progress: [.init(id: "T2", path: other.url.path, expectedModifiedAt: seen - 5,
                                                          note: "Progress", markInProgress: true)]))
        XCTAssertEqual(stale.receipts.first?.result, "stale")
        XCTAssertEqual(WorkItemService().read(at: other.url)?.status, .open)
    }

    func testMissingTaskIsNeverRecreatedAndCompletedTaskIsLeftAlone() throws {
        let task = try existing("T1", title: "Fix sync retry")
        let stamp = try XCTUnwrap(task.modifiedAt?.timeIntervalSince1970)
        try FileManager.default.removeItem(at: task.url)   // Deleted in Finder.
        let gone = try apply(manifest(complete: [.init(id: "T1", path: task.url.path, expectedModifiedAt: stamp, note: "x", markInProgress: nil)]))
        XCTAssertEqual(gone.receipts.first?.result, "missing")
        XCTAssertFalse(FileManager.default.fileExists(atPath: task.url.path))

        var closed = try existing("T3", title: "Already done")
        closed = try WorkItemService().complete(closed)
        let notOpen = try apply(manifest(progress: [.init(id: "T3", path: closed.url.path,
                                                            expectedModifiedAt: try XCTUnwrap(closed.modifiedAt?.timeIntervalSince1970),
                                                            note: "Progress", markInProgress: true)]))
        XCTAssertEqual(notOpen.receipts.first?.result, "not-open")
    }

    func testRevertRestoresExactBytesAndTrashesCreatedTasksOnlyWhenUnchanged() throws {
        let task = try existing("T1", title: "Fix sync retry")
        let before = try String(contentsOf: task.url, encoding: .utf8)
        let done = try apply(manifest(
            create: [.init(id: "NEW-1", title: "Verify deployment", body: "", stage: "next", priority: "medium", due: nil,
                           actionMetadata: metadata("monitor:b", delegation: "USER + AGENT"))],
            complete: [.init(id: "T1", path: task.url.path, expectedModifiedAt: try XCTUnwrap(task.modifiedAt?.timeIntervalSince1970),
                             note: "Completed", markInProgress: nil)]))
        let reverts = done.receipts.reversed().map {
            AgentMonitorBridge.Revert(id: $0.id, path: $0.path ?? "", expectedModifiedAt: $0.modifiedAt ?? 0,
                                      previousContent: $0.op == "create" ? nil : $0.previousContent)
        }
        let undone = try apply(manifest(revert: reverts))
        XCTAssertEqual(undone.receipts.map(\.result), ["applied", "applied"])
        XCTAssertEqual(try String(contentsOf: task.url, encoding: .utf8), before)
        XCTAssertEqual(WorkItemService().items(under: queue).map(\.id), ["T1"])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: trash.path).count, 1, "Created task is recoverable")
    }

    func testRevertLeavesARecordAPersonChangedSinceTheMonitorWrote() throws {
        let task = try existing("T1", title: "Fix sync retry")
        let done = try apply(manifest(progress: [.init(id: "T1", path: task.url.path,
                                                         expectedModifiedAt: try XCTUnwrap(task.modifiedAt?.timeIntervalSince1970),
                                                         note: "Progress", markInProgress: true)]))
        let receipt = try XCTUnwrap(done.receipts.first)
        var edited = try XCTUnwrap(WorkItemService().read(at: task.url)); edited.title = "Renamed by a person"
        Thread.sleep(forTimeInterval: 0.01)
        _ = try WorkItemService().update(edited)
        let undone = try apply(manifest(revert: [.init(id: "T1", path: task.url.path, expectedModifiedAt: receipt.modifiedAt ?? 0,
                                                       previousContent: receipt.previousContent)]))
        XCTAssertEqual(undone.receipts.first?.result, "stale")
        XCTAssertEqual(WorkItemService().read(at: task.url)?.title, "Renamed by a person")
    }

    func testRefusesProjectsOutsideProjectsAndInvalidMetadata() throws {
        var bad = manifest(); bad.projectPath = "Projects/_Utilities"
        XCTAssertThrowsError(try apply(bad))
        bad.projectPath = "Ideas/Something"
        XCTAssertThrowsError(try apply(bad))
        var meta = metadata("monitor:c"); meta.delegation = "SOMEONE"
        let invalid = try apply(manifest(create: [.init(id: "N", title: "Do it", body: "", stage: "now", priority: "high",
                                                        due: nil, actionMetadata: meta)]))
        XCTAssertEqual(invalid.receipts.first?.result, "invalid")
        XCTAssertTrue(WorkItemService().items(under: queue).isEmpty)
    }
}
