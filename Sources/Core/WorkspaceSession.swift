import Foundation
import Observation
import SwiftData
import WidgetKit
#if os(iOS)
import UIKit
#endif

public struct WorkspaceSessionSettings: Codable, Sendable {
    public var sourceID = UUID()
    public var deviceID = UUID()
    public var cloudEnabled = false
    public var accountScope: String?
    public var approvals: [WorkspaceJoinApproval] = []
    public var macIncluded = false
    public var welcomeCompleted = false
}

/// The normal app's one portable workspace. All editor saves commit locally first.
/// The old notebook is an additive upgrade source, never an alternative workspace.
@MainActor @Observable
public final class WorkspaceSession {
    public let store: WorkspaceReplicaStore
    public let directory: URL
    public let isFixture: Bool
    public private(set) var settings: WorkspaceSessionSettings
    public private(set) var replica: WorkspaceReplica
    public private(set) var pendingPeers: [WorkspaceCloudPeer] = []
    private var receivedPeers: [WorkspaceCloudPeer] = []
    public private(set) var syncing = false
    private var syncAgain = false
    private var syncAgainIncludesCloud = false
    public private(set) var status = "Saved on this device"
    public private(set) var lastSync: Date?
    public var error: String?
    public private(set) var connectionError: String?
    /// Backoff for periodic passes after failures; see `SyncRetryState`.
    public private(set) var retry = SyncRetryState()
    public var capabilityStatus: String?
    public var focusedRecordID: UUID?
    @ObservationIgnored public var macBridge: (@MainActor () async throws -> Void)?
    @ObservationIgnored private let cloud: WorkspaceCloudTransport
    @ObservationIgnored private var reloadGeneration = 0
    @ObservationIgnored private static var live: WorkspaceSession?
    @ObservationIgnored private static var opening: Task<WorkspaceSession, Error>?

    nonisolated public static var fixtureID: UUID? { TestIsolation.launchArgument("BWUnifiedFixture").flatMap(UUID.init(uuidString:)) }
    public var sourceID: UUID { settings.sourceID }
    public var deviceID: UUID { settings.deviceID }
    public var cloudEnabled: Bool { settings.cloudEnabled }
    public private(set) var records: [WorkspaceRecordState]
    public private(set) var displayTitles: [UUID: String]
    public private(set) var locationIssues: [UUID: WorkspaceReplica.LocationIssue]
    /// Last published workspaces, not a claim that the devices are online now.
    public var connectedPeers: [WorkspaceCloudPeer] {
        receivedPeers.filter { $0.deviceID != deviceID && $0.replica.joinedWorkspaceIDs.isSubset(of: replica.joinedWorkspaceIDs) }
            .sorted { $0.deviceID.uuidString < $1.deviceID.uuidString }
    }
    public var origin: WorkspaceRecordRevision.Origin {
        #if os(macOS)
        .mac
        #else
        .iOS
        #endif
    }
    public var deviceName: String {
        #if os(macOS)
        "Mac"
        #else
        UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"
        #endif
    }

    /// Shared with this app’s widget extension. Legacy notebook storage stays at
    /// its original URL and is imported through SwiftData, never moved or reset.
    nonisolated public static var storageDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("BetterWorkspace")
        if let fixture = fixtureID { return (TestIsolation.sandbox ?? base).appendingPathComponent("UnifiedAcceptance/" + fixture.uuidString) }
        if let sandbox = TestIsolation.sandbox { return sandbox.appendingPathComponent("UnifiedWorkspace") }
        #if os(macOS)
        let group = WidgetAppGroup.mac
        #else
        let group = WidgetAppGroup.mobile
        #endif
        return (FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) ?? base).appendingPathComponent("UnifiedWorkspace")
    }

    public static func openLive() async throws -> WorkspaceSession {
        if let live { return live }
        if let opening { return try await opening.value }
        let task = Task { @MainActor in
            let session = try await open(directory: storageDirectory, fixture: fixtureID != nil || TestIsolation.isActive)
            if !session.isFixture { try await session.importEarlierNotebook() }
            if !session.isFixture, !session.settings.welcomeCompleted, UserDefaults.standard.bool(forKey: "workspaceWelcomeCompleted") { try session.finishWelcome() }
            live = session
            return session
        }
        opening = task
        defer { opening = nil }
        return try await task.value
    }

    public static func open(directory: URL, fixture: Bool) async throws -> WorkspaceSession {
        let loaded = try await Task.detached(priority: .userInitiated) { try SuspensionProtection.run("Workspace setup") {
            try WorkspaceLocalPathChecks.rejectSymlinks(to: directory)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let lockURL = directory.appendingPathComponent("session.lock")
            try WorkspaceLocalPathChecks.rejectSymlinks(to: lockURL)
            let descriptor = Darwin.open(lockURL.path, O_CREAT | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
            guard descriptor >= 0 else { throw WorkspaceReplicaError.invalid("Workspace setup could not be locked.") }
            defer { close(descriptor) }
            guard flock(descriptor, LOCK_EX) == 0 else { throw WorkspaceReplicaError.changed }
            defer { flock(descriptor, LOCK_UN) }
            let file = directory.appendingPathComponent("settings.json")
            try WorkspaceLocalPathChecks.rejectSymlinks(to: file)
            let settings: WorkspaceSessionSettings
            if FileManager.default.fileExists(atPath: file.path) {
                settings = try JSONDecoder().decode(WorkspaceSessionSettings.self, from: Data(contentsOf: file))
                guard settings.approvals.count <= 256, Set(settings.approvals.map(\.id)).count == settings.approvals.count, !settings.cloudEnabled || settings.accountScope != nil else {
                    throw WorkspaceReplicaError.invalid("The workspace connection settings need review. Local records have been retained.")
                }
            } else {
                settings = WorkspaceSessionSettings()
                try JSONEncoder().encode(settings).write(to: file, options: .atomic)
            }
            let store = WorkspaceReplicaStore(directory: directory, initialWorkspaceID: settings.sourceID)
            let replica = try store.load()
            return (settings, store, replica, replica.records, replica.displayTitles, replica.locationIssues)
        } }.value
        return WorkspaceSession(directory: directory, settings: loaded.0, store: loaded.1, replica: loaded.2, records: loaded.3, displayTitles: loaded.4, locationIssues: loaded.5, fixture: fixture)
    }

    private init(directory: URL, settings: WorkspaceSessionSettings, store: WorkspaceReplicaStore, replica: WorkspaceReplica,
                 records: [WorkspaceRecordState], displayTitles: [UUID: String], locationIssues: [UUID: WorkspaceReplica.LocationIssue], fixture: Bool) {
        self.directory = directory; self.settings = settings; self.store = store; self.replica = replica; isFixture = fixture
        self.records = records; self.displayTitles = displayTitles; self.locationIssues = locationIssues
        cloud = WorkspaceCloudTransport()
    }

    public func reload() async throws {
        reloadGeneration += 1
        let generation = reloadGeneration, store = store, previous = replica
        let loaded = try await Task.detached(priority: .userInitiated) {
            let current = try store.load()
            // Equal replicas (the usual case: the journal is cached until its file
            // changes) have equal fingerprints; encode only when they differ.
            let changed = try current != previous && previous.fingerprint != current.fingerprint
            return (current, changed, changed ? current.records : [], changed ? current.displayTitles : [:], changed ? current.locationIssues : [:])
        }.value
        if generation == reloadGeneration, loaded.1 {
            replica = loaded.0; records = loaded.2; displayTitles = loaded.3; locationIssues = loaded.4
            if !isFixture { WidgetCenter.shared.reloadAllTimelines() }
        }
    }

    @discardableResult public func save(recordID: UUID = UUID(), content: WorkspaceRecordContent, expectedHeads: Set<UUID>, resolvingConflict: Bool = false) async throws -> WorkspaceRecordRevision {
        let store = store, device = deviceID, origin = origin
        let saved = try await Task.detached(priority: .userInitiated) {
            try store.save(recordID: recordID, content: content, expectedHeads: expectedHeads, deviceID: device, origin: origin, resolvingConflict: resolvingConflict)
        }.value
        try await reload()
        Task { await synchronize() }
        return saved
    }

    public func importEarlierNotebook() async throws {
        guard !isFixture else { return }
        let legacy = try WorkspaceNotebookPersistence.sharedContainer()
        try await importNotebook(from: legacy.mainContext)
    }

    public func importNotebook(from context: ModelContext) async throws {
        let incoming = try WorkspaceNotebookImport.preview(from: context, workspaceID: replica.workspaceID)
        // Match the current approved identity set; local upgrade introduces no other device.
        let adjusted = try WorkspaceReplica(workspaceID: replica.workspaceID, revisions: incoming.revisions, joinedWorkspaceIDs: replica.joinedWorkspaceIDs)
        let store = store
        try await Task.detached(priority: .utility) {
            let known = Set(try store.load().revisions.map(\.id))
            if !Set(adjusted.revisions.map(\.id)).isSubset(of: known) { try store.receive(adjusted) }
        }.value
        try await reload()
    }

    public func enableCloud() async {
        guard !isFixture else { status = "Isolated device test · synchronization disabled"; return }
        do {
            let scope = try await cloud.accountScope()
            guard settings.accountScope == nil || settings.accountScope == scope else {
                throw WorkspaceReplicaError.invalid("This workspace belongs to another iCloud account. Its records are retained locally; reconnect using the original account.")
            }
            var updated = settings; updated.accountScope = scope; updated.cloudEnabled = true
            try persist(updated); settings = updated
            await synchronize()
        } catch { self.error = WorkspaceCloudTransport.userMessage(for: error); status = "Saved locally · connection needs attention" }
    }

    public func pauseCloud() throws {
        var updated = settings; updated.cloudEnabled = false
        try persist(updated); settings = updated; status = "Saved on this device · synchronization paused"
    }
    public func finishWelcome() throws {
        var updated = settings; updated.welcomeCompleted = true
        try persist(updated); settings = updated
    }
    public func markMacIncluded() throws {
        var updated = settings; updated.macIncluded = true
        try persist(updated); settings = updated
    }

    public func review(_ peer: WorkspaceCloudPeer) throws -> WorkspaceMergePreview { try store.previewMerge(peer.replica) }
    @discardableResult public func approve(_ peer: WorkspaceCloudPeer, preview: WorkspaceMergePreview) async throws -> URL {
        let store = store, device = deviceID
        let applied = try await Task.detached(priority: .userInitiated) {
            try peer.validate()
            let before = try store.load()
            let grant = try WorkspaceJoinApproval(local: before, incoming: peer.replica, authorDeviceID: device)
            let checkpoint = try store.applyReviewedMerge(peer.replica, approved: preview)
            return (checkpoint, grant, grant.roots != before.joinedWorkspaceIDs)
        }.value
        let checkpoint = applied.0
        var updated = settings
        if applied.2 { updated.approvals.append(applied.1) }
        try persist(updated); settings = updated
        try await reload(); pendingPeers.removeAll { $0.id == peer.id }
        Task { await synchronize() }
        return checkpoint
    }

    /// A change saved while a pass runs is sent by a follow-up pass rather than the next
    /// periodic one, and every caller returns only once its change has had a pass — so a
    /// device going to the background can wait for its last edit to be sent.
    /// What a periodic timer calls. While backing off after iCloud failures (including a
    /// wait CloudKit asked for) the pass still runs its local work, the Mac's Workspace
    /// bridge included, and skips only the iCloud exchange. Explicit opportunities call
    /// `synchronize()`, which always tries iCloud.
    public func synchronizeIfDue(now: Date = Date()) async {
        await synchronize(includingCloud: retry.isDue(at: now))
    }

    public func synchronize() async { await synchronize(includingCloud: true) }

    private func synchronize(includingCloud: Bool) async {
        guard !syncing else {
            // The follow-up pass keeps an explicit request's iCloud attempt even when the
            // pass already running is a local-only one.
            syncAgain = true; syncAgainIncludesCloud = syncAgainIncludesCloud || includingCloud
            while syncing { do { try await Task.sleep(for: .milliseconds(200)) } catch { return } }
            return
        }
        syncing = true; defer { syncing = false }
        var cloud = includingCloud
        repeat {
            syncAgain = false; syncAgainIncludesCloud = false
            await synchronizationPass(includingCloud: cloud)
            cloud = syncAgainIncludesCloud || retry.isDue()
        } while syncAgain
    }

    private func synchronizationPass(includingCloud: Bool) async {
        var reachedCloud = false
        var bridgeFailed = false
        do {
            if !isFixture { try await importEarlierNotebook() }
            if let macBridge {
                // A previous pass's failure must not outlive a pass that succeeds.
                capabilityStatus = nil
                do { try await macBridge() } catch { capabilityStatus = error.localizedDescription; bridgeFailed = true }
                try await reload()
            }
            guard includingCloud, settings.cloudEnabled, !isFixture, let scope = settings.accountScope else { return }
            reachedCloud = true
            status = "Synchronizing with your private iCloud account…"
            let exchange = try await cloud.exchange(payload(), accountScope: scope)
            let before = replica
            try await receive(exchange.peers)
            // The first pass already observed Finder and applied pending edits.
            // An unchanged delivery has nothing new for the Mac editor to apply.
            if let macBridge, bridgeFailed || replica != before {
                do { try await macBridge() } catch { capabilityStatus = error.localizedDescription }
                try await reload()
            }
            let after = replica
            // Equal replicas have equal fingerprints; encode both only when they differ.
            let changed = after == before ? false : try await Task.detached(priority: .utility) { try before.fingerprint != after.fingerprint }.value
            if changed { _ = try await cloud.exchange(payload(), accountScope: scope) }
            connectionError = nil; retry.recordSuccess()
            lastSync = Date(); status = pendingPeers.isEmpty ? "Workspace synchronized · available offline" : "Review the initial workspace merge to connect devices"
        } catch {
            connectionError = WorkspaceCloudTransport.userMessage(for: error)
            // Only iCloud's failures back iCloud off; a local error retries on the next tick.
            if reachedCloud { retry.recordFailure(error) }
            status = "Saved locally · synchronization will retry"
        }
    }

    /// Routine delivery adopts only roots already approved locally, or an exact
    /// unchanged base named by another device’s reviewed join approval. Other roots
    /// become visible pending previews; delivery itself never grants approval.
    public func receive(_ peers: [WorkspaceCloudPeer]) async throws {
        var pending: [WorkspaceCloudPeer] = []
        // Every exchange returns every device's whole snapshot. One that adds nothing to
        // what is already here is not reloaded and merged again (each pass used to decode
        // the store once per device). A stale in-memory copy only makes this check fail.
        let known = Set(replica.revisions.map(\.id)), joined = replica.joinedWorkspaceIDs
        for peer in peers.sorted(by: { $0.deviceID.uuidString < $1.deviceID.uuidString }) {
            let store = store
            let accepted = try await Task.detached(priority: .utility) {
                try peer.validate()
                if peer.replica.joinedWorkspaceIDs.isSubset(of: joined), peer.replica.revisions.allSatisfy({ known.contains($0.id) }) { return true }
                let current = try store.load()
                if peer.replica.joinedWorkspaceIDs.isSubset(of: current.joinedWorkspaceIDs) {
                    let normalized = try WorkspaceReplica(workspaceID: current.workspaceID, revisions: peer.replica.revisions, joinedWorkspaceIDs: current.joinedWorkspaceIDs)
                    try store.receive(normalized)
                } else if try peer.approvals.contains(where: { try $0.authorizes(local: current, incoming: peer.replica) }) {
                    _ = try store.applyReviewedMerge(peer.replica, approved: store.previewMerge(peer.replica))
                } else { return false }
                return true
            }.value
            guard accepted else { pending.append(peer); continue }
            var grants = Dictionary(uniqueKeysWithValues: settings.approvals.map { ($0.id, $0) })
            for grant in peer.approvals {
                if let old = grants[grant.id], old != grant { throw WorkspaceReplicaError.revisionCollision }
                grants[grant.id] = grant
            }
            var updated = settings; updated.approvals = grants.values.sorted { $0.id.uuidString < $1.id.uuidString }
            try persist(updated); settings = updated
        }
        pendingPeers = pending
        try await reload()
        receivedPeers = peers
    }

    public func payload() -> WorkspaceCloudPeer {
        .init(deviceID: deviceID, sourceID: sourceID, name: deviceName, platform: origin.rawValue, replica: replica, approvals: settings.approvals)
    }

    public func checkpoints() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey])
            .filter { $0.lastPathComponent.hasPrefix("merge-") && UUID(uuidString: String($0.deletingPathExtension().lastPathComponent.dropFirst(6))) != nil && $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
    /// Recovery is additive. Later edits are retained and differing versions become
    /// conflicts, rather than replacing the current store with an old checkpoint.
    public func recover(_ checkpoint: URL) async throws {
        guard let owned = try checkpoints().first(where: { $0.canonicalPath == checkpoint.canonicalPath }) else { throw WorkspaceReplicaError.missing }
        try WorkspaceLocalPathChecks.rejectSymlinks(to: checkpoint)
        try WorkspaceLocalPathChecks.rejectSymlinks(to: owned)
        let backup = try JSONDecoder().decode(WorkspaceReplica.self, from: Data(contentsOf: owned))
        let current = try store.load()
        for state in backup.records {
            guard let old = state.resolved else { continue }
            if let now = current.records.first(where: { $0.id == state.id }), now.heads.contains(where: { $0.content == old.content }) { continue }
            let revision = WorkspaceRecordRevision(recordID: old.recordID, parents: [old.id], deviceID: deviceID, origin: origin,
                recordCreatedAt: old.recordCreatedAt, content: old.content)
            let incoming = try WorkspaceReplica(workspaceID: current.workspaceID, revisions: backup.revisions + [revision], joinedWorkspaceIDs: current.joinedWorkspaceIDs)
            try store.receive(incoming)
        }
        try await reload(); Task { await synchronize() }
    }
    private func persist(_ settings: WorkspaceSessionSettings) throws {
        let file = directory.appendingPathComponent("settings.json")
        try WorkspaceLocalPathChecks.rejectSymlinks(to: file)
        try JSONEncoder().encode(settings).write(to: file, options: .atomic)
    }
}
