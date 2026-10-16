import XCTest
@testable import BetterWorkspaceCore

/// What happens to a person's data when the app and something else — Finder, another
/// editor, a sync provider — both touch the same file.
final class DataLifecycleTests: XCTestCase {

    private var root: URL!
    private let service = WorkItemService()

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("bw-lifecycle-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func created(_ title: String = "Ship it") throws -> WorkItem {
        try service.create(WorkItem(kind: .task, title: title, url: root.appendingPathComponent("x.bw.md")), in: root)
    }

    private func xattr(_ url: URL, _ name: String) -> String? {
        let length = getxattr(url.path, name, nil, 0, 0, 0)
        guard length > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: length)
        getxattr(url.path, name, &buffer, length, 0, 0)
        return String(decoding: buffer, as: UTF8.self)
    }

    // MARK: Work items

    /// Someone added fields this app doesn't know about. Saving must not delete them.
    func testSavingKeepsFrontMatterThisAppDoesNotKnow() throws {
        let item = try created()
        var text = try String(contentsOf: item.url, encoding: .utf8)
        text = text.replacingOccurrences(of: "better-workspace: 1\n",
                                          with: "better-workspace: 1\nestimate: 2h\ntags: [home, garden]\n")
        try text.write(to: item.url, atomically: true, encoding: .utf8)

        let reread = try XCTUnwrap(service.read(at: item.url))
        _ = try service.complete(reread)

        let saved = try String(contentsOf: item.url, encoding: .utf8)
        XCTAssertTrue(saved.contains("estimate: 2h"), saved)
        XCTAssertTrue(saved.contains("tags: [home, garden]"), saved)
        XCTAssertTrue(saved.contains("status: completed"), saved)
    }

    /// Extended attributes (quarantine, provenance, other tools' markers) belong to the
    /// file, and a save is not a reason to strip them.
    func testSavingKeepsExtendedAttributesAndCreationDate() throws {
        let item = try created()
        _ = "kept".withCString { setxattr(item.url.path, "com.example.marker", $0, 4, 0, 0) }
        var values = URLResourceValues()
        values.creationDate = Date(timeIntervalSince1970: 1_600_000_000)
        var url = item.url
        try url.setResourceValues(values)

        let reread = try XCTUnwrap(service.read(at: item.url))
        var edited = reread
        edited.title = "Ship it today"
        _ = try service.update(edited)

        XCTAssertEqual(xattr(item.url, "com.example.marker"), "kept")
        XCTAssertEqual(try item.url.resourceValues(forKeys: [.creationDateKey]).creationDate,
                       Date(timeIntervalSince1970: 1_600_000_000))
    }

    /// The editor held a snapshot; the file then moved or vanished in Finder. Saving
    /// must say that plainly and must not recreate the file where it used to be.
    func testSavingAfterTheFileWasRemovedSaysSoAndWritesNothing() throws {
        let item = try created()
        try FileManager.default.removeItem(at: item.url)
        var edited = item
        edited.title = "Changed"
        XCTAssertThrowsError(try service.update(edited)) { error in
            guard case WorkItemService.WorkItemError.missing = error else {
                return XCTFail("Expected .missing, got \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: item.url.path),
                       "A save must not resurrect a file someone deleted")
    }

    func testRestorePutsADeletedRecordBackAtItsOriginalPathWithoutOverwriting() throws {
        let item = try created("Restore me")
        try FileManager.default.removeItem(at: item.url)

        let restored = try service.restore(item)
        XCTAssertEqual(restored.id, item.id)
        XCTAssertEqual(restored.url.canonicalPath, item.url.canonicalPath)
        XCTAssertEqual(service.read(at: item.url)?.title, "Restore me")

        XCTAssertThrowsError(try service.restore(item)) { error in
            XCTAssertEqual((error as NSError).code, CocoaError.fileWriteFileExists.rawValue)
        }
    }

    /// Two creates with one title must produce two files, never one overwriting the other.
    func testCreatingNeverReplacesAnExistingFile() throws {
        let first = try created("Same title")
        // Another tool writes the next candidate name between the check and the write.
        let squatter = root.appendingPathComponent("Same title 2.bw.md")
        try "someone else's".write(to: squatter, atomically: true, encoding: .utf8)
        let second = try created("Same title")
        XCTAssertNotEqual(first.url, second.url)
        XCTAssertNotEqual(second.url.lastPathComponent, squatter.lastPathComponent)
        XCTAssertEqual(try String(contentsOf: squatter, encoding: .utf8), "someone else's")
    }

    /// A file mid-write by another editor (front matter not yet closed) is not a work
    /// item yet — and must not become one with invented values.
    func testAHalfWrittenRecordIsSkippedNotMisread() throws {
        let url = root.appendingPathComponent("Partial.bw.md")
        try "---\nbetter-workspace: 1\nid: abc\nkind: task\ntit".write(to: url, atomically: true, encoding: .utf8)
        XCTAssertNil(service.read(at: url))
        XCTAssertTrue(service.items(under: root).isEmpty)
    }

    // MARK: Incremental work-item index

    /// Edited, deleted and half-written records are handled one file at a time.
    func testChangedRecordsAreReconciledWithoutAWalk() throws {
        let keep = try created("Keep")
        let edit = try created("Edit")
        let gone = try created("Gone")
        let known = service.items(under: root)

        var edited = try XCTUnwrap(service.read(at: edit.url))
        edited.stage = .now
        _ = try service.update(edited)
        try FileManager.default.removeItem(at: gone.url)
        // Mid-write by another editor: exists, does not parse. Not a deletion.
        try "---\nbetter-workspace: 1\nid: ".write(to: keep.url, atomically: false, encoding: .utf8)

        guard case let .incremental(upserts, removed) = service.reconcile(
            changedPaths: [edit.url.path, gone.url.path, keep.url.path], known: known) else {
            return XCTFail("Changes to individual records should not need a full walk")
        }
        let merged = WorkItemService.merged(known, upserting: upserts, removingPaths: removed)
        XCTAssertEqual(Set(merged.map(\.title)), ["Keep", "Edit"])
        XCTAssertEqual(merged.first { $0.title == "Edit" }?.stage, .now)
        XCTAssertEqual(merged.first { $0.title == "Keep" }?.id, keep.id, "The last good version stays")
    }

    /// A folder moved in reports only itself; the records inside it are found by
    /// scanning just that folder.
    func testAFolderMovedInBringsItsRecords() throws {
        let outside = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("bw-outside-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: outside) }
        let carried = try service.create(WorkItem(kind: .feature, title: "Carried in",
                                                  url: outside.appendingPathComponent("x.bw.md")), in: outside)
        let arrived = root.appendingPathComponent("Arrived", isDirectory: true)
        try FileManager.default.moveItem(at: outside, to: arrived)

        guard case let .incremental(upserts, _) = service.reconcile(changedPaths: [arrived.path], known: []) else {
            return XCTFail("A new folder is scanned on its own")
        }
        XCTAssertEqual(upserts.map(\.id), [carried.id])
    }

    /// A folder that held records disappearing is the one case that needs a full walk.
    func testAFolderThatHeldRecordsDisappearingAsksForAFullWalk() throws {
        let folder = root.appendingPathComponent("Queue", isDirectory: true)
        _ = try service.create(WorkItem(kind: .task, title: "Inside", url: folder.appendingPathComponent("x.bw.md")), in: folder)
        let known = service.items(under: root)
        try FileManager.default.moveItem(at: folder, to: root.appendingPathComponent("Queue renamed"))
        guard case .rescan = service.reconcile(changedPaths: [folder.path], known: known) else {
            return XCTFail("Records moved with their folder; only a walk knows where")
        }
    }

    // MARK: Tags across other apps' saves

    /// Most editors save by writing a new file and renaming it over the old one, which
    /// gives it a new inode. The tag must survive that, and survive a later rename too.
    func testTagsSurviveAnExternalAtomicSaveFollowedByARename() throws {
        let dbURL = root.appendingPathComponent("tags.sqlite")
        let store = TagStore(database: try Database(url: dbURL))
        let doc = root.appendingPathComponent("Notes.md")
        try "v1".write(to: doc, atomically: false, encoding: .utf8)
        let tag = try XCTUnwrap(store.createTag(named: "Keep"))
        store.assign(tagID: tag.id, to: doc, area: "For Reference")

        // Another editor saves: new inode, same path.
        let before = FileIdentityResolver.identity(of: doc)?.key
        try "v2".write(to: doc, atomically: true, encoding: .utf8)
        XCTAssertNotEqual(FileIdentityResolver.identity(of: doc)?.key, before, "precondition: the save changed the inode")
        XCTAssertEqual(store.tags(for: doc).map(\.name), ["Keep"])

        // Then it is renamed in Finder: new path, same (new) inode.
        let renamed = root.appendingPathComponent("Renamed notes.md")
        try FileManager.default.moveItem(at: doc, to: renamed)
        XCTAssertEqual(store.tags(for: renamed).map(\.name), ["Keep"],
                       "The tag must follow the file through an atomic save and a rename")
    }

    // MARK: Area settings edited by hand

    /// Areas.json is documented as hand-editable. An edit made while the app runs must
    /// survive the app's next save, and the app must pick it up.
    func testHandEditsToAreaSettingsSurviveTheAppsNextSave() throws {
        let url = root.appendingPathComponent("Areas.json")
        let store = AreaConfigurationStore(url: url)
        try store.set(AreaConfiguration(layout: .table), forFolderNamed: "Notes", identity: nil)

        // Edited by hand in a text editor: another folder's settings added.
        Thread.sleep(forTimeInterval: 1.1)  // a distinct modification time
        let edited = #"{"version":1,"areas":{"Notes":{"configuration":{"layout":"table"}},"Recipes":{"configuration":{"layout":"gallery"}}}}"#
        try edited.write(to: url, atomically: true, encoding: .utf8)

        XCTAssertTrue(store.reloadIfChangedOnDisk())
        XCTAssertEqual(store.entry(forFolderNamed: "Recipes")?.configuration.layout, .gallery)

        // And even without that reload, a save applies only its own change on top.
        Thread.sleep(forTimeInterval: 1.1)
        let again = #"{"version":1,"areas":{"Notes":{"configuration":{"layout":"table"}},"Recipes":{"configuration":{"layout":"gallery"}},"Travel":{"configuration":{"hidden":true}}}}"#
        try again.write(to: url, atomically: true, encoding: .utf8)
        try store.set(AreaConfiguration(layout: .outline), forFolderNamed: "Notes", identity: nil)

        let reread = AreaConfigurationStore(url: url)
        XCTAssertEqual(reread.entry(forFolderNamed: "Notes")?.configuration.layout, .outline)
        XCTAssertEqual(reread.entry(forFolderNamed: "Recipes")?.configuration.layout, .gallery)
        XCTAssertEqual(reread.entry(forFolderNamed: "Travel")?.configuration.hidden, true,
                       "A hand edit made while the app ran must not be overwritten")
    }

    /// The conflict check must see an edit made after the same record was already
    /// checked once — through the very same URL value.
    func testAnExternalEditIsCaughtEvenAfterAnEarlierCheckOfTheSameURL() throws {
        let item = try created()
        var edited = try XCTUnwrap(service.read(at: item.url))
        edited.stage = .now
        let saved = try service.update(edited)
        // Prime any per-URL cache on the value the editor now holds.
        _ = try saved.url.resourceValues(forKeys: [.contentModificationDateKey])

        Thread.sleep(forTimeInterval: 1.1)
        let text = try String(contentsOf: saved.url, encoding: .utf8)
        try text.replacingOccurrences(of: "priority: medium", with: "priority: high")
            .write(to: saved.url, atomically: false, encoding: .utf8)

        var mine = saved
        mine.title = "Mine"
        XCTAssertThrowsError(try service.update(mine), "Another editor's change must not be overwritten")
    }

    // MARK: Leftovers from an interrupted save

    private func makeOld(_ url: URL) throws {
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -3600)], ofItemAtPath: url.path)
    }

    private func staging(_ content: String) throws -> URL {
        let url = root.appendingPathComponent(".bw-save-\(UUID().uuidString).tmp")
        try content.write(to: url, atomically: false, encoding: .utf8)
        try makeOld(url)
        return url
    }

    /// An interrupted update leaves a staging copy beside an intact record: removed.
    /// An interrupted create leaves the only copy: put in place, not deleted.
    func testInterruptedSavesAreClearedAndInterruptedCreatesRecovered() throws {
        let existing = try created("Existing")
        var text = try String(contentsOf: existing.url, encoding: .utf8)
        let staleUpdate = try staging(text.replacingOccurrences(of: "stage: next", with: "stage: now"))
        text = text.replacingOccurrences(of: "id: \(existing.id)", with: "id: never-landed")
            .replacingOccurrences(of: "Existing", with: "Never landed")
        let orphanCreate = try staging(text)
        let cutOff = try staging("---\nbetter-workspace: 1\nid: abc\nki")
        let empty = try staging("")

        let result = service.cleanUpStaging(in: [root], knownIDs: [existing.id])
        XCTAssertEqual(Set(result.removed.map(\.lastPathComponent)),
                       [staleUpdate.lastPathComponent, cutOff.lastPathComponent, empty.lastPathComponent])
        XCTAssertEqual(result.recovered.map(\.lastPathComponent), ["Never landed.bw.md"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphanCreate.path))
        XCTAssertEqual(service.read(at: existing.url)?.stage, .next, "The intact record is untouched")
        XCTAssertEqual(service.read(at: root.appendingPathComponent("Never landed.bw.md"))?.id, "never-landed")
    }

    /// Anything that is not provably this app's leftover stays exactly where it is.
    func testCleanupNeverTouchesAnythingElse() throws {
        let fm = FileManager.default
        let record = try created("Keep me")
        var untouchable: [URL] = []
        func write(_ name: String, _ content: String, old: Bool = true) throws {
            let url = root.appendingPathComponent(name)
            try content.write(to: url, atomically: false, encoding: .utf8)
            if old { try makeOld(url) }
            untouchable.append(url)
        }
        let recordText = try String(contentsOf: record.url, encoding: .utf8)
        try write(".bw-save-not-a-uuid.tmp", recordText)                       // wrong shape
        try write(".bw-save-\(UUID().uuidString).txt", recordText)              // wrong suffix
        try write("bw-save-\(UUID().uuidString).tmp", recordText)               // not hidden
        try write(".bw-save-\(UUID().uuidString).tmp", "my own notes")          // not a record
        try write(".bw-save-\(UUID().uuidString).tmp", recordText, old: false)  // a save in flight
        try write(".hidden-notes.md", recordText)                                // someone else's dotfile
        let directory = root.appendingPathComponent(".bw-save-\(UUID().uuidString).tmp", isDirectory: true)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)   // a folder
        untouchable.append(directory)

        let result = service.cleanUpStaging(in: [root], knownIDs: [record.id])
        XCTAssertTrue(result.removed.isEmpty && result.recovered.isEmpty, "\(result)")
        for url in untouchable { XCTAssertTrue(fm.fileExists(atPath: url.path), url.lastPathComponent) }
    }

    /// Long titles in multi-byte scripts are cut by bytes, so they can still be saved.
    func testAVeryLongMultiByteTitleStillSaves() throws {
        let title = String(repeating: "日本語のタイトル", count: 20)
        let item = try created(title)
        XCTAssertTrue(FileManager.default.fileExists(atPath: item.url.path))
        XCTAssertLessThanOrEqual(item.url.lastPathComponent.utf8.count, 255)
        var edited = try XCTUnwrap(service.read(at: item.url))
        edited.stage = .now
        XCTAssertNoThrow(try service.update(edited))
    }
}
