import SwiftUI
import BetterWorkspaceCore

/// Available offline; the public policy and support pages provide further detail.
struct WorkspacePrivacyView: View {
    var body: some View {
        Form {
            Section("My Workspace") {
                Text("Projects, tasks, ideas and documents you create in My Workspace stay in a separate private app database. They work offline and do not require the advanced Mac app or its background service. The private sample uses memory only and discards its edits when closed.")
                Text(WorkspaceNotebookPersistence.isCloudSyncEnabled ? "Personal records also synchronize through your private iCloud account when available. Use the same Apple account on your devices. Transfers can take a few minutes; the workspace shows account and transfer status. The developer cannot access your private iCloud database." : "Personal iCloud synchronization is not enabled in this edition yet. Your records remain on this device.")
            }
            Section("Your workspace") {
                Text("Better Workspace stores your files in folders you control. Tags, indexes, settings and sync receipts stay in private app storage. The app includes no advertising, tracking or developer analytics service.")
            }
            Section("Across devices") {
                Text("When you enable workspace publishing on your Mac, its index and selected previews sync through your private iCloud account. Captures use iCloud Drive. Planning changes wait for your Mac to apply them and return a receipt.")
            }
            Section("Optional integrations") {
                Text("On Mac, connecting Notion can send the content you choose to that service. Agent tasks and AI requests go to the provider you select. Review the provider’s privacy terms before sharing sensitive content.")
            }
            Section("Privacy & support") {
                Link("Privacy policy", destination: URL(string: "https://zacharysturman.com/better-workspace/privacy")!)
                Link("Setup & support", destination: URL(string: "https://zacharysturman.com/better-workspace/support")!)
                Text("Deleting the app does not delete your workspace folders, iCloud files or Notion pages. Manage those separately in Finder, Files, iCloud and Notion.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Privacy & Support")
        .accessibilityIdentifier("workspace-privacy")
    }
}
