import Foundation
import BetterWorkspaceCore

struct WorkspaceDeletionRequest: Identifiable {
    let id = UUID()
    let item: WorkspaceItem?
    let work: WorkItem?
    var title: String { work?.title ?? item?.displayTitle ?? "item" }
    var message: String {
        if item?.isDirectory == true {
            return "Are you sure? The entire folder and everything inside it will move to the Mac’s Trash. Work stored elsewhere stays in place. Linked Notion pages stay in Notion. You can recover the folder in Finder."
        }
        return "Are you sure? This item’s file will move to the Mac’s Trash. Linked Notion pages stay in Notion. You can recover the file in Finder."
    }
}

extension AppModel {
    func canDelete(_ item: WorkspaceItem) -> Bool {
        guard let path = workspaceRelativePath(for: item.url) else { return false }
        // Pure path checks only; reads and symlink validation happen off the main actor.
        return path.split(separator: "/").count >= 2 && !path.split(separator: "/").contains {
            $0.hasPrefix(".") || NoiseFilter.isForeignMetadata(name: String($0)) || NoiseFilter.foreignTopLevelDirectories.contains(String($0))
        }
    }

    func requestDeletion(of item: WorkspaceItem) {
        guard canDelete(item) else { return }
        if let work = workItems.first(where: { $0.url.canonicalPath == item.url.canonicalPath }) {
            requestDeletion(of: work)
        } else if workspace.area(containing: item.url) == .ideas && !item.isDirectory {
            deleteWorkspaceItem(item)
        } else {
            deletionRequest = WorkspaceDeletionRequest(item: item, work: nil)
        }
    }

    func requestDeletion(of work: WorkItem) {
        if work.kind == .task { deleteWorkItem(work) }
        else { deletionRequest = WorkspaceDeletionRequest(item: nil, work: work) }
    }

    func confirmDeletion() {
        guard let request = deletionRequest else { return }
        deletionRequest = nil
        if let work = request.work { deleteWorkItem(work) }
        else if let item = request.item { deleteWorkspaceItem(item) }
    }

    func deleteWorkspaceItem(_ item: WorkspaceItem) {
        Task {
            do { try await trashWorkspaceItem(item) }
            catch { lastError = error.localizedDescription }
        }
    }

    func trashWorkspaceItem(_ item: WorkspaceItem) async throws {
        guard let path = workspaceRelativePath(for: item.url), canDelete(item) else {
            throw MobilePlanningFiles.Error.invalid("That item cannot be deleted here.")
        }
        let workspace = workspace, trash = TestIsolation.trashDirectory
        let contained = workItems.filter { $0.url.canonicalPath == item.url.canonicalPath || $0.url.canonicalPath.hasPrefix(item.url.canonicalPath + "/") }
        contained.forEach { beginAppTrash(ofWorkItemAt: $0.url.canonicalPath) }
        do {
            _ = try await Task.detached(priority: .userInitiated) {
                try WorkspaceTrash.move(path: path, workspace: workspace, isDirectory: item.isDirectory,
                                        modifiedAt: item.rawModifiedAt, into: trash)
            }.value
        } catch {
            contained.forEach { endAppTrash(ofWorkItemAt: $0.url.canonicalPath, trashed: false) }
            throw error
        }
        contained.forEach { endAppTrash(ofWorkItemAt: $0.url.canonicalPath, trashed: true) }
        do {
            let store = try ProjectGraphStore(database: database)
            try store.recordLocalDeletion(path: item.url.canonicalPath, pageIDs: Set(contained.compactMap(\.importedNotionPageID)))
        }
        catch { lastError = "The file is in the Trash, but its sync bookkeeping could not be updated: " + error.localizedDescription }
        if selectedItem?.url.canonicalPath == item.url.canonicalPath || selectedItem?.url.canonicalPath.hasPrefix(item.url.canonicalPath + "/") == true { selectedItem = nil }
        if workspaceProject()?.url.canonicalPath == item.url.canonicalPath { closeProjectWorkspace() }
        reloadProjectGraph()
        if let area = workspace.areaName(containing: item.url) { await refresh(areaNamed: area) }
        refreshOverview()
        statusMessage = "Moved “\(item.displayTitle)” to the Trash"
    }
}
