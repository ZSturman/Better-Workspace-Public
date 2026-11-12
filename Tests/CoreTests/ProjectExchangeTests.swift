import XCTest
@testable import BetterWorkspaceCore

/// Workspace Project Exchange v1. The contract file is shared byte-for-byte with Finder
/// Workspace Extensions; these cases cover Better Workspace's side of it.
final class ProjectExchangeTests: XCTestCase {
    private func fixture() -> ExchangeFiles {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("bw-exchange-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return ExchangeFiles(directory: url.appendingPathComponent("better-workspace"))
    }

    func testCanonicalStatusAdoptsAnExistingEquivalentOption() {
        let metadata = ProjectMetadata(status: "Active")
        let result = ProjectExchangeMetadata.apply([.init(field: .status, base: "Active", value: "Backburner")], to: metadata,
            statusOptions: ["Active", "Paused", "Done"], notionStatusOptions: ["Active", "Paused", "Done"], statusPropertyKind: "status")
        XCTAssertEqual(result.plan.outcome, .applied)
        XCTAssertEqual(result.metadata.status, "Paused")
        XCTAssertEqual(result.notionFields, ["Status"])
        XCTAssertTrue(result.warnings.isEmpty)
    }

    func testUnknownStatusOptionWarnsInsteadOfFailingSilently() {
        let result = ProjectExchangeMetadata.apply([.init(field: .status, base: nil, value: "Maintained")], to: ProjectMetadata(),
            statusOptions: ["Active"], notionStatusOptions: ["Active"], statusPropertyKind: "status")
        XCTAssertEqual(result.metadata.status, "Maintained")
        XCTAssertEqual(result.warnings.count, 1)
        let select = ProjectExchangeMetadata.apply([.init(field: .status, base: nil, value: "Maintained")], to: ProjectMetadata(),
            statusOptions: ["Active"], notionStatusOptions: ["Active"], statusPropertyKind: "select")
        XCTAssertTrue(select.warnings.isEmpty, "Notion creates select options on write")
    }

    func testConflictLeavesMetadataUntouchedAndLocalPriorityStaysLocal() {
        let metadata = ProjectMetadata(domain: "Apps", status: "In Progress", phase: "Build")
        let conflict = ProjectExchangeMetadata.apply([.init(field: .status, base: "Active", value: "Completed"),
                                                      .init(field: .domain, base: "Apps", value: "Tools")], to: metadata,
            statusOptions: [], notionStatusOptions: [], statusPropertyKind: nil)
        XCTAssertEqual(conflict.plan.outcome, .conflict)
        XCTAssertEqual(conflict.metadata, metadata)
        let priority = ProjectExchangeMetadata.apply([.init(field: .portfolioPriority, base: nil, value: "4"),
                                                      .init(field: .phase, base: "Build", value: nil)], to: metadata,
            statusOptions: [], notionStatusOptions: [], statusPropertyKind: nil)
        XCTAssertEqual(priority.metadata.portfolioPriority, 4)
        XCTAssertNil(priority.metadata.phase)
        XCTAssertEqual(priority.notionFields, ["Phase"], "Portfolio priority is a local triage signal")
    }

    func testRepeatedRequestIsUnchanged() {
        let metadata = ProjectMetadata(status: "Maintained")
        let result = ProjectExchangeMetadata.apply([.init(field: .status, base: "Completed", value: "Maintained")], to: metadata,
            statusOptions: ["Maintained"], notionStatusOptions: [], statusPropertyKind: nil)
        XCTAssertEqual(result.plan.outcome, .unchanged)
    }

    func testClaimReceiptRoundTripIsSingleUse() throws {
        let files = fixture()
        let request = ExchangeRequest(requesterID: "finder-workspace-extensions", projectID: "P", projectPath: "/tmp/P",
                                      changes: [.init(field: .phase, base: nil, value: "Ship")])
        try files.submit(request)
        XCTAssertNotNil(files.claim(request.id))
        XCTAssertNil(files.claim(request.id))
        XCTAssertEqual(files.claimedRequests(), [request.id], "An interrupted claim is found again at launch")
        try files.finish(.init(requestID: request.id, projectID: "P", outcome: .applied, message: "Saved"))
        XCTAssertTrue(files.claimedRequests().isEmpty)
        XCTAssertEqual(files.receipt(request.id)?.outcome, .applied)
    }

    func testSnapshotLifecycleAndRevisionFollowEdits() throws {
        let files = fixture()
        var project = ExchangeProject(id: "P", path: "/tmp/P", name: "P", status: "On hold", score: 81.5)
        XCTAssertEqual(project.lifecycle, .backburner)
        let revision = project.revision
        project.phase = "Maintain"; project.seal()
        XCTAssertNotEqual(project.revision, revision)
        try files.writeSnapshot(.init(workspaceRoot: "/tmp", notion: .init(configured: false, summary: "Not configured"),
                                      statusOptions: [], phaseOptions: [], domainOptions: [], projects: [project],
                                      ideaFolders: ["/tmp/Ideas/Draft": .init(domain: "Narrative", status: "exploring",
                                                                             priority: 3, score: 64, openTaskCount: 0)]))
        let snapshot = try files.readSnapshot()
        XCTAssertEqual(snapshot.projects, [project])
        XCTAssertEqual(snapshot.ideaFolders?["/tmp/Ideas/Draft"], .init(domain: "Narrative", status: "exploring",
                                                                        priority: 3, score: 64, openTaskCount: 0))
    }

    func testFinderOwnedValuesReplaceANotionPullButNotAWaitingEdit() {
        let row = ExchangeProject(id: "P", path: "/tmp/P", name: "P", status: "Active", domain: "Apps", portfolioPriority: 4)
        let pulled = ProjectMetadata(domain: "Apps", status: "Idea", phase: "Build", currentWork: ["Keep"], portfolioPriority: 4)
        let mirrored = FinderOwnedMetadata.mirror(row, onto: pulled)
        XCTAssertEqual(mirrored.changed, [.status, .phase])
        XCTAssertEqual(mirrored.metadata.status, "Active")
        XCTAssertNil(mirrored.metadata.phase, "The owner has no phase, so none is kept")
        XCTAssertEqual(mirrored.metadata.currentWork, ["Keep"], "Fields outside the exchange stay local")
        let waiting = FinderOwnedMetadata.mirror(row, onto: pulled, skipping: [.status])
        XCTAssertEqual(waiting.metadata.status, "Idea", "This Mac's own edit stays until its receipt")
        XCTAssertTrue(FinderOwnedMetadata.mirror(row, onto: mirrored.metadata).changed.isEmpty, "Mirroring settles")
    }

    func testEditsHereBecomeOneRequestBasedOnWhatThePersonSaw() throws {
        let old = ProjectMetadata(domain: "Apps", status: "Active", currentWork: ["A"])
        let new = ProjectMetadata(domain: "Tools", status: "Paused", currentWork: ["B"])
        let request = try XCTUnwrap(FinderOwnedMetadata.request(projectID: "P", projectPath: "/tmp/P", from: old, to: new))
        XCTAssertEqual(request.requesterID, FinderOwnedMetadata.requesterID)
        XCTAssertEqual(request.changes, [.init(field: .status, base: "Active", value: "Paused"), .init(field: .domain, base: "Apps", value: "Tools")])
        XCTAssertNoThrow(try request.validate())
        // Finder chose Blocked meanwhile: the owner's base check refuses the stale edit.
        XCTAssertEqual(ExchangeMerge.plan(request.changes) { $0 == .status ? "Blocked" : "Apps" }.outcome, .conflict)
        let only = FinderOwnedMetadata.request(projectID: "P", projectPath: "/tmp/P", from: old, to: new, only: [.domain])
        XCTAssertEqual(only?.changes.map(\.field), [.domain])
        XCTAssertNil(FinderOwnedMetadata.request(projectID: "P", projectPath: "/tmp/P", from: old, to: old))
    }

    func testStatusDetailsAreNeverMirroredOrSent() {
        let full = String(repeating: "Long status details. ", count: 200)
        let row = ExchangeProject(id: "P", path: "/tmp/P", name: "P", status: "Active", statusDetail: String(full.prefix(500)))
        let mirrored = FinderOwnedMetadata.mirror(row, onto: ProjectMetadata(status: "Active", statusDetail: full))
        XCTAssertTrue(mirrored.changed.isEmpty)
        XCTAssertEqual(mirrored.metadata.statusDetail, full, "A cut snapshot value never replaces the full text")
        XCTAssertNil(FinderOwnedMetadata.request(projectID: "P", projectPath: "/tmp/P", from: ProjectMetadata(statusDetail: "A"),
                                                 to: ProjectMetadata(statusDetail: full)))
    }
}
