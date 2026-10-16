import XCTest
@testable import BetterWorkspaceCore

/// The last of Better Projects' data: project descriptions (including two edits that
/// never reached Notion) and ratings, carried over without ever overwriting what has
/// been set in Better Workspace since.
final class BetterProjectsMigrationTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("bw-bp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func project(_ name: String, notion: String? = nil, document: String? = nil, in store: ProjectStore) throws -> ProjectRecord {
        let url = root.appendingPathComponent("Projects/\(name)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let record = store.register(url: url, name: name)
        store.setExternalIDs(watcherID: nil, documentID: document, for: record.id)
        if let notion { store.setNotionPageID(notion, for: record.id) }
        return store.record(id: record.id)!
    }

    /// The real shapes: `pendingFieldWrites` from Better Projects' cache.json, a
    /// local-only project named `local-document-<documentID>`, and cached Notion projects.
    private func cache(_ json: [String: Any]) throws -> URL {
        let url = root.appendingPathComponent("cache.json")
        try JSONSerialization.data(withJSONObject: json).write(to: url)
        return url
    }

    func testUnsentEditsReachTheirLocalOnlyProjectAndCachedDescriptionsFillTheRest() throws {
        let store = ProjectStore(database: try Database(inMemory: true))
        let local = try project("16 Personalities", document: "CAE0D2D1-465B-4C43-B255-59DBB00DA6FC", in: store)
        let linked = try project("Folio", notion: "324aec94-4d3c-8068-a8a7-ed6d1d4d1790", in: store)
        let described = try project("Already described", notion: "aaaa", in: store)
        store.setDescription(ProjectDescription(oneLiner: "Written here"), for: described.id)

        let url = try cache([
            "pendingFieldWrites": [
                ["projectID": "local-document-cae0d2d1-465b-4c43-b255-59dbb00da6fc", "propertyName": "one liner",
                 "value": ["richText": ["_0": "A chat-first persona builder."]]],
                ["projectID": "local-document-cae0d2d1-465b-4c43-b255-59dbb00da6fc", "propertyName": "summary",
                 "value": ["richText": ["_0": "A chat-first persona builder, honest about gaps."]]],
                ["projectID": "local-document-00000000-0000-0000-0000-000000000000", "propertyName": "summary",
                 "value": ["richText": ["_0": "No project here"]]],
            ],
            "projects": [
                ["id": "324aec94-4d3c-8068-a8a7-ed6d1d4d1790", "metadata": ["oneLiner": "A portfolio", "summary": ""]],
                ["id": "aaaa", "metadata": ["oneLiner": "From Notion", "summary": "Long form"]],
            ],
        ])

        let preview = LegacyImport.importDescriptions(from: url, into: store, apply: false)
        XCTAssertEqual(preview.described, 3)
        XCTAssertTrue(store.description(for: local.id).isEmpty, "A preview writes nothing")

        let report = LegacyImport.importDescriptions(from: url, into: store, apply: true)
        XCTAssertEqual(report.pendingEditsApplied, 2)
        XCTAssertEqual(report.pendingEditsUnmatched.count, 1)
        XCTAssertEqual(store.description(for: local.id),
                       ProjectDescription(oneLiner: "A chat-first persona builder.",
                                          summary: "A chat-first persona builder, honest about gaps."))
        XCTAssertEqual(store.description(for: linked.id), ProjectDescription(oneLiner: "A portfolio"))
        XCTAssertEqual(store.description(for: described.id),
                       ProjectDescription(oneLiner: "Written here", summary: "Long form"),
                       "What is set here wins; only the blank field is filled")

        let again = LegacyImport.importDescriptions(from: url, into: store, apply: true)
        XCTAssertEqual(again.described, 0, "Running again changes nothing")
    }

    func testRatingsAreFilledButNeverOverwritten() throws {
        let store = ProjectStore(database: try Database(inMemory: true))
        let record = try project("Why is a human construct", notion: "33baec94-4d3c-8016-a557-ffd72e8895e6", in: store)
        store.setRating(5, metricID: "effort", for: record.id)
        let url = try cache(["projects": [
            ["id": "33baec94-4d3c-8016-a557-ffd72e8895e6", "ratings": ["effort": 3, "enjoyment": 3, "knowledgeGain": 2]],
        ]])

        let report = LegacyImport.importRatings(from: url, into: store, apply: true)
        XCTAssertEqual(report.keptExisting, 1)
        XCTAssertEqual(store.ratings(for: record.id), ["effort": 5, "enjoyment": 3, "knowledgeGain": 2])
    }

    func testADescriptionClearedToBlankIsRemoved() throws {
        let store = ProjectStore(database: try Database(inMemory: true))
        let record = try project("Thing", in: store)
        store.setDescription(ProjectDescription(oneLiner: "x", summary: "y"), for: record.id)
        store.setDescription(ProjectDescription(oneLiner: "  ", summary: nil), for: record.id)
        XCTAssertTrue(store.description(for: record.id).isEmpty)
    }
}
