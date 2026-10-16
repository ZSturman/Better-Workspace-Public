import Foundation
import BetterWorkspaceCore

/// Captures filed into a work queue, and the optional links between work.
///
/// A work queue (Features, Milestones, To Do, …) lists `.bw.md` records only. Filing a
/// capture there used to move the raw note in, where the queue could not see it. Every
/// filing path — the menu bar and Inbox composers, App Intents, Inbox processing and
/// phone captures — now comes here when the destination is a queue.
extension AppModel {

    /// Whether filing into `folder` makes a work item rather than moving a file.
    func isWorkQueue(_ folder: WorkspaceFolder) -> Bool { folder.settings.layout == .workQueue }

    /// Makes `capture` a work item of the queue's kind. A text capture becomes the
    /// record's title and notes and then goes to the Trash; anything else (a photo, a
    /// phone capture folder) is filed beside the record and linked from its notes.
    /// The record is written before anything is removed, so a failure part-way leaves
    /// a duplicate, never a loss.
    @discardableResult
    func promoteCapture(_ capture: IngestItem, toQueue folder: WorkspaceFolder,
                        links: WorkItemLinks = .none, tagIDs: Set<String> = [], operationID: UUID? = nil) async throws -> WorkItem {
        let kind = folder.settings.workItemKind
        if let operationID, let existing = workItems.first(where: { $0.id == operationID.uuidString }) { return existing }
        let links = links.applicable(to: kind)
        // Before anything moves: a project that no longer exists fails here, not after
        // an attachment has already been filed.
        _ = try validatedProjectPath(links.projectPath, for: kind)
        let url = capture.url
        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        let isNote = isDirectory.boolValue == false && StrandedQueueNotes.isStranded(url)
        let ingest = ingest
        var (title, body) = isNote ? WorkItemPromotion.content(of: url)
                                   : (url.deletingPathExtension().lastPathComponent, "")
        if isNote == false {
            let filed = try await Task.detached(priority: .userInitiated) {
                let unique = CaptureNaming.uniqueURL(in: folder.url, base: url.deletingPathExtension().lastPathComponent,
                                                     extension: url.pathExtension)
                return try ingest.file(capture, intoDirectory: folder.url,
                                       renamingTo: unique.deletingPathExtension().lastPathComponent)
            }.value
            if let operationID { try widgetCommands?.set("filing-attachment:" + operationID.uuidString, filed.destination.canonicalPath) }
            let name = filed.destination.lastPathComponent
            body = "[\(name)](<\(name)>)"
        }
        if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { title = CaptureNaming.timestampName() }
        let saved = try await createWorkItem(id: operationID?.uuidString ?? UUID().uuidString, kind: kind, title: title, body: body, status: .open, stage: .next,
                                             priority: .medium, projectPath: links.projectPath,
                                             featureIDs: links.featureIDs, milestoneIDs: links.milestoneIDs,
                                             in: folder.url)
        for tagID in tagIDs { tagStore.assign(tagID: tagID, to: saved.url, area: folder.name) }
        if isNote {
            let trash = TestIsolation.trashDirectory
            do { try await Task.detached(priority: .userInitiated) { try ingest.trash(capture, into: trash) }.value }
            catch { statusMessage = "Created “\(saved.title)”, but its Inbox note could not be moved to the Trash." }
        }
        noteFiled(into: folder.name)
        reloadTags()
        return saved
    }

    /// The same, for a note already sitting loose in a queue folder: it becomes a work
    /// item there, keeps its tags, and the note goes to the Trash.
    func convertStrandedNote(_ url: URL, in folder: WorkspaceFolder, links: WorkItemLinks = .none) async {
        guard StrandedQueueNotes.isStranded(url) else { return }
        let kind = folder.settings.workItemKind
        let (title, body) = WorkItemPromotion.content(of: url)
        let tagIDs = tagStore.tags(for: url).map(\.id)
        do {
            let links = links.applicable(to: kind)
            let saved = try await createWorkItem(kind: kind, title: title, body: body, status: .open, stage: .next,
                                                 priority: .medium, projectPath: links.projectPath,
                                                 featureIDs: links.featureIDs, milestoneIDs: links.milestoneIDs,
                                                 in: folder.url)
            for tagID in tagIDs { tagStore.assign(tagID: tagID, to: saved.url, area: folder.name) }
            let trash = TestIsolation.trashDirectory
            try await Task.detached(priority: .userInitiated) {
                if let trash {
                    try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
                    try FileManager.default.moveItem(at: url, to: trash.appendingPathComponent(UUID().uuidString + "-" + url.lastPathComponent))
                } else {
                    try FileManager.default.trashItem(at: url, resultingItemURL: nil)
                }
            }.value
            reloadTags()
            await refresh(areaNamed: folder.name)
            statusMessage = "“\(saved.title)” is now a \(kind.displayName.lowercased())"
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Re-links one record. Fire-and-forget, for menus in lists.
    func setLinks(_ links: WorkItemLinks, for item: WorkItem) {
        var updated = workItems.first { $0.id == item.id } ?? item
        updated.links = links.applicable(to: updated.kind)
        updateWorkItem(updated)
    }

    // MARK: Choices

    /// Every project, by title, as the pickers offer them.
    var projectLinkChoices: [WorkLinkChoice] {
        projects()
            .compactMap { project in
                workspaceRelativePath(for: project.url).map { WorkLinkChoice(id: $0, title: project.displayTitle, detail: nil) }
            }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    /// Open records of `kind`, those in `projectPath` first when one is chosen; a record
    /// already linked is included even when complete, so it can be unlinked.
    func workLinkChoices(_ kind: WorkItemKind, projectPath: String?, keeping selected: [String] = [],
                         excluding excludedID: String? = nil) -> [WorkLinkChoice] {
        workItems
            .filter { $0.kind == kind && $0.id != excludedID && ($0.isOpen || selected.contains($0.id)) }
            .sorted { lhs, rhs in
                let left = projectPath != nil && lhs.projectPath == projectPath
                let right = projectPath != nil && rhs.projectPath == projectPath
                if left != right { return left }
                return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
            }
            .map { WorkLinkChoice(id: $0.id, title: $0.title, detail: $0.projectPath.map { ($0 as NSString).lastPathComponent }) }
    }
}

/// One option in a link picker: a project (id is its path) or a work record (its id).
struct WorkLinkChoice: Identifiable, Hashable {
    let id: String
    let title: String
    let detail: String?
}
