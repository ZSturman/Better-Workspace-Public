import Foundation
import Observation
import WidgetKit
import UIKit
import BetterWorkspaceCore

@MainActor
@Observable
final class MobileWorkspaceModel {
    /// Sample browsing uses its own preferences and never queues Mac/cloud actions.
    let isSample: Bool
    private let sampleDefaultsName: String?
    enum SyncState: Equatable {
        case loading
        case ready(Date)
        /// Showing the last index CloudKit answered, with the reason it is not live.
        case cached(Date, String)
        /// Nothing to show and no way to get it right now.
        case unavailable(String)
    }

    // One ordered queue prevents an older cache/widget write from finishing after a newer one.
    private let snapshotWriteQueue = DispatchQueue(label: "BetterWorkspace.mobile-snapshots", qos: .utility)
    private var widgetPublishWork: DispatchWorkItem?
    private let cloudStore = MobileCloudStore()
    private let outbox: MobileIntentOutbox
    private let draftStore: MobilePlanningDraftStore
    private let widgetCommands: WidgetCommandStore?
    private let planningDefaults: UserDefaults
    var overviewDefaults: UserDefaults { planningDefaults }
    private var flushing = false
    /// The refresh in progress. A second request waits for it rather than returning at
    /// once: a pull that silently did nothing ended its spinner with stale data on screen.
    private var refreshTask: Task<Void, Never>?
    var refreshing: Bool { refreshTask != nil }
    /// CloudKit calls can stall (throttling, a poor network). Past this the refresh stops
    /// waiting, keeps what is on screen and says so, so later refreshes are not blocked.
    static let refreshTimeout: TimeInterval = 180
    private var cleaningReceipts = false
    private(set) var planningDrafts: [MobilePlanningEdit] = []
    var planningErrors: [String: String] = [:]
    var saveMessage: String?
    private var receiptCleanup: Set<UUID> = []
    private var backgroundFlush: UIBackgroundTaskIdentifier = .invalid
    /// Drafts the Mac reports applied while the downloaded index still shows the record
    /// as it was. CloudKit queries lag behind writes, so dropping the draft on the receipt
    /// alone made a completed task flip back to open until a later refresh. The draft's
    /// effect stays on screen until the index shows it, or for ten minutes at most.
    private var appliedAt: [UUID: Date] = [:]
    static let appliedDraftGrace: TimeInterval = 600
    private let widgetStore = WidgetSnapshotStore(appGroup: WidgetAppGroup.mobile)
    private let snapshotCache = MobileSnapshotCache(appGroup: WidgetAppGroup.mobile)

    let downloadCache: MobileDownloadCache
    private(set) var downloads: [MobileDownloadState] = []
    private var receivingDownloads = false

    private(set) var snapshot = MobileWorkspaceSnapshot()
    /// Received records before optimistic phone drafts: used for history and source comparisons.
    private(set) var macWorkItems: [MobileWorkItem] = []
    private var macEntries: [MobileWorkspaceEntry] = []
    private var macIdeas: [MobileIdea] = []
    private(set) var syncState: SyncState = .loading
    var widgetNavigation: WidgetRoute?
    var widgetReviewItemID: String?
    var selectedTagIDs: Set<String> = []
    private(set) var pendingIntentCount = 0
    /// Tag taps the Mac's index may not show yet; kept over each refresh.
    private var pendingTags = PendingTagChanges()

    /// True when what is on screen came out of the cache rather than from CloudKit.
    var isShowingCachedIndex: Bool {
        if case .cached = syncState { return true }
        return false
    }

    var isCachedIndexStale: Bool {
        guard case .cached = syncState else { return false }
        return MobileSnapshotCache.isStale(snapshot)
    }

    init(sampleSnapshot: MobileWorkspaceSnapshot? = nil) {
        isSample = sampleSnapshot != nil
        sampleDefaultsName = sampleSnapshot == nil ? nil : "BetterWorkspace.Sample.\(UUID().uuidString)"
        let downloadRoot: URL
        if sampleSnapshot != nil || UserDefaults.standard.bool(forKey: "BWTestMobilePlanning") {
            downloadRoot = FileManager.default.temporaryDirectory.appendingPathComponent("bw-offline-fixture-" + UUID().uuidString)
        } else {
            downloadRoot = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("WorkspaceDownloads")
        }
        downloadCache = MobileDownloadCache(root: downloadRoot)
        #if DEBUG
        let fixture = !isSample && UserDefaults.standard.bool(forKey: "BWTestMobilePlanning")
        #endif
        if let sampleDefaultsName {
            planningDefaults = UserDefaults(suiteName: sampleDefaultsName)!
            widgetCommands = nil
        } else {
        #if DEBUG
        // `-BWResetPlanningFixture YES`: start from the fixture as written, not from drafts
        // another test saved into the same private suite.
        if fixture, UserDefaults.standard.bool(forKey: "BWResetPlanningFixture") {
            UserDefaults.standard.removePersistentDomain(forName: "BWPlanningUITests")
        }
        planningDefaults = fixture ? UserDefaults(suiteName: "BWPlanningUITests")! : .standard
        #else
        planningDefaults = .standard
        #endif
        #if DEBUG
        widgetCommands = fixture ? nil : WidgetCommandStore.shared(appGroup: WidgetAppGroup.mobile)
        #else
        widgetCommands = WidgetCommandStore.shared(appGroup: WidgetAppGroup.mobile)
        #endif
        }
        try? widgetCommands?.migrate(defaults: planningDefaults, outboxKey: "mobileWorkspaceIntentOutbox", stream: "workspace", planning: true)
        outbox = MobileIntentOutbox(defaults: planningDefaults, ledger: widgetCommands)
        if !isSample, let data = planningDefaults.data(forKey: "BWOfflineDownloads"), data.count <= 4_000_000,
           let saved = try? JSONDecoder().decode([MobileDownloadState].self, from: data) { downloads = saved }
        draftStore = MobilePlanningDraftStore(defaults: planningDefaults, ledger: widgetCommands)
        receiptCleanup = Set((planningDefaults.stringArray(forKey: "BWPlanningReceiptCleanup") ?? []).compactMap(UUID.init(uuidString:)))
        planningDrafts = draftStore.load()
        planningErrors = planningDefaults.dictionary(forKey: "BWMobilePlanningErrors") as? [String: String] ?? [:]
        appliedAt = ((planningDefaults.dictionary(forKey: "BWPlanningAppliedAt") as? [String: Double]) ?? [:])
            .reduce(into: [:]) { result, pair in
                if let id = UUID(uuidString: pair.key) { result[id] = Date(timeIntervalSince1970: pair.value) }
            }
        pendingIntentCount = outbox.count
        if let sampleSnapshot {
            snapshot = sampleSnapshot
            macWorkItems = snapshot.workItems; macEntries = snapshot.entries; macIdeas = snapshot.ideas
            syncState = .ready(sampleSnapshot.fetchedAt)
            return
        }
        // The cache is read before the first request so a phone that is offline, signed
        // out, or simply slow opens on the index it last saw. Nothing here touches
        // CloudKit: constructing a container is deferred until a refresh actually runs.
        #if DEBUG
        if fixture {
            snapshot = MobileWorkspaceSnapshot(
                tags: [Tag(id: "test-tag", name: "Design", colorIndex: 1, createdAt: Date())],
                entries: [MobileWorkspaceEntry(path: "Projects/Example", parentPath: "Projects", name: "Example", isDirectory: true, revision: 1, modifiedAt: Date(), projectDetails: MobileProjectDetails(path: "Projects/Example", oneLiner: "A clearer workspace", assessment: MobileParityFixture.assessment, projectID: "fixture-project", ratings: [:], scoringPreferences: ProjectScoringPreferences(), needsSetup: true,
                        previews: [MobileFilePreview(path: "Projects/Example/README.md", name: "README.md", text: "Read-only project file preview.")])),
                    MobileWorkspaceEntry(path: "Ideas/Potential studio", parentPath: "Ideas", name: "Potential studio", isDirectory: true, revision: 1, modifiedAt: Date(timeIntervalSince1970: 1_700_000_000)),
                    MobileWorkspaceEntry(path: "Ideas/Example.md", parentPath: "Ideas", name: "Example.md", isDirectory: false, revision: 1, modifiedAt: Date())],
                workItems: [MobileWorkItem(id: "test-work", path: "Projects/Example/Work/Next.bw.md", title: "Sketch the next screen", kind: .task,
                    status: .open, stage: .now, priority: .high, projectPath: "Projects/Example", revision: 1, body: "## Plan\n\nKeep the **next action** clear.\n\n- [ ] Sketch the empty state\n- [x] List the screens", actionMetadata: MobileParityFixture.action, createdAt: Date(timeIntervalSinceNow: -14 * 86400), modifiedAt: Date(timeIntervalSinceNow: -86400)),
                    MobileWorkItem(id: "test-feature", path: "Projects/Example/Work/Offline.bw.md", title: "Offline reading", kind: .feature,
                        status: .inProgress, stage: .later, priority: .low, projectPath: "Projects/Example", revision: 1, body: "Open on the last index.", createdAt: Date(timeIntervalSinceNow: -21 * 86400), modifiedAt: Date(timeIntervalSinceNow: -2 * 86400)),
                    // No project: listed under Needs Attention.
                    MobileWorkItem(id: "test-unplaced", path: "Features/Unplaced.bw.md", title: "Unplaced feature", kind: .feature,
                        status: .open, stage: .next, priority: .medium, revision: 1, body: "", featureIDs: [], milestoneIDs: []),
                    MobileWorkItem(id: "test-done", path: "Projects/Example/Work/Done.bw.md", title: "Write the brief", kind: .task,
                        status: .completed, stage: .next, priority: .medium, projectPath: "Projects/Example", revision: 1, body: "", createdAt: Date(timeIntervalSinceNow: -21 * 86400), modifiedAt: Date(timeIntervalSinceNow: -3 * 86400), completedAt: Date(timeIntervalSinceNow: -3 * 86400))],
                ideas: [MobileIdea(path: "Ideas/Potential studio", title: "Potential studio", revision: 1, modifiedAt: Date(timeIntervalSince1970: 1_700_000_000), description: "Keep the entire idea and its files together.", attachments: [MobileIdeaAttachment(path: "Ideas/Potential studio/reference.png", name: "reference.png")], serviceID: "fixture-studio", planning: IdeaPlanning(priority: 4, ratings: ["qualityOfLife": 4], potential: .project), scoringPreferences: ProjectScoringPreferences()),
                    MobileIdea(path: "Ideas/Example.md", title: "A simpler capture flow", revision: 1, tagIDs: ["test-tag"], modifiedAt: Date(),
                    description: "Title, description, then supporting files.", attachments: [MobileIdeaAttachment(path: "Ideas/reference.png", name: "reference.png")], serviceID: "fixture-idea", planning: IdeaPlanning(), scoringPreferences: ProjectScoringPreferences())])
            snapshot.overview = OverviewDigest(focusItems: [
                OverviewFocusItem(id: "Projects/Example", path: "Projects/Example", title: "Example", kind: .projects, score: 88, completed: 1, total: 2, lastWorked: Date(timeIntervalSinceNow: -21 * 86_400)),
                OverviewFocusItem(id: "test-feature", path: "Projects/Example/Work/Offline.bw.md", title: "Offline reading", kind: .features, completed: 2, total: 3, lastChanged: Date(timeIntervalSinceNow: -40 * 86_400)),
                OverviewFocusItem(id: "Ideas/Example.md", path: "Ideas/Example.md", title: "A simpler capture flow", kind: .ideas, lastChanged: Date(timeIntervalSinceNow: -9 * 86_400))
            ], inboxItem: OverviewInboxItem(id: "fixture-review", path: "To Study/Review.md", title: "Review the next screen.md", category: "To Study", modified: Date(timeIntervalSince1970: 1_700_000_000), size: 32, preview: "Review a small piece of work without losing your place.", link: URL(string: "https://example.com")), inboxCheckedAt: Date())
            macWorkItems = snapshot.workItems; macEntries = snapshot.entries; macIdeas = snapshot.ideas
            syncState = .cached(Date(), "Isolated UI fixture")
            applyPlanningDrafts()
            return
        }
        #endif
        #if DEBUG
        // `-BWIgnoreSnapshotCache YES`: behave like a fresh install, so first-launch
        // states (loading, sync unavailable) can be checked on a device that has
        // already synced. Reads only; the cache itself is left untouched.
        let useCache = UserDefaults.standard.bool(forKey: "BWIgnoreSnapshotCache") == false
        #else
        let useCache = true
        #endif
        if useCache, let cached = snapshotCache?.load() {
            snapshot = cached
            syncState = .cached(cached.fetchedAt, "Showing the last index this phone received.")
        }
        macWorkItems = snapshot.workItems; macEntries = snapshot.entries; macIdeas = snapshot.ideas
        pendingTags.reconcile(&snapshot)
        applyPlanningDrafts()
        Task { await refresh() }
    }

    /// How many refreshes were asked for; UI tests read it to check a gesture reached here.
    private(set) var refreshRequests = 0

    deinit {
        if let sampleDefaultsName { planningDefaults.removePersistentDomain(forName: sampleDefaultsName) }
    }

    func refresh() async {
        guard !isSample else { return }
        reloadSharedWidgetDrafts()
        refreshRequests += 1
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "BWTestMobilePlanning") { return }
        #endif
        if let inFlight = refreshTask { await inFlight.value; return }
        let task = Task { await performRefresh() }
        refreshTask = task
        await task.value
        refreshTask = nil
    }

    private func reloadSharedWidgetDrafts() {
        guard let widgetCommands else { return }
        planningDrafts = draftStore.load()
        for record in (try? widgetCommands.records()) ?? [] {
            if record.state == .rejected { planningErrors[record.id.uuidString] = record.message ?? "The Mac refused this change." }
            if let date = record.appliedAt { appliedAt[record.id] = date }
        }
        UserDefaults(suiteName: WidgetAppGroup.mobile)?.set(UserDefaults.standard.bool(forKey: MobileCloudStore.disabledDefaultsKey), forKey: MobileCloudStore.disabledDefaultsKey)
        applyPlanningDrafts()
        publishWidgetSnapshot()
    }

    private func performRefresh() async {        // Deliberately does not clear `snapshot`: a refresh that fails must leave what
        // the user was reading in place.
        if MobileSnapshotCache.isEmpty(snapshot) { syncState = .loading }
        #if DEBUG
        // `-bwSimulatedReadDelay <seconds>` holds the first fetch back so a UI test can see
        // the loading state. Never set outside a test launch.
        if MobileSnapshotCache.isEmpty(snapshot),
           let delay = Double(UserDefaults.standard.string(forKey: "bwSimulatedReadDelay") ?? "") {
            try? await Task.sleep(for: .seconds(delay))
        }
        #endif
        do {
            let ids = planningDrafts.filter { planningErrors[$0.id.uuidString] == nil && appliedAt[$0.id] == nil }.map(\.id)
            let store = cloudStore
            let (receipts, downloaded) = try await Self.withTimeout(Self.refreshTimeout) {
                async let receipts = store.planningReceipts(for: ids)
                async let snapshot = store.fetchSnapshot()
                return try await (receipts, snapshot)
            }
            var fetched = downloaded
            pendingTags.reconcile(&fetched)
            snapshot = fetched
            macWorkItems = downloaded.workItems; macEntries = downloaded.entries; macIdeas = downloaded.ideas
            for receipt in receipts {
                if let index = downloads.firstIndex(where: { $0.requestID == receipt.id }) {
                    downloads[index].receiptReceived = true
                    if !receipt.applied {
                        downloads[index].error = receipt.message ?? "The Mac could not prepare this download."
                        downloads[index].requestID = nil
                    }
                }
                try? widgetCommands?.receipt(id: receipt.id, applied: receipt.applied, message: receipt.message, workModifiedAt: receipt.workModifiedAt, now: receipt.appliedAt ?? Date())
                if receipt.applied { appliedAt[receipt.id] = appliedAt[receipt.id] ?? Date() }
                else { planningErrors[receipt.id.uuidString] = receipt.message ?? "The Mac could not apply this change." }
            }
            let now = Date()
            planningDrafts.removeAll { draft in
                guard let applied = appliedAt[draft.id] else { return false }
                let settled = MobilePlanningFiles.index(fetched, reflects: draft)
                    || now.timeIntervalSince(applied) > Self.appliedDraftGrace
                if settled { appliedAt.removeValue(forKey: draft.id) }
                return settled
            }
            outbox.remove(ids: Set(receipts.map(\.id)))
            receiptCleanup.formUnion(receipts.map(\.id))
            persistDownloads()
            await receiveDownloads()
            persistPlanningDrafts()
            applyPlanningDrafts()
            cacheReceivedSnapshot()
            syncState = .ready(fetched.fetchedAt)
            MobileWorkspaceGuidance.successfulSync.sendDonation()
            publishWidgetSnapshot()
            // Not awaited: a send or cleanup that stalls on the network used to hold
            // `refreshing` forever, so every later refresh (pull, button, foreground)
            // silently did nothing and the screen kept a deleted item until relaunch.
            Task { await sendAndCleanUp() }
        } catch {
            syncState = Self.fallback(for: error, showing: snapshot)
        }
    }

    /// Stops waiting after `seconds`. The operation itself may run on (CloudKit calls do
    /// not all honour cancellation); its late result is simply not used.
    private static func withTimeout<T: Sendable>(_ seconds: TimeInterval,
                                                 _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        let gate = ResumeOnce()
        return try await withCheckedThrowingContinuation { continuation in
            Task {
                do { let value = try await operation(); if gate.claim() { continuation.resume(returning: value) } }
                catch { if gate.claim() { continuation.resume(throwing: error) } }
            }
            Task {
                try? await Task.sleep(for: .seconds(seconds))
                if gate.claim() {
                    continuation.resume(throwing: MobileCloudError.unavailable(
                        "CloudKit is taking too long to answer. Showing the last index; pull down to try again."))
                }
            }
        }
    }

    private func sendAndCleanUp() async {
        await flushOutbox()
        guard !cleaningReceipts, !receiptCleanup.isEmpty else { return }
        cleaningReceipts = true
        defer { cleaningReceipts = false }
        if let removed = try? await cloudStore.removePlanningReceipts(receiptCleanup) {
            receiptCleanup.subtract(removed)
            persistPlanningDrafts()
        }
    }

    /// An unreachable CloudKit is an ordinary state, so the message says what the app is
    /// doing about it rather than only what failed.
    private static func fallback(for error: Error, showing snapshot: MobileWorkspaceSnapshot) -> SyncState {
        let reason = (error as? MobileCloudError)?.errorDescription ?? error.localizedDescription
        guard MobileSnapshotCache.isEmpty(snapshot) == false else {
            return .unavailable(reason)
        }
        return .cached(snapshot.fetchedAt, reason)
    }

    func toggleFilter(_ id: String) {
        if selectedTagIDs.contains(id) { selectedTagIDs.remove(id) }
        else { selectedTagIDs.insert(id) }
    }

    func filtered(_ entries: [MobileWorkspaceEntry]) -> [MobileWorkspaceEntry] {
        guard selectedTagIDs.isEmpty == false else { return entries }
        return entries.filter { selectedTagIDs.isSubset(of: $0.tagIDs) }
    }

    func filteredWorkItems() -> [MobileWorkItem] {
        guard selectedTagIDs.isEmpty == false else { return snapshot.workItems }
        return snapshot.workItems.filter { selectedTagIDs.isSubset(of: $0.tagIDs) }
    }

    func download(for path: String) -> MobileDownloadState? { downloads.first { $0.entry.path == path } }

    func setDownload(_ entry: MobileWorkspaceEntry, enabled: Bool) {
        guard !isSample else { return }
        if !enabled, let index = downloads.firstIndex(where: { $0.entry.path == entry.path }) {
            if let copy = downloads[index].copy { Task { try? await downloadCache.remove(copy.id) } }
            downloads[index].copy = nil; downloads[index].enabled = false
            if downloads[index].requestID == nil { downloads.remove(at: index) }
            persistDownloads(); return
        }
        if let index = downloads.firstIndex(where: { $0.entry.path == entry.path }), downloads[index].requestID != nil {
            downloads[index].enabled = true; persistDownloads(); return
        }
        guard downloads.filter({ $0.enabled }).count < 20 || download(for: entry.path)?.enabled == true else {
            saveMessage = "Keep up to 20 offline files, folders or categories. Remove a download first."; return
        }
        var compact = entry
        // File previews never belong in a download request.
        if var details = compact.projectDetails {
            details.previews = nil
            compact = MobileWorkspaceEntry(path: entry.path, parentPath: entry.parentPath, name: entry.name, isDirectory: entry.isDirectory,
                revision: entry.revision, tagIDs: entry.tagIDs, modifiedAt: entry.modifiedAt, projectDetails: details)
        }
        let edit = MobilePlanningEdit(operation: .downloadFiles, title: entry.name, originalEntry: compact)
        guard savePlanning(edit) else { return }
        if let index = downloads.firstIndex(where: { $0.entry.path == entry.path }) {
            downloads[index].requestID = edit.id; downloads[index].error = nil; downloads[index].receiptReceived = false
            downloads[index].entry = compact; downloads[index].enabled = true
        } else { downloads.append(MobileDownloadState(entry: compact, requestID: edit.id)) }
        persistDownloads()
    }

    private func persistDownloads() {
        guard !isSample, let data = try? JSONEncoder().encode(downloads) else { return }
        planningDefaults.set(data, forKey: "BWOfflineDownloads")
    }

    private func receiveDownloads() async {
        guard !receivingDownloads, !isSample else { return }
        receivingDownloads = true; defer { receivingDownloads = false }
        for state in downloads {
            guard let request = state.requestID else { continue }
            do {
                if !state.enabled {
                    guard state.receiptReceived else { continue }
                    try await cloudStore.removeDownload(request)
                    downloads.removeAll { $0.entry.path == state.entry.path && !$0.enabled && $0.requestID == request }
                } else {
                    let copy: MobileOfflineCopy?
                    if state.copy?.id == request { copy = state.copy }
                    else { copy = try await cloudStore.receiveDownload(id: request, path: state.entry.path, cache: downloadCache) }
                    guard let copy else { continue }
                    guard let index = downloads.firstIndex(where: { $0.entry.path == state.entry.path && $0.requestID == request }), downloads[index].enabled else {
                        try? await downloadCache.remove(copy.id); continue
                    }
                    let old = downloads[index].copy
                    downloads[index].copy = copy; downloads[index].error = nil
                    persistDownloads()
                    if let old, old.id != copy.id { try? await downloadCache.remove(old.id) }
                    // Wait for the Mac's receipt before deleting its transfer asset:
                    // an interrupted Mac may still be retrying this immutable command.
                    if downloads.first(where: { $0.requestID == request })?.receiptReceived == true {
                        try await cloudStore.removeDownload(request)
                        if let current = downloads.firstIndex(where: { $0.requestID == request }) { downloads[current].requestID = nil }
                    }
                }
            } catch {
                if let index = downloads.firstIndex(where: { $0.requestID == request }) { downloads[index].error = error.localizedDescription }
            }
        }
        downloads.removeAll { !$0.enabled && $0.requestID == nil }
        persistDownloads()
    }

    var propertyOptions: [String: [String]] {
        let projects = snapshot.entries.compactMap(\.projectDetails)
        let ideas = snapshot.ideas.compactMap { $0.planning?.project?.metadata }
        return ["domain": projects.compactMap(\.domain) + ideas.compactMap(\.domain),
                "Status": projects.compactMap(\.status) + ideas.compactMap(\.status),
                "Phase": projects.compactMap(\.phase) + ideas.compactMap(\.phase),
                "Type": projects.compactMap(\.projectType) + ideas.compactMap(\.projectType)]
            .mapValues { Array(Set($0)).sorted { $0.localizedStandardCompare($1) == .orderedAscending } }
    }

    func filteredIdeas() -> [MobileIdea] {
        guard selectedTagIDs.isEmpty == false else { return snapshot.ideas }
        return snapshot.ideas.filter { selectedTagIDs.isSubset(of: $0.tagIDs) }
    }

    func tags(for ids: Set<String>) -> [Tag] {
        snapshot.tags.filter { ids.contains($0.id) }
    }

    /// The phone receives only immediate children for every area.  Keeping these
    /// small derived collections here lets the mobile UI be task-oriented without
    /// pretending that it can browse a Mac project's complete file tree.
    func entries(in area: String) -> [MobileWorkspaceEntry] {
        filtered(snapshot.entries.filter { $0.parentPath == area })
    }

    func workItems(forProjectPath path: String) -> [MobileWorkItem] {
        filteredWorkItems()
            .filter { $0.projectPath == path && $0.status != .completed }
            .sorted(by: Self.workComesFirst)
    }

    /// Every item of the project, completed ones included: what its progress counts.
    func allWorkItems(forProjectPath path: String) -> [MobileWorkItem] {
        filteredWorkItems().filter { $0.projectPath == path }
    }

    func projectName(for path: String) -> String {
        snapshot.entries.first { $0.path == path }?.name ?? path.split(separator: "/").last.map(String.init) ?? path
    }

    var projectScores: [String: Double] {
        Dictionary(uniqueKeysWithValues: snapshot.entries.compactMap { entry in
            entry.projectDetails?.rankingScore.map { (entry.path, $0) }
        })
    }
    var recommendedWorkItem: MobileWorkItem? {
        let paths = Set(projectChoices.map(\.path))
        return WorkItemRecommendation.nextMobileAction(in: filteredWorkItems().filter { $0.projectPath.map(paths.contains) ?? true }, allItems: snapshot.workItems, projectScores: projectScores)
    }

    func toggle(tagID: String, on entry: MobileWorkspaceEntry) {
        guard !isSample else { return }
        let adding = entry.tagIDs.contains(tagID) == false
        let intent = MobileWorkspaceIntent.tagChange(path: entry.path, baseRevision: entry.revision,
                                                     adding: adding ? [tagID] : [], removing: adding ? [] : [tagID])
        outbox.append(intent)
        pendingIntentCount = outbox.count
        pendingTags.record(tagID: tagID, onPath: entry.path, isPresent: adding)
        // Shown immediately, and cached, so a tag applied offline survives relaunch
        // while its intent waits. The Mac remains the one that decides: the next
        // successful refresh replaces this with the canonical entry revision.
        if snapshot.entries.contains(where: { $0.id == entry.id }) {
            snapshot.setTag(tagID, onPath: entry.path, isPresent: adding)
            cacheReceivedSnapshot()
        }
        Task { await flushOutbox() }
    }

    static func workComesFirst(_ lhs: MobileWorkItem, _ rhs: MobileWorkItem) -> Bool {
        if lhs.stage != rhs.stage { return lhs.stage.rank < rhs.stage.rank }
        if lhs.priority != rhs.priority { return lhs.priority.rank < rhs.priority.rank }
        return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
    }

    @discardableResult
    func savePlanning(_ edit: MobilePlanningEdit) -> Bool {
        guard !isSample else {
            saveMessage = "This sample workspace is read-only. Close it and connect your Mac to save changes."
            return false
        }
        do { try MobilePlanningFiles.validate(edit) }
        catch { saveMessage = error.localizedDescription; return false }
        guard planningDrafts.count < 100, outbox.count < MobileIntentOutbox.capacity else { saveMessage = "Let the Mac apply your waiting changes before adding more."; return false }
        do { try widgetCommands?.append(.planning(edit)) }
        catch { saveMessage = "The change could not be saved: \(error.localizedDescription)"; return false }
        planningDrafts.append(edit)
        persistPlanningDrafts()
        outbox.append(.planning(edit))
        pendingIntentCount = outbox.count
        applyPlanningDrafts()
        #if DEBUG
        if !UserDefaults.standard.bool(forKey: "BWTestMobilePlanning") { cacheReceivedSnapshot() }
        #else
        cacheReceivedSnapshot()
        #endif
        publishWidgetSnapshot()
        saveMessage = "Saved on this phone · waiting for the Mac"
        Task { await flushOutbox() }
        return true
    }

    /// Completes an open item or reopens (restores) a completed one.
    @discardableResult
    func toggleCompletion(of item: MobileWorkItem) -> Bool {
        var changed = item
        changed.status = item.status == .completed ? .open : .completed
        return savePlanning(MobilePlanningEdit(operation: .saveWork, title: changed.title,
            description: changed.body ?? "", work: changed, originalWork: item, tagIDs: changed.tagIDs))
    }

    /// Re-links one record — project, features, milestones — as an ordinary saved edit.
    @discardableResult
    func setLinks(_ links: WorkItemLinks, for item: MobileWorkItem) -> Bool {
        let links = links.applicable(to: item.kind)
        var changed = item
        changed.projectPath = links.projectPath
        changed.featureIDs = links.featureIDs
        changed.milestoneIDs = links.milestoneIDs
        return savePlanning(MobilePlanningEdit(operation: .saveWork, title: changed.title,
            description: changed.body ?? "", work: changed, originalWork: item, tagIDs: changed.tagIDs))
    }

    /// Project folders, by name, as the link pickers offer them.
    var projectChoices: [MobileWorkspaceEntry] {
        snapshot.entries.filter { $0.parentPath == "Projects" && $0.isDirectory }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Open records of `kind`, those in `projectPath` first; anything already linked is
    /// kept so it can be unlinked.
    func linkChoices(_ kind: WorkItemKind, projectPath: String?, keeping selected: [String] = [],
                     excluding id: String? = nil) -> [MobileWorkItem] {
        snapshot.workItems
            .filter { $0.kind == kind && $0.id != id && ($0.status != .completed || selected.contains($0.id)) }
            .sorted { lhs, rhs in
                let left = projectPath != nil && lhs.projectPath == projectPath
                let right = projectPath != nil && rhs.projectPath == projectPath
                if left != right { return left }
                return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
            }
    }

    func workTitle(for id: String) -> String {
        snapshot.workItems.first { $0.id == id }?.title ?? "Unknown"
    }

    /// Asks the Mac to move the record to its Trash. It disappears here at once; if the
    /// Mac refuses (changed there or no longer at a safe path) it comes back with a draft to review.
    @discardableResult
    func trash(_ item: MobileWorkItem) -> Bool {
        let saved = savePlanning(MobilePlanningEdit(operation: .trashWork, title: item.title,
            description: item.body ?? "", originalWork: item, tagIDs: item.tagIDs))
        if saved { saveMessage = "Deleted on this phone · the Mac moves it to the Trash" }
        return saved
    }

    @discardableResult
    func trash(_ entry: MobileWorkspaceEntry, idea: MobileIdea? = nil) -> Bool {
        let operation: MobilePlanningEdit.Operation = entry.parentPath == "Ideas" ? .trashIdea : entry.parentPath == "Projects" && entry.isDirectory ? .trashProject : .trashEntry
        let saved = savePlanning(MobilePlanningEdit(operation: operation, title: idea?.title ?? entry.name,
            originalIdea: idea, originalEntry: entry))
        if saved { saveMessage = "Deletion queued · your Mac moves it to the Trash when online" }
        return saved
    }

    @discardableResult
    func trash(_ idea: MobileIdea) -> Bool {
        guard let entry = snapshot.entries.first(where: { $0.path == idea.path }) else {
            saveMessage = "Refresh this idea before deleting it."; return false
        }
        return trash(entry, idea: idea)
    }

    /// Leaving the app right after a save used to strand that change in the outbox until
    /// the next launch. Ask for the little time iOS allows to send what is waiting.
    func flushBeforeSuspending() {
        guard !isSample else { return }
        guard pendingIntentCount > 0, backgroundFlush == .invalid else { return }
        backgroundFlush = UIApplication.shared.beginBackgroundTask(withName: "Send waiting changes") { [weak self] in
            MainActor.assumeIsolated { self?.endBackgroundFlush() }
        }
        Task {
            await flushOutbox()
            endBackgroundFlush()
        }
    }

    private func endBackgroundFlush() {
        guard backgroundFlush != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundFlush)
        backgroundFlush = .invalid
    }

    /// Changes still on their way to the Mac (not refused, not yet applied there).
    var waitingPlanningDrafts: [MobilePlanningEdit] {
        planningDrafts.filter { planningErrors[$0.id.uuidString] == nil && appliedAt[$0.id] == nil }
    }

    func discardPlanningDraft(_ id: UUID) {
        guard planningErrors[id.uuidString] != nil else { return }
        planningDrafts.removeAll { $0.id == id }
        planningErrors.removeValue(forKey: id.uuidString)
        persistPlanningDrafts()
    }

    private func persistPlanningDrafts() {
        for (id, message) in planningErrors { if let id = UUID(uuidString: id) { try? widgetCommands?.receipt(id: id, applied: false, message: message) } }
        draftStore.save(planningDrafts)
        planningDefaults.set(receiptCleanup.map(\.uuidString), forKey: "BWPlanningReceiptCleanup")
        planningDefaults.set(planningErrors, forKey: "BWMobilePlanningErrors")
        planningDefaults.set(appliedAt.reduce(into: [String: Double]()) { $0[$1.key.uuidString] = $1.value.timeIntervalSince1970 },
                             forKey: "BWPlanningAppliedAt")
    }

    private func cacheReceivedSnapshot() {
        guard !isSample else { return }
        // Reapply drafts from their own store on launch; never mistake an optimistic
        // phone edit for a newly received Mac record or a recorded completion date.
        var received = snapshot
        received.workItems = macWorkItems
        received.entries = macEntries
        received.ideas = macIdeas
        let cache = snapshotCache
        snapshotWriteQueue.async { cache?.save(received) }
    }

    private func applyPlanningDrafts() {
        for edit in planningDrafts where planningErrors[edit.id.uuidString] == nil {
            switch edit.operation {
            case .saveIdeaPlanning:
                if let original = edit.originalIdea, let index = snapshot.ideas.firstIndex(where: { $0.path == original.path }) { snapshot.ideas[index].planning = edit.ideaPlanning }
            case .promoteIdea: break // Keep the idea visible until the Mac's move receipt.
            case .downloadFiles, .previewIdea, .scheduleCapture, .previewProject: break
            case .saveProject:
                guard let change = edit.projectEdit, let index = snapshot.entries.firstIndex(where: { $0.path == change.original.path }) else { continue }
                let entry = snapshot.entries[index]
                var details = entry.projectDetails ?? change.original
                details.ratings = change.ratings; details.needsSetup = false
                details.oneLiner = change.oneLiner; details.summary = change.summary
                if let properties = change.properties {
                    let fields = properties.changedFields(from: change.original)
                    if fields.contains("domain") { details.domain = properties.domain.isEmpty ? nil : properties.domain }
                    if fields.contains("Status") { details.status = properties.status.isEmpty ? nil : properties.status }
                    if fields.contains("Phase") { details.phase = properties.phase.isEmpty ? nil : properties.phase }
                    if fields.contains("Type") { details.projectType = properties.projectType.isEmpty ? nil : properties.projectType }
                }
                snapshot.entries[index] = MobileWorkspaceEntry(path: entry.path, parentPath: entry.parentPath, name: entry.name, isDirectory: entry.isDirectory, revision: entry.revision, tagIDs: entry.tagIDs, modifiedAt: entry.modifiedAt, projectDetails: details)
            case .fileCapture, .reviewInbox: break // The card uses persisted drafts; keep the downloaded projection untouched.
            case .saveWork:
                guard let work = edit.work else { continue }
                snapshot.workItems.removeAll { $0.id == work.id }
                snapshot.workItems.append(work)
            case .saveIdea:
                if let original = edit.originalIdea, let index = snapshot.ideas.firstIndex(where: { $0.id == original.id }) {
                    snapshot.ideas[index].title = edit.title
                    snapshot.ideas[index].description = edit.description
                    snapshot.ideas[index].tagIDs = edit.tagIDs
                }
            case .createIdea:
                let path = "Ideas/" + CaptureNaming.safeFilename(edit.title) + " (" + edit.id.uuidString + ").md"
                snapshot.ideas.removeAll { $0.path == path }
                snapshot.ideas.append(MobileIdea(path: path, title: edit.title, revision: 0,
                    tagIDs: edit.tagIDs, modifiedAt: Date(), description: edit.description))
            case .trashIdea, .trashProject, .trashEntry:
                guard let entry = edit.originalEntry else { continue }
                func contains(_ path: String) -> Bool { path == entry.path || path.hasPrefix(entry.path + "/") }
                snapshot.entries.removeAll { contains($0.path) }
                snapshot.ideas.removeAll { contains($0.path) }
                snapshot.workItems.removeAll { contains($0.path) }
            case .trashWork:
                guard let original = edit.originalWork else { continue }
                snapshot.workItems.removeAll { $0.id == original.id }
            case .createProject:
                let path = MobilePlanningFiles.projectPath(for: edit)
                snapshot.entries.removeAll { $0.path == path }
                snapshot.entries.append(MobileWorkspaceEntry(path: path, parentPath: "Projects", name: edit.title,
                    isDirectory: true, revision: 0, tagIDs: edit.tagIDs,
                    projectDetails: MobileProjectDetails(path: path, summary: edit.description)))
            }
        }
    }

    private func flushOutbox() async {
        guard !isSample else { return }
        #if DEBUG
        // The planning fixture is offline by definition. Without this, a fixture launch
        // that forgot `-mobileCloudDisabled` would send synthetic test edits to the
        // signed-in account, and a running Mac would apply them to the real Workspace.
        if UserDefaults.standard.bool(forKey: "BWTestMobilePlanning") { return }
        #endif
        guard !flushing else { return }
        flushing = true
        defer { flushing = false }
        // The general intent queue is bounded and another capture/tag operation may
        // evict an old entry. Private planning drafts still own their immutable ID;
        // resubmitting that ID is safe even after CloudKit accepted it earlier.
        let queuedIDs = Set(outbox.queued().map(\.id))
        for draft in planningDrafts where planningErrors[draft.id.uuidString] == nil && appliedAt[draft.id] == nil
            && !queuedIDs.contains(draft.id) {
            outbox.append(.planning(draft))
        }
        let result = await outbox.flush { [cloudStore] intent in
            try await cloudStore.submit(intent)
        }
        pendingIntentCount = result.remaining
    }

    /// Widgets are intentionally fed only after a successful CloudKit refresh.  An
    /// offline launch keeps the last useful projection instead of replacing it with an
    /// error or an empty workspace.
    private func publishWidgetSnapshot() {
        guard !isSample else { return }
        #if DEBUG
        guard !UserDefaults.standard.bool(forKey: "BWTestMobilePlanning") else { return }
        #endif
        let display = snapshot, widgetStore = widgetStore
        var canonical = snapshot
        canonical.workItems = macWorkItems
        canonical.entries = macEntries
        canonical.ideas = macIdeas
        let directory = widgetCommands?.directory
        widgetPublishWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            widgetStore?.save(WorkspaceWidgetSnapshot.make(from: display))
            if let directory, !MobileSnapshotCache.isEmpty(canonical) {
                do { try DashboardWidgetStore.saveWorkspace(WorkspaceDashboardSnapshot.make(from: canonical), directory: directory) }
                catch {
                    let message = error.localizedDescription
                    Task { @MainActor [weak self] in self?.saveMessage = "Widgets could not update: \(message)" }
                }
            }
            WidgetCenter.shared.reloadAllTimelines()
        }
        widgetPublishWork = work
        snapshotWriteQueue.async(execute: work)
    }
}

/// Lets exactly one of several racing tasks resume a continuation.
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false
    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if claimed { return false }
        claimed = true
        return true
    }
}
