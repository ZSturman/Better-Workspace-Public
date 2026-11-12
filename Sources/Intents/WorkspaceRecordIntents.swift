import AppIntents
import BetterWorkspaceCore

/// Portable captures save to the same local journal as the editor. The existing
/// file/clipboard/folder capture intents retain their established inbox behavior.
struct AddWorkspaceTaskIntent: AppIntent {
    static var title: LocalizedStringResource = "Add Workspace Task"
    static var description = IntentDescription("Save a task in your workspace, even when your computer is unavailable.")
    @Parameter(title: "Title") var title: String
    @Parameter(title: "Notes", default: "") var notes: String
    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        let session = try await WorkspaceSession.openLive()
        _ = try await session.save(content: .init(kind: .task, title: title, body: notes), expectedHeads: [])
        return .result(dialog: "Saved in your workspace.")
    }
}

struct AddWorkspaceIdeaIntent: AppIntent {
    static var title: LocalizedStringResource = "Add Workspace Idea"
    static var description = IntentDescription("Save an idea in your workspace without requiring a computer connection.")
    @Parameter(title: "Title") var title: String
    @Parameter(title: "Notes", default: "") var notes: String
    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        let session = try await WorkspaceSession.openLive()
        _ = try await session.save(content: .init(kind: .idea, title: title, body: notes), expectedHeads: [])
        return .result(dialog: "Saved in your workspace.")
    }
}
