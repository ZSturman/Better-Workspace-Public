import SwiftUI

/// Mobile is a window onto the Mac-owned Workspace. Existing personal storage is retained.
struct MobileExperienceRoot: View {
    @Environment(MobileWorkspaceModel.self) private var model
    @Binding var selectedTab: MobileWorkspaceTab
    let captureRequest: Int
    @AppStorage("workspaceWelcomeCompleted") private var welcomed = false
    @State private var showsWelcome = false
    @State private var showsSample = false

    var body: some View {
        MobileWorkspaceRootView(selectedTab: $selectedTab, captureRequest: captureRequest)
        .task {
            // Existing connected users retain their home; fixtures never show a modal.
            if !welcomed && model.snapshot.entries.isEmpty && !model.isSample &&
                !UserDefaults.standard.bool(forKey: "mobileCloudDisabled") &&
                !UserDefaults.standard.bool(forKey: "BWTestMobilePlanning") {
                showsWelcome = true
            }
        }
        .sheet(isPresented: $showsWelcome) {
            WorkspaceWelcomeView(platform: .mobile, startPersonal: {
                finishWelcome()
            }, connect: nil, exploreSample: {
                finishWelcome(); showsSample = true
            })
        }
        .fullScreenCover(isPresented: $showsSample) { MobileSampleWorkspaceView() }
        .onReceive(NotificationCenter.default.publisher(for: .init("BetterWorkspace.ShowWelcome"))) { _ in showsWelcome = true }
    }

    private func finishWelcome() { welcomed = true; showsWelcome = false }
}
