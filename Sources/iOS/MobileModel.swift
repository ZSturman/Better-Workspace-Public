import Foundation
import SwiftUI
import Observation
import WidgetKit
import UniformTypeIdentifiers
import UIKit
import BetterWorkspaceCore

/// Resolves and remembers where captures go, and performs them.
///
/// Destination resolution, in order:
///  1. This app's iCloud ubiquity container, if one is provisioned.
///  2. A folder the user picked once through the document picker, remembered as a
///     security-scoped bookmark. This is how the prototype reaches the shared
///     `iCloud Drive/Better Workspace/Inbox` folder with no entitlement or provisioning.
///  3. Nothing — the UI asks the user to pick the folder.
@MainActor
@Observable
final class MobileModel {

    /// One model per process. The app's scene, its App Intents (which may run with no
    /// scene at all) and widget-launched captures all use this instance.
    static let shared = MobileModel()

    static let bookmarkKey = "ingestFolderBookmark"

    /// A plain path override, read from `UserDefaults` (so it can also be supplied as a
    /// launch argument: `-ingestInboxPath /some/folder`).
    ///
    /// Two uses: pointing the app at a synced folder that isn't iCloud Drive, and
    /// exercising the real capture path in the Simulator, where iCloud Drive is not
    /// available but the host filesystem is.
    static let pathOverrideKey = "ingestInboxPath"

    /// A Debug-only app-private fixture. UI-test processes and applications have
    /// separate sandboxes, so a runner-created temporary path cannot be the app's
    /// destination on current iOS runtimes. Core tests assert the bytes on disk;
    /// UI tests use this to exercise the actual capture and read-back flow.
    #if DEBUG
    static let testInboxIDKey = "BWTestCaptureInboxID"
    #endif

    private(set) var capture: MobileCaptureService
    private(set) var inboxDescription: String = "Not set"
    private(set) var backing: Backing = .none
    private(set) var recent: [RecentCapture] = []
    private(set) var inboxCount = 0
    private(set) var availableTags: [Tag] = []
    private(set) var workspaceFolders: [WorkspaceDestination] = []
    /// What this phone saved recently and where it asked for each save to be filed.
    private(set) var recentRecords: [RecentCaptureRecord] = []
    /// The Mac-published index (area roots and their direct children), which is how
    /// the phone learns that a capture has actually been placed.
    private(set) var publishedEntries: [MobileWorkspaceEntry] = []
    /// Tags the phone has changed on a filed capture, shown until the Mac republishes.
    private var tagOverrides: [String: Set<String>] = [:]
    private(set) var classificationCloudMessage: String?
    /// Separate from the tag-catalog message: this is the durable hand-off status for
    /// an already-saved capture.  The real file remains in Inbox in every state.
    private(set) var classificationDeliveryMessage: String?

    /// Filing and tags are optional intents attached only after the folder is saved.
    var selectedCaptureDestinationPath: String?
    /// `.idea` files the capture as an idea (its own folder in Ideas) instead of into
    /// a destination folder. Set by the New Idea widget, intent and Organize menu.
    var selectedCaptureKind: CaptureClassificationKind?
    /// Project, feature and milestone for a capture filed into a work queue. Optional.
    var selectedCaptureLinks = WorkItemLinks.none
    var selectedCaptureTagIDs: Set<String> = []
    private(set) var draftAttachments: [DraftAttachment] = []

    var statusMessage: String?
    var errorMessage: String?
    /// Where the last save went, kept on the capture card after the toast fades so a
    /// glance later still answers "did that go where I meant?".
    private(set) var lastSaveReceipt: String?

    enum Backing {
        case resolving
        case ubiquity
        case bookmark
        case none
    }

    struct RecentCapture: Identifiable, Hashable {
        let url: URL
        let name: String
        let kind: FileKind
        let modified: Date
        let expectedChildren: Set<String>
        var id: String { url.path }
    }

    /// A folder the Mac has explicitly published as a top-level Workspace area. This
    /// is a display/intent value only — Ingest never receives filesystem access to it.
    typealias WorkspaceDestination = MobileCaptureDestination

    /// Files are copied into this app-private staging area until Save creates one
    /// durable Inbox folder. Nothing reaches the shared Inbox while it is a draft.
    struct DraftAttachment: Identifiable, Hashable {
        let id: UUID
        let url: URL
        var name: String
        let isImage: Bool
    }

    private var scopedURL: URL?
    private let draftDirectory: URL
    private var refreshTask: Task<Void, Never>?
    private var inboxMonitorTask: Task<Void, Never>?
    private let cloudStore = MobileCloudStore()
    /// Shared with the Share extension and App Intents through the app group.
    var widgetCaptureName: String?
    private var captureQueue: MobileCaptureQueue
    /// An isolated UI run supplies its own tags and folders and never fetches CloudKit's.
    private var usesCatalogFixture = false
    private let widgetStore = WidgetSnapshotStore(appGroup: WidgetAppGroup.mobile)

    private struct RecentRefresh: Sendable {
        let captures: [RecentCapture]
        let inboxCount: Int
    }

    init() {
        #if DEBUG
        if let id = UserDefaults.standard.string(forKey: Self.testInboxIDKey) {
            captureQueue = MobileCaptureQueue(defaults: .standard, outboxKey: "mobileCaptureIntentOutbox.test.\(id)", logKey: "recentCaptureLog.test.\(id)")
        } else { captureQueue = .shared() }
        #else
        captureQueue = .shared()
        #endif
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        draftDirectory = base.appendingPathComponent("IngestDrafts", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: draftDirectory, withIntermediateDirectories: true)
        capture = MobileCaptureService(inbox: nil)
        backing = .resolving
        inboxDescription = "Connecting to iCloud…"
        #if DEBUG
        if let testInboxID = UserDefaults.standard.string(forKey: Self.testInboxIDKey) {
            // A test run's history and queued intents belong to its own Inbox, never
            // the history or outbox of the app installed on this device.
            captureQueue = MobileCaptureQueue(defaults: .standard,
                                              outboxKey: "mobileCaptureIntentOutbox.test.\(testInboxID)",
                                              logKey: "recentCaptureLog.test.\(testInboxID)")
            if UserDefaults.standard.bool(forKey: "BWTestCaptureCatalog") { installCatalogFixture() }
        }
        #endif
        if usesCatalogFixture == false, let catalog = captureQueue.catalog() {
            availableTags = catalog.tags
            workspaceFolders = catalog.destinations
        }
        recentRecords = captureQueue.log.load()
        Task { await resolveDestinationAsync() }
        Task { await refreshClassificationCatalog() }
        // A queued classification must recover after a relaunch, not only after the
        // user creates another capture. This makes a fixed dashboard/provisioning
        // issue self-healing without touching the file-first capture path.
        Task { await flushClassificationOutbox() }
    }

    // MARK: - Destination

    /// Resolves where captures go, without ever blocking the main actor.
    ///
    /// `url(forUbiquityContainerIdentifier:)` is documented as slow and can take seconds
    /// on a cold start, so it runs off-actor. Until it answers, the UI shows a
    /// "Connecting to iCloud…" state rather than wrongly telling the user to go and pick
    /// a folder.
    func resolveDestination() {
        Task { await resolveDestinationAsync() }
    }

    func resolveDestinationAsync() async {
        if let path = UserDefaults.standard.string(forKey: Self.pathOverrideKey), path.isEmpty == false {
            let url = URL(fileURLWithPath: path, isDirectory: true)
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            capture.setInbox(url)
            backing = .bookmark
            inboxDescription = url.lastPathComponent
            refreshRecent()
            return
        }

        #if DEBUG
        if let testInboxID = UserDefaults.standard.string(forKey: Self.testInboxIDKey),
           testInboxID.range(of: "^[A-Za-z0-9-]+$", options: .regularExpression) != nil,
           let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory,
                                                              in: .userDomainMask).first {
            let inbox = applicationSupport
                .appendingPathComponent("BWUITestInboxes", isDirectory: true)
                .appendingPathComponent(testInboxID, isDirectory: true)
            try? FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
            capture.setInbox(inbox)
            backing = .bookmark
            inboxDescription = "Test Inbox"
            // Isolated UI fixture: never enabled for an actual shared Inbox.
            if UserDefaults.standard.bool(forKey: "BWTestCaptureImageDraft") {
                let image = UIGraphicsImageRenderer(size: CGSize(width: 80, height: 80)).image { context in
                    UIColor.systemBlue.setFill()
                    context.fill(CGRect(x: 0, y: 0, width: 80, height: 80))
                }
                if let png = image.pngData() { stageImageData(png, name: "First image", ext: "png") }
                if let jpeg = image.jpegData(compressionQuality: 0.9) { stageImageData(jpeg, name: "Second image", ext: "jpeg") }
            }
            refreshRecent()
            return
        }
        #endif

        let containerID = IngestLocation.ubiquityContainerID
        let inbox = await Task.detached(priority: .userInitiated) { () -> URL? in
            guard let container = FileManager.default.url(forUbiquityContainerIdentifier: containerID) else {
                return nil
            }
            let inbox = container
                .appendingPathComponent("Documents", isDirectory: true)
                .appendingPathComponent(IngestLocation.inboxName, isDirectory: true)
            try? FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
            return inbox
        }.value

        if let inbox {
            capture.setInbox(inbox)
            backing = .ubiquity
            inboxDescription = "iCloud · Better Workspace"
            refreshRecent()
            return
        }

        // No container — either iCloud is off or this build has no entitlement. Fall back
        // to a folder the user picked once.
        if restoreBookmark() { refreshRecent(); return }
        backing = .none
        inboxDescription = "Not set"
        // Nothing will list an inbox that does not exist, so this is the only resolve-time
        // publish: it moves a first run into the widget's setup state.
        publishWidgetSnapshot()
    }

    #if DEBUG
    private func installCatalogFixture() {
        usesCatalogFixture = true
        availableTags = ["Cooking", "Photography", "Programming", "Projects", "Reference"]
            .map { Tag(id: "fixture-\($0)", name: $0, colorIndex: Tag.colorIndex(for: $0)) }
        workspaceFolders = [WorkspaceDestination(path: "Features", name: "Features"),
                            WorkspaceDestination(path: "For Reference", name: "For Reference"),
                            WorkspaceDestination(path: "Ideas", name: "Ideas")]
    }
    #endif

    // MARK: - Recently Added

    /// Recent saves wherever they went, plus anything else waiting in the Inbox.
    var recentRows: [RecentCaptureRow] {
        RecentCaptureHistory.rows(records: recentRecords,
                                  inbox: recent.map { ($0.url, $0.modified) },
                                  entries: publishedEntries)
    }

    /// Folders up front in the destination menu: recently used first, then the start
    /// of the Mac's list. The rest stay under More, in the order the Mac publishes.
    private(set) var recentDestinationsRevision = 0
    func splitDestinations(limit: Int) -> (leading: [WorkspaceDestination], rest: [WorkspaceDestination]) {
        _ = recentDestinationsRevision
        let leading = RecentDestinations(defaults: .standard).leading(workspaceFolders, limit: limit, name: \.name)
        let shown = Set(leading.map(\.path))
        return (leading, workspaceFolders.filter { shown.contains($0.path) == false })
    }

    private func noteFiled(into destination: WorkspaceDestination?) {
        guard let destination else { return }
        RecentDestinations(defaults: .standard).record(destination.name)
        recentDestinationsRevision += 1
    }

    /// Inbox items with no destination yet: the ones that actually need filing.
    var needsFilingCount: Int {
        let routed = Set(recentRecords.filter { $0.destinationPath != nil }.map(\.name))
        return max(0, inboxCount - recent.filter { routed.contains($0.name) }.count)
    }

    func recentCapture(for row: RecentCaptureRow) -> RecentCapture? {
        guard let url = row.inboxURL else { return nil }
        return recent.first { $0.url == url }
    }

    func publishedEntry(atPath path: String) -> MobileWorkspaceEntry? {
        publishedEntries.first { $0.path == path }
    }

    /// The tags a filed capture has, including changes still on their way to the Mac.
    func tagIDs(ofFiledPath path: String) -> Set<String> {
        tagOverrides[path] ?? publishedEntry(atPath: path)?.tagIDs ?? []
    }

    /// Tags a capture that is already filed, through the same tag-change command the
    /// Workspace tabs send. The phone never edits the Workspace itself.
    func toggleTag(_ tagID: String, onFiledPath path: String) {
        guard let entry = publishedEntry(atPath: path) else { return }
        var tags = tagIDs(ofFiledPath: path)
        let adding = tags.contains(tagID) == false
        if adding { tags.insert(tagID) } else { tags.remove(tagID) }
        tagOverrides[path] = tags
        queueClassification(.tagChange(path: path, baseRevision: entry.revision,
                                       adding: adding ? [tagID] : [], removing: adding ? [] : [tagID]))
    }

    /// Creates a tag, or finds the one that already has this name, and answers its id.
    func tagForName(_ name: String) -> Tag? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return nil }
        if let existing = TagMatching.equivalent(to: trimmed, in: availableTags) { return existing }
        let tag = Tag(name: trimmed, colorIndex: Tag.colorIndex(for: trimmed))
        availableTags.append(tag)
        availableTags.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        captureQueue.queueNewTag(tag)
        flushSoon()
        return tag
    }

    // MARK: - Optional classification

    func toggleCaptureTag(_ tagID: String) {
        if selectedCaptureTagIDs.contains(tagID) {
            selectedCaptureTagIDs.remove(tagID)
        } else {
            selectedCaptureTagIDs.insert(tagID)
        }
    }

    /// Adds a tag to this draft immediately, then sends a durable creation command
    /// before the capture's classification command. The Mac creates the tag with this
    /// same ID and republishes it to every device.
    func createCaptureTag(named name: String) {
        guard let tag = tagForName(name) else { return }
        selectedCaptureTagIDs.insert(tag.id)
    }

    func selectCaptureDestination(_ destination: WorkspaceDestination) {
        if selectedCaptureDestinationPath == destination.path {
            selectedCaptureDestinationPath = nil
        } else {
            selectedCaptureDestinationPath = destination.path
        }
    }

    func refreshClassificationCatalog() async {
        if usesCatalogFixture { return }
        // UI tests and offline capture must not be held hostage by CloudKit account
        // setup.  A disabled or unreachable service simply leaves the optional tag
        // picker empty; the store refuses before it constructs a container, so nothing
        // here depends on CloudKit being usable.
        do {
            let snapshot = try await cloudStore.fetchSnapshot()
            availableTags = snapshot.tags
            publishedEntries = snapshot.entries
            if let overview = snapshot.overview {
                publishedEntries.append(MobileWorkspaceEntry(path: OverviewDigest.path, parentPath: nil, name: "Overview", isDirectory: false, revision: 0, overview: overview))
            }
            // The Mac's index now speaks for itself; drop optimistic tags it has caught up with.
            tagOverrides = tagOverrides.filter { path, tags in
                snapshot.entries.first(where: { $0.path == path }).map { $0.tagIDs != tags } ?? true
            }
            workspaceFolders = MobileCaptureCatalog.destinations(from: snapshot.entries)
            captureQueue.saveCatalog(MobileCaptureCatalog(tags: availableTags, destinations: workspaceFolders))
            if workspaceFolders.isEmpty {
                classificationCloudMessage = "Workspace folders will appear when the Mac syncs."
            } else if availableTags.isEmpty {
                classificationCloudMessage = "Tags will appear when the Mac syncs."
            } else {
                classificationCloudMessage = nil
            }
        } catch {
            classificationCloudMessage = "Tags will sync when CloudKit is available."
        }
    }

    /// Files, or only tags, a capture that is still in the Inbox. With no destination
    /// it stays in the Inbox, still waiting to be filed, with its tags attached.
    func reviewSettings(for capture: RecentCapture) -> MobileCaptureReview? {
        let records = try? WidgetCommandStore.shared(appGroup: WidgetAppGroup.mobile)?.records()
        if let queued = records?.last(where: { $0.pending && $0.edit?.captureReview?.capture.name == capture.name })?.edit?.captureReview { return queued }
        return publishedEntries.first { $0.path == OverviewDigest.path }?.overview?.captureReviews?.first { $0.capture.name == capture.name }
    }

    func schedule(_ capture: RecentCapture, priority: Int, until: Date?) {
        let edit = MobilePlanningEdit(operation: .scheduleCapture, title: capture.name,
            captureReview: MobileCaptureReview(capture: DashboardCapture(name: capture.name, modified: capture.modified, expectedChildren: capture.expectedChildren), priority: priority, until: until))
        do {
            try MobilePlanningFiles.validate(edit)
            let intent = MobileWorkspaceIntent.planning(edit)
            if let store = WidgetCommandStore.shared(appGroup: WidgetAppGroup.mobile) { try store.append(intent, stream: "capture") }
            captureQueue.outbox.append(intent)
            classificationCloudMessage = "Priority and return date saved · waiting for the Mac"
            Task { await flushClassificationOutbox() }
        } catch { classificationCloudMessage = error.localizedDescription }
    }

    func classify(_ capture: RecentCapture, tagIDs: Set<String>, destination: WorkspaceDestination?) {
        guard destination != nil || tagIDs.isEmpty == false else { return }
        let intent = MobileWorkspaceIntent.captureClassification(
            name: capture.name, kind: nil, tagIDs: tagIDs, destinationPath: destination?.path,
            expectedChildren: capture.expectedChildren
        )
        queueClassification(intent)
        noteFiled(into: destination)
        if let destination {
            recentRecords = captureQueue.log.setDestination(name: capture.name, savedAt: capture.modified,
                                                     destinationPath: destination.path,
                                                     destinationName: destination.name)
            statusMessage = "Filing to \(destination.name)"
        } else {
            statusMessage = "Tags added. Still in Inbox"
        }
    }

    private func queueClassification(_ intent: MobileWorkspaceIntent) {
        captureQueue.outbox.append(intent)
        flushSoon()
    }

    private func flushSoon() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            await flushClassificationOutbox()
        }
    }

    private func clearCaptureClassification() {
        selectedCaptureDestinationPath = nil
        selectedCaptureKind = nil
        selectedCaptureTagIDs = []
        selectedCaptureLinks = .none
    }

    /// The local outbox is the durable hand-off while offline.  Captures remain real
    /// files even if a classification is never delivered. The failure is visible, but
    /// it remains non-blocking and retryable for configuration/connectivity problems.
    func flushClassificationOutbox() async {
        let result = await captureQueue.flush(using: cloudStore)
        if let error = result.blockedBy {
            classificationDeliveryMessage = Self.deliveryMessage(for: error)
        } else if let error = result.discardedBy {
            classificationDeliveryMessage = "The optional classification could not be sent: \(error.localizedDescription) The file is safely in Inbox."
        } else if result.delivered > 0 {
            classificationDeliveryMessage = nil
        }
    }

    private static func deliveryMessage(for error: MobileCloudError) -> String {
        switch error {
        case .configuration:
            return "Classification is queued until CloudKit is configured. The file is safely in Inbox."
        case .noAccount:
            return "Classification is queued until this device can use iCloud. The file is safely in Inbox."
        case .turnedOff, .unavailable:
            return "Classification is queued and will retry when CloudKit is available. The file is safely in Inbox."
        case .rejected, .malformedRecord:
            return "The optional classification could not be sent. The file is safely in Inbox."
        }
    }

    /// Stores the picked folder as a security-scoped bookmark so the choice survives
    /// relaunch without re-prompting.
    func setDestination(_ url: URL) {
        do {
            let bookmark = try url.bookmarkData(options: .minimalBookmark,
                                                includingResourceValuesForKeys: nil,
                                                relativeTo: nil)
            UserDefaults.standard.set(bookmark, forKey: Self.bookmarkKey)
            _ = url.startAccessingSecurityScopedResource()
            scopedURL = url
            capture.setInbox(url)
            backing = .bookmark
            inboxDescription = url.lastPathComponent
            statusMessage = "Captures will go to \(url.lastPathComponent)"
            refreshRecent()
        } catch {
            errorMessage = "Could not remember that folder: \(error.localizedDescription)"
        }
    }

    private func restoreBookmark() -> Bool {
        guard let data = UserDefaults.standard.data(forKey: Self.bookmarkKey) else { return false }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: [],
                                 relativeTo: nil, bookmarkDataIsStale: &stale)
        else { return false }
        _ = url.startAccessingSecurityScopedResource()
        scopedURL = url
        capture.setInbox(url)
        backing = .bookmark
        inboxDescription = url.lastPathComponent
        return true
    }

    var isReady: Bool { backing == .ubiquity || backing == .bookmark }

    /// Still working out where captures go — don't nag the user to pick a folder yet.
    var isResolving: Bool { backing == .resolving }

    /// Lets the user point the app somewhere else even when iCloud resolved fine.
    func clearBookmark() {
        UserDefaults.standard.removeObject(forKey: Self.bookmarkKey)
    }

    // MARK: - Capture

    func stageImageData(_ data: Data, name: String, ext: String) {
        let url = CaptureNaming.uniqueURL(in: draftDirectory, base: CaptureNaming.safeFilename(name), extension: ext)
        do {
            try data.write(to: url, options: .atomic)
            draftAttachments.append(DraftAttachment(id: UUID(), url: url, name: url.deletingPathExtension().lastPathComponent, isImage: true))
        } catch {
            errorMessage = "Could not prepare the image: \(error.localizedDescription)"
        }
    }

    func stageFiles(_ urls: [URL]) {
        var added = 0
        for source in urls {
            let scoped = source.startAccessingSecurityScopedResource()
            defer { if scoped { source.stopAccessingSecurityScopedResource() } }
            let destination = CaptureNaming.uniqueURL(
                in: draftDirectory,
                base: CaptureNaming.safeFilename(source.deletingPathExtension().lastPathComponent),
                extension: source.pathExtension
            )
            do {
                try FileManager.default.copyItem(at: source, to: destination)
                let values = try? destination.resourceValues(forKeys: [.contentTypeKey])
                let image = values?.contentType?.conforms(to: .image) == true
                draftAttachments.append(DraftAttachment(id: UUID(), url: destination,
                                                        name: destination.deletingPathExtension().lastPathComponent, isImage: image))
                added += 1
            } catch {
                errorMessage = "Could not prepare \(source.lastPathComponent): \(error.localizedDescription)"
            }
        }
        if added > 0 { IngestGuidance.savedAttachment = true }
    }

    func removeDraftAttachment(_ attachment: DraftAttachment) {
        try? FileManager.default.removeItem(at: attachment.url)
        draftAttachments.removeAll { $0.id == attachment.id }
    }

    func renameDraftAttachment(_ id: UUID, title: String) {
        guard let index = draftAttachments.firstIndex(where: { $0.id == id }) else { return }
        draftAttachments[index].name = title
    }

    /// Each saved file receives its own durable routing intent. Successful entries
    /// leave the draft even if another entry fails, so a retry cannot duplicate them.
    func saveDraft(note: String, title: String, link: String) async -> (noteSaved: Bool, complete: Bool) {
        let noteID = UUID()
        var entries = draftAttachments.map {
            CaptureDraftEntry(id: $0.id, title: $0.name, content: .file($0.url))
        }
        if let entry = CaptureDraftEntry.note(id: noteID, title: title, markdown: note, url: link) { entries.insert(entry, at: 0) }
        let service = capture
        let result = await Task.detached(priority: .userInitiated) { service.capture(entries) }.value
        let destination = selectedCaptureDestination
        let kind = selectedCaptureKind
        if result.saved.isEmpty == false { noteFiled(into: destination) }
        for saved in result.saved {
            recentRecords = captureQueue.record(savedURL: saved.url, destination: destination,
                                                kind: kind, tagIDs: selectedCaptureTagIDs, links: captureLinks)
            if let attachment = draftAttachments.first(where: { $0.id == saved.id }) {
                removeDraftAttachment(attachment)
            }
        }
        if !result.saved.isEmpty {
            statusMessage = MobileCaptureQueue.savedMessage(count: result.saved.count, destination: destination, kind: kind)
            lastSaveReceipt = statusMessage
            IngestGuidance.captured()
            flushSoon()
        }
        errorMessage = result.failures.isEmpty ? nil : result.failures.map(\.message).joined(separator: "\n")
        if result.failures.isEmpty { clearCaptureClassification() }
        refreshRecent()
        return (result.saved.contains { $0.id == noteID }, result.failures.isEmpty)
    }

    /// Links only travel with a capture going to a work queue.
    var captureLinks: WorkItemLinks? {
        guard let kind = selectedCaptureDestination?.workItemKind else { return nil }
        return selectedCaptureLinks.applicable(to: kind)
    }

    /// The destination chosen in Organize, if it is still one the Mac publishes.
    var selectedCaptureDestination: WorkspaceDestination? {
        guard selectedCaptureKind != .idea else { return nil }
        return selectedCaptureDestinationPath.flatMap { path in workspaceFolders.first { $0.path == path } }
    }

    @discardableResult
    func saveBundle(note: String) -> Bool {
        do {
            let url = try capture.captureBundle(note: note, attachmentURLs: draftAttachments.map(\.url))
            let destination = selectedCaptureDestination
            let kind = selectedCaptureKind
            recentRecords = captureQueue.record(savedURL: url, destination: destination,
                                                kind: kind, tagIDs: selectedCaptureTagIDs, links: captureLinks)
            flushSoon()
            clearCaptureClassification()
            for attachment in draftAttachments { try? FileManager.default.removeItem(at: attachment.url) }
            draftAttachments = []
            statusMessage = MobileCaptureQueue.savedMessage(count: 1, destination: destination, kind: kind)
            lastSaveReceipt = statusMessage
            IngestGuidance.captured()
            refreshRecent()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    /// A capture is disposable until it is filed. The service validates that the row is
    /// still a direct Inbox child before removing it.
    func delete(_ recentCapture: RecentCapture) {
        let service = capture
        Task {
            do {
                try await Task.detached(priority: .userInitiated) {
                    try service.deleteCapture(at: recentCapture.url)
                }.value
                statusMessage = "Deleted \(recentCapture.name)"
                recentRecords = captureQueue.log.forget(name: recentCapture.name)
                refreshRecent()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    /// Never block the main actor on this.
    ///
    /// The inbox is an iCloud folder, and enumerating one goes through the file
    /// provider, which can stall for a long time — long enough to make the app look
    /// hung. The listing runs off-actor and gives up rather than waiting.
    func refreshRecent() {
        refreshTask?.cancel()
        let service = capture
        refreshTask = Task { [weak self] in
            let listing: RecentRefresh? = await withTaskGroup(of: RecentRefresh?.self) { group in
                group.addTask {
                    await Task.detached(priority: .utility) { () -> RecentRefresh? in
                        // A nil overview is an unreadable inbox, not an empty one; the
                        // last known listing and count stay on screen.
                        // Wider than the visible list: Recently Added decides "still in
                        // the Inbox" from this listing, so a recent save must not fall
                        // off the end of it just because the Inbox is busy.
                        guard let overview = service.recentCaptureOverview(limit: 100) else { return nil }
                        let captures = overview.urls.map { url in
                            let values = try? url.resourceValues(
                                forKeys: [.isDirectoryKey, .contentModificationDateKey])
                            let isDir = values?.isDirectory ?? false
                            return RecentCapture(
                                url: url,
                                name: url.lastPathComponent,
                                kind: FileKind.classify(url: url, isDirectory: isDir),
                                modified: values?.contentModificationDate ?? Date(),
                                expectedChildren: MobileCaptureBundleReceipt.children(at: url) ?? []
                            )
                        }
                        return RecentRefresh(captures: captures, inboxCount: overview.totalCount)
                    }.value
                }
                group.addTask {
                    try? await Task.sleep(for: .seconds(5))
                    return nil
                }
                let first = await group.next() ?? nil
                group.cancelAll()
                return first
            }
            guard let self, Task.isCancelled == false, let listing else { return }
            self.recent = listing.captures
            self.inboxCount = listing.inboxCount
            self.publishWidgetSnapshot()
        }
    }

    /// The Mac removes an item from the shared Inbox after filing it. Poll only while
    /// this foreground capture screen is open so that removal becomes visible without
    /// a relaunch while avoiding background file-provider work.
    func setInboxMonitoring(active: Bool) {
        inboxMonitorTask?.cancel()
        inboxMonitorTask = nil
        guard active else { return }
        // The Share extension and App Intents write the same history and outbox.
        recentRecords = captureQueue.log.load()
        flushSoon()
        refreshRecent()
        Task { @MainActor [weak self] in
            await self?.refreshClassificationCatalog()
        }
        inboxMonitorTask = Task { @MainActor [weak self] in
            while Task.isCancelled == false {
                try? await Task.sleep(for: .seconds(15))
                guard let self, Task.isCancelled == false else { return }
                self.refreshRecent()
            }
        }
    }

    private func publishWidgetSnapshot() {
        #if DEBUG
        guard UserDefaults.standard.string(forKey: Self.testInboxIDKey) == nil else { return }
        #endif
        let newestCapture = recent.first.map {
            IngestWidgetCapture(name: $0.name, modifiedAt: $0.modified)
        }
        let state: IngestWidgetSnapshot.State = isReady ? .ready : .needsInbox
        let latest = recentRows.first.map { row -> IngestWidgetCapture in
            IngestWidgetCapture(name: row.name, modifiedAt: row.date, status: Self.widgetStatus(row.placement))
        } ?? newestCapture
        let snapshot = IngestWidgetSnapshot(state: state, inboxCount: inboxCount,
                                            newestCapture: latest, needsFilingCount: needsFilingCount)
        // Destination resolution runs on every launch and can transiently fail, so this
        // must not be the thing that wipes the widget back to its setup state.
        guard widgetStore?.savePreservingLastKnownGood(snapshot) == true else { return }
        if let store = WidgetCommandStore.shared(appGroup: WidgetAppGroup.mobile) {
            try? DashboardWidgetStore.update(directory: store.directory) { existing in
                var dashboard = existing ?? WorkspaceDashboardSnapshot(updatedAt: snapshot.updatedAt)
                dashboard.captures = recent.prefix(30).map { DashboardCapture(name: $0.name, modified: $0.modified, expectedChildren: $0.expectedChildren) }
                dashboard.captureCount = needsFilingCount; dashboard.captureUpdatedAt = snapshot.updatedAt
                if dashboard.destinations.isEmpty { dashboard.destinations = workspaceFolders.map { .init(path: $0.path, name: $0.name) } }
                return dashboard
            }
        }
        WidgetCenter.shared.reloadAllTimelines()
        WidgetCenter.shared.reloadTimelines(ofKind: WidgetKind.quickCapture)
        // The consolidated app has no separate Inbox widget. Its normal workspace
        // widgets keep their last CloudKit-published state instead of being replaced
        // with an unrelated local inbox count.
    }

    private static func widgetStatus(_ placement: RecentCapturePlacement) -> String {
        switch placement {
        case .needsFiling: return "Needs filing"
        case .filing(let destination): return "Filing to \(destination)"
        case .filed(let destination, _): return "In \(destination)"
        case .filedOnMac: return "Filed on your Mac"
        }
    }

    // MARK: - App Intents

    /// Waits for the Inbox to resolve, as an intent launched with no scene must.
    func ensureInboxResolved(timeout: Duration = .seconds(20)) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while backing == .resolving, clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
        return isReady
    }

    enum IntentCaptureError: LocalizedError {
        case noInbox
        case empty
        case failed(String)
        var errorDescription: String? {
            switch self {
            case .noInbox: return "Better Workspace has no Inbox yet. Open the app once to connect iCloud or choose a folder."
            case .empty: return "There is nothing to capture."
            case .failed(let message): return message
            }
        }
    }

    /// The App Intents' save: the same `MobileCaptureService` write and the same
    /// capture queue as the Capture screen. Success means the file is in the Inbox;
    /// filing happens when the Mac syncs.
    func captureFromIntent(text: String?, title: String?, link: String?, files: [(data: Data, filename: String)],
                           destination: MobileCaptureDestination?, kind: CaptureClassificationKind?,
                           tags: [Tag]) async throws -> String {
        guard await ensureInboxResolved() else { throw IntentCaptureError.noInbox }
        var entries: [CaptureDraftEntry] = []
        if let note = CaptureDraftEntry.note(id: UUID(), title: title ?? "", markdown: text ?? "", url: link ?? "") {
            entries.append(note)
        }
        for file in files {
            let base = (file.filename as NSString).deletingPathExtension
            let ext = (file.filename as NSString).pathExtension
            let named = entries.isEmpty ? (title ?? "") : ""
            entries.append(CaptureDraftEntry(title: named.isEmpty ? base : named, content: .data(file.data, extension: ext)))
        }
        guard entries.isEmpty == false else { throw IntentCaptureError.empty }
        let service = capture
        let result = await Task.detached(priority: .userInitiated) { service.capture(entries) }.value
        let tagIDs = Set(tags.map(\.id))
        for saved in result.saved {
            recentRecords = captureQueue.record(savedURL: saved.url, destination: kind == .idea ? nil : destination,
                                                kind: kind, tagIDs: tagIDs)
        }
        if result.saved.isEmpty, let failure = result.failures.first { throw IntentCaptureError.failed(failure.message) }
        IngestGuidance.captured()
        await flushClassificationOutbox()
        refreshRecent()
        let message = MobileCaptureQueue.savedMessage(count: result.saved.count, destination: kind == .idea ? nil : destination, kind: kind)
        lastSaveReceipt = message
        return message
    }

    /// Tags and folders for intent parameters: the live catalog if loaded, otherwise
    /// the last one the Mac published.
    func intentCatalog() async -> MobileCaptureCatalog {
        if availableTags.isEmpty && workspaceFolders.isEmpty { await refreshClassificationCatalog() }
        if availableTags.isEmpty && workspaceFolders.isEmpty, let cached = captureQueue.catalog() { return cached }
        return MobileCaptureCatalog(tags: availableTags, destinations: workspaceFolders)
    }

    /// Resolves an intent's tag choices: known ids, plus names typed in Shortcuts.
    func intentTags(ids: [String], newNames: [String]) -> [Tag] {
        let known = availableTags.isEmpty ? (captureQueue.catalog()?.tags ?? []) : availableTags
        var tags = ids.compactMap { id in known.first { $0.id == id } }
        for tag in captureQueue.tags(named: newNames) where tags.contains(tag) == false { tags.append(tag) }
        // New tags are shown at once, as the Capture screen's own Create does.
        for tag in tags where availableTags.contains(where: { $0.id == tag.id }) == false { availableTags.append(tag) }
        availableTags.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return tags
    }
}
