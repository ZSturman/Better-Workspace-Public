import SwiftUI
import BetterWorkspaceCore

/// Attach to the row label so every presentation (Overview, project, and Work)
/// offers the same long-press actions.
struct MobileWorkDeletionActions: ViewModifier {
    @Environment(MobileWorkspaceModel.self) private var model
    let item: MobileWorkItem
    @State private var confirming = false
    func body(content: Content) -> some View {
        content.contextMenu {
            Button(item.status == .completed ? "Reopen" : "Complete") { model.toggleCompletion(of: item) }
            if item.kind == .task {
                Button("Delete", systemImage: "trash", role: .destructive) { confirming = true }
            } else {
                Menu("Manage \(item.kind.displayName.lowercased())") {
                    Button("Delete…", systemImage: "trash", role: .destructive) { confirming = true }
                }
            }
        }
        .alert("Delete “\(item.title)”?", isPresented: $confirming) {
            Button("Move to Trash", role: .destructive) { model.trash(item) }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Are you sure? Your Mac moves this file to its recoverable Trash when online. Linked Notion pages stay in Notion.") }
    }
}

struct MobileProjectDeletionActions: ViewModifier {
    @Environment(MobileWorkspaceModel.self) private var model
    let project: MobileWorkspaceEntry
    @State private var confirming = false
    func body(content: Content) -> some View {
        content.contextMenu {
            Menu("Manage project") {
                Button("Delete project…", systemImage: "trash", role: .destructive) { confirming = true }
            }
        }
        .alert("Delete project “\(project.name)”?", isPresented: $confirming) {
            Button("Move entire project to Trash", role: .destructive) { model.trash(project) }
            Button("Cancel", role: .cancel) {}
        } message: { Text(Self.message) }
    }
    static let message = "Are you sure? Your Mac moves the entire project folder and everything inside it to its recoverable Trash when online. Work stored elsewhere and linked Notion pages stay in place."
}

struct MobileIdeaDeletionActions: ViewModifier {
    @Environment(MobileWorkspaceModel.self) private var model
    let idea: MobileIdea
    @State private var confirming = false
    func body(content: Content) -> some View {
        content.contextMenu {
            Button("Delete idea", systemImage: "trash", role: .destructive) { confirming = true }
        }
        .confirmationDialog("Delete idea “\(idea.title)”?", isPresented: $confirming, titleVisibility: .visible) {
            Button("Move to Trash", role: .destructive) { model.trash(idea) }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Your Mac moves the idea and any files inside its folder to its recoverable Trash when online. Linked Notion pages stay in Notion.") }
    }
}

struct MobileEntryDeletionActions: ViewModifier {
    @Environment(MobileWorkspaceModel.self) private var model
    let entry: MobileWorkspaceEntry
    @State private var confirming = false
    func body(content: Content) -> some View {
        content.contextMenu {
            if entry.parentPath != nil {
                Menu("Manage item") {
                    Button("Delete…", systemImage: "trash", role: .destructive) { confirming = true }
                }
            }
        }
        .alert("Delete “\(entry.name)”?", isPresented: $confirming) {
            Button("Move to Trash", role: .destructive) { model.trash(entry) }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Are you sure? Your Mac moves this item and everything inside it to its recoverable Trash when online. Linked Notion pages stay in Notion.") }
    }
}
