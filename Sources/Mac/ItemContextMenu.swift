import SwiftUI
import BetterWorkspaceCore

/// File actions on the displayed item; deletion is explicit and recoverable.
struct ItemContextMenu: View {
    @Environment(AppModel.self) private var model
    let item: WorkspaceItem

    var body: some View {
        Button("Open") { model.open(item.url) }
        Button("Quick Look") { QuickLookController.shared.preview([item.url]) }
        Button("Reveal in Finder") { model.revealInFinder(item.url) }
        if let capability = model.cachedProjectToolCapability(for: item) {
            if capability.canExplain { Button("Explain") { model.openProjectTool(.explain, for: item) } }
            if capability.canFlowReview { Button("Flow Review") { model.openProjectTool(.flowReview, for: item) } }
        }
        Divider()
        Button("Copy Path") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(item.url.path, forType: .string)
        }
        Divider()
        Menu("Add Tag") {
            if model.allTags.isEmpty {
                Text("No tags yet")
            } else {
                ForEach(model.allTags) { tag in
                    Button(tag.name) { model.assign(tag: tag, to: item) }
                }
            }
        }
        if model.canDelete(item) {
            Divider()
            if model.workspace.area(containing: item.url) == .projects && item.isDirectory {
                Menu("Manage project") {
                    Button("Delete project…", role: .destructive) { model.requestDeletion(of: item) }
                }
            } else {
                Button(item.isDirectory ? "Delete folder…" : "Delete", role: .destructive) { model.requestDeletion(of: item) }
            }
        }
        Button("Inspect") {
            model.selectedItem = item
            model.showInspector = true
        }
    }
}
