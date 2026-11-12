import Foundation

/// Widgets share the app-owned journal, not a filesystem index or credentials.
/// Their projection omits note bodies and preserves existing capture/integration data.
public enum WorkspaceUnifiedWidgets {
    public struct Context {
        public let graph: WorkspaceReplica
        public let settings: WorkspaceSessionSettings
        public let store: WorkspaceReplicaStore
    }
    public static func read(directory: URL = WorkspaceSession.storageDirectory) throws -> Context? {
        let settingsURL = directory.appendingPathComponent("settings.json")
        let graphURL = directory.appendingPathComponent("workspace.json")
        guard FileManager.default.fileExists(atPath: settingsURL.path), FileManager.default.fileExists(atPath: graphURL.path) else { return nil }
        try WorkspaceLocalPathChecks.rejectSymlinks(to: settingsURL)
        guard (try settingsURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) <= 1_048_576 else { throw WorkspaceReplicaError.invalid("The workspace settings exceed the widget read limit.") }
        let settings = try JSONDecoder().decode(WorkspaceSessionSettings.self, from: Data(contentsOf: settingsURL))
        let store = WorkspaceReplicaStore(directory: directory, initialWorkspaceID: settings.sourceID)
        return .init(graph: try store.load(), settings: settings, store: store)
    }
    public static func overlay(_ existing: WorkspaceDashboardSnapshot?, replica: WorkspaceReplica) -> WorkspaceDashboardSnapshot {
        var result = existing ?? .init()
        let states = replica.records
        let ids = Set(states.map(\.id)), titles = replica.displayTitles
        func owned(_ id: String) -> Bool { UUID(uuidString: id).map { ids.contains($0) } ?? false }
        let previousWork = result.work.reduce(into: [UUID: MobileWorkItem]()) { result, item in if let id = UUID(uuidString: item.id), result[id] == nil { result[id] = item } }
        let previousProjects = result.projects.reduce(into: [UUID: DashboardProject]()) { result, item in if let id = UUID(uuidString: item.id), result[id] == nil { result[id] = item } }
        var projects: [UUID: DashboardProject] = [:]
        for state in states {
            guard let revision = state.resolved, revision.content.kind == .project, !revision.content.isDeleted else { continue }
            let title = titles[state.id] ?? revision.content.title
            let path = previousProjects[state.id]?.path ?? "unified/" + state.id.uuidString
            var project = previousProjects[state.id] ?? .init(id: state.id.uuidString, path: path, name: title,
                focus: .init(id: state.id.uuidString, path: path, title: title, kind: .projects, completed: 0, total: 0, terminal: false, blocked: false))
            project.name = title; project.focus.title = title; project.focus.terminal = revision.content.isComplete
            project.status = revision.content.isComplete ? "completed" : nil
            projects[state.id] = project
        }
        result.work.removeAll { owned($0.id) }
        result.projects.removeAll { owned($0.id) }
        result.focusItems.removeAll { owned($0.id) }
        result.attention.removeAll { $0.id.hasPrefix("unified:") }
        for state in states {
            guard let revision = state.resolved else {
                result.attention.append(.init(id: "unified:" + state.id.uuidString, title: titles[state.id] ?? "Workspace item", reason: "Review concurrent changes", category: .failure, route: .task(state.id.uuidString)))
                continue
            }
            let value = revision.content
            guard !value.isDeleted, let kind = WorkItemKind(rawValue: value.kind.rawValue) else { continue }
            var item = previousWork[state.id] ?? MobileWorkItem(id: state.id.uuidString, path: "unified/" + state.id.uuidString,
                title: value.title, kind: kind, status: .open, stage: .next, priority: .medium, revision: 0)
            item.title = titles[state.id] ?? value.title; item.kind = kind
            item.status = value.isComplete ? .completed : (item.status == .completed ? .open : item.status)
            item.projectPath = value.parentID.flatMap { projects[$0]?.path }
            item.createdAt = revision.recordCreatedAt; item.modifiedAt = revision.createdAt
            item.workspaceRevisionID = revision.id; item.body = nil
            result.work.append(item)
        }
        for (_, var project) in projects {
            let work = result.work.filter { $0.projectPath == project.path }
            project.focus.total = work.filter { $0.kind == .task }.count
            project.focus.completed = work.filter { $0.kind == .task && $0.status == .completed }.count
            project.nextTask = WorkItemRecommendation.nextMobileAction(in: work, allItems: result.work)
            result.projects.append(project); result.focusItems.append(project.focus)
        }
        result.projects.sort { $0.name == $1.name ? $0.id < $1.id : $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        result.work.sort { $0.id < $1.id }
        result.updatedAt = max(result.updatedAt, replica.revisions.map(\.createdAt).max() ?? .distantPast)
        return result
    }
    @discardableResult
    public static func completeIfPresent(taskID: String, expectedRevisionID: UUID?, directory: URL = WorkspaceSession.storageDirectory) throws -> Bool {
        guard let id = UUID(uuidString: taskID), let context = try read(directory: directory),
              let state = context.graph.records.first(where: { $0.id == id }) else { return false }
        guard let current = state.resolved, current.content.kind == .task, !current.content.isDeleted,
              let expectedRevisionID, current.id == expectedRevisionID else { throw WorkspaceReplicaError.changed }
        if current.content.isComplete { return true }
        var content = current.content; content.isComplete = true
        #if os(macOS)
        let origin = WorkspaceRecordRevision.Origin.mac
        #else
        let origin = WorkspaceRecordRevision.Origin.iOS
        #endif
        _ = try context.store.save(recordID: id, content: content, expectedHeads: [expectedRevisionID], deviceID: context.settings.deviceID, origin: origin)
        return true
    }
}
