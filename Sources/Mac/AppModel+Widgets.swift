import Foundation
import WidgetKit
import BetterWorkspaceCore

extension AppModel {
    func startWidgetDashboard() {
        if TestIsolation.isActive {
            if let root = TestIsolation.sandbox { widgetCommands = try? WidgetCommandStore(directory: root.appendingPathComponent("Widgets")) }
        } else { widgetCommands = WidgetCommandStore.shared(appGroup: WidgetAppGroup.mac) }
    }

    func widgetProjectAttention() -> [WidgetAttentionItem] {
        let projects = attention.compactMap { item -> WidgetAttentionItem? in
            guard case .project(let path) = item.target,
                  let project = projects().first(where: { $0.url.canonicalPath == path }) else { return nil }
            let id = projectRecord(for: project)?.id ?? workspaceRelativePath(for: project.url) ?? project.id
            return WidgetAttentionItem(id: "project:\(id)", title: item.title, reason: item.explanation, category: .project, route: .project(id))
        }
        // Triage already compared these fields when the graph changed. Widget refresh
        // must not compare thousands of rich-text/relationship values on the main actor again.
        let conflicts = Set(syncTriage.filter { $0.fields.contains { $0.state == .conflict } }.map(\.id))
        let failures = graphRecords.compactMap { record -> WidgetAttentionItem? in
            let conflict = conflicts.contains(record.id)
            guard record.error != nil || conflict || record.ambiguousCreate else { return nil }
            return WidgetAttentionItem(id: "sync:" + record.id, title: record.title,
                reason: record.error ?? (record.ambiguousCreate ? "A previous send needs reconciliation on Mac" : "Local and Notion changes conflict; review them on Mac"),
                category: .failure, route: .attention("sync:" + record.id))
        }
        let ideas = attention.compactMap { item -> WidgetAttentionItem? in
            guard case .idea(let path) = item.target, let relative = workspaceRelativePath(for: URL(fileURLWithPath: path)) else { return nil }
            return WidgetAttentionItem(id: "idea:" + relative, title: item.title, reason: item.explanation, category: .project, route: .idea(relative))
        }
        return failures + ideas + projects
    }

    /// Coalesced with ordinary app refreshes. No new workspace traversal or Notion
    /// check happens here; the app already owns every value in this projection.
    func requestWidgetDashboardPublish() {
        guard workspaceAvailable, !isAwaitingInitialRefresh, workItemsLoaded, let store = widgetCommands else { return }
        widgetPublishingTask?.cancel()
        widgetPublishingTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, let self else { return }
            let projects = self.projects(), folders = self.folders, items = self.workItems
            let root = self.workspace.root, projectRecords = self.projectRecordsByPath
            let ratings = self.ratingsByProject, focusItems = self.overviewFocusItems
            let projectStore = self.projectStore, tagStore = self.tagStore
            let overview = self.overviewDigest()
            let input = await Task.detached(priority: .utility) {
                let rootPath = root.canonicalPath
                func relative(_ url: URL) -> String? {
                    let path = url.path, lexicalRoot = root.path
                    guard path.hasPrefix(lexicalRoot + "/") else { return nil }
                    return MobileWorkspacePath.normalizedRelative(String(path.dropFirst(lexicalRoot.count + 1)))
                }
                let preferences = projectStore.scoringPreferences()
                var entries: [MobileWorkspaceEntry] = []
                for item in projects {
                    guard let path = relative(item.url) else { continue }
                    let record = projectRecords[item.url.canonicalPath]
                    let metadata = record.map { projectStore.metadata(for: $0.id) } ?? ProjectMetadata()
                    let rating = record.map { ProjectScore(ratings: ratings[$0.id] ?? [:], enabledMetricIDs: preferences.enabledMetricIDs,
                        enabledGroups: MetricGroup.allGroups.filter { preferences.enabledGroupIDs.contains($0.id) }, groupWeights: preferences.groupWeights) }
                    let focus = focusItems.first { $0.kind == .projects && $0.path == path }
                    entries.append(MobileWorkspaceEntry(path: path, parentPath: "Projects", name: item.displayTitle,
                        isDirectory: true, revision: 0, modifiedAt: item.contentModifiedAt,
                        projectDetails: MobileProjectDetails(path: path, status: metadata.status, projectID: record?.id,
                            serviceID: record?.watcherID, manualScore: rating?.projectScore, ratingCoverage: rating?.coverage, lastWorked: focus?.lastWorked)))
                }
                entries += folders.map { MobileWorkspaceEntry(path: $0.name, parentPath: nil, name: $0.name, isDirectory: true, revision: 0) }
                let work = items.compactMap { item -> MobileWorkItem? in
                    guard let path = relative(item.url) else { return nil }
                    let projectPath = item.projectPath.map { raw in
                        raw.hasPrefix(rootPath + "/") ? String(raw.dropFirst(rootPath.count + 1)) : raw
                    }
                    return MobileWorkItem(id: item.id, path: path, title: item.title, kind: item.kind, status: item.status,
                        stage: item.stage, priority: item.priority, projectPath: projectPath, dueDate: item.dueDate, revision: 0,
                        tagIDs: Set(tagStore.tags(for: item.url).map(\.id)), actionMetadata: item.actionMetadata,
                        dependencyIDs: item.dependencyIDs, featureIDs: item.featureIDs, milestoneIDs: item.milestoneIDs,
                        createdAt: item.createdAt, modifiedAt: item.modifiedAt, completedAt: item.completedAt, importedNotionPageID: item.importedNotionPageID)
                }
                return MobileWorkspaceSnapshot(entries: entries, workItems: work, overview: overview)
            }.value
            guard !Task.isCancelled else { return }
            var snapshot = await Task.detached(priority: .utility) { WorkspaceDashboardSnapshot.make(from: input) }.value
            guard !Task.isCancelled else { return }
            snapshot.focusItems = self.overviewFocusItems
            if self.ingestScannedOnce && !self.ingestStalled {
                snapshot.captures = self.ingestItems.filter { $0.state == .pending }.prefix(30).map {
                    DashboardCapture(name: $0.url.lastPathComponent, modified: $0.item.rawModifiedAt ?? $0.capturedAt)
                }
                snapshot.captureCount = self.pendingIngestCount
                snapshot.captureUpdatedAt = Date()
            } else if let previous = DashboardWidgetStore.load(directory: store.directory) {
                snapshot.captures = previous.captures; snapshot.captureCount = previous.captureCount; snapshot.captureUpdatedAt = previous.captureUpdatedAt
            }
            if let message = self.lastError {
                snapshot.attention.insert(.init(id: "app-error", title: "Workspace needs attention", reason: message, category: .failure, route: .attention("failure")), at: 0)
            }
            let value = snapshot
            do {
                let changed = try await Task.detached(priority: .utility) {
                    try store.reconcile(value)
                    if var existing = DashboardWidgetStore.load(directory: store.directory) {
                        existing.updatedAt = value.updatedAt; existing.captureUpdatedAt = value.captureUpdatedAt
                        if existing == value { return false }
                    }
                    try DashboardWidgetStore.save(value, directory: store.directory); return true
                }.value
                if changed && !TestIsolation.isActive { WidgetCenter.shared.reloadAllTimelines() }
            } catch { self.lastError = "Could not publish widgets: \(error.localizedDescription)" }
        }
    }

    func consumeWidgetCommands() async {
        guard workspaceAvailable, let store = widgetCommands else { return }
        do {
            guard try store.beginDelivery(stream: "workspace") else { return }
            defer { try? store.release("delivery:workspace") }
            let queued = try store.records(stream: "workspace").filter { $0.state == .queued }
            guard !queued.isEmpty else { return }
            for record in queued {
                guard try store.beginSending(record.id), let edit = record.edit else { continue }
                do {
                    try await applyMobilePlanning(edit)
                    try store.receipt(id: record.id, applied: true, workModifiedAt: store.value("applied-work:" + edit.id.uuidString, as: Date.self))
                } catch WidgetCommandError.waitingForIdeaService {
                    statusMessage = WidgetCommandError.waitingForIdeaService.localizedDescription
                    if MobileIntentLifetime.hasExpired(record.intent) {
                        try store.receipt(id: record.id, applied: false, message: "The idea folder moved, but its metadata still needs service acknowledgement. Update/start the service and resume this promotion on Mac.")
                    } else { try store.retry(record.id) }
                } catch WidgetCommandError.waitingForCapture {
                    if MobileIntentLifetime.hasExpired(record.intent) {
                        try store.receipt(id: record.id, applied: false, message: "The capture did not arrive within two weeks. Nothing was filed.")
                    } else { try store.retry(record.id) }
                } catch {
                    try store.receipt(id: record.id, applied: false, message: error.localizedDescription)
                }
            }
            refreshOverview()
        } catch { lastError = "Widget actions could not be processed: \(error.localizedDescription)" }
    }
}

private struct WidgetFilingCheckpoint: Codable {
    var sourceIdentity: String
    var destination: String
    var applied: Bool
}

extension AppModel {
    /// The checkpoint names one bounded destination. Recovery never searches for a
    /// similarly named file and never repeats a work-item creation with a new ID.
    func applyWidgetCaptureFiling(_ edit: MobilePlanningEdit) async throws {
        guard let filing = edit.captureFiling, let store = widgetCommands,
              let folder = folders.first(where: { $0.name == filing.destination }) else {
            throw WidgetCommandError.message("The filing destination is no longer available. Open Ingest to choose another.")
        }
        guard try MobilePlanningFiles.resolve(filing.destination, workspace: workspace).canonicalPath == folder.url.canonicalPath else {
            throw WidgetCommandError.message("Open Ingest on Mac to review this destination.")
        }
        let key = "filing:" + edit.id.uuidString
        let previous = try store.value(key, as: WidgetFilingCheckpoint.self)
        if previous?.applied == true { return }
        if isWorkQueue(folder), workItems.contains(where: { $0.id == edit.id.uuidString }) {
            if var previous { previous.applied = true; try store.set(key, previous) }
            return
        }
        guard let capture = ingestItems.first(where: { $0.url.lastPathComponent == filing.capture.name }) else {
            if let previous {
                let attachment = try store.value("filing-attachment:" + edit.id.uuidString, as: String.self)
                let destination = URL(fileURLWithPath: isWorkQueue(folder) ? attachment ?? previous.destination : previous.destination)
                guard destination.deletingLastPathComponent().canonicalPath == folder.url.canonicalPath else {
                    throw WidgetCommandError.message("Filing recovery needs the Mac's Ingest flow.")
                }
                if isWorkQueue(folder), let attachment,
                   attachment == destination.canonicalPath, FileManager.default.fileExists(atPath: attachment) {
                    _ = try await createWorkItem(id: edit.id.uuidString, kind: folder.settings.workItemKind,
                        title: URL(fileURLWithPath: filing.capture.name).deletingPathExtension().lastPathComponent,
                        body: "[\(destination.lastPathComponent)](<\(destination.lastPathComponent)>)", status: .open,
                        stage: .next, priority: .medium, projectPath: nil, in: folder.url)
                    var completed = previous; completed.applied = true; try store.set(key, completed); return
                }
                if !isWorkQueue(folder), FileIdentityResolver.identity(of: destination)?.key == previous.sourceIdentity {
                    var completed = previous; completed.applied = true; try store.set(key, completed); return
                }
                throw WidgetCommandError.message("Filing was interrupted and the capture is no longer in Inbox. Check Recently Filed on Mac before retrying.")
            }
            throw WidgetCommandError.waitingForCapture
        }
        let url = capture.url
        let modified = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
        guard modified.map({ abs($0.timeIntervalSince(filing.capture.modified)) < 0.001 }) == true else {
            throw WidgetCommandError.message("This capture changed since its preview. Refresh before filing it.")
        }
        guard filing.capture.expectedChildren.isEmpty || MobileCaptureBundleReceipt.hasAllChildren(filing.capture.expectedChildren, at: url) else { throw WidgetCommandError.waitingForCapture }
        var checkpoint = previous ?? WidgetFilingCheckpoint(sourceIdentity: FileIdentityResolver.identity(of: url)?.key ?? capture.id,
            destination: folder.url.appendingPathComponent(url.lastPathComponent).canonicalPath, applied: false)
        try store.set(key, checkpoint)
        if isWorkQueue(folder) {
            _ = try await promoteCapture(capture, toQueue: folder, operationID: edit.id)
            if let attachment = try store.value("filing-attachment:" + edit.id.uuidString, as: String.self) { checkpoint.destination = attachment }
        } else {
            let ingest = ingest
            let directory = folder.url
            _ = try await Task.detached(priority: .userInitiated) { try ingest.classify(capture, intoDirectory: directory, renamingTo: nil) }.value
        }
        checkpoint.applied = true
        try store.set(key, checkpoint)
        await refreshIngest()
    }
}
