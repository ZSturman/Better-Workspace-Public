import Foundation

/// Fully prepared private sync state. Build off-thread, then publish as one UI update.
public struct ProjectGraphSnapshot: Sendable {
    public let records: [ProjectGraphRecord]
    public let sources: [ProjectGraphSource]
    public let index: ProjectGraphIndex
    public let mediaIndex: ProjectGraphIndex
    public let syncIndex: ProjectGraphIndex
    public let projectsByLocalID: [String: ProjectGraphRecord]
    public let projectsByPageID: [String: ProjectGraphRecord]
    public let sourcesByID: [String: ProjectGraphSource]
    public let incomingIDs: Set<String>
    public let outgoingIDs: Set<String>
    public let report: ProjectSyncReport?
    public let triage: [ProjectSyncTriage.Item]
    public let deferred: [String: String]
    public let failures: [String: ProjectAutoSyncPlanner.Failure]
    public let syncReport: ProjectAutoSync.Report?
    public let actionReport: ProjectAutoSync.Report?
    public let lastChangesReport: ProjectAutoSync.Report?

    init(records allRecords: [ProjectGraphRecord], state: [String: String]) throws {
        func read<T: Decodable>(_ key: String, _ type: T.Type) throws -> T? {
            try state[key].map { try JSONDecoder().decode(type, from: Data($0.utf8)) }
        }
        records = allRecords.filter { $0.locallyDeleted != true }
        sources = try read("sources", [ProjectGraphSource].self) ?? []
        index = ProjectGraphIndex(records: records)
        mediaIndex = ProjectGraphIndex(records: records, readingIncoming: true)
        syncIndex = ProjectGraphIndex(records: records, includingIncoming: true)
        let projects = records.filter { $0.kind == .projects }
        projectsByLocalID = Dictionary(projects.compactMap { record in record.localProjectID.map { ($0, record) } }, uniquingKeysWith: { first, _ in first })
        projectsByPageID = Dictionary(projects.compactMap { record in record.pageID.map { (ProjectGraph.normalizedID($0), record) } }, uniquingKeysWith: { first, _ in first })
        sourcesByID = Dictionary(sources.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var incoming: Set<String> = [], outgoing: Set<String> = []
        for record in records {
            if record.baseline.isEmpty && !record.remote.isEmpty { incoming.insert(record.id) }
            else {
                let changes = record.changes
                if changes.contains(where: { [.incoming, .conflict].contains($0.state) }) { incoming.insert(record.id) }
                if changes.contains(where: { [.outgoing, .conflict].contains($0.state) }) { outgoing.insert(record.id) }
            }
            if record.remoteArchived != (record.acknowledgedArchived ?? false) { incoming.insert(record.id) }
            if record.pageID == nil || record.archiveRequested || record.serviceAcknowledgementPending == true || !(record.pendingUploads ?? []).isEmpty { outgoing.insert(record.id) }
        }
        incomingIDs = incoming; outgoingIDs = outgoing
        report = try read("report", ProjectSyncReport.self)
        triage = ProjectSyncTriage.items(records: records, sources: sources)
        deferred = try read(ProjectAutoSync.deferredKey, [String: String].self) ?? [:]
        failures = try read(ProjectAutoSync.failuresKey, [String: ProjectAutoSyncPlanner.Failure].self) ?? [:]
        syncReport = try read(ProjectAutoSync.reportKey, ProjectAutoSync.Report.self)
        actionReport = try read(ProjectAutoSync.actionReportKey, ProjectAutoSync.Report.self)
        lastChangesReport = try read(ProjectAutoSync.lastMergesKey, ProjectAutoSync.Report.self) ?? read(ProjectAutoSync.lastChangesKey, ProjectAutoSync.Report.self)
    }
}
