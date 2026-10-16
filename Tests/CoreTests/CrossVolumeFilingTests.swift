import XCTest
@testable import BetterWorkspaceCore

/// Filing to another drive is a copy, and a copy can be cut off. The destination must
/// never look filed with an incomplete copy, and the original must stay until the copy
/// is known good.
final class CrossVolumeFilingTests: XCTestCase {

    private var root: URL!
    private var workspace: WorkspaceLocation!
    private var inbox: URL!
    private var ingest: IngestService!
    private var tagStore: TagStore!
    private var mountPoint: URL?

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("bw-xvol-\(UUID().uuidString)")
        inbox = root.appendingPathComponent("Inbox", isDirectory: true)
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        try makeWorkspace(at: root.appendingPathComponent("Workspace"))
    }

    override func tearDownWithError() throws {
        if let mountPoint {
            run("/usr/bin/hdiutil", ["detach", mountPoint.path, "-force", "-quiet"])
        }
        try? FileManager.default.removeItem(at: root)
    }

    private func makeWorkspace(at url: URL) throws {
        try FileManager.default.createDirectory(at: url.appendingPathComponent("Ideas"), withIntermediateDirectories: true)
        workspace = WorkspaceLocation(root: url)
        let db = try Database(url: root.appendingPathComponent("db-\(UUID().uuidString).sqlite"))
        tagStore = TagStore(database: db)
        ingest = IngestService(location: IngestLocation(inbox: inbox, backing: .local),
                               database: db, tagStore: tagStore, workspace: workspace)
    }

    @discardableResult
    private func run(_ tool: String, _ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return -1 }
        process.waitUntilExit()
        return process.terminationStatus
    }

    private var ideas: URL { workspace.url(forArea: "Ideas") }

    private func capture(_ name: String, bytes: Int = 200_000) throws -> IngestItem {
        let url = inbox.appendingPathComponent(name)
        try Data(repeating: 0x41, count: bytes).write(to: url)
        return try XCTUnwrap(ingest.importItem(at: url, moveOriginal: true) as IngestItem?)
    }

    private func hiddenEntries(_ directory: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).filter { $0.hasPrefix(".") }
    }

    // MARK: Interruption

    /// The copy dies part-way (a crash, a pulled drive, a full disk).
    func testAnInterruptedCopyLeavesNothingFiledAndKeepsTheOriginal() throws {
        let item = try capture("Big scan.pdf")
        ingest.crossesVolumes = { _, _ in true }
        ingest.copyItem = { source, destination in
            let half = try Data(contentsOf: source).prefix(100_000)
            try half.write(to: destination)
            throw CocoaError(.fileWriteOutOfSpace)
        }

        XCTAssertThrowsError(try ingest.file(item, intoDirectory: ideas, renamingTo: nil))
        XCTAssertFalse(FileManager.default.fileExists(atPath: ideas.appendingPathComponent("Big scan.pdf").path),
                       "Nothing may look filed")
        XCTAssertTrue(hiddenEntries(ideas).isEmpty, "No staging copy is left behind")
        XCTAssertEqual(try Data(contentsOf: item.url).count, 200_000, "The original is untouched")
    }

    /// The copy "succeeds" but is short. Verification must catch it.
    func testACopyThatComesOutShortIsNotFiled() throws {
        let item = try capture("Recording.m4a")
        ingest.crossesVolumes = { _, _ in true }
        ingest.copyItem = { source, destination in
            try Data(contentsOf: source).prefix(10).write(to: destination)
        }
        XCTAssertThrowsError(try ingest.file(item, intoDirectory: ideas, renamingTo: nil)) { error in
            XCTAssertTrue(error.localizedDescription.contains("did not match"), error.localizedDescription)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: ideas.appendingPathComponent("Recording.m4a").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: item.url.path))
        XCTAssertTrue(hiddenEntries(ideas).isEmpty)
    }

    /// Filed fine, but the original could not be removed (a locked inbox, a provider
    /// refusing the delete). Filed is filed; the caller is told the original remains.
    func testAnOriginalThatCannotBeRemovedIsReportedNotLost() throws {
        let item = try capture("Notes.txt", bytes: 50)
        ingest.crossesVolumes = { _, _ in true }
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: inbox.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: inbox.path) }

        let filed = try ingest.file(item, intoDirectory: ideas, renamingTo: nil)
        XCTAssertTrue(filed.originalKept)
        XCTAssertEqual(try Data(contentsOf: filed.destination).count, 50)
        XCTAssertTrue(FileManager.default.fileExists(atPath: item.url.path))
    }

    // MARK: A real second volume

    /// A real disk image as the Workspace: a file and a folder go across, verified, and
    /// tags follow.
    func testFilingOntoAnotherVolumeReallyWorks() throws {
        let image = root.appendingPathComponent("vol.dmg")
        let mount = root.appendingPathComponent("mnt", isDirectory: true)
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
        guard run("/usr/bin/hdiutil", ["create", "-size", "32m", "-fs", "APFS", "-volname", "BWFiling", "-quiet", image.path]) == 0,
              run("/usr/bin/hdiutil", ["attach", image.path, "-nobrowse", "-mountpoint", mount.path, "-quiet"]) == 0
        else { throw XCTSkip("Could not create a disk image here") }
        mountPoint = mount
        try makeWorkspace(at: mount.appendingPathComponent("Workspace"))
        XCTAssertTrue(SafeTransfer.crossesVolumes(inbox, ideas), "precondition: two volumes")

        let file = try capture("Scan.pdf")
        let tag = try XCTUnwrap(tagStore.createTag(named: "Receipts"))
        tagStore.assign(tagID: tag.id, to: file.url, area: nil)
        let filed = try ingest.file(file, intoDirectory: ideas, renamingTo: nil)
        XCTAssertFalse(filed.originalKept)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.url.path), "The original went only after the copy")
        XCTAssertEqual(try Data(contentsOf: filed.destination).count, 200_000)
        XCTAssertEqual(tagStore.tags(for: filed.destination).map(\.name), ["Receipts"])

        let folder = inbox.appendingPathComponent("Project bundle", isDirectory: true)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("sub"), withIntermediateDirectories: true)
        for n in 0..<20 { try Data(repeating: 1, count: 5_000).write(to: folder.appendingPathComponent("sub/f\(n).bin")) }
        let folderItem = try XCTUnwrap(ingest.importItem(at: folder, moveOriginal: true) as IngestItem?)
        let filedFolder = try ingest.file(folderItem, intoDirectory: ideas, renamingTo: nil)
        XCTAssertEqual(SafeTransfer.summary(of: filedFolder.destination), SafeTransfer.Summary(files: 20, bytes: 100_000))
        XCTAssertTrue(hiddenEntries(ideas).isEmpty)
    }

    // MARK: Leftovers from a crash

    private func leftover(source: URL, name: String, verified: Bool, old: Bool = true, marked: Bool = true) throws -> URL {
        let staging = ideas.appendingPathComponent(SafeTransfer.stagingPrefix + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try Data(repeating: 2, count: 300).write(to: staging.appendingPathComponent(name))
        if marked {
            SafeTransfer.setMarker(.init(source: source.path, destinationName: name, verified: verified), on: staging)
        }
        if old {
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -7200)], ofItemAtPath: staging.path)
        }
        return staging
    }

    func testCrashLeftoversAreRemovedOrRecoveredAndNothingElseIsTouched() throws {
        let stillThere = inbox.appendingPathComponent("Still in inbox.pdf")
        try Data([1]).write(to: stillThere)
        let gone = inbox.appendingPathComponent("Deleted since.pdf")

        let redundant = try leftover(source: stillThere, name: "Still in inbox.pdf", verified: false)
        _ = try leftover(source: gone, name: "Only copy.pdf", verified: true)
        _ = try leftover(source: gone, name: "Partial.pdf", verified: false)
        let unmarked = try leftover(source: gone, name: "Someone else's.pdf", verified: true, marked: false)
        let young = try leftover(source: stillThere, name: "In flight.pdf", verified: false, old: false)

        let result = SafeTransfer.cleanUpInterruptedFilings(in: [ideas])
        XCTAssertEqual(result.removed.map(\.lastPathComponent), [redundant.lastPathComponent])
        XCTAssertEqual(Set(result.recovered.map(\.lastPathComponent)), ["Only copy.pdf", "Partial (possibly incomplete).pdf"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: unmarked.path), "Unmarked: not provably ours")
        XCTAssertTrue(FileManager.default.fileExists(atPath: young.path), "Recent: possibly still copying")
        XCTAssertTrue(FileManager.default.fileExists(atPath: stillThere.path))
    }
}
