import SwiftUI
import UIKit
import BetterWorkspaceCore
#if DEBUG
import CryptoKit
#endif

@main
struct BetterWorkspaceMobileApp: App {
    @State private var model: MobileWorkspaceModel?
    /// Shared with the App Intents, which can run before any scene exists.
    @State private var captureModel: MobileModel?
    /// Overview is the mobile home, even when the Mac was last showing a folder.
    @State private var selectedTab: MobileWorkspaceTab = .overview
    @State private var captureRequest = 0
    @Environment(\.scenePhase) private var scenePhase

    init() {
        UnifiedWorkspaceTipSetup.configureFixture()
        if !NotebookReleaseAcceptance.isActive && (WorkspaceSession.fixtureID == nil || TestIsolation.launchArgument("BWTestUnifiedNavigation") == "YES") {
            _model = State(initialValue: MobileWorkspaceModel())
            _captureModel = State(initialValue: MobileModel.shared)
            MobileWorkspaceTipConfiguration.configure()
        }
    }

    #if DEBUG
    private static let qaImage = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAwAAAAJCAIAAACJ2loDAAAAEklEQVR4nGNgmD2bMBpVRJQiANPpgslXqttUAAAAAElFTkSuQmCC")!
    private static let qaFile = Data("Better Workspace idea attachment integrity fixture.\n".utf8)

    private static func isQAStamp(_ stamp: String) -> Bool {
        stamp.range(of: "^[A-Za-z0-9-]{1,48}$", options: .regularExpression) != nil
    }

    /// Installed-device fallback when XCTest cannot enable UI automation. Requests
    /// downloads only for explicit disposable QA names through the normal model.
    @MainActor
    private static func verifyCloudIdeas(_ stamps: [String], model: MobileWorkspaceModel) async {
        guard !stamps.isEmpty, stamps.count <= 3, stamps.allSatisfy(isQAStamp) else { return }
        var remaining = Set(stamps)
        for _ in 0..<12 where !remaining.isEmpty {
            await model.refresh()
            for stamp in remaining {
                let title = "BW QA idea " + stamp
                let matches = model.snapshot.entries.filter { $0.parentPath == "Ideas" && $0.name.hasPrefix(title) }
                guard matches.count == 1, let entry = matches.first, entry.name == title else { continue }
                guard let state = model.download(for: entry.path) else {
                    model.setDownload(entry, enabled: true)
                    continue
                }
                guard let copy = state.copy else { continue }
                let hashes = copy.files.filter { $0.hasPrefix("Attachments/") }.sorted().compactMap { path -> String? in
                    guard let url = model.downloadCache.fileURL(copy: copy, path: path),
                          let data = try? Data(contentsOf: url) else { return nil }
                    return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                }
                guard !hashes.isEmpty else { continue }
                print("BW QA READ \(stamp) count=1 hashes=\(hashes.joined(separator: ","))")
                remaining.remove(stamp)
            }
            fflush(stdout)
            if !remaining.isEmpty { try? await Task.sleep(for: .seconds(10)) }
        }
        if !remaining.isEmpty { print("BW QA READ INCOMPLETE \(remaining.sorted().joined(separator: ","))"); fflush(stdout) }
    }
    #endif

    var body: some Scene {
        WindowGroup {
            if WorkspaceSession.fixtureID != nil && TestIsolation.launchArgument("BWTestUnifiedNavigation") != "YES" {
                UnifiedWorkspaceAcceptanceRoot()
            } else if let session = NotebookReleaseAcceptance.sessionID {
                NotebookReleaseAcceptanceView(sessionID: session)
            } else if NotebookReleaseAcceptance.previewSessionID != nil {
                PersonalWorkspaceView(sample: NotebookReleaseAcceptance.isSamplePreview, isolated: true)
            } else if NotebookReleaseAcceptance.isBackendTest {
                PersonalWorkspaceView(sample: true)
            } else if let model, let captureModel {
                MobileExperienceRoot(selectedTab: $selectedTab, captureRequest: captureRequest)
                    .connectedApps()
                    .onChange(of: model.snapshot.fetchedAt, initial: true) { _, date in
                        guard !model.isSample else { return }
                        ConnectedApps.shared.publishSummary("\(model.snapshot.workItems.count) work items available", generatedAt: date)
                    }
                    .environment(model)
                    .environment(captureModel)
                    .onChange(of: scenePhase) { _, phase in
                        if phase == .active {
                            Task { await model.refresh() }
                            Task { await captureModel.flushClassificationOutbox() }
                        }
                        if phase == .background { model.flushBeforeSuspending() }
                    }
                    .task(id: scenePhase) {
                        guard scenePhase == .active else { return }
                        while !Task.isCancelled {
                            try? await Task.sleep(for: .seconds(30))
                            guard !Task.isCancelled else { return }
                            async let refresh: Void = model.refresh()
                            if !captureModel.pendingIdeas.isEmpty { await captureModel.flushClassificationOutbox() }
                            await refresh
                        }
                    }
                    .onOpenURL { url in
                        if url.host != "connected-apps" { open(url) }
                    }
                    .task {
                        if let value = UserDefaults.standard.string(forKey: "BWInitialURL"), let url = URL(string: value) {
                            open(url)
                        }
                        // New Capture / Control Center / Action Button may have launched us.
                        if let request = CaptureLaunchRouter.shared.take() { startCapture(asIdea: request.asIdea) }
                        #if DEBUG
                        // Device capture tests: a background test runner may not write the
                        // clipboard, so the foreground app puts a generated image there and
                        // the test pastes it through the normal Paste media path.
                        if TestIsolation.launchArgument("BWTestPasteboardImage") == "YES" {
                            UIPasteboard.general.image = UIGraphicsImageRenderer(size: CGSize(width: 120, height: 90)).image { context in
                                UIColor.systemTeal.setFill(); context.fill(CGRect(x: 0, y: 0, width: 120, height: 90))
                            }
                        }
                        if TestIsolation.launchArgument("BWTestIdeaAttachments") == "YES" {
                            let png = Self.qaImage
                            UIPasteboard.general.setData(png, forPasteboardType: "public.png")
                            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                            let file = directory.appendingPathComponent("Integrity fixture.txt")
                            do {
                                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
                                defer { try? FileManager.default.removeItem(at: directory) }
                                try Self.qaFile.write(to: file)
                                captureModel.stageFiles([file])
                            } catch { captureModel.errorMessage = error.localizedDescription }
                        }
                        if let stamp = TestIsolation.launchArgument("BWTestCloudIdeaSave"), Self.isQAStamp(stamp) {
                            do {
                                let result = try await captureModel.captureFromIntent(
                                    text: "BW QA idea " + stamp, title: nil, link: nil,
                                    files: [(Self.qaImage, "Fixture.png"), (Self.qaFile, "Integrity fixture.txt")],
                                    destination: nil, kind: .idea, tags: [])
                                print("BW QA SAVE \(stamp) \(result)")
                            } catch { print("BW QA SAVE FAILED \(error.localizedDescription)") }
                            fflush(stdout)
                        }
                        if let stamps = TestIsolation.launchArgument("BWTestCloudIdeaRead") {
                            await Self.verifyCloudIdeas(stamps.split(separator: ",").map(String.init), model: model)
                        }
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
        // Hardware keyboard (iPad, or iPhone with a keyboard): hold ⌘ to see these.
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Capture") { startCapture(asIdea: false) }
                    .keyboardShortcut("n", modifiers: .command)
                Button("New Idea") { startCapture(asIdea: true) }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
            }
        }
    }

    private func open(_ url: URL) {
        guard url.scheme == "betterworkspace-mobile" else { return }
        if let route = WidgetRoute(url: url) {
            model?.widgetNavigation = route
            return
        }
        switch url.host {
        case "workspace": selectedTab = .workspace
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
        // Select the destination before changing the request.
        selectedTab = .capture
        if asIdea { captureModel?.selectedCaptureKind = .idea }
        captureRequest += 1
    }
}
