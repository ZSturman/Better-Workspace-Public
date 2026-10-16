import Foundation
import BetterWorkspaceCore

/// The background service, as the app sees it: what it is observing right now, the idea
/// metadata it keeps, the ideas it is resurfacing and the work log it drafts — plus
/// installing and starting it. See `BackgroundServiceClient` for who owns which data.
extension AppModel {

    /// How often the live session and suggestions are re-read while the app is open.
    /// The service decides when a session starts or a suggestion is due; this only
    /// controls how soon the app shows it.
    static let servicePollInterval: Duration = .seconds(60)

    /// True until the first read of the service has finished, when it may be read at all.
    var isAwaitingBackgroundService: Bool { mayReadBackgroundService && backgroundServiceReadOnce == false }

    /// An isolated test run reads a service only when its launch names one
    /// (`-backgroundServiceURL http://127.0.0.1:<port>`), so a test never reaches the real one
    /// by default.
    var mayReadBackgroundService: Bool {
        TestIsolation.isActive == false
            || TestIsolation.launchArgument(MeasurementService.defaultsBaseURLKey) != nil
            || TestIsolation.launchArgument(MeasurementService.legacyDefaultsBaseURLKey) != nil
            || TestIsolation.launchArgument(Self.serviceFixtureArgument) != nil
    }

    /// Isolated runs read measurements only from named fixtures or a named service.
    /// Without this, every UI test's app read the real service's
    /// scoring, sessions and project ids -- results that depended on this Mac's data, and
    /// ~0.7 s of the real service's CPU per test.
    var mayReadMeasurements: Bool {
        TestIsolation.isActive == false
            || TestIsolation.launchArgument(MeasurementService.defaultsBaseURLKey) != nil
            || TestIsolation.launchArgument(MeasurementService.legacyDefaultsBaseURLKey) != nil
            || TestIsolation.launchArgument(Self.serviceFixtureArgument) != nil
    }

    /// `-bwServiceFixture <directory>`: an isolated UI test's canned service responses.
    static let serviceFixtureArgument = "bwServiceFixture"

    func startServicePolling() {
        servicePoll?.cancel()
        #if DEBUG
        MenuBarPanelInspection.presentIfRequested(model: self)
        #endif
        #if DEBUG
        if TestIsolation.isActive, let directory = TestIsolation.launchArgument(Self.serviceFixtureArgument) {
            BackgroundServiceClient.fixtureDirectory = URL(fileURLWithPath: directory)
        }
        #endif
        guard mayReadBackgroundService else { return }
        servicePoll = Task { @MainActor [weak self] in
            while Task.isCancelled == false {
                try? await Task.sleep(for: Self.servicePollInterval)
                guard let self, Task.isCancelled == false else { return }
                await self.refreshLiveActivity()
            }
        }
    }

    /// Everything the service offers. Each read fails on its own, so this does not wait
    /// on measurements proving the service is up.
    @MainActor
    func refreshBackgroundService() async {
        guard mayReadBackgroundService else { return }
        if backgroundServiceReadOnce == false { await holdFirstReadIfSimulating() }
        let client = BackgroundServiceClient.shared
        await refreshLiveActivity()
        if let ideas = await client.ideas() {
            let records = Dictionary(ideas.map { ($0.canonicalPath, $0) }, uniquingKeysWith: { first, _ in first })
            if records != serviceIdeasByPath { serviceIdeasByPath = records; refreshOverview(); requestMobileCloudSync() }
        }
        await refreshIdeaPlanning()
        if let logs = await client.workLogs(), logs != workLogs { workLogs = logs; refreshOverview() }
        if let coverage = await client.workLogCoverage() { workLogCoverage = coverage }
        backgroundServiceReadOnce = true
        await queueServiceProjectGraph()
        await synchronizePotentialIdeaProjects()
    }

    /// The cheap, frequent part: who is being worked on, and what is being resurfaced.
    @MainActor
    func refreshLiveActivity() async {
        let client = BackgroundServiceClient.shared
        if let live = await client.liveSession() { liveSession = live }
        if let notifications = await client.notifications() {
            resurfacedSuggestions = Array(notifications.filter(\.isOpenSuggestion).prefix(20))
        }
    }

    /// The idea metadata the service keeps for a folder in Ideas, if any.
    func ideaRecord(for url: URL) -> IdeaRecord? {
        serviceIdeasByPath[url.canonicalPath]
    }

    /// The suggestion's idea folder, when the service's idea is one this app can see.
    func ideaURL(for suggestion: ServiceNotification) -> URL? {
        guard let id = suggestion.entityID,
              let idea = serviceIdeasByPath.values.first(where: { $0.id == id }) else { return nil }
        return URL(fileURLWithPath: idea.path)
    }

    /// Every value in use for one idea field, so the editor offers what is already there.
    func ideaValues(_ field: KeyPath<IdeaRecord, String?>) -> [String?] {
        serviceIdeasByPath.values.map { $0[keyPath: field] }
    }

    /// Changes an idea's private metadata through its owning service.
    @MainActor
    @discardableResult
    func updateIdea(_ idea: IdeaRecord, _ changes: IdeaChanges) async -> Bool {
        guard changes.isEmpty == false else { return true }
        if !TestIsolation.isActive {
            do { try await claimServiceProjectGraphWriter() } catch { lastError = error.localizedDescription; return false }
        }
        guard let updated = await BackgroundServiceClient.shared.updateIdea(id: idea.id, changes) else {
            lastError = "The background service did not save that change to “\(idea.title)”. Is it running?"
            return false
        }
        serviceIdeasByPath[updated.canonicalPath] = updated
        await queueServiceProjectGraph()
        refreshOverview(); requestMobileCloudSync()
        return true
    }

    @MainActor
    func act(on suggestion: ServiceNotification, _ action: ServiceNotification.Action) async {
        guard await BackgroundServiceClient.shared.act(on: suggestion.id, action) else {
            lastError = "The background service did not record that. Is it running?"
            return
        }
        resurfacedSuggestions.removeAll { $0.id == suggestion.id }
    }

    // MARK: - The launch agent

    @MainActor
    func refreshServiceAgentStatus() async {
        serviceAgentStatus = await Task.detached(priority: .utility) {
            BackgroundServiceAgent().status()
        }.value
    }

    /// Installs, upgrades or restarts the service; on a machine that still runs the old
    /// Workspace Watcher agents, this is also what retires them.
    @MainActor
    func installBackgroundService() async {
        // Launch agents are per-user state outside any sandbox; a test must never change them.
        guard TestIsolation.isActive == false else {
            lastError = "The background service is not installed from an isolated test run."
            return
        }
        serviceBusy = true
        defer { serviceBusy = false }
        let failure: String? = await Task.detached(priority: .userInitiated) {
            do { try BackgroundServiceAgent().install(); return nil } catch { return error.localizedDescription }
        }.value
        if let failure { lastError = failure }
        // The service takes a few seconds to open its database and port.
        for _ in 0..<15 {
            if await BackgroundServiceClient.shared.health()?.isRunning == true { break }
            try? await Task.sleep(for: .seconds(2))
        }
        await refreshServiceAgentStatus()
        if failure == nil { statusMessage = "Background service is running under Better Workspace" }
        await refreshMeasurements()
        await refreshBackgroundService()
    }
}
