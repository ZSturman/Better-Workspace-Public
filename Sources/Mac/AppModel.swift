import Foundation
import SwiftUI
import Observation
import BetterWorkspaceCore

enum SidebarSelection: Hashable {
    case overview
    case work
    case ingest
    /// A top-level Workspace folder, by name — purpose-built or configured alike.
    case folder(String)
    case tag(String)   // tag id

    static func area(_ area: WorkspaceArea) -> SidebarSelection { .folder(area.directoryName) }
}

struct WorkItemSyncPrompt: Identifiable {
    let id = UUID()
    let count: Int
    let sampleTitles: [String]

    var message: String {
        let noun = count == 1 ? "work item file is" : "work item files are"
        let sample = sampleTitles.isEmpty ? "" : " (including \(sampleTitles.joined(separator: ", ")))."
        return "\(count) \(noun) missing from the Workspace\(sample) Choose whether to restore the files or accept the folder as the source of truth."
    }
}

@MainActor
@Observable
final class AppModel {
    let captureDraft = CaptureComposerDraft()
    var deletionRequest: WorkspaceDeletionRequest?


    struct OverviewNextAction: Identifiable {
        let item: WorkItem
        let project: WorkspaceItem
        let resumesRecentProject: Bool

        var id: String { item.id }
    }

    var graphRecords: [ProjectGraphRecord] = []
    var graphRevision = 0
    var projectViewRevision = 0
    @ObservationIgnored var graphProjectsByLocalID: [String: ProjectGraphRecord] = [:]
    @ObservationIgnored var graphProjectsByPageID: [String: ProjectGraphRecord] = [:]
    @ObservationIgnored var graphSourcesByID: [String: ProjectGraphSource] = [:]
    @ObservationIgnored var graphIncomingIDs: Set<String> = []
    @ObservationIgnored var graphOutgoingIDs: Set<String> = []
    @ObservationIgnored var applyingGraphToLocal = false
    @ObservationIgnored var graphIndex = ProjectGraphIndex(records: [])
    @ObservationIgnored var graphMediaIndex = ProjectGraphIndex(records: [], readingIncoming: true)
    var graphSyncIndex = ProjectGraphIndex(records: [], includingIncoming: true)
    var graphSources: [ProjectGraphSource] = []
    var graphReport: ProjectSyncReport?
    var graphBusy = false
    var graphSyncReview: ProjectSyncReview?
    var openGraphProjectID: String?
    @ObservationIgnored var graphReloadGeneration = 0
    @ObservationIgnored var graphReloadTask: Task<Void, Never>?
    @ObservationIgnored var graphCheckTask: Task<Void, Never>?

    // Infrastructure — created once, shared by every screen.
    let workspace: WorkspaceLocation
    let database: Database
    /// Where tags and ratings are actually being written. Anything but `.file` is worth
    /// telling the user about, because it changes whether their work is kept.
    let databaseBacking: Database.Backing
    let tagStore: TagStore
    /// Personal area settings. A private file, never anything inside `~/Workspace`.
    let areaConfigurations: AreaConfigurationStore
    let agentTasks = AgentTaskCoordinator()
    let projectStore: ProjectStore
    let folderDiscovery = WorkspaceFolderDiscovery()
    let workItemService = WorkItemService()
    let textDocumentService = TextDocumentService()
    let ingest: IngestService
    /// Optional projection/intent transport. It owns no Workspace data and does not
    /// construct a CloudKit container until the user enables mobile sync.
    let mobileCloudPublisher: MobileCloudPublisher
    let fs = FilesystemService.shared
    let probe = ItemProbe.shared
    let measurementService = MeasurementService.shared

    // Navigation
    var selection: SidebarSelection? = AppModel.initialSelection {
        didSet { StateRestoration.save(selection, folder: selectedFolderIdentity) }
    }

    /// The open area's file identity, saved with its name so a Finder rename made while
    /// the app was closed can be followed on the next launch.
    private var selectedFolderIdentity: String? {
        if case .folder(let name)? = selection { return folder(named: name)?.identity }
        return nil
    }

    /// `-bwStartArea Projects` opens straight into an area. Keystroke automation is
    /// refused to this app's test tooling, so without it a screenshot of anything but
    /// the default screen is unreachable. Absent in normal use.
    private static var initialSelection: SidebarSelection {
        #if DEBUG
        // A launch argument (tests, screenshots) beats what was restored.
        let startArea = UserDefaults.standard.string(forKey: "bwStartArea")
        if startArea == nil, let restored = StateRestoration.selection { return restored }
        switch startArea {
        // The screens first: a Workspace folder can share a screen's name (there is an
        // `Overview` folder), and the name alone used to open the folder instead.
        case "Overview": return .overview
        case "Ingest": return .ingest
        // Work records belong in their project queue. Keep this launch argument for
        // the focused-work regression tests, but do not restore the retired sidebar
        // destination for people who last used an older build.
        case "Work": return .work
        case let name?: return .folder(name)
        case nil: break
        }
        #endif
        return StateRestoration.selection ?? .overview
    }

    /// Whether the inspector is shown: a layout preference, so it survives a restart.
    var showInspector = StateRestoration.showInspector {
        didSet { StateRestoration.showInspector = showInspector }
    }

    /// Set until the first discovery has had a chance to check a restored area.
    private var restoredSelectionPending = true

    // Content, keyed by area folder name. Views never scan the filesystem themselves.
    private(set) var itemsByArea: [String: [WorkspaceItem]] = [:]
    private(set) var folders: [WorkspaceFolder] = []
    private(set) var workItems: [WorkItem] = []
    private(set) var socialPosts: [SocialPost] = []
    private(set) var loadingAreas: Set<String> = []
    /// Areas whose last read failed before any listing was published. They are not
    /// loading any more, and they are not known to be empty either.
    private(set) var unreadableAreas: Set<String> = []
    /// False until the first work-item walk publishes. An empty `workItems` before then
    /// means "not looked yet", which views must not present as "no work".
    private(set) var workItemsLoaded = false
    private(set) var socialPostsLoaded = false
    private(set) var tagsByPath: [String: [Tag]] = [:]
    /// The work record open in the editor sheet, wherever it was opened from.
    var editingWorkItem: WorkItem?

    // Notion sync (AppModel+NotionSync.swift)
    var syncTriage: [ProjectSyncTriage.Item] = []
    var syncDeferred: [String: String] = [:]
    var syncFailures: [String: ProjectAutoSyncPlanner.Failure] = [:]
    var syncReport: ProjectAutoSync.Report?
    var syncActionReport: ProjectAutoSync.Report?
    var syncLastChangesReport: ProjectAutoSync.Report?
    var syncActivity: String?
    var syncFeedback: String?
    var syncFeedbackIsError = false
    var syncSettingRevision = 0
    var showingSyncCenter = false
    var autoSyncRunning = false
    var autoSyncError: String?
    var autoSyncLoop: Task<Void, Never>?
    var autoSyncDebounce: Task<Void, Never>?

    // Ingest
    private(set) var ingestItems: [IngestItem] = []
    var ingestCursor: Int = 0
    var ingestManualSelectionID: String?
    /// Captures that have already been filed, still reachable from Ingest for
    /// follow-up edits. Each is the real filed object; one that has since moved or
    /// been deleted is simply not listed.
    private(set) var recentlyFiledIngest: [RecentlyFiledIngest] = []

    struct RecentlyFiledIngest: Identifiable, Hashable {
        let record: FiledIngestRecord
        let item: WorkspaceItem
        var id: String { record.id }
    }

    // Tags
    private(set) var allTags: [Tag] = []
    private(set) var tagUsage: [String: Int] = [:]

    // Selection within an area — what the shared tag inspector acts on.
    var selectedItem: WorkspaceItem?
    var selectedIngestItem: IngestItem?
    /// Transient route only; state restoration intentionally remembers the area, not
    /// an unfinished project workflow.
    var openProjectWorkspaceID: String?
    /// Overview supplies this explicit handoff so its recommendation never becomes a
    /// second work-item browser.
    var focusedWorkItemPath: String?

    var statusMessage: String?
    var lastError: String?
    /// Set when a work-item file disappears outside the app. The last-known records stay
    /// visible until the person chooses whether to restore them or accept the folder.
    var workItemSyncPrompt: WorkItemSyncPrompt?

    // Project tools are intentionally scoped to an explicit selected folder.  Their
    // sessions live in the app's private database; none of this state writes into a
    // Workspace project until Flow Review presents and confirms a change plan.
    var projectToolTarget: ProjectToolTarget?
    private(set) var projectToolCapabilities: [String: ProjectToolCapability] = [:]

    var autoSyncOperation: Task<ProjectAutoSync.Report, Error>?
    @ObservationIgnored private lazy var workItemPathIndex = WorkItemPathIndex(file: Database.preferredURL().deletingLastPathComponent().appendingPathComponent("work-item-paths.json"))
    private var workItemIndexSaveTask: Task<Void, Never>?
    private var workItemScanInFlight = false
    /// A short grace period makes a mistaken completion reversible before the item
    /// leaves an active queue, matching the interaction people expect from Reminders.
    private(set) var pendingWorkItemCompletionIDs: Set<String> = []
    private var pendingWorkItemCompletionTasks: [String: Task<Void, Never>] = [:]
    /// Set when a second filesystem event lands during the potentially long recursive
    /// scan. Without it, that event was dropped and the UI could remain stale until a
    /// third change or a relaunch.
    private var workItemRefreshRequested = false
    private var workItemPendingPaths: Set<String> = []
    private var pendingMissingWorkItems: [WorkItem] = []
    /// Records this app is moving, or has moved, to the Trash itself: its own Delete and
    /// a phone delete. Their disappearance is expected, so it is applied rather than
    /// raising the restore-or-sync prompt meant for changes made outside the app.
    private var appTrashedWorkItemPaths: Set<String> = []
    private var workItemSyncResolutionInFlight = false
    private var observer: DirectoryObserver?
    /// Phone tag ids the store resolved to an equivalent tag already here (`TagStore.createTag(_:)`).
    @ObservationIgnored private var mobileTagAliases: [String: String] = [:]
    private var refreshTask: Task<Void, Never>?
    private var inboxPoll: Task<Void, Never>?
    var widgetOverviewSection: String?
    var widgetChartRequest = UUID()
    @ObservationIgnored var widgetCommands: WidgetCommandStore?
    @ObservationIgnored var widgetPublishingTask: Task<Void, Never>?
    private var mobileCloudSyncTask: Task<Void, Never>?
    private var mobileCloudSyncInFlight = false
    private var mobileCloudSyncRequested = false
    private var completedInitialRefresh = false
    /// Set once the first service read has been attempted, whatever its outcome, so
    /// views can tell "still asking" from "the service has nothing" or "is not running".
    var backgroundServiceReadOnce = false

    /// True while the first full refresh is still running — what Overview derives from
    /// is incomplete until then.
    var isAwaitingInitialRefresh: Bool { workspaceAvailable && completedInitialRefresh == false }
    var isAwaitingWorkItems: Bool { workspaceAvailable && workItemsLoaded == false }

    init() {
        let workspace = WorkspaceLocation.resolved
        self.workspace = workspace
        let opened = Database.opened(preferring: Database.preferredURL())
        let db = opened.database
        self.database = db
        self.databaseBacking = opened.backing
        self.tagStore = TagStore(database: db)
        self.areaConfigurations = AreaConfigurationStore(url: AreaConfigurationStore.defaultURL())
        self.projectStore = ProjectStore(database: db)
        self.ingest = IngestService(
            location: IngestLocation.provisional(),
            database: db,
            tagStore: tagStore,
            workspace: workspace
        )
        self.mobileCloudPublisher = MobileCloudPublisher(database: db)
        reloadTags()
        if let problem = areaConfigurations.loadError { lastError = problem }
    }

    func projectToolCapability(for item: WorkspaceItem) async -> ProjectToolCapability {
        let capability = await ProjectToolCapabilityService.shared.capability(for: item.url)
        projectToolCapabilities[item.url.canonicalPath] = capability
        return capability
    }

    func cachedProjectToolCapability(for item: WorkspaceItem) -> ProjectToolCapability? {
        projectToolCapabilities[item.url.canonicalPath]
    }

    func openProjectTool(_ kind: ProjectToolTarget.Kind, for item: WorkspaceItem) {
        selectedItem = item
        projectToolTarget = ProjectToolTarget(kind: kind, item: item)
    }

    /// The area restored from the last run may have been renamed or removed while the
    /// app was closed. Follow a rename by identity; otherwise fall back to Overview
    /// rather than opening on "Folder not found".
    private func settleRestoredSelection() {
        switch selection {
        case .folder(let name)?:
            guard folder(named: name) == nil else { return }
            if let identity = StateRestoration.folderIdentity,
               let renamed = folders.first(where: { $0.identity == identity }) {
                selection = .folder(renamed.name)
            } else {
                selection = .overview
            }
        case .tag(let id)?:
            if allTags.contains(where: { $0.id == id }) == false { selection = .overview }
        default:
            break
        }
    }

    // MARK: - Lifecycle

    func start() {
        agentTasks.start(model: self)
        startWidgetDashboard()
        startProjectSyncChecks()
        reportDatabaseBacking()
        // Fire and forget: this is what keeps the shared Inbox syncing at all, and it
        // can block for seconds, so nothing on the launch path waits for it.
        // Not in an isolated test: it has no business touching the real iCloud container.
        if TestIsolation.isActive == false {
            Task.detached(priority: .utility) { IngestLocation.registerUbiquityContainer() }
        }
        Task { [weak self] in
            // Settle the real inbox location before the first scan. Resolution stats
            // iCloud paths, so it happens here rather than during init.
            let resolved = await Task.detached(priority: .userInitiated) {
                IngestLocation.resolve()
            }.value
            guard let self else { return }
            self.ingest.updateLocation(resolved)
            self.ingestLocationResolved = true
            self.startObserving()
            await self.refreshAll()
            #if DEBUG
            // `-bwRunLegacyImport YES` runs the Better Projects import at launch and
            // reports to stderr, so the migration can be exercised for real without
            // driving Settings through the UI. Same code path the button uses.
            // `-bwDumpCloudState YES` prints what is actually in CloudKit, then quits.
            // Reading the container rather than this app's projection table is the point:
            // the two are meant to agree, and a sync bug is exactly the case where they
            // do not. Same stderr-reporting shape as the legacy-import switch below.
            if UserDefaults.standard.bool(forKey: "bwDumpCloudState") {
                // `-bwDumpCloudNoSync YES` reads the container without consuming the
                // intent channel first, which is the only way to see what the phone
                // actually queued before the Mac acknowledges and deletes it.
                await self.dumpCloudState(sync: UserDefaults.standard.bool(forKey: "bwDumpCloudNoSync") == false)
            }
            if UserDefaults.standard.bool(forKey: "bwRunLegacyImport") {
                let summary = await self.runLegacyImport(apply: true)
                let line = "LEGACY IMPORT: \(summary.documents) documents, "
                    + "\(summary.projectsRegistered) registered, "
                    + "\(summary.notionLinksRecovered) Notion links, "
                    + "\(summary.ratingsImported) ratings across \(summary.ratedProjects) projects, "
                    + "\(summary.missingDirectories) missing, \(summary.conflicts) conflicts\n"
                FileHandle.standardError.write(Data(line.utf8))
            }
            #endif
        }
        startInboxPolling()
        startServicePolling()
    }

    /// Says so when the store is not where it should be.
    ///
    /// Silence here would mean someone tags a hundred things into a session-only
    /// database and finds them gone after a relaunch.
    private func reportDatabaseBacking() {
        switch databaseBacking {
        case .file:
            break
        case .recovered(let movedAside):
            lastError = "The tag database could not be opened, so a new one was started. "
                + "The old file is kept at \(movedAside.lastPathComponent) in case it can be recovered."
        case .memory:
            lastError = "No tag database could be opened. Tags and ratings will last for "
                + "this session only — the filesystem is unaffected."
        }
    }

    /// FSEvents is reliable for `~/Workspace`, but the inbox sits inside iCloud Drive,
    /// where changes arrive through a file provider and events are not dependable — a
    /// file synced from the phone can land without any event firing. A slow poll makes
    /// the inbox trustworthy without making the rest of the app chatty.
    private func startInboxPolling() {
        inboxPoll?.cancel()
        inboxPoll = Task { [weak self] in
            var mobileSyncTicks = 0
            while Task.isCancelled == false {
                try? await Task.sleep(for: .seconds(5))
                guard let self, Task.isCancelled == false else { return }
                await self.checkWorkspaceAvailability()
                // A file provider can deliver a deletion without an FSEvent. Stat the
                // already-known record paths so external deletes still get the same
                // explicit restore-or-sync choice. This is bounded work, unlike a
                // recursive workspace scan, and runs only after the initial index exists.
                await self.checkForMissingWorkItems()
                // Areas.json is hand-editable; pick up an edit made while running.
                if self.areaConfigurations.reloadIfChangedOnDisk() {
                    if let problem = self.areaConfigurations.loadError { self.lastError = problem }
                    await self.refreshFolders()
                }
                await self.refreshIngest()
                await self.consumeWidgetCommands()
                self.requestWidgetDashboardPublish()
                // A phone can submit a destination intent without causing a local
                // filesystem event. Poll the optional command channel at a modest
                // cadence so an already-arrived Inbox item is filed promptly.
                mobileSyncTicks += 1
                if mobileSyncTicks.isMultiple(of: 3) { self.requestMobileCloudSync() }
            }
        }
    }

    private func checkForMissingWorkItems() async {
        guard completedInitialRefresh, workspaceAvailable, workItemsLoaded,
              workItemScanInFlight == false, workItemSyncResolutionInFlight == false else { return }
        let known = workItems.filter { appTrashedWorkItemPaths.contains($0.url.canonicalPath) == false }
        let missing = await Task.detached(priority: .utility) {
            let fm = FileManager.default
            return known.filter { fm.fileExists(atPath: $0.url.path) == false }
        }.value
            .filter { appTrashedWorkItemPaths.contains($0.url.canonicalPath) == false }
        guard missing.isEmpty == false else { return }
        pendingMissingWorkItems = WorkItemService.indexed(pendingMissingWorkItems + missing)
        presentWorkItemSyncPrompt()
    }

    /// False while the Workspace root itself is missing: a disconnected drive, a folder
    /// moved away, a network volume dropped.
    ///
    /// Every area used to read as empty then — "a folder that is not there holds
    /// nothing" is right for one area, and wrong when the whole root is gone — and the
    /// empty state could be published to the phone. When the root came back nothing was
    /// re-read, because the file-event stream had been watching the old one.
    private(set) var workspaceAvailable = true

    /// Checked on every inbox poll and before applying file events; a stat of one
    /// local path. On the way back it restarts the observer and re-reads everything.
    func checkWorkspaceAvailability() async {
        let root = workspace.root
        let present = await Task.detached(priority: .utility) { () -> Bool in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory) && isDirectory.boolValue
        }.value
        guard present != workspaceAvailable else { return }
        workspaceAvailable = present
        guard present else { return }
        observer?.stop()
        observer = nil
        startObserving()
        await refreshAll()
        statusMessage = "The Workspace is available again."
    }

    private func startObserving() {
        let candidates = [workspace.root, ingest.location.inbox]
        Task { [weak self] in
            // `fileExists` on the iCloud inbox is a file-provider round trip; keep it
            // off the main thread so a cold provider can't delay the first frame.
            let roots = await Task.detached(priority: .utility) {
                candidates.filter { FileManager.default.fileExists(atPath: $0.path) }
            }.value
            guard let self, roots.isEmpty == false else { return }
            let observer = DirectoryObserver { [weak self] paths in
                Task { @MainActor [weak self] in self?.handleFilesystemChange(paths: paths) }
            }
            observer.start(watching: roots)
            self.observer = observer
        }
    }

    /// Coalesces FSEvents bursts into a single refresh so that unzipping something into
    /// the inbox doesn't trigger a hundred rescans.
    private func handleFilesystemChange(paths: [String]) {
        // Accumulate, then debounce. Each batch used to cancel the previous one's
        // refresh and replace it with its own, so when a copy or a move spanned two
        // FSEvents batches (the stream delivers the first event at once and the rest a
        // moment later) the areas only the first batch touched were never re-read.
        pendingChangePaths.formUnion(paths)
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard let self, Task.isCancelled == false else { return }
            // Taken only once the wait is over: a cancelled task leaves them for the next.
            let paths = Array(self.pendingChangePaths)
            self.pendingChangePaths.removeAll()
            await self.applyFilesystemChange(paths: paths)
        }
    }

    private var pendingChangePaths: Set<String> = []

    private func applyFilesystemChange(paths: [String]) async {
        await checkWorkspaceAvailability()
        // Keep what was last seen; nothing read now would be true.
        guard workspaceAvailable else { return }
        // FSEvents reports resolved paths; compare canonical forms on both sides, or an
        // inbox reached through a symlink (or /var vs /private/var) never matches.
        let inboxPath = ingest.location.inbox.canonicalPath
        let touchesIngest = paths.contains { URL(fileURLWithPath: $0).canonicalPath.hasPrefix(inboxPath) }
        // Which top-level folders were touched. Other tools' metadata (`_audit`,
        // `.project-core`) and hidden root files like `.DS_Store` are not areas, and a
        // change inside them is not a reason to rescan anything.
        let rootPath = workspace.root.canonicalPath
        let changedNames = paths.compactMap { workspace.areaName(containing: URL(fileURLWithPath: $0)) }
        let touchedAreas = Set(changedNames.filter(WorkspaceFolderDiscovery.couldBeArea))
        let outsideAreas = paths.contains { path in
            guard URL(fileURLWithPath: path).canonicalPath.hasPrefix(inboxPath) == false else { return false }
            return workspace.areaName(containing: URL(fileURLWithPath: path)) == nil
        }
        // A folder made, renamed or removed directly under the root changes the set of
        // areas itself, not just one area's contents.
        let knownAreas = Set(folders.map(\.name))
        let touchesRoot = paths.contains { path in
            let url = URL(fileURLWithPath: path)
            return url.canonicalPath == rootPath
                || (url.deletingLastPathComponent().canonicalPath == rootPath
                    && WorkspaceFolderDiscovery.couldBeArea(url.lastPathComponent))
        } || touchedAreas.contains { knownAreas.contains($0) == false }

        await probe.invalidate(affectedBy: paths)
        await fs.invalidateCaches(affectedBy: paths)
        if touchesIngest { await refreshIngest() }
        if touchesRoot { await refreshFolders() }
        // Only areas that still exist: a folder just removed in Finder is gone from
        // `folders` by now, and reading it would report a failure that isn't one.
        let current = Set(folders.map(\.name))
        for area in touchedAreas where current.contains(area) { await refresh(areaNamed: area) }
        if outsideAreas && touchedAreas.isEmpty && touchesIngest == false && touchesRoot == false {
            await refreshAll()
        } else {
            // Every batch, not a guess at which ones matter: a folder moved in reports
            // only its own path, never the records inside it. Reconciling is a stat per
            // path plus reads of changed records, so it is cheap to run on everything.
            await reconcileWorkItems(paths: paths)
        }
    }

    // MARK: - Refresh

    func refreshAll() async {
        // Load known paths immediately while the independent area/service reads run.
        async let workRefresh: Void = refreshWorkItems()
        let review = prepareOverviewInbox()
        Task { await review.refresh() }
        // The sidebar first: it is one directory read, and everything below is slower.
        await refreshFolders()
        await refreshIngest()
        for folder in folders {
            await refresh(areaNamed: folder.name)
        }
        // Needs the Projects listing, so it follows the area scans.
        await refreshProjectRecords()
        await refreshMeasurements()
        await refreshBackgroundService()
        await workRefresh
        if completedInitialRefresh == false { await cleanUpInterruptedSaves() }
        refreshOverview()
        reloadTags()
        completedInitialRefresh = true
        requestMobileCloudSync()
    }

    /// One `contentsOfDirectory` against the workspace root. Deliberately separate from
    /// work-item indexing: the two were previously computed in a single detached task
    /// and `folders` was only assigned once *both* finished, so the whole Workspace
    /// section of the sidebar stayed empty behind a full-workspace walk.
    func refreshFolders() async {
        let workspace = workspace
        let store = areaConfigurations
        let discovery = folderDiscovery
        let scanned = await Task.detached(priority: .userInitiated) { () -> ([WorkspaceFolder], [String])? in
            guard let found = discovery.folders(in: workspace, store: store) else { return nil }
            // Folders someone made and has not put anything in yet. Counted here
            // because this task is already off the main actor and already reading
            // this directory.
            let empty = found.filter { folder in
                let children = (try? FileManager.default.contentsOfDirectory(atPath: folder.url.path)) ?? []
                return children.allSatisfy { NoiseFilter.isHidden(name: $0, showHidden: false) }
            }
            return (found, empty.map(\.name))
        }.value
        guard let scanned else {
            if FileManager.default.fileExists(atPath: workspace.root.path) {
                lastError = "Couldn't read the Workspace folder. Showing what was last seen."
            } else {
                workspaceAvailable = false
            }
            return
        }
        // The open area's identity, before the list changes under it.
        let openIdentity: String? = {
            if case .folder(let name)? = selection { return folder(named: name)?.identity }
            return nil
        }()
        folders = scanned.0
        emptyFolderNames = scanned.1
        // Renamed in Finder while open: follow it, the way its settings already follow
        // it by file identity, rather than showing "Folder not found".
        if case .folder(let name)? = selection, folder(named: name) == nil,
           let openIdentity, let renamed = folders.first(where: { $0.identity == openIdentity }) {
            selection = .folder(renamed.name)
        }
        if restoredSelectionPending {
            restoredSelectionPending = false
            settleRestoredSelection()
        }
        // A folder removed or renamed in Finder takes its listing with it; the renamed
        // one is read afresh under its new name.
        let present = Set(folders.map(\.name))
        for gone in itemsByArea.keys where present.contains(gone) == false {
            for item in itemsByArea[gone] ?? [] { tagsByPath.removeValue(forKey: item.url.canonicalPath) }
            itemsByArea.removeValue(forKey: gone)
        }
        for folder in folders where itemsByArea[folder.name] == nil && completedInitialRefresh {
            await refresh(areaNamed: folder.name)
        }
        refreshOverview()
    }

    /// Walks the workspace for `*.bw.md`. Single-flight, because every work-item
    /// mutation and every unattributed FSEvents burst asks for one and they would
    /// otherwise stack up behind each other.
    func refreshWorkItems() async {
        // A walk of a missing root finds nothing, which is not the same as no work.
        guard workspaceAvailable else { return }
        guard workItemScanInFlight == false else {
            workItemRefreshRequested = true
            return
        }
        workItemScanInFlight = true
        defer {
            workItemScanInFlight = false
            if !workItemPendingPaths.isEmpty {
                let paths = Array(workItemPendingPaths)
                workItemPendingPaths.removeAll()
                Task { await reconcileWorkItems(paths: paths) }
            }
        }
        if workItemsLoaded == false { await holdFirstReadIfSimulating() }
        let workspace = workspace
        let service = workItemService
        if !workItemsLoaded, let warm = await workItemPathIndex.load(under: workspace.root, service: service) {
            workItems = warm
            workItemsLoaded = true
            refreshOverview()
        }
        repeat {
            workItemRefreshRequested = false
            let scan = await Task.detached(priority: .utility) {
                #if DEBUG
                if TestIsolation.isActive, let delay = TestIsolation.launchArgument("bwWorkItemDiscoveryDelay").flatMap(Double.init) {
                    try? await Task.sleep(for: .seconds(delay))
                }
                #endif
                return service.scan(under: workspace.root)
            }.value
            guard let scan, scan.complete else {
                if !FileManager.default.fileExists(atPath: workspace.root.path) { workspaceAvailable = false }
                lastError = "Couldn't finish reading work items. Showing the last known records."
                return
            }
            // A save/event landed during the walk; don't publish the older scan.
            if workItemRefreshRequested { continue }
            var found = scan.items
            if !workItemPendingPaths.isEmpty {
                let paths = Array(workItemPendingPaths)
                workItemPendingPaths.removeAll()
                let scanned = found
                let delta = await Task.detached(priority: .utility) {
                    service.reconcile(changedPaths: paths, known: scanned)
                }.value
                switch delta {
                case .rescan: workItemRefreshRequested = true; continue
                case let .incremental(upserts, removed):
                    found = WorkItemService.merged(found, upserting: upserts, removingPaths: removed)
                }
            }
            if found.isEmpty, FileManager.default.fileExists(atPath: workspace.root.path) == false {
                workspaceAvailable = false
                return
            }
            let foundPaths = Set(found.map { $0.url.canonicalPath })
            let foundIDs = Set(found.map(\.id))
            let disappeared = workItemsLoaded
                ? workItems.filter { foundPaths.contains($0.url.canonicalPath) == false && foundIDs.contains($0.id) == false
                    && appTrashedWorkItemPaths.contains($0.url.canonicalPath) == false }
                : []
            // Confirmed gone. One this scan still found is mid-trash; keep expecting it.
            appTrashedWorkItemPaths = appTrashedWorkItemPaths.filter { foundPaths.contains($0) }
            // A record may have been moved and found at a new path. That is a normal
            // filesystem change, not a deletion, so it clears any older pending entry.
            pendingMissingWorkItems.removeAll { foundPaths.contains($0.url.canonicalPath) || foundIDs.contains($0.id) }
            if disappeared.isEmpty == false {
                pendingMissingWorkItems = WorkItemService.indexed(pendingMissingWorkItems + disappeared)
            }
            // Keep unresolved records in the list until the user makes the explicit
            // choice. This prevents a missed FSEvent from silently changing the app's
            // task view while still allowing a full refresh to discover the drift.
            workItems = WorkItemService.indexed(found + pendingMissingWorkItems)
            if pendingMissingWorkItems.isEmpty { workItemSyncPrompt = nil }
            else { presentWorkItemSyncPrompt() }
            workItemsLoaded = true
            try? await workItemPathIndex.save(found, under: workspace.root)
        } while workItemRefreshRequested
        refreshOverview()
    }

    func refreshFoldersAndWork() async {
        await refreshFolders()
        await refreshWorkItems()
    }

    // MARK: - Projects

    /// Ratings for every project, read once per refresh rather than once per row —
    /// the table renders 383 of them.
    private(set) var ratingsByProject: [String: [String: Int]] = [:]
    private(set) var projectRecordsByPath: [String: ProjectRecord] = [:]
    private(set) var measurementsByWatcherID: [String: ProjectMeasurements] = [:]
    private(set) var recentSessions: [WorkSession] = []
    private(set) var attention: [Attention.Item] = []
    var overviewFocusItems: [OverviewFocusItem] = []
    var overviewInbox: OverviewInboxController?
    private(set) var resumePoint: Attention.ResumePoint?
    private(set) var overviewNextAction: OverviewNextAction?
    private(set) var emptyFolderNames: [String] = []
    /// `nil` until the first attempt. False is an ordinary state, not an error: the
    /// daemon is an enhancement and the app is complete without it.
    private(set) var watcherReachable: Bool?

    // Background service. Each keeps its last value when a read fails: a service that
    // is restarting is not one that has no ideas. See AppModel+BackgroundService.swift.
    var liveSession: LiveSession?
    var serviceIdeasByPath: [String: IdeaRecord] = [:]
    var ideaPlanningRefreshInFlight = false
    var projectRegistrationGeneration = 0
    func updateIdeaPlanningRecords(_ records: [String: IdeaRecord]) { serviceIdeasByPath = records }
    var resurfacedSuggestions: [ServiceNotification] = []
    var workLogs: [WorkLogEntry] = []
    var workLogCoverage: [String: WorkLogDayCoverage] = [:]
    var serviceAgentStatus: BackgroundServiceAgent.Status?
    var serviceBusy = false
    var servicePoll: Task<Void, Never>?

    /// Registers the projects currently on disk and reloads what this app knows about
    /// them. Registration is pure bookkeeping: it never invents a Notion association
    /// and never writes to the Workspace.
    func refreshProjectRecords() async {
        projectRegistrationGeneration += 1
        let generation = projectRegistrationGeneration
        let urls = projects().map(\.url)
        guard urls.isEmpty == false else {
            // A deletion or a workspace-root change must not leave Overview reasoning
            // over records from a project that no longer exists.
            projectRecordsByPath = [:]
            ratingsByProject = projectStore.allRatings()
            refreshOverview()
            return
        }
        let store = projectStore
        let records = await Task.detached(priority: .utility) {
            let known = Set(store.allRecords().map(\.id))
            return urls.map { url in
                let record = store.register(url: url)
                let values = try? url.resourceValues(forKeys: [.creationDateKey, .isDirectoryKey])
                let created = values?.creationDate
                let recentlyCreated = created.map { Date().timeIntervalSince($0) < 7 * 86_400 } ?? false
                if values?.isDirectory == true, ((!known.isEmpty && !known.contains(record.id)) || recentlyCreated),
                   store.description(for: record.id).isEmpty, store.ratings(for: record.id).isEmpty {
                    store.markDiscovered(record.id)
                }
                return record
            }
        }.value
        guard projectRegistrationGeneration == generation else { return }
        projectRecordsByPath = Dictionary(records.map { ($0.lastPath, $0) }, uniquingKeysWith: { first, _ in first })
        ratingsByProject = projectStore.allRatings()
        refreshOverview()
    }

    /// Pulls observed measurements from Workspace Watcher.
    ///
    /// Failure is silent by design. A daemon that is not running means every measured
    /// column reads as unknown, which is exactly true, and nothing else changes.
    func refreshMeasurements() async {
        guard mayReadMeasurements, projectRecordsByPath.isEmpty == false else {
            measurementsByWatcherID = [:]
            recentSessions = []
            refreshOverview()
            return
        }
        let reachable = await measurementService.refresh()
        watcherReachable = reachable
        guard reachable else {
            measurementsByWatcherID = [:]
            recentSessions = []
            refreshOverview()
            return
        }
        await linkNewProjectsToWatcher()
        let records = projectRecordsByPath.values.compactMap(\.watcherID)
        await measurementService.refreshSessions()
        recentSessions = await measurementService.sessions()
        var fresh: [String: ProjectMeasurements] = [:]
        for watcherID in records {
            if let measurements = await measurementService.measurements(watcherID: watcherID) {
                fresh[watcherID] = measurements
            }
        }
        measurementsByWatcherID = fresh
        refreshOverview()
    }

    /// Joins projects that have no Watcher id yet — anything made after Better Projects'
    /// documents were imported — to the id Watcher gave the same folder.
    private func linkNewProjectsToWatcher() async {
        guard projectRecordsByPath.values.contains(where: { $0.watcherID == nil }),
              let identities = await measurementService.projectIDsByIdentityKey()
        else { return }
        let store = projectStore
        let linked = await Task.detached(priority: .utility) {
            store.linkWatcherIDs(byIdentityKey: identities)
        }.value
        guard linked > 0 else { return }
        projectRecordsByPath = projectRecordsByPath.mapValues { store.record(id: $0.id) ?? $0 }
    }

    /// Rebuilds what Overview reasons over.
    ///
    /// Gathered once from everything already loaded, so the rules stay pure and
    /// Overview never reaches into a service of its own.
    func refreshOverview() {
        rebuildOverviewFocus()
        projectViewRevision += 1
        var input = Attention.Input()
        input.now = Date()
        input.pendingIngestCount = pendingIngestCount

        let setupIDs = projectStore.setupProjectIDs()
        let scoring = scoringPreferences()
        let sessionsByWatcherID = Dictionary(grouping: recentSessions, by: \.projectID)
        input.projects = projects().map { item in
            let record = projectRecord(for: item)
            let ratings = record.map { ratingsByProject[$0.id] ?? [:] } ?? [:]
            let composite = ProjectScore(ratings: ratings, enabledMetricIDs: scoring.enabledMetricIDs,
                enabledGroups: MetricGroup.allGroups.filter { scoring.enabledGroupIDs.contains($0.id) }, groupWeights: scoring.groupWeights)
            let score = composite.projectScore
            let watcherID = record?.watcherID
            let measured = watcherID.flatMap { measurementsByWatcherID[$0] }
            return Attention.Input.Project(
                name: item.displayTitle,
                path: item.url.canonicalPath,
                contentModifiedAt: item.contentModifiedAt,
                score: score,
                ratedCount: composite.answeredCount,
                lastSessionAt: watcherID.flatMap { sessionsByWatcherID[$0] }?
                    .filter { $0.activeSeconds >= Attention.meaningfulSessionSeconds }
                    .map(\.endedAt).max(),
                observedHours: measured?.measurement(.investmentObserved)?.rawValue,
                watcherID: watcherID, needsSetup: record.map { setupIDs.contains($0.id) } ?? false
            )
        }

        input.ideas = items(for: .ideas).map { item in
            // An idea written as a single file *is* its content; only an empty folder
            // is "still just a title".
            let hasContent = item.isDirectory ? (item.immediateChildCount ?? 0) > 0 : true
            let planning = ideaRecord(for: item.url)?.planning
            return Attention.Input.Idea(name: item.displayTitle, hasContent: hasContent, path: item.url.canonicalPath,
                priority: planning?.priority ?? 3, score: planning?.score(preferences: scoring).projectScore, needsSetup: planning?.needsSetup ?? false)
        }

        // Only a folder nobody has said anything about is a prompt. An empty known area
        // (To Do, Calendar, Features…) is simply waiting to be used — surfacing those
        // made Overview report "12 folders are empty" about the Workspace's own layout,
        // forever. Hiding or configuring a folder is an answer too.
        input.emptyTopLevelFolders = emptyFolderNames.filter { folder(named: $0)?.isUnfamiliar == true }

        resumePoint = Attention.resumePoint(sessions: recentSessions, input: input)
        attention = Attention.evaluate(input)
        overviewNextAction = recommendedProjectAction()
        requestWidgetDashboardPublish()
    }

    /// Finds a real, currently actionable item and the project directory it names.
    /// A project linked from a recent session wins when it has a Now/Next item; when
    /// it does not, the same documented work-item ordering chooses among projects.
    private func recommendedProjectAction() -> OverviewNextAction? {
        // Resolve against one lookup table: matching every work item against every
        // project path ran on the main thread each inbox poll and pinned it.
        let lookup = ProjectPathLookup(projects: projects(), relativePath: workspaceRelativePath(for:))
        let candidates = workItems.compactMap { item -> (WorkItem, WorkspaceItem)? in
            guard item.isOpen, item.stage != .later,
                  let project = project(for: item, in: lookup)
            else { return nil }
            return (item, project)
        }
        guard candidates.isEmpty == false else { return nil }

        let preferences = scoringPreferences()
        var scores: [String: Double] = [:]
        for project in projects() {
            if let value = score(for: project, preferences: preferences)?.projectScore {
                scores[project.url.path] = value
                if let path = workspaceRelativePath(for: project.url) { scores[path] = value }
            }
        }
        if let best = WorkItemRecommendation.nextAction(in: candidates.map(\.0), allItems: workItems, projectScores: scores),
           let candidate = candidates.first(where: { $0.0.id == best.id }),
           best.projectPath.flatMap({ scores[$0] }) != nil {
            return OverviewNextAction(item: best, project: candidate.1, resumesRecentProject: false)
        }
        if let recentPath = resumePoint?.projectPath,
           candidates.contains(where: { $0.1.url.canonicalPath == recentPath }),
           let item = WorkItemRecommendation.nextAction(in: candidates
               .filter { $0.1.url.canonicalPath == recentPath }
               .map(\.0), allItems: workItems) {
            let project = candidates.first {
                $0.0.url.canonicalPath == item.url.canonicalPath && $0.1.url.canonicalPath == recentPath
            }!.1
            return OverviewNextAction(item: item, project: project, resumesRecentProject: true)
        }

        guard let item = WorkItemRecommendation.nextAction(in: candidates.map(\.0), allItems: workItems),
              let candidate = candidates.first(where: { $0.0.url.canonicalPath == item.url.canonicalPath })
        else { return nil }
        return OverviewNextAction(item: item, project: candidate.1, resumesRecentProject: false)
    }

    /// Work-item project references are intentionally portable, workspace-relative
    /// paths. Resolve one only against an actual project currently discovered here;
    /// no private project copy or guessed directory is ever created.
    private func project(for item: WorkItem, in lookup: ProjectPathLookup) -> WorkspaceItem? {
        guard let rawPath = item.projectPath else { return nil }
        if let projectPath = MobileWorkspacePath.normalizedRelative(rawPath),
           let project = lookup.byRelativePath[projectPath] {
            return project
        }
        // Early Notion imports wrote this field as an absolute Mac path. New imports
        // write portable paths, but keep old files useful without rewriting them just
        // because they were opened: organized Markdown remains user-owned.
        guard rawPath.hasPrefix("/") else { return nil }
        return lookup.project(atCanonicalPath: URL(fileURLWithPath: rawPath).canonicalPath)
    }

    func workspaceRelativePath(for url: URL) -> String? {
        // Discovery has already established these URLs under `workspace.root`.
        // Do not canonicalize here: this helper feeds table-row derivation, where a
        // canonical path performs filesystem reachability checks for every project.
        // Portable work-item links are authored as lexical workspace-relative paths.
        let rootPath = workspace.root.path
        let path = url.path
        guard path.hasPrefix(rootPath + "/") else { return nil }
        return MobileWorkspacePath.normalizedRelative(String(path.dropFirst(rootPath.count + 1)))
    }

    func measurements(for item: WorkspaceItem) -> ProjectMeasurements? {
        guard let watcherID = projectRecord(for: item)?.watcherID else { return nil }
        return measurementsByWatcherID[watcherID]
    }

    /// Opens the specific project screen for Overview and relationship links.
    func reveal(projectPath: String) {
        let path = URL(fileURLWithPath: projectPath).canonicalPath
        guard let item = projects().first(where: { $0.url.canonicalPath == path })
        else { return }
        openProjectWorkspace(for: item)
    }

    /// An item to select once its area has opened. Changing area clears the selection
    /// (ContentView), and that runs after whoever changed it, so setting both at once
    /// lost the item: Overview's Recently rows opened Projects with nothing selected.
    var selectionAfterNavigation: WorkspaceItem?

    func navigate(to destination: SidebarSelection, selecting item: WorkspaceItem?) {
        if selection == destination {
            selectedItem = item
        } else {
            selectionAfterNavigation = item
            selection = destination
        }
    }

    func reveal(workItem: WorkItem) {
        focusedWorkItemPath = workItem.url.canonicalPath
        // Work is organised in real queues. Follow a relationship into that queue
        // (for example Milestone → task opens To Do) instead of exposing a duplicate
        // global Work destination.
        if let queue = folders
            .filter({ workItem.url.canonicalPath.hasPrefix($0.url.canonicalPath + "/") })
            .max(by: { $0.url.canonicalPath.count < $1.url.canonicalPath.count }) {
            selection = .folder(queue.name)
        } else {
            // Kept as a recovery view for a hand-authored record outside a known queue.
            selection = .work
        }
    }

    func revealProject(for workItem: WorkItem) {
        let lookup = ProjectPathLookup(projects: projects(), relativePath: workspaceRelativePath(for:))
        guard let project = project(for: workItem, in: lookup) else { return }
        reveal(projectPath: project.url.canonicalPath)
    }

    func projectRecord(for item: WorkspaceItem) -> ProjectRecord? {
        projectRecordsByPath[item.url.canonicalPath]
    }

    func score(for item: WorkspaceItem) -> ProjectScore? {
        guard let record = projectRecord(for: item) else { return nil }
        return ProjectScore(ratings: ratingsByProject[record.id] ?? [:])
    }

    func reloadProjectRatings() { ratingsByProject = projectStore.allRatings() }

    func setRating(_ value: Int?, metric: MetricDefinition, for record: ProjectRecord) {
        projectStore.setRating(value, metricID: metric.id, for: record.id)
        var ratings = ratingsByProject[record.id] ?? [:]
        if let value { ratings[metric.id] = value } else { ratings.removeValue(forKey: metric.id) }
        ratingsByProject[record.id] = ratings
        if let item = projects().first(where: { projectRecord(for: $0)?.id == record.id }) { queueProjectGraphEdits(for: item, fields: [metric.displayName]) }
        refreshOverview()
    }

    // MARK: - Importing from Notion

    struct NotionMappingReview {
        let groups: [NotionImport.UnresolvedProjectGroup]
        /// Only unlinked directories are candidates.  An established association is
        /// history, not a suggestion this review can silently replace.
        let localProjectCandidates: [ProjectRecord]
    }

    private(set) var notionPlan: NotionImport.Plan?
    private(set) var notionMappingReview: NotionMappingReview?
    /// A project-metadata import is deliberately separate from the planning importer:
    /// it fetches only the Projects database and holds the response in memory until a
    /// person selects fields. Normal portfolio rendering never reads this state.
    private(set) var projectMetadataImportPreviews: [ProjectMetadataImport.Preview] = []
    private(set) var projectMetadataImportUnavailableRelations = 0
    private(set) var notionBusy = false
    /// The last successfully fetched snapshot stays in memory only long enough for a
    /// person to review mappings.  Mapping then re-plans locally — it does not make a
    /// second Notion request and nothing about normal app use depends on this cache.
    private var notionImportSource: NotionImport.Source?
    private var notionImportOptions: NotionImport.Options?

    var hasNotionToken: Bool { SecretStore.hasNotionToken }
    var canPreviewProjectMetadataImport: Bool {
        hasNotionToken && NotionSettings.load().databases.projects != nil
    }

    /// Fills the import's empty database slots from the databases the token can see,
    /// matched by title — every empty slot when asked, only undecided ones when this
    /// runs by itself after a token is saved. Answers how many slots were filled, or nil
    /// when Notion could not be read.
    @discardableResult
    func discoverNotionDatabases(onlyUndecided: Bool = false) async -> Int? {
        guard let token = SecretStore.read() else {
            lastError = NotionClient.Failure.noCredentials.localizedDescription
            return nil
        }
        notionBusy = true
        defer { notionBusy = false }
        do {
            let found = try await NotionClient(token: token).searchDatabases()
            let before = NotionSettings.load()
            let after = before.filled(from: found, onlyUndecided: onlyUndecided)
            after.save()
            let ids = { (s: NotionSettings) in
                [s.databases.tasks, s.databases.milestones, s.databases.features,
                 s.databases.ideas, s.databases.projects, s.databases.socialPosts].compactMap { $0 }.count
            }
            let filled = ids(after) - ids(before)
            statusMessage = "Found \(found.count) shared Notion databases; filled \(filled)"
            return filled
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    /// Reads the configured Notion databases and works out what an import would do.
    /// Nothing is written; the plan is shown first.
    func planNotionImport(options: NotionImport.Options = .init()) async {
        guard let token = SecretStore.read() else {
            lastError = NotionClient.Failure.noCredentials.localizedDescription
            return
        }
        notionBusy = true
        defer { notionBusy = false }

        let settings = NotionSettings.load()
        let client = NotionClient(token: token)
        var source = NotionImport.Source()

        func fetch(_ id: String?, _ label: String) async -> [NotionPage] {
            guard let id else { return [] }
            do {
                let (pages, complete) = try await client.allPages(inDatabase: id)
                if complete == false { source.truncated.append(label) }
                return pages
            } catch {
                lastError = error.localizedDescription
                return []
            }
        }

        source.tasks = await fetch(settings.databases.tasks, "Tasks")
        source.milestones = await fetch(settings.databases.milestones, "Milestones")
        source.features = await fetch(settings.databases.features, "Features")
        source.ideas = await fetch(settings.databases.ideas, "Ideas")
        source.projects = await fetch(settings.databases.projects, "Projects")
        source.socialPosts = await fetch(settings.databases.socialPosts, "Social Posts")

        await refreshProjectRecords()
        refreshNotionPlan(from: source, options: options)
    }

    /// Fetches the optional Notion Projects database once and compares only pages that
    /// are already linked to a local project.  This is a dry run: values stay in memory
    /// and no project metadata, link, or folder is changed here.
    func planProjectMetadataImport() async {
        guard let token = SecretStore.read() else {
            lastError = NotionClient.Failure.noCredentials.localizedDescription
            return
        }
        guard let databaseID = NotionSettings.load().databases.projects else {
            lastError = "No Notion Projects database is configured. Notion is optional; add its database ID in Settings to import metadata."
            return
        }
        notionBusy = true
        defer { notionBusy = false }
        do {
            let result = try await NotionClient(token: token).allPages(inDatabase: databaseID)
            guard result.complete else {
                lastError = "The Notion Projects database was too large to read completely. No metadata preview was created."
                return
            }
            await refreshProjectRecords()
            let records = Array(projectRecordsByPath.values)
            let linkedRecordsByNotionID = Dictionary(
                records.compactMap { record in record.notionPageID.map { (NotionImport.normalizedID($0), record) } },
                uniquingKeysWith: { first, _ in first }
            )
            // Metadata import follows the same conservative identity rules as the
            // planning importer. A unique exact title or Local Directory match is
            // eligible for the reviewed preview; it is not persisted as a Notion link
            // until the person imports at least one checked field for that project.
            let resolution = NotionImport.resolveProjectLinks(
                notionProjects: result.pages, localProjects: records, workspaceRoot: workspace.root
            )
            let recordsByID = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
            var previewRecordsByNotionID = linkedRecordsByNotionID
            for link in resolution.links {
                if let record = recordsByID[link.projectID] {
                    previewRecordsByNotionID[link.notionPageID] = record
                }
            }
            let namesByNotionID = Dictionary(
                result.pages.compactMap { page in page.title.map { (NotionImport.normalizedID(page.id), $0) } },
                uniquingKeysWith: { first, _ in first }
            )
            let itemsByPath = Dictionary(uniqueKeysWithValues: projects().map { ($0.url.canonicalPath, $0) })
            var unavailableRelations = 0
            let previews = result.pages.compactMap { page -> ProjectMetadataImport.Preview? in
                let pageID = NotionImport.normalizedID(page.id)
                guard let record = previewRecordsByNotionID[pageID] else { return nil }
                let localItem = itemsByPath[record.lastPath]
                let localRelated = localItem.map { relatedProjects(for: $0).map(\.displayTitle) } ?? []
                let notionValues = ProjectMetadataImport.values(from: page)
                let relationNames = notionValues.relatedNotionPageIDs.compactMap { relatedID -> String? in
                    guard previewRecordsByNotionID[NotionImport.normalizedID(relatedID)] != nil else {
                        unavailableRelations += 1
                        return nil
                    }
                    return namesByNotionID[NotionImport.normalizedID(relatedID)]
                }
                return ProjectMetadataImport.preview(
                    projectID: record.id, projectName: record.name, notionPageID: pageID,
                    localMetadata: projectStore.metadata(for: record.id),
                    localDescription: projectStore.description(for: record.id),
                    localPortfolioDetails: projectStore.portfolioDetails(for: record.id),
                    localRelatedProjectNames: localRelated, page: page,
                    relatedNotionProjectNames: relationNames
                )
            }
            projectMetadataImportPreviews = previews.sorted {
                $0.projectName.localizedStandardCompare($1.projectName) == .orderedAscending
            }
            projectMetadataImportUnavailableRelations = unavailableRelations
            let fillCount = previews.reduce(0) { $0 + $1.changes.filter { $0.state == .fill }.count }
            statusMessage = "Compared \(previews.count) linked or exact-match Projects pages; \(fillCount) empty local fields can be imported."
        } catch {
            projectMetadataImportPreviews = []
            lastError = error.localizedDescription
        }
    }

    /// Commits precisely the checked preview fields.  The values were fetched by the
    /// preceding dry run; applying them makes no Notion request and writes only private
    /// SQLite rows, never project folders or `.bw.md` records.
    @discardableResult
    func applyProjectMetadataImport(_ selected: [String: Set<ProjectMetadataImport.Field>]) -> Int {
        guard selected.isEmpty == false else { return 0 }
        let previews = projectMetadataImportPreviews
        let recordsByNotionID = Dictionary(
            previews.compactMap { preview in projectStore.record(id: preview.projectID).map { (preview.notionPageID, $0) } },
            uniquingKeysWith: { first, _ in first }
        )
        var changedProjects = 0
        do {
            try projectStore.batch {
                for preview in previews {
                    guard let fields = selected[preview.projectID], fields.isEmpty == false,
                          let record = projectStore.record(id: preview.projectID)
                    else { continue }
                    // A conservative exact match becomes a durable private mapping
                    // only as part of this explicit reviewed import.
                    if record.notionPageID == nil {
                        try projectStore.setExplicitNotionPageID(preview.notionPageID, for: record.id)
                    }
                    let applied = ProjectMetadataImport.applying(
                        fields, values: preview.values,
                        to: projectStore.metadata(for: record.id), description: projectStore.description(for: record.id),
                        portfolioDetails: projectStore.portfolioDetails(for: record.id)
                    )
                    projectStore.setMetadata(applied.metadata, for: record.id)
                    projectStore.setDescription(applied.description, for: record.id)
                    projectStore.setPortfolioDetails(applied.portfolioDetails, for: record.id)
                    if fields.contains(.relatedProjects) {
                        let targets = Set(preview.values.relatedNotionPageIDs.compactMap {
                            recordsByNotionID[NotionImport.normalizedID($0)]?.id
                        })
                        projectStore.setRelatedProjectIDs(targets, for: record.id)
                    }
                    changedProjects += 1
                }
            }
        } catch {
            lastError = "Could not import project metadata: \(error.localizedDescription)"
            return 0
        }
        projectMetadataImportPreviews = []
        projectMetadataImportUnavailableRelations = 0
        statusMessage = "Imported selected metadata for \(changedProjects) projects."
        refreshOverview()
        Task { await refreshProjectRecords() }
        return changedProjects
    }

    /// Rebuilds a Notion preview from an already-fetched snapshot.  Exact automatic
    /// links are still preview-only; person-confirmed links have already been saved in
    /// ProjectStore and therefore take precedence on every later preview.
    private func refreshNotionPlan(from source: NotionImport.Source, options: NotionImport.Options) {
        let localProjects = Array(projectRecordsByPath.values)
        let resolution = NotionImport.resolveProjectLinks(
            notionProjects: source.projects, localProjects: localProjects, workspaceRoot: workspace.root
        )
        var byNotionID = Dictionary(
            localProjects.compactMap { record in
                record.notionPageID.map { (NotionImport.normalizedID($0), record) }
            },
            uniquingKeysWith: { first, _ in first }
        )
        let recordsByID = Dictionary(uniqueKeysWithValues: localProjects.map { ($0.id, $0) })
        for link in resolution.links {
            if let record = recordsByID[link.projectID] {
                byNotionID[link.notionPageID] = record
            }
        }
        let ideaNames = Set(items(for: .ideas).map(\.name))

        var plan = NotionImport.plan(
            from: source, options: options,
            destinations: .init(workspace: workspace, folders: folders),
            projectsByNotionID: byNotionID,
            existingWorkItems: workItems,
            existingIdeaNames: ideaNames,
            existingSocialPostIDs: Set(socialPosts.map(\.id)),
            projectLinks: resolution.links
        )
        if resolution.links.isEmpty == false {
            plan.warnings.append("\(resolution.links.count) exact Notion project matches will be linked when you import.")
        }
        if resolution.unmatchedCount > 0 {
            plan.warnings.append("\(resolution.unmatchedCount) Notion projects did not have a unique local directory or name match; existing links were left unchanged.")
        }
        notionPlan = plan
        notionImportSource = source
        notionImportOptions = options
        let groups = NotionImport.unresolvedPlanningGroups(
            from: source, linkedNotionProjectIDs: Set(byNotionID.keys), options: options
        )
        notionMappingReview = groups.isEmpty ? nil : NotionMappingReview(
            groups: groups,
            localProjectCandidates: localProjects.filter { $0.hasNotionLink == false }
        )
    }

    /// Saves a mapping chosen in the review sheet, then re-plans from the in-memory
    /// snapshot.  This is intentionally one-to-one and conservative; a reviewer cannot
    /// replace an existing external association by accident.
    func mapNotionProject(_ notionProjectID: String, to localProjectID: String) async {
        guard let source = notionImportSource, let options = notionImportOptions else { return }
        do {
            try projectStore.setExplicitNotionPageID(notionProjectID, for: localProjectID)
            await refreshProjectRecords()
            refreshNotionPlan(from: source, options: options)
            statusMessage = "Saved Notion project mapping and updated the import preview."
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Writes the plan that was shown. This is the one place an import touches disk.
    func applyNotionImport() async {
        guard let plan = notionPlan else { return }
        notionBusy = true
        defer { notionBusy = false }
        // The preview's associations are applied immediately before records are
        // written. ProjectStore is private app metadata; Workspace folders remain
        // untouched and an existing association is never replaced by this pass.
        let store = projectStore
        let currentRecords = Dictionary(uniqueKeysWithValues: projectRecordsByPath.values.map { ($0.id, $0) })
        let links = plan.projectLinks.filter { link in
            currentRecords[link.projectID]?.notionPageID == nil
        }
        let result: NotionImport.Result = await Task.detached(priority: .userInitiated) { () -> NotionImport.Result in
            for link in links { store.setNotionPageID(link.notionPageID, for: link.projectID) }
            return NotionImport.apply(plan)
        }.value
        statusMessage = "Linked \(links.count) projects; imported \(result.workItemsCreated) work items, \(result.ideasCreated) ideas and \(result.socialPostsCreated) social posts"
        if let failure = result.failures.first { lastError = failure }
        notionPlan = nil
        notionMappingReview = nil
        notionImportSource = nil
        notionImportOptions = nil
        await refreshWorkItems()
        await refreshProjectRecords()
        await refresh(area: .ideas)
        await refresh(area: .socialPosts)
    }

    // MARK: - Migrating out of Better Projects

    struct LegacyImportSummary: Sendable {
        var documents = 0
        var projectsRegistered = 0
        var notionLinksRecovered = 0
        var ratedProjects = 0
        var ratingsImported = 0
        var missingDirectories = 0
        var conflicts = 0

        var description: String {
            "\(projectsRegistered) projects, \(notionLinksRecovered) Notion links, "
                + "\(ratingsImported) ratings across \(ratedProjects) projects"
        }
    }

    /// Reads Better Projects' documents and ratings cache into this app's own store.
    ///
    /// Writes nothing to `~/Workspace` — not even the sidecars it reads — so a preview
    /// and a real run differ only in whether this app's database changes.
    @discardableResult
    func runLegacyImport(apply: Bool) async -> LegacyImportSummary {
        let root = workspace.url(for: .projects)
        let store = projectStore
        let summary = await Task.detached(priority: .userInitiated) { () -> LegacyImportSummary in
            let documents = LegacyImport.scanDocuments(in: root)
            let documentReport = LegacyImport.importDocuments(documents, into: store, apply: apply)
            // Ratings join to projects by Notion page id, so they can only be matched
            // after the documents have supplied those ids.
            let ratingsReport = LegacyImport.importRatings(into: store, apply: apply)
            return LegacyImportSummary(
                documents: documentReport.discovered,
                projectsRegistered: documentReport.imported,
                notionLinksRecovered: documentReport.notionLinksRecovered,
                ratedProjects: ratingsReport.matchedToLocalProject,
                ratingsImported: ratingsReport.ratingsWritten,
                missingDirectories: documentReport.skippedMissingDirectory.count,
                conflicts: documentReport.conflicts.count
            )
        }.value

        if apply {
            await refreshProjectRecords()
            statusMessage = "Imported \(summary.description)"
        }
        return summary
    }

    // MARK: - Area configuration

    func folder(named name: String) -> WorkspaceFolder? {
        folders.first { $0.name == name }
    }

    /// A subtitle the person gave an area. The built-in ones ("Action queue", "Titles as
    /// thoughts") described the area to its designer; repeated in every header they are
    /// noise, so only a personal one is shown.
    func headerSubtitle(forFolderNamed name: String) -> String? {
        areaConfigurations.entry(forFolderNamed: name)?.configuration.subtitle.flatMap { $0.isEmpty ? nil : $0 }
    }
    func headerSubtitle(for area: WorkspaceArea) -> String? { headerSubtitle(forFolderNamed: area.directoryName) }

    /// A purpose-built area's resolved settings, so its dedicated view still honors a
    /// personal symbol or subtitle. Defaults answer before the first discovery.
    func settings(for area: WorkspaceArea) -> AreaSettings {
        folder(named: area.directoryName)?.settings
            ?? AreaSettings(resolving: AreaDefaults.configuration(forFolderNamed: area.directoryName),
                            purposeBuilt: area)
    }

    /// Replaces an area's personal settings. Only this app's private file changes; the
    /// folder and everything in it stay exactly as they are.
    func setConfiguration(_ configuration: AreaConfiguration, for folder: WorkspaceFolder) {
        do {
            try areaConfigurations.set(configuration, forFolderNamed: folder.name, identity: folder.identity)
        } catch {
            lastError = "Couldn't save settings for \(folder.name): \(error.localizedDescription)"
            return
        }
        Task { await refreshFolders() }
    }

    func refresh(area: WorkspaceArea) async {
        await refresh(areaNamed: area.directoryName)
    }

    /// Which read of each area is the latest. Two reads can overlap (a full refresh
    /// still reading Projects when a file event starts another); whichever *finished*
    /// last used to win, so an older listing could land on top of a newer one.
    private var areaReadGeneration: [String: Int] = [:]

    func refresh(areaNamed area: String) async {
        guard workspaceAvailable else { return }
        loadingAreas.insert(area)
        defer { loadingAreas.remove(area) }
        if itemsByArea[area] == nil { await holdFirstReadIfSimulating() }
        areaReadGeneration[area, default: 0] += 1
        let generation = areaReadGeneration[area]
        let location = workspace
        let items: [WorkspaceItem]
        do {
            items = try await fs.items(inArea: area, location: location)
        } catch {
            // An unavailable external/iCloud directory is not an empty directory.
            // Keeping the last known list prevents an interrupted provider read from
            // falsely deleting UI rows or a future mobile projection.
            lastError = "Couldn't read \(area): \(error.localizedDescription)"
            if itemsByArea[area] == nil { unreadableAreas.insert(area) }
            return
        }
        // Superseded while reading: a newer read of this area will publish.
        guard areaReadGeneration[area] == generation else { return }
        // An empty answer because the whole root vanished mid-read is not an empty area.
        if items.isEmpty, FileManager.default.fileExists(atPath: workspace.root.path) == false {
            workspaceAvailable = false
            return
        }
        // The path-keyed tag cache is an optimization, not a second source of truth.
        // Drop entries that disappeared from this area before publishing its new list
        // so a Finder deletion/rename cannot keep a stale tag set reachable in the UI.
        let currentPaths = Set(items.map { $0.url.canonicalPath })
        for old in itemsByArea[area] ?? [] {
            let path = old.url.canonicalPath
            if currentPaths.contains(path) == false { tagsByPath.removeValue(forKey: path) }
        }
        itemsByArea[area] = items
        unreadableAreas.remove(area)
        reloadTagAssignments(for: items)
        areaRevisions[area, default: 0] += 1
        await refreshSelection(in: area, topLevel: items)
        if area == WorkspaceArea.projects.directoryName, completedInitialRefresh {
            let current = projects()
            let changed = current.count != projectRecordsByPath.count || current.contains { item in
                guard let record = projectRecordsByPath[item.url.canonicalPath] else { return true }
                return record.identityKey != item.identity?.key
            }
            if changed { await refreshProjectRecords() } else { refreshOverview() }
        } else if area == WorkspaceArea.ideas.directoryName, completedInitialRefresh {
            Task { await refreshIdeaPlanning() }
            refreshOverview()
        } else if area == WorkspaceArea.projects.directoryName || area == WorkspaceArea.ideas.directoryName {
            refreshOverview()
        }
        if area == WorkspaceArea.socialPosts.directoryName {
            await refreshSocialPosts()
        }
        requestMobileCloudSync()
    }

    /// Bumped each time an area is re-read, which happens for a change anywhere inside
    /// it. Views that keep their own copy of something below the area — a drilled
    /// folder, a log's tail, an outline's opened folders — reload when it moves.
    ///
    /// Keying those reloads on the item *count* missed every change that keeps the count:
    /// a log line appended, a file edited or renamed, something added inside a subfolder.
    private(set) var areaRevisions: [String: Int] = [:]

    func revision(ofArea name: String) -> Int { areaRevisions[name] ?? 0 }

    /// Keeps the inspector on the live item after an area is re-read.
    ///
    /// The selection is a snapshot, so without this it kept showing the size and date
    /// from when it was clicked. And the old check cleared any selection that was not
    /// one of the area's top-level items — which every nested selection is (an opened
    /// outline folder, a drilled gallery, a log file) — so any change anywhere in the
    /// area silently emptied the inspector.
    private func refreshSelection(in area: String, topLevel items: [WorkspaceItem]) async {
        guard let selected = selectedItem, workspace.areaName(containing: selected.url) == area else { return }
        let path = selected.url.canonicalPath
        if let fresh = items.first(where: { $0.url.canonicalPath == path }) {
            selectedItem = fresh
            return
        }
        let isTopLevel = selected.url.deletingLastPathComponent().canonicalPath
            == workspace.url(forArea: area).canonicalPath
        let fresh = isTopLevel ? nil : await fs.makeItem(url: selected.url)
        // Someone may have selected something else while this looked.
        guard selectedItem?.id == selected.id else { return }
        selectedItem = fresh
    }

    /// True when the inbox could not be read in time — an iCloud file provider that is
    /// asleep. The queue keeps showing whatever was last known rather than claiming zero.
    private(set) var ingestStalled = false

    /// False until the inbox has been read once. A stalled first read sets
    /// `ingestStalled` instead, so the two together say whether the queue is known.
    private(set) var ingestScannedOnce = false

    /// False until the real inbox location has been worked out. Resolution stats iCloud
    /// paths and can take a few seconds, during which the provisional location would
    /// otherwise be displayed as if it were the answer.
    private(set) var ingestLocationResolved = false

    /// One inbox scan at a time. The poll and file events both ask for scans, and
    /// overlapping ones could publish out of order — and would count as the two
    /// consecutive misses that let a capture's private title be forgotten.
    private var ingestScanInFlight = false
    private var ingestRescanRequested = false

    func refreshIngest() async {
        guard ingestScanInFlight == false else {
            ingestRescanRequested = true
            return
        }
        ingestScanInFlight = true
        defer { ingestScanInFlight = false }
        repeat {
            ingestRescanRequested = false
            await scanIngest()
        } while ingestRescanRequested
    }

    private func scanIngest() async {
        if ingestScannedOnce == false { await holdFirstReadIfSimulating() }
        guard let items = await ingest.pendingItems(fsService: fs) else {
            ingestStalled = true
            return
        }
        ingestStalled = false
        ingestScannedOnce = true
        let previousPaths = Set(ingestItems.map { $0.url.canonicalPath })
        let currentPaths = Set(items.map { $0.url.canonicalPath })
        let previousPendingCount = pendingIngestCount
        for path in previousPaths.subtracting(currentPaths) {
            tagsByPath.removeValue(forKey: path)
        }
        ingestItems = items
        if ingestCursor >= items.count { ingestCursor = max(0, items.count - 1) }
        reloadTagAssignments(for: items.map(\.item))
        if let selected = selectedIngestItem {
            // A Finder deletion or classification in another process must not leave
            // the inspector editing an in-memory capture that no longer exists.
            selectedIngestItem = items.first(where: { $0.id == selected.id })
        }
        // The inbox poll and FSEvents call this method directly. Rebuild the derived
        // signal here so an arriving or filed capture is reflected on Overview without
        // requiring a manual refresh or app relaunch. Only when the inbox actually
        // changed: this runs every five seconds, and a rebuild also invalidates the
        // Projects views, which then recompute every row on the main thread.
        if previousPaths != currentPaths || previousPendingCount != pendingIngestCount {
            refreshOverview()
        }
        // Filing is what removes an item from the inbox, so only then can this change.
        if previousPaths != currentPaths || recentlyFiledLoaded == false {
            await reloadRecentlyFiledIngest()
        }
        // A new iCloud file might have appeared after the phone's intent reached
        // CloudKit. Ask immediately rather than waiting for the periodic command poll.
        if previousPaths != currentPaths { requestMobileCloudSync() }
    }

    func items(for area: WorkspaceArea) -> [WorkspaceItem] { itemsByArea[area.directoryName] ?? [] }

    /// Social posts are an explicit Markdown vocabulary, so only `.social.md` files
    /// directly inside this area are part of the post queue.
    func refreshSocialPosts() async {
        let directory = workspace.url(for: .socialPosts)
        socialPosts = await Task.detached(priority: .userInitiated) {
            SocialPostService().items(in: directory)
        }.value
        socialPostsLoaded = true
    }

    func items(inArea name: String) -> [WorkspaceItem] { itemsByArea[name] ?? [] }

    /// Underscore-prefixed folders in Projects are organizational spaces. They remain
    /// browsable, but they must not acquire project ratings, links, or planning data.
    func projects() -> [WorkspaceItem] {
        items(for: .projects).filter { $0.projectFolderRole == nil }
    }

    func projectSpaces() -> [WorkspaceItem] {
        items(for: .projects).filter { $0.projectFolderRole != nil }
    }

    func items(in folder: URL) async -> [WorkspaceItem] {
        (try? await fs.items(inDirectory: folder)) ?? []
    }

    /// True once an area's listing has been read at least once. Until then its
    /// capabilities are unknown, not absent.
    func hasLoaded(areaNamed name: String) -> Bool { itemsByArea[name] != nil }

    /// True while an area has never been read and a read is still expected. Views show
    /// a loading state then, rather than claiming the area is empty.
    func isAwaitingFirstRead(areaNamed name: String) -> Bool {
        workspaceAvailable && itemsByArea[name] == nil && unreadableAreas.contains(name) == false
    }

    func isAwaitingFirstRead(of area: WorkspaceArea) -> Bool {
        isAwaitingFirstRead(areaNamed: area.directoryName)
    }

    #if DEBUG
    static let simulatedReadDelayArgument = "bwSimulatedReadDelay"
    /// `-bwSimulatedReadDelay <seconds>` holds every first read back until that long after
    /// the first one starts, so a UI test can see the loading states. Isolated runs only.
    private static let simulatedReadRelease: ContinuousClock.Instant? = {
        guard TestIsolation.isActive,
              let value = TestIsolation.launchArgument(simulatedReadDelayArgument),
              let seconds = Double(value) else { return nil }
        return .now + .seconds(seconds)
    }()
    #endif

    /// A no-op except in an isolated test run that asked for slow first reads.
    func holdFirstReadIfSimulating() async {
        #if DEBUG
        if let release = Self.simulatedReadRelease { try? await Task.sleep(until: release) }
        #endif
    }

    /// Children of a folder below an area, for views that open folders in place.
    /// `nil` means the folder could not be read in time — not that it is empty.
    func children(of directory: URL) async -> [WorkspaceItem]? {
        await FilesystemService.items(inDirectory: directory, timeout: .seconds(8))
    }

    /// Work items anywhere below a folder.
    func workItems(under folder: URL) -> [WorkItem] {
        let root = folder.canonicalPath + "/"
        return workItems.filter { $0.url.canonicalPath.hasPrefix(root) }
    }

    /// What an area's current contents support, which decides the views it offers.
    func capabilities(for folder: WorkspaceFolder) -> AreaCapabilities {
        AreaCapabilities(items: items(inArea: folder.name), workItemCount: workItems(under: folder.url).count)
    }

    /// Shared transparent ordering for any future Work entry point. A `Later` item is
    /// not shown as an immediate recommendation.
    var recommendedWorkItem: WorkItem? {
        WorkItemRecommendation.nextAction(in: workItems)
    }

    // Each operation writes one file and patches that one record into `workItems`.
    // They used to finish with a walk of the entire Workspace (1–2 s on the real one),
    // which the save's own file event then repeated.

    @discardableResult
    func createWorkItem(id: String = UUID().uuidString, kind: WorkItemKind, title: String, body: String,
                        status: WorkItemStatus, stage: WorkItemStage,
                        priority: WorkItemPriority, projectPath: String?, parentID: String? = nil,
                        relatedIDs: [String] = [], featureIDs: [String] = [], milestoneIDs: [String] = [],
                        dependencyIDs: [String] = [], in directory: URL) async throws -> WorkItem {
        let projectPath = try validatedProjectPath(projectPath, for: kind)
        let draft = WorkItem(id: id, kind: kind, title: title, status: status, stage: stage,
                             priority: priority, projectPath: projectPath, parentID: parentID,
                             relatedIDs: relatedIDs, dependencyIDs: dependencyIDs, featureIDs: featureIDs,
                             milestoneIDs: milestoneIDs, body: body, url: directory.appendingPathComponent("placeholder"))
        let service = workItemService
        let saved = try await Task.detached(priority: .userInitiated) { try service.create(draft, in: directory) }.value
        adopt(saved)
        queueGraphWork(saved)
        statusMessage = "Created \(saved.kind.displayName.lowercased()) “\(saved.title)”"
        return saved
    }

    /// Creates what a work-item editor described, in the queue set up for its kind (as
    /// the phone and Notion import route it), or To Do.
    @discardableResult
    func createWorkItem(_ value: WorkItemEditor.Value) async throws -> WorkItem {
        try await createWorkItem(kind: value.kind, title: value.title, body: value.body, status: value.status,
                                 stage: value.stage, priority: value.priority, projectPath: value.projectPath,
                                 parentID: value.parentID, relatedIDs: value.relatedIDs, featureIDs: value.featureIDs,
                                 milestoneIDs: value.milestoneIDs, dependencyIDs: value.dependencyIDs,
                                 in: WorkQueueRouting.folder(for: value.kind, among: folders)?.url ?? workspace.url(forArea: "To Do"))
    }

    /// Saves an edited record. Throws `WorkItemError.changedOnDisk` or `.missing`
    /// rather than overwriting a change made elsewhere or recreating a moved file.
    @discardableResult
    func saveWorkItem(_ item: WorkItem) async throws -> WorkItem {
        if let previous = workItems.first(where: { $0.id == item.id }), previous.importedNotionPageID != nil {
            if previous.kind != item.kind { throw NotionProjectSync.SyncError.unsupported("A linked Notion record cannot change databases through its portable type. Create a new record or review its binding.") }
            if isComputedNotionMilestone(previous) && previous.status != item.status { throw NotionProjectSync.SyncError.unsupported("Notion computes this milestone's status. Edit its tasks and dates instead.") }
        }
        var item = item
        item.projectPath = try validatedProjectPath(item.projectPath, for: item.kind)
        let service = workItemService
        let saved = try await Task.detached(priority: .userInitiated) { try service.update(item) }.value
        adopt(saved)
        queueGraphWork(saved)
        return saved
    }

    /// A project is optional for every kind: a feature captured without one is listed
    /// under its queue's Needs Attention until it is placed. A project that *is* named
    /// must still be one that exists, for features and milestones, so the link is never
    /// a dangling path. Tasks and goals intentionally remain more flexible.
    func validatedProjectPath(_ rawPath: String?, for kind: WorkItemKind) throws -> String? {
        let needsProject = kind == .feature || kind == .milestone
        guard let rawPath, rawPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            return nil
        }

        let project = projects().first { item in
            workspaceRelativePath(for: item.url) == MobileWorkspacePath.normalizedRelative(rawPath)
                || item.url.canonicalPath == URL(fileURLWithPath: rawPath).canonicalPath
        }
        guard let project else {
            if needsProject { throw WorkItemProjectLinkError.unavailable(kind, rawPath) }
            return rawPath
        }
        return workspaceRelativePath(for: project.url) ?? rawPath
    }

    enum WorkItemProjectLinkError: LocalizedError {
        case unavailable(WorkItemKind, String)

        var errorDescription: String? {
            switch self {
            case let .unavailable(kind, path):
                return "\(path) is not a current project, so this \(kind.displayName.lowercased()) was not saved."
            }
        }
    }

    /// Fire-and-forget form for list controls; failures go to the error banner.
    func updateWorkItem(_ item: WorkItem) {
        Task { do { try await saveWorkItem(item) } catch { lastError = error.localizedDescription } }
    }

    func completeWorkItem(_ item: WorkItem) {
        guard !isComputedNotionMilestone(item) else { lastError = "Notion computes this milestone's status. Edit its tasks and dates instead."; return }
        // The row may still hold the snapshot from before an earlier save; complete the
        // current record, or a quick second click reads as "changed in another editor".
        let current = workItems.first { $0.id == item.id } ?? item
        if pendingWorkItemCompletionIDs.contains(current.id) {
            pendingWorkItemCompletionTasks.removeValue(forKey: current.id)?.cancel()
            pendingWorkItemCompletionIDs.remove(current.id)
            statusMessage = "Kept “\(current.title)” open"
            return
        }
        if current.status == .completed {
            reopenWorkItem(current)
            return
        }
        pendingWorkItemCompletionIDs.insert(current.id)
        pendingWorkItemCompletionTasks[current.id] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1.25))
            guard Task.isCancelled == false, let self,
                  self.pendingWorkItemCompletionIDs.remove(current.id) != nil else { return }
            self.pendingWorkItemCompletionTasks.removeValue(forKey: current.id)
            self.persistCompletion(current)
        }
    }

    // MARK: Recently used destinations

    /// Bumped when a destination is used, so views showing the recent row redraw.
    private(set) var recentDestinationsRevision = 0
    private var recentDestinationStore: RecentDestinations { RecentDestinations(defaults: TestIsolation.defaults) }

    func noteFiled(into folderName: String) {
        recentDestinationStore.record(folderName)
        recentDestinationsRevision += 1
    }

    /// The destinations shown up front — recently used first, then the usual top
    /// folders — and the rest, in `DestinationOrder`'s stable order.
    func splitDestinations(limit: Int) -> (leading: [WorkspaceFolder], rest: [WorkspaceFolder]) {
        _ = recentDestinationsRevision
        let all = DestinationOrder.destinations(folders)
        let leading = recentDestinationStore.leading(all, limit: limit, name: \.name)
        let shown = Set(leading.map(\.name))
        return (leading, all.filter { shown.contains($0.name) == false })
    }

    // MARK: Quick edits from Projects → Next Action

    /// Renames a work record in place (its title; the file keeps its name and identity).
    func renameWorkItem(_ item: WorkItem, to title: String) async throws {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return }
        var current = workItems.first { $0.id == item.id } ?? item
        guard current.title != trimmed else { return }
        current.title = trimmed
        try await saveWorkItem(current)
        statusMessage = "Renamed to “\(trimmed)”"
    }

    /// Moves a work record to the Trash (recoverable in Finder) and forgets any planning
    /// record of it that was never sent to Notion.
    func deleteWorkItem(_ item: WorkItem) {
        let current = item
        let service = workItemService
        let path = current.url.canonicalPath
        guard let relative = workspaceRelativePath(for: current.url) else { return }
        let workspace = workspace
        beginAppTrash(ofWorkItemAt: path)
        Task {
            do {
                let trash = TestIsolation.trashDirectory
                try await Task.detached(priority: .userInitiated) {
                    _ = try WorkspaceTrash.resolve(relative, workspace: workspace)
                    try service.trash(current, into: trash)
                }.value
                do { try ProjectGraphStore(database: database).recordLocalDeletion(path: path, pageID: current.importedNotionPageID) }
                catch { lastError = "The file is in the Trash, but its sync bookkeeping could not be updated: " + error.localizedDescription }
                if selectedItem?.url.canonicalPath == path { selectedItem = nil }
                endAppTrash(ofWorkItemAt: path, trashed: true)
                reloadProjectGraph()
                refreshOverview()
                statusMessage = "Moved “\(current.title)” to the Trash"
            } catch {
                endAppTrash(ofWorkItemAt: path, trashed: false)
                lastError = error.localizedDescription
            }
        }
    }

    func isPendingCompletion(_ item: WorkItem) -> Bool {
        pendingWorkItemCompletionIDs.contains(item.id)
    }

    private func persistCompletion(_ current: WorkItem) {
        let service = workItemService
        Task {
            do {
                let saved = try await Task.detached(priority: .userInitiated) { try service.complete(current) }.value
                adopt(saved)
                // Its Notion draft follows, as every other save does; Send stays explicit.
                queueGraphWork(saved)
                statusMessage = "Completed “\(saved.title)”"
            } catch { lastError = error.localizedDescription }
        }
    }

    private func reopenWorkItem(_ item: WorkItem) {
        var reopened = item
        reopened.status = .open
        reopened.completedAt = nil
        let service = workItemService
        Task {
            do {
                let saved = try await Task.detached(priority: .userInitiated) { try service.update(reopened) }.value
                adopt(saved)
                queueGraphWork(saved)
                statusMessage = "Reopened “\(saved.title)”"
            } catch { lastError = error.localizedDescription }
        }
    }

    /// Work records live below an area rather than in its shallow item list. Turn one
    /// into the same selection every other screen uses so its editor lives in the
    /// inspector, not in a disconnected modal destination.
    func inspect(workItem: WorkItem) {
        let path = workItem.url.canonicalPath
        Task {
            guard let item = await fs.makeItem(url: workItem.url),
                  workItem.url.canonicalPath == path else { return }
            selectedItem = item
            showInspector = true
        }
    }

    func moveWorkItem(_ item: WorkItem, to directory: URL) {
        let service = workItemService
        Task {
            do {
                let moved = try await Task.detached(priority: .userInitiated) { try service.move(item, to: directory) }.value
                adopt(moved, replacing: item.url)
                statusMessage = "Moved “\(item.title)” to \(directory.lastPathComponent)"
            } catch { lastError = error.localizedDescription }
        }
    }

    /// Once per launch: clears staging copies a crash left beside work items, and puts
    /// back a record whose creation was interrupted. Looks only where records live —
    /// their folders and the work queues — and `cleanUpStaging` touches only files it
    /// can prove are its own.
    private func cleanUpInterruptedSaves() async {
        let directories = Set(workItems.map { $0.url.deletingLastPathComponent().canonicalPath })
            .map { URL(fileURLWithPath: $0) }
            + folders.filter { $0.settings.layout == .workQueue }.map(\.url)
        let known = Set(workItems.map(\.id))
        let service = workItemService
        let result = await Task.detached(priority: .utility) {
            service.cleanUpStaging(in: directories, knownIDs: known)
        }.value
        // Copies to another drive that were cut off: in any area folder, since that is
        // where filing stages them. Only marked staging folders are considered.
        let areaFolders = folders.map(\.url)
        let filings = await Task.detached(priority: .utility) {
            SafeTransfer.cleanUpInterruptedFilings(in: areaFolders)
        }.value
        if filings.recovered.isEmpty == false {
            lastError = "A filing to another drive was interrupted and its original is gone, so the copy was kept: "
                + filings.recovered.map(\.lastPathComponent).joined(separator: ", ")
                + ". Check it is complete."
        }
        if result.recovered.isEmpty == false {
            let names = result.recovered.map { $0.deletingPathExtension().deletingPathExtension().lastPathComponent }
            statusMessage = "Recovered \(names.count == 1 ? "“\(names[0])”, a work item" : "\(names.count) work items") "
                + "whose creation was interrupted."
            await reconcileWorkItems(paths: result.recovered.map(\.path))
        }
    }

    /// Coalesce index writes after local saves and incremental filesystem updates.
    private func persistWorkItemPaths() {
        workItemIndexSaveTask?.cancel()
        let index = workItemPathIndex, root = workspace.root
        let items = workItems.filter { item in !pendingMissingWorkItems.contains(where: { $0.url == item.url }) }
        workItemIndexSaveTask = Task {
            do {
                try await Task.sleep(for: .milliseconds(300))
                try Task.checkCancellation()
                try await index.save(items, under: root)
            } catch { /* A disposable index cannot make a successful edit fail. */ }
        }
    }

    /// Puts one freshly written record into the list, in order.
    func adopt(_ item: WorkItem, replacing old: URL? = nil) {
        workItems = WorkItemService.merged(workItems, upserting: [item],
                                           removingPaths: Set([old?.canonicalPath].compactMap { $0 }))
        // A full walk already under way read the disk before this write; have it go
        // round once more rather than publish a list without this change.
        if workItemScanInFlight {
            workItemPendingPaths.insert(item.url.canonicalPath)
            if let old { workItemPendingPaths.insert(old.canonicalPath) }
        }
        persistWorkItemPaths()
        refreshOverview()
    }

    /// Applies file events to the work-item list, walking the Workspace only when a
    /// folder that held records moved or disappeared.
    private func reconcileWorkItems(paths: [String]) async {
        guard workItemScanInFlight == false else {
            workItemPendingPaths.formUnion(paths)
            return
        }
        let known = workItems
        let service = workItemService
        let outcome = await Task.detached(priority: .utility) {
            service.reconcile(changedPaths: paths, known: known)
        }.value
        switch outcome {
        case .rescan:
            await refreshWorkItems()
        case let .incremental(upserts, removed):
            let trashedHere = removed.filter { appTrashedWorkItemPaths.contains($0) }
            appTrashedWorkItemPaths.subtract(trashedHere)
            let disappeared = known.filter { removed.contains($0.url.canonicalPath) && trashedHere.contains($0.url.canonicalPath) == false }
            if disappeared.isEmpty == false {
                pendingMissingWorkItems = WorkItemService.indexed(pendingMissingWorkItems + disappeared)
            }
            let upsertedPaths = Set(upserts.map { $0.url.canonicalPath })
            let upsertedIDs = Set(upserts.map(\.id))
            pendingMissingWorkItems.removeAll { upsertedPaths.contains($0.url.canonicalPath) || upsertedIDs.contains($0.id) }
            if pendingMissingWorkItems.isEmpty { workItemSyncPrompt = nil }
            else { presentWorkItemSyncPrompt() }
            guard upserts.isEmpty == false || removed.isEmpty == false else { return }
            // Applied to the list as it is *now*, so an in-app save that landed while
            // this was reading is not undone. Missing records stay until the user
            // resolves the prompt; external deletion is never an implicit app action.
            // A record found again by ID at a new path was renamed or moved, not deleted:
            // its old path goes, or `indexed` could keep the stale copy over the new one.
            let movedPaths = known.filter { removed.contains($0.url.canonicalPath) && upsertedIDs.contains($0.id) }
                .map(\.url.canonicalPath)
            workItems = WorkItemService.merged(workItems, upserting: upserts, removingPaths: Set(trashedHere).union(movedPaths))
            persistWorkItemPaths()
            refreshOverview()
        }
    }

    /// Call before this app moves a work record to the Trash. On success the record
    /// leaves the list; on failure it is no longer treated as an expected removal.
    func beginAppTrash(ofWorkItemAt path: String) { appTrashedWorkItemPaths.insert(path) }

    func endAppTrash(ofWorkItemAt path: String, trashed: Bool) {
        guard trashed else { appTrashedWorkItemPaths.remove(path); return }
        for item in workItems where item.url.canonicalPath == path {
            pendingWorkItemCompletionTasks.removeValue(forKey: item.id)?.cancel()
            pendingWorkItemCompletionIDs.remove(item.id)
        }
        workItems = WorkItemService.merged(workItems, upserting: [], removingPaths: [path])
        pendingMissingWorkItems.removeAll { $0.url.canonicalPath == path }
        if pendingMissingWorkItems.isEmpty { workItemSyncPrompt = nil }
    }

    private func presentWorkItemSyncPrompt() {
        guard pendingMissingWorkItems.isEmpty == false,
              workItemSyncResolutionInFlight == false else { return }
        let sorted = pendingMissingWorkItems.sorted {
            $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
        workItemSyncPrompt = WorkItemSyncPrompt(
            count: sorted.count,
            sampleTitles: Array(sorted.prefix(3).map { "“\($0.title)”" })
        )
    }

    func dismissWorkItemSyncPrompt() {
        workItemSyncPrompt = nil
    }

    /// Restores every missing record at the path it had before the external deletion.
    /// A file that appeared in the meantime is never overwritten; it remains pending
    /// so the person can inspect the conflict and choose again.
    func restoreMissingWorkItems() {
        let candidates = pendingMissingWorkItems
        guard candidates.isEmpty == false else {
            workItemSyncPrompt = nil
            return
        }
        workItemSyncPrompt = nil
        workItemSyncResolutionInFlight = true
        let service = workItemService
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                var restored: [WorkItem] = []
                var failed: [WorkItem] = []
                for item in candidates {
                    do { restored.append(try service.restore(item)) }
                    catch { failed.append(item) }
                }
                return (restored, failed)
            }.value
            workItemSyncResolutionInFlight = false
            pendingMissingWorkItems = result.1
            workItems = WorkItemService.merged(workItems, upserting: result.0, removingPaths: [])
            if result.1.isEmpty {
                statusMessage = "Restored \(result.0.count) work item file\(result.0.count == 1 ? "" : "s")"
            } else {
                lastError = "Could not restore \(result.1.count) work item file\(result.1.count == 1 ? "" : "s"). A file may have appeared at the original path."
                presentWorkItemSyncPrompt()
            }
            refreshOverview()
            requestMobileCloudSync()
        }
    }

    /// Accepts the current Workspace contents as authoritative and removes only the
    /// missing records from the app's in-memory and mobile projections. The files are
    /// already gone; this action does not delete or modify anything on disk.
    func syncWorkItemsToFolder() {
        let candidates = pendingMissingWorkItems
        guard candidates.isEmpty == false else {
            workItemSyncPrompt = nil
            return
        }
        let paths = Set(candidates.map { $0.url.canonicalPath })
        pendingMissingWorkItems.removeAll()
        workItemSyncPrompt = nil
        workItems = WorkItemService.merged(workItems, upserting: [], removingPaths: paths)
        for path in paths { try? ProjectGraphStore(database: database).removeUnsent(localPath: path) }
        reloadProjectGraph()
        refreshOverview()
        requestMobileCloudSync()
        statusMessage = "Synced the app to the Workspace; removed \(candidates.count) missing work item\(candidates.count == 1 ? "" : "s")"
    }

    /// Items waiting on a decision, ready to process now.
    var pendingIngestCount: Int { ingestItems.filter(\.isDue).count }

    /// Everything still sitting in the inbox, skipped or not.
    ///
    /// The badge counts this rather than `pendingIngestCount`: skipping something means
    /// "not now", not "gone", and an inbox showing 0 with two items visible in the queue
    /// is simply lying.
    var unprocessedIngestCount: Int { ingestItems.count }

    var deferredIngestCount: Int { ingestItems.filter { $0.state == .deferred }.count }

    var currentIngestItem: IngestItem? {
        if let id = ingestManualSelectionID, let item = ingestItems.first(where: { $0.id == id }) { return item }
        return ingestItems.first(where: \.isDue)
    }

    // MARK: - Optional mobile CloudKit projection

    /// Coalesce local filesystem and tag changes. This check is intentionally before
    /// creating a task: a normal offline Mac launch makes no CloudKit object or call.
    func requestMobileCloudSync() {
        guard completedInitialRefresh, workspaceAvailable,
              TestIsolation.isActive == false,
              TestIsolation.defaults.bool(forKey: MobileCloudPublisher.enabledDefaultsKey)
        else { return }
        mobileCloudSyncRequested = true
        guard mobileCloudSyncInFlight == false else { return }
        mobileCloudSyncTask?.cancel()
        mobileCloudSyncTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard let self, Task.isCancelled == false else { return }
            await self.syncMobileCloud()
        }
    }

    #if DEBUG
    /// Waits for the first publish to settle, prints the container's contents, and quits.
    private func dumpCloudState(sync: Bool) async {
        if sync { await syncMobileCloud() }
        var report = "BW CLOUD DUMP\n"
        var projectionTags = tagsByPath
        for item in workItems where projectionTags[item.url.canonicalPath] == nil {
            projectionTags[item.url.canonicalPath] = tagStore.tags(for: item.url)
        }
        let candidates = MobileWorkspaceProjection.candidates(
            from: MobileWorkspaceLocalSnapshot(itemsByArea: itemsByArea, workItems: workItems,
                                               tags: allTags, tagsByPath: projectionTags),
            workspace: workspace)
        report += "LOCAL workItems=\(workItems.count) tags=\(allTags.count) "
            + "areas=\(itemsByArea.map { "\($0.key):\($0.value.count)" }.sorted().joined(separator: ","))\n"
        report += "TAGSBYPATH " + tagsByPath.filter { $0.value.isEmpty == false }
            .map { "\($0.key)=[\($0.value.map(\.name).joined(separator: ","))]" }.sorted().joined(separator: " ") + "\n"
        report += "CANDIDATES " + Dictionary(grouping: candidates, by: \.scope)
            .map { "\($0.key)=\($0.value.count)" }.sorted().joined(separator: " ") + "\n"
        if let lastError { report += "LAST ERROR: \(lastError)\n" }
        do {
            report += try await mobileCloudPublisher.diagnostics(allowWhenDisabled: sync == false).description + "\n"
        } catch {
            report += "unavailable: \(error.localizedDescription)\n"
        }
        report += "BW CLOUD DUMP END\n"
        FileHandle.standardError.write(Data(report.utf8))
        NSApp.terminate(nil)
    }
    #endif

    private func syncMobileCloud() async {
        guard mobileCloudSyncInFlight == false else { return }
        mobileCloudSyncInFlight = true
        defer {
            let shouldReschedule = mobileCloudSyncRequested
            mobileCloudSyncRequested = false
            mobileCloudSyncInFlight = false
            if shouldReschedule {
                requestMobileCloudSync()
            }
        }
        mobileCloudSyncRequested = false

        do {
            let inbound = try await mobileCloudPublisher.pendingIntents().sorted {
                let left = $0.intent?.createdAt ?? .distantPast, right = $1.intent?.createdAt ?? .distantPast
                return left == right ? $0.recordName < $1.recordName : left < right
            }
            var changedLocalState = false
            var expiredMobileIntents = 0
            for record in inbound {
                guard let intent = record.intent else {
                    try await mobileCloudPublisher.acknowledge(recordName: record.recordName)
                    continue
                }
                if intent.kind == .planningEdit, let edit = intent.planningEdit {
                    if try await mobileCloudPublisher.isHandled(intent.id) {
                        continue
                    }
                    do {
                        try await applyMobilePlanning(edit)
                    } catch WidgetCommandError.waitingForIdeaService {
                        if MobileIntentLifetime.hasExpired(intent) { try await mobileCloudPublisher.finishPlanning(intent, error: "The idea folder moved, but the service has not acknowledged its metadata. Update/start the service and resume this promotion on Mac.") }
                        continue
                    } catch WidgetCommandError.waitingForCapture {
                        if MobileIntentLifetime.hasExpired(intent) { try await mobileCloudPublisher.finishPlanning(intent, error: "The capture did not arrive within two weeks. Nothing was filed.") }
                        continue
                    } catch {
                        try await mobileCloudPublisher.finishPlanning(intent, error: error.localizedDescription)
                        continue
                    }
                    try await mobileCloudPublisher.markHandled(intent)
                    changedLocalState = true
                    // Publish before returning the receipt so a phone never discards
                    // its draft while still fetching the pre-save projection.
                    continue
                }
                if try await mobileCloudPublisher.isHandled(intent.id) {
                    try await mobileCloudPublisher.acknowledge(recordName: record.recordName)
                    continue
                }
                guard await applyMobileIntent(intent) else {
                    // Not applicable yet. Usually iCloud delivering a classification
                    // before the capture it names, which a later poll resolves — but an
                    // intent whose capture was deleted on the phone or filed by hand on
                    // the Mac never becomes applicable, and retrying it forever leaves
                    // the command channel unable to drain.
                    if MobileIntentLifetime.hasExpired(intent) {
                        expiredMobileIntents += 1
                        try await mobileCloudPublisher.markHandled(intent)
                        try await mobileCloudPublisher.acknowledge(recordName: record.recordName)
                    }
                    continue
                }
                // Store the acknowledgement before removing the remote record. Both
                // tag assignments and classification are idempotent, so an app crash
                // between these two calls merely retries a safe operation.
                try await mobileCloudPublisher.markHandled(intent)
                try await mobileCloudPublisher.acknowledge(recordName: record.recordName)
                changedLocalState = true
            }
            if changedLocalState { await refreshAll() }
            if expiredMobileIntents > 0 {
                statusMessage = "Gave up on \(expiredMobileIntents) phone change\(expiredMobileIntents == 1 ? "" : "s") "
                    + "older than two weeks that no longer match anything here."
            }
            // Work records may live below their area roots and never be rendered in
            // a tag inspector. Fill those cache misses from the one private tag store
            // before projecting rather than publishing an accidentally tag-less task.
            var projectionTags = tagsByPath
            for item in workItems where projectionTags[item.url.canonicalPath] == nil {
                projectionTags[item.url.canonicalPath] = tagStore.tags(for: item.url)
            }
            let previewCache = await loadedMobileProjectPreviews()
            let setupProjectIDs = projectStore.setupProjectIDs()
            let scoring = scoringPreferences()
            let projectDetailsByPath = Dictionary(uniqueKeysWithValues: projects().compactMap { item -> (String, MobileProjectDetails)? in
                guard let record = projectRecord(for: item), let path = workspaceRelativePath(for: item.url) else { return nil }
                let description = projectStore.description(for: record.id)
                let metadata = projectStore.metadata(for: record.id)
                let references = projectStore.portfolioDetails(for: record.id)
                return (path, MobileProjectDetails(
                    path: path, oneLiner: description.oneLiner, summary: description.summary,
                    domain: metadata.domain, status: metadata.status, phase: metadata.phase, githubURL: references.githubURL,
                    websiteURL: references.websiteURL, resourceCount: references.resourceReferences.count,
                    collectionCount: references.collectionReferences.count, mediaCount: references.mediaReferences.count,
                    taskCount: references.taskReferences.count, featureCount: references.featureReferences.count,
                    milestoneCount: references.milestoneReferences.count, workLogCount: references.workLogReferences.count,
                    assessment: projectAudit(for: item).map(MobileProjectAssessment.init), projectID: record.id, serviceID: record.watcherID,
                    manualScore: score(for: item, preferences: scoringPreferences())?.projectScore,
                    ratingCoverage: score(for: item, preferences: scoringPreferences())?.coverage,
                    lastWorked: overviewFocusItems.first { $0.path == path }?.lastWorked,
                    ratings: ratingsByProject[record.id] ?? [:], scoringPreferences: scoring,
                    needsSetup: setupProjectIDs.contains(record.id), previews: previewCache[record.id]
                ))
            })
            let snapshot = MobileWorkspaceLocalSnapshot(
                itemsByArea: itemsByArea, workItems: workItems, tags: allTags,
                tagsByPath: projectionTags, projectDetailsByPath: projectDetailsByPath,
                ideaDetailsByPath: await mobileIdeaDetails(previews: previewCache)
            )
            // Projecting the whole workspace is pure work over a value snapshot; keep it
            // off the main thread so a periodic sync never stalls clicks.
            let workspace = workspace
            var candidates = await Task.detached(priority: .utility) {
                MobileWorkspaceProjection.candidates(from: snapshot, workspace: workspace)
            }.value
            candidates.append(.entry(MobileWorkspaceEntry(path: OverviewDigest.path, parentPath: nil, name: "Overview focus", isDirectory: false, revision: 0, overview: overviewDigest())))
            try await mobileCloudPublisher.publish(candidates)
            for record in inbound {
                if let intent = record.intent, intent.kind == .planningEdit,
                   try await mobileCloudPublisher.isHandled(intent.id) {
                    try await mobileCloudPublisher.finishPlanning(intent, workModifiedAt: widgetCommands?.value("applied-work:" + intent.id.uuidString, as: Date.self))
                }
            }
        } catch let error as MobileCloudError {
            // Offline/no-account mode is expected. It is deliberately quiet so a
            // filesystem-first workspace does not look broken without iCloud.
            if case .rejected = error { lastError = error.localizedDescription }
            if case .configuration = error { lastError = error.localizedDescription }
        } catch {
            // The publisher's conversion normally maps CloudKit errors above, but
            // never make a transport failure invalidate or alter local state.
            lastError = "Mobile sync couldn't finish: \(error.localizedDescription)"
        }
    }

    /// Applies only operations that can be completed against the current authoritative
    /// filesystem. A stale tag revision is deliberately rebased as a set operation;
    /// rejecting it would lose an offline user's independent add/remove change.
    /// Returns false when a capture needs user context or has not arrived through
    /// iCloud yet, leaving the intent queued for a later refresh.
    func applyMobileIntent(_ intent: MobileWorkspaceIntent) async -> Bool {
        let knownTagIDs = Set(allTags.map(\.id))
        let resolved: (Set<String>) -> Set<String> = { ids in
            Set(ids.map { self.mobileTagAliases[$0] ?? $0 }).intersection(knownTagIDs)
        }
        switch intent.kind {
        case .planningEdit: return false // Applied asynchronously through the planning editor.
        case .tagCreation:
            guard let tag = intent.createdTag else { return true }
            // A phone that had not yet seen the Mac's "Raspberry Pi" may have made
            // "RaspberryPi". The store answers the existing tag; later intents in this
            // session that name the phone's id are pointed at it.
            if let stored = tagStore.createTag(tag), stored.id != tag.id { mobileTagAliases[tag.id] = stored.id }
            reloadTags()
            return true

        case .tagAssignment:
            guard let path = intent.targetPath.flatMap(MobileWorkspacePath.normalizedRelative) else { return true }
            let url = workspace.root.appendingPathComponent(path)
            guard NoiseFilter.isForeignMetadata(name: url.lastPathComponent) == false,
                  FileManager.default.fileExists(atPath: url.path)
            else { return true }
            let area = workspace.areaName(containing: url)
            for tagID in resolved(intent.addTagIDs) {
                tagStore.assign(tagID: tagID, to: url, area: area)
            }
            for tagID in resolved(intent.removeTagIDs) {
                tagStore.unassign(tagID: tagID, from: url)
            }
            tagsByPath[url.canonicalPath] = tagStore.tags(for: url, area: area)
            reloadTags()
            return true

        case .captureClassification:
            guard let name = intent.captureName,
                  name.isEmpty == false,
                  name == URL(fileURLWithPath: name).lastPathComponent,
                  name != ".", name != ".."
            else { return true }
            guard let capture = ingestItems.first(where: { $0.url.lastPathComponent == name }) else {
                // iCloud may deliver the intent before its matching file. Do not
                // acknowledge it until a future inbox poll can see the capture.
                return false
            }
            if intent.captureExpectedChildren.isEmpty == false,
               MobileCaptureBundleReceipt.hasAllChildren(intent.captureExpectedChildren, at: capture.url) == false {
                // The folder's receipt and intent name every child that was present at
                // Save. iCloud may expose the directory before its photo/file upload;
                // leave this command queued until moving it cannot split the bundle.
                return false
            }
            let tagIDs = resolved(intent.tagIDs)
            if let requestedPath = intent.captureDestinationPath {
                // The phone only offers the top-level folders published by this Mac.
                // Check that again at the trust boundary: an intent is a network input,
                // not permission to move an Inbox file anywhere under the filesystem.
                guard let normalizedPath = MobileWorkspacePath.normalizedRelative(requestedPath),
                      normalizedPath.split(separator: "/").count == 1
                else { return true }
                guard let destination = folders.first(where: { $0.name == normalizedPath }) else {
                    statusMessage = "“\(capture.title)” is waiting in the inbox because “\(normalizedPath)” is no longer a Workspace folder."
                    return false
                }
                if isWorkQueue(destination) {
                    // A queue lists work items: the capture becomes one.
                    return (try? await promoteCapture(capture, toQueue: destination,
                                                      links: intent.captureLinks ?? .none, tagIDs: tagIDs)) != nil
                }
                for tagID in tagIDs { tagStore.assign(tagID: tagID, to: capture.url, area: nil) }
                do {
                    _ = try ingest.classify(capture, intoDirectory: destination.url, renamingTo: nil)
                    return true
                } catch {
                    // A conflict or unavailable provider can be corrected without
                    // discarding the phone's explicitly chosen destination.
                    return false
                }
            }
            guard let kind = intent.captureKind else {
                // Tags only: the phone tagged a capture that stays in the inbox. They
                // follow it when it is filed.
                for tagID in tagIDs { tagStore.assign(tagID: tagID, to: capture.url, area: nil) }
                if tagIDs.isEmpty == false { reloadTags() }
                return true
            }
            if kind == .idea {
                guard folders.contains(where: { $0.name == WorkspaceArea.ideas.directoryName }) else {
                    statusMessage = "“\(capture.title)” arrived from your phone as an idea, but the Ideas area is not available yet."
                    return false
                }
                return (try? fileAsIdea(capture, tagIDs: tagIDs)) != nil
            }
            // Whichever folder is set up as this kind's work queue, so the route follows
            // area settings and Finder renames rather than a fixed name.
            guard let workItemKind = kind.workItemKind else { return false }
            guard let queue = WorkQueueRouting.folder(for: workItemKind, among: folders) else {
                statusMessage = "“\(capture.title)” arrived from your phone as a \(kind.displayName.lowercased()), "
                    + "but no area is set up as a \(kind.displayName.lowercased()) queue. It is waiting in the inbox."
                // Unlike a missing project decision, this one can be fixed here —
                // by setting up a queue — so keep the request for the next pass.
                return false
            }
            do {
                // A work item, not a loose note the queue cannot list. A project named on
                // the phone that is gone here fails the save; it is then filed without
                // links and listed under Needs Attention rather than retried forever.
                let links = intent.captureLinks ?? .none
                do {
                    _ = try await promoteCapture(capture, toQueue: queue, links: links, tagIDs: tagIDs)
                } catch is WorkItemProjectLinkError {
                    _ = try await promoteCapture(capture, toQueue: queue, tagIDs: tagIDs)
                }
                return true
            } catch {
                // Missing destinations and filename conflicts can be corrected in
                // Finder; preserving the intent avoids silently discarding a capture.
                return false
            }
        }
    }

    /// Files a capture as an idea: a new folder of its own in Ideas, named after it,
    /// with the capture inside and the tags on the folder. Phone intents and the Mac's
    /// own Capture Idea action both come here.
    @discardableResult
    func fileAsIdea(_ capture: IngestItem, tagIDs: Set<String>) throws -> URL {
        guard let ideas = folders.first(where: { $0.name == WorkspaceArea.ideas.directoryName }) else {
            throw IngestService.IngestError.moveFailed("The Ideas area is not available.")
        }
        let base = CaptureNaming.safeFilename(capture.title)
        var folder = ideas.url.appendingPathComponent(base, isDirectory: true)
        var number = 2
        while FileManager.default.fileExists(atPath: folder.path) {
            folder = ideas.url.appendingPathComponent("\(base) \(number)", isDirectory: true)
            number += 1
        }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            _ = try ingest.classify(capture, intoDirectory: folder, renamingTo: nil)
            for tagID in tagIDs { tagStore.assign(tagID: tagID, to: folder, area: ideas.name) }
            reloadTags()
            return folder
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
    }

    // MARK: - Tags

    func reloadMobilePlanningTags(at url: URL) {
        tagsByPath[url.canonicalPath] = tagStore.tags(for: url)
        reloadTags()
    }

    /// Opens the work editor sheet for `item`.
    func edit(workItem item: WorkItem) {
        editingWorkItem = workItems.first { $0.id == item.id } ?? item
    }

    /// Tags on a work file, read fresh.
    func tags(forWorkAt url: URL) -> [Tag] { tagStore.tags(for: url) }

    /// Makes a work file's tags exactly `tags`.
    func setTags(_ tags: [Tag], forWorkAt url: URL) {
        let current = Set(tagStore.tags(for: url).map(\.id)), wanted = Set(tags.map(\.id))
        guard current != wanted else { return }
        let area = workspace.areaName(containing: url)
        for id in wanted.subtracting(current) { tagStore.assign(tagID: id, to: url, area: area) }
        for id in current.subtracting(wanted) { tagStore.unassign(tagID: id, from: url) }
        tagsByPath[url.canonicalPath] = tagStore.tags(for: url)
        reloadTags()
        requestMobileCloudSync()
    }

    func reloadTags() {
        allTags = tagStore.allTags()
        tagUsage = tagStore.tagUsageCounts()
    }

    private func reloadTagAssignments(for items: [WorkspaceItem]) {
        let paths = items.map { $0.url.canonicalPath }
        let fresh = tagStore.tagsByObjectKey(forPaths: paths)
        for path in paths { tagsByPath[path] = fresh[path] ?? [] }
    }

    func tags(for item: WorkspaceItem) -> [Tag] {
        if let cached = tagsByPath[item.url.canonicalPath] { return cached }
        let fetched = tagStore.tags(for: item.url)
        tagsByPath[item.url.canonicalPath] = fetched
        return fetched
    }

    func assign(tag: Tag, to item: WorkspaceItem) {
        let area = workspace.areaName(containing: item.url)
        tagStore.assign(tagID: tag.id, to: item.url, area: area)
        tagsByPath[item.url.canonicalPath] = tagStore.tags(for: item.url)
        reloadTags()
        requestMobileCloudSync()
        if !applyingGraphToLocal && projectRecord(for: item) != nil { queueProjectGraphEdits(for: item, fields: ["tags"]) }
    }

    func unassign(tag: Tag, from item: WorkspaceItem) {
        tagStore.unassign(tagID: tag.id, from: item.url)
        tagsByPath[item.url.canonicalPath] = tagStore.tags(for: item.url)
        reloadTags()
        requestMobileCloudSync()
        if !applyingGraphToLocal && projectRecord(for: item) != nil { queueProjectGraphEdits(for: item, fields: ["tags"]) }
    }

    @discardableResult
    func createTag(named name: String) -> Tag? {
        let tag = tagStore.createTag(named: name)
        reloadTags()
        requestMobileCloudSync()
        return tag
    }

    func deleteTag(_ tag: Tag) {
        tagStore.deleteTag(id: tag.id)
        tagsByPath.removeAll()
        reloadTags()
        requestMobileCloudSync()
        Task { await refreshAll() }
    }

    func renameTag(_ tag: Tag, to newName: String) {
        tagStore.renameTag(id: tag.id, to: newName)
        tagsByPath.removeAll()
        reloadTags()
        requestMobileCloudSync()
        Task { await refreshAll() }
    }

    // MARK: - Ideas editing

    /// Ideas intentionally allow explicit note and attachment edits. The service
    /// validates every target remains below `Ideas`; this is not a general escape
    /// hatch from the workspace's browse-only policy.
    func createIdeaNote(named name: String, in directory: URL?) async throws -> WorkspaceItem {
        let root = workspace.url(for: .ideas)
        let url = try await Task.detached(priority: .userInitiated) {
            try IdeaFileService(ideasRoot: root).createNote(named: name, in: directory)
        }.value
        await refresh(area: .ideas)
        guard let item = await fs.makeItem(url: url) else { throw CocoaError(.fileNoSuchFile) }
        selectedItem = item
        statusMessage = "Created “\(item.name)” in Ideas"
        return item
    }

    func createIdeaFolder(named name: String, in directory: URL?) async throws -> WorkspaceItem {
        let root = workspace.url(for: .ideas)
        let url = try await Task.detached(priority: .userInitiated) {
            try IdeaFileService(ideasRoot: root).createFolder(named: name, in: directory)
        }.value
        await refresh(area: .ideas)
        guard let item = await fs.makeItem(url: url) else { throw CocoaError(.fileNoSuchFile) }
        selectedItem = item
        statusMessage = "Created “\(item.name)” in Ideas"
        return item
    }

    func importIdeaItems(_ urls: [URL], into directory: URL?) async throws -> [WorkspaceItem] {
        let root = workspace.url(for: .ideas)
        let imported = try await Task.detached(priority: .userInitiated) {
            try IdeaFileService(ideasRoot: root).importItems(urls, into: directory)
        }.value
        await refresh(area: .ideas)
        var items: [WorkspaceItem] = []
        for url in imported {
            if let item = await fs.makeItem(url: url) { items.append(item) }
        }
        if let first = items.first { selectedItem = first }
        statusMessage = "Added \(items.count) item\(items.count == 1 ? "" : "s") to Ideas"
        return items
    }

    func saveIdeaText(_ text: String, to url: URL, expecting snapshot: TextDocumentService.Snapshot) async throws -> TextDocumentService.Snapshot {
        let root = workspace.url(for: .ideas)
        let path = url.canonicalPath
        guard path.hasPrefix(root.canonicalPath + "/") else { throw IdeaFileService.Error.outsideIdeas }
        let service = textDocumentService
        let saved = try await Task.detached(priority: .userInitiated) {
            try service.save(text, at: url, expecting: snapshot)
        }.value
        await refresh(area: .ideas)
        statusMessage = "Saved “\(url.lastPathComponent)”"
        return saved
    }

    /// Everything anywhere in the workspace carrying this tag — the payoff of having
    /// one shared repository rather than nine.
    func objects(withTag tag: Tag) -> [TaggedObject] {
        tagStore.objects(withTagID: tag.id)
    }

    /// Drops records for files carrying this tag that no longer exist. Records only —
    /// the filesystem is never touched.
    func forgetMissing(tag: Tag) {
        let removed = tagStore.forgetMissingObjects(withTagID: tag.id)
        if removed > 0 { statusMessage = "Forgot \(removed) missing item\(removed == 1 ? "" : "s")" }
        tagsByPath.removeAll()
        reloadTags()
    }

    // MARK: - Ingest actions

    @discardableResult
    func captureText(_ text: String, source: IngestSource = .quickCapture) -> Bool {
        do {
            let item = try ingest.captureText(text, source: source)
            statusMessage = "Captured “\(item.title)”"
            Task { await refreshIngest() }
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    func importURLs(_ urls: [URL], source: IngestSource = .desktopDrop) {
        var imported = 0
        for url in urls {
            do {
                _ = try ingest.importItem(at: url, source: source)
                imported += 1
            } catch {
                lastError = error.localizedDescription
            }
        }
        if imported > 0 { statusMessage = "Added \(imported) item\(imported == 1 ? "" : "s") to the inbox" }
        Task { await refreshIngest() }
    }

    func importData(_ data: Data, name: String, ext: String) {
        do {
            _ = try ingest.importData(data, preferredName: name, extension: ext)
            statusMessage = "Added “\(name)” to the inbox"
            Task { await refreshIngest() }
        } catch {
            lastError = error.localizedDescription
        }
    }

    func setIngestTitle(_ title: String, for item: IngestItem) {
        ingest.setTitle(title, for: item)
        if let index = ingestItems.firstIndex(where: { $0.id == item.id }) {
            ingestItems[index].title = title
        }
    }

    /// Selecting a cloud-backed capture starts its download immediately. There is no
    /// separate manual download step in the inbox; the next inbox poll replaces the
    /// placeholder snapshot once the provider has the content locally.
    func startDownloadingIngestItem(_ item: IngestItem) {
        guard item.item.isContentLocal == false else { return }
        ingest.startDownloading(item)
        statusMessage = "Downloading “\(item.title)” from iCloud…"
    }

    func scheduleIngestItem(_ item: IngestItem, priority: Int, until: Date?) {
        do { try ingest.schedule(item, priority: priority, until: until) }
        catch { lastError = error.localizedDescription; return }
        Task {
            await refreshIngest()
            ingestManualSelectionID = nil
            ingestCursor = ingestItems.firstIndex(where: \.isDue) ?? 0
        }
    }

    func deferIngestItem(_ item: IngestItem) {
        scheduleIngestItem(item, priority: item.priority, until: Date().addingTimeInterval(86_400))
    }

    func undeferIngestItem(_ item: IngestItem) {
        ingest.setState(.pending, for: item)
        Task { await refreshIngest() }
    }

    /// The inbox is intentionally disposable. This action cannot delete an organized
    /// file because `IngestService.delete` accepts only the selected inbox URL.
    func deleteIngestItem(_ item: IngestItem) {
        let ingest = ingest
        Task {
            do {
                try await Task.detached(priority: .userInitiated) { try ingest.trash(item, into: TestIsolation.trashDirectory) }.value
                statusMessage = "Moved “\(item.title)” from the inbox to the Trash"
                await refreshIngest()
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    /// The explicit, confirmed filesystem mutation.
    /// Captures being filed right now. A move can take a while (a large folder, a
    /// slow disk), and pressing Return again during it used to start a second move of
    /// a file that was already on its way.
    private(set) var classifyingIDs: Set<String> = []

    func classify(_ item: IngestItem, into folder: WorkspaceFolder, renamingTo newName: String?,
                  links: WorkItemLinks = .none) {
        guard classifyingIDs.contains(item.id) == false else { return }
        classifyingIDs.insert(item.id)
        let ingest = ingest
        Task {
            defer { classifyingIDs.remove(item.id) }
            if isWorkQueue(folder) {
                // A queue lists work items: the capture becomes one, keeping its tags.
                do {
                    let tagIDs = Set(tagStore.tags(for: item.url).map(\.id))
                    let saved = try await promoteCapture(item, toQueue: folder, links: links, tagIDs: tagIDs)
                    statusMessage = "Made “\(saved.title)” a \(saved.kind.displayName.lowercased()) in \(folder.name)"
                    await refreshIngest()
                    await refresh(areaNamed: folder.name)
                } catch { lastError = error.localizedDescription }
                return
            }
            do {
                // Off the main thread: it used to run inline, so a big move froze the UI.
                let filed = try await Task.detached(priority: .userInitiated) {
                    try ingest.file(item, intoDirectory: folder.url, renamingTo: newName)
                }.value
                let destination = filed.destination
                noteFiled(into: folder.name)
                statusMessage = filed.originalKept
                    ? "Filed in \(folder.name)/\(destination.lastPathComponent), but the original could not be "
                        + "removed from the inbox. Nothing was lost; delete the inbox copy when convenient."
                    : "Moved to \(folder.name)/\(destination.lastPathComponent)"
                await refreshIngest()
                await refresh(areaNamed: folder.name)
                if destination.lastPathComponent.hasSuffix(WorkItemService.fileSuffix) {
                    await reconcileWorkItems(paths: [destination.path])
                }
                reloadTags()
            } catch IngestService.IngestError.notDownloaded(let name) {
                statusMessage = "“\(name)” is downloading from iCloud. File it once it has arrived."
                await refreshIngest()
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    private var recentlyFiledLoaded = false

    func reloadRecentlyFiledIngest() async {
        recentlyFiledLoaded = true
        var filed: [RecentlyFiledIngest] = []
        for record in ingest.recentlyFiled() {
            guard let item = await fs.makeItem(url: record.url) else { continue }
            filed.append(RecentlyFiledIngest(record: record, item: item))
        }
        recentlyFiledIngest = filed
    }

    /// Opens a filed capture where it now lives, so tags, text and attachments are
    /// edited on the real item in its area rather than on an inbox copy.
    func openFiledIngest(_ filed: RecentlyFiledIngest) {
        guard FileManager.default.fileExists(atPath: filed.item.url.path) else {
            statusMessage = "“\(filed.record.title)” is no longer in \(filed.record.destinationName)."
            Task { await reloadRecentlyFiledIngest() }
            return
        }
        // Follows the item, not the remembered name, in case the folder was renamed.
        guard let folder = folders.first(where: {
            filed.item.url.canonicalPath.hasPrefix($0.url.canonicalPath + "/")
        }) else {
            revealInFinder(filed.item.url)
            return
        }
        navigate(to: .folder(folder.name), selecting: filed.item)
    }

    func selectIngestItem(_ index: Int) {
        guard ingestItems.indices.contains(index) else { return }
        ingestCursor = index; ingestManualSelectionID = ingestItems[index].id
    }

    func advanceIngestCursor() {
        let indices = ingestItems.indices.filter { ingestItems[$0].isDue }
        let current = currentIngestItem.flatMap { item in ingestItems.firstIndex { $0.id == item.id } } ?? -1
        if let next = indices.first(where: { $0 > current }) ?? indices.last { selectIngestItem(next) }
        else { ingestManualSelectionID = nil }
    }

    func retreatIngestCursor() {
        let indices = ingestItems.indices.filter { ingestItems[$0].isDue }
        let current = currentIngestItem.flatMap { item in ingestItems.firstIndex { $0.id == item.id } } ?? 0
        if let previous = indices.last(where: { $0 < current }) ?? indices.first { selectIngestItem(previous) }
        else { ingestManualSelectionID = nil }
    }

    // MARK: - Finder handoff

    func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }
}

/// What survives a quit: where you were and how the window was laid out. Not what
/// you were in the middle of — a selected file, a search, a drilled folder, the ingest
/// cursor — which a restart should start fresh. Per-area choices (layout, sort, date
/// basis) already live in Areas.json.
enum StateRestoration {
    private static var defaults: UserDefaults { TestIsolation.defaults }
    private static let selectionKey = "restore.selection"
    private static let identityKey = "restore.folderIdentity"
    private static let inspectorKey = "restore.showInspector"

    static var selection: SidebarSelection? {
        guard let raw = defaults.string(forKey: selectionKey) else { return nil }
        switch raw {
        case "overview": return .overview
        // The old global Work screen was redundant with project queues. A saved
        // selection from an older release opens Overview instead.
        case "work": return .overview
        case "ingest": return .ingest
        default:
            if raw.hasPrefix("folder:") { return .folder(String(raw.dropFirst(7))) }
            if raw.hasPrefix("tag:") { return .tag(String(raw.dropFirst(4))) }
            return nil
        }
    }

    static var folderIdentity: String? { defaults.string(forKey: identityKey) }

    static func save(_ selection: SidebarSelection?, folder identity: String?) {
        let raw: String? = switch selection {
        case .overview?: "overview"
        case .work?: "work"
        case .ingest?: "ingest"
        case .folder(let name)?: "folder:" + name
        case .tag(let id)?: "tag:" + id
        case nil: nil
        }
        defaults.set(raw, forKey: selectionKey)
        defaults.set(identity, forKey: identityKey)
    }

    static var showInspector: Bool {
        get { defaults.object(forKey: inspectorKey) as? Bool ?? true }
        set { defaults.set(newValue, forKey: inspectorKey) }
    }
}

/// Discovered projects indexed by their workspace-relative path, built once per pass so
/// resolving many work items does not rescan and re-normalize every project each time.
/// Canonical paths touch the filesystem, so that index is only built for a legacy
/// absolute reference that actually needs it.
private struct ProjectPathLookup {
    let projects: [WorkspaceItem]
    let byRelativePath: [String: WorkspaceItem]

    init(projects: [WorkspaceItem], relativePath: (URL) -> String?) {
        self.projects = projects
        var index: [String: WorkspaceItem] = [:]
        for project in projects {
            guard let path = relativePath(project.url), index[path] == nil else { continue }
            index[path] = project
        }
        byRelativePath = index
    }

    func project(atCanonicalPath path: String) -> WorkspaceItem? {
        projects.first { $0.url.canonicalPath == path }
    }
}
