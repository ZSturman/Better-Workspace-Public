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
    func reviewNewProjectInNotion(_ item: WorkspaceItem, presenterID: String = "newProject") async throws {
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
        try await bindGraphProjects(onlyLocalID: local.id)
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
        graphSyncReview = .init(presenterID: presenterID, direction: .outgoing, records: [record],
            plan: ProjectSyncReviewPlan(records: [preview], allRecords: graphRecords, sources: graphSources), createProjectOnly: true)
    }

    /// Identity-only linking: local metadata and pending remote choices are retained.
    func linkExistingNotionProject(_ expected: ProjectGraphRecord, to item: WorkspaceItem) async throws {
        guard !graphBusy, let local = projectRecord(for: item),
              projectStore.record(for: item.url)?.id == local.id else { throw NotionProjectSync.SyncError.stale }
        let store = try ProjectGraphStore(database: database)
        let existing = graphProject(for: item)
        try store.linkLocalProject(local, page: expected, draft: existing?.id == expected.id ? nil : existing, projectStore: projectStore)
        await refreshProjectRecords()
        await refreshProjectGraph()
        statusMessage = "Linked the existing Notion page. Review differences in Sync Center."
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
                // Unchanged content keeps graphRevision, so nothing keyed on it rebuilds.
                case .success(let snapshot) where snapshot.contentID != self.publishedGraphContentID: self.publishProjectGraph(snapshot)
                case .success: break
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
        publishedGraphContentID = snapshot.contentID
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
        syncPolicy = snapshot.policy
        syncHealth = snapshot.health
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
        holdSnapshotFolders()
        adoptFinderNotionPolicyIfConfigured()
        graphCheckTask?.cancel()
        graphCheckTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refreshBackgroundService()
                await self.refreshProjectGraph()
                if self.notionAutoSync {
                    await self.runAutoSyncPass()
                } else if self.hasNotionToken && (TestIsolation.defaults.object(forKey: "projectGraphBackgroundChecks") as? Bool ?? true) && (self.graphReport?.checkedAt.map { Date().timeIntervalSince($0) >= 900 } ?? true) {
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
        guard let token = await Task.detached(priority: .utility, operation: { SecretStore.read(interactive: false) }).value else { showSyncFailure("Add a Notion token in Settings first."); return }
        do {
            let seeds = NotionGraphConfiguration.seeds()
            guard !seeds.isEmpty else { throw NotionProjectSync.SyncError.unsupported("Configure the Projects database in Settings → Integrations → Notion.") }
            let coordinator = NotionProjectSync(store: try ProjectGraphStore(database: database), client: NotionClient(token: token))
            graphReport = try await coordinator.check(seeds: seeds, disabled: NotionGraphConfiguration.disabled(), forceFull: forceFull)
            await refreshProjectGraph()
            try await bindGraphProjects()
            await refreshProjectGraph()
            await bindExistingGraphWork()
            await refreshProjectGraph()
            syncFeedbackIsError = graphReport?.failures.isEmpty == false
            syncFeedback = syncFeedbackIsError ? "Check finished with source errors. Previous values were kept." : "Checked \(graphReport?.counts.count ?? 0) Notion sources. Changes are ready for review."
            statusMessage = (graphReport?.failures.isEmpty == false) ? "Notion check has source failures. Review Settings → Integrations → Notion; previous snapshots are retained." : "Checked \(graphReport?.counts.count ?? 0) Notion sources; changes are ready for review."
        } catch { showSyncFailure(error.localizedDescription) }
    }
    func bindGraphProjects(onlyLocalID: String? = nil) async throws {
        let database = database, projectStore = projectStore, graphRecords = graphRecords, sources = graphSourcesByID
        let tagsByProject = Dictionary(projects().compactMap { item -> (String, [String])? in
            guard let record = projectRecord(for: item) else { return nil }
            return (record.id, tags(for: item).map(\.name))
        }, uniquingKeysWith: { first, _ in first })
        try await Task.detached(priority: .utility) {
        let store = try ProjectGraphStore(database: database)
        let localRecords = projectStore.allRecords()
        let linkedByPage = Dictionary(localRecords.compactMap { record in
            record.notionPageID.map { (NotionImport.normalizedID($0), record) }
        }, uniquingKeysWith: { first, _ in first })
        let unlinkedByPath = Dictionary(localRecords.lazy.filter { !$0.hasNotionLink && !$0.lastPath.isEmpty }
            .map { ($0.lastPath, $0) }, uniquingKeysWith: { first, _ in first })
        for var graph in graphRecords where graph.kind == .projects && graph.pageID != nil {
            guard let pageID = graph.pageID, let source = sources[graph.sourceID] else { continue }
            let original = graph
            let declaredPath = graph.value("Local Directory", source: source).display
            let local = linkedByPage[NotionImport.normalizedID(pageID)] ?? unlinkedByPath[declaredPath]
            if let local {
                guard onlyLocalID == nil || local.id == onlyLocalID else { continue }
                if local.notionPageID == pageID, graph.localProjectID == local.id, graph.localPath == local.lastPath,
                   !graph.local.isEmpty || !graph.baseline.isEmpty { continue }
                guard try store.record(id: graph.id) == graph else { continue }
                if graph.local.isEmpty && graph.baseline.isEmpty {
                    let metadata = projectStore.metadata(for: local.id), description = projectStore.description(for: local.id)
                    var owned: [String: ProjectJSON] = [:]
                    func text(_ name: String, _ value: String?) { if let value, !value.isEmpty { owned[name] = ProjectServiceBridge.text(value) } }
                    text("one liner", description.oneLiner); text("summary", description.summary); text("status details", metadata.statusDetail)
                    for (name, value) in [("domain", metadata.domain), ("Status", metadata.status), ("Phase", metadata.phase), ("Completion Model", metadata.completionModel), ("Maintenance Cadence", metadata.maintenanceCadence)] { if let value, !value.isEmpty { owned[name] = ProjectJSON(["name": value]) } }
                    for (name, values) in [("Current Work", metadata.currentWork), ("Next Work", metadata.nextWork), ("Recent Work", metadata.recentWork), ("Work Mode", metadata.workModes), ("Blocked By", metadata.blockers), ("Type", (metadata.projectType ?? "").components(separatedBy: ", ").filter { !$0.isEmpty })] where !values.isEmpty { owned[name] = ProjectJSON(values.map { ["name": $0] }) }
                    for (name, date) in [("started at", metadata.startedAt), ("last update at", metadata.lastUpdateAt)] { if let date { owned[name] = ProjectJSON(["start": ISO8601DateFormatter().string(from: date)]) } }
                    let ratings = projectStore.ratings(for: local.id)
                    for metric in MetricDefinition.all { if let rating = ratings[metric.id] { owned[metric.displayName] = .number(Double(rating)) } }
                    if let tags = tagsByProject[local.id], !tags.isEmpty { owned["tags"] = ProjectJSON(tags.map { ["name": $0] }) }
                    graph.seedInitialLocalState(owned, source: source)
                }
                graph.localProjectID = local.id; graph.localPath = local.lastPath
                try projectStore.setExplicitNotionPageID(pageID, for: local.id)
                try database.transaction {
                    guard try store.record(id: graph.id) == original else { return }
                    if graph != original { try store.save(graph) }
                }
                if let oldPath = original.localPath, oldPath != local.lastPath,
                   FileIdentityResolver.identity(of: URL(fileURLWithPath: local.lastPath))?.key == local.identityKey {
                    try store.reflectFinderProjectLocation(projectID: local.id, path: local.lastPath, title: local.name,
                        renamed: URL(fileURLWithPath: oldPath).lastPathComponent != local.name, isIdea: false, source: source)
                }
            }
        }
        }.value
    }
    func reviewProjectSync(_ direction: ProjectSyncReview.Direction, project: ProjectGraphRecord? = nil, presenterID: String = "settings") {
        Task { @MainActor in
            await refreshProjectGraph()
            do { try await bindGraphProjects(); await bindExistingGraphWork(); await queueServiceProjectGraph(); await refreshProjectGraph() } catch { lastError = error.localizedDescription }
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
        guard !graphBusy else { throw NotionProjectSync.SyncError.busy }
        graphBusy = true
        defer { syncApplyingIDs.subtract(selected); graphBusy = false }
        await beginReviewedSync(selected)
        do {
            guard let token = await Task.detached(priority: .userInitiated, operation: { SecretStore.read() }).value else { throw NotionClient.Failure.noCredentials }
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
            await refreshProjectGraph()
        } catch {
            await refreshProjectGraph()
            throw error
        }
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
    func saveGraphRecord(_ record: ProjectGraphRecord, replacingUploads: Bool = false, projectValuesAlreadySaved: Bool = false) {
        do {
            let store = try ProjectGraphStore(database: database)
            var draft = record
            let previous = try store.record(id: record.id)
            if let current = previous {
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
            if draft.kind == .projects && !projectValuesAlreadySaved {
                let before = draft.localProjectID.map { projectStore.metadata(for: $0) }
                projectGraphValuesToLocal(draft)
                // A draft edited here is a person's choice; send only the fields they changed.
                if !applyingGraphToLocal, let localID = draft.localProjectID, let before, let source = graphSource(for: draft) {
                    let edited = Set(ProjectExchangeMetadata.notionNames.compactMap { field, name in
                        previous?.value(name, source: source) == draft.value(name, source: source) ? nil : field
                    })
                    forwardOwnedMetadata(projectID: localID, from: before, to: projectStore.metadata(for: localID), only: edited)
                }
            }
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
        let links = projectStore.portfolioDetails(for: local.id)
        for (aliases, value) in [(["GitHub", "Github", "Repo Link", "Repository URL", "Repository", "Repo"], links.githubURL),
                                  (["Website", "Project URL", "URL", "Live URL", "Download URL"], links.websiteURL)] {
            if let name = aliases.first(where: { source.property(named: $0)?.definition["type"].string == "url" }), fields?.contains(name) == true {
                graph.set(name, value: value.map(ProjectJSON.string) ?? .null, source: source)
            }
        }
        for (name, value) in [("Featured", links.featured), ("In Showcase", links.inShowcase), ("Public", links.isPublic)] where fields?.contains(name) == true {
            if source.property(named: name)?.definition["type"].string == "checkbox" { graph.set(name, value: .bool(value ?? false), source: source) }
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
        // These fields came from committed ProjectStore values. Reapplying the
        // entire older graph would overwrite unrelated newer local properties.
        saveGraphRecord(graph, projectValuesAlreadySaved: true)
    }
    func graphPending(_ direction: ProjectSyncReview.Direction, project: ProjectGraphRecord? = nil) -> Int {
        _ = graphRevision
        let scope = project.map { Set(graphSyncIndex.related(to: $0).map(\.id) + [$0.id]) }
        let pending = direction == .incoming ? graphIncomingIDs : graphOutgoingIDs
        return scope.map { pending.intersection($0).count } ?? pending.count
    }
}

extension AppModel {
    /// Called from successful shallow Finder observations, never a remote status.
    func reflectFinderProjectLocation(_ prior: ProjectRecord, item: WorkspaceItem, isIdea: Bool) async {
        guard let source = graphSources.first(where: { $0.kind == .projects }),
              prior.lastPath != item.url.canonicalPath || prior.name != item.name else { return }
        let database = database, workspace = workspace, projects = projectStore
        do {
            try await Task.detached(priority: .utility) {
                guard let relative = MobileWorkspaceProjection.relativePath(of: item.url, workspace: workspace),
                      try MobilePlanningFiles.resolve(relative, workspace: workspace).canonicalPath == item.url.canonicalPath,
                      let identity = FileIdentityResolver.identity(of: item.url),
                      prior.identityKey.flatMap(FileIdentity.init(key:)) == identity else { throw WorkspaceReplicaError.changed }
                try ProjectGraphStore(database: database).reflectFinderProjectLocation(projectID: prior.id,
                    path: item.url.canonicalPath, title: item.name, renamed: prior.name != item.name, isIdea: isIdea, source: source)
                _ = projects.register(url: item.url)
            }.value
            reloadProjectGraph(); requestAutoSync()
        } catch { lastError = "The Finder change will be checked again: " + error.localizedDescription }
    }
}
