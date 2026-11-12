import Foundation
import BetterWorkspaceCore

extension AppModel {
    func installConnectedWorkspace() {
        ConnectedApps.shared.registerAsync(.workspaceTasks) { [weak self] _, data in
            guard let self else { throw ConnectionFailure.unavailable }
            try await self.waitForConnectedWorkspace()
            guard (data?.count ?? 0) <= 2048 else { throw ConnectionFailure.invalidMessage }
            let search = try data.map { try JSONDecoder().decode(ConnectedWorkspaceQuery.self, from: $0).search } ?? ""
            guard search.count <= 200 else { throw ConnectionFailure.invalidMessage }
            return try self.connectedTaskData(search: search)
        }
        ConnectedApps.shared.registerAsync(.workspaceUpdate) { [weak self] requestID, data in
            guard let self, let data, data.count <= 2048 else { throw ConnectionFailure.unavailable }
            try await self.waitForConnectedWorkspace()
            let input = try JSONDecoder().decode(ConnectedWorkspaceUpdate.self, from: data)
            guard let status = WorkItemStatus(rawValue: input.status), input.revision.count == 64,
                  let item = self.workItems.first(where: { $0.id == input.taskID && $0.kind == .task }) else { throw ConnectionFailure.invalidMessage }
            // Resolve only a current source-owned record; no caller-provided filesystem path.
            let root = self.workspace.root.standardizedFileURL
            let path = item.url.standardizedFileURL
            guard path.path.hasPrefix(root.path + "/"), path.resolvingSymlinksInPath().path == path.path else { throw ConnectionFailure.denied }
            let service = self.workItemService
            let saved = try await Task.detached(priority: .userInitiated) {
                try service.setConnectedStatus(item, expectedRevision: input.revision, status: status, requestID: requestID)
            }.value
            self.adopt(saved)
            self.queueGraphWork(saved)
            self.publishConnectedTasks()
            return try JSONEncoder().encode(ConnectedWorkspaceReceipt(requestID: requestID, task: self.connectedTask(saved)))
        }
    }
    private func waitForConnectedWorkspace() async throws {
        for _ in 0..<80 {
            guard workspaceAvailable else { throw ConnectionFailure.unavailable }
            if workItemsLoaded { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw ConnectionFailure.unavailable
    }
    private func connectedTask(_ item: WorkItem) -> ConnectedWorkspaceTask {
        .init(id: item.id, revision: workItemService.connectedRevision(item), title: String(item.title.prefix(200)),
              status: item.status.rawValue, stage: item.stage.rawValue, dueDate: item.dueDate,
              project: item.projectPath.map { String($0.prefix(200)) })
    }
    func connectedTaskData(search: String = "") throws -> Data {
        guard workspaceAvailable, workItemsLoaded else { throw ConnectionFailure.unavailable }
        let tasks = workItems.filter { $0.kind == .task }
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let matching = tasks.filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) || ($0.projectPath?.localizedCaseInsensitiveContains(query) ?? false) }
        let ordered = matching.sorted {
            if $0.isOpen != $1.isOpen { return $0.isOpen }
            if $0.dueDate != $1.dueDate { return ($0.dueDate ?? .distantFuture) < ($1.dueDate ?? .distantFuture) }
            if $0.stage != $1.stage { return $0.stage.rank < $1.stage.rank }
            return $0.id < $1.id
        }
        // Keep urgent dates and recently edited/captured work available in one bounded page.
        let due = Array(ordered.prefix(30))
        let recent = matching.filter { task in !due.contains(where: { $0.id == task.id }) }
            .sorted { ($0.modifiedAt ?? .distantPast) > ($1.modifiedAt ?? .distantPast) }.prefix(10)
        let page = due + recent
        let snapshot = ConnectedWorkspaceSnapshot(generatedAt: .now, tasks: page.map(connectedTask),
            openCount: matching.filter(\.isOpen).count,
            overdueCount: matching.filter { $0.isOpen && ($0.dueDate ?? .distantFuture) < .now }.count,
            syncStatus: "Local Workspace available. Notion: \(connectedSyncStatus)", query: query.isEmpty ? nil : query)
        return try JSONEncoder().encode(snapshot)
    }
    private var connectedSyncStatus: String {
        switch notionSyncState {
        case .notConfigured: return "Not configured"
        case .syncing: return "Synchronizing"
        case .upToDate: return "Up to date"
        case .waiting(let count): return "\(count) changes waiting"
        case .recovering(let count): return "\(count) changes retrying"
        case .attention(let count): return "\(count) changes need review"
        case .unavailable(let reason): return String(reason.prefix(200))
        }
    }
    func publishConnectedTasks() {
        if let data = try? connectedTaskData() { ConnectedApps.shared.publishRead("workspace.tasks.read.v1", data: data) }
    }
}
