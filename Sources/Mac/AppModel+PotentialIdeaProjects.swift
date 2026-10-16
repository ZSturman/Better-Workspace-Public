import Foundation
import BetterWorkspaceCore

extension AppModel {
    func classifyCreatedIdea(_ item: WorkspaceItem, as kind: IdeaPromotionKind) async {
        var record = ideaRecord(for: item.url)
        if record == nil { record = await BackgroundServiceClient.shared.registerIdea(at: item.url) }
        guard let record else {
            lastError = "Created the idea, but its classification could not be saved. Start the idea service and set it in Details."
            return
        }
        var records = serviceIdeasByPath; records[record.canonicalPath] = record; updateIdeaPlanningRecords(records)
        var planning = record.planning ?? IdeaPlanning(); planning.potential = kind
        _ = await saveIdeaPlanning(planning, for: item, original: record.planning)
    }

    func ideaProjectPropertyOptions() -> [String: [String]] {
        guard let source = graphSources.first(where: { $0.kind == .projects }) else { return [:] }
        return ["domain", "Type", "Phase"].reduce(into: [:]) { result, name in
            guard let field = source.property(named: name) else { return }
            let type = field.definition["type"].display
            result[name] = field.definition[type]["options"].array.compactMap { $0["name"].string }
        }
    }
    func potentialProjectRecord(for idea: IdeaRecord) -> ProjectGraphRecord? {
        graphRecords.first { $0.kind == .projects && ($0.serviceRecordID == idea.id || $0.id == IdeaProjectBridge.recordID(idea.id)) }
    }
    func notionIdeaPromotionStatus(_ idea: IdeaRecord) -> String? {
        guard idea.planning?.potential == .project, let record = potentialProjectRecord(for: idea),
              IdeaProjectBridge.isPotentialRecord(record), let source = graphSource(for: record) else { return nil }
        return IdeaProjectBridge.promotedStatus(record, source: source)
    }
    func deferNotionIdeaPromotion(_ idea: IdeaRecord) {
        guard let record = potentialProjectRecord(for: idea) else { return }
        // Dismiss exactly this observed revision. A later external edit surfaces again.
        TestIsolation.defaults.set(record.editedAt?.timeIntervalSince1970 ?? 0, forKey: "idea.promotion.deferred." + record.id)
        refreshOverview()
    }
    func showsNotionIdeaPromotion(_ idea: IdeaRecord) -> Bool {
        guard notionIdeaPromotionStatus(idea) != nil, let record = potentialProjectRecord(for: idea) else { return false }
        return (TestIsolation.defaults.object(forKey: "idea.promotion.deferred." + record.id) as? Double) != (record.editedAt?.timeIntervalSince1970 ?? 0)
    }

    /// Explicit potential-project saves authorize only these graph properties. No
    /// unrelated graph drafts, uploads, archives or incoming metadata are sent/applied.
    func synchronizePotentialIdeaProjects(only serviceID: String? = nil) async {
        guard !graphBusy, !NotionGraphConfiguration.disabled().contains(.projects), let source = graphSources.first(where: { $0.kind == .projects }) else { return }
        graphBusy = true
        defer { graphBusy = false; reloadProjectGraph() }
        do {
            let store = try ProjectGraphStore(database: database)
            var records = try await Task.detached(priority: .utility) { try store.records() }.value
            for idea in serviceIdeasByPath.values where idea.planning?.potential == .project && (serviceID == nil || serviceID == idea.id) {
                guard let details = idea.planning?.project, details.automaticNotionSync,
                      let relative = workspaceRelativePath(for: URL(fileURLWithPath: idea.canonicalPath)),
                      relative.hasPrefix("Ideas/"), relative.split(separator: "/").count == 2 else { continue }
                do {
                    let existing = try IdeaProjectBridge.existing(serviceID: idea.id, path: idea.canonicalPath, records: records, source: source)
                    // Service reads can lag the acknowledged move. A stale idea
                    // projection must never undo a project's graph binding/path.
                    if existing?.localProjectID != nil { continue }
                    // Never create a look-alike of an unlinked page with the same title.
                    if existing?.pageID == nil, let clash = IdeaProjectBridge.unlinkedTitleMatch(title: idea.title, records: records, source: source) {
                        var held = try IdeaProjectBridge.applying(serviceID: idea.id, title: idea.title, path: idea.canonicalPath, details: details,
                            tags: idea.tags, ratings: idea.planning?.ratings ?? [:], to: existing, source: source)
                        held.error = "Notion already has a project named “\(clash.title)” without a Local Directory. To link it, set its Local Directory to \(idea.canonicalPath) in Notion; or rename this idea to create a separate project."
                        if existing != held { try store.save(held) }
                        records.removeAll { $0.id == held.id }; records.append(held)
                        continue
                    }
                    var record = try IdeaProjectBridge.applying(serviceID: idea.id, title: idea.title, path: idea.canonicalPath, details: details,
                        tags: idea.tags, ratings: idea.planning?.ratings ?? [:], to: existing, source: source)
                    if existing != record { try store.save(record) }
                    records.removeAll { $0.id == record.id }; records.append(record)
                    guard !TestIsolation.isActive, let token = SecretStore.read(), IdeaProjectBridge.canAutomaticallySend(record, source: source) else { continue }
                    let fieldIDs = Set((record.serviceSnapshot ?? [:]).keys)
                    // An ambiguous create is deliberately never repeated by the existing
                    // sync coordinator. A human can recover the page in Sync Center.
                    let dirty = record.pageID == nil || record.changes.contains { $0.state == .outgoing && fieldIDs.contains($0.id) }
                    guard dirty else { continue }
                    let coordinator = NotionProjectSync(store: store, client: NotionClient(token: token))
                    try await coordinator.push(ids: [record.id], reviewed: [record], fields: record.pageID == nil ? nil : [record.id: fieldIDs])
                    record = try store.record(id: record.id) ?? record
                    record.error = nil; try store.save(record)
                } catch {
                    if var pending = try? IdeaProjectBridge.existing(serviceID: idea.id, path: idea.canonicalPath, records: try store.records(), source: source) {
                        pending.error = error.localizedDescription; try? store.save(pending)
                    }
                    statusMessage = "Idea saved locally. Notion needs attention: " + error.localizedDescription
                }
            }
            // Retry only the exact field values authorized by the completed move.
            let promoted = try await Task.detached(priority: .utility) { try store.records().filter { $0.kind == .projects && $0.serviceRecordID != nil && $0.localProjectID != nil } }.value
            for record in promoted {
                let key = "ideaPromotionOutgoing:" + record.id
                guard let captured = try store.read(key, as: [String: ProjectJSON].self), !captured.isEmpty,
                      captured.allSatisfy({ record.local[$0.key]?.comparable == $0.value.comparable }),
                      !TestIsolation.isActive, let token = SecretStore.read() else { continue }
                if record.pageID == nil {
                    let allowed = Set((record.serviceSnapshot ?? [:]).keys).union(captured.keys)
                    guard Set(record.local.keys).isSubset(of: allowed), (record.pendingUploads ?? []).isEmpty, !record.archiveRequested else { continue }
                }
                do {
                    try await NotionProjectSync(store: store, client: NotionClient(token: token)).push(ids: [record.id], reviewed: [record], fields: record.pageID == nil ? nil : [record.id: Set(captured.keys)])
                    try store.write(key, [String: ProjectJSON]())
                } catch { var failed = try store.record(id: record.id) ?? record; failed.error = error.localizedDescription; try store.save(failed) }
            }
        } catch { statusMessage = "Idea saved locally; Notion sync is pending: " + error.localizedDescription }
    }

    func verifyPotentialIdeaPromotion(_ id: UUID) async throws {
        guard let commands = widgetCommands,
              let reviewed = try commands.value("idea-promotion-notion-review:" + id.uuidString, as: ProjectGraphRecord.self) else { return }
        let store = try ProjectGraphStore(database: database)
        guard let source = graphSources.first(where: { $0.id == reviewed.sourceID }),
              let current = try store.record(id: reviewed.id), current.local == reviewed.local,
              current.pageID == reviewed.pageID else { throw MobilePlanningFiles.Error.conflict }
        if let pageID = reviewed.pageID, !TestIsolation.isActive {
            guard let token = SecretStore.read() else { throw NotionClient.Failure.noCredentials }
            let client = NotionClient(token: token)
            let page = try await client.completeProperties(try await client.graphRequest("pages/" + pageID))
            try store.ingest(pages: [page], source: source)
        }
        guard let fresh = try store.record(id: reviewed.id), fresh.remote.mapValues(\.comparable) == reviewed.remote.mapValues(\.comparable),
              !fresh.remoteArchived else { throw MobilePlanningFiles.Error.conflict }
    }

    /// Runs after the journaled rename and before the receipt is marked applied. The
    /// same graph record/page is rebound; its latest remote status is retained.
    func finishPotentialIdeaPromotion(serviceID: String?, project: ProjectRecord, destination: URL) async throws {
        guard let serviceID else { return }
        let store = try ProjectGraphStore(database: database)
        guard var record = try store.records().first(where: { $0.kind == .projects && $0.serviceRecordID == serviceID }),
              let source = graphSources.first(where: { $0.id == record.sourceID }) else { return }
        record.localProjectID = project.id; record.localPath = destination.canonicalPath
        var outgoing: [String: ProjectJSON] = [:]
        if let field = source.property(named: "Status") {
            let remote = record.remote[field.id]
            if let remote, !remote.display.isEmpty, ProjectViewQuery.normalize(remote.display) != "idea" {
                record.local[field.id] = remote; record.baseline[field.id] = remote
                var metadata = projectStore.metadata(for: project.id); metadata.status = remote.display
                projectStore.setMetadata(metadata, for: project.id)
            } else {
                record.set("Status", value: ProjectJSON(["name": "Queued"]), source: source)
                outgoing[field.id] = record.local[field.id]
            }
        }
        if let field = source.property(named: "Local Directory") {
            let value: ProjectJSON = field.definition["type"].display == "url" ? .string(destination.absoluteString) : ProjectServiceBridge.text(destination.canonicalPath)
            record.set("Local Directory", value: value, source: source)
            outgoing[field.id] = record.local[field.id]
        }
        // Save recovery intent before the binding. Repeating this stage is safe.
        try store.write("ideaPromotionOutgoing:" + record.id, outgoing)
        try store.save(record)
        if let pageID = record.pageID { try projectStore.setExplicitNotionPageID(pageID, for: project.id) }
        await refreshProjectGraph()
        // Local success remains valid if Notion is offline. The outgoing directory
        // edit and any error are durable and the next pass retries the same page.
    }
}
