import XCTest
@testable import BetterWorkspaceCore

final class AgentTaskRunTests: XCTestCase {
    private func request(sequential: Bool = true) -> AgentTaskRequest {
        .init(runID: "run", projectPath: "/project", provider: "codex", model: "", effort: "", endpoint: "", sequential: sequential,
              instructions: "", tasks: ["a", "b"].map { .init(id: $0, title: $0, body: "", fingerprint: "", workPath: nil) })
    }
    private func receipt(_ ids: [String], evidence: String = "Verified file", runID: String = "run", state: String = "finished") throws -> AgentTaskReceipt {
        let data = try JSONSerialization.data(withJSONObject: ["runID": runID, "state": state,
            "summary": "Done", "completed": ids.map { ["id": $0, "evidence": evidence] }])
        return try JSONDecoder().decode(AgentTaskReceipt.self, from: data)
    }
    func testCompletionRequiresSelectedIDsEvidenceAndMatchingRun() throws {
        XCTAssertEqual(try receipt(["a"]).validated(for: request()).map(\.id), ["a"])
        for value in [try receipt(["foreign"]), try receipt(["a", "a"]), try receipt(["a"], evidence: " "),
                      try receipt(["a"], runID: "other"), try receipt(["a"], state: "unknown")] {
            XCTAssertThrowsError(try value.validated(for: request()))
        }
    }
    func testSequentialReportsMustBeAPrefixButUnorderedCanFinishAnyTask() throws {
        XCTAssertThrowsError(try receipt(["b"]).validated(for: request()))
        XCTAssertThrowsError(try receipt(["b", "a"]).validated(for: request()))
        XCTAssertEqual(try receipt(["b"]).validated(for: request(sequential: false)).count, 1)
        XCTAssertEqual(try receipt(["a"], state: "failed").validated(for: request()).count, 1,
                       "A later failure does not erase earlier successful tasks")
        XCTAssertEqual(try receipt([]).validated(for: request()).count, 0, "Exit success is not task completion")
    }
    func testFingerprintChangesWhenTaskMeaningChanges() {
        let item = WorkItem(id: "a", kind: .task, title: "Create file", body: "Use hello", url: URL(fileURLWithPath: "/task"))
        let original = AgentTaskSnapshot.fingerprint(item)
        var changed = item; changed.body = "Use goodbye"
        XCTAssertNotEqual(original, AgentTaskSnapshot.fingerprint(changed))
        changed = item; changed.dependencyIDs = ["new-dependency"]
        XCTAssertNotEqual(original, AgentTaskSnapshot.fingerprint(changed))
        changed = item; changed.status = .completed
        XCTAssertNotEqual(original, AgentTaskSnapshot.fingerprint(changed))
        XCTAssertEqual(original, AgentTaskSnapshot.fingerprint(item))
    }
    func testOlderPrivateRequestsRemainDecodable() throws {
        var old = try JSONSerialization.jsonObject(with: JSONEncoder().encode(request())) as! [String: Any]
        old.removeValue(forKey: "networkAccess"); old.removeValue(forKey: "interactive")
        let decoded = try JSONDecoder().decode(AgentTaskRequest.self, from: JSONSerialization.data(withJSONObject: old))
        XCTAssertNil(decoded.networkAccess)
        XCTAssertNil(decoded.interactive)
        XCTAssertEqual(decoded.tasks.map(\.id), ["a", "b"])
        XCTAssertEqual(try receipt(["a"]).validated(for: decoded).count, 1)
    }
}
