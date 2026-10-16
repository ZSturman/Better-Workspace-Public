import XCTest
@testable import BetterWorkspaceCore

final class CaptureDraftTests: XCTestCase {
    func testMarkdownIsNotRewritten() throws {
        let body = "\n- [ ] **First task**\n\n```swift\nlet x = 1\n```\n"
        let document = try XCTUnwrap(CaptureDraftEntry(title: "My tasks", content: .markdown(body)).document)
        XCTAssertEqual(String(data: document.data, encoding: .utf8), body)
        XCTAssertEqual(document.name, "My tasks")
    }

    func testPortableLinkRoundTripAndURLValidation() throws {
        let link = try WorkspaceLink(id: "fixture-id", title: "Quotes \" / Unicode 🐈", url: "example.com/watch?a=1&b=2", notes: "## Notes\n\n**Keep** this\n")
        XCTAssertEqual(link.url, "https://example.com/watch?a=1&b=2")
        XCTAssertEqual(try WorkspaceLink.parse(link.markdown), link)
        XCTAssertThrowsError(try WorkspaceLink(title: "", url: "javascript:alert(1)"))
        XCTAssertThrowsError(try WorkspaceLink(title: "", url: "https://example.com/a b"))
        XCTAssertThrowsError(try WorkspaceLink.parse("# Ordinary note\nhttps://example.com"))
        XCTAssertEqual(try WorkspaceLink(title: "", url: "https://example.com/path").title, "example.com")
    }

    func testURLPastedIntoMarkdownBecomesAReviewableLink() throws {
        let entry = try XCTUnwrap(CaptureDraftEntry.note(title: "", markdown: "https://example.com/watch\n", url: ""))
        let document = try XCTUnwrap(entry.document)
        XCTAssertEqual(try WorkspaceLink.parse(String(decoding: document.data, as: UTF8.self)).url, "https://example.com/watch")
        let markdown = "https://example.com\n\nThis is a plain note."
        XCTAssertEqual(String(decoding: try XCTUnwrap(CaptureDraftEntry.note(title: "", markdown: markdown, url: "")?.document).data, as: UTF8.self), markdown)
    }

    #if os(macOS)
    func testSharedLuaFixture() throws {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/workspace-link-v1.md")
        let parsed = try WorkspaceLink.parse(String(contentsOf: file))
        XCTAssertEqual(parsed.id, "shared-fixture-id")
        XCTAssertEqual(parsed.title, "Quoted \"title\" 🐈")
        XCTAssertEqual(parsed.notes, "## Notes\n\n- [ ] Keep **Markdown** intact.\n")
    }
    #endif

    func testMobileBatchRetainsSuccessWhenAnotherFileFails() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bw-batch-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("original.png")
        let bytes = Data([1, 2, 3, 4])
        try bytes.write(to: source)
        let inbox = root.appendingPathComponent("Inbox")
        let service = MobileCaptureService(inbox: inbox)
        let first = CaptureDraftEntry(title: "Titled image", content: .file(source))
        let bad = CaptureDraftEntry(content: .file(root.appendingPathComponent("missing.png")))
        let result = service.capture([first, bad])
        XCTAssertEqual(result.saved.map(\.id), [first.id])
        XCTAssertEqual(result.failures.map(\.id), [bad.id])
        XCTAssertEqual(result.saved.first?.url.lastPathComponent, "Titled image.png")
        XCTAssertEqual(try Data(contentsOf: source), bytes)
        XCTAssertEqual(try Data(contentsOf: result.saved[0].url), bytes)
        let next = service.capture([first])
        XCTAssertEqual(next.saved.first?.url.lastPathComponent, "Titled image 2.png")
    }

    func testRetryOnlyFailedBatchEntriesDoesNotDuplicateSuccess() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bw-retry-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let missing = root.appendingPathComponent("later.jpg")
        let entries = [CaptureDraftEntry(title: "Saved note", content: .markdown("**Keep**\n")),
                       CaptureDraftEntry(title: "Recovered image", content: .file(missing))]
        let inbox = root.appendingPathComponent("Inbox")
        let service = MobileCaptureService(inbox: inbox)
        let first = service.capture(entries)
        XCTAssertEqual(first.saved.count, 1)
        XCTAssertEqual(first.failures.count, 1)
        let bytes = Data([5, 6, 7])
        try bytes.write(to: missing)
        let failedIDs = Set(first.failures.map(\.id))
        let retry = service.capture(entries.filter { failedIDs.contains($0.id) })
        XCTAssertEqual(retry.saved.count, 1)
        XCTAssertTrue(retry.failures.isEmpty)
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: inbox.path)),
                       ["Saved note.md", "Recovered image.jpg"])
        XCTAssertEqual(try Data(contentsOf: retry.saved[0].url), bytes)
    }
}
