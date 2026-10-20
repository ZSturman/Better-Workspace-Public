import Foundation
import BetterWorkspaceCore

struct ProjectSyncReview: Identifiable {
    enum Direction { case incoming, outgoing }
    let id = UUID()
    let presenterID: String
    let direction: Direction
    let records: [ProjectGraphRecord]
    let plan: ProjectSyncReviewPlan
    var createProjectOnly = false
}

extension AppModel {
    /// Prepare only the selected project's page. No general sync preparation runs
    /// here: it can queue service records and unrelated work.
    func reviewNewProjectInNotion(_ item: WorkspaceItem) async throws {
        guard !graphBusy else { throw NotionProjectSync.SyncError.busy }
        guard hasNotionToken else { throw NotionClient.Failure.noCredentials }
        await refreshProjectGraph()
        guard let local = projectRecord(for: item),
              graphSources.contains(where: { $0.kind == .projects }) else {
            throw NotionProjectSync.SyncError.unsupported("Configure and check the Projects source in Notion settings first.")
        }
        let matches = graphRecords.filter { record in
            guard record.kind == .projects, record.pageID != nil, let source = graphSource(for: record) else { return false }
            return record.localProjectID == local.id || record.value("Local Directory", source: source).display == local.lastPath
        }
        guard matches.count <= 1 else {
            throw NotionProjectSync.SyncError.unsupported("Several Notion pages declare this directory. Resolve the duplicate links in Sync Center before adding this project.")
        }
        try bindGraphProjects(onlyLocalID: local.id)
        await refreshProjectGraph()
        if let linked = graphProject(for: item), let url = linked.pageID.flatMap({ URL(string: "https://www.notion.so/" + $0) }) {
            open(url); return
        }
        // Existing drafts win. Newly discovered folders need their first local graph.
        if graphProject(for: item) == nil {
            queueProjectGraphEdits(for: item)
            await refreshProjectGraph()
        }
        guard let record = graphProject(for: item), record.pageID == nil, !record.archiveRequested else {
            throw NotionProjectSync.SyncError.unsupported("The project could not be prepared. Check its local details and Notion source.")
        }
        var preview = record
        preview.local = record.local.filter { !["relation", "files"].contains($0.value["type"].string ?? "") }
        preview.pendingUploads = nil
        graphSyncReview = .init(presenterID: "newProject", direction: .outgoing, records: [record],
            plan: ProjectSyncReviewPlan(records: [preview], allRecords: graphRecords, sources: graphSources), createProjectOnly: true)
    }

    /// One worker prepares an immutable graph away from the UI. Requests arriving
    /// during a read invalidate it, so an older snapshot cannot undo a newer save.
    func reloadProjectGraph() {
        graphReloadGeneration += 1
        guard graphReloadTask == nil else { return }
        graphReloadTask = Task { [weak self] in
            guard let self else { return }
            defer { self.graphReloadTask = nil }
            while !Task.isCancelled {
                let generation = self.graphReloadGeneration
                let database = self.database
                let result = await Task.detached(priority: .utility) {
                    Result { try ProjectGraphStore(database: database).snapshot() }
                }.value
                guard generation == self.graphReloadGeneration else { continue }
                switch result {
                case .success(let snapshot): self.publishProjectGraph(snapshot)
                case .failure(let error): self.lastError = error.localizedDescription
                }
                return
            }
        }
    }

    /// Reviewed actions must use the completed snapshot, never a queued reload.
    func refreshProjectGraph() async {
        reloadProjectGraph()
        await graphReloadTask?.value
    }

    private func publishProjectGraph(_ snapshot: ProjectGraphSnapshot) {
        graphRecords = snapshot.records
        graphIndex = snapshot.index
        graphMediaIndex = snapshot.mediaIndex
        graphSyncIndex = snapshot.syncIndex
        graphSources = snapshot.sources
        graphProjectsByLocalID = snapshot.projectsByLocalID
        graphProjectsByPageID = snapshot.projectsByPageID
        graphSourcesByID = snapshot.sourcesByID
        graphIncomingIDs = snapshot.incomingIDs
        graphOutgoingIDs = snapshot.outgoingIDs
        graphReport = snapshot.report
        syncTriage = snapshot.triage
        syncDeferred = snapshot.deferred
        syncFailures = snapshot.failures
        syncReport = snapshot.syncReport
        syncActionReport = snapshot.actionReport
        syncLastChangesReport = snapshot.lastChangesReport
        graphRevision += 1
    }
    func graphSource(for record: ProjectGraphRecord) -> ProjectGraphSource? { _ = graphRevision; return graphSourcesByID[record.sourceID] }
    func graphProject(for item: WorkspaceItem) -> ProjectGraphRecord? {
        guard let local = projectRecord(for: item) else { return nil }
        _ = graphRevision
        return graphProjectsByLocalID[local.id] ?? local.notionPageID.flatMap { graphProjectsByPageID[ProjectGraph.normalizedID($0)] }
    }
    func graphRelated(to project: ProjectGraphRecord) -> [ProjectGraphRecord] {
        return graphIndex.related(to: project)
    }
    /// Browsing media does not acknowledge incoming fields or queue remote writes.
    func graphMediaRelated(to project: ProjectGraphRecord) -> [ProjectGraphRecord] {
        _ = graphRevision
        return graphMediaIndex.related(to: project)
    }
    func startProjectSyncChecks() {
        reloadProjectGraph()
        guard !TestIsolation.isActive else { return }
        graphCheckTask?.cancel()
        graphCheckTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refreshBackgroundService()
                await self.refreshProjectGraph()
                if self.notionAutoSync {
                    await self.runAutoSyncPass()
                } else if SecretStore.hasNotionToken && (TestIsolation.defaults.object(forKey: "projectGraphBackgroundChecks") as? Bool ?? true) && (self.graphReport?.checkedAt.map { Date().timeIntervalSince($0) >= 900 } ?? true) {
                    await self.checkProjectGraph()
                }
                await self.synchronizePotentialIdeaProjects()
                // Automatic sync looks every five minutes; a check-only Mac every fifteen.
                do { try await Task.sleep(for: .seconds(self.notionAutoSync ? 300 : 900)) } catch { return }
            }
        }
    }
    func checkProjectGraph(forceFull: Bool = false) async {
        guard !graphBusy else { syncFeedback = "A sync is already running."; return }
        graphBusy = true; syncActivity = "Checking Notion for changes…"
        defer { graphBusy = false; syncActivity = nil }
        guard let token = SecretStore.read() else { showSyncFailure("Add a Notion token in Settings first."); return }
        do {
            let seeds = NotionGraphConfiguration.seeds()
            guard !seeds.isEmpty else { throw NotionProjectSync.SyncError.unsupported("Configure the Projects database in Settings → Integrations → Notion.") }
            let coordinator = NotionProjectSync(store: try ProjectGraphStore(database: database), client: NotionClient(token: token))
            graphReport = try await coordinator.check(seeds: seeds, disabled: NotionGraphConfiguration.disabled(), forceFull: forceFull)
            await refreshProjectGraph()
            try bindGraphProjects()
            await refreshProjectGraph()
            bindExistingGraphWork()
            await refreshProjectGraph()
            syncFeedbackIsError = graphReport?.failures.isEmpty == false
            syncFeedback = syncFeedbackIsError ? "Check finished with source errors. Previous values were kept." : "Checked \(graphReport?.counts.count ?? 0) Notion sources. Changes are ready for review."
            statusMessage = (graphReport?.failures.isEmpty == false) ? "Notion check has source failures. Review Settings → Integrations → Notion; previous snapshots are retained." : "Checked \(graphReport?.counts.count ?? 0) Notion sources; changes are ready for review."
        } catch { showSyncFailure(error.localizedDescription) }
    }
    func bindGraphProjects(onlyLocalID: String? = nil) throws {
        let store = try ProjectGraphStore(database: database)
        for var graph in graphRecords where graph.kind == .projects && graph.pageID != nil {
            guard let source = graphSource(for: graph) else { continue }
            let pageID = graph.pageID.map(NotionImport.normalizedID)
            let declaredPath = graph.value("Local Directory", source: source).display
            let local = projectStore.allRecords().first { $0.notionPageID.map(NotionImport.normalizedID) == pageID }
                ?? projectStore.allRecords().first { !$0.hasNotionLink && !$0.lastPath.isEmpty && $0.lastPath == declaredPath }
            if let local {
                guard onlyLocalID == nil || local.id == onlyLocalID else { continue }
                if graph.local.isEmpty && graph.baseline.isEmpty {
                    let metadata = projectStore.metadata(for: local.id), description = projectStore.description(for: local.id)
                    var owned: [String: ProjectJSON] = [:]
                    func text(_ name: String, _ value: String?) { if let value, !value.isEmpty { owned[name] = ProjectServiceBridge.text(value) } }
                    text("one liner", description.oneLiner); text("summary", description.summary); text("status details", metadata.statusDetail)
                    for (name, value) in [("domain", metadata.domain), ("Status", metadata.status), ("Phase", metadata.phase), ("Completion Model", metadata.completionModel), ("Maintenance Cadence", metadata.maintenanceCadence)] { if let value, !value.isEmpty { owned[name] = ProjectJSON(["name": value]) } }
                    for (name, values) in [("Current Work", metadata.currentWork), ("Next Work", metadata.nextWork), ("Recent Work", metadata.recentWork), ("Work Mode", metadata.workModes), ("Blocked By", metadata.blockers), ("Type", (metadata.projectType ?? "").components(separatedBy: ", ").filter { !$0.isEmpty })] where !values.isEmpty { owned[name] = ProjectJSON(values.map { ["name": $0] }) }
                    for (name, date) in [("started at", metadata.startedAt), ("last update at", metadata.lastUpdateAt)] { if let date { owned[name] = ProjectJSON(["start": ISO8601DateFormatter().string(from: date)]) } }
                    for metric in MetricDefinition.all { if let rating = projectStore.ratings(for: local.id)[metric.id] { owned[metric.displayName] = .number(Double(rating)) } }
                    if let item = projects().first(where: { projectRecord(for: $0)?.id == local.id }), !tags(for: item).isEmpty { owned["tags"] = ProjectJSON(tags(for: item).map { ["name": $0.name] }) }
                    graph.seedInitialLocalState(owned, source: source)
                }
                graph.localProjectID = local.id; graph.localPath = local.lastPath
                if let id = graph.pageID { try projectStore.setExplicitNotionPageID(id, for: local.id) }
                try store.save(graph)
            }
        }
    }
    func reviewProjectSync(_ direction: ProjectSyncReview.Direction, project: ProjectGraphRecord? = nil, presenterID: String = "settings") {
        Task { @MainActor in
            await refreshProjectGraph()
            do { try bindGraphProjects(); bindExistingGraphWork(); await queueServiceProjectGraph(); await refreshProjectGraph() } catch { lastError = error.localizedDescription }
            let scope = project.map { Set(graphSyncIndex.related(to: $0).map(\.id) + [$0.id]) }
            let records = graphRecords.filter { record in
                guard scope == nil || scope!.contains(record.id) else { return false }
                return direction == .incoming ? (record.baseline.isEmpty && !record.remote.isEmpty) || record.remoteArchived != (record.acknowledgedArchived ?? false) || record.changes.contains { [.incoming, .conflict].contains($0.state) }
                    : record.archiveRequested || record.serviceAcknowledgementPending == true || !(record.pendingUploads ?? []).isEmpty || record.pageID == nil || record.changes.contains { [.outgoing, .conflict].contains($0.state) }
            }
            graphSyncReview = .init(presenterID: presenterID, direction: direction, records: records, plan: ProjectSyncReviewPlan(records: records, allRecords: graphRecords, sources: graphSources))
        }
    }
    func applyProjectSync(_ review: ProjectSyncReview, selected: Set<String>, resolutions: [String: [String: Bool]]) async throws {
        guard !graphBusy, let token = SecretStore.read() else { throw NotionClient.Failure.noCredentials }
        graphBusy = true; defer { graphBusy = false; reloadProjectGraph() }
        let store = try ProjectGraphStore(database: database)
        let coordinator = NotionProjectSync(store: store, client: NotionClient(token: token))
        // Sending ideas or work logs takes over the service's Notion writers; receiving does not.
        if review.direction == .outgoing, review.records.contains(where: { selected.contains($0.id) && [.ideas, .workLogs].contains($0.kind) }) {
            try await claimServiceProjectGraphWriter()
            for var record in review.records where selected.contains(record.id) && record.serviceRecordID != nil { record.serviceAcknowledgementPending = true; try store.save(record) }
        }
        if review.direction == .incoming { try await coordinator.pull(ids: selected, reviewed: review.records, resolutions: resolutions) }
        else { try await coordinator.push(ids: selected, reviewed: review.records, resolutions: resolutions, createProjectsOnly: review.createProjectOnly) }
        try await applyLocalEffects(of: selected, previous: review.records, createFiles: true)
    }

    /// What this Mac does once records have been received or sent: service
    /// acknowledgements, project metadata and tags, and the work files of tasks,
    /// features and milestones. `createFiles` is false for automatic passes, which
    /// update a work file that exists but never add one to the Workspace on their own.
    func applyLocalEffects(of selected: Set<String>, previous: [ProjectGraphRecord], createFiles: Bool) async throws {
        await refreshProjectGraph()
        try await acknowledgeServiceGraphRecords(selected)
        await refreshProjectGraph()
        applyingGraphToLocal = true; defer { applyingGraphToLocal = false }
        for record in graphRecords where selected.contains(record.id) && record.kind == .projects {
            guard let localID = record.localProjectID, let source = graphSource(for: record), let page = record.notionPage(source: source) else { continue }
            if let pageID = record.pageID { try projectStore.setExplicitNotionPageID(pageID, for: localID) }
            projectGraphValuesToLocal(record)
            if let item = projects().first(where: { projectRecord(for: $0)?.id == localID }) {
                let incomingTags = Set(page.choices("tags"))
                let prior = previous.first { $0.id == record.id }
                let previousNames = Set(source.property(named: "tags").map { property in (prior?.baseline[property.id] ?? .null)["multi_select"].array.compactMap { $0["name"].string } } ?? [])
                for tag in tags(for: item) where previousNames.contains(tag.name) && !incomingTags.contains(tag.name) { unassign(tag: tag, from: item) }
                for name in incomingTags { if let tag = createTag(named: name) { assign(tag: tag, to: item) } }
            }
        }
        for record in graphRecords where selected.contains(record.id) && [.features, .milestones, .tasks].contains(record.kind) {
            try await materializeGraphWork(record, createFiles: createFiles)
        }
        refreshOverview()
    }
    func saveGraphRecord(_ record: ProjectGraphRecord, replacingUploads: Bool = false) {
        do {
            let store = try ProjectGraphStore(database: database)
            var draft = record
            if let current = try store.record(id: record.id) {
                draft.pageID = current.pageID; draft.baseline = current.baseline; draft.remote = current.remote
                draft.editedAt = current.editedAt
                if !replacingUploads { draft.pendingUploads = current.pendingUploads }
                draft.serviceRecordID = current.serviceRecordID; draft.serviceSnapshot = current.serviceSnapshot; draft.serviceAcknowledgementPending = current.serviceAcknowledgementPending
                draft.ambiguousCreate = current.ambiguousCreate; draft.remoteArchived = current.remoteArchived; draft.acknowledgedArchived = current.acknowledgedArchived
            }
            try store.save(draft)
            if let index = graphRecords.firstIndex(where: { $0.id == draft.id }) { graphRecords[index] = draft }
            else { graphRecords.append(draft) }
            if let localID = draft.localProjectID { graphProjectsByLocalID[localID] = draft }
            if draft.kind == .projects, let pageID = draft.pageID { graphProjectsByPageID[ProjectGraph.normalizedID(pageID)] = draft }
            reloadProjectGraph()
            if draft.kind == .projects { projectGraphValuesToLocal(draft) }
            // A local edit is picked up by the next automatic pass, if that is on.
            requestAutoSync()
        }
        catch { lastError = error.localizedDescription }
    }
    private func projectGraphValuesToLocal(_ record: ProjectGraphRecord) {
        guard let localID = record.localProjectID, let source = graphSource(for: record), let page = record.notionPage(source: source) else { return }
        let values = ProjectMetadataImport.values(from: page)
        let applied = ProjectMetadataImport.applying(ProjectMetadataImport.suppliedFields(propertyNames: Set(source.schema.object.keys.filter { source.property(named: $0).map { record.local[$0.id] != nil } ?? false }), relationNames: Set(source.schema.object.keys.filter { source.property(named: $0)?.definition["type"].string == "relation" })), values: values,
            to: projectStore.metadata(for: localID), description: projectStore.description(for: localID), portfolioDetails: projectStore.portfolioDetails(for: localID))
        projectStore.setMetadata(applied.metadata, for: localID); projectStore.setDescription(applied.description, for: localID); projectStore.setPortfolioDetails(applied.portfolioDetails, for: localID)
        if let field = source.property(named: "related projects"), record.local[field.id] != nil {
            let ids = Set(values.relatedNotionPageIDs.compactMap { graphProjectsByPageID[ProjectGraph.normalizedID($0)]?.localProjectID })
            projectStore.setRelatedProjectIDs(ids, for: localID)
        }
        if let field = source.property(named: "tags"), record.local[field.id] != nil,
           let item = projects().first(where: { projectRecord(for: $0)?.id == localID }) {
            let wasApplying = applyingGraphToLocal; applyingGraphToLocal = true
            defer { applyingGraphToLocal = wasApplying }
            let desired = Set(page.choices("tags"))
            for tag in tags(for: item) where !desired.contains(tag.name) { unassign(tag: tag, from: item) }
            for name in desired { if let tag = createTag(named: name) { assign(tag: tag, to: item) } }
        }
        for metric in MetricDefinition.all {
            guard let property = source.property(named: metric.displayName), property.definition["type"].string == "number", let value = record.local[property.id] else { continue }
            let rating: Int?
            if case .number(let raw) = value["number"] { rating = Int(raw) } else { rating = nil }
            projectStore.setRating(rating, metricID: metric.id, for: localID)
        }
        reloadProjectRatings()
    }
    func queueProjectGraphEdits(for item: WorkspaceItem, fields: Set<String>? = nil) {
        guard let local = projectRecord(for: item), let source = graphSources.first(where: { $0.kind == .projects }) else { return }
        var graph = graphProject(for: item) ?? .init(pageID: local.notionPageID, sourceID: source.id, kind: .projects)
        graph.localProjectID = local.id; graph.localPath = local.lastPath
        let metadata = projectStore.metadata(for: local.id), description = projectStore.description(for: local.id)
        func text(_ value: String?) -> ProjectJSON { ProjectJSON((value ?? "").isEmpty ? [] : [["type": "text", "text": ["content": value ?? ""]]]) }
        func includes(_ name: String) -> Bool { fields == nil || fields!.contains(name) }
        func setText(_ name: String, _ value: String?) {
            // Retain mentions, links and annotations whenever the user did not change the text.
            if includes(name) && graph.value(name, source: source).display != (value ?? "") { graph.set(name, value: text(value), source: source) }
        }
        if graph.pageID == nil { for (name, definition) in source.schema.object where definition["type"].string == "title" { graph.set(name, value: text(local.name), source: source) } }
        setText("one liner", description.oneLiner)
        setText("summary", description.summary)
        setText("Local Directory", local.lastPath)
        for (name, value) in [("domain", metadata.domain), ("Status", metadata.status), ("Phase", metadata.phase), ("Completion Model", metadata.completionModel), ("Maintenance Cadence", metadata.maintenanceCadence)] where includes(name) {
            graph.set(name, value: value.map { ProjectJSON(["name": $0]) } ?? .null, source: source)
        }
        for (name, values) in [("Current Work", metadata.currentWork), ("Next Work", metadata.nextWork), ("Recent Work", metadata.recentWork), ("Work Mode", metadata.workModes), ("Blocked By", metadata.blockers)] where includes(name) {
            graph.set(name, value: .array(values.map { ProjectJSON(["name": $0]) }), source: source)
        }
        setText("status details", metadata.statusDetail)
        if includes("tags") { graph.set("tags", value: ProjectJSON(tags(for: item).map { ["name": $0.name] }), source: source) }
        if includes("Type") { graph.set("Type", value: ProjectJSON((metadata.projectType ?? "").components(separatedBy: ", ").filter { !$0.isEmpty }.map { ["name": $0] }), source: source) }
        for (name, date) in [("started at", metadata.startedAt), ("last update at", metadata.lastUpdateAt)] where includes(name) {
            let current = graph.value(name, source: source)["date"]
            if let raw = current["start"].string, date == ProjectDates.parse(raw) { continue }
            var value = current.object
            if let date { value["start"] = .string(ISO8601DateFormatter().string(from: date)) }
            graph.set(name, value: date == nil ? .null : .object(value), source: source)
        }
        if includes("related projects") {
            let ids = projectStore.relatedProjectIDs(for: local.id).compactMap { graphProjectsByLocalID[$0].map { $0.pageID ?? $0.id } }
            graph.set("related projects", value: ProjectJSON(ids.map { ["id": $0] }), source: source)
        }
        for metric in MetricDefinition.all where includes(metric.displayName) { graph.set(metric.displayName, value: ratingsByProject[local.id]?[metric.id].map { .number(Double($0)) } ?? .null, source: source) }
        saveGraphRecord(graph)
    }
    func graphPending(_ direction: ProjectSyncReview.Direction, project: ProjectGraphRecord? = nil) -> Int {
        _ = graphRevision
        let scope = project.map { Set(graphSyncIndex.related(to: $0).map(\.id) + [$0.id]) }
        let pending = direction == .incoming ? graphIncomingIDs : graphOutgoingIDs
        return scope.map { pending.intersection($0).count } ?? pending.count
    }
}
