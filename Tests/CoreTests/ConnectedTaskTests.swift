import XCTest
@testable import BetterWorkspaceCore

final class ConnectedTaskTests: XCTestCase {
    func testStatusWritePersistsAndRetryAfterRelaunchDoesNotRewrite() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ConnectedTask-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = WorkItemService()
        let task = try service.create(.init(kind: .task, title: "Disposable task", body: "Keep this text", extraFrontMatter: ["foreign: preserved"], url: root.appendingPathComponent("placeholder")), in: root)
        let revision = service.connectedRevision(task), id = UUID()
        let saved = try service.setConnectedStatus(task, expectedRevision: revision, status: .completed, requestID: id)
        XCTAssertEqual(saved.status, .completed)
        XCTAssertTrue(saved.extraFrontMatter.contains("foreign: preserved"))
        XCTAssertEqual(saved.body, task.body)
        let bytes = try Data(contentsOf: saved.url)
        let restarted = WorkItemService()
        let retried = try restarted.setConnectedStatus(task, expectedRevision: revision, status: .completed, requestID: id)
        XCTAssertEqual(retried.completedAt, saved.completedAt)
        XCTAssertEqual(try Data(contentsOf: saved.url), bytes)
        XCTAssertThrowsError(try restarted.setConnectedStatus(task, expectedRevision: revision, status: .open, requestID: id))
        XCTAssertThrowsError(try restarted.setConnectedStatus(task, expectedRevision: revision, status: .open, requestID: UUID()))
        let reopened = try restarted.setConnectedStatus(saved, expectedRevision: restarted.connectedRevision(saved), status: .inProgress, requestID: UUID())
        XCTAssertEqual(reopened.status, .inProgress); XCTAssertNil(reopened.completedAt)
    }
    func testExternalEditAndNonTaskAreRefused() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ConnectedTask-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = WorkItemService()
        let task = try service.create(.init(kind: .task, title: "Disposable", url: root.appendingPathComponent("placeholder")), in: root)
        let revision = service.connectedRevision(task)
        let text = try String(contentsOf: task.url) + "\nExternal edit\n"
        try text.write(to: task.url, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try service.setConnectedStatus(task, expectedRevision: revision, status: .completed, requestID: UUID()))
        XCTAssertEqual(try String(contentsOf: task.url), text)
        let goal = try service.create(.init(kind: .goal, title: "A goal", url: root.appendingPathComponent("placeholder")), in: root)
        XCTAssertThrowsError(try service.setConnectedStatus(goal, expectedRevision: service.connectedRevision(goal), status: .completed, requestID: UUID()))
    }
}
