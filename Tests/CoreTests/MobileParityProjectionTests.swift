import XCTest
@testable import BetterWorkspaceCore

final class MobileParityProjectionTests: XCTestCase {
    func testDatesTravelInExistingBodyEnvelopeAndOldPublishersRemainReadable() throws {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let item = MobileWorkItem(id: "work", path: "To Do/Test.bw.md", title: "Test", kind: .task,
                                  status: .completed, stage: .next, priority: .medium, revision: 1,
                                  body: "Original text", createdAt: date, modifiedAt: date, completedAt: date)
        let decoded = MobileActionProjection.decode(MobileActionProjection.encode(item))
        XCTAssertEqual(decoded.body, "Original text")
        XCTAssertEqual(decoded.createdAt, date); XCTAssertEqual(decoded.modifiedAt, date); XCTAssertEqual(decoded.completedAt, date)
        XCTAssertNil(MobileActionProjection.decode("Legacy text").completedAt)
        let old = #"{"id":"old","path":"To Do/Old.bw.md","title":"Old","kind":"task","status":"open","stage":"next","priority":"medium","revision":1,"tagIDs":[]}"#
        XCTAssertNil(try JSONDecoder().decode(MobileWorkItem.self, from: Data(old.utf8)).createdAt)
    }
    func testCompletedNotionDependencyHasSameReadinessOnPhone() {
        let done = MobileWorkItem(id: "local-done", path: "To Do/Done.bw.md", title: "Done", kind: .task,
                                 status: .completed, stage: .now, priority: .high, revision: 1, importedNotionPageID: "notion-done")
        let next = MobileWorkItem(id: "next", path: "To Do/Next.bw.md", title: "Next", kind: .task,
                                 status: .open, stage: .next, priority: .high, revision: 1, dependencyIDs: ["notion-done"])
        XCTAssertEqual(MobileActionProjection.decode(MobileActionProjection.encode(done)).notionPageID, "notion-done")
        XCTAssertEqual(WorkItemRecommendation.nextMobileAction(in: [next], allItems: [next, done])?.id, "next")
        XCTAssertNil(WorkItemRecommendation.nextMobileAction(in: [next], allItems: [next]))
    }
    func testAssessmentProjectionOmitsPrivateIDsAndCommandsAndChangesPublicationSignature() throws {
        let audit = ProjectAuditAssessment(projectID: "private-project", assessedAt: "2026-10-09", classification: "Active", recommendation: "Repair", scores: ["TechnicalRisk": 3], workPriorityScore: 80, validationCoverage: "Targeted", confidence: "Medium", notes: ["private note"], commands: ["/Users/private/run"])
        let details = MobileProjectDetails(path: "Projects/Test", assessment: MobileProjectAssessment(audit))
        let encoded = try JSONEncoder().encode(details)
        let text = String(decoding: encoded, as: UTF8.self)
        XCTAssertFalse(text.contains("private-project")); XCTAssertFalse(text.contains("/Users/")); XCTAssertFalse(text.contains("private note"))
        XCTAssertEqual(try JSONDecoder().decode(MobileProjectDetails.self, from: encoded), details)
        let old = try JSONDecoder().decode(MobileProjectDetails.self, from: Data(#"{"path":"Projects/Test"}"#.utf8))
        XCTAssertNil(old.assessment)
        let baseline = MobileCloudPublicationCandidate.entry(MobileWorkspaceEntry(path: "Projects/Test", parentPath: "Projects", name: "Test", isDirectory: true, revision: 1, projectDetails: old))
        let changed = MobileCloudPublicationCandidate.entry(MobileWorkspaceEntry(path: "Projects/Test", parentPath: "Projects", name: "Test", isDirectory: true, revision: 1, projectDetails: details))
        XCTAssertNotEqual(baseline.fingerprint, changed.fingerprint)
    }
}
