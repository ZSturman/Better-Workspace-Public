import Foundation
import BetterWorkspaceCore

extension AppModel {
    func queueServiceProjectGraph() async {
        guard !TestIsolation.isActive else { return }
        do {
            let store = try ProjectGraphStore(database: database)
            let storedRecords = try await Task.detached(priority: .utility) { try store.records() }.value
            let ownsWrites = try store.read("serviceWriterClaimed", as: Bool.self) == true
            // Bind identities through the API even before writer handoff. Reads alone
            // must not adopt the service's values or queue duplicate Notion pages.
            if !ownsWrites {
                var changed = false
                for var record in storedRecords where [.ideas, .workLogs].contains(record.kind) {
                    let id = record.kind == .ideas
                        ? serviceIdeasByPath.values.first { $0.notionPageID != nil && $0.notionPageID.map(ProjectGraph.normalizedID) == record.pageID.map(ProjectGraph.normalizedID) }?.id
                        : workLogs.first { $0.notionPageID != nil && $0.notionPageID.map(ProjectGraph.normalizedID) == record.pageID.map(ProjectGraph.normalizedID) }?.id
                    if let id, record.serviceRecordID != id { record.serviceRecordID = id; try store.save(record); changed = true }
                }
                if changed { reloadProjectGraph() }
                return
            }
            var records = storedRecords
            let localProjects = projectStore.allRecords()
            func initial(_ kind: ProjectEntityKind, id: String, pageID: String?, source: ProjectGraphSource) -> ProjectGraphRecord {
                records.first { $0.kind == kind && ($0.serviceRecordID == id || (pageID != nil && $0.pageID.map(ProjectGraph.normalizedID) == pageID.map(ProjectGraph.normalizedID))) }
                    ?? .init(id: "service:\(kind.rawValue):\(id)", pageID: pageID, sourceID: source.id, kind: kind)
            }
            func save(_ record: ProjectGraphRecord) throws {
                if records.first(where: { $0.id == record.id }) != record { try store.save(record); records.removeAll { $0.id == record.id }; records.append(record) }
            }
            if let source = graphSources.first(where: { $0.kind == .ideas }) {
                for idea in serviceIdeasByPath.values {
                    var values: [String: ProjectJSON] = ["idea": ProjectServiceBridge.text(idea.title), "one liner": ProjectServiceBridge.text(idea.oneLiner),
                        "type": idea.type.map { ProjectJSON(["name": $0]) } ?? .null, "status": idea.status.map { ProjectJSON(["name": $0]) } ?? .null,
                        "impact": idea.impact.map { ProjectJSON(["name": $0]) } ?? .null, "effort": idea.effort.map { ProjectJSON(["name": $0]) } ?? .null,
                        "tags": ProjectJSON(idea.tags.map { ["name": $0] }), "keep suggesting": .bool(idea.keepSuggesting),
                        "defer until": idea.deferUntil.map { ProjectJSON(["start": ISO8601DateFormatter().string(from: $0)]) } ?? .null,
                        "Workspace Watcher ID": ProjectServiceBridge.text(idea.id)]
                    let linked = idea.relatedProjects.compactMap { name -> String? in
                        let matches = records.filter { $0.kind == .projects && $0.title == name }
                        if matches.count == 1 { return matches[0].pageID ?? matches[0].id }
                        return localProjects.first { $0.name == name }.flatMap { graphProjectsByLocalID[$0.id] }.map { $0.pageID ?? $0.id }
                    }
                    // Do not discard unresolved service project associations.
                    if linked.count == idea.relatedProjects.count { values["projects"] = ProjectJSON(linked.map { ["id": $0] }) }
                    try save(ProjectServiceBridge.applying(values, serviceID: idea.id, to: initial(.ideas, id: idea.id, pageID: idea.notionPageID, source: source), source: source))
                }
            }
            if let source = graphSources.first(where: { $0.kind == .workLogs }) {
                for log in workLogs {
                    var values: [String: ProjectJSON] = ["entry": ProjectServiceBridge.text("\(log.projectName) · \(log.dateKey)"),
                        "date": ProjectJSON(["start": String(log.dateKey.prefix(10))]), "active seconds": .number(log.activeMinutes * 60),
                        "sessions_count": .number(Double(log.sessionCount)), "progress_summary": ProjectServiceBridge.text(log.summary)]
                    if let projectID = log.projectID, let local = localProjects.first(where: { $0.watcherID == projectID }), let project = graphProjectsByLocalID[local.id] { values["project"] = ProjectJSON([["id": project.pageID ?? project.id]]) }
                    try save(ProjectServiceBridge.applying(values, serviceID: log.id, to: initial(.workLogs, id: log.id, pageID: log.notionPageID, source: source), source: source))
                }
            }
            if graphRecords != records { reloadProjectGraph() }
        } catch { lastError = error.localizedDescription }
    }
    func claimServiceProjectGraphWriter() async throws {
        guard await BackgroundServiceClient.shared.claimProjectGraphWriter() else { throw NotionProjectSync.SyncError.unsupported("Update and start the bundled service in Settings → Service before sending Ideas or Work Logs. Its existing Notion writers must hand off ownership first.") }
        try ProjectGraphStore(database: database).write("serviceWriterClaimed", true)
    }
    func acknowledgeServiceGraphRecords(_ selected: Set<String>) async throws {
        let store = try ProjectGraphStore(database: database)
        let records = try await Task.detached(priority: .utility) { try store.records() }.value
        for var record in records where selected.contains(record.id) {
            guard [.ideas, .workLogs].contains(record.kind), let id = record.serviceRecordID, let pageID = record.pageID else { continue }
            if record.kind == .ideas, let source = graphSource(for: record) {
                var changes = IdeaChanges()
                func present(_ name: String) -> Bool { source.property(named: name).map { record.local[$0.id] != nil } ?? false }
                if present("idea") { changes.title = record.value("idea", source: source).display }
                if present("status") { changes.status = record.value("status", source: source).display }
                if present("type") { changes.type = record.value("type", source: source).display }
                if present("impact") { changes.impact = record.value("impact", source: source).display }
                if present("effort") { changes.effort = record.value("effort", source: source).display }
                if present("one liner") { changes.oneLiner = record.value("one liner", source: source).display }
                if present("tags") { changes.tags = record.value("tags", source: source)["multi_select"].array.compactMap { $0["name"].string } }
                if present("keep suggesting") { changes.keepSuggesting = record.value("keep suggesting", source: source)["checkbox"].bool }
                if present("defer until") { changes.deferUntil = record.value("defer until", source: source)["date"]["start"].string ?? "" }
                if present("projects") {
                    let ids = record.value("projects", source: source)["relation"].array.compactMap { $0["id"].string }.map(ProjectGraph.normalizedID)
                    let names = ids.compactMap { graphProjectsByPageID[$0]?.title }
                    if names.count == ids.count { changes.relatedProjects = names }
                }
                if !changes.isEmpty {
                    guard let updated = await BackgroundServiceClient.shared.updateIdea(id: id, changes) else {
                        record.serviceAcknowledgementPending = true; record.error = "The reviewed idea is saved privately, but the service has not applied its metadata. Retry Send to Notion."; try store.save(record)
                        throw NotionProjectSync.SyncError.unsupported(record.error!)
                    }
                    serviceIdeasByPath[updated.canonicalPath] = updated
                    // Prevent the next API refresh from echoing the just-applied fields
                    // back as new edits. Observed work-log values remain service-owned.
                    var snapshot = record.serviceSnapshot ?? [:]
                    for name in ["idea", "one liner", "type", "status", "impact", "effort", "tags", "keep suggesting", "defer until", "projects"] {
                        if let field = source.property(named: name), let value = record.local[field.id], let type = value["type"].string { snapshot[field.id] = value[type] }
                    }
                    record.serviceSnapshot = snapshot
                }
            }
            guard await BackgroundServiceClient.shared.acknowledgeGraphLink(kind: record.kind, recordID: id, pageID: pageID) else {
                record.serviceAcknowledgementPending = true; record.error = "Notion saved this record, but the service has not acknowledged its page ID. Retry Send to Notion."; try store.save(record)
                throw NotionProjectSync.SyncError.unsupported(record.error!)
            }
            record.serviceAcknowledgementPending = false; record.error = nil; try store.save(record)
        }
    }
}
