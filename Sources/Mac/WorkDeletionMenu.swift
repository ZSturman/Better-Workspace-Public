import SwiftUI
import BetterWorkspaceCore

/// Values and an action only: safe to use in outgoing List/Table rows.
struct WorkDeletionMenu: View {
    let item: WorkItem
    let requestDeletion: (WorkItem) -> Void
    var body: some View {
        if item.kind == .task {
            Button("Delete", role: .destructive) { requestDeletion(item) }
        } else {
            Menu("Manage \(item.kind.displayName.lowercased())") {
                Button("Delete…", role: .destructive) { requestDeletion(item) }
            }
        }
    }
}
