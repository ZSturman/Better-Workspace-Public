import XCTest
@testable import BetterWorkspaceCore

final class IdeaProjectBridgeTests: XCTestCase {
    private let source = ProjectGraphSource(id: "projects", title: "Projects", kind: .projects, schema: ProjectJSON([
        "Name": ["id": "title", "type": "title"], "Status": ["id": "status", "type": "status"],
        "Local Directory": ["id": "directory", "type": "rich_text"], "Domain": ["id": "domain", "type": "select"],
        "Type": ["id": "type", "type": "multi_select"], "Phase": ["id": "phase", "type": "select"],
        "One Liner": ["id": "line", "type": "rich_text"], "Summary": ["id": "summary", "type": "rich_text"]]))
    private var details: IdeaProjectDetails { .init(metadata: .init(domain: "Technology", phase: "Planning", projectType: "Application"), oneLiner: "Useful tool", summary: "Keep the idea’s complete files") }
    private func make(existing: ProjectGraphRecord? = nil) throws -> ProjectGraphRecord {
        try IdeaProjectBridge.applying(serviceID: "idea-uuid", title: "Studio", path: "/Fixture/Ideas/Studio", details: details, tags: [], ratings: [:], to: existing, source: source)
    }
    func testPotentialMetadataRoundTripsThroughExistingPlanningAndMobileEnvelope() throws {
        let planning = IdeaPlanning(potential: .project, project: details)
        try planning.validate()
        let decoded = try JSONDecoder().decode(IdeaPlanning.self, from: JSONEncoder().encode(planning))
        XCTAssertEqual(decoded, planning)
        let legacy = try JSONDecoder().decode(IdeaPlanning.self, from: Data(#"{"priority":3,"ratings":{},"needsSetup":false}"#.utf8))
        XCTAssertNil(legacy.project)
        let idea = MobileIdea(path: "Ideas/Studio", title: "Studio", revision: 1, planning: planning)
        XCTAssertEqual(MobileIdeaEnvelope.decode(MobileIdeaEnvelope.encode(idea))?.planning?.project, details)
    }
    func testStableIdentityAndExactDirectoryAdoptionPreventDuplicateProjects() throws {
        let first = try make()
        let second = try make(existing: first)
        XCTAssertEqual(second, first)
        XCTAssertEqual(first.id, "idea-project:idea-uuid")
        XCTAssertEqual(first.value("Status", source: source).display, "Idea")
        XCTAssertEqual(first.value("Local Directory", source: source).display, "/Fixture/Ideas/Studio")
        XCTAssertEqual(first.value("Type", source: source)["multi_select"].array.first?["name"].string, "Application")
        XCTAssertEqual(first.value("Summary", source: source).display, details.summary)
        var remote = first; remote.id = "imported-page"; remote.serviceRecordID = nil; remote.pageID = "notion-page"
        XCTAssertEqual(try IdeaProjectBridge.existing(serviceID: "idea-uuid", path: "/Fixture/Ideas/Studio", records: [remote], source: source)?.pageID, "notion-page")
        var duplicate = remote; duplicate.id = "another-page"
        XCTAssertThrowsError(try IdeaProjectBridge.existing(serviceID: "idea-uuid", path: "/Fixture/Ideas/Studio", records: [remote, duplicate], source: source))
        XCTAssertNil(try IdeaProjectBridge.existing(serviceID: "another", path: "/Fixture/Ideas/Other", records: [remote], source: source))
    }
    func testUnlinkedSameTitlePageIsHeldNotDuplicatedAndNeverAdopted() throws {
        var unlinked = ProjectGraphRecord(id: "unlinked", pageID: "older-idea-page", sourceID: source.id, kind: .projects)
        unlinked.remote = ["title": ProjectServiceBridge.text(" studio "), "status": ProjectJSON(["type": "status", "status": ["name": "Idea"]])]
        XCTAssertEqual(IdeaProjectBridge.unlinkedTitleMatch(title: "Studio", records: [unlinked], source: source)?.id, "unlinked")
        XCTAssertNil(try IdeaProjectBridge.existing(serviceID: "idea-uuid", path: "/Fixture/Ideas/Studio", records: [unlinked], source: source), "Titles never establish identity")
        var linked = unlinked; linked.remote["directory"] = ProjectServiceBridge.text("/Fixture/Projects/Studio")
        XCTAssertNil(IdeaProjectBridge.unlinkedTitleMatch(title: "Studio", records: [linked], source: source), "A page with its own directory is another project")
        var ours = unlinked; ours.serviceRecordID = "idea-uuid"
        XCTAssertNil(IdeaProjectBridge.unlinkedTitleMatch(title: "Studio", records: [ours], source: source))
        var draft = unlinked; draft.pageID = nil
        XCTAssertNil(IdeaProjectBridge.unlinkedTitleMatch(title: "Studio", records: [draft], source: source))
        XCTAssertNil(IdeaProjectBridge.unlinkedTitleMatch(title: "Studio Two", records: [unlinked], source: source))
        // Once someone sets that page's Local Directory to the idea's folder, it is adopted exactly.
        var linkedToIdea = unlinked; linkedToIdea.remote["directory"] = ProjectServiceBridge.text("/Fixture/Ideas/Studio"); linkedToIdea.local = linkedToIdea.remote
        XCTAssertEqual(try IdeaProjectBridge.existing(serviceID: "idea-uuid", path: "/Fixture/Ideas/Studio", records: [linkedToIdea], source: source)?.pageID, "older-idea-page")
    }
    func testExternalPromotionDetectionDoesNotResetRemoteStatusOrAcceptIncomingMetadata() throws {
        var record = try make(); record.pageID = "page"
        record.baseline = record.local; record.remote = record.local
        record.remote["status"] = ProjectJSON(["type": "status", "status": ["name": "Queued"]])
        record.remote["summary"] = ProjectJSON(["type": "rich_text", "rich_text": [["text": ["content": "Remote summary"]]]])
        let updated = try make(existing: record)
        XCTAssertEqual(IdeaProjectBridge.promotedStatus(updated, source: source), "Queued")
        XCTAssertEqual(updated.remote, record.remote)
        XCTAssertEqual(updated.local["summary"], record.local["summary"])
        XCTAssertEqual(updated.local["status"], record.local["status"])
        record.remoteArchived = true
        XCTAssertNil(IdeaProjectBridge.promotedStatus(record, source: source))
        record.remoteArchived = false
        for status in ["Idea", "Complete", "Archived", "Abandoned", "Deprecated", ""] {
            record.remote["status"] = ProjectJSON(["type": "status", "status": ["name": status]])
            XCTAssertNil(IdeaProjectBridge.promotedStatus(record, source: source))
        }
    }
    func testMissingSchemaIsActionableAndOversizedMetadataIsRefused() throws {
        let empty = ProjectGraphSource(id: "none", title: "Projects", kind: .projects, schema: .null)
        XCTAssertThrowsError(try IdeaProjectBridge.applying(serviceID: "idea", title: "Studio", path: "/Fixture/Ideas/Studio", details: details, tags: [], ratings: [:], to: nil, source: empty))
        var planning = IdeaPlanning(potential: .project, project: details)
        planning.project?.summary = String(repeating: "a", count: 12001)
        XCTAssertThrowsError(try planning.validate())
    }
    func testLongNotionSummaryUsesBoundedSegmentsWithoutLosingUnicode() {
        let text = String(repeating: "🙂e\u{301}", count: 2100)
        let segments = ProjectServiceBridge.text(text).array
        XCTAssertGreaterThan(segments.count, 1)
        XCTAssertTrue(segments.allSatisfy { ($0["text"]["content"].string ?? "").utf16.count <= 2000 })
        XCTAssertEqual(segments.map { $0["text"]["content"].display }.joined(), text)
    }

    func testDelayedIdeaAPIResponseCannotUndoCompletedProjectPromotion() throws {
        var record = try make()
        record.localProjectID = "registered-project"
        record.localPath = "/Fixture/Projects/Studio"
        record.set("Local Directory", value: ProjectServiceBridge.text(record.localPath), source: source)
        XCTAssertEqual(try make(existing: record), record)
        XCTAssertFalse(IdeaProjectBridge.canAutomaticallySend(record, source: source))
    }

}
