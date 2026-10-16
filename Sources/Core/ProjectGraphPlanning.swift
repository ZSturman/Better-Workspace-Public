import Foundation

/// Planning questions asked of the private project graph: is this record done, and
/// which task comes next.
///
/// A task, feature or milestone made in this app is a `.bw.md` file first and a graph
/// record second (the record is its pending Notion draft, bound by `localPath`). The
/// file is the source of truth, so a bound record answers from the file. Asking the
/// record alone is how a task completed in the app kept being recommended as the next
/// action: its draft still said "Todo".
public enum ProjectGraphPlanning {
    /// Work stages, most immediate first. Notion's options are Recent/Current/Next/
    /// Backlog; this app's own are Now/Next/Later. Anything else is not recommended.
    static let stageRank: [String: Int] = ["now": 0, "current": 0, "next": 1]

    public static func isCompleted(_ record: ProjectGraphRecord, source: ProjectGraphSource,
                                   localWork: WorkItem?) -> Bool {
        if let localWork { return localWork.isOpen == false }
        return ProjectGraph.isCompleted(record, source: source)
    }

    /// Whether this record is the planning draft of a work file that still exists.
    public static func boundWork(_ record: ProjectGraphRecord, in workByPath: [String: WorkItem]) -> WorkItem? {
        record.localPath.flatMap { workByPath[$0] }
    }

    /// A task that is staged for now or next, not blocked, not paused, and whose
    /// dependencies are all complete. Tasks bound to a work file are left to
    /// `WorkItemRecommendation`, which already considered the file: recommending its
    /// draft as well is what put the same task in two "Next action" cards.
    public static func nextAction(among candidates: [ProjectGraphRecord],
                                  allRecords: [ProjectGraphRecord],
                                  source: (ProjectGraphRecord) -> ProjectGraphSource?,
                                  workByPath: [String: WorkItem]) -> ProjectGraphRecord? {
        let completedIDs = Set(allRecords.compactMap { record -> String? in
            guard let source = source(record),
                  isCompleted(record, source: source, localWork: boundWork(record, in: workByPath)) else { return nil }
            return ProjectGraph.normalizedID(record.pageID ?? record.id)
        })
        func rank(_ record: ProjectGraphRecord) -> Int? {
            guard record.kind == .tasks, boundWork(record, in: workByPath) == nil,
                  record.locallyDeleted != true, !record.remoteArchived, !record.archiveRequested,
                  let source = source(record), !isCompleted(record, source: source, localWork: nil) else { return nil }
            let status = record.value("Status", source: source).display.lowercased()
            guard !status.contains("blocked"), !status.contains("paused"), status != "duplicate" else { return nil }
            let dependencies = Set(["Dependencies", "Blocked by", "depends on"].flatMap {
                record.value($0, source: source)["relation"].array.compactMap { $0["id"].string }.map(ProjectGraph.normalizedID)
            })
            guard dependencies.isSubset(of: completedIDs) else { return nil }
            return stageRank[record.value("Work Stage", source: source).display.lowercased()]
        }
        return candidates.compactMap { record in rank(record).map { (record, $0) } }
            .sorted { lhs, rhs in
                if lhs.1 != rhs.1 { return lhs.1 < rhs.1 }
                return lhs.0.title.localizedStandardCompare(rhs.0.title) == .orderedAscending
            }
            .first?.0
    }

    /// The Notion status option for a work status. A current option that already means
    /// the same thing is kept: "Backlog" and "Todo" are both open, and rewriting one as
    /// the other made every saved task a pending change, and a conflict when Notion moved.
    public static func statusOption(for status: WorkItemStatus, current: String?, options: [String]) -> String? {
        func kind(_ name: String) -> WorkItemStatus? {
            switch name.lowercased().trimmingCharacters(in: .whitespaces) {
            case "done", "complete", "completed": return .completed
            case "in progress", "in-progress", "doing", "in development", "in review": return .inProgress
            case "open", "not started", "to do", "todo", "planned", "backlog": return .open
            default: return nil
            }
        }
        if let current, kind(current) == status { return current }
        let preferred: [String] = switch status {
        case .completed: ["done", "completed", "complete"]
        case .inProgress: ["in progress", "in-progress", "doing", "in development"]
        case .open: ["open", "not started", "to do", "todo", "planned", "backlog"]
        }
        for name in preferred { if let option = options.first(where: { $0.lowercased() == name }) { return option } }
        return nil
    }
}
