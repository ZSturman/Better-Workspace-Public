import Foundation
import BetterWorkspaceCore

extension AppModel {
    /// Called only after an explicit reviewed Get/Send, never by background detection.
    func materializeGraphWork(_ record: ProjectGraphRecord, createFiles: Bool = true) async throws {
        guard record.locallyDeleted != true, let source = graphSource(for: record), let pageID = record.pageID, [.features, .milestones, .tasks].contains(record.kind) else { return }
        let projectPageIDs = source.schema.object.keys.filter { name in
            source.property(named: name)?.definition["relation"]["data_source_id"].string == graphSources.first { $0.kind == .projects }?.id
        }.flatMap { record.value($0, source: source)["relation"].array.compactMap { $0["id"].string }.map(ProjectGraph.normalizedID) }
        guard let linkedProject = graphRecords.first(where: { $0.kind == .projects && $0.pageID.map(ProjectGraph.normalizedID).map(projectPageIDs.contains) == true && $0.localPath != nil }),
              let item = projects().first(where: { $0.url.canonicalPath == linkedProject.localPath }) else { return }
        let existing = workItems.first { work in work.importedNotionPageID.map(ProjectGraph.normalizedID) == ProjectGraph.normalizedID(pageID) }
        guard existing != nil || createFiles else { return }
        let kind: WorkItemKind = record.kind == .tasks ? .task : record.kind == .features ? .feature : .milestone
        func ids(_ names: [String]) -> [String] {
            let remote = names.flatMap { record.value($0, source: source)["relation"].array.compactMap { $0["id"].string } }
            return Array(Set(remote.map { id in
                let graph = graphRecords.first { $0.pageID.map(ProjectGraph.normalizedID) == ProjectGraph.normalizedID(id) }
                return workItems.first { $0.importedNotionPageID.map(ProjectGraph.normalizedID) == ProjectGraph.normalizedID(id) }?.id ?? graph?.id ?? id
            })).sorted()
        }
        var work = existing ?? WorkItem(id: record.id, kind: kind, title: record.title, url: item.url.appendingPathComponent("placeholder"))
        work.notionPageID = pageID; work.title = record.title
        work.projectPath = workspaceRelativePath(for: item.url)
        work.parentIDs = ids(["Parent Feature", "Parent Task", "Parent item", "Parent"])
        work.parentID = work.parentIDs.first
        work.featureIDs = ids(["Features", "Feature"]); work.milestoneIDs = ids(["Milestones", "Milestone"])
        work.dependencyIDs = ids(["Dependencies", "Blocked by", "depends on"])
        let status = record.value("Status", source: source).display.lowercased()
        if !status.isEmpty { work.status = ["done", "completed", "complete"].contains(status) ? .completed : status.contains("progress") ? .inProgress : .open }
        if record.value("Complete", source: source)["checkbox"].bool { work.status = .completed }
        if let stage = WorkItemStage(rawValue: record.value("Work Stage", source: source).display.lowercased()) { work.stage = stage }
        if let priority = WorkItemPriority(rawValue: record.value("Priority", source: source).display.lowercased()) { work.priority = priority }
        if let name = ["due date (manual)", "due date", "Due"].first(where: { source.property(named: $0)?.definition["type"].string == "date" }) {
            work.dueDate = record.value(name, source: source)["date"]["start"].string.flatMap { ProjectDates.parse($0) ?? DateFormatter.projectGraphDay.date(from: $0) }
        }
        let service = workItemService, destination = WorkQueueRouting.folder(for: kind, among: folders)?.url ?? workspace.url(forArea: "To Do")
        let saved = try await Task.detached { try existing == nil ? service.create(work, in: destination) : service.update(work) }.value
        adopt(saved)
        var bound = graphRecords.first { $0.id == record.id } ?? record; bound.localPath = saved.url.canonicalPath
        try ProjectGraphStore(database: database).save(bound)
    }

    func bindExistingGraphWork() {
        do {
            let store = try ProjectGraphStore(database: database)
            for work in workItems {
                guard let id = work.importedNotionPageID, var record = graphRecords.first(where: { $0.pageID.map(ProjectGraph.normalizedID) == ProjectGraph.normalizedID(id) }), let source = graphSource(for: record), record.local.isEmpty, record.baseline.isEmpty else { continue }
                var owned: [String: ProjectJSON] = [:]
                for (name, schema) in source.schema.object where schema["type"].string == "title" { owned[name] = ProjectServiceBridge.text(work.title) }
                owned["Complete"] = .bool(!work.isOpen)
                if let field = source.property(named: "Work Stage"), let option = field.definition["select"]["options"].array.compactMap({ $0["name"].string }).first(where: { $0.lowercased() == work.stage.rawValue }) { owned["Work Stage"] = ProjectJSON(["name": option]) }
                if let date = work.dueDate, let name = ["due date (manual)", "due date", "Due"].first(where: { source.property(named: $0)?.definition["type"].string == "date" }) { owned[name] = ProjectJSON(["start": DateFormatter.projectGraphDay.string(from: date)]) }
                if let field = source.property(named: "Status"), let type = field.definition["type"].string,
                   let name = ProjectGraphPlanning.statusOption(for: work.status, current: record.value("Status", source: source)[type]["name"].string,
                                                                 options: field.definition[type]["options"].array.compactMap { $0["name"].string }) { owned["Status"] = ProjectJSON(["name": name]) }
                record.seedInitialLocalState(owned, source: source)
                record.localPath = work.url.canonicalPath
                try store.save(record)
            }
        } catch { lastError = error.localizedDescription }
    }

    func isComputedNotionMilestone(_ work: WorkItem) -> Bool {
        guard work.kind == .milestone, work.importedNotionPageID != nil else { return false }
        guard let source = graphSources.first(where: { $0.kind == .milestones }), let field = source.property(named: "Status") else { return true }
        return !source.writable(field.id)
    }

    func queueGraphWork(_ work: WorkItem) {
        let kind: ProjectEntityKind
        switch work.kind { case .task: kind = .tasks; case .feature: kind = .features; case .milestone: kind = .milestones; case .goal: return }
        guard let source = graphSources.first(where: { $0.kind == kind }) else { return }
        var record = graphRecords.first { $0.localPath == work.url.canonicalPath || (work.importedNotionPageID != nil && $0.pageID.map(ProjectGraph.normalizedID) == work.importedNotionPageID.map(ProjectGraph.normalizedID)) }
            ?? ProjectGraphRecord(id: work.id, pageID: work.importedNotionPageID, sourceID: source.id, kind: kind)
        guard record.kind == kind else { lastError = "This work item is linked to a different Notion record type. Review its Notion binding before syncing."; return }
        record.localPath = work.url.canonicalPath
        for (name, schema) in source.schema.object where schema["type"].string == "title" {
            if record.value(name, source: source).display != work.title { record.set(name, value: ProjectServiceBridge.text(work.title), source: source) }
        }
        let statusChoices = source.property(named: "Status")?.definition
        let statusType = statusChoices?["type"].string ?? "status"
        let choices = statusChoices?[statusType]["options"].array.compactMap { $0["name"].string } ?? []
        let currentStatus = record.value("Status", source: source)[statusType]["name"].string
        if let status = ProjectGraphPlanning.statusOption(for: work.status, current: currentStatus, options: choices), status != currentStatus {
            record.set("Status", value: ProjectJSON(["name": status]), source: source)
        }
        record.set("Complete", value: .bool(!work.isOpen), source: source)
        if let field = source.property(named: "Work Stage"), let option = field.definition["select"]["options"].array.first(where: { $0["name"].display.lowercased() == work.stage.rawValue })?["name"].string { record.set("Work Stage", value: ProjectJSON(["name": option]), source: source) }
        if let field = source.property(named: "Priority"), ["select", "status"].contains(field.definition["type"].string ?? "") { let type = field.definition["type"].string!; if let option = field.definition[type]["options"].array.first(where: { $0["name"].display.lowercased() == work.priority.rawValue })?["name"].string { record.set("Priority", value: ProjectJSON(["name": option]), source: source) } }
        if let path = work.projectPath, let local = projects().first(where: { workspaceRelativePath(for: $0.url) == path || $0.url.canonicalPath == path }), let project = graphProject(for: local) {
            for (name, schema) in source.schema.object where schema["type"].string == "relation" && schema["relation"]["data_source_id"].string == project.sourceID {
                var relations = record.value(name, source: source)["relation"].array
                let id = project.pageID ?? project.id
                if !relations.contains(where: { $0["id"].string == id }) { relations.append(ProjectJSON(["id": id])) }
                record.set(name, value: .array(relations), source: source)
            }
        }
        if let name = ["due date (manual)", "due date", "Due"].first(where: { source.property(named: $0)?.definition["type"].string == "date" }) {
            let previous = record.value(name, source: source)["date"]
            if previous["start"].string.flatMap(ProjectDates.parse) != work.dueDate {
                var date = previous.object
                if let due = work.dueDate { date["start"] = .string(DateFormatter.projectGraphDay.string(from: due)) }
                record.set(name, value: work.dueDate == nil ? .null : .object(date), source: source)
            }
        }
        let canClearRelations = work.notionPageID != nil || record.pageID == nil
        func linked(_ id: String) -> ProjectGraphRecord? {
            let portablePageID = workItems.first { $0.id == id }?.importedNotionPageID.map(ProjectGraph.normalizedID)
            return graphRecords.first { $0.id == id || $0.pageID.map(ProjectGraph.normalizedID) == ProjectGraph.normalizedID(id) || (portablePageID != nil && $0.pageID.map(ProjectGraph.normalizedID) == portablePageID) }
        }
        func setRelations(_ names: [String], ids: [String]) {
            guard let name = names.first(where: { source.property(named: $0)?.definition["type"].string == "relation" }), let target = source.property(named: name)?.definition["relation"]["data_source_id"].string else { return }
            let resolved = ids.compactMap { id -> String? in
                if let record = linked(id) { return record.sourceID == target ? record.pageID ?? record.id : nil }
                return id
            }
            if !canClearRelations && resolved.isEmpty { return }
            var references = canClearRelations ? [] : record.value(name, source: source)["relation"].array.compactMap { $0["id"].string }
            references += resolved
            record.set(name, value: ProjectJSON(Array(Set(references)).sorted().map { ["id": $0] }), source: source)
        }
        let parents = Array(Set(work.parentIDs + (work.parentID.map { [$0] } ?? [])))
        setRelations(["Parent Feature", "Parent Task", "Parent item", "Parent"], ids: parents)
        setRelations(["Features", "Feature"], ids: work.featureIDs + parents.filter { linked($0)?.kind == .features && kind != .features })
        setRelations(["Milestones", "Milestone"], ids: work.milestoneIDs + parents.filter { linked($0)?.kind == .milestones && kind != .milestones })
        setRelations(["Dependencies", "Blocked by", "depends on"], ids: work.dependencyIDs)
        saveGraphRecord(record)
    }
}
private extension DateFormatter {
    static var projectGraphDay: DateFormatter { let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd"; formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(secondsFromGMT: 0); return formatter }
}
