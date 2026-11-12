import XCTest
import Darwin
@testable import BetterWorkspaceCore

final class WorkspaceRootItemTests: XCTestCase {
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bw-root-items-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    func testRootDiscoverySeparatesApplicationsWebpagesAndFilesFromAreas() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        for name in ["Projects", "Custom", "_Group", "Example.app", "_audit"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: false)
        }
        try Data("Original document".utf8).write(to: root.appendingPathComponent("Read me.txt"))
        try Data("[InternetShortcut]\nURL=https://example.com/path?q=one\n".utf8).write(to: root.appendingPathComponent("Site.url"))
        try Data("---\nurl: https://example.com/notes\n---\nA linked note".utf8).write(to: root.appendingPathComponent("Notes.md"))
        let items = try XCTUnwrap(WorkspaceRootDiscovery.items(in: .init(root: root)))
        XCTAssertEqual(items.count, 4)
        XCTAssertEqual(items.first { $0.id == "Example.app" }?.kind, .application)
        XCTAssertEqual(items.first { $0.id == "Site.url" }?.links.first?.host, "example.com")
        XCTAssertEqual(items.first { $0.id == "Notes.md" }?.kind, .webpage)
        XCTAssertEqual(items.first { $0.id == "Read me.txt" }?.kind, .file)
        let folders = try XCTUnwrap(WorkspaceFolderDiscovery().folders(in: .init(root: root), store: .init(url: root.appendingPathComponent(".private-settings.json"))))
        XCTAssertEqual(Set(folders.map(\.name)), ["Projects", "Custom", "_Group"])
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("Read me.txt"), encoding: .utf8), "Original document")
    }
    func testWeblocAndInternetShortcutValidateWholeURLAndRetainInvalidEntries() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("Site.webloc")
        let data = try PropertyListSerialization.data(fromPropertyList: ["URL": "https://example.com/a?x=1&y=2"], format: .binary, options: 0)
        try data.write(to: url)
        XCTAssertEqual(try WorkspaceRootDiscovery.webpageLinks(at: url).first?.path, "/a")
        try Data("[InternetShortcut]\n URL=javascript:alert('https://example.com')".utf8).write(to: root.appendingPathComponent("Unsafe.url"))
        let invalid = try XCTUnwrap(WorkspaceRootDiscovery.items(in: .init(root: root))?.first { $0.id == "Unsafe.url" })
        XCTAssertEqual(invalid.kind, .webpage); XCTAssertTrue(invalid.links.isEmpty); XCTAssertNotNil(invalid.warning)
        XCTAssertEqual(try Data(contentsOf: url), data)
    }
    func testBoundedRegularReadsRefuseSymlinksOversizeAndSpecialFiles() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Original.txt"), link = root.appendingPathComponent("Link.url")
        try Data("https://example.com".utf8).write(to: source)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
        XCTAssertThrowsError(try WorkspaceRootDiscovery.webpageLinks(at: link))
        let large = root.appendingPathComponent("Large.txt"); try Data(repeating: 65, count: 32_769).write(to: large)
        XCTAssertThrowsError(try WorkspaceRootDiscovery.webpageLinks(at: large))
        let fifo = root.appendingPathComponent("Pipe.url"); XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        XCTAssertThrowsError(try WorkspaceRootDiscovery.webpageLinks(at: fifo))
    }
    func testWebPolicyRejectsLocalScriptCredentialAndCustomURLs() {
        for raw in ["file:///etc/passwd", "javascript:alert(1)", "shortcuts://run-shortcut?name=X", "https://user:password@example.com", "https:///", "https://example.com:99999", "about:blank"] {
            XCTAssertNil(WorkspaceWebPolicy.webpage(raw), raw)
        }
        XCTAssertTrue(WorkspaceWebPolicy.allowsNavigation(URL(string: "about:blank")!))
        XCTAssertNotNil(WorkspaceWebPolicy.webpage(" HTTPS://example.com/path?q=one "))
    }
    func testNamedShortcutCannotInjectInputOrClipboardParameters() throws {
        let name = "Review & input=clipboard # notes"
        let url = try XCTUnwrap(WorkspaceWebPolicy.shortcut(named: name))
        let parts = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(parts.host, "run-shortcut")
        XCTAssertEqual(parts.queryItems, [.init(name: "name", value: name)])
        XCTAssertNil(WorkspaceWebPolicy.shortcut(named: "  "))
    }
    func testDeclaredAppSymlinkResolvesButMissingRootIsUnavailable() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("Target.app"), link = root.appendingPathComponent("Linked.app")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        XCTAssertEqual(WorkspaceRootDiscovery.applicationURL(for: link)?.resolvingSymlinksInPath(), target.resolvingSymlinksInPath())
        XCTAssertNil(WorkspaceRootDiscovery.items(in: .init(root: root.appendingPathComponent("Unavailable"))))
    }
}
