import XCTest
@testable import BetterWorkspaceCore

final class ProjectPropertiesTests: XCTestCase {
    func testLegacyPortfolioAndRevisionDecodeWithoutLosingLinks() throws {
        let old = Data(#"{"githubURL":"https://github.com/example/repo","resourceReferences":["resource"]}"#.utf8)
        let details = try JSONDecoder().decode(ProjectPortfolioDetails.self, from: old)
        XCTAssertEqual(details.githubURL, "https://github.com/example/repo")
        XCTAssertEqual(details.resourceReferences, ["resource"]); XCTAssertNil(details.featured)
        let content = try JSONDecoder().decode(WorkspaceRecordContent.self, from: Data(#"{"kind":"project","title":"Earlier","body":"","isComplete":false,"isDeleted":false}"#.utf8))
        XCTAssertNil(content.projectMetadata); XCTAssertNil(content.projectLinks)
    }
    func testTypesNormalizeLikeTagsAndKeepFirstSpelling() {
        XCTAssertEqual(ProjectProperties.types(" Animation, animation, ART, Arts, Machine-Learning, machine learning, ,Collection"), ["Animation", "ART", "Machine-Learning", "Collection"])
    }
    func testSparsePortfolioEditsPreserveConcurrentFieldsAndRejectSameFieldConflict() throws {
        let original = ProjectPortfolioDetails(githubURL: "https://github.com/example/repo", resourceReferences: ["r"])
        var desired = original; desired.featured = true
        var current = original; current.websiteURL = "https://example.com"; current.mediaReferences = ["m"]
        let result = try ProjectProperties.merging(desired, original: original, current: current)
        XCTAssertEqual(result.featured, true); XCTAssertEqual(result.websiteURL, current.websiteURL)
        XCTAssertEqual(result.mediaReferences, ["m"]); XCTAssertEqual(result.resourceReferences, ["r"])
        desired.websiteURL = "https://new.example.com"
        XCTAssertThrowsError(try ProjectProperties.merging(desired, original: original, current: current))
    }
    func testLinksAllowOnlyNamedWebURLs() throws {
        var details = ProjectPortfolioDetails(); details.customLinks = [.init(label: "App Store", url: "https://apps.apple.com/app/id123")]
        try ProjectProperties.validate(details)
        let envelope = MobileProjectDetails(path: "Projects/P", portfolio: details)
        XCTAssertEqual(MobileProjectEnvelope.decode(MobileProjectEnvelope.encode(envelope))?.portfolio, details)
        for url in ["file:///etc/passwd", "javascript:alert(1)", "https://", "example.com"] {
            details.customLinks = [.init(label: "Other", url: url)]
            XCTAssertThrowsError(try ProjectProperties.validate(details))
        }
    }
    func testMobilePortfolioSavePersistsAfterReopenAndIsRetryable() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bw-properties-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Projects/P"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("private.sqlite")
        let store = ProjectStore(database: try Database(url: url)), record = store.register(url: root.appendingPathComponent("Projects/P"))
        store.setPortfolioDetails(.init(resourceReferences: ["keep"]), for: record.id)
        let original = MobileProjectDetails(path: "Projects/P", projectID: record.id, ratings: [:], portfolio: store.portfolioDetails(for: record.id))
        var properties = MobileProjectProperties(original)
        properties.domain = "Art"; properties.projectType = "Animation, Collection"
        properties.portfolio?.featured = true; properties.portfolio?.inShowcase = true; properties.portfolio?.isPublic = false
        properties.portfolio?.customLinks = [.init(label: "Notion", url: "https://notion.so/example")]
        let edit = MobileProjectEdit(original: original, ratings: [:], oneLiner: "", summary: "", properties: properties)
        try store.saveMobileProject(edit); try store.saveMobileProject(edit)
        let reopened = ProjectStore(database: try Database(url: url))
        XCTAssertEqual(reopened.portfolioDetails(for: record.id), properties.portfolio)
        XCTAssertEqual(reopened.metadata(for: record.id).domain, "Art")
        XCTAssertEqual(reopened.portfolioDetails(for: record.id).resourceReferences, ["keep"])
        var off = MobileProjectProperties(MobileProjectDetails(path: "Projects/P", domain: "Art", projectID: record.id, ratings: [:], projectType: "Animation, Collection", portfolio: properties.portfolio))
        let before = MobileProjectDetails(path: "Projects/P", domain: "Art", projectID: record.id, ratings: [:], projectType: "Animation, Collection", portfolio: properties.portfolio)
        off.portfolio?.featured = false
        try reopened.saveMobileProject(.init(original: before, ratings: [:], oneLiner: "", summary: "", properties: off))
        XCTAssertEqual(ProjectStore(database: try Database(url: url)).portfolioDetails(for: record.id).featured, false)
    }
    func testProjectQueryFiltersSortsAndGroupsHundredsOfRecords() {
        let entries = (0..<500).map { index -> MobileWorkspaceEntry in
            var portfolio = ProjectPortfolioDetails(); portfolio.featured = index.isMultiple(of: 2)
            return .init(path: "Projects/P\(index)", parentPath: "Projects", name: "P\(index)", isDirectory: true, revision: 0,
                projectDetails: .init(path: "Projects/P\(index)", domain: index.isMultiple(of: 2) ? "Art" : "Tech", status: "Active", projectType: "Animation, Collection", portfolio: portfolio))
        }
        var query = MobileBrowseQuery(); query.domain = "árt"; query.status = "active"; query.featured = true; query.projectType = "animations"; query.group = .status; query.sort = .name; query.ascending = true
        let groups = query.projects(entries)
        XCTAssertEqual(groups.count, 1); XCTAssertEqual(groups.first?.title, "Active"); XCTAssertEqual(groups.first?.items.count, 250)
        XCTAssertEqual(groups.first?.items.prefix(3).map(\.name), ["P0", "P2", "P4"])
        query.group = .domain; query.domain = ""; query.featured = nil; query.sort = .domain
        XCTAssertEqual(query.projects(entries).map(\.title), ["Art", "Tech"])
        let row = ProjectProperties.queryRecord(id: "a", name: "A", metadata: .init(), portfolio: .init())
        XCTAssertTrue(ProjectViewQuery.matches(row, query: "", filters: [.init(field: "domain", values: ["Not set"])]))
    }
    func testGroupedProjectPreviewValidationAcceptsPhysicalPath() throws {
        let entry = MobileWorkspaceEntry(path: "Projects/_Art/P", parentPath: "Projects/_Art", name: "P", isDirectory: true, revision: 0)
        try MobilePlanningFiles.validate(.init(operation: .previewProject, title: "P", originalEntry: entry))
    }
    func testProjectAdapterPersistsMetadataAndRefusesRenameOrStaleSource() throws {
        let sourceID = UUID().uuidString, device = UUID()
        let entry = MobileWorkspaceEntry(path: "Projects/P", parentPath: "Projects", name: "P", isDirectory: true, revision: 0, projectDetails: .init(path: "Projects/P", projectID: sourceID, ratings: [:]))
        let observation = try WorkspaceMacProjection.observe(.init(entries: [entry]), in: WorkspaceReplica(), bindings: [], deviceID: device)
        let binding = try XCTUnwrap(observation.bindings.first)
        var graph = observation.replica, content = try XCTUnwrap(graph.records.first?.resolved?.content)
        content.projectMetadata = .init(domain: "Art", status: "Active", projectType: "Animation, Collection")
        var portfolio = ProjectPortfolioDetails(); portfolio.featured = true; content.projectLinks = portfolio
        let saved = try graph.save(recordID: binding.recordID, content: content, expectedHeads: [binding.observedRevisionID], deviceID: device, origin: .iOS)
        let edit = try XCTUnwrap(WorkspaceMacProjection.prepareProjectSave(binding: binding, in: graph, current: entry))
        XCTAssertEqual(edit.properties?.domain, "Art"); XCTAssertEqual(edit.properties?.portfolio?.featured, true)
        let applied = MobileWorkspaceEntry(path: entry.path, parentPath: entry.parentPath, name: entry.name, isDirectory: true, revision: 0, projectDetails: .init(path: entry.path, domain: "Art", status: "Active", projectID: sourceID, ratings: [:], projectType: "Animation, Collection", portfolio: portfolio))
        XCTAssertNil(try WorkspaceMacProjection.prepareProjectSave(binding: binding, in: graph, current: applied))
        let stale = MobileWorkspaceEntry(path: entry.path, parentPath: entry.parentPath, name: entry.name, isDirectory: true, revision: 0, projectDetails: .init(path: entry.path, domain: "Concurrent edit", projectID: sourceID, ratings: [:]))
        XCTAssertThrowsError(try WorkspaceMacProjection.prepareProjectSave(binding: binding, in: graph, current: stale))
        content.title = "Rename"
        _ = try graph.save(recordID: binding.recordID, content: content, expectedHeads: [saved.id], deviceID: device, origin: .iOS)
        XCTAssertThrowsError(try WorkspaceMacProjection.prepareProjectSave(binding: binding, in: graph, current: entry))
    }
    func testPortableMetadataSurvivesJournalReloadAndConcurrentStarEditIsConflict() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bw-project-journal-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = WorkspaceReplicaStore(directory: root, initialWorkspaceID: UUID())
        var graph = try store.load(), portfolio = ProjectPortfolioDetails(); portfolio.featured = true
        let revision = try store.save(content: .init(kind: .project, title: "P", projectMetadata: .init(domain: "Art"), projectLinks: portfolio), expectedHeads: [], deviceID: UUID(), origin: .iOS)
        graph = try store.load()
        XCTAssertEqual(try store.load().records.first?.resolved?.content.projectLinks?.featured, true)
        var other = graph, content = revision.content; content.projectLinks?.featured = false
        _ = try other.save(recordID: revision.recordID, content: content, expectedHeads: [revision.id], deviceID: UUID(), origin: .mac)
        content.projectMetadata?.status = "Active"
        _ = try graph.save(recordID: revision.recordID, content: content, expectedHeads: [revision.id], deviceID: UUID(), origin: .iOS)
        XCTAssertTrue(try graph.merging(other).records.first!.isConflict)
    }
}


extension ProjectPropertiesTests {
    func testExistingGraphFlagsUseTheSamePortfolioFieldsAndSparseImportsPreserveThem() {
        let page = NotionPage(id: "p", properties: ["Featured": .flag(true), "In Showcase": .flag(false), "Public": .flag(true)])
        let values = ProjectMetadataImport.values(from: page)
        var local = ProjectPortfolioDetails(resourceReferences: ["keep"])
        local.customLinks = [.init(label: "Other", url: "https://example.com")]
        let applied = ProjectMetadataImport.applying(ProjectMetadataImport.suppliedFields(propertyNames: ["Featured", "In Showcase", "Public"]), values: values, to: .init(), description: .init(), portfolioDetails: local).portfolioDetails
        XCTAssertEqual(applied.featured, true); XCTAssertEqual(applied.inShowcase, false); XCTAssertEqual(applied.isPublic, true)
        XCTAssertEqual(applied.resourceReferences, ["keep"]); XCTAssertEqual(applied.customLinks, local.customLinks)
        let unchanged = ProjectMetadataImport.applying(ProjectMetadataImport.suppliedFields(propertyNames: ["Personal Value"]), values: .init(), to: .init(), description: .init(), portfolioDetails: applied).portfolioDetails
        XCTAssertEqual(unchanged, applied)
        let wrongType = ProjectMetadataImport.values(from: NotionPage(id: "p", properties: ["Featured": .choice("Other meaning")]))
        XCTAssertEqual(ProjectMetadataImport.applying([.featured], values: wrongType, to: .init(), description: .init(), portfolioDetails: applied).portfolioDetails.featured, true)
    }
}
