import Foundation

/// Mac-only routing metadata. Never put these bindings in the portable graph or
/// treat a path as record identity. Persist them privately with observation receipts.
public struct WorkspaceMacBinding: Codable, Equatable, Sendable {
    public enum Source: String, Codable, Sendable { case project, work, idea, note, folder }
    public let recordID: UUID
    public let source: Source
    public let sourceID: String
    public let relativePath: String
    public let observedRevisionID: UUID
    public let fileIdentity: FileIdentity?
    public let sourceCreatedAt: Date?
    public let serviceID: String?
    public init(recordID: UUID, source: Source, sourceID: String, relativePath: String, observedRevisionID: UUID, fileIdentity: FileIdentity? = nil, sourceCreatedAt: Date? = nil, serviceID: String? = nil) {
        self.recordID = recordID; self.source = source; self.sourceID = sourceID
        self.relativePath = relativePath; self.observedRevisionID = observedRevisionID
        self.fileIdentity = fileIdentity
        self.sourceCreatedAt = sourceCreatedAt; self.serviceID = serviceID
    }
}

public struct WorkspaceMacObservation: Sendable {
    public let replica: WorkspaceReplica
    public let bindings: [WorkspaceMacBinding]
    /// Missing original text or identity must be explained, never converted to empty
    /// content or inferred deletion. Unselected files are never visited.
    public let deferredSourceIDs: [String: String]
    public init(replica: WorkspaceReplica, bindings: [WorkspaceMacBinding], deferredSourceIDs: [String: String] = [:]) {
        self.replica = replica; self.bindings = bindings; self.deferredSourceIDs = deferredSourceIDs
    }
}

/// A bounded adapter over already selected/published records, rather than another
/// filesystem crawler. ProjectStore and portable work IDs remain authoritative.
public enum WorkspaceMacProjection {
    /// Notes, not problems: the work itself syncs; only its parent link (often a project
    /// later moved to Ideas or archived in Finder) is unresolved. Never shown as needing review.
    public static let unresolvedProjectLink = "Work content is included; its linked project is unavailable. Review its location."
    public static let unresolvedFolderLink = "Work content is included; its linked folder is unavailable. Review its location."
    public static func observe(_ selected: MobileWorkspaceSnapshot, in replica: WorkspaceReplica,
                               bindings: [WorkspaceMacBinding], deviceID: UUID,
                               projectIdentities: [String: FileIdentity] = [:], allowIdentityAdoption: Bool = false,
                               files: [WorkspaceMacFileSource] = [], projectAliases: [String: String] = [:],
                               replacedProjectFolders: Set<String> = []) throws -> WorkspaceMacObservation {
        try replica.validate()
        try validateBindings(bindings)
        let old = Dictionary(uniqueKeysWithValues: bindings.map { ($0.recordID, $0) })
        let known = Dictionary(uniqueKeysWithValues: replica.revisions.map { ($0.id, $0) })
        let states = Dictionary(uniqueKeysWithValues: replica.records.map { ($0.id, $0) })
        let histories = Dictionary(grouping: replica.revisions, by: \.recordID)
        var upserts: [WorkspaceRecordRevision] = [], result = old, deferred: [String: String] = [:]
        var seen: Set<UUID> = [], projects: [String: UUID] = [:]

        func observe(source: WorkspaceMacBinding.Source, sourceID: String, path: String,
                     content: WorkspaceRecordContent, createdAt: Date?, modifiedAt: Date?) throws {
            guard !sourceID.isEmpty, MobileDownloadBundle.safePath(path) else { throw invalid("Choose an ordinary, published Workspace location.") }
            let id = recordID(source: source, sourceID: sourceID)
            guard seen.insert(id).inserted else { throw invalid("More than one Mac item has the same identity. Resolve the duplicates before merging.") }
            let previous = old[id]
            // `replacedProjectFolders`: the Mac proved the bound folder is gone and the same
            // project record now names the folder at this path (restored or replaced).
            if source == .project, let identity = projectIdentities[path], let previous, !replacedProjectFolders.contains(path),
               previous.fileIdentity != identity && (previous.fileIdentity != nil || !allowIdentityAdoption) {
                deferred["project:" + path] = "This project folder's identity changed or needs review. Its existing workspace content is retained."
                return
            }
            if let previous {
                // A folder moved between Projects and Ideas in Finder keeps its record, in
                // either direction, when it is provably the same folder.
                let finderReclassification: Bool
                switch (previous.source, source) {
                case (.project, .idea):
                    finderReclassification = files.contains { $0.id == id && $0.identity == previous.fileIdentity && $0.relativePath == path }
                case (.idea, .project):
                    finderReclassification = previous.fileIdentity != nil && projectIdentities[path] == previous.fileIdentity
                default: finderReclassification = false
                }
                // Anything else that changed kind waits for review on its own; it must
                // never stop every other item from synchronizing.
                if previous.source != source && !finderReclassification {
                    deferred[source == .project ? "project:" + path : path] = "This item changed kind in Finder and its identity could not be confirmed. Its workspace content is retained."
                    return
                }
                guard recordID(source: previous.source, sourceID: previous.sourceID) == id,
                      known[previous.observedRevisionID]?.recordID == id else { throw WorkspaceReplicaError.changed }
            }
            let reclassified = previous.map { $0.source != source } ?? false
            let parents: Set<UUID> = reclassified ? Set(states[id]?.heads.map(\.id) ?? []) : previous.map { [$0.observedRevisionID] } ?? []
            let revision: WorkspaceRecordRevision
            if let previous, let existing = known[previous.observedRevisionID], equivalent(existing.content, content, source: source) {
                revision = existing
            } else if let previous, let head = states[id]?.resolved,
                      equivalent(head.content, content, source: source), descends(head, from: previous.observedRevisionID, in: replica) {
                // The explicit Mac editor already materialized this revision, or
                // both sides independently reached the same content. Acknowledge
                // the actual canonical head instead of creating a duplicate branch.
                revision = head
            } else if let existing = histories[id]?.first(where: { $0.deviceID == deviceID && $0.parents == parents && $0.content == content }) {
                // A retry after the graph save but before its binding receipt must
                // not manufacture another revision because a file date changed.
                revision = existing
            } else {
                struct Seed: Encodable {
                    let recordID: UUID; let deviceID: UUID; let parents: [String]; let content: WorkspaceRecordContent
                }
                let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
                let bytes = try encoder.encode(Seed(recordID: id, deviceID: deviceID, parents: parents.map(\.uuidString).sorted(), content: content))
                revision = WorkspaceRecordRevision(id: WorkspaceStableIdentity.uuid(namespace: "BetterWorkspace.mac-observation.v1", data: bytes),
                    recordID: id, parents: parents, deviceID: deviceID, origin: .mac,
                    createdAt: modifiedAt ?? createdAt ?? Date(timeIntervalSince1970: 0),
                    recordCreatedAt: createdAt ?? previous.flatMap { known[$0.observedRevisionID]?.recordCreatedAt } ?? Date(timeIntervalSince1970: 0), content: content)
                upserts.append(revision)
            }
            result[id] = WorkspaceMacBinding(recordID: id, source: source, sourceID: sourceID, relativePath: path, observedRevisionID: revision.id, fileIdentity: source == .project ? projectIdentities[path] ?? previous?.fileIdentity : previous?.fileIdentity, sourceCreatedAt: previous?.sourceCreatedAt, serviceID: previous?.serviceID)
        }

        for entry in selected.entries where entry.isDirectory && entry.parentPath == "Projects" {
            guard let sourceID = entry.projectDetails?.projectID, !sourceID.isEmpty else {
                deferred["project:" + entry.path] = "The Mac must publish this project's persistent identity first."
                continue
            }
            guard projects[entry.path] == nil else { throw invalid("More than one project occupies this path.") }
            let id = recordID(source: .project, sourceID: sourceID); projects[entry.path] = id
            try observe(source: .project, sourceID: sourceID, path: entry.path,
                content: projectContent(entry, binding: old[id], baseline: old[id].flatMap { known[$0.observedRevisionID]?.content }),
                createdAt: entry.projectDetails?.createdAt, modifiedAt: entry.modifiedAt)
        }
        // A Finder rename can leave an earlier project identity bound to a path that a
        // different published project now occupies (Current State renamed to Better
        // Signals). The folder there is provably not the earlier one's any more, so its
        // binding is retired: its record gets a tombstone that keeps every revision, no
        // file or Notion page is touched, and it no longer blocks that project's work.
        // Receipts never drop a binding, so it stays, observing that tombstone.
        var superseded: Set<UUID> = []
        for binding in bindings where binding.source == .project && !seen.contains(binding.recordID) && binding.fileIdentity != nil {
            guard let owner = projects[binding.relativePath], owner != binding.recordID, seen.contains(owner),
                  let identity = projectIdentities[binding.relativePath], let current = result[owner],
                  current.relativePath == binding.relativePath, current.fileIdentity == identity else { continue }
            guard let state = states[binding.recordID], let head = state.resolved ?? state.heads.first else { continue }
            var tombstone = head
            if state.resolved?.content.isDeleted != true {
                var content = head.content; content.isDeleted = true
                let parents = Set(state.heads.map(\.id))
                tombstone = WorkspaceRecordRevision(
                    id: WorkspaceStableIdentity.uuid(namespace: "BetterWorkspace.superseded-project.v1",
                        data: Data((binding.recordID.uuidString + parents.map(\.uuidString).sorted().joined(separator: "\n")).utf8)),
                    recordID: binding.recordID, parents: parents, deviceID: deviceID, origin: .mac,
                    createdAt: state.heads.map(\.createdAt).max() ?? head.createdAt,
                    recordCreatedAt: state.heads.map(\.recordCreatedAt).min(), content: content)
                upserts.append(tombstone)
            }
            superseded.insert(binding.recordID)
            result[binding.recordID] = .init(recordID: binding.recordID, source: binding.source, sourceID: binding.sourceID,
                relativePath: binding.relativePath, observedRevisionID: tombstone.id, fileIdentity: binding.fileIdentity,
                sourceCreatedAt: binding.sourceCreatedAt, serviceID: binding.serviceID)
        }
        // A project retired by Finder (deleted, archived out of Projects, superseded) no
        // longer takes work links, exactly as in prepareWorkSave and readWorkContent.
        let retired = Set((replica.revisions + upserts).filter(\.content.isDeleted).map(\.id))
        for binding in result.values where binding.source == .project && projects[binding.relativePath] == nil && !retired.contains(binding.observedRevisionID) {
            projects[binding.relativePath] = binding.recordID
        }
        let containers = Dictionary(files.filter(\.isDirectory).map { ($0.relativePath, $0.id) }, uniquingKeysWith: { first, _ in first })
        for file in files {
            let previous = old[file.id]
            let baseline = previous.flatMap { known[$0.observedRevisionID]?.content }
            guard let body = file.body ?? (previous?.source == .project ? baseline?.body : nil) else {
                deferred[file.relativePath] = "The original idea description or text is unavailable. Reconnect its service or download the original before including it."
                continue
            }
            let parentPath = String(file.relativePath.split(separator: "/").dropLast().joined(separator: "/"))
            let parent = containers[parentPath] ?? projects[parentPath]
            var content = WorkspaceRecordContent(kind: file.kind, title: file.title, body: body, parentID: parent,
                                                 isComplete: baseline?.isComplete ?? false,
                                                 projectMetadata: baseline?.projectMetadata, projectLinks: baseline?.projectLinks)
            if file.kind == .folder {
                content.body = baseline?.body ?? body
                if previous?.relativePath == file.relativePath { content.title = baseline?.title ?? file.title }
            }
            try observe(source: file.source, sourceID: file.id.uuidString, path: file.relativePath, content: content,
                        createdAt: file.createdAt, modifiedAt: file.modifiedAt)
            if let value = result[file.id] {
                result[file.id] = .init(recordID: value.recordID, source: value.source, sourceID: value.sourceID, relativePath: value.relativePath,
                    observedRevisionID: value.observedRevisionID, fileIdentity: file.identity, sourceCreatedAt: file.createdAt, serviceID: file.serviceID)
            }
        }
        let linked = linking(projects, aliases: projectAliases)
        let parentIDs = physicalParentIDs(result.values.filter { !superseded.contains($0.recordID) })
        let knownFolderIDs = Set(files.lazy.filter(\.isDirectory).map(\.id))
            .union(bindings.lazy.filter { $0.source == .folder || $0.source == .idea }.map(\.recordID))
        for work in selected.workItems {
            guard let body = work.body else {
                deferred["work:" + work.id] = "Original text is unavailable. Download or publish the complete work record before merging."
                continue
            }
            // A snapshot copy never takes over a live binding: if the live file is gone,
            // missing-source reconciliation decides, as for any Finder deletion.
            if let previous = old[recordID(source: .work, sourceID: work.id)], !isSnapshotPath(previous.relativePath), isSnapshotPath(work.path) { continue }
            if let folderID = work.workspaceFolderID {
                if !knownFolderIDs.contains(folderID) {
                    deferred["work:" + work.id] = unresolvedFolderLink
                }
            } else if let path = work.projectPath, linked[path] == nil {
                deferred["work:" + work.id] = unresolvedProjectLink
            }
            let parentID = physicalParent(path: work.path, projectPath: work.projectPath, folderID: work.workspaceFolderID,
                projects: linked, parentIDs: parentIDs)
                ?? workParent(sourceID: work.id, folderID: work.workspaceFolderID, projectPath: work.projectPath, projects: linked)
            var content = WorkspaceRecordContent(kind: kind(work.kind), title: work.title, body: body, parentID: parentID, isComplete: work.status == .completed)
            content.responsibility = work.actionMetadata?.responsibilityLabel
            try observe(source: .work, sourceID: work.id, path: work.path, content: content,
                        createdAt: work.createdAt, modifiedAt: work.modifiedAt)
            let id = recordID(source: .work, sourceID: work.id)
            // Only when the journal holds nothing unacknowledged; a pending branch is a conflict.
            if let previous = old[id], isSnapshotPath(previous.relativePath), !isSnapshotPath(work.path),
               let head = states[id]?.resolved, head.id == previous.observedRevisionID,
               let observedID = result[id]?.observedRevisionID,
               let observed = known[observedID] ?? upserts.last(where: { $0.id == observedID }),
               let merged = relocationMerge(observed, head: head, fileModifiedAt: work.modifiedAt, histories[id] ?? [], deviceID: deviceID) {
                upserts.append(merged)
            }
        }
        for (path, owners) in Dictionary(grouping: result.values.filter { $0.source == .project && !superseded.contains($0.recordID) }, by: \.relativePath) where owners.count > 1 {
            deferred["project:" + path] = "More than one project identity names this location. Review its binding before applying edits."
        }
        let incoming = try WorkspaceReplica(workspaceID: replica.workspaceID, revisions: upserts, joinedWorkspaceIDs: replica.joinedWorkspaceIDs)
        return WorkspaceMacObservation(replica: try replica.merging(incoming), bindings: result.values.sorted { $0.recordID.uuidString < $1.recordID.uuidString }, deferredSourceIDs: deferred)
    }

    /// Reflect only positively confirmed absence under a readable, unchanged root.
    /// An incomplete listing, permission failure, missing area or symlink never
    /// becomes a deletion. No source files or remote pages are changed.
    public static func reconcileMissingSources(_ observation: WorkspaceMacObservation,
                                               workspace: WorkspaceLocation, rootIdentity: FileIdentity,
                                               deviceID: UUID, previousBindings: [WorkspaceMacBinding] = []) throws -> WorkspaceMacObservation {
        try WorkspaceLocalPathChecks.rejectSymlinks(to: workspace.root)
        guard FileIdentityResolver.identity(of: workspace.root) == rootIdentity else { throw WorkspaceReplicaError.changed }
        let states = Dictionary(uniqueKeysWithValues: observation.replica.records.map { ($0.id, $0) })
        var revisions: [WorkspaceRecordRevision] = [], bindings: [WorkspaceMacBinding] = []
        var readableAreas: [String: Bool] = [:]
        for binding in observation.bindings {
            var updated = binding
            do {
                let url = try bounded(binding.relativePath, workspace: workspace)
                let components = binding.relativePath.split(separator: "/")
                guard components.count >= 2 else { throw WorkspaceReplicaError.changed }
                let area = String(components[0])
                if readableAreas[area] == nil {
                    let areaURL = try bounded(area, workspace: workspace)
                    readableAreas[area] = (try? FileManager.default.contentsOfDirectory(atPath: areaURL.path)) != nil
                }
                var info = stat()
                var missing = lstat(url.path, &info) != 0 && errno == ENOENT
                // A known containing folder may have moved since the work index
                // finished. Check only its exact bound descendant, never crawl.
                if missing {
                    for parent in previousBindings.filter({ [.project, .idea, .folder].contains($0.source) && binding.relativePath.hasPrefix($0.relativePath + "/") }).sorted(by: { $0.relativePath.count > $1.relativePath.count }) {
                        guard let moved = observation.bindings.first(where: { $0.recordID == parent.recordID && $0.fileIdentity == parent.fileIdentity && $0.relativePath != parent.relativePath }) else { continue }
                        let path = moved.relativePath + binding.relativePath.dropFirst(parent.relativePath.count)
                        let destination = try bounded(path, workspace: workspace)
                        let matches: Bool
                        if binding.source == .work { matches = WorkItemService().read(at: destination).map { recordID(source: .work, sourceID: $0.id) } == binding.recordID }
                        else { matches = binding.fileIdentity != nil && FileIdentityResolver.identity(of: destination) == binding.fileIdentity }
                        guard matches else { continue }
                        updated = .init(recordID: binding.recordID, source: binding.source, sourceID: binding.sourceID,
                            relativePath: path, observedRevisionID: binding.observedRevisionID, fileIdentity: binding.fileIdentity,
                            sourceCreatedAt: binding.sourceCreatedAt, serviceID: binding.serviceID)
                        missing = false
                        break
                    }
                }
                // A bound folder found elsewhere in Projects or Ideas moved; the next
                // observation follows it. Only a folder that left them (or the Trash) is gone.
                if missing, [.project, .idea, .folder].contains(binding.source), let identity = binding.fileIdentity,
                   let moved = FileIdentityResolver.currentPath(of: identity, onVolumeOf: workspace.root),
                   moved.hasPrefix(workspace.root.canonicalPath + "/") {
                    let relative = String(moved.dropFirst(workspace.root.canonicalPath.count + 1))
                    if WorkspaceListing.isAreaChild(relative, area: "Projects") || WorkspaceListing.isAreaChild(relative, area: "Ideas") { missing = false }
                }
                if readableAreas[area] == true, missing, let state = states[binding.recordID],
                   let head = state.resolved ?? state.heads.first {
                    let revision: WorkspaceRecordRevision
                    if state.resolved?.content.isDeleted == true { revision = head }
                    else {
                        var content = head.content; content.isDeleted = true
                        let parents = Set(state.heads.map(\.id))
                        let seed = parents.map(\.uuidString).sorted().joined(separator: "\n")
                        revision = WorkspaceRecordRevision(
                            id: WorkspaceStableIdentity.uuid(namespace: "BetterWorkspace.finder-deletion.v1", data: Data((binding.recordID.uuidString + seed).utf8)),
                            recordID: binding.recordID, parents: parents, deviceID: deviceID, origin: .mac,
                            createdAt: state.heads.map(\.createdAt).max() ?? head.createdAt,
                            recordCreatedAt: state.heads.map(\.recordCreatedAt).min(), content: content)
                        revisions.append(revision)
                    }
                    updated = .init(recordID: binding.recordID, source: binding.source, sourceID: binding.sourceID,
                        relativePath: binding.relativePath, observedRevisionID: revision.id, fileIdentity: binding.fileIdentity,
                        sourceCreatedAt: binding.sourceCreatedAt, serviceID: binding.serviceID)
                }
            } catch {
                // Retain the last usable record when the source cannot be checked.
            }
            bindings.append(updated)
        }
        guard FileIdentityResolver.identity(of: workspace.root) == rootIdentity else { throw WorkspaceReplicaError.changed }
        let incoming = try WorkspaceReplica(workspaceID: observation.replica.workspaceID, revisions: revisions,
                                             joinedWorkspaceIDs: observation.replica.joinedWorkspaceIDs)
        return .init(replica: try observation.replica.merging(incoming), bindings: bindings,
                     deferredSourceIDs: observation.deferredSourceIDs)
    }

    public static func projectContent(_ entry: MobileWorkspaceEntry, binding: WorkspaceMacBinding? = nil, baseline: WorkspaceRecordContent? = nil) -> WorkspaceRecordContent {
        let details = entry.projectDetails
        let metadata = ProjectMetadata(domain: details?.domain, status: details?.status, phase: details?.phase, projectType: details?.projectType)
        let portfolio = details?.editablePortfolio ?? .init()
        var value = WorkspaceRecordContent(kind: .project, title: entry.name, body: details?.summary ?? "", projectMetadata: metadata.isEmpty ? nil : metadata, projectLinks: portfolio.isEmpty ? nil : portfolio)
        if let binding, let baseline {
            value.parentID = baseline.parentID; value.isComplete = baseline.isComplete
            // A creation suffix is a physical collision label. A real Finder
            // rename changes the bound path and is observed as a new title.
            if binding.relativePath == entry.path, entry.name == URL(fileURLWithPath: binding.relativePath).lastPathComponent { value.title = baseline.title }
        }
        return value
    }

    /// Only existing project properties and summary use this adapter. Renames,
    /// moves and deletion still require their reviewed filesystem actions.
    public static func prepareProjectSave(binding: WorkspaceMacBinding, in graph: WorkspaceReplica, current entry: MobileWorkspaceEntry) throws -> MobileProjectEdit? {
        guard binding.source == .project, entry.path == binding.relativePath, let fresh = entry.projectDetails,
              fresh.projectID == binding.sourceID, let baseline = graph.revisions.first(where: { $0.id == binding.observedRevisionID && $0.recordID == binding.recordID }),
              let desired = graph.records.first(where: { $0.id == binding.recordID })?.resolved,
              descends(desired, from: baseline.id, in: graph) else { throw WorkspaceReplicaError.changed }
        let content = desired.content
        var permitted = baseline.content
        permitted.projectMetadata = content.projectMetadata; permitted.projectLinks = content.projectLinks; permitted.body = content.body
        guard permitted == content else { throw WorkspaceReplicaError.invalid("A project rename, move, completion or deletion needs a reviewed Mac action.") }
        let source = projectContent(entry, binding: binding, baseline: baseline.content)
        if equivalent(source, content, source: .project) { return nil }
        guard equivalent(source, baseline.content, source: .project) else { throw WorkspaceReplicaError.changed }
        var properties = MobileProjectProperties(fresh)
        properties.domain = content.projectMetadata?.domain ?? ""; properties.status = content.projectMetadata?.status ?? ""
        properties.phase = content.projectMetadata?.phase ?? ""; properties.projectType = content.projectMetadata?.projectType ?? ""
        properties.portfolio = content.projectLinks ?? .init()
        return MobileProjectEdit(original: fresh, ratings: fresh.ratings ?? [:], oneLiner: fresh.oneLiner ?? "", summary: content.body, properties: properties)
    }

    public enum WorkSave: Sendable { case unchanged(WorkItem), update(WorkItem) }

    public static func validateProjectIdentity(_ binding: WorkspaceMacBinding, workspace: WorkspaceLocation) throws {
        guard binding.source == .project, let identity = binding.fileIdentity else {
            throw invalid("Review this Mac project folder's identity before applying changes.")
        }
        guard FileIdentityResolver.identity(of: try bounded(binding.relativePath, workspace: workspace)) == identity else { throw WorkspaceReplicaError.changed }
    }

    /// Prepares a selected explicit Save for AppModel.saveWorkItem / WorkItemService.
    /// This method never writes. It rereads only the bounded bound original, keeps
    /// unrelated fields/front matter, and refuses stale text or an unresolved branch.
    public static func prepareWorkSave(recordID id: UUID, in replica: WorkspaceReplica,
                                       bindings: [WorkspaceMacBinding], workspace: WorkspaceLocation,
                                       projectAliases: [String: String] = [:],
                                       service: WorkItemService = WorkItemService()) throws -> WorkSave {
        try replica.validate()
        try validateBindings(bindings)
        guard let binding = bindings.first(where: { $0.recordID == id && $0.source == .work }),
              let baseline = replica.revisions.first(where: { $0.id == binding.observedRevisionID && $0.recordID == id }),
              let current = replica.records.first(where: { $0.id == id }) else { throw WorkspaceReplicaError.missing }
        guard let desired = current.resolved else { throw WorkspaceReplicaError.conflicting }
        guard !desired.content.isDeleted, let kind = workKind(desired.content.kind) else { throw invalid("Deletion and this content kind require their own reviewed action.") }
        let url = try bounded(binding.relativePath, workspace: workspace)
        guard var fresh = service.read(at: url), recordID(source: .work, sourceID: fresh.id) == binding.recordID else { throw WorkspaceReplicaError.changed }
        let relative = relativeProjectPath(fresh.projectPath, workspace: workspace)
        // An ambiguous project (two identities at one path) blocks edits to its own work
        // and to work moved into it, never every other project's tasks.
        let grouped = Dictionary(grouping: liveProjectBindings(bindings, in: replica), by: \.relativePath)
        let ambiguous = Set(grouped.filter { $0.value.count > 1 }.keys)
        let target = desired.content.parentID.flatMap { parent in bindings.first { $0.recordID == parent && $0.source == .project }?.relativePath }
        guard relative.map({ !ambiguous.contains($0) }) ?? true, target.map({ !ambiguous.contains($0) }) ?? true else {
            throw invalid("More than one project identity names this location. Review its binding before applying edits.")
        }
        let projectBindings = liveProjectBindings(bindings, in: replica).filter { !ambiguous.contains($0.relativePath) }
        let projects = linking(Dictionary(uniqueKeysWithValues: projectBindings.map { ($0.relativePath, $0.recordID) }), aliases: projectAliases)
        let sourceParent = physicalParent(path: binding.relativePath, projectPath: relative, folderID: workspaceFolderID(in: fresh), projects: projects, parentIDs: physicalParentIDs(bindings))
            ?? workParent(sourceID: fresh.id, folderID: workspaceFolderID(in: fresh), projectPath: relative, projects: projects)
        let source = WorkspaceRecordContent(kind: Self.kind(fresh.kind), title: fresh.title, body: fresh.body,
            parentID: sourceParent, isComplete: fresh.status == .completed)
        if equivalent(source, desired.content, source: .work) { return .unchanged(fresh) }
        guard equivalent(source, baseline.content, source: .work), descends(desired, from: baseline.id, in: replica) else { throw WorkspaceReplicaError.changed }
        // An ordinary text/status Save must not erase or rewrite an unresolved
        // original relationship. Only an explicit canonical move changes links.
        if desired.content.parentID != sourceParent {
            fresh.extraFrontMatter.removeAll { $0.hasPrefix(folderParentKey) }
            if let parentID = desired.content.parentID {
                guard let parent = bindings.first(where: { $0.recordID == parentID && [.project, .folder, .idea].contains($0.source) }),
                      replica.records.first(where: { $0.id == parentID })?.resolved?.content.isDeleted == false else { throw WorkspaceReplicaError.missing }
                let target = try bounded(parent.relativePath, workspace: workspace)
                guard (try? target.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                      parent.fileIdentity == nil || FileIdentityResolver.identity(of: target) == parent.fileIdentity else { throw WorkspaceReplicaError.changed }
                if parent.source == .project { fresh.projectPath = parent.relativePath }
                else { fresh.extraFrontMatter.append(folderParentKey + " " + parentID.uuidString) }
            } else { fresh.projectPath = nil }
        } else if let sourceParent, let parent = bindings.first(where: { $0.recordID == sourceParent && [.project, .folder, .idea].contains($0.source) }) {
            // Retain existing identity protection when a linked parent is known.
            let target = try bounded(parent.relativePath, workspace: workspace)
            guard (try? target.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                  parent.fileIdentity == nil || FileIdentityResolver.identity(of: target) == parent.fileIdentity else { throw WorkspaceReplicaError.changed }
        }
        fresh.kind = kind; fresh.title = desired.content.title; fresh.body = desired.content.body
        fresh.status = desired.content.isComplete ? .completed : fresh.status == .completed ? .open : fresh.status
        fresh.completedAt = desired.content.isComplete ? (fresh.completedAt ?? Date()) : nil
        return .update(fresh)
    }

    /// Reread one bound source after a rejected/interrupted save. Unknown or moved
    /// sources are refused; absence from a listing never becomes a deletion.
    public static func readWorkContent(_ binding: WorkspaceMacBinding, bindings: [WorkspaceMacBinding], workspace: WorkspaceLocation, replica: WorkspaceReplica? = nil, projectAliases: [String: String] = [:], service: WorkItemService = WorkItemService()) throws -> WorkspaceRecordContent {
        try validateBindings(bindings)
        guard binding.source == .work, let fresh = service.read(at: try bounded(binding.relativePath, workspace: workspace)), recordID(source: .work, sourceID: fresh.id) == binding.recordID else { throw WorkspaceReplicaError.missing }
        // As in prepareWorkSave, an ambiguous project path withholds only its own work.
        let grouped = Dictionary(grouping: replica.map { liveProjectBindings(bindings, in: $0) } ?? bindings.filter { $0.source == .project }, by: \.relativePath)
        let relative = relativeProjectPath(fresh.projectPath, workspace: workspace)
        guard relative.map({ (grouped[$0]?.count ?? 0) <= 1 }) ?? true else { throw WorkspaceReplicaError.changed }
        let projectMap = linking(grouped.compactMapValues { $0.count == 1 ? $0[0].recordID : nil }, aliases: projectAliases)
        let parent = physicalParent(path: binding.relativePath, projectPath: relative, folderID: workspaceFolderID(in: fresh), projects: projectMap, parentIDs: physicalParentIDs(bindings))
            ?? workParent(sourceID: fresh.id, folderID: workspaceFolderID(in: fresh), projectPath: relative, projects: projectMap)
        return .init(kind: kind(fresh.kind), title: fresh.title, body: fresh.body, parentID: parent, isComplete: fresh.status == .completed)
    }

    /// Project bindings that still name a folder. A retired one (its folder confirmed
    /// missing, or now published under another identity) observes a tombstone.
    static func liveProjectBindings(_ bindings: [WorkspaceMacBinding], in replica: WorkspaceReplica) -> [WorkspaceMacBinding] {
        let retired = Set(replica.revisions.filter(\.content.isDeleted).map(\.id))
        return bindings.filter { $0.source == .project && !retired.contains($0.observedRevisionID) }
    }

    /// A work link naming a path a project left in Finder (`ProjectStore.pathAliases`)
    /// means that project where it is now. A path some project occupies always wins,
    /// and the same rule is used by observation, save and reread so they never disagree.
    static func linking(_ projects: [String: UUID], aliases: [String: String]) -> [String: UUID] {
        var result = projects
        for (old, current) in aliases where projects[old] == nil {
            if let id = projects[current] { result[old] = id }
        }
        return result
    }

    private static func relativeProjectPath(_ path: String?, workspace: WorkspaceLocation) -> String? {
        path.map { $0.hasPrefix(workspace.root.canonicalPath + "/") ? String($0.dropFirst(workspace.root.canonicalPath.count + 1)) : $0 }
    }

    private static func workParent(sourceID: String, folderID: UUID?, projectPath: String?, projects: [String: UUID]) -> UUID? {
        if let folderID { return folderID }
        guard let projectPath else { return nil }
        if let id = projects[projectPath] { return id }
        // A missing-reference token, never a project record or project identity.
        // Scope it to the persistent work ID so unrelated same-name links cannot
        // coalesce. No original path is sent to mobile. A changed unresolved link
        // changes the token and therefore participates in normal stale/conflict checks.
        let data = Data((recordID(source: .work, sourceID: sourceID).uuidString + "\n" + projectPath).utf8)
        return WorkspaceStableIdentity.uuid(namespace: "BetterWorkspace.unresolved-project-link.v1", data: data)
    }

    private static func physicalParentIDs(_ bindings: [WorkspaceMacBinding]) -> [String: UUID] {
        Dictionary(bindings.lazy.filter { [.project, .idea, .folder].contains($0.source) }
            .map { ($0.relativePath, $0.recordID) }, uniquingKeysWith: { first, _ in first })
    }

    private static func physicalParent(path: String, projectPath: String?, folderID: UUID?, projects: [String: UUID], parentIDs: @autoclosure () -> [String: UUID]) -> UUID? {
        guard folderID == nil, projectPath.map({ projects[$0] == nil }) ?? true else { return nil }
        let parents = parentIDs()
        var ancestor = path[...]
        while let separator = ancestor.lastIndex(of: "/") {
            ancestor = ancestor[..<separator]
            if let id = parents[String(ancestor)] { return id }
        }
        return nil
    }

    public static let folderParentKey = "better-workspace-folder:"
    public static func workspaceFolderID(in item: WorkItem) -> UUID? {
        let values = item.extraFrontMatter.filter { $0.hasPrefix(folderParentKey) }
        guard values.count == 1 else { return nil }
        return UUID(uuidString: String(values[0].dropFirst(folderParentKey.count)).trimmingCharacters(in: .whitespaces))
    }

    public static func recordID(source: WorkspaceMacBinding.Source, sourceID: String) -> UUID {
        UUID(uuidString: sourceID) ?? WorkspaceStableIdentity.uuid(namespace: "BetterWorkspace.mac-identity." + source.rawValue, data: Data(sourceID.utf8))
    }

    private static func kind(_ value: WorkItemKind) -> WorkspaceRecordContent.Kind {
        switch value { case .task: .task; case .feature: .feature; case .milestone: .milestone; case .goal: .goal }
    }
    private static func workKind(_ value: WorkspaceRecordContent.Kind) -> WorkItemKind? {
        switch value { case .task: .task; case .feature: .feature; case .milestone: .milestone; case .goal: .goal; default: nil }
    }
    private static func invalid(_ message: String) -> WorkspaceReplicaError { .invalid(message) }

    static func isSnapshotPath(_ relativePath: String) -> Bool {
        relativePath.split(separator: "/").dropLast().contains { $0 == WorkspaceArea.backups.rawValue }
    }

    /// A binding that observed a Backups snapshot (same id as the live record) moves to the
    /// live file. Edits applied meanwhile went into the snapshot, so the live file's text is
    /// not a newer edit of them: for each field, the newer of the live file and the field's
    /// last journal change wins, as in Notion review. The result is a revision on top of the
    /// file's own observation, so the Mac then writes it into the live file.
    static func relocationMerge(_ observed: WorkspaceRecordRevision, head: WorkspaceRecordRevision?, fileModifiedAt: Date?,
                                _ history: [WorkspaceRecordRevision], deviceID: UUID) -> WorkspaceRecordRevision? {
        guard let head, !head.content.isDeleted, head.id != observed.id, let fileModifiedAt else { return nil }
        let known = Dictionary(uniqueKeysWithValues: history.map { ($0.id, $0) })
        var ancestry: [WorkspaceRecordRevision] = [], pending = [head.id], visited: Set<UUID> = []
        while let id = pending.popLast() {
            guard visited.insert(id).inserted, let revision = known[id] else { continue }
            ancestry.append(revision); pending.append(contentsOf: revision.parents)
        }
        func changedAt<Value: Equatable>(_ field: (WorkspaceRecordContent) -> Value) -> Date? {
            ancestry.filter { revision in
                let parents = revision.parents.compactMap { known[$0] }
                return parents.isEmpty || parents.contains { field($0.content) != field(revision.content) }
            }.map(\.createdAt).max()
        }
        var content = observed.content, newest: Date?
        func keep<Value: Equatable>(_ path: WritableKeyPath<WorkspaceRecordContent, Value>) {
            guard head.content[keyPath: path] != content[keyPath: path],
                  let date = changedAt({ $0[keyPath: path] }), date > fileModifiedAt else { return }
            content[keyPath: path] = head.content[keyPath: path]; newest = max(newest ?? date, date)
        }
        keep(\.title); keep(\.body); keep(\.isComplete)
        guard let newest else { return nil }
        let seed = Data((observed.recordID.uuidString + "\n" + observed.id.uuidString + "\n" + head.id.uuidString).utf8)
        return WorkspaceRecordRevision(id: WorkspaceStableIdentity.uuid(namespace: "BetterWorkspace.snapshot-relocation.v1", data: seed),
            recordID: observed.recordID, parents: [observed.id], deviceID: deviceID, origin: .mac,
            createdAt: max(newest, observed.createdAt), recordCreatedAt: observed.recordCreatedAt, content: content)
    }
    private static func equivalent(_ lhs: WorkspaceRecordContent, _ rhs: WorkspaceRecordContent, source: WorkspaceMacBinding.Source) -> Bool {
        guard source == .work || source == .project || source == .note || source == .idea else { return lhs == rhs }
        // The existing Markdown renderer/parser normalizes line endings and outer
        // blank lines. That representation change must not reject a saved revision
        // or manufacture a source edit when a reviewed creation is acknowledged.
        var left = lhs, right = rhs
        // Responsibility is shown on devices but only ever comes from the Mac file.
        left.responsibility = nil; right.responsibility = nil
        if source != .project {
            left.body = MobilePlanningFiles.normalizedWorkBody(left.body)
            right.body = MobilePlanningFiles.normalizedWorkBody(right.body)
        } else {
            left.body = left.body.trimmingCharacters(in: .whitespacesAndNewlines)
            right.body = right.body.trimmingCharacters(in: .whitespacesAndNewlines)
            if left.projectMetadata?.isEmpty == true { left.projectMetadata = nil }; if right.projectMetadata?.isEmpty == true { right.projectMetadata = nil }
            if left.projectLinks?.isEmpty == true { left.projectLinks = nil }; if right.projectLinks?.isEmpty == true { right.projectLinks = nil }
        }
        return left == right
    }
    static func validateBindings(_ bindings: [WorkspaceMacBinding]) throws {
        guard Set(bindings.map(\.recordID)).count == bindings.count,
              bindings.allSatisfy({ !$0.sourceID.isEmpty && $0.recordID == recordID(source: $0.source, sourceID: $0.sourceID) && MobileDownloadBundle.safePath($0.relativePath) }) else {
            throw invalid("The Mac identity bindings need review.")
        }
    }
    static func bounded(_ path: String, workspace: WorkspaceLocation) throws -> URL {
        guard MobileDownloadBundle.safePath(path) else { throw invalid("That location cannot be edited.") }
        var rootInfo = stat()
        guard lstat(workspace.root.path, &rootInfo) == 0, (rootInfo.st_mode & S_IFMT) == S_IFDIR else { throw WorkspaceReplicaError.missing }
        let url = try MobilePlanningFiles.resolve(path, workspace: workspace)
        try WorkspaceLocalPathChecks.rejectSymlinks(to: url)
        return url
    }
    static func descends(_ revision: WorkspaceRecordRevision, from ancestor: UUID, in replica: WorkspaceReplica) -> Bool {
        let known = Dictionary(uniqueKeysWithValues: replica.revisions.map { ($0.id, $0) })
        var pending = [revision.id], visited: Set<UUID> = []
        while let id = pending.popLast() {
            if id == ancestor { return true }
            if visited.insert(id).inserted { pending.append(contentsOf: known[id]?.parents ?? []) }
        }
        return false
    }
}
