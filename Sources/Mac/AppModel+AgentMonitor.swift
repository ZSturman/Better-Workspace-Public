import Foundation
import AppKit
import BetterWorkspaceCore

/// Where an Agent Completion Monitor notification leads.
extension AppModel {
    /// Opens a project's Tasks, and optionally one task's editor. The project is named by
    /// its workspace-relative path (`Projects/<name>`), as every task records it.
    @MainActor
    func openProjectTasks(projectPath: String, taskID: String?) async {
        AppDelegate.suppressLaunchWindow = false
        AppDelegate.reopenWorkspace()
        NSApp.activate(ignoringOtherApps: true)
        if projects().isEmpty { await refresh(area: .projects) }
        // A project renamed after the notification was sent is found where it is now.
        let candidates = [projectPath, projectLinkAliases[projectPath]].compactMap { $0 }
            .map { workspace.root.appendingPathComponent($0).canonicalPath }
        guard let project = candidates.lazy.compactMap({ target in self.projects().first { $0.url.canonicalPath == target } }).first else {
            statusMessage = "“\(projectPath)” is no longer in Projects."
            selection = .overview
            return
        }
        requestedProjectSection = .tasks
        openProjectWorkspace(for: project)
        if let taskID {
            // The task was just written; wait briefly for the file observer to index it.
            for _ in 0..<20 where workItems.contains(where: { $0.id == taskID }) == false {
                try? await Task.sleep(for: .milliseconds(150))
            }
            if let item = workItems.first(where: { $0.id == taskID }) { edit(workItem: item) }
        }
    }
}
