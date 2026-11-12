import SwiftUI
import BetterWorkspaceCore

struct MobileSettingsView: View {
    @Bindable var session: WorkspaceSession
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                ConnectedAppsSettings()
                NavigationLink("Devices & recovery") { UnifiedConnectionsView(session: session) }
                NavigationLink("Privacy, storage & support") { WorkspacePrivacyView() }
                Button("Show welcome guide") { dismiss(); NotificationCenter.default.post(name: .init("BetterWorkspace.ShowWelcome"), object: nil) }
            }.navigationTitle("Settings")
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}
