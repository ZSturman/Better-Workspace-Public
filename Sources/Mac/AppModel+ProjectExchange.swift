import Foundation
import AppKit
import BetterWorkspaceCore

/// Workspace Project Exchange v1 (`docs/PROJECT_EXCHANGE.md`). Better Workspace publishes
/// its projects, tasks and idea labels and applies task requests. Finder Workspace
/// Extensions owns project metadata: `ownedMetadata` mirrors its `finder-workspace`
/// folder and sends this app's edits there. Requests here still go through the same store
/// and Notion queue as an editor Save.
@MainActor
final class ProjectExchangeHost {
    static let shared = ProjectExchangeHost()
    let files = ExchangeFiles.standard()
    private var loop: Task<Void, Never>?
    private var observer: NSObjectProtocol?
    private var snapshotObserver: NSObjectProtocol?
    let ownedMetadata = FinderOwnedMetadataMirror()
    private var lastToken = ""
    private var lastPublishedSnapshot: ExchangeSnapshot?
    private var lastWrite = Date.distantPast
    private(set) var lastError: String?
    private(set) var processedCount = 0

    /// Isolated tests and fixtures must never reach the person's exchange folder.
    static var isolated: Bool {
        let environment = ProcessInfo.processInfo.environment
        return TestIsolation.isActive || environment["XCTestConfigurationFilePath"] != nil || NSClassFromString("XCTestCase") != nil
            || ProcessInfo.processInfo.arguments.contains { argument in
                ["uitest", "fixture", "acceptance", "isolated"].contains { argument.lowercased().contains($0) }
            }
    }

    func start(model: AppModel) {
        guard loop == nil, !Self.isolated else { return }
        observer = DistributedNotificationCenter.default().addObserver(
            forName: .init(ExchangeFiles.requestNotification), object: nil, queue: .main) { [weak self, weak model] _ in
            MainActor.assumeIsolated { if let self, let model { Task { await self.processRequests(model: model) } } }
        }
        ownedMetadata.active = true
        snapshotObserver = DistributedNotificationCenter.default().addObserver(
            forName: .init(ExchangeFiles.snapshotNotification), object: FinderOwnedMetadata.sourceID, queue: .main) { [weak self, weak model] _ in
            MainActor.assumeIsolated { if let self, let model { self.ownedMetadata.pass(model: model) } }
        }
        loop = Task { [weak self, weak model] in
            while !Task.isCancelled {
                guard let self, let model else { return }
                await self.processRequests(model: model)
                self.ownedMetadata.pass(model: model)
                self.publishIfNeeded(model: model)
                try? await Task.sleep(for: .seconds(4))
            }
        }
    }

    // MARK: Snapshot

    func publishIfNeeded(model: AppModel, force: Bool = false) {
        let token = model.exchangeChangeToken
        guard (force || token != lastToken || Date().timeIntervalSince(lastWrite) > 300),
              model.exchangeListingComplete else { return }
        let snapshot = model.exchangeSnapshot()
        var comparable = snapshot
        if let previous = lastPublishedSnapshot {
            comparable.generatedAt = previous.generatedAt; comparable.expiresAt = previous.expiresAt
        }
        // Rewrite unchanged content only to keep the snapshot from expiring.
        guard force || comparable != lastPublishedSnapshot || Date().timeIntervalSince(lastWrite) > 300 else {
            lastToken = token
            return
        }
        do {
            try files.writeSnapshot(snapshot)
            lastToken = token; lastPublishedSnapshot = snapshot; lastWrite = Date(); lastError = nil
            notifyCompanions()
        } catch { lastError = "Could not publish the project exchange: \(error.localizedDescription)" }
    }

    // MARK: Requests

    private var processing = false
    func processRequests(model: AppModel) async {
        guard !processing else { return }
        processing = true; defer { processing = false }
        // A claim left by an interrupted pass is compared again; equal values are no-ops.
        let ids = files.claimedRequests() + files.pendingRequests()
        guard !ids.isEmpty else { files.pruneReceipts(); return }
        guard model.exchangeListingComplete else { return }
        var changed = false, receipted = false
        for id in ids {
            if files.hasReceipt(id) { files.release(id); _ = files.cancel(id); continue }
            guard let request = files.claimed(id) ?? files.claim(id) else { continue }
            let receipt = await model.applyExchange(request)
            do { try files.finish(receipt); processedCount += 1; receipted = true } catch { lastError = error.localizedDescription }
            changed = changed || receipt.outcome == .applied
        }
        if changed { publishIfNeeded(model: model, force: true) }
        if receipted { notifyCompanions() }
    }

    private func notifyCompanions() {
        DistributedNotificationCenter.default().postNotificationName(.init(ExchangeFiles.snapshotNotification), object: nil, userInfo: nil, deliverImmediately: true)
    }
}

extension AppModel {
    /// A partial listing must never be published: requesters unlink projects it omits.
    var exchangeListingComplete: Bool {
        let area = WorkspaceArea.projects.directoryName
        return workspaceAvailable && workItemsLoaded && itemsByArea[area] != nil
            && !loadingAreas.contains(area) && !unreadableAreas.contains(area)
            && projects().allSatisfy { projectRecord(for: $0) != nil }
    }

    /// Changes when anything the snapshot shows may have changed.
    var exchangeChangeToken: String {
        let latestWork = workItems.compactMap(\.modifiedAt).max()?.timeIntervalSince1970 ?? 0
        return "\(projectViewRevision)|\(graphRevision)|\(workItems.count)|\(latestWork)|\(notionSyncState)|\(serviceIdeasLoaded)"
    }

    private var exchangeProjectsSource: ProjectGraphSource? { graphSources.first { $0.kind == .projects } }

    private func exchangeOptions(_ property: String) -> (kind: String?, options: [String]) {
        guard let definition = exchangeProjectsSource?.property(named: property)?.definition,
              let kind = definition["type"].string else { return (nil, []) }
        return (kind, definition[kind]["options"].array.compactMap { $0["name"].string })
    }

    func exchangeSnapshot() -> ExchangeSnapshot {
        let metadata = projectStore.allMetadata()
        let scoring = scoringPreferences()
        var ideas = exchangeIdeaFolders(scoring: scoring)
        let root = workspace.root
        let items = projects()
        var byRelative: [String: String] = [:], byPath: [String: String] = [:]
        var records: [(WorkspaceItem, ProjectRecord)] = []
        for item in items {
            guard let record = projectRecord(for: item) else { continue }
            records.append((item, record))
            byPath[item.url.canonicalPath] = record.id
            if let relative = workspaceRelativePath(for: item.url) { byRelative[relative] = record.id }
        }
        var tasksByProject: [String: [WorkItem]] = [:]
        for task in workItems where task.kind == .task {
            guard let raw = task.projectPath else { continue }
            let relative = MobileWorkspacePath.normalizedRelative(raw)
            if let id = relative.flatMap({ byRelative[$0] }) {
                if task.isOpen { tasksByProject[id, default: []].append(task) }
                continue
            }
            guard raw.hasPrefix("/") || relative?.hasPrefix("Ideas/") == true else { continue }
            let path = raw.hasPrefix("/") ? URL(fileURLWithPath: raw).canonicalPath
                : relative.map { root.appendingPathComponent($0).canonicalPath }
            if let path, let count = ideas?[path].map({ $0.openTaskCount ?? 0 }) {
                ideas?[path]?.openTaskCount = count + (task.isOpen ? 1 : 0)
            } else if task.isOpen, let id = path.flatMap({ byPath[$0] }) {
                tasksByProject[id, default: []].append(task)
            }
        }
        let projects = records.map { item, record -> ExchangeProject in
            let values = metadata[record.id] ?? ProjectMetadata()
            let open = (tasksByProject[record.id] ?? []).sorted {
                if $0.status != $1.status { return $0.status == .inProgress }
                if $0.dueDate != $1.dueDate { return ($0.dueDate ?? .distantFuture) < ($1.dueDate ?? .distantFuture) }
                if $0.stage != $1.stage { return $0.stage.rank < $1.stage.rank }
                if $0.priority != $1.priority { return $0.priority.rank < $1.priority.rank }
                return $0.id < $1.id
            }
            func bounded(_ list: [String]) -> [String] { list.prefix(8).map { String($0.prefix(200)) } }
            return ExchangeProject(
                id: record.id, path: item.url.canonicalPath, name: item.displayTitle, identityKey: record.identityKey,
                notionLinked: record.hasNotionLink, status: values.status, phase: values.phase, domain: values.domain,
                maintenanceCadence: values.maintenanceCadence, completionModel: values.completionModel,
                projectType: values.projectType, statusDetail: values.statusDetail.map { String($0.prefix(500)) },
                portfolioPriority: values.portfolioPriority, blockers: bounded(values.blockers),
                currentWork: bounded(values.currentWork), nextWork: bounded(values.nextWork), lastUpdateAt: values.lastUpdateAt,
                openTaskCount: open.count,
                tasks: open.prefix(5).map { task in
                    ExchangeTask(id: task.id, revision: workItemService.connectedRevision(task), title: String(task.title.prefix(200)),
                                 status: task.status.rawValue, stage: task.stage.rawValue, priority: task.priority.rawValue, dueDate: task.dueDate)
                }, score: score(for: item, preferences: scoring)?.projectScore)
        }
        let status = exchangeOptions("Status"), phase = exchangeOptions("Phase"), domain = exchangeOptions("domain")
        func merged(_ options: [String], _ used: [String?]) -> [String] {
            var seen = Set<String>()
            return (options + used.compactMap(ExchangeText.clean).sorted()).filter { seen.insert($0.lowercased()).inserted }
        }
        let summary: String
        switch notionSyncState {
        case .notConfigured: summary = "Not configured"
        case .syncing: summary = "Synchronizing"
        case .upToDate: summary = "Up to date"
        case .waiting(let count): summary = "\(count) changes waiting"
        case .recovering(let count): summary = "\(count) changes retrying"
        case .attention(let count): summary = "\(count) changes need review"
        case .unavailable(let reason): summary = String(reason.prefix(200))
        }
        return ExchangeSnapshot(
            workspaceRoot: workspace.root.path,
            notion: .init(configured: !graphSources.isEmpty, summary: summary, statusPropertyKind: status.kind),
            statusOptions: merged(status.options, metadata.values.map(\.status)),
            phaseOptions: merged(phase.options, metadata.values.map(\.phase)),
            domainOptions: merged(domain.options, metadata.values.map(\.domain)),
            projects: projects,
            ideaFolders: ideas)
    }

    private func exchangeIdeaFolders(scoring: ProjectScoringPreferences) -> [String: ExchangeIdeaFacts]? {
        let area = WorkspaceArea.ideas.directoryName
        guard serviceIdeasLoaded, !unreadableAreas.contains(area), let items = itemsByArea[area] else { return nil }
        let facts = items.compactMap { item -> (String, ExchangeIdeaFacts)? in
            let path = item.url.canonicalPath
            guard item.isDirectory, let idea = serviceIdeasByPath[path] else { return nil }
            return (path, ExchangeIdeaFacts(domain: idea.planning?.project?.metadata.domain, status: idea.status,
                priority: idea.planning?.priority, score: idea.planning?.score(preferences: scoring).projectScore))
        }
        return Dictionary(facts, uniquingKeysWith: { first, _ in first })
    }

    // MARK: Applying a request

    func applyExchange(_ request: ExchangeRequest) async -> ExchangeReceipt {
        func receipt(_ outcome: ExchangeReceipt.Outcome, _ message: String, conflicts: [ExchangeField] = [], warnings: [String] = []) -> ExchangeReceipt {
            .init(requestID: request.id, projectID: request.projectID, outcome: outcome, message: message, conflicts: conflicts,
                  warnings: warnings, project: exchangeSnapshotProject(id: request.projectID))
        }
        do { try request.validate() } catch { return receipt(.rejected, error.localizedDescription) }
        guard request.task == nil || request.changes.isEmpty else {
            return receipt(.rejected, "Send project details and task changes as separate requests.")
        }
        guard let item = projects().first(where: { projectRecord(for: $0)?.id == request.projectID }),
              let record = projectRecord(for: item) else {
            return receipt(.rejected, "This project is no longer in Better Workspace.")
        }
        guard item.url.canonicalPath == request.projectPath,
              (try? MobilePlanningFiles.resolve(workspaceRelativePath(for: item.url) ?? "", workspace: workspace))?.canonicalPath == item.url.canonicalPath,
              let identity = FileIdentityResolver.identity(of: item.url),
              let recordedIdentity = record.identityKey.flatMap(FileIdentity.init(key:)), identity == recordedIdentity else {
            return receipt(.rejected, "This project moved since Finder last read it.")
        }
        var warnings: [String] = [], applied = false
        if !request.changes.isEmpty {
            let status = exchangeOptions("Status")
            let result = ProjectExchangeMetadata.apply(
                request.changes, to: projectStore.metadata(for: request.projectID),
                statusOptions: status.options + projectStore.allMetadata().values.compactMap(\.status),
                notionStatusOptions: status.options, statusPropertyKind: status.kind)
            if result.plan.outcome == .conflict {
                return receipt(.conflict, "Better Workspace changed \(result.plan.conflicts.map(\.rawValue).joined(separator: ", ")) since Finder last read it. Review the current value and choose again.", conflicts: result.plan.conflicts)
            }
            warnings = result.warnings
            if result.plan.outcome == .applied {
                do { try projectStore.saveMetadata(result.metadata, for: request.projectID) }
                catch { return receipt(.rejected, "Better Workspace couldn’t save the project details. Try again.") }
                applied = true
                if !result.notionFields.isEmpty { queueProjectGraphEdits(for: item, fields: result.notionFields) }
                statusMessage = "Finder updated “\(item.displayTitle)”"
                refreshOverview(); requestMobileCloudSync()
            }
        }
        if let change = request.task {
            guard let status = WorkItemStatus(rawValue: change.status),
                  let task = workItems.first(where: { $0.id == change.taskID && $0.kind == .task }),
                  task.projectPath == workspaceRelativePath(for: item.url) || task.projectPath == item.url.canonicalPath else {
                return receipt(.rejected, "That task is no longer available.")
            }
            let root = workspace.root.standardizedFileURL, path = task.url.standardizedFileURL
            guard path.path.hasPrefix(root.path + "/"), path.resolvingSymlinksInPath().path == path.path else {
                return receipt(.rejected, "That task is outside the Workspace.")
            }
            if task.status != status {
                let service = workItemService, requestID = request.id
                do {
                    let saved = try await Task.detached(priority: .userInitiated) {
                        try service.setConnectedStatus(task, expectedRevision: change.revision, status: status, requestID: requestID)
                    }.value
                    adopt(saved); queueGraphWork(saved); publishConnectedTasks(); applied = true
                } catch {
                    return receipt(.conflict, "The task changed since Finder last read it. Review it and try again.", warnings: warnings)
                }
            }
        }
        guard applied else { return receipt(.unchanged, "Better Workspace already has these values.", warnings: warnings) }
        requestAutoSync()
        return receipt(.applied, "Saved in Better Workspace.", warnings: warnings)
    }

    private func exchangeSnapshotProject(id: String) -> ExchangeProject? { exchangeSnapshot().projects.first { $0.id == id } }
}
