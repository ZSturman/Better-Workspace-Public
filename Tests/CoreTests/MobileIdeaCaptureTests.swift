import XCTest
import CryptoKit
@testable import BetterWorkspaceCore

final class MobileIdeaCaptureTests: XCTestCase {
    func testAttachmentHashesAndRetryAfterPublish() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).canonical
        let ideas = root.appendingPathComponent("Ideas")
        try FileManager.default.createDirectory(at: ideas, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = WorkspaceLocation(root: root)
        let checkpoints = root.appendingPathComponent("Private")
        let id = UUID()
        let png = Data([137, 80, 78, 71, 0, 1, 2, 3])
        let file = Data("original attachment bytes\n".utf8)
        let bundle = MobileDownloadBundle(path: MobileIdeaCapture.transferName(id), title: "Same title", files: [
            .init(path: "Note.md", data: Data("# Same title\n\nCaptured offline.".utf8)),
            .init(path: "Drawing.png", data: png),
            .init(path: "Reference.txt", data: file)
        ])
        let asset = root.appendingPathComponent("transfer.plist")
        try bundle.write(to: asset)
        let received = try MobileDownloadBundle.read(from: asset)
        let unrelated = ideas.appendingPathComponent("Same title")
        try FileManager.default.createDirectory(at: unrelated, withIntermediateDirectories: false)

        let published = try MobileIdeaCapture.file(received, id: id, workspace: workspace, checkpointDirectory: checkpoints)
        XCTAssertNotEqual(published, unrelated)
        XCTAssertEqual(try MobileIdeaCapture.file(received, id: id, workspace: workspace, checkpointDirectory: checkpoints), published)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: ideas.path).count, 2)
        for (name, expected) in [("Drawing.png", png), ("Reference.txt", file)] {
            let installed = try Data(contentsOf: published.appendingPathComponent("Attachments/" + name))
            XCTAssertEqual(SHA256.hash(data: installed), SHA256.hash(data: expected))
            let note = try String(contentsOf: published.appendingPathComponent(published.lastPathComponent + ".md"), encoding: .utf8)
            XCTAssertTrue(note.contains("](<Attachments/" + name + ">)"))
        }

        try FileManager.default.moveItem(at: published, to: ideas.appendingPathComponent("Moved in Finder"))
        XCTAssertThrowsError(try MobileIdeaCapture.file(received, id: id, workspace: workspace, checkpointDirectory: checkpoints))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: ideas.path).count, 2)
    }

    func testUnexpectedPayloadCannotWriteAnIdea() throws {
        let id = UUID()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).canonical
        let ideas = root.appendingPathComponent("Ideas")
        try FileManager.default.createDirectory(at: ideas, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for (path, filename) in [("another-transfer", "Image.png"), (MobileIdeaCapture.transferName(id), "nested/Image.png")] {
            let bundle = MobileDownloadBundle(path: path, title: "Invalid", files: [.init(path: filename, data: Data([0]))])
            XCTAssertThrowsError(try MobileIdeaCapture.file(bundle, id: id, workspace: .init(root: root),
                                                            checkpointDirectory: root.appendingPathComponent("Private")))
        }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: ideas.path).isEmpty)
    }
}
