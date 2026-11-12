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
        let idea = try service.createIdea(named: "Future project")
        XCTAssertEqual(idea.lastPathComponent, "Future project")
        XCTAssertEqual(try String(contentsOf: idea.appendingPathComponent("Future project.md"), encoding: .utf8),
                       "# Future project\n\n")
        let folder = try service.createFolder(named: "Sketches")
        let note = try service.createNote(named: "First thought", in: folder)
        let imported = try service.importItems([outside], into: folder)

        XCTAssertEqual(try String(contentsOf: note), "# First thought\n\n")
        XCTAssertTrue(FileManager.default.fileExists(atPath: imported[0].path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path), "Import copies; it never removes the Finder original")
        XCTAssertThrowsError(try service.importItems([outside], into: root))
    }

    /// Files added at the Ideas root become ideas; images added to an idea become its
    /// attachments and are linked from its note.
    func testImportsKeepTheIdeaLayout() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("bw-ideas-\(UUID().uuidString)")
        let ideas = root.appendingPathComponent("Ideas", isDirectory: true)
        try FileManager.default.createDirectory(at: ideas, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let image = root.appendingPathComponent("Mood board.png")
        try Data([1, 2]).write(to: image)
        let service = IdeaFileService(ideasRoot: ideas)

        let added = try service.importItems([image])
        XCTAssertEqual(added[0].lastPathComponent, "Mood board")
        XCTAssertEqual(try Data(contentsOf: added[0].appendingPathComponent("Attachments/Mood board.png")), Data([1, 2]))
        XCTAssertEqual(try String(contentsOf: added[0].appendingPathComponent("Mood board.md"), encoding: .utf8),
                       "# Mood board\n\n![Mood board](<Attachments/Mood board.png>)\n")
        XCTAssertEqual(try service.importItems([image]).first?.lastPathComponent, "Mood board 2", "Never replaces an idea")

        let idea = try service.createIdea(named: "Studio")
        let attached = try service.importItems([image], into: idea)
        XCTAssertEqual(attached[0].path, idea.appendingPathComponent("Attachments/Mood board.png").path)
        XCTAssertEqual(try String(contentsOf: idea.appendingPathComponent("Studio.md"), encoding: .utf8),
                       "# Studio\n\n\n![Mood board](<Attachments/Mood board.png>)\n")
        XCTAssertTrue(FileManager.default.fileExists(atPath: image.path))
    }
}
