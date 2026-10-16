import Foundation
import BetterWorkspaceCore

extension AppModel {
    /// Called only for an explicit phone Save. Portable work saves still pass through
    /// the normal local/graph editor; Notion remains a separately reviewed Send.
    func applyMobilePlanning(_ edit: MobilePlanningEdit) async throws {
        try MobilePlanningFiles.validate(edit)
        switch edit.operation {
        case .previewIdea:
            guard let original = edit.originalIdea else { throw MobilePlanningFiles.Error.invalid("Missing idea preview request.") }
            try await prepareMobileIdeaPreviews(original)
        case .saveIdeaPlanning:
            guard let original = edit.originalIdea, let planning = edit.ideaPlanning else { throw MobilePlanningFiles.Error.invalid("Missing idea scores.") }
            let url = try MobilePlanningFiles.resolve(original.path, workspace: workspace)
            guard let fresh = await BackgroundServiceClient.shared.ideas()?.first(where: { $0.id == original.serviceID && $0.canonicalPath == url.canonicalPath }),
                  fresh.planning == original.planning || fresh.planning == planning else { throw MobilePlanningFiles.Error.conflict }
            var changes = IdeaChanges(); changes.planning = planning; changes.expectedPlanning = original.planning; changes.checksPlanning = true
            guard await updateIdea(fresh, changes) else { throw MobilePlanningFiles.Error.invalid(lastError ?? "The idea service is unavailable.") }
            await synchronizePotentialIdeaProjects(only: fresh.id)
            refreshOverview()
        case .promoteIdea:
            try await applyIdeaPromotion(edit)
        case .scheduleCapture:
            guard let review = edit.captureReview else { throw MobilePlanningFiles.Error.invalid("Missing capture schedule.") }
            await refreshIngest()
            guard let capture = ingestItems.first(where: { $0.url.lastPathComponent == review.capture.name }) else { throw WidgetCommandError.waitingForCapture }
            guard capture.item.rawModifiedAt.map({ abs($0.timeIntervalSince(review.capture.modified)) < 0.001 }) == true else { throw MobilePlanningFiles.Error.conflict }
            try ingest.schedule(capture, priority: review.priority, until: review.until)
            await refreshIngest()
        case .saveProject:
            guard let change = edit.projectEdit else { throw MobilePlanningFiles.Error.invalid("Missing project edit.") }
            let url = try MobilePlanningFiles.resolve(change.original.path, workspace: workspace)
            guard let project = projects().first(where: { $0.url.canonicalPath == url.canonicalPath }),
                  projectRecord(for: project)?.id == change.original.projectID else { throw MobilePlanningFiles.Error.conflict }
            try projectStore.saveMobileProject(change)
            reloadProjectRatings()
            queueProjectGraphEdits(for: project, fields: Set(["one liner", "summary"] + MetricDefinition.all.map(\.displayName)))
            refreshOverview()
        case .previewProject:
            guard let entry = edit.originalEntry else { throw MobilePlanningFiles.Error.invalid("Missing project.") }
            try await prepareMobileProjectPreviews(entry)
        case .fileCapture:
            try await applyWidgetCaptureFiling(edit)
        case .reviewInbox:
            guard let command = edit.inboxReview else { throw MobilePlanningFiles.Error.invalid("Missing review decision.") }
            let controller = prepareOverviewInbox()
            try await controller.apply(command, operationID: edit.id)
            // Refresh before the digest is published so the phone receives the next
            // item with its receipt, rather than an empty card until the next sync.
            await controller.refresh(force: true)
            await refreshWorkItems()
            refreshOverview()
        case .saveWork:
            guard let draft = edit.work, draft.title == edit.title else {
                throw MobilePlanningFiles.Error.invalid("The work draft is incomplete.")
            }
            if let original = edit.originalWork {
                // By stable ID when the path is stale: a task created on the phone and
                // edited before this Mac applied it names a placeholder path.
                let service = workItemService
                let workspace = workspace
                let known = workItems
                guard var item = try await Task.detached(priority: .userInitiated, operation: {
                          try MobilePlanningFiles.locateWork(original, among: known, workspace: workspace, service: service)
                      }).value,
                      item.id == draft.id,
                      MobilePlanningFiles.matches(item, original: original, workspace: workspace) || MobilePlanningFiles.matches(item, original: draft, workspace: workspace, respectModifiedDate: false) else {
                    throw MobilePlanningFiles.Error.conflict
                }
                if draft.body == nil, !MobilePlanningFiles.matches(item, original: original, workspace: workspace),
                   MobilePlanningFiles.matches(item, original: draft, workspace: workspace, respectModifiedDate: false) { return }
                item.title = draft.title; item.kind = draft.kind; item.status = draft.status
                item.stage = draft.stage; item.priority = draft.priority; item.projectPath = draft.projectPath
                item.dueDate = draft.dueDate
                // Sent only when changed on the phone; absent means leave them be.
                if let features = draft.featureIDs { item.featureIDs = features }
                if let milestones = draft.milestoneIDs { item.milestoneIDs = milestones }
                if let body = draft.body { item.body = body }
                item.completedAt = draft.status == .completed ? (item.completedAt ?? Date()) : nil
                let saved = try await saveWorkItem(item)
                try widgetCommands?.set("applied-work:" + edit.id.uuidString, saved.modifiedAt)
                applyMobilePlanningTags(edit, to: saved.url, original: original.tagIDs)
            } else {
                // Creation is idempotent by stable ID, including a retry after a crash
                // between the filesystem write and private acknowledgement.
                guard draft.id == edit.id.uuidString else { throw MobilePlanningFiles.Error.invalid("Invalid new work identity.") }
                if let existing = workItems.first(where: { $0.id == draft.id }) {
                    applyMobilePlanningTags(edit, to: existing.url, original: [])
                    return
                }
                let directory: URL
                if let path = draft.projectPath {
                    guard let project = projects().first(where: { workspaceRelativePath(for: $0.url) == path && $0.isDirectory }) else {
                        throw WorkItemProjectLinkError.unavailable(draft.kind, path)
                    }
                    directory = try MobilePlanningFiles.resolve(path + "/Work", workspace: workspace)
                } else {
                    guard let queue = WorkQueueRouting.folder(for: draft.kind, among: folders) else {
                        throw MobilePlanningFiles.Error.invalid("Choose a project or set up a work queue on the Mac.")
                    }
                    directory = queue.url
                }
                let service = workItemService
                let existing = await Task.detached(priority: .userInitiated) {
                    service.items(under: directory).first { $0.id == draft.id }
                }.value
                var saved: WorkItem
                if let existing { saved = existing }
                else {
                    saved = try await createWorkItem(id: draft.id, kind: draft.kind, title: draft.title,
                        body: draft.body ?? "", status: draft.status, stage: draft.stage, priority: draft.priority,
                        projectPath: draft.projectPath, featureIDs: draft.featureIDs ?? [],
                        milestoneIDs: draft.milestoneIDs ?? [], in: directory)
                }
                // `createWorkItem` has no due date or completion; without this a task
                // created on the phone with a due date silently lost it here.
                let needsDueDate = draft.dueDate != nil && saved.dueDate == nil
                let needsCompletion = draft.status == .completed && saved.completedAt == nil
                if needsDueDate || needsCompletion {
                    if needsDueDate { saved.dueDate = draft.dueDate }
                    if needsCompletion { saved.completedAt = Date() }
                    saved = try await saveWorkItem(saved)
                }
                applyMobilePlanningTags(edit, to: saved.url, original: [])
            }
        case .trashWork:
            guard let original = edit.originalWork else { throw MobilePlanningFiles.Error.invalid("The work record to delete is missing.") }
            let service = workItemService
            let workspace = workspace
            let known = workItems
            let trash = TestIsolation.trashDirectory
            // Mark the record as this app's own removal before it goes, so the Mac does
            // not mistake it for a file deleted outside the app and keep showing it.
            let located = try await Task.detached(priority: .userInitiated) {
                try MobilePlanningFiles.locateWork(original, among: known, workspace: workspace, service: service)
            }.value
            guard let path = located?.url.canonicalPath else {
                // Finish bookkeeping if the previous attempt moved the file but lost
                // its receipt or exited before writing its private tombstone.
                let url = try MobilePlanningFiles.resolve(original.path, workspace: workspace)
                try ProjectGraphStore(database: database).recordLocalDeletion(path: url.canonicalPath, pageID: original.importedNotionPageID)
                reloadProjectGraph()
                return
            }
            beginAppTrash(ofWorkItemAt: path)
            do {
                let trashed = try await Task.detached(priority: .userInitiated) {
                    try MobilePlanningFiles.trashWork(edit, among: known, workspace: workspace, service: service, into: trash)
                }.value
                endAppTrash(ofWorkItemAt: path, trashed: trashed != nil)
                if trashed != nil {
                    do { try ProjectGraphStore(database: database).recordLocalDeletion(path: path, pageID: original.importedNotionPageID) }
                    catch { lastError = "The file is in the Trash, but its sync bookkeeping could not be updated: " + error.localizedDescription }
                    reloadProjectGraph()
                }
            } catch {
                endAppTrash(ofWorkItemAt: path, trashed: false)
                throw error
            }
        case .trashIdea, .trashProject, .trashEntry:
            guard let entry = edit.originalEntry else { throw MobilePlanningFiles.Error.invalid("The original item is missing.") }
            let workspace = workspace
            let url = try await Task.detached(priority: .userInitiated) {
                try WorkspaceTrash.resolve(entry.path, workspace: workspace)
            }.value
            // A lost receipt may retry a successful deletion. Do not read service
            // metadata or attempt to recreate a missing item.
            guard let item = await fs.makeItem(url: url) else {
                if await Task.detached(operation: { FileManager.default.fileExists(atPath: url.path) }).value { throw MobilePlanningFiles.Error.conflict }
                let contained = workItems.filter { $0.url.canonicalPath == url.canonicalPath || $0.url.canonicalPath.hasPrefix(url.canonicalPath + "/") }
                try ProjectGraphStore(database: database).recordLocalDeletion(path: url.canonicalPath, pageIDs: Set(contained.compactMap(\.importedNotionPageID)))
                for work in contained {
                    beginAppTrash(ofWorkItemAt: work.url.canonicalPath)
                    endAppTrash(ofWorkItemAt: work.url.canonicalPath, trashed: true)
                }
                reloadProjectGraph()
                return
            }
            guard item.isDirectory == entry.isDirectory, item.contentModifiedAt == entry.modifiedAt else { throw MobilePlanningFiles.Error.conflict }
            if edit.operation == .trashIdea, let original = edit.originalIdea, let id = original.serviceID,
               item.isDirectory || !["md", "markdown", "mdown", "txt"].contains(url.pathExtension.lowercased()) {
                guard let fresh = await BackgroundServiceClient.shared.ideas()?.first(where: { $0.id == id }),
                      fresh.canonicalPath == url.canonicalPath, fresh.title == original.title,
                      fresh.oneLiner == original.description else { throw MobilePlanningFiles.Error.conflict }
            }
            try await trashWorkspaceItem(item)
        case .saveIdea:
            guard let original = edit.originalIdea else { throw MobilePlanningFiles.Error.invalid("The original idea is missing.") }
            let url = try MobilePlanningFiles.resolve(original.path, workspace: workspace)
            guard workspace.areaName(containing: url) == WorkspaceArea.ideas.directoryName else {
                throw MobilePlanningFiles.Error.invalid("Only Ideas can be edited here.")
            }
            let isDirectory = await Task.detached(priority: .utility) { (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }.value
            if let id = original.serviceID, isDirectory || !["md", "markdown", "mdown", "txt"].contains(url.pathExtension.lowercased()) {
                guard let fresh = await BackgroundServiceClient.shared.ideas()?.first(where: { $0.id == id }),
                      fresh.canonicalPath == url.canonicalPath,
                      (fresh.title == original.title && fresh.oneLiner == original.description)
                        || (fresh.title == edit.title && (fresh.oneLiner ?? "") == edit.description) else {
                    throw MobilePlanningFiles.Error.conflict
                }
                var changes = IdeaChanges(oneLiner: edit.description)
                changes.title = edit.title
                guard await updateIdea(fresh, changes) else { throw MobilePlanningFiles.Error.invalid(lastError ?? "The idea service is unavailable.") }
            } else {
                guard ["md", "markdown", "mdown", "txt"].contains(url.pathExtension.lowercased()) else {
                    throw MobilePlanningFiles.Error.invalid("Edit this file in its original app on the Mac.")
                }
                let snapshot = try await Task.detached(priority: .userInitiated) { try TextDocumentService().read(at: url) }.value
                let parts = MobilePlanningFiles.splitIdeaText(snapshot.text, fallbackTitle: original.title)
                guard (parts.0 == original.title && parts.1 == original.description)
                    || (parts.0 == edit.title && parts.1 == edit.description) else { throw MobilePlanningFiles.Error.conflict }
                _ = try await saveIdeaText(MobilePlanningFiles.ideaText(title: edit.title, description: edit.description), to: url, expecting: snapshot)
            }
            applyMobilePlanningTags(edit, to: url, original: original.tagIDs)
        case .createIdea:
            let workspace = workspace
            let url = try await Task.detached(priority: .userInitiated) { try MobilePlanningFiles.createIdea(edit, workspace: workspace) }.value
            applyMobilePlanningTags(edit, to: url, original: [])
        case .createProject:
            let workspace = workspace
            let url = try await Task.detached(priority: .userInitiated) { try MobilePlanningFiles.createProject(edit, workspace: workspace) }.value
            await refreshAll()
            let path = MobilePlanningFiles.projectPath(for: edit)
            // A goal carries the idea into an ordinary editable project plan, while
            // keeping its original idea and attachments intact.
            if !workItems.contains(where: { $0.id == edit.id.uuidString }) {
                _ = try await createWorkItem(id: edit.id.uuidString, kind: .goal, title: edit.title,
                    body: edit.description, status: .open, stage: .later, priority: .medium,
                    projectPath: path, in: url.appendingPathComponent("Work", isDirectory: true))
            }
            if let project = projects().first(where: { $0.url.canonicalPath == url.canonicalPath }) {
                if projectDescription(for: project)?.isEmpty != false {
                    setProjectDescription(ProjectDescription(oneLiner: nil, summary: edit.description), for: project)
                }
            }
            applyMobilePlanningTags(edit, to: url, original: [])
        }
    }

    private func applyMobilePlanningTags(_ edit: MobilePlanningEdit, to url: URL, original: Set<String>) {
        let known = Set(allTags.map(\.id))
        for id in edit.tagIDs.subtracting(original).intersection(known) { tagStore.assign(tagID: id, to: url, area: workspace.areaName(containing: url)) }
        for id in original.subtracting(edit.tagIDs).intersection(known) { tagStore.unassign(tagID: id, from: url) }
        reloadMobilePlanningTags(at: url)
    }

    /// Only immediate idea children and small UTF-8 descriptions are projected. The
    /// service supplies folder metadata; its sidecars are never read by the app.
    func mobileIdeaDetails(previews: [String: [MobileFilePreview]] = [:]) async -> [String: MobileIdea] {
        var result: [String: MobileIdea] = [:]
        for item in items(for: .ideas) {
            guard let path = workspaceRelativePath(for: item.url) else { continue }
            let metadata = ideaRecord(for: item.url)
            var title = metadata?.title ?? item.displayTitle
            var description = metadata?.oneLiner
            var attachments: [MobileIdeaAttachment] = []
            if item.isDirectory {
                if let children = await FilesystemService.items(inDirectory: item.url, timeout: .seconds(2)) {
                    attachments = children.prefix(50).compactMap { child in
                        guard let childPath = workspaceRelativePath(for: child.url) else { return nil }
                        return MobileIdeaAttachment(path: childPath, name: child.name, isDirectory: child.isDirectory)
                    }
                }
            } else if ["md", "markdown", "mdown", "txt"].contains(item.url.pathExtension.lowercased()) {
                let url = item.url
                if let text = await Task.detached(priority: .utility, operation: { () -> String? in
                    guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                          size <= MobilePlanningFiles.maximumTextBytes else { return nil }
                    return try? String(contentsOf: url, encoding: .utf8)
                }).value {
                    let parts = MobilePlanningFiles.splitIdeaText(text, fallbackTitle: title)
                    title = parts.0; description = parts.1
                }
            } else {
                attachments = [MobileIdeaAttachment(path: path, name: item.name)]
            }
            result[path] = MobileIdea(path: path, title: title, revision: 0,
                description: description, attachments: attachments, serviceID: metadata?.id, planning: metadata?.planning, scoringPreferences: scoringPreferences(), previews: previews["idea:" + (metadata?.id ?? item.id)])
        }
        return result
    }
}
