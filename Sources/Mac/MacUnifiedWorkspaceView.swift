import SwiftUI
import BetterWorkspaceCore

struct MacUnifiedWorkspaceView: View {
    @Environment(AppModel.self) private var model
    @State private var session: WorkspaceSession?
    @State private var inclusion: MacWorkspaceInclusion?
    @State private var creation: MacWorkCreationPreview?
    @State private var error: String?
    var body: some View {
        Group {
            if let session {
                UnifiedWorkspaceHome(session: session, projectHistory: { id in
                    guard let record = model.projectRecordsByPath.values.first(where: { WorkspaceMacProjection.recordID(source: .project, sourceID: $0.id) == id }) else { return nil }
                    return ProjectWorkHistory(serviceID: record.watcherID, logs: model.workLogs, sessions: model.recentSessions)
                }, synchronizesWhileVisible: session.isFixture)
                    .safeAreaInset(edge: .bottom) {
                        VStack(alignment: .leading, spacing: 8) {
                                Text(session.settings.macIncluded ? "Finder controls linked Mac files. Changes sync automatically; Notion updates wait for review." : "Include indexed projects, work, ideas and reference notes from this Mac.").font(.caption)
                            HStack {
                                Button("Review Mac content") {
                                    Task {
                                        do { inclusion = try await model.prepareUnifiedInclusion(session) }
                                        catch { self.error = error.localizedDescription }
                                    }
                                }.accessibilityIdentifier("unified.includeMac")
                                if session.settings.macIncluded {
                                    Button("Review new Mac items") {
                                        Task {
                                            do { creation = try await model.prepareUnifiedWorkCreation(session) }
                                            catch { self.error = error.localizedDescription }
                                        }
                                    }.accessibilityIdentifier("unified.reviewFiles")
                                }
                            }
                            }.padding().background(.bar)
                    }
            } else if let error {
                ContentUnavailableView("Workspace could not be opened", systemImage: "externaldrive.badge.exclamationmark", description: Text(error))
            } else { ProgressView("Opening workspace…") }
        }
        .task { @MainActor in
            do {
                let session = try await WorkspaceSession.openLive()
                try await UnifiedWorkspaceAcceptanceSeed.prepare(session)
                model.unifiedWorkspace = session
                session.macBridge = { [weak model, weak session] in
                    guard let model, let session else { return }
                    try await model.synchronizeUnifiedFiles(session)
                }
                self.session = session
            } catch { self.error = error.localizedDescription }
        }
        .sheet(item: $inclusion) { value in
            if let session {
                UnifiedMergeReview(session: session, peer: value.peer, onApproved: {
                    try model.commitUnifiedInclusion(value, session: session)
                }, additionalNotes: Array(value.observation.deferredSourceIDs.values))
            }
        }
        .sheet(item: $creation) { value in
            if let session {
                MacWorkCreationReview(preview: value, approve: { try await model.approveUnifiedWorkCreation(value, session: session) }, cancelQueued: { request in
                    try await model.cancelUnifiedWorkCreation(request, sourceID: value.sourceID, session: session)
                })
            }
        }
        .alert("Mac workspace needs attention", isPresented: Binding(get: { error != nil && session != nil }, set: { if !$0 { error = nil } })) { Button("OK") { error = nil } } message: { Text(error ?? "") }
    }
}

struct MacWorkCreationPreview: Identifiable {
    let id = UUID()
    let sourceID: UUID
    let receiptID: UUID
    let requests: [WorkspaceMacWorkCreation]
    let pending: [WorkspaceMacWorkCreation]
    let issues: [String]
}

private struct MacWorkCreationReview: View {
    let preview: MacWorkCreationPreview
    let approve: () async throws -> Void
    let cancelQueued: (WorkspaceMacWorkCreation) async throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var applying = false
    @State private var error: String?
    @State private var cancellation: WorkspaceMacWorkCreation?
    var body: some View {
        NavigationStack {
            List {
                Text("Create folders and small Markdown notes for the selected workspace items. Review the exact destinations below. Existing files and folders are preserved; each item keeps its workspace identity.")
                ForEach(preview.requests) { request in
                    VStack(alignment: .leading) { Text(request.revision.content.title).bold(); Text(request.relativePath).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).textSelection(.enabled) }
                }
                if preview.requests.isEmpty { Text("No new Mac items are ready to create.") }
                if !preview.pending.isEmpty {
                    Section("Queued creations needing attention") {
                        Text("Canceling a request keeps the workspace item and any file already created. Review again to choose a new available destination.")
                        ForEach(preview.pending) { request in
                            VStack(alignment: .leading) {
                                Text(request.revision.content.title).bold()
                                Text(request.relativePath).font(.caption).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                                Button("Cancel queued creation") { cancellation = request }
                                    .accessibilityIdentifier("unified.cancelCreation." + request.id.uuidString)
                            }
                        }
                    }
                }
                ForEach(Array(preview.issues.enumerated()), id: \.offset) { _, issue in Text(issue).foregroundStyle(.secondary) }
                if let error { Text(error).foregroundStyle(.red).accessibilityIdentifier("unified.creationError") }
            }.navigationTitle("Review new Mac items")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Later") { dismiss() }.disabled(applying) }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(preview.requests.count == 1 ? "Create 1 item" : "Create \(preview.requests.count) items") {
                            applying = true
                            Task { do { try await approve(); dismiss() } catch { self.error = error.localizedDescription; applying = false } }
                        }.disabled(applying || preview.requests.isEmpty).accessibilityIdentifier("unified.createFiles")
                    }
                }
        }.frame(minWidth: 560, minHeight: 300, maxHeight: 360)
            .alert("Cancel this file creation?", isPresented: Binding(get: { cancellation != nil }, set: { if !$0 { cancellation = nil } })) {
                Button("Keep queued", role: .cancel) { cancellation = nil }
                Button("Cancel file creation", role: .destructive) {
                    guard let request = cancellation else { return }; applying = true
                    Task { do { try await cancelQueued(request); dismiss() } catch { self.error = error.localizedDescription; applying = false }; cancellation = nil }
                }
            } message: { Text("Your workspace item and existing Mac files will be kept.") }
    }
}

struct MacWorkspaceInclusion: Identifiable {
    let id = UUID()
    let peer: WorkspaceCloudPeer
    let observation: WorkspaceMacObservation
    let receiptID: UUID?
    let sourceID: UUID
}

extension AppModel {
    func prepareUnifiedWorkCreation(_ session: WorkspaceSession) async throws -> MacWorkCreationPreview {
        try await synchronizeUnifiedFiles(session)
        let source = try WorkspaceMacReceiptStore.sourceID(deviceID: session.deviceID, sourceRoot: workspace.root, database: database)
        let receipts = try WorkspaceMacReceiptStore(database: database)
        guard session.settings.macIncluded, let receipt = try receipts.load(sourceID: source) else { throw WorkspaceReplicaError.invalid("Review this Mac's content first.") }
        try receipts.validateRoot(receipt, sourceRoot: workspace.root)
        let graph = try session.store.load(), workspace = workspace
        var directories = Dictionary(uniqueKeysWithValues: WorkItemKind.allCases.compactMap { kind -> (String, String)? in
            let url = WorkQueueRouting.folder(for: kind, among: folders)?.url ?? workspace.url(forArea: "To Do")
            return workspaceRelativePath(for: url).map { (kind.rawValue, $0) }
        })
        directories["project"] = WorkspaceArea.projects.directoryName
        directories["folder"] = WorkspaceArea.references.directoryName
        directories["note"] = WorkspaceArea.references.directoryName
        directories["idea"] = WorkspaceArea.ideas.directoryName
        let creationDirectories = directories
        let journal = WorkspaceMacCreationJournal(directory: session.directory.appendingPathComponent("MacSources/" + source.uuidString))
        let pending = try journal.pending()
        let known = Set(receipt.bindings.map(\.recordID)).union(pending.map(\.id))
        let prepared = await Task.detached(priority: .userInitiated) {
            var requests: [WorkspaceMacWorkCreation] = [], issues: [String] = []
            for state in graph.records where !known.contains(state.id) {
                guard let content = state.resolved?.content, !content.isDeleted, let directory = creationDirectories[content.kind.rawValue] else { continue }
                do { requests.append(try .prepare(recordID: state.id, in: graph, bindings: receipt.bindings, workspace: workspace, directoryPath: directory, reservedPaths: Set(requests.map(\.relativePath)))) }
                catch { issues.append(content.title + ": " + error.localizedDescription) }
            }
            return (requests, issues)
        }.value
        return .init(sourceID: source, receiptID: receipt.id, requests: prepared.0, pending: pending, issues: prepared.1)
    }

    func cancelUnifiedWorkCreation(_ request: WorkspaceMacWorkCreation, sourceID: UUID, session: WorkspaceSession) async throws {
        guard try WorkspaceMacReceiptStore.sourceID(deviceID: session.deviceID, sourceRoot: workspace.root, database: database) == sourceID else { throw WorkspaceReplicaError.changed }
        let journal = WorkspaceMacCreationJournal(directory: session.directory.appendingPathComponent("MacSources/" + sourceID.uuidString))
        if request.createsContent {
            let directory = session.directory.appendingPathComponent("MacSources/" + sourceID.uuidString), projects = projectStore
            try await Task.detached(priority: .userInitiated) { try WorkspaceMacDirectoryCreation.cancel(request, journalDirectory: directory, projects: projects) }.value
        }
        try journal.finish(request)
        // Only a private queued request was removed. If a file was already written,
        // normal UUID observation retains it and exposes any competing content.
        try await synchronizeUnifiedFiles(session)
        try await session.reload()
    }

    func approveUnifiedWorkCreation(_ preview: MacWorkCreationPreview, session: WorkspaceSession) async throws {
        guard try WorkspaceMacReceiptStore.sourceID(deviceID: session.deviceID, sourceRoot: workspace.root, database: database) == preview.sourceID else { throw WorkspaceReplicaError.changed }
        let receipts = try WorkspaceMacReceiptStore(database: database)
        guard let receipt = try receipts.load(sourceID: preview.sourceID), receipt.id == preview.receiptID else { throw WorkspaceReplicaError.changed }
        try receipts.validateRoot(receipt, sourceRoot: workspace.root)
        let graph = try session.store.load()
        for request in preview.requests { try request.validateApproval(in: graph, bindings: receipt.bindings) }
        let journal = WorkspaceMacCreationJournal(directory: session.directory.appendingPathComponent("MacSources/" + preview.sourceID.uuidString))
        for request in preview.requests { try journal.begin(request) }
        try await synchronizeUnifiedFiles(session)
        try await session.reload()
        if !(try journal.pending()).isEmpty { throw WorkspaceReplicaError.invalid(session.capabilityStatus ?? "The selected work files are queued. Reconnect their original Mac locations to finish.") }
    }

    func startUnifiedWorkspace() {
        guard !TestIsolation.isActive, WorkspaceSession.fixtureID == nil, unifiedSyncTask == nil else { return }
        unifiedSyncTask = Task { [weak self] in
            do {
                let session = try await WorkspaceSession.openLive()
                self?.unifiedWorkspace = session
                session.macBridge = { [weak self, weak session] in
                    guard let self, let session else { return }
                    try await self.synchronizeUnifiedFiles(session)
                }
                while !Task.isCancelled {
                    await session.synchronizeIfDue()
                    Self.recordUnifiedSyncStatus(session)
                    try await Task.sleep(for: .seconds(25))
                }
            } catch is CancellationError { }
            catch { self?.lastError = "Workspace: " + error.localizedDescription }
        }
    }

    /// The last background pass, for diagnosing device sync without opening the window:
    /// `~/Library/Application Support/BetterWorkspace/unified-sync-status.json`.
    @MainActor static func recordUnifiedSyncStatus(_ session: WorkspaceSession) {
        let value: [String: Any] = [
            "at": ISO8601DateFormatter().string(from: Date()), "status": session.status,
            "connectionError": session.connectionError ?? NSNull(), "capabilityStatus": session.capabilityStatus ?? NSNull(),
            "lastSync": session.lastSync.map { ISO8601DateFormatter().string(from: $0) } ?? NSNull(),
            "cloudEnabled": session.settings.cloudEnabled, "macIncluded": session.settings.macIncluded,
            "pendingPeers": session.pendingPeers.count,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]) else { return }
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BetterWorkspace/unified-sync-status.json")
        try? data.write(to: url, options: .atomic)
    }

    private func unifiedSnapshot() async -> MobileWorkspaceSnapshot {
        let projects = projects(), records = projectRecordsByPath, store = projectStore
        let workItems = workItems, workspace = workspace
        return await Task.detached(priority: .utility) {
            var details: [String: MobileProjectDetails] = [:], entries: [MobileWorkspaceEntry] = []
            for item in projects {
                guard let record = records[item.url.canonicalPath],
                      let path = MobileWorkspaceProjection.relativePath(of: item.url, workspace: workspace) else { continue }
                let metadata = store.metadata(for: record.id), description = store.description(for: record.id)
                let detail = MobileProjectDetails(path: path, oneLiner: description.oneLiner, summary: description.summary,
                    domain: metadata.domain, status: metadata.status, phase: metadata.phase, projectID: record.id,
                    ratings: store.ratings(for: record.id), projectType: metadata.projectType,
                    createdAt: item.createdAt, portfolio: store.portfolioDetails(for: record.id))
                details[path] = detail
                entries.append(.init(path: path, parentPath: "Projects", name: item.name, isDirectory: true,
                    revision: 0, modifiedAt: item.contentModifiedAt, projectDetails: detail))
            }
            let snapshot = MobileWorkspaceLocalSnapshot(itemsByArea: [:], workItems: workItems, tags: [], tagsByPath: [:], projectDetailsByPath: details)
            let work = MobileWorkspaceProjection.candidates(from: snapshot, workspace: workspace).compactMap { candidate -> MobileWorkItem? in
                if case .workItem(let work) = candidate { return work }; return nil
            }
            return .init(entries: entries, workItems: work)
        }.value
    }

    func prepareUnifiedInclusion(_ session: WorkspaceSession) async throws -> MacWorkspaceInclusion {
        if !workItemsLoaded { await refreshAll() }
        let receipts = try WorkspaceMacReceiptStore(database: database)
        let sourceID = try WorkspaceMacReceiptStore.sourceID(deviceID: session.deviceID, sourceRoot: workspace.root, database: database)
        let receipt = try receipts.load(sourceID: sourceID)
        let snapshot = await unifiedSnapshot(), graph = try session.store.load(), identities = unifiedProjectIdentities()
        let files = await unifiedFileSources(bindings: receipt?.bindings ?? [], scope: sourceID)
        let projected = try WorkspaceMacProjection.observe(snapshot, in: graph, bindings: receipt?.bindings ?? [], deviceID: session.deviceID, projectIdentities: identities, allowIdentityAdoption: true, files: files.0, projectAliases: projectLinkAliases,
            replacedProjectFolders: replacedProjectFolders(receipt?.bindings ?? [], identities: identities))
        let observation = WorkspaceMacObservation(replica: projected.replica, bindings: projected.bindings, deferredSourceIDs: projected.deferredSourceIDs.merging(files.1, uniquingKeysWith: { first, _ in first }))
        return .init(peer: .init(deviceID: session.deviceID, sourceID: session.sourceID, name: "This Mac’s selected workspace content", platform: "Mac", replica: observation.replica, approvals: []), observation: observation, receiptID: receipt?.id, sourceID: sourceID)
    }

    /// Only shallow, already indexed planning/reference items and explicitly bound
    /// nested items. Project directories are never walked to find notes.
    private func unifiedFileSources(bindings: [WorkspaceMacBinding], scope: UUID) async -> ([WorkspaceMacFileSource], [String: String]) {
        var candidates: [String: WorkspaceMacFileCandidate] = [:]
        for area in [WorkspaceArea.ideas, .references] {
            for item in items(for: area) where item.isContentLocal && !item.name.hasPrefix("_") {
                guard let path = workspaceRelativePath(for: item.url), !NoiseFilter.isForeignMetadata(name: item.name),
                      item.isDirectory || (["md", "markdown", "mdown", "txt"].contains(item.url.pathExtension.lowercased()) && !item.name.hasSuffix(WorkItemService.fileSuffix)) else { continue }
                let idea = serviceIdeasByPath[item.url.canonicalPath]
                candidates[path] = .init(relativePath: path, kind: area == .ideas ? .idea : item.isDirectory ? .folder : .note,
                    title: area == .ideas ? idea?.title : nil, description: idea.map { $0.oneLiner ?? "" }, serviceID: idea?.id)
            }
        }
        for binding in bindings where [.note, .idea, .folder].contains(binding.source) {
            let idea = serviceIdeasByPath[workspace.root.appendingPathComponent(binding.relativePath).canonicalPath]
            if candidates[binding.relativePath] == nil {
                candidates[binding.relativePath] = .init(relativePath: binding.relativePath, kind: binding.source == .idea ? .idea : binding.source == .folder ? .folder : .note,
                    title: idea?.title, description: idea.map { $0.oneLiner ?? "" }, serviceID: idea?.id ?? binding.serviceID)
            }
        }
        let selected = Array(candidates.values), workspace = workspace
        return await Task.detached(priority: .utility) {
            var files: [WorkspaceMacFileSource] = [], issues: [String: String] = [:]
            for candidate in selected {
                do { files.append(try WorkspaceMacFileSource.read(candidate, workspace: workspace, bindings: bindings, scope: scope)) }
                catch { issues[candidate.relativePath] = candidate.relativePath + ": " + error.localizedDescription }
            }
            return (files, issues)
        }.value
    }

    private func unifiedProjectIdentities() -> [String: FileIdentity] {
        Dictionary(uniqueKeysWithValues: projects().compactMap { item in
            guard let path = workspaceRelativePath(for: item.url), let identity = item.identity else { return nil }
            return (path, identity)
        })
    }

    /// Bound project folders replaced at the same path (restored from a backup, or copied
    /// over): the bound folder is provably gone and the same project record names this one.
    private func replacedProjectFolders(_ bindings: [WorkspaceMacBinding], identities: [String: FileIdentity]) -> Set<String> {
        Set(bindings.compactMap { binding in
            let url = workspace.root.appendingPathComponent(binding.relativePath)
            guard binding.source == .project, let bound = binding.fileIdentity, let now = identities[binding.relativePath], bound != now,
                  projectRecordsByPath[url.canonicalPath]?.id == binding.sourceID,
                  FileIdentityResolver.isGone(bound, onVolumeOf: url) else { return nil }
            return binding.relativePath
        })
    }

    private func validateUnifiedProjectBinding(_ binding: WorkspaceMacBinding) throws {
        guard binding.source == .project else { return }
        try WorkspaceMacProjection.validateProjectIdentity(binding, workspace: workspace)
    }

    func commitUnifiedInclusion(_ inclusion: MacWorkspaceInclusion, session: WorkspaceSession) throws {
        guard try WorkspaceMacReceiptStore.sourceID(deviceID: session.deviceID, sourceRoot: workspace.root, database: database) == inclusion.sourceID else { throw WorkspaceReplicaError.changed }
        let current = try session.store.load()
        let observation = WorkspaceMacObservation(replica: try current.merging(inclusion.observation.replica), bindings: inclusion.observation.bindings, deferredSourceIDs: inclusion.observation.deferredSourceIDs)
        _ = try WorkspaceMacReceiptStore(database: database).commit(observation, sourceID: inclusion.sourceID, sourceRoot: workspace.root, expectedReceiptID: inclusion.receiptID, graph: session.store)
        try session.markMacIncluded()
    }

    /// Source observations and in-flight writes are serialized here. File updates
    /// use the existing editor, including its Notion draft and stale-source checks.
    func synchronizeUnifiedFiles(_ session: WorkspaceSession) async throws {
        let isolatedCreationAcceptance = session.isFixture && TestIsolation.isActive && TestIsolation.launchArgument("BWUnifiedFileCreationFixture") == "YES"
        guard session.settings.macIncluded, !session.isFixture || isolatedCreationAcceptance, !unifiedBridgeRunning else { return }
        unifiedBridgeRunning = true; defer { unifiedBridgeRunning = false }
        let workspace = workspace, database = database
        let receipts = try WorkspaceMacReceiptStore(database: database)
        let sourceID = try WorkspaceMacReceiptStore.sourceID(deviceID: session.deviceID, sourceRoot: workspace.root, database: database)
        let journal = WorkspaceMacWriteJournal(directory: session.directory.appendingPathComponent("MacSources/" + sourceID.uuidString))
        var receipt = try receipts.load(sourceID: sourceID)
        guard receipt != nil else { throw WorkspaceReplicaError.invalid("Review this Mac’s content before connecting its filesystem.") }
        try receipts.validateRoot(receipt!, sourceRoot: workspace.root)
        var issues: [String] = []
        let creations = WorkspaceMacCreationJournal(directory: session.directory.appendingPathComponent("MacSources/" + sourceID.uuidString))
        for request in try creations.pending() {
            do {
                let graph = try session.store.load(), bindings = receipt!.bindings, workspace = workspace, service = workItemService
                let binding: WorkspaceMacBinding
                if request.createsContent {
                    let projects = projectStore, directory = session.directory.appendingPathComponent("MacSources/" + sourceID.uuidString)
                    (_, binding) = try await Task.detached(priority: .userInitiated) {
                        try WorkspaceMacDirectoryCreation.materialize(request, in: graph, bindings: bindings, workspace: workspace, journalDirectory: directory, projects: projects)
                    }.value
                    await refreshAll()
                } else {
                    let (saved, value) = try await Task.detached(priority: .userInitiated) {
                        try request.materialize(in: graph, bindings: bindings, workspace: workspace, service: service)
                    }.value
                    binding = value
                    adopt(saved); queueGraphWork(saved)
                }
                try receipts.validateRoot(receipt!, sourceRoot: workspace.root)
                let updated = bindings.filter { $0.recordID != binding.recordID } + [binding]
                receipt = try receipts.commit(.init(replica: session.store.load(), bindings: updated), sourceID: sourceID, sourceRoot: workspace.root, expectedReceiptID: receipt?.id, graph: session.store)
                try creations.finish(request)
            } catch {
                session.capabilityStatus = "A reviewed work-file creation needs attention. Its request and workspace content are retained. " + error.localizedDescription
                return
            }
        }

        func apply(_ request: WorkspaceMacWriteRequest) async throws {
            try receipts.validateRoot(receipt!, sourceRoot: workspace.root)
            let graph = try session.store.load()
            let selected = try request.selectedReplica(in: graph)
            if request.binding.source == .project {
                try validateUnifiedProjectBinding(request.binding)
                guard let entry = await unifiedSnapshot().entries.first(where: { $0.path == request.binding.relativePath }) else { throw WorkspaceReplicaError.missing }
                if let change = try WorkspaceMacProjection.prepareProjectSave(binding: request.binding, in: selected, current: entry) {
                    try await applyMobilePlanning(.init(operation: .saveProject, title: entry.name, projectEdit: change))
                }
                guard let reread = await unifiedSnapshot().entries.first(where: { $0.path == entry.path }),
                      try WorkspaceMacProjection.prepareProjectSave(binding: request.binding, in: selected, current: reread) == nil else { throw WorkspaceReplicaError.changed }
            } else if request.binding.source == .work {
                let prepared = try WorkspaceMacProjection.prepareWorkSave(recordID: request.binding.recordID, in: selected, bindings: receipt!.bindings, workspace: workspace, projectAliases: projectLinkAliases)
                if case .update(let work) = prepared { _ = try await saveWorkItem(work) }
                // Reread after the asynchronous writer. A remote change may have arrived
                // in the meantime; acknowledge the selected revision, never that new head.
                guard case .unchanged = try WorkspaceMacProjection.prepareWorkSave(recordID: request.binding.recordID, in: selected, bindings: receipt!.bindings, workspace: workspace, projectAliases: projectLinkAliases) else { throw WorkspaceReplicaError.changed }
            }
            var bindings = try request.acknowledgedBindings(receipt!.bindings)
            if [.note, .idea, .folder].contains(request.binding.source) {
                let old = request.binding, workspace = workspace
                let idea = serviceIdeasByPath[workspace.root.appendingPathComponent(old.relativePath).canonicalPath]
                let sourceBindings = receipt!.bindings
                let edit = try await Task.detached(priority: .userInitiated) {
                    try WorkspaceMacFileSave.prepare(binding: old, in: selected, bindings: sourceBindings, workspace: workspace, scope: sourceID, ideaTitle: idea?.title, ideaDescription: idea.map { $0.oneLiner ?? "" })
                }.value
                let url = try MobilePlanningFiles.resolve(old.relativePath, workspace: workspace)
                if edit.original.isDirectory && edit.original.kind == .idea {
                    guard let serviceID = edit.original.serviceID else { throw WorkspaceReplicaError.missing }
                    let original = MobileIdea(path: old.relativePath, title: edit.original.title, revision: 0, description: edit.original.body, serviceID: serviceID)
                    try await applyMobilePlanning(.init(operation: .saveIdea, title: edit.desired.title, description: edit.desired.body, originalIdea: original))
                    await refreshIdeaPlanning()
                } else if let text = edit.replacementText, let snapshot = edit.snapshot {
                    if edit.original.kind == .idea && workspace.areaName(containing: url) == WorkspaceArea.ideas.directoryName { _ = try await saveIdeaText(text, to: url, expecting: snapshot) }
                    else { _ = try await Task.detached(priority: .userInitiated) { try TextDocumentService().save(text, at: url, expecting: snapshot) }.value }
                    try WorkspaceContentIdentity.write(.init(id: old.recordID, kind: edit.original.kind), at: url)
                }
                let refreshedIdea = serviceIdeasByPath[url.canonicalPath]
                let readback = try await Task.detached(priority: .userInitiated) {
                    try WorkspaceMacFileSave.prepare(binding: old, in: selected, bindings: sourceBindings, workspace: workspace, scope: sourceID, ideaTitle: refreshedIdea?.title, ideaDescription: refreshedIdea.map { $0.oneLiner ?? "" })
                }.value
                guard readback.replacementText == nil,
                      !readback.original.isDirectory || readback.original.kind != .idea || (readback.original.title == edit.desired.title && readback.original.body == edit.desired.body) else { throw WorkspaceReplicaError.changed }
                bindings = bindings.map { value in
                    value.recordID == old.recordID ? .init(recordID: value.recordID, source: value.source, sourceID: value.sourceID, relativePath: value.relativePath, observedRevisionID: value.observedRevisionID, fileIdentity: readback.original.identity, sourceCreatedAt: readback.original.createdAt, serviceID: readback.original.serviceID) : value
                }
            }
            receipt = try receipts.commit(.init(replica: session.store.load(), bindings: bindings), sourceID: sourceID, sourceRoot: workspace.root, expectedReceiptID: receipt?.id, graph: session.store)
            try journal.finish(request)
        }

        func preserveRejectedSource(_ request: WorkspaceMacWriteRequest) async throws {
            try receipts.validateRoot(receipt!, sourceRoot: workspace.root)
            guard let binding = receipt!.bindings.first(where: { $0.recordID == request.binding.recordID }) else { throw WorkspaceReplicaError.missing }
            let graph = try session.store.load()
            let source: WorkspaceRecordContent
            if binding.source == .project {
                try validateUnifiedProjectBinding(binding)
                guard let item = projects().first(where: { projectRecord(for: $0)?.id == binding.sourceID }), workspaceRelativePath(for: item.url) == binding.relativePath else { throw WorkspaceReplicaError.missing }
                let metadata = projectStore.metadata(for: binding.sourceID)
                source = WorkspaceMacProjection.projectContent(.init(path: binding.relativePath, parentPath: "Projects", name: item.name, isDirectory: true, revision: 0, projectDetails: .init(path: binding.relativePath, summary: projectStore.description(for: binding.sourceID).summary, domain: metadata.domain, status: metadata.status, phase: metadata.phase, projectID: binding.sourceID, projectType: metadata.projectType, portfolio: projectStore.portfolioDetails(for: binding.sourceID))))
            } else if binding.source == .work { source = try WorkspaceMacProjection.readWorkContent(binding, bindings: receipt!.bindings, workspace: workspace, replica: graph, projectAliases: projectLinkAliases) }
            else {
                let idea = serviceIdeasByPath[workspace.root.appendingPathComponent(binding.relativePath).canonicalPath]
                let workspace = workspace, bindings = receipt!.bindings
                source = try await Task.detached(priority: .utility) {
                    let file = try WorkspaceMacFileSource.readBound(binding, workspace: workspace, scope: sourceID, title: idea?.title, description: idea.map { $0.oneLiner ?? "" })
                    return try WorkspaceMacFileSave.sourceContent(file, binding: binding, in: graph, bindings: bindings)
                }.value
            }
            let rejection = try request.rejectionRevision(in: graph, currentBinding: binding, source: source, deviceID: session.deviceID)
            let incoming = try WorkspaceReplica(workspaceID: graph.workspaceID, revisions: [rejection], joinedWorkspaceIDs: graph.joinedWorkspaceIDs)
            let combined = try graph.merging(incoming)
            let bindings = receipt!.bindings.map { value in
                value.recordID == binding.recordID ? WorkspaceMacBinding(recordID: value.recordID, source: value.source, sourceID: value.sourceID, relativePath: value.relativePath, observedRevisionID: rejection.id, fileIdentity: value.fileIdentity, sourceCreatedAt: value.sourceCreatedAt, serviceID: value.serviceID) : value
            }
            receipt = try receipts.commit(.init(replica: combined, bindings: bindings), sourceID: sourceID, sourceRoot: workspace.root, expectedReceiptID: receipt?.id, graph: session.store)
            try journal.finish(request)
        }

        for request in try journal.pending() {
            do { try await apply(request) }
            catch {
                let reason = error.localizedDescription
                do {
                    try await preserveRejectedSource(request)
                    issues.append("A Mac file save was rejected. Both versions are retained for review. " + reason)
                } catch {
                    session.capabilityStatus = "A Mac file save needs its original source before it can be reconciled: " + reason
                    // A missing/moved original must not stop observation of other
                    // Finder changes. Keep the request until its source is reconciled.
                }
            }
        }
        let snapshot = await unifiedSnapshot()
        let files = await unifiedFileSources(bindings: receipt!.bindings, scope: sourceID)
        let currentReceipt = receipt!, deviceID = session.deviceID, graphStore = session.store
        let identities = unifiedProjectIdentities(), aliases = projectLinkAliases
        let replaced = replacedProjectFolders(currentReceipt.bindings, identities: identities)
        let reconciled = try await Task.detached(priority: .utility) {
            try receipts.validateRoot(currentReceipt, sourceRoot: workspace.root)
            let observed = try WorkspaceMacProjection.observe(snapshot, in: graphStore.load(), bindings: currentReceipt.bindings,
                deviceID: deviceID, projectIdentities: identities, files: files.0, projectAliases: aliases, replacedProjectFolders: replaced)
            let observation = try WorkspaceMacProjection.reconcileMissingSources(observed, workspace: workspace,
                rootIdentity: currentReceipt.rootIdentity, deviceID: deviceID, previousBindings: currentReceipt.bindings)
            let saved = try receipts.commit(observation, sourceID: sourceID, sourceRoot: workspace.root,
                expectedReceiptID: currentReceipt.id, graph: graphStore)
            return (saved, observation)
        }.value
        receipt = reconciled.0
        let deleted = Set(reconciled.1.replica.records.filter { $0.resolved?.content.isDeleted == true }.map(\.id))
        let deletedPaths = Set(receipt!.bindings.filter { deleted.contains($0.recordID) }.map(\.relativePath))
        let previousRevisions = Dictionary(uniqueKeysWithValues: currentReceipt.bindings.map { ($0.recordID, $0.observedRevisionID) })
        let newlyDeletedPaths = Set(receipt!.bindings.filter { deleted.contains($0.recordID) && previousRevisions[$0.recordID] != $0.observedRevisionID }.map(\.relativePath))
        issues.append(contentsOf: files.1.filter { !deletedPaths.contains($0.key) }.map(\.value))
        issues.append(contentsOf: reconciled.1.deferredSourceIDs.values)
        // A Finder deletion retires only this private local projection. Remote
        // Notion pages and all saved revision history remain available.
        try await Task.detached(priority: .utility) {
            let notion = try ProjectGraphStore(database: database)
            for path in newlyDeletedPaths { try notion.recordLocalDeletion(path: workspace.root.appendingPathComponent(path).canonicalPath) }
            for request in try journal.pending() where deleted.contains(request.binding.recordID) { try journal.finish(request) }
        }.value
        let loadedGraph = try await Task.detached(priority: .utility) {
            let graph = try graphStore.load()
            return (graph, Dictionary(uniqueKeysWithValues: graph.records.map { ($0.id, $0) }))
        }.value
        let graph = loadedGraph.0, states = loadedGraph.1
        for binding in receipt!.bindings {
            guard let desired = states[binding.recordID]?.resolved, desired.id != binding.observedRevisionID else { continue }
            guard !desired.content.isDeleted else {
                issues.append("A linked project or deletion needs a reviewed action in the Mac filesystem browser."); continue
            }
            do {
                // Validate before recording a request; unsupported edits do not leave
                // an unreplayable pending write blocking later source observation.
                if binding.source == .project {
                    try validateUnifiedProjectBinding(binding)
                    guard let entry = snapshot.entries.first(where: { $0.path == binding.relativePath }) else { throw WorkspaceReplicaError.missing }
                    _ = try WorkspaceMacProjection.prepareProjectSave(binding: binding, in: graph, current: entry)
                } else if binding.source == .work { _ = try WorkspaceMacProjection.prepareWorkSave(recordID: binding.recordID, in: graph, bindings: receipt!.bindings, workspace: workspace, projectAliases: projectLinkAliases) }
                else {
                    let idea = serviceIdeasByPath[workspace.root.appendingPathComponent(binding.relativePath).canonicalPath]
                    let workspace = workspace, bindings = receipt!.bindings
                    _ = try await Task.detached(priority: .utility) {
                        try WorkspaceMacFileSave.prepare(binding: binding, in: graph, bindings: bindings, workspace: workspace, scope: sourceID, ideaTitle: idea?.title, ideaDescription: idea.map { $0.oneLiner ?? "" })
                    }.value
                }
                guard try session.store.load().records.first(where: { $0.id == binding.recordID })?.resolved?.id == desired.id else { continue }
                let request = WorkspaceMacWriteRequest(binding: binding, revisionID: desired.id)
                try journal.begin(request); try await apply(request)
            } catch {
                let message = error.localizedDescription
                if let pending = try journal.pending().first(where: { $0.binding.recordID == binding.recordID }) {
                    try? await preserveRejectedSource(pending)
                }
                issues.append(message)
            }
        }
        // Work that syncs with an unresolved parent link is not something to review.
        let problems = Set(issues).subtracting([WorkspaceMacProjection.unresolvedProjectLink, WorkspaceMacProjection.unresolvedFolderLink])
        session.capabilityStatus = problems.isEmpty ? nil : "Mac files: " + problems.sorted().joined(separator: " ")
    }
}
