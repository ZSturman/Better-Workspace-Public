import SwiftUI
import BetterWorkspaceCore

/// Ingest Companion — capture only.
///
/// Deliberately narrow: type, paste, add a photo, or add a file. It does not browse or
/// edit the Workspace. Save writes one real capture folder in the shared Inbox; an
/// optional Mac-published folder and tag intent lets the Mac finish the hand-off
/// without giving the phone broad Workspace filesystem access.
@main
struct IngestCompanionApp: App {
    @State private var model = MobileModel()
    @State private var captureRequest = 0

    init() {
        IngestTipConfiguration.configure()
    }

    var body: some Scene {
        WindowGroup {
            CaptureScreen(captureRequest: captureRequest)
                .environment(model)
                .onOpenURL { url in
                    openCapture(url)
                }
                .task {
                    if let value = UserDefaults.standard.string(forKey: "BWInitialURL"), let url = URL(string: value) {
                        openCapture(url)
                    }
                }
        }
    }

    private func openCapture(_ url: URL) {
        guard url.scheme == "betterworkspace-ingest", url.host == "capture" else { return }
        captureRequest += 1
    }
}
