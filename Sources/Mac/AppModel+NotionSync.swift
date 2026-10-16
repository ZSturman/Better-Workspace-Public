import Foundation
import BetterWorkspaceCore

/// Where Notion sync stands, in the few states a toolbar can show.
enum NotionSyncState: Equatable {
    case notConfigured
    case syncing
    case upToDate
    /// Changes that can move on their own are waiting (manual mode, or between passes).
    case waiting(Int)
    /// Something needs a person.
    case attention(Int)
    /// Notion could not be reached or read; local work is unaffected.
    case unavailable(String)
}

extension AppModel {
    static let notionAutoSyncKey = "notionAutoSync"

    /// Off unless the person turns it on. Turning it off stops transfers; nothing pending
    /// is lost, and it all stays in the Sync Center.
    var notionAutoSync: Bool {
        get { _ = syncSettingRevision; return TestIsolation.defaults.bool(forKey: Self.notionAutoSyncKey) }
        set {
            TestIsolation.defaults.set(newValue, forKey: Self.notionAutoSyncKey)
            syncSettingRevision += 1
            syncFeedbackIsError = false
            syncFeedback = newValue ? "Automatic sync enabled. Checking shortly; merges and conflicts still need review." : "Manual sync enabled. Pending changes are kept."
            if newValue { requestAutoSync(after: 1) } else { autoSyncDebounce?.cancel(); autoSyncOperation?.cancel() }
        }
    }

    /// The plan an automatic pass would follow now, from what is already known.
    var syncPlan: ProjectAutoSyncPlanner.Plan {
        _ = graphRevision
        return ProjectAutoSyncPlanner.plan(syncTriage, deferred: syncDeferred, failures: syncFailures)
    }

    var notionSyncState: NotionSyncState {
        _ = graphRevision; _ = syncSettingRevision
        guard !graphSources.isEmpty else { return .notConfigured }
        if graphBusy || autoSyncRunning { return .syncing }
        let sections = syncSections
        if let needs = sections[.needsYou], !needs.isEmpty { return .attention(needs.count) }
        if !hasNotionToken { return .unavailable("Add a Notion token in Settings") }
        if let autoSyncError { return .unavailable(autoSyncError) }
        if let failure = graphReport?.failures.first { return .unavailable("\(failure.key): \(failure.value)") }
        let waiting = sections[.ready]?.count ?? 0
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
        guard let token = SecretStore.read() else { showSyncFailure("Add a Notion token in Settings first."); return }
        let seeds = NotionGraphConfiguration.seeds()
        guard !seeds.isEmpty else { showSyncFailure("Configure a Notion database in Settings first."); return }
        do {
            let store = try ProjectGraphStore(database: database)
            let before = try await Task.detached(priority: .utility) { try store.records() }.value
            let disabled = NotionGraphConfiguration.disabled()
            let operation = Task { try await ProjectAutoSync(store: store, client: NotionClient(token: token))
                .run(seeds: seeds, disabled: disabled, progress: { [weak self] update in await self?.updateSyncProgress(update) }) }
            autoSyncOperation = operation
            let report = try await operation.value
            await refreshProjectGraph()
            graphReport = try store.read("report", as: ProjectSyncReport.self)
            try bindGraphProjects(); bindExistingGraphWork()
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

    func finishSyncFeedback(_ report: ProjectAutoSync.Report) {
        syncFeedbackIsError = !report.failed.isEmpty || !report.readFailures.isEmpty
        syncFeedback = report.completionSummary
        let mergeFields = syncTriage.reduce(0) { $0 + ProjectSyncTriage.mergeChoices($1).count }
        if mergeFields > 0 { syncFeedback! += " \(mergeFields) multi-value fields can be merged after review." }
        if let failure = report.failed.values.sorted().first { syncFeedback! += " \(failure)" }
    }

    // MARK: Acting from the Sync Center

    /// Applies items with per-field choices: settle locally, then receive or send each.
    /// Anything that fails stays where it was, with its reason.
    @discardableResult
    func applySync(_ items: [ProjectSyncTriage.Item], choices: [String: [String: ProjectSyncTriage.Side]] = [:], mergesOnly: Bool = false) async -> ProjectAutoSync.Report? {
        guard !graphBusy else { syncFeedback = "A sync is already running."; return nil }
        graphBusy = true; syncFeedback = nil; syncFeedbackIsError = false
        syncActivity = mergesOnly ? "Preparing reviewed merges…" : "Preparing reviewed changes…"
        defer { graphBusy = false; syncActivity = nil; reloadProjectGraph() }
        guard let token = SecretStore.read() else { showSyncFailure("Add a Notion token in Settings first."); return nil }
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
            finishSyncFeedback(report)
            let done = changed.count, failed = report.failed.count
            statusMessage = failed == 0 ? "Synced \(done) \(done == 1 ? "record" : "records")" : "Synced \(done); \(failed) could not be synced"
            return report
        } catch {
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
