import SwiftUI

/// Personal work is independent; the existing Mac index/command path stays intact.
struct MobileExperienceRoot: View {
    @Environment(MobileWorkspaceModel.self) private var model
    @Binding var experience: String
    @Binding var selectedTab: MobileWorkspaceTab
    let captureRequest: Int
    @AppStorage("workspaceWelcomeCompleted") private var welcomed = false
    @State private var showsWelcome = false
    @State private var showsSample = false

    var body: some View {
        VStack(spacing: 0) {
            Picker("Workspace", selection: $experience) {
                Text("My Workspace").tag("personal")
                Text("Mac Workspace").tag("connected")
            }
            .pickerStyle(.segmented).padding(.horizontal).padding(.vertical, 6)
            .accessibilityIdentifier("workspace.experience")
            if experience == "personal" { PersonalWorkspaceView() }
            else { MobileWorkspaceRootView(selectedTab: $selectedTab, captureRequest: captureRequest) }
        }
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
                experience = "personal"; finishWelcome()
            }, connect: { experience = "connected"; finishWelcome() }, exploreSample: {
                finishWelcome(); showsSample = true
            })
        }
        .fullScreenCover(isPresented: $showsSample) { MobileSampleWorkspaceView() }
        .onReceive(NotificationCenter.default.publisher(for: .init("BetterWorkspace.ShowWelcome"))) { _ in showsWelcome = true }
        .onChange(of: captureRequest) { _, _ in experience = "connected" }
        .onChange(of: model.widgetNavigation) { _, route in if route != nil { experience = "connected" } }
    }

    private func finishWelcome() { welcomed = true; showsWelcome = false }
}
