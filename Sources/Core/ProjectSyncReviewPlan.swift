import Foundation

/// A read-only review projection. Ordering and recommendations never acknowledge data.
public struct ProjectSyncReviewPlan: Sendable {
    public enum Group: String, CaseIterable, Identifiable, Sendable {
        case attention, relevant, other, history
        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .attention: return "Needs attention"
            case .relevant: return "Active projects & related records"
            case .other: return "Other project data"
            case .history: return "History & completed work"
            }
        }
    }
    public struct Entry: Identifiable, Sendable {
        public let record: ProjectGraphRecord
        public let group: Group
        public let reason: String
        public let projectIDs: Set<String>
        public let projectNames: [String]
        public let changes: [ProjectFieldChange]
        public let initialImport: Bool
        public var id: String { record.id }
    }
    public struct Project: Identifiable, Sendable {
        public let id: String
        public let title: String
        public let count: Int
        public let relevant: Bool
    }
    public let entries: [Entry]
    public let projects: [Project]
    public let recommendedIDs: Set<String>
    public let safeIDs: Set<String>
    public let initialCount: Int

    public init(records: [ProjectGraphRecord], allRecords: [ProjectGraphRecord], sources: [ProjectGraphSource]) {
        let schemas = Dictionary(sources.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let byPage = Dictionary(allRecords.map { (ProjectGraph.normalizedID($0.pageID ?? $0.id), $0.id) }, uniquingKeysWith: { first, _ in first })
        let projectRecords = allRecords.filter { $0.kind == .projects }
        let projectIDs = Set(projectRecords.map(\.id))
        let titles = Dictionary(projectRecords.map { ($0.id, $0.title) }, uniquingKeysWith: { first, _ in first })
        func completed(_ record: ProjectGraphRecord) -> Bool {
            if record.remoteArchived || record.acknowledgedArchived == true { return true }
            guard let source = schemas[record.sourceID] else { return false }
            if ProjectGraph.isCompleted(record, source: source) { return true }
            let statuses = ["status", "task status"].map { record.value($0, source: source).display.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) }
            if statuses.contains(where: { ["done", "complete", "completed", "archived", "abandoned", "cancelled", "canceled"].contains($0) }) { return true }
            return record.kind == .tasks && record.value("date completed", source: source)["date"]["start"].string != nil
        }
        func active(_ record: ProjectGraphRecord) -> Bool {
            guard !completed(record) else { return false }
            let status = schemas[record.sourceID].map { record.value("status", source: $0).display.lowercased() } ?? ""
            guard !["paused", "on hold", "backlog", "idea", "planned", "not started"].contains(status) else { return false }
            return record.localProjectID != nil || record.localPath != nil || ["active", "in progress", "in-progress", "doing"].contains(status)
        }
        let relevantProjects = Set(projectRecords.filter(active).map(\.id))
        let activeLocalProjects = Set(projectRecords.filter(active).compactMap(\.localProjectID))
        // Propagate project membership over work/media containers, preserving multiple
        // parents. Do not cross related-project links or expand a project's entire
        // workspace through arbitrary resources, notes, ideas or work-log links.
        let containers: Set<ProjectEntityKind> = [.tasks, .features, .milestones, .assets, .collections, .versions]
        let kinds = Dictionary(allRecords.map { ($0.id, $0.kind) }, uniquingKeysWith: { first, _ in first })
        var adjacent: [String: Set<String>] = [:]
        for record in allRecords {
            let references = record.relatedPageIDs.union(record.remote.values.filter { $0["type"].string == "relation" }.flatMap { $0["relation"].array.compactMap { $0["id"].string.map(ProjectGraph.normalizedID) } })
            for reference in references {
                guard let target = byPage[reference], target != record.id,
                      !(record.kind == .projects && kinds[target] == .projects) else { continue }
                adjacent[record.id, default: []].insert(target)
                adjacent[target, default: []].insert(record.id)
            }
        }
        var membership: [String: Set<String>] = [:]
        for project in projectRecords {
            var visited: Set<String> = [project.id], queue = [project.id], offset = 0
            membership[project.id, default: []].insert(project.id)
            while offset < queue.count {
                let current = queue[offset]; offset += 1
                for target in adjacent[current] ?? [] where !projectIDs.contains(target) && visited.insert(target).inserted {
                    membership[target, default: []].insert(project.id)
                    if kinds[target].map(containers.contains) == true { queue.append(target) }
                }
            }
        }
        var projected: [Entry] = []
        var scores: [String: Int] = [:]
        for record in records {
            let changes = record.changes
            let conflicts = changes.filter { $0.state == .conflict }.count
            let archived = record.archiveRequested || record.remoteArchived != (record.acknowledgedArchived ?? false)
            let attention = conflicts > 0 || record.error != nil || record.ambiguousCreate || archived
            let owners = membership[record.id] ?? []
            let linked = record.localProjectID != nil || record.localPath != nil
            let history = record.kind == .workLogs || completed(record)
            let relevant = !history && (record.kind == .projects ? active(record) : (!owners.isDisjoint(with: relevantProjects) || record.localProjectID.map(activeLocalProjects.contains) == true))
            let group: Group = attention ? .attention : history ? .history : relevant ? .relevant : .other
            let reason: String
            if record.ambiguousCreate { reason = "Creation needs reconciliation" }
            else if record.error != nil { reason = "Previous sync failed" }
            else if archived { reason = "Archive or restore needs review" }
            else if conflicts > 0 { reason = "\(conflicts) conflicting field\(conflicts == 1 ? "" : "s")" }
            else if record.kind == .workLogs { reason = "Historical work log" }
            else if history { reason = "Completed or inactive" }
            else if linked { reason = "Linked to a local project" }
            else if relevant { reason = "Related to an active project" }
            else { reason = record.baseline.isEmpty && !record.remote.isEmpty ? "New from Notion" : "Incoming or local changes" }
            projected.append(Entry(record: record, group: group, reason: reason, projectIDs: owners,
                                   projectNames: owners.compactMap { titles[$0] }.sorted(), changes: changes,
                                   initialImport: record.baseline.isEmpty && !record.remote.isEmpty))
            scores[record.id] = (record.kind == .projects ? 100 : 0) + (linked ? 30 : 0) + (active(record) ? 10 : 0)
        }
        entries = projected.sorted {
            let left = Group.allCases.firstIndex(of: $0.group)!, right = Group.allCases.firstIndex(of: $1.group)!
            if left != right { return left < right }
            if scores[$0.id] != scores[$1.id] { return scores[$0.id, default: 0] > scores[$1.id, default: 0] }
            if $0.record.editedAt != $1.record.editedAt { return ($0.record.editedAt ?? .distantPast) > ($1.record.editedAt ?? .distantPast) }
            let order = $0.record.title.localizedStandardCompare($1.record.title)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
        safeIDs = Set(entries.filter { $0.group != .attention }.map(\.id))
        recommendedIDs = Set(entries.filter { $0.group == .relevant }.map(\.id))
        initialCount = entries.filter(\.initialImport).count
        var counts: [String: Int] = [:]
        for entry in entries { for project in entry.projectIDs { counts[project, default: 0] += 1 } }
        projects = projectRecords.compactMap { project in
            guard let count = counts[project.id] else { return nil }
            return Project(id: project.id, title: project.title, count: count, relevant: relevantProjects.contains(project.id))
        }.sorted { $0.relevant != $1.relevant ? $0.relevant : $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }
}
