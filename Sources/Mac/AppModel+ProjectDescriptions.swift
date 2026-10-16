import Foundation
import BetterWorkspaceCore

/// A project's one-liner and summary — what it is, in a person's words. Kept with the
/// project's ratings, keyed to its identity rather than its path.
extension AppModel {

    func projectDescription(for item: WorkspaceItem) -> ProjectDescription? {
        guard let record = projectRecord(for: item) else { return nil }
        return projectStore.description(for: record.id)
    }

    func setProjectDescription(_ description: ProjectDescription, for item: WorkspaceItem) {
        guard let record = projectRecord(for: item) else { return }
        projectStore.setDescription(description, for: record.id)
        queueProjectGraphEdits(for: item, fields: ["one liner", "summary"])
        refreshOverview()
        requestMobileCloudSync()
        statusMessage = "Saved the description of “\(item.displayTitle)”"
    }
}
