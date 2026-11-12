import SwiftUI
import BetterWorkspaceCore

/// A single navigation shell owns both the portable workspace and connected views.
struct MobileExperienceRoot: View {
    @Environment(MobileWorkspaceModel.self) private var model
    @Binding var selectedTab: MobileWorkspaceTab
    let captureRequest: Int
    @State private var session: WorkspaceSession?
    @State private var loadError: String?
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        MobileWorkspaceRootView(selectedTab: $selectedTab, captureRequest: captureRequest,
                                includesWorkspace: !isLegacyFixture, session: session,
                                workspaceLoadError: loadError, retryWorkspace: { Task { await load() } })
            .task { @MainActor in
                guard !isLegacyFixture else { return }
                await load()
                while !Task.isCancelled {
                    if scenePhase == .active { await session?.synchronizeIfDue() }
                    do { try await Task.sleep(for: .seconds(25)) } catch { return }
                }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { Task { await session?.synchronize() } }
                // An edit made just before leaving the app is sent now, not on next launch.
                if phase == .background, let session { finishSyncingInBackground(session) }
            }
    }
    private func finishSyncingInBackground(_ session: WorkspaceSession) {
        var identifier = UIBackgroundTaskIdentifier.invalid
        identifier = UIApplication.shared.beginBackgroundTask(withName: "Workspace synchronization") {
            UIApplication.shared.endBackgroundTask(identifier); identifier = .invalid
        }
        Task { @MainActor in
            await session.synchronize()
            if identifier != .invalid { UIApplication.shared.endBackgroundTask(identifier); identifier = .invalid }
        }
    }

    private var isLegacyFixture: Bool {
        if TestIsolation.launchArgument("BWTestUnifiedNavigation") == "YES" { return false }
        return model.isSample || ["BWTestMobilePlanning", "BWTestCaptureInboxID"].contains { TestIsolation.launchArgument($0) != nil }
    }
    @MainActor private func load() async {
        guard !isLegacyFixture else { return }
        do { session = try await WorkspaceSession.openLive(); loadError = nil }
        catch { loadError = error.localizedDescription }
    }
}

/// Physical UI acceptance uses exactly the shared product editor, with its own
/// durable directory and no legacy/cloud/service initialization.
struct UnifiedWorkspaceAcceptanceRoot: View {
    @State private var session: WorkspaceSession?
    @State private var error: String?
    @State private var settings = false
    var body: some View {
        Group {
            if let session { UnifiedWorkspaceHome(session: session, showSettings: { settings = true }).sheet(isPresented: $settings) { MobileSettingsView(session: session) } }
            else if let error { Text(error).accessibilityIdentifier("unified.loadError") }
            else { ProgressView() }
        }.task {
            do {
                let session = try await WorkspaceSession.openLive()
                try await UnifiedWorkspaceAcceptanceSeed.prepare(session)
                if let spec = TestIsolation.launchArgument("BWUnifiedIntent"), session.records.isEmpty {
                    if spec == "task" {
                        var intent = AddWorkspaceTaskIntent(); intent.title = "Intent-created standalone task"; intent.notes = "Saved by the actual App Intent"
                        _ = try await intent.perform()
                    } else if spec == "idea" {
                        var intent = AddWorkspaceIdeaIntent(); intent.title = "Intent-created standalone idea"; intent.notes = "Saved by the actual App Intent"
                        _ = try await intent.perform()
                    }
                    try await session.reload(); try session.finishWelcome()
                }
                self.session = session
            }
            catch { self.error = error.localizedDescription }
        }
    }
}
