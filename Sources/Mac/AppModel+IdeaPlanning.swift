import Foundation
import BetterWorkspaceCore

extension AppModel {
    /// All idea decisions go through the service. Register only shallow missing records,
    /// in bounded batches, and fill inherited project ratings without overwriting choices.
    func refreshIdeaPlanning() async {
        guard mayReadBackgroundService, !ideaPlanningRefreshInFlight else { return }
        ideaPlanningRefreshInFlight = true
        defer { ideaPlanningRefreshInFlight = false }
        guard let fresh = await BackgroundServiceClient.shared.ideas() else { return }
        var byPath = Dictionary(fresh.map { ($0.canonicalPath, $0) }, uniquingKeysWith: { first, _ in first })
        let store = projectStore
        let projectsByIdentity = Dictionary(store.allRecords().compactMap { record in record.identityKey.map { ($0, record) } }, uniquingKeysWith: { first, _ in first })
        var changed = false
        let candidates = items(for: .ideas).filter { byPath[$0.url.canonicalPath]?.planning == nil }
        if !candidates.isEmpty, !TestIsolation.isActive {
            do { try await claimServiceProjectGraphWriter() } catch { lastError = error.localizedDescription; return }
        }
        for item in candidates.prefix(20) {
            guard let path = workspaceRelativePath(for: item.url), (try? MobilePlanningFiles.resolve(path, workspace: workspace)) != nil,
                  var record = await BackgroundServiceClient.shared.registerIdea(at: item.url) else { continue }
            if let identity = item.identity?.key, let source = projectsByIdentity[identity], record.planning?.ratings.isEmpty != false {
                var inherited = record.planning ?? IdeaPlanning()
                inherited.ratings = ratingsByProject[source.id] ?? store.ratings(for: source.id)
                inherited.potential = inherited.potential ?? .project; inherited.sourceProjectID = source.id
                var changes = IdeaChanges()
                changes.planning = inherited; changes.expectedPlanning = record.planning; changes.checksPlanning = true
                if record.oneLiner == nil { changes.oneLiner = store.description(for: source.id).oneLiner }
                if let updated = await BackgroundServiceClient.shared.updateIdea(id: record.id, changes) { record = updated }
            }
            byPath[record.canonicalPath] = record; changed = true
        }
        let projectionChanged = byPath != serviceIdeasByPath
        updateIdeaPlanningRecords(byPath)
        if changed || projectionChanged { refreshOverview(); requestMobileCloudSync() }
    }

    /// Keeps access to the observable dictionary within AppModel's own mutation API.
    func saveIdeaPlanning(_ planning: IdeaPlanning, for item: WorkspaceItem, original: IdeaPlanning?) async -> Bool {
        guard let record = ideaRecord(for: item.url) else { lastError = "Wait for the updated idea service to index this item."; return false }
        var updatedPlanning = planning
        if updatedPlanning.potential == .project && updatedPlanning.project == nil { updatedPlanning.project = .init(oneLiner: record.oneLiner ?? "") }
        do { try updatedPlanning.validate(original: original) } catch { lastError = error.localizedDescription; return false }
        var changes = IdeaChanges(); changes.planning = updatedPlanning; changes.expectedPlanning = original; changes.checksPlanning = true
        guard await updateIdea(record, changes) else { return false }
        refreshOverview(); requestMobileCloudSync()
        await synchronizePotentialIdeaProjects(only: record.id)
        return true
    }

    func queueIdeaPromotion(_ item: WorkspaceItem, kind: IdeaPromotionKind) -> Bool {
        guard item.isDirectory, let path = workspaceRelativePath(for: item.url), let store = widgetCommands else { lastError = "Choose an idea folder. Folder promotion requires the Mac command service."; return false }
        guard let metadata = ideaRecord(for: item.url) else { lastError = "Wait for the updated idea service to index this folder before promoting it."; return false }
        let original = MobileIdea(path: path, title: metadata.title, revision: 0,
            tagIDs: Set(tags(for: item).map(\.id)), modifiedAt: item.rawModifiedAt, description: metadata.oneLiner,
            serviceID: metadata.id, planning: metadata.planning)
        let edit = MobilePlanningEdit(operation: .promoteIdea, title: original.title, originalIdea: original, ideaPromotion: kind)
        do {
            try MobilePlanningFiles.validate(edit)
            if kind == .project, let graph = potentialProjectRecord(for: metadata) {
                try store.set("idea-promotion-notion-review:" + edit.id.uuidString, graph)
            }
            try store.append(.planning(edit), stream: "workspace")
            statusMessage = "Moving the complete idea folder to \(kind.area)…"
            Task { await consumeWidgetCommands() }
            return true
        } catch { lastError = error.localizedDescription; return false }
    }

    func applyIdeaPromotion(_ edit: MobilePlanningEdit) async throws {
        guard let original = edit.originalIdea, let kind = edit.ideaPromotion, let commands = widgetCommands else { throw MobilePlanningFiles.Error.invalid("Missing idea promotion.") }
        let key = "idea-promotion:" + edit.id.uuidString
        var checkpoint = try commands.value(key, as: IdeaPromotionCheckpoint.self)
        if checkpoint?.applied == true { return }
        let workspace = workspace
        if checkpoint == nil, let id = original.serviceID {
            guard let fresh = await BackgroundServiceClient.shared.ideas()?.first(where: { $0.id == id }),
                  fresh.canonicalPath == (try MobilePlanningFiles.resolve(original.path, workspace: workspace)).canonicalPath,
                  fresh.planning == original.planning, fresh.title == original.title,
                  (fresh.oneLiner ?? "") == (original.description ?? "") else { throw MobilePlanningFiles.Error.conflict }
        }
        if checkpoint == nil { try await verifyPotentialIdeaPromotion(edit.id) }
        let prior = checkpoint
        checkpoint = try await Task.detached(priority: .userInitiated) {
            try IdeaPromotionFiles.move(original, kind: kind, workspace: workspace, checkpoint: prior)
        }.value
        guard var value = checkpoint else { throw MobilePlanningFiles.Error.conflict }
        try commands.set(key, value) // Persist identity before moving any user data.
        try await Task.detached(priority: .userInitiated) { try IdeaPromotionFiles.apply(value) }.value
        let destination = URL(fileURLWithPath: value.destination)
        if let workKind = kind.workKind {
            // The entire idea and attachments stay in this folder. Only the explicit
            // promotion adds one portable feature/milestone plan, idempotent by UUID.
            if !workItems.contains(where: { $0.id == edit.id.uuidString }) {
                let service = workItemService
                let existing = await Task.detached(priority: .utility) { service.items(under: destination).first { $0.id == edit.id.uuidString } }.value
                if existing == nil {
                    _ = try await createWorkItem(id: edit.id.uuidString, kind: workKind, title: original.title,
                        body: original.description ?? "", status: .open, stage: .next, priority: (original.planning?.priority ?? 3) >= 4 ? .high : (original.planning?.priority ?? 3) <= 2 ? .low : .medium, projectPath: nil, in: destination)
                }
            }
        } else if value.projectBound != true {
            let record = projectStore.register(url: destination)
            if let planning = original.planning {
                for metric in MetricDefinition.all { projectStore.setRating(planning.ratings[metric.id], metricID: metric.id, for: record.id) }
            }
            if projectStore.description(for: record.id).isEmpty, let text = original.description {
                projectStore.setDescription(ProjectDescription(oneLiner: text, summary: nil), for: record.id)
            }
            if let project = original.planning?.project {
                var metadata = project.metadata
                metadata.status = "Queued"
                projectStore.setMetadata(metadata, for: record.id)
                projectStore.setDescription(ProjectDescription(oneLiner: project.oneLiner, summary: project.summary), for: record.id)
            }
            try await finishPotentialIdeaPromotion(serviceID: original.serviceID, project: record, destination: destination)
            reloadProjectRatings()
            value.projectBound = true; try commands.set(key, value)
        }
        // Same-volume identity preserves tags even before paths are refreshed.
        try tagStore.rebindKnownPaths(from: URL(fileURLWithPath: value.source), to: destination, area: kind.area)
        _ = tagStore.registerObject(url: destination, area: kind.area)
        if let id = original.serviceID, !(await BackgroundServiceClient.shared.relocateIdea(id: id, source: value.source, destination: value.destination)) {
            // The move is already journaled. Retrying this command safely resumes here.
            throw WidgetCommandError.waitingForIdeaService
        }
        value.applied = true; try commands.set(key, value)
        await refreshAll()
        await synchronizePotentialIdeaProjects()
        statusMessage = "Moved “\(original.title)” and all its files to \(kind.area)"
    }
}
