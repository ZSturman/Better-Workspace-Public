import Foundation
import BetterWorkspaceCore

/// Where Notion sync stands, in the few states a toolbar can show.
enum NotionSyncState: Equatable {
    case notConfigured
    case syncing
    case upToDate
    /// Changes that can move on their own are waiting (manual mode, or between passes).
    case waiting(Int)
    /// Records are retrying after a failure; nothing needs a person yet.
    case recovering(Int)
    /// Something needs a person.
    case attention(Int)
    /// Notion could not be reached or read; local work is unaffected.
    case unavailable(String)
}

extension AppModel {
    static let notionAutoSyncKey = "notionAutoSync"

    /// Configured installations adopt the owner's outgoing-only policy once. A later
    /// explicit pause stops transfers and retains pending values in Sync Center.
    var notionAutoSync: Bool {
        get { _ = syncSettingRevision; return TestIsolation.defaults.bool(forKey: Self.notionAutoSyncKey) }
        set {
            TestIsolation.defaults.set(newValue, forKey: Self.notionAutoSyncKey)
            syncSettingRevision += 1
            syncFeedbackIsError = false
            syncFeedback = newValue ? "Local updates will send automatically. \(syncPolicy.receiveNotionChanges ? "Routine Notion changes are received automatically." : "Notion changes wait until you receive them.")" : "Manual sync enabled. Pending changes are kept."
            if newValue { requestAutoSync(after: 1) } else { autoSyncDebounce?.cancel(); autoSyncOperation?.cancel() }
        }
    }

    func adoptFinderNotionPolicyIfConfigured() {
        guard !TestIsolation.isActive, hasNotionToken, !NotionGraphConfiguration.seeds().isEmpty else { return }
        if !TestIsolation.defaults.bool(forKey: "notionWorkspaceAuthorityPolicyV2") {
            do {
                let store = try ProjectGraphStore(database: database)
                var policy = try store.read(ProjectSyncTriage.Policy.key, as: ProjectSyncTriage.Policy.self) ?? .init()
                policy.preferWorkspaceChanges = true
                policy.receiveNotionChanges = true
                try store.write(ProjectSyncTriage.Policy.key, policy)
                syncPolicy = policy
                TestIsolation.defaults.set(true, forKey: "notionWorkspaceAuthorityPolicyV2")
                notionAutoSync = true
            } catch { showSyncFailure(error.localizedDescription) }
        }
        guard !TestIsolation.defaults.bool(forKey: "notionLocalAuthorityPolicyV1") else { return }
        TestIsolation.defaults.set(true, forKey: "notionLocalAuthorityPolicyV1")
        notionAutoSync = true
    }

    /// Keeps the Workspace's Backups area (snapshots) out of automatic Notion updates.
    /// Written into the stored policy so automatic passes and the Sync Center agree.
    func holdSnapshotFolders() {
        // From the store, not `syncPolicy`: at launch the snapshot has not loaded yet, and
        // the person's other choices must not be replaced with defaults.
        let held = [workspace.url(for: .backups).canonicalPath + "/"]
        do {
            let store = try ProjectGraphStore(database: database)
            var policy = try store.read(ProjectSyncTriage.Policy.key, as: ProjectSyncTriage.Policy.self) ?? .init()
            guard policy.heldPaths != held else { return }
            policy.heldPaths = held
            try store.write(ProjectSyncTriage.Policy.key, policy)
            syncPolicy = policy
        } catch { lastError = error.localizedDescription; return }
        reloadProjectGraph()
    }

    /// The plan an automatic pass would follow now, from what is already known.
    /// Recomputed when the graph or a setting changes; each reload bumps `graphRevision`,
    /// so a retry's backoff ending is noticed at the next pass's reload.
    var syncPlan: ProjectAutoSyncPlanner.Plan {
        let revision = graphRevision, settings = syncSettingRevision
        if let cached = cachedSyncPlan, cached.revision == revision, cached.settings == settings { return cached.plan }
        let plan = ProjectAutoSyncPlanner.plan(syncTriage, deferred: syncDeferred, failures: syncFailures, policy: syncPolicy)
        cachedSyncPlan = (revision, settings, plan)
        return plan
    }

    /// Saves the person's sync policy where automatic passes read it, then re-sorts.
    func setSyncPolicy(_ policy: ProjectSyncTriage.Policy) {
        guard policy != syncPolicy else { return }
        do { try ProjectGraphStore(database: database).write(ProjectSyncTriage.Policy.key, policy) }
        catch { showSyncFailure("The sync setting could not be saved: \(error.localizedDescription)"); return }
        syncPolicy = policy
        syncFeedbackIsError = false
        syncFeedback = policy.receiveNotionChanges ? "Routine Notion changes will be received automatically. File and service changes retain review."
            : "Notion changes will wait until you receive them."
        reloadProjectGraph()
        requestAutoSync(after: 1)
    }

    /// One line for the Sync Center: who controls what, under the current policy.
    var syncPolicySummary: String {
        _ = graphRevision
        let incoming = syncPolicy.receiveNotionChanges
            ? (syncPolicy.preferWorkspaceChanges
                ? "Routine Notion metadata is received automatically; file and service changes wait for you."
                : "Routine Notion changes are received automatically; conflicts and anything that would change a Workspace file wait for you.")
            : "Notion changes wait until you receive them."
        let precedence = syncPolicy.preferWorkspaceChanges ? " Newer known edits win; otherwise Better Workspace wins." : ""
        return "Finder controls local files. Linked local updates send in the background. \(incoming)\(precedence)"
    }

    /// Diagnosis from recent automatic passes; empty when nothing looks wrong.
    var syncHealthFindings: [ProjectSyncHealth.Finding] {
        _ = graphRevision; _ = syncSettingRevision
        return syncHealth?.findings(automatic: notionAutoSync) ?? []
    }

    var notionSyncState: NotionSyncState {
        _ = graphRevision; _ = syncSettingRevision
        guard !graphSources.isEmpty else { return .notConfigured }
        if graphBusy || autoSyncRunning { return .syncing }
        // Only records a person must decide are counted in orange. Routine changes,
        // retries and records kept by the background service are not warnings.
        let plan = syncPlan
        if !plan.attention.isEmpty { return .attention(plan.attention.count) }
        if !hasNotionToken { return .unavailable("Add a Notion token in Settings") }
        if let autoSyncError { return .unavailable(autoSyncError) }
        if let failure = graphReport?.failures.first { return .unavailable("\(failure.key): \(failure.value)") }
        if !plan.waiting.isEmpty { return .recovering(plan.waiting.count) }
        let waiting = plan.push.count + plan.pull.count + plan.settle.count + plan.receivable.count
        return waiting > 0 ? .waiting(waiting) : .upToDate
    }

    // MARK: Automatic passes

    /// Asks for a pass shortly, coalescing bursts of edits. Does nothing in manual mode.
    func requestAutoSync(after seconds: Double = 15) {
        guard notionAutoSync, !TestIsolation.isActive || TestIsolation.launchArgument("bwAllowAutoSync") != nil else { return }
        autoSyncDebounce?.cancel()
        autoSyncDebounce = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            await self?.runAutoSyncPass()
        }
    }

    func runAutoSyncPass() async {
        guard notionAutoSync else { return }
        guard !graphBusy else { requestAutoSync(after: 2); return }
        graphBusy = true; autoSyncRunning = true
        syncActivity = "Checking Notion for changes…"; syncFeedback = nil; syncFeedbackIsError = false
        defer { graphBusy = false; autoSyncRunning = false; autoSyncOperation = nil; syncActivity = nil; reloadProjectGraph() }
        guard let token = await Task.detached(priority: .utility, operation: { SecretStore.read(interactive: false) }).value else { showSyncFailure("Add a Notion token in Settings first."); return }
        let seeds = NotionGraphConfiguration.seeds()
        guard !seeds.isEmpty else { showSyncFailure("Configure a Notion database in Settings first."); return }
        do {
            let store = try ProjectGraphStore(database: database)
            let before = try await Task.detached(priority: .utility) { try store.records() }.value
            let disabled = NotionGraphConfiguration.disabled()
            let operation = Task { try await ProjectAutoSync(store: store, client: NotionClient(token: token))
                .run(seeds: seeds, disabled: disabled, workspace: workspace, progress: { [weak self] update in await self?.updateSyncProgress(update) }) }
            autoSyncOperation = operation
            let report = try await operation.value
            await refreshProjectGraph()
            graphReport = try store.read("report", as: ProjectSyncReport.self)
            try await bindGraphProjects(); await bindExistingGraphWork()
            await refreshProjectGraph()
            let changed = Set(report.received + report.sent)
            if !changed.isEmpty {
                syncActivity = "Updating this workspace…"
                try await applyLocalEffects(of: changed, previous: before, createFiles: false)
            }
            finishSyncFeedback(report)
            autoSyncError = report.readFailures.isEmpty ? nil : "Notion could not be read"
        } catch is CancellationError {
            syncFeedback = "Sync stopped. Completed transfers are kept; pending changes remain."
            // Disabling stops the next transfer; a request already acknowledged stays journaled.
        } catch NotionProjectSync.SyncError.busy {
            syncFeedback = "Another Notion operation is running. Automatic sync will try again."
            requestAutoSync(after: 5)
            // Another operation holds the lease; the next pass picks up where it left off.
        } catch {
            autoSyncError = error.localizedDescription
            showSyncFailure(error.localizedDescription)
        }
    }

    func updateSyncProgress(_ progress: ProjectAutoSync.Progress) { syncActivity = progress.message }

    func showSyncFailure(_ message: String) {
        lastError = message; syncFeedbackIsError = true
        syncFeedback = "Sync could not finish: \(message)"
    }

    var lastSuccessfulNotionSync: Date? {
        _ = syncSettingRevision
        return TestIsolation.defaults.object(forKey: "notionLastSuccessfulSync") as? Date
    }

    func finishSyncFeedback(_ report: ProjectAutoSync.Report) {
        if report.failed.isEmpty && report.readFailures.isEmpty, let date = report.finishedAt {
            TestIsolation.defaults.set(date, forKey: "notionLastSuccessfulSync")
            syncSettingRevision += 1
        }
        syncFeedbackIsError = !report.failed.isEmpty || !report.readFailures.isEmpty
        syncFeedback = report.completionSummary
        let mergeFields = syncTriage.reduce(0) { $0 + ProjectSyncTriage.mergeChoices($1).count }
        if mergeFields > 0 { syncFeedback! += " \(mergeFields) multi-value fields can be merged after review." }
        if let failure = report.failed.values.sorted().first { syncFeedback! += " \(failure)" }
    }

    // MARK: Acting from the Sync Center

    func beginReviewedSync(_ ids: Set<String>) async {
        syncApplyingIDs.formUnion(ids)
        #if DEBUG
        // Give isolated UI coverage a deterministic in-flight state without allowing
        // credentials or live Notion traffic into a fixture.
        if TestIsolation.isActive, let raw = TestIsolation.launchArgument("bwReviewedSyncDelay"),
           let delay = Double(raw), delay.isFinite, delay > 0 {
            try? await Task.sleep(for: .seconds(min(delay, 15)))
        }
        #endif
    }

    /// Applies items with per-field choices: settle locally, then receive or send each.
    /// Anything that fails stays where it was, with its reason.
    @discardableResult
    func applySync(_ items: [ProjectSyncTriage.Item], choices: [String: [String: ProjectSyncTriage.Side]] = [:], mergesOnly: Bool = false) async -> ProjectAutoSync.Report? {
        guard !graphBusy else { syncFeedback = "A sync is already running."; return nil }
        graphBusy = true; syncFeedback = nil; syncFeedbackIsError = false
        syncActivity = mergesOnly ? "Preparing reviewed merges…" : "Preparing reviewed changes…"
        let applying = Set(items.map(\.id))
        defer { syncApplyingIDs.subtract(applying); graphBusy = false; syncActivity = nil }
        await beginReviewedSync(applying)
        guard let token = await Task.detached(priority: .userInitiated, operation: { SecretStore.read() }).value else {
            await refreshProjectGraph()
            showSyncFailure("Add a Notion token in Settings first."); return nil
        }
        do {
            let store = try ProjectGraphStore(database: database)
            // Sending ideas or work logs is the service handoff; ask the service first.
            let serviceSends = items.filter { item in
                item.record.serviceRecordID != nil && (mergesOnly
                    ? !ProjectSyncTriage.mergeChoices(item).isEmpty
                    : item.sendsToNotion || choices[item.id]?.values.contains(.merge) == true || choices[item.id]?.values.contains(.local) == true)
            }
            if !serviceSends.isEmpty {
                try await claimServiceProjectGraphWriter()
            }
            let before = try await Task.detached(priority: .utility) { try store.records() }.value
            let report = try await ProjectAutoSync(store: store, client: NotionClient(token: token)).apply(items, choices: choices, mergesOnly: mergesOnly, serviceAcknowledgements: Set(serviceSends.map(\.id)), progress: { [weak self] update in await self?.updateSyncProgress(update) })
            await refreshProjectGraph()
            let changed = Set(report.received + report.sent)
            if !changed.isEmpty {
                syncActivity = "Updating this workspace…"
                try await applyLocalEffects(of: changed, previous: before, createFiles: true)
            }
            await refreshProjectGraph()
            finishSyncFeedback(report)
            let done = changed.count, failed = report.failed.count
            statusMessage = failed == 0 ? "Synced \(done) \(done == 1 ? "record" : "records")" : "Synced \(done); \(failed) could not be synced"
            return report
        } catch {
            await refreshProjectGraph()
            showSyncFailure(error.localizedDescription)
            return nil
        }
    }

    func deferSync(_ items: [ProjectSyncTriage.Item]) {
        do { let store = try ProjectGraphStore(database: database); for item in items { try store.deferDifference(item) } }
        catch { lastError = error.localizedDescription }
        reloadProjectGraph()
    }

    func undeferSync(_ items: [ProjectSyncTriage.Item]) {
        do { let store = try ProjectGraphStore(database: database); for item in items { try store.undeferDifference(item.id) } }
        catch { lastError = error.localizedDescription }
        reloadProjectGraph()
    }

    /// Forgets drafts that never reached Notion. Records that exist in Notion are never touched.
    func discardSyncDrafts(_ items: [ProjectSyncTriage.Item]) {
        var discarded = 0
        do { let store = try ProjectGraphStore(database: database); for item in items where try store.discardDraft(item.id) { discarded += 1 } }
        catch { lastError = error.localizedDescription }
        reloadProjectGraph()
        statusMessage = "Discarded \(discarded) \(discarded == 1 ? "draft" : "drafts")"
    }

    /// Withdraws a request to archive a page in Notion.
    func cancelArchiveRequest(_ item: ProjectSyncTriage.Item) {
        guard var record = graphRecords.first(where: { $0.id == item.id }) else { return }
        record.archiveRequested = false
        saveGraphRecord(record)
    }

    /// Project names for the Sync Center's grouping and filters.
    func syncProjectName(_ pageID: String) -> String? {
        graphProjectsByPageID[pageID]?.title ?? graphRecords.first { $0.kind == .projects && ProjectGraph.normalizedID($0.id) == pageID }?.title
    }
}
