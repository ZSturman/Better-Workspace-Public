import XCTest
import Network
@testable import BetterWorkspaceCore

final class LMStudioTests: XCTestCase {
    private let tag = Tag(id: "tag-ai", name: "AI")
    private var input: LMStudioInput { LMStudioInput(name: "Fixture garden", description: ProjectDescription(oneLiner: "Old line", summary: "A native gardening journal."), assignedTags: [], catalog: [tag]) }
    private func prepared(schema: Bool = false) throws -> LMStudioPreparedRequest {
        try LMStudioRequest.prepare(endpoint: "http://127.0.0.1:1234/v1", model: "fixture-model", input: input, schema: schema)
    }
    private func response(_ content: String) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": content], "finish_reason": "stop"]]])
    }
    private func http(_ request: URLRequest, status: Int = 200) -> HTTPURLResponse { HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)! }
    private let valid = #"{"one_liner":"A native garden journal.","existing_tag_ids":["tag-ai"],"new_tags":[]}"#

    func testExactPreviewAndAllowlistedInputs() async throws {
        let prepared = try prepared(schema: true)
        XCTAssertEqual(prepared.request.httpBody, Data(prepared.preview.utf8))
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: prepared.request.httpBody!) as? [String: Any])
        XCTAssertEqual(body["model"] as? String, "fixture-model")
        XCTAssertEqual(body["stream"] as? Bool, false)
        XCTAssertNotNil(body["response_format"])
        let messages = try XCTUnwrap(body["messages"] as? [[String: String]])
        let metadata = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(messages[1]["content"]!.utf8)) as? [String: Any])
        XCTAssertEqual(Set(metadata.keys), ["project_name", "current_one_liner", "summary", "category", "domain", "assigned_tag_names", "existing_tags", "additional_context", "requested"])
        XCTAssertFalse(prepared.preview.contains("/Users/"))
        let data = try response(valid)
        let client = LMStudioClient { request, _ in
            if request.url?.lastPathComponent == "models" { return (Data(#"{"models":[{"key":"fixture-model","type":"llm"}]}"#.utf8), self.http(request)) }
            XCTAssertEqual(request.httpBody, prepared.request.httpBody)
            return (data, self.http(request))
        }
        let result = try await client.generate(prepared)
        XCTAssertEqual(result.tags.first?.existingID, tag.id)
    }

    func testPresetAndRemovedModelNeverGenerate() async throws {
        XCTAssertEqual(LMStudioPreset.choose(saved: "saved", available: ["saved", LMStudioPreset.preferredModel]), "saved")
        XCTAssertEqual(LMStudioPreset.choose(saved: "missing", available: ["z", LMStudioPreset.preferredModel]), LMStudioPreset.preferredModel)
        XCTAssertEqual(LMStudioPreset.choose(saved: "missing", available: ["z", "a"]), "a")
        XCTAssertNil(LMStudioPreset.choose(saved: "missing", available: []))
        let client = LMStudioClient { request, _ in
            XCTAssertEqual(request.httpMethod ?? "GET", "GET", "A removed model must never receive a generation request")
            return (Data(#"{"models":[{"key":"other","type":"llm"}]}"#.utf8), self.http(request))
        }
        do { _ = try await client.generate(prepared()); XCTFail() }
        catch { XCTAssertEqual(error as? LMStudioError, .invalidModel) }
    }

    func testEndpointValidation() throws {
        for value in ["http://example.com/v1", "file:///v1", "http://127.0.0.1:1234", "http://user:secret@localhost/v1", "http://localhost/v1?key=x", "http://localhost/v1#x", "http://localhost/%76%31", "http://localhost:0/v1"] {
            XCTAssertThrowsError(try LMStudioRequest.root(value), value)
        }
        for value in ["http://127.0.0.1:1234/v1", "http://localhost/v1/", "http://[::1]:1234/v1", "https://localhost/v1"] { XCTAssertNoThrow(try LMStudioRequest.root(value)) }
    }

    func testBoundsAndTruncationAreVisible() throws {
        var input = input; input.context = String(repeating: "x", count: 4200); input.description.summary = String(repeating: "y", count: 6200)
        input.catalog = (0..<205).map { Tag(id: "id-\($0)", name: String(format: "Tag %03d", $0)) }
        let request = try LMStudioRequest.prepare(endpoint: "http://localhost/v1", model: "m", input: input)
        XCTAssertEqual(request.notices.count, 3)
        XCTAssertFalse(request.preview.contains("id-204"))
        XCTAssertThrowsError(try LMStudioRequest.prepare(endpoint: "http://localhost/v1", model: "", input: input))
    }

    func testTagEquivalenceDeduplicationAndUnknownIDs() throws {
        let tags = [tag, Tag(id: "tag-ml", name: "Machine Learning"), Tag(id: "tag-projects", name: "Projects")]
        let output = #"{"one_liner":"","existing_tag_ids":["tag-ai","tag-ai"],"new_tags":[{"name":"machine-learning","reason":"Equivalent"},{"name":"project","reason":"Equivalent"},{"name":"Plant care","reason":"No existing tag describes plant care."}]}"#
        let result = try LMStudioRequest.resolve(content: output, catalog: tags)
        XCTAssertEqual(result.tags.count, 4)
        XCTAssertEqual(result.tags[1].existingID, "tag-ml")
        XCTAssertEqual(result.tags[2].existingID, "tag-projects")
        XCTAssertTrue(result.tags[3].isNew)
        let fullCatalogResult = try LMStudioRequest.resolve(content: #"{"one_liner":"","existing_tag_ids":[],"new_tags":[{"name":"machine-learning","reason":"Not in the supplied subset."}]}"#, catalog: [tag], existingCatalog: tags)
        XCTAssertEqual(fullCatalogResult.tags.first?.existingID, "tag-ml")
        XCTAssertThrowsError(try LMStudioRequest.resolve(content: valid.replacingOccurrences(of: "tag-ai", with: "unknown"), catalog: tags))
    }

    func testMalformedTruncatedAndUnrequestedFieldsRejected() async throws {
        for content in ["some prose {}", #"{"one_liner":"hello"}"#, valid.replacingOccurrences(of: "A native garden journal.", with: String(repeating: "a", count: 241))] {
            XCTAssertThrowsError(try LMStudioRequest.resolve(content: content, catalog: [tag]))
        }
        XCTAssertThrowsError(try LMStudioRequest.resolve(content: valid, catalog: [tag], oneLiner: false))
        XCTAssertThrowsError(try LMStudioRequest.resolve(content: valid.replacingOccurrences(of: "{", with: "{\"unexpected\":true,", options: [], range: valid.startIndex..<valid.index(after: valid.startIndex)), catalog: [tag]))
        let client = LMStudioClient { request, _ in
            if request.url?.lastPathComponent == "models" { return (Data(#"{"models":[{"key":"fixture-model","type":"llm"}]}"#.utf8), self.http(request)) }
            return (Data(#"{"choices":[{"message":{"content":"{}"},"finish_reason":"length"}]}"#.utf8), self.http(request))
        }
        do { _ = try await client.generate(prepared()); XCTFail() } catch { XCTAssertTrue(error is LMStudioError) }
    }

    func testDiscoveryHTTPFailureAndResponseLimit() async throws {
        let client = LMStudioClient { request, _ in
            XCTAssertEqual(request.url?.path, "/api/v1/models")
            return (Data(#"{"models":[{"key":"z","type":"llm"},{"key":"a","type":"llm"},{"key":"a","type":"llm"},{"key":"embedding","type":"embedding"}]}"#.utf8), self.http(request))
        }
        let models = try await client.models(endpoint: "http://localhost/v1")
        XCTAssertEqual(models, ["a", "z"])
        for status in [400, 503, 302] {
            let failed = LMStudioClient { request, _ in (Data(), self.http(request, status: status)) }
            do { _ = try await failed.generate(prepared(schema: true)); XCTFail() } catch { XCTAssertEqual(error as? LMStudioError, .http(status)) }
        }
        let large = LMStudioClient { request, limit in (Data(repeating: 0, count: limit + 1), self.http(request)) }
        do { _ = try await large.generate(prepared()); XCTFail() } catch { XCTAssertEqual(error as? LMStudioError, .tooLarge) }
    }

    func testCancellationConcurrencyAndTimeoutRecovery() async throws {
        let entered = expectation(description: "Transport entered")
        let client = LMStudioClient { request, _ in
            entered.fulfill()
            try await Task.sleep(for: .seconds(30))
            return (Data(), self.http(request))
        }
        let request = try prepared()
        let task = Task { try await client.generate(request) }
        await fulfillment(of: [entered], timeout: 3)
        do { _ = try await client.generate(request); XCTFail() } catch { XCTAssertEqual(error as? LMStudioError, .busy) }
        task.cancel()
        do { _ = try await task.value; XCTFail() } catch { XCTAssertTrue(error is CancellationError) }
        let timeout = LMStudioClient { _, _ in throw URLError(.timedOut) }
        for _ in 0..<2 {
            do { _ = try await timeout.generate(request); XCTFail() } catch { XCTAssertEqual((error as? URLError)?.code, .timedOut) }
        }
    }

    func testRealTransportRefusesRedirectAndBoundsStream() async throws {
        for (headers, expected) in [("302 Found\r\nLocation: http://127.0.0.1:1/v1/chat/completions\r\nContent-Length: 0", LMStudioError.http(302)),
                                    ("200 OK\r\nContent-Length: 101", LMStudioError.tooLarge)] {
            let server = try LocalFixtureHTTP(headers: headers)
            defer { server.stop() }
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(server.port)/v1/models")!)
            request.timeoutInterval = 3
            do { _ = try await LMStudioClient.localTransport(request, 100); XCTFail() } catch { XCTAssertEqual(error as? LMStudioError, expected) }
        }
    }
}

/// Disposable loopback server: no shared preferences, model or project data.
private final class LocalFixtureHTTP: @unchecked Sendable {
    private let listener: NWListener
    let port: UInt16
    init(headers: String) throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: parameters)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in if case .ready = state { ready.signal() }; if case .failed = state { ready.signal() } }
        listener.newConnectionHandler = { connection in
            connection.start(queue: .global())
            connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { _, _, _, _ in
                connection.send(content: Data(("HTTP/1.1 \(headers)\r\nConnection: close\r\n\r\n" + (headers.contains("101") ? String(repeating: "x", count: 101) : "")).utf8), completion: .contentProcessed { _ in connection.cancel() })
            }
        }
        listener.start(queue: .global())
        guard ready.wait(timeout: .now() + 3) == .success, let port = listener.port else { listener.cancel(); throw URLError(.cannotConnectToHost) }
        self.port = port.rawValue
    }
    func stop() { listener.cancel() }
}

final class ProjectMetadataSuggestionTests: XCTestCase {
    private var root: URL!
    private var database: Database!
    private var project: ProjectRecord!
    private var projects: ProjectStore!
    private var tags: TagStore!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("bw-lm-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Project"), withIntermediateDirectories: true)
        try "untouched".write(to: root.appendingPathComponent("Project/README.md"), atomically: true, encoding: .utf8)
        database = try Database(url: root.appendingPathComponent("private.sqlite"))
        projects = ProjectStore(database: database); tags = TagStore(database: database)
        project = try XCTUnwrap(projects.register(url: root.appendingPathComponent("Project")))
        projects.setDescription(ProjectDescription(oneLiner: "Original", summary: "Preserved summary"), for: project.id)
    }
    override func tearDownWithError() throws { database = nil; projects = nil; tags = nil; try FileManager.default.removeItem(at: root) }
    private var baseline: ProjectSuggestionBaseline {
        ProjectSuggestionBaseline(projectID: project.id, path: project.lastPath, description: projects.description(for: project.id), metadata: projects.metadata(for: project.id), assignedTagIDs: Set(tags.tags(for: project.url).map(\.id)))
    }
    func testApplyRequiresNewApprovalAndRollsBackAllChanges() throws {
        let proposed = try LMStudioRequest.resolve(content: #"{"one_liner":"New","existing_tag_ids":[],"new_tags":[{"name":"Plants","reason":"No fitting existing tag."}]}"#, catalog: []).tags
        XCTAssertThrowsError(try ProjectMetadataSuggestions.apply(database: database, baseline: baseline, oneLiner: "New", tags: proposed, approvedNewTagIDs: []))
        XCTAssertEqual(projects.description(for: project.id).oneLiner, "Original")
        XCTAssertTrue(tags.allTags().isEmpty)
        let fields = try ProjectMetadataSuggestions.apply(database: database, baseline: baseline, oneLiner: "New", tags: proposed, approvedNewTagIDs: [proposed[0].id])
        XCTAssertEqual(fields, ["one liner", "tags"])
        XCTAssertEqual(projects.description(for: project.id), ProjectDescription(oneLiner: "New", summary: "Preserved summary"))
        XCTAssertEqual(tags.tags(for: project.url).map(\.name), ["Plants"])
        XCTAssertEqual(try String(contentsOf: project.url.appendingPathComponent("README.md")), "untouched")
    }
    func testConcurrentEquivalentTagReusedAndOtherProjectsUntouched() throws {
        let original = baseline
        let proposed = try LMStudioRequest.resolve(content: #"{"one_liner":"","existing_tag_ids":[],"new_tags":[{"name":"machine-learning","reason":"No fitting tag."}]}"#, catalog: []).tags
        let existing = try XCTUnwrap(tags.createTag(named: "Machine Learning"))
        let otherURL = root.appendingPathComponent("Other")
        try FileManager.default.createDirectory(at: otherURL, withIntermediateDirectories: true)
        let other = try XCTUnwrap(projects.register(url: otherURL))
        try ProjectMetadataSuggestions.apply(database: database, baseline: original, oneLiner: nil, tags: proposed, approvedNewTagIDs: [proposed[0].id])
        XCTAssertEqual(tags.allTags().count, 1)
        XCTAssertEqual(tags.tags(for: project.url).map(\.id), [existing.id])
        XCTAssertTrue(tags.tags(for: other.url).isEmpty)
        XCTAssertEqual(projects.description(for: other.id), ProjectDescription())
        let reopened = try Database(url: root.appendingPathComponent("private.sqlite"))
        XCTAssertEqual(TagStore(database: reopened).tags(for: project.url).map(\.id), [existing.id])
    }
    func testStaleDetailsAndRenamedTagRefused() throws {
        let original = baseline
        projects.setDescription(ProjectDescription(oneLiner: "Edited elsewhere"), for: project.id)
        XCTAssertThrowsError(try ProjectMetadataSuggestions.apply(database: database, baseline: original, oneLiner: "New", tags: [], approvedNewTagIDs: []))
        let existing = try XCTUnwrap(tags.createTag(named: "AI"))
        let proposal = try LMStudioRequest.resolve(content: "{\"one_liner\":\"\",\"existing_tag_ids\":[\"\(existing.id)\"],\"new_tags\":[]}", catalog: [existing]).tags
        tags.renameTag(id: existing.id, to: "Renamed")
        XCTAssertThrowsError(try ProjectMetadataSuggestions.apply(database: database, baseline: baseline, oneLiner: nil, tags: proposal, approvedNewTagIDs: []))
    }
}
