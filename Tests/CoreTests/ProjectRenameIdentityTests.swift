import XCTest
@testable import BetterWorkspaceCore

/// "Current State" was renamed to "Better Signals" in Finder while an older Better
/// Signals record still named that path. The rename update failed on the unique path,
/// and after volume identities moved to UUIDs the folder was re-keyed by path onto the
/// wrong record, leaving two identities bound to one folder and blocking its work.
final class ProjectRenameIdentityTests: XCTestCase {
    private var root: URL!
    private var database: Database!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("bw-rename-identity-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Projects"), withIntermediateDirectories: true)
        database = try Database(url: root.appendingPathComponent("private.sqlite"))
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func folder(_ name: String) -> URL { root.appendingPathComponent("Projects/" + name) }

    private func recordLegacyKey(for id: String, at url: URL) throws {
        let identity = try XCTUnwrap(FileIdentityResolver.identity(of: url))
        try database.run("UPDATE projects SET identity_key = ? WHERE id = ?", [.text("16777234:\(identity.fileID)"), .text(id)])
    }

    func testRenameOntoAStalePathKeepsTheRenamedProjectsIdentity() throws {
        let store = ProjectStore(database: database)
        let stale = store.register(url: folder("Better Signals"))  // no folder: path only
        try FileManager.default.createDirectory(at: folder("Current State"), withIntermediateDirectories: true)
        let renamed = store.register(url: folder("Current State"))
        store.setNotionPageID("current-state-page", for: renamed.id)
        try recordLegacyKey(for: renamed.id, at: folder("Current State"))  // written before a restart
        try FileManager.default.moveItem(at: folder("Current State"), to: folder("Better Signals"))

        XCTAssertEqual(store.register(url: folder("Better Signals")).id, renamed.id)
        let healed = try XCTUnwrap(store.record(id: renamed.id))
        XCTAssertEqual(healed.lastPath, folder("Better Signals").canonicalPath)
        XCTAssertEqual(healed.identityKey, FileIdentityResolver.identity(of: folder("Better Signals"))?.key, "The legacy key is upgraded")
        XCTAssertEqual(healed.notionPageID, "current-state-page")
        let aside = try XCTUnwrap(store.record(id: stale.id), "The stale record is kept, with its links")
        XCTAssertNotEqual(aside.lastPath, healed.lastPath)
        XCTAssertFalse(FileManager.default.fileExists(atPath: aside.lastPath))
        XCTAssertEqual(store.record(for: folder("Better Signals"))?.id, renamed.id)
        XCTAssertEqual(store.allRecords().count, 2, "No identity is invented")
    }

    func testLookupFollowsALegacyKeyAcrossARename() throws {
        let store = ProjectStore(database: database)
        try FileManager.default.createDirectory(at: folder("Before"), withIntermediateDirectories: true)
        let record = store.register(url: folder("Before"))
        try recordLegacyKey(for: record.id, at: folder("Before"))
        try FileManager.default.moveItem(at: folder("Before"), to: folder("After"))
        XCTAssertEqual(store.record(for: folder("After"))?.id, record.id)
        XCTAssertEqual(store.record(id: record.id)?.lastPath, folder("After").canonicalPath)
    }

    /// October 27: projects moved from Projects into Ideas after a restart kept a legacy
    /// key; an exact key comparison never found them, so 19 looked deleted to Notion sync.
    func testAProjectMovedIntoIdeasIsFoundByItsLegacyIdentity() throws {
        let store = ProjectStore(database: database)
        try FileManager.default.createDirectory(at: folder("Welch Labs Clone"), withIntermediateDirectories: true)
        let record = store.register(url: folder("Welch Labs Clone"))
        try recordLegacyKey(for: record.id, at: folder("Welch Labs Clone"))
        let ideas = root.appendingPathComponent("Ideas")
        try FileManager.default.createDirectory(at: ideas, withIntermediateDirectories: true)
        let moved = ideas.appendingPathComponent("Welch Labs Clone")
        try FileManager.default.moveItem(at: folder("Welch Labs Clone"), to: moved)
        let identity = try XCTUnwrap(FileIdentityResolver.identity(of: moved))
        XCTAssertNotEqual(store.record(id: record.id)?.identityKey, identity.key, "The stored key text no longer matches")
        XCTAssertEqual(store.identityIndex().record(for: identity, at: moved.canonicalPath)?.id, record.id)
        XCTAssertEqual(store.record(id: record.id)?.identityKey.flatMap(FileIdentity.init(key:)), identity)
    }

    func testTheIdentityIndexIgnoresALegacyKeyWhoseFolderIsStillThere() throws {
        let store = ProjectStore(database: database)
        try FileManager.default.createDirectory(at: folder("Present"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: folder("Other"), withIntermediateDirectories: true)
        let present = store.register(url: folder("Present"))
        try recordLegacyKey(for: present.id, at: folder("Other"))
        let other = try XCTUnwrap(FileIdentityResolver.identity(of: folder("Other")))
        XCTAssertNil(store.identityIndex().record(for: other, at: folder("Other").canonicalPath), "Its own folder is still where it was recorded")
    }

    func testALegacyKeyWhoseFolderStillExistsIsNotAdopted() throws {
        let store = ProjectStore(database: database)
        try FileManager.default.createDirectory(at: folder("Present"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: folder("Other"), withIntermediateDirectories: true)
        let present = store.register(url: folder("Present"))
        // Same inode number recorded with a device number, but that record's folder is
        // still where it was: it cannot be the folder being registered.
        try recordLegacyKey(for: present.id, at: folder("Other"))
        XCTAssertNotEqual(store.register(url: folder("Other")).id, present.id)
        XCTAssertEqual(store.record(id: present.id)?.lastPath, folder("Present").canonicalPath)
    }

    func testAFolderSwappedIntoAProjectsPathDoesNotTakeItsIdentity() throws {
        let store = ProjectStore(database: database)
        try FileManager.default.createDirectory(at: folder("Alpha"), withIntermediateDirectories: true)
        let alpha = store.register(url: folder("Alpha"))
        store.setNotionPageID("alpha-page", for: alpha.id)
        try FileManager.default.moveItem(at: folder("Alpha"), to: folder("Alpha Old"))
        try FileManager.default.createDirectory(at: folder("Alpha"), withIntermediateDirectories: true)  // a different folder

        XCTAssertNil(store.record(for: folder("Alpha")), "A lookup never hands the newcomer the earlier record")
        let newcomer = store.register(url: folder("Alpha"))
        XCTAssertNotEqual(newcomer.id, alpha.id)
        XCTAssertNil(store.record(id: newcomer.id)?.notionPageID)
        XCTAssertEqual(store.record(for: folder("Alpha"))?.id, newcomer.id, "The new record was stored, not ignored")
        let moved = try XCTUnwrap(store.record(id: alpha.id))
        XCTAssertEqual(moved.lastPath, folder("Alpha Old").canonicalPath, "The earlier record follows its folder")
        XCTAssertEqual(moved.notionPageID, "alpha-page")
        XCTAssertEqual(store.register(url: folder("Alpha Old")).id, alpha.id)
    }

    func testAFolderReplacedAtItsPathKeepsTheProject() throws {
        let store = ProjectStore(database: database)
        try FileManager.default.createDirectory(at: folder("Restored"), withIntermediateDirectories: true)
        let original = store.register(url: folder("Restored"))
        store.setNotionPageID("restored-page", for: original.id)
        try FileManager.default.removeItem(at: folder("Restored"))
        try FileManager.default.createDirectory(at: folder("Restored"), withIntermediateDirectories: true)  // e.g. from a backup

        let again = store.register(url: folder("Restored"))
        XCTAssertEqual(again.id, original.id)
        XCTAssertEqual(store.record(id: original.id)?.identityKey, FileIdentityResolver.identity(of: folder("Restored"))?.key)
        XCTAssertEqual(store.allRecords().count, 1)
    }

    func testARenameLeavesAnAliasAndAPathTwoProjectsLeftIsAmbiguous() throws {
        let store = ProjectStore(database: database)
        try FileManager.default.createDirectory(at: folder("First"), withIntermediateDirectories: true)
        let first = store.register(url: folder("First"))
        XCTAssertTrue(store.pathAliases().isEmpty)
        try FileManager.default.moveItem(at: folder("First"), to: folder("First Renamed"))
        _ = store.register(url: folder("First Renamed"))
        XCTAssertEqual(store.pathAliases()[folder("First").canonicalPath], first.id)

        try FileManager.default.createDirectory(at: folder("First"), withIntermediateDirectories: true)  // a new project takes the name
        let second = store.register(url: folder("First"))
        XCTAssertNotEqual(second.id, first.id)
        try FileManager.default.moveItem(at: folder("First"), to: folder("Second"))
        _ = store.register(url: folder("Second"))
        XCTAssertNil(store.pathAliases()[folder("First").canonicalPath], "Neither project may claim a path both left")
    }

    func testAReplacedProjectFolderIsAdoptedOnlyWhenTheBoundFolderIsGone() throws {
        let path = "Projects/Replaced", id = UUID()
        try FileManager.default.createDirectory(at: folder("Replaced"), withIntermediateDirectories: true)
        let bound = try XCTUnwrap(FileIdentityResolver.identity(of: folder("Replaced")))
        XCTAssertFalse(FileIdentityResolver.isGone(bound, onVolumeOf: folder("Replaced")))
        try FileManager.default.removeItem(at: folder("Replaced"))
        try FileManager.default.createDirectory(at: folder("Replaced"), withIntermediateDirectories: true)
        let now = try XCTUnwrap(FileIdentityResolver.identity(of: folder("Replaced")))
        XCTAssertTrue(FileIdentityResolver.isGone(bound, onVolumeOf: folder("Replaced")))

        let snapshot = MobileWorkspaceSnapshot(entries: [.init(path: path, parentPath: "Projects", name: "Replaced", isDirectory: true,
            revision: 1, projectDetails: .init(path: path, projectID: id.uuidString))], workItems: [])
        let first = try WorkspaceMacProjection.observe(snapshot, in: WorkspaceReplica(), bindings: [], deviceID: UUID(), projectIdentities: [path: bound])
        let held = try WorkspaceMacProjection.observe(snapshot, in: first.replica, bindings: first.bindings, deviceID: UUID(),
                                                      projectIdentities: [path: now], allowIdentityAdoption: true)
        XCTAssertNotNil(held.deferredSourceIDs["project:" + path], "An unexplained identity change waits for review")
        let adopted = try WorkspaceMacProjection.observe(snapshot, in: first.replica, bindings: first.bindings, deviceID: UUID(),
                                                         projectIdentities: [path: now], replacedProjectFolders: [path])
        XCTAssertTrue(adopted.deferredSourceIDs.isEmpty)
        XCTAssertEqual(adopted.bindings.first?.fileIdentity, now)
        XCTAssertEqual(adopted.bindings.first?.recordID, first.bindings.first?.recordID)
    }

    /// `_Utilities/Storage Maintenance` is a project, as on the Mac and in Finder Workspace
    /// Extensions; its container is not a level and its work links to it.
    func testANestedUnderscoreProjectIsProjectedAsAProject() throws {
        let path = "Projects/_Utilities/Storage Maintenance", id = UUID()
        let work = MobileWorkItem(id: "nested-task", path: "To Do/Clean.bw.md", title: "Clean", kind: .task, status: .open, stage: .now,
            priority: .medium, projectPath: path, dueDate: nil, revision: 1, body: "", dependencyIDs: [], featureIDs: [], milestoneIDs: [],
            createdAt: Date(timeIntervalSince1970: 1), modifiedAt: Date(timeIntervalSince1970: 1), completedAt: nil)
        let snapshot = MobileWorkspaceSnapshot(entries: [.init(path: path, parentPath: "Projects", name: "Storage Maintenance", isDirectory: true,
            revision: 1, projectDetails: .init(path: path, projectID: id.uuidString))], workItems: [work])
        let graph = WorkspaceReplicaStore(directory: root.appendingPathComponent("graph"), initialWorkspaceID: UUID())
        let observed = try WorkspaceMacProjection.observe(snapshot, in: try graph.load(), bindings: [], deviceID: UUID())
        let project = try XCTUnwrap(observed.replica.records.first { $0.resolved?.content.kind == .project })
        XCTAssertEqual(project.resolved?.content.title, "Storage Maintenance")
        XCTAssertNil(project.resolved?.content.parentID)
        let task = try XCTUnwrap(observed.replica.records.first { $0.resolved?.content.kind == .task })
        XCTAssertEqual(task.resolved?.content.parentID, project.id)
        XCTAssertTrue(observed.deferredSourceIDs.isEmpty, "\(observed.deferredSourceIDs)")
    }

    func testSupersededProjectBindingIsRetiredWithItsHistory() throws {
        let path = "Projects/Better Signals"
        try FileManager.default.createDirectory(at: folder("Better Signals"), withIntermediateDirectories: true)
        let identity = try XCTUnwrap(FileIdentityResolver.identity(of: folder("Better Signals")))
        let legacy = FileIdentity(volume: "16777234", fileID: identity.fileID)
        let earlier = UUID(), current = UUID(), device = UUID()
        func snapshot(_ projects: [(String, UUID)]) -> MobileWorkspaceSnapshot {
            let work = MobileWorkItem(id: UUID(uuidString: "6C1D63E0-46B8-4E6C-9A0B-6A8D2C0E5F11")!.uuidString, path: path + "/Work/Task.bw.md",
                title: "Task", kind: .task, status: .open, stage: .now, priority: .medium, projectPath: path, dueDate: nil, revision: 1,
                body: "Body", dependencyIDs: [], featureIDs: [], milestoneIDs: [], createdAt: Date(timeIntervalSince1970: 1), modifiedAt: Date(timeIntervalSince1970: 1), completedAt: nil)
            return .init(entries: projects.map { .init(path: $0.0, parentPath: "Projects", name: String($0.0.dropFirst("Projects/".count)),
                isDirectory: true, revision: 1, projectDetails: .init(path: $0.0, projectID: $0.1.uuidString)) }, workItems: [work])
        }
        let graph = WorkspaceReplicaStore(directory: root.appendingPathComponent("graph"), initialWorkspaceID: UUID())
        let receipts = try WorkspaceMacReceiptStore(database: database), source = UUID()
        let before = try WorkspaceMacProjection.observe(snapshot([(path, earlier)]), in: try graph.load(), bindings: [], deviceID: device,
                                                        projectIdentities: [path: legacy])
        // After the restart the store published the folder under the other identity.
        let after = try WorkspaceMacProjection.observe(snapshot([(path, current)]), in: before.replica, bindings: before.bindings, deviceID: device,
                                                       projectIdentities: [path: identity], allowIdentityAdoption: true)

        // The production failure: the receipt store refuses an observation that drops a binding.
        let first = try receipts.commit(before, sourceID: source, sourceRoot: root, expectedReceiptID: nil, graph: graph)
        XCTAssertNoThrow(try receipts.commit(after, sourceID: source, sourceRoot: root, expectedReceiptID: first.id, graph: graph))
        XCTAssertNil(after.deferredSourceIDs["project:" + path], "One project per folder again")
        XCTAssertEqual(WorkspaceMacProjection.liveProjectBindings(after.bindings, in: after.replica).map(\.recordID), [current])
        XCTAssertTrue(Set(before.bindings.map(\.recordID)).isSubset(of: Set(after.bindings.map(\.recordID))), "Receipts never lose a binding")
        let retired = try XCTUnwrap(after.replica.records.first { $0.id == earlier })
        XCTAssertEqual(retired.resolved?.content.isDeleted, true)
        XCTAssertTrue(Set(before.replica.revisions.map(\.id)).isSubset(of: Set(after.replica.revisions.map(\.id))), "History is kept")
        let task = try XCTUnwrap(after.replica.records.first { $0.resolved?.content.kind == .task })
        XCTAssertEqual(task.resolved?.content.parentID, current, "Work follows the folder's current project")

        let repeated = try WorkspaceMacProjection.observe(snapshot([(path, current)]), in: after.replica, bindings: after.bindings, deviceID: device,
                                                          projectIdentities: [path: identity])
        XCTAssertEqual(try repeated.replica.fingerprint, try after.replica.fingerprint, "Retirement happens once")

        // If the earlier identity is published again elsewhere, it waits for review rather
        // than silently resurrecting or branching.
        try FileManager.default.createDirectory(at: folder("Current State"), withIntermediateDirectories: true)
        let back = try WorkspaceMacProjection.observe(snapshot([(path, current), ("Projects/Current State", earlier)]), in: after.replica,
            bindings: after.bindings, deviceID: device,
            projectIdentities: [path: identity, "Projects/Current State": try XCTUnwrap(FileIdentityResolver.identity(of: folder("Current State")))])
        let returned = try XCTUnwrap(back.replica.records.first { $0.id == earlier })
        XCTAssertFalse(returned.isConflict)
        XCTAssertNotNil(back.deferredSourceIDs["project:Projects/Current State"])
    }
}
