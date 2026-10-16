import XCTest
@testable import BetterWorkspaceCore

final class IdeaFileServiceTests: XCTestCase {
    func testCreatesAndImportsOnlyInsideIdeas() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("bw-ideas-\(UUID().uuidString)")
        let ideas = root.appendingPathComponent("Ideas", isDirectory: true)
        let outside = root.appendingPathComponent("outside.txt")
        try FileManager.default.createDirectory(at: ideas, withIntermediateDirectories: true)
        try "outside".write(to: outside, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: root) }

        let service = IdeaFileService(ideasRoot: ideas)
        let folder = try service.createFolder(named: "Sketches")
        let note = try service.createNote(named: "First thought", in: folder)
        let imported = try service.importItems([outside], into: folder)

        XCTAssertEqual(try String(contentsOf: note), "# First thought\n\n")
        XCTAssertTrue(FileManager.default.fileExists(atPath: imported[0].path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path), "Import copies; it never removes the Finder original")
        XCTAssertThrowsError(try service.importItems([outside], into: root))
    }
}
