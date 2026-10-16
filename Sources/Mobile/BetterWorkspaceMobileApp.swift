import SwiftUI
import BetterWorkspaceCore

@main
struct BetterWorkspaceMobileApp: App {
    @State private var model: MobileWorkspaceModel?
    /// Shared with the App Intents, which can run before any scene exists.
    @State private var captureModel: MobileModel?
    /// Overview is the mobile home, even when the Mac was last showing a folder.
    @State private var selectedTab: MobileWorkspaceTab = .overview
    @State private var captureRequest = 0
    @AppStorage("workspaceExperience") private var experience = "connected"
    @Environment(\.scenePhase) private var scenePhase

    init() {
        if !NotebookReleaseAcceptance.isActive {
            _model = State(initialValue: MobileWorkspaceModel())
            _captureModel = State(initialValue: MobileModel.shared)
            MobileWorkspaceTipConfiguration.configure()
        }
    }

    var body: some Scene {
        WindowGroup {
            if let session = NotebookReleaseAcceptance.sessionID {
                NotebookReleaseAcceptanceView(sessionID: session)
            } else if NotebookReleaseAcceptance.previewSessionID != nil {
                PersonalWorkspaceView(sample: NotebookReleaseAcceptance.isSamplePreview, isolated: true)
            } else if NotebookReleaseAcceptance.isBackendTest {
                PersonalWorkspaceView(sample: true)
            } else if let model, let captureModel {
                MobileExperienceRoot(experience: $experience, selectedTab: $selectedTab, captureRequest: captureRequest)
                    .environment(model)
                    .environment(captureModel)
                    .onChange(of: scenePhase) { _, phase in
                        if phase == .active { Task { await model.refresh() } }
                        if phase == .background { model.flushBeforeSuspending() }
                    }
                    .onOpenURL { url in
                        open(url)
                    }
                    .task {
                        if let value = UserDefaults.standard.string(forKey: "BWInitialURL"), let url = URL(string: value) {
                            open(url)
                        }
                        // New Capture / Control Center / Action Button may have launched us.
                        if let request = CaptureLaunchRouter.shared.take() { startCapture(asIdea: request.asIdea) }
                        #if DEBUG
                        if let spec = IntentTestHarness.requestedSpec {
                            selectedTab = .capture
                            captureModel.statusMessage = await IntentTestHarness.run(spec)
                        }
                        #endif
                    }
                    .onReceive(NotificationCenter.default.publisher(for: CaptureLaunchRouter.notification)) { _ in
                        if let request = CaptureLaunchRouter.shared.take() { startCapture(asIdea: request.asIdea) }
                    }
            }
        }
    }

    private func open(_ url: URL) {
        guard url.scheme == "betterworkspace-mobile" else { return }
        if let route = WidgetRoute(url: url) {
            experience = "connected"
            model?.widgetNavigation = route
            return
        }
        if ["work", "ideas", "projects"].contains(url.host ?? "") { experience = "connected" }
        switch url.host {
        case "work": selectedTab = .work
        case "ideas": selectedTab = .ideas
        case "projects": selectedTab = .projects
        case "capture":
            // `capture?kind=idea` (the New Idea widget) files the next save as an idea.
            let kind = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "kind" }?.value
            startCapture(asIdea: kind == CaptureClassificationKind.idea.rawValue)
        default: selectedTab = .overview
        }
    }

    /// Straight to a focused capture field: the fewest taps between a thought and Save.
    private func startCapture(asIdea: Bool) {
        // A cold-launch request can arrive before the root installs onChange.
        // Select its owning experience here, before changing the destination.
        experience = "connected"
        selectedTab = .capture
        if asIdea { captureModel?.selectedCaptureKind = .idea }
        captureRequest += 1
    }
}
