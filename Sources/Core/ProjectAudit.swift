import Foundation

public enum WorkActionAudience: String, CaseIterable, Sendable { case all, agent, user }

/// Optional scalar JSON in the portable record, preserved verbatim by older editors.
/// These audit ratings do not replace the person's project ratings or shared tags.
public struct WorkItemActionMetadata: Codable, Hashable, Sendable {
    public var version = 1
    public var fingerprint: String
    public var priority: String
    public var actionScore: Int
    public var delegation: String
    public var tags: [String]
    public var requirements: [String]
    public var agentExecutability: Int
    public var humanInvolvement: Int
    public var estimatedEffort: String
    public var category: String
    public var reason: String
    public var evidence: [String]
    public var agentSubtasks: [String]
    public var userSubtasks: [String]
    public var blockedBy: [String]
    public var isNextWork: Bool
    public var isNextAgentAction: Bool
    public var isNextUserAction: Bool

    public var isValid: Bool {
        version == 1 && !fingerprint.isEmpty && ["P0", "P1", "P2", "P3"].contains(priority)
            && (0...100).contains(actionScore) && (0...100).contains(agentExecutability)
            && (0...100).contains(humanInvolvement)
            && ["USER", "AGENT", "USER + AGENT"].contains(delegation)
            && !tags.isEmpty && !evidence.isEmpty && !reason.isEmpty
    }
    public var isAgentReady: Bool { delegation != "USER" && agentExecutability > 0 && !agentSubtasks.isEmpty && blockedBy.isEmpty }
    public var needsUser: Bool { delegation != "AGENT" && !userSubtasks.isEmpty }
    public var legacyPriority: WorkItemPriority { priority == "P3" ? .low : priority == "P2" ? .medium : .high }
}

extension WorkItem {
    public var actionMetadata: WorkItemActionMetadata? {
        get {
            guard let line = extraFrontMatter.first(where: { $0.hasPrefix("action-metadata:") }) else { return nil }
            let raw = String(line.dropFirst("action-metadata:".count)).trimmingCharacters(in: .whitespaces)
            guard let json = try? JSONDecoder().decode(String.self, from: Data(raw.utf8)),
                  let value = try? JSONDecoder().decode(WorkItemActionMetadata.self, from: Data(json.utf8)), value.isValid else { return nil }
            return value
        }
        set {
            // Refuse to destroy an unsupported version simply because this editor
            // cannot interpret it. The importer only supplies validated version 1.
            guard let value = newValue, value.isValid,
                  let data = try? JSONEncoder().encode(value),
                  let scalar = try? JSONEncoder().encode(String(decoding: data, as: UTF8.self)) else { return }
            extraFrontMatter.removeAll { $0.hasPrefix("action-metadata:") }
            extraFrontMatter.append("action-metadata: " + String(decoding: scalar, as: UTF8.self))
        }
    }
    public var actionPriorityLabel: String { actionMetadata?.priority ?? priority.rawValue.capitalized }
}

public struct ProjectAuditAssessment: Codable, Hashable, Sendable {
    public var version = 1
    public var projectID: String
    public var assessedAt: String
    public var classification: String
    public var recommendation: String
    public var scores: [String: Int]
    public var workPriorityScore: Int
    public var validationCoverage: String
    public var confidence: String
    public var nextWorkID: String?
    public var nextAgentActionID: String?
    public var nextUserActionID: String?
    public var notes: [String]
    public var commands: [String]
}

/// Private assessment state contains references to work records, never a second task
/// collection. It uses the existing private graph-state storage and schema.
public final class ProjectAuditStore: @unchecked Sendable {
    private let graph: ProjectGraphStore
    public init(database: Database) throws { graph = try ProjectGraphStore(database: database) }
    public func assessment(for projectID: String) throws -> ProjectAuditAssessment? {
        try graph.read("projectAudit:" + projectID, as: ProjectAuditAssessment.self)
    }
    public func save(_ assessment: ProjectAuditAssessment) throws {
        let names = Set(["FunctionalHealth", "Maintainability", "TestConfidence", "Documentation", "Completion", "CurrentUtility", "Uniqueness", "FuturePotential", "EaseOfProgress", "TechnicalRisk"])
        guard assessment.version == 1, !assessment.projectID.isEmpty,
              (0...100).contains(assessment.workPriorityScore),
              Set(assessment.scores.keys) == names, assessment.scores.values.allSatisfy({ (1...10).contains($0) }) else {
            throw ProjectAuditError.invalid("Invalid project assessment")
        }
        try graph.write("projectAudit:" + assessment.projectID, assessment)
    }
}

public enum ProjectAuditError: LocalizedError {
    case invalid(String)
    public var errorDescription: String? { if case .invalid(let message) = self { return message }; return nil }
}

/// Carries optional planning metadata in the existing CloudKit body field, without
/// requiring a production CloudKit schema deployment. The envelope is removed before
/// the description is displayed or compared during an explicit phone Save.
public enum MobileActionProjection {
    /// Features and milestones ride here too: one field the CloudKit schema already has,
    /// and older readers ignore keys they do not know.
    private struct Envelope: Codable {
        var metadata: WorkItemActionMetadata?; var dependencies: [String]
        var features: [String]?; var milestones: [String]?
        var createdAt: Date?; var modifiedAt: Date?; var completedAt: Date?; var notionPageID: String?
    }
    private static let prefix = "<!-- better-workspace-action-v1:"
    public static func encode(_ item: MobileWorkItem) -> String? {
        let features = (item.featureIDs ?? []).isEmpty ? nil : item.featureIDs
        let milestones = (item.milestoneIDs ?? []).isEmpty ? nil : item.milestoneIDs
        guard item.actionMetadata != nil || !(item.dependencyIDs ?? []).isEmpty || features != nil || milestones != nil || item.createdAt != nil || item.modifiedAt != nil || item.completedAt != nil || item.importedNotionPageID != nil else { return item.body }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(Envelope(metadata: item.actionMetadata, dependencies: item.dependencyIDs ?? [],
                                                      features: features, milestones: milestones, createdAt: item.createdAt, modifiedAt: item.modifiedAt, completedAt: item.completedAt, notionPageID: item.importedNotionPageID)) else { return item.body }
        let text = prefix + data.base64EncodedString() + " -->\n" + (item.body ?? "")
        // The planning edit limit applies to user descriptions, not this transport
        // envelope. Never replace a large existing description with a nil field.
        return text
    }
    public static func decode(_ raw: String?) -> (body: String?, metadata: WorkItemActionMetadata?, dependencies: [String]?,
                                                  features: [String]?, milestones: [String]?, createdAt: Date?, modifiedAt: Date?, completedAt: Date?, notionPageID: String?) {
        guard let raw, raw.hasPrefix(prefix), let end = raw.range(of: " -->\n"),
              let data = Data(base64Encoded: String(raw[raw.index(raw.startIndex, offsetBy: prefix.count)..<end.lowerBound])),
              let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
              envelope.metadata == nil || envelope.metadata?.isValid == true else { return (raw, nil, nil, nil, nil, nil, nil, nil, nil) }
        // A published item always says what it belongs to: absent lists are empty.
        return (String(raw[end.upperBound...]), envelope.metadata, envelope.dependencies,
                envelope.features ?? [], envelope.milestones ?? [], envelope.createdAt, envelope.modifiedAt, envelope.completedAt, envelope.notionPageID)
    }
}

extension WorkItemRecommendation {
    public static func nextMobileAction(in items: [MobileWorkItem], allItems: [MobileWorkItem]? = nil, audience: WorkActionAudience = .all, projectScores: [String: Double] = [:]) -> MobileWorkItem? {
        let selected = nextAction(in: items.map(portableForRecommendation), allItems: (allItems ?? items).map(portableForRecommendation), audience: audience, projectScores: projectScores)
        return items.first { $0.id == selected?.id }
    }

    static func portableForRecommendation(_ item: MobileWorkItem) -> WorkItem {
        var result = WorkItem(id: item.id, kind: item.kind, title: item.title, status: item.status,
            stage: item.stage, priority: item.priority, projectPath: item.projectPath,
            dependencyIDs: item.dependencyIDs ?? [], notionPageID: item.importedNotionPageID, url: URL(fileURLWithPath: "/unused"))
        result.actionMetadata = item.actionMetadata
        return result
    }
}

public struct ProjectAuditTodoInput: Codable, Sendable {
    public var id: String
    public var title: String
    public var description: String
    public var stage: WorkItemStage
    public var metadata: WorkItemActionMetadata
    public var existingID: String?
    public var expectedModifiedAt: Double?
    public var linkedNotionID: String?
    public var linkedExpectedBody: String?
    /// Only audit-created titles with an exact prior-title match may be clarified.
    public var expectedAuditTitle: String?
}

/// Read-only planning projection of reviewed Notion graph rows. Reuses the app's
/// migration planner, including authoritative relationships, stages, and page IDs.
public enum ProjectAuditLinkedWork {
    public static func items(database: Database, workspace: WorkspaceLocation, existing: [WorkItem]) throws -> [WorkItem] {
        let graph = try ProjectGraphStore(database: database)
        let sources = try graph.read("sources", as: [ProjectGraphSource].self) ?? []
        var input = NotionImport.Source()
        for row in try graph.records() where !row.local.isEmpty && !row.remoteArchived && !row.archiveRequested {
            guard let pageID = row.pageID, let source = sources.first(where: { $0.id == row.sourceID }) else { continue }
            var properties: [String: NotionValue] = [:]
            for (name, definition) in source.schema.object {
                let id = definition["id"].string ?? name
                guard let value = row.local[id] else { continue }
                // Local rich text may have content without Notion's plain_text
                // transport field. Display preserves both received and edited text.
                switch definition["type"].string {
                case "title": properties[name] = .title(value.display)
                case "rich_text", "url": properties[name] = .text(value.display)
                case "select", "status": if !value.display.isEmpty { properties[name] = .choice(value.display) }
                case "multi_select": properties[name] = .choices(value["multi_select"].array.map(\.display))
                case "relation": properties[name] = .relations(value["relation"].array.compactMap { $0["id"].string })
                case "number": if case .number(let number) = value["number"] { properties[name] = .number(number) }
                case "checkbox": if case .bool(let flag) = value["checkbox"] { properties[name] = .flag(flag) }
                case "date": if let date = value["date"]["start"].string { properties[name] = .date(date) }
                default: break
                }
            }
            let page = NotionPage(id: pageID, url: nil, createdTime: nil, lastEditedTime: row.editedAt, properties: properties)
            switch row.kind { case .tasks: input.tasks.append(page); case .features: input.features.append(page)
            case .milestones: input.milestones.append(page); case .projects: input.projects.append(page); default: break }
        }
        let records = ProjectStore(database: database).allRecords()
        let bindings = Dictionary(records.compactMap { row -> (String, ProjectRecord)? in
            guard let id = row.notionPageID else { return nil }; return (NotionImport.normalizedID(id), row)
        }, uniquingKeysWith: { first, _ in first })
        var options = NotionImport.Options(); options.includeIdeas = false; options.includeSocialPosts = false; options.includeIdeaProjects = false
        return NotionImport.plan(from: input, options: options, destinations: .init(workspace: workspace),
            projectsByNotionID: bindings, existingWorkItems: existing, existingIdeaNames: []).tasks.map(\.item)
            .filter { $0.projectPath != nil }
            .map { original in
                var item = original
                if let line = item.extraFrontMatter.first(where: { $0.hasPrefix("blocked-by:") }) {
                    let raw = String(line.dropFirst("blocked-by:".count)).trimmingCharacters(in: .whitespaces)
                    item.dependencyIDs = raw.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
                        .split(separator: ",").map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " \"")) }
                }
                return item
            }
    }
}
public struct ProjectAuditImportInput: Codable, Sendable {
    public var projectPath: String
    public var assessment: ProjectAuditAssessment
    public var todos: [ProjectAuditTodoInput]
    public var notionCategory: String?
}
public struct ProjectAuditWriteReceipt: Codable, Sendable {
    public var id: String
    public var path: String
    public var created: Bool
}
public struct ProjectAuditImportReceipt: Codable, Sendable {
    public var projectID: String
    public var writes: [ProjectAuditWriteReceipt]
    public var notionStatus: String
    public var nextWorkID: String?
    public var nextAgentActionID: String?
    public var nextUserActionID: String?
}

/// Explicit audit imports use the same conflict-aware file service as the app's
/// composer. Each completed write is retryable by ID/fingerprint after interruption.
public final class ProjectAuditImporter {
    private let db: Database
    private let projects: ProjectStore
    private let service = WorkItemService()
    private let reuseDiscovery: Bool
    private var discoveredItems: [WorkItem]?
    public init(database: Database, reuseDiscovery: Bool = false) { db = database; projects = ProjectStore(database: database); self.reuseDiscovery = reuseDiscovery }

    public func apply(_ input: ProjectAuditImportInput, workspace: WorkspaceLocation, queue: URL) throws -> ProjectAuditImportReceipt {
        let project = URL(fileURLWithPath: input.projectPath).canonical
        let projectRoot = workspace.url(for: .projects).canonicalPath
        guard project.deletingLastPathComponent().canonicalPath == projectRoot,
              !project.lastPathComponent.hasPrefix("_"), !project.lastPathComponent.hasPrefix("."),
              FileManager.default.fileExists(atPath: project.path),
              queue.canonicalPath.hasPrefix(workspace.root.canonicalPath + "/"),
              !queue.pathComponents.contains(where: { NoiseFilter.isForeignMetadata(name: $0) || $0.hasPrefix(".") }) else {
            throw ProjectAuditError.invalid("Audit imports require a real immediate project and a visible workspace work queue")
        }
        guard input.todos.allSatisfy({ $0.metadata.isValid }),
              Set(input.todos.map(\.id)).count == input.todos.count,
              input.todos.filter({ $0.metadata.isNextWork }).count <= 1,
              input.todos.filter({ $0.metadata.isNextAgentAction }).count <= 1,
              input.todos.filter({ $0.metadata.isNextUserAction }).count <= 1 else {
            throw ProjectAuditError.invalid("Invalid or ambiguous action metadata")
        }
        guard input.todos.allSatisfy({ todo in
            let m = todo.metadata
            let designated = m.isNextWork || m.isNextAgentAction || m.isNextUserAction
            return (!designated || (todo.stage != .later && m.blockedBy.isEmpty))
                && (!m.isNextAgentAction || m.isAgentReady) && (!m.isNextUserAction || m.needsUser)
        }) else { throw ProjectAuditError.invalid("A recommendation is blocked, deferred, or lacks an actionable owner portion") }
        let record = projects.register(url: project)
        guard let persisted = projects.record(id: record.id), persisted.url.canonicalPath == project.canonicalPath else {
            throw ProjectAuditError.invalid("Project registration did not persist; database is locked or unavailable. Retry after the active writer completes.")
        }
        let relative = "Projects/" + project.lastPathComponent
        var items = (reuseDiscovery ? discoveredItems : nil) ?? service.items(under: workspace.root)
        let linkedDrafts = input.todos.contains(where: { $0.linkedNotionID != nil }) ? try ProjectAuditLinkedWork.items(database: db, workspace: workspace, existing: items) : []
        var receipts: [ProjectAuditWriteReceipt] = []
        for todo in input.todos {
            let equivalent = items.first { $0.id == (todo.existingID ?? todo.id) ||
                ($0.projectPath == relative && $0.actionMetadata?.fingerprint == todo.metadata.fingerprint) }
            var work: WorkItem
            let created: Bool
            if var existing = equivalent {
                if reuseDiscovery {
                    guard let current = service.read(at: existing.url), current.id == existing.id else { throw ProjectAuditError.invalid("Existing work disappeared during portfolio import: " + existing.title) }
                    existing = current
                }
                guard existing.projectPath == relative || existing.projectPath == project.canonicalPath else {
                    throw ProjectAuditError.invalid("An existing action belongs to a different project: " + todo.title)
                }
                guard !existing.extraFrontMatter.contains(where: { $0.hasPrefix("action-metadata:") }) || existing.actionMetadata != nil else {
                    throw ProjectAuditError.invalid("Unsupported action metadata preserved: " + existing.title)
                }
                if let expected = todo.expectedModifiedAt, let actual = existing.modifiedAt,
                   abs(actual.timeIntervalSince1970 - expected) > 0.001,
                   existing.actionMetadata != todo.metadata {
                    throw ProjectAuditError.invalid("Existing work changed after audit review: " + existing.title)
                }
                guard existing.isOpen || !todo.metadata.isNextWork else { throw ProjectAuditError.invalid("Completed work cannot be NEXT WORK") }
                if let expected = todo.expectedAuditTitle, existing.title != todo.title {
                    guard existing.title == expected, existing.actionMetadata?.fingerprint == todo.metadata.fingerprint,
                          todo.metadata.fingerprint.hasPrefix("audit:") else { throw ProjectAuditError.invalid("Audit title changed after review: " + existing.title) }
                    existing.title = todo.title
                }
                if existing.actionMetadata == todo.metadata && existing.priority == todo.metadata.legacyPriority && (todo.expectedAuditTitle == nil || equivalent?.title == todo.title) { work = existing }
                else { existing.actionMetadata = todo.metadata; existing.priority = todo.metadata.legacyPriority; work = try service.update(existing) }
                created = false
            } else {
                if todo.existingID != nil { throw ProjectAuditError.invalid("Existing work disappeared: " + todo.title) }
                var draft: WorkItem
                if let linkedID = todo.linkedNotionID {
                    guard let original = linkedDrafts.first(where: { $0.id == linkedID && $0.projectPath == relative }),
                          original.body == todo.linkedExpectedBody, original.title == todo.title else {
                        throw ProjectAuditError.invalid("Linked Notion work changed after review: " + todo.title)
                    }
                    draft = original
                } else {
                    draft = WorkItem(id: todo.id, kind: .task, title: todo.title, stage: todo.stage,
                        priority: todo.metadata.legacyPriority, projectPath: relative,
                        body: body(for: todo), url: queue.appendingPathComponent("placeholder"))
                }
                draft.priority = todo.metadata.legacyPriority
                draft.actionMetadata = todo.metadata
                work = try service.create(draft, in: queue); created = true
            }
            items = WorkItemService.merged(items, upserting: [work], removingPaths: [])
            if reuseDiscovery { discoveredItems = items }
            receipts.append(.init(id: work.id, path: work.url.path, created: created))
        }
        var assessment = input.assessment; assessment.projectID = record.id
        let linked = items.filter { $0.projectPath == relative || $0.projectPath == project.canonicalPath }
        assessment.nextWorkID = WorkItemRecommendation.nextAction(in: linked, allItems: items)?.id
        assessment.nextAgentActionID = WorkItemRecommendation.nextAction(in: linked, allItems: items, audience: .agent)?.id
        assessment.nextUserActionID = WorkItemRecommendation.nextAction(in: linked, allItems: items, audience: .user)?.id
        try ProjectAuditStore(database: db).save(assessment)
        let notionStatus: String
        if assessment.classification == "ARCHIVE CANDIDATE" { notionStatus = "Preserved legacy; no Notion proposal" }
        else {
            do { notionStatus = try stageNotion(assessment, items: linked, record: record, category: input.notionCategory) }
            catch { notionStatus = "Proposed; Notion staging blocked: " + String(describing: error) }
        }
        return .init(projectID: record.id, writes: receipts, notionStatus: notionStatus,
                     nextWorkID: assessment.nextWorkID, nextAgentActionID: assessment.nextAgentActionID, nextUserActionID: assessment.nextUserActionID)
    }

    private func body(for todo: ProjectAuditTodoInput) -> String {
        let m = todo.metadata
        var lines = [todo.description, "", "## Why", m.reason, "", "## Evidence"] + m.evidence.map { "- " + $0 }
        lines += ["", "## Action details", "- Priority: \(m.priority) · Action Score: \(m.actionScore)/100",
                  "- Delegation: \(m.delegation)", "- Tags: " + m.tags.joined(separator: ", "),
                  "- Requirements: " + m.requirements.joined(separator: ", "),
                  "- Agent Executability: \(m.agentExecutability)/100 · Human Involvement: \(m.humanInvolvement)/100",
                  "- Estimated effort: " + m.estimatedEffort]
        if !m.agentSubtasks.isEmpty { lines += ["", "## Agent subtasks"] + m.agentSubtasks.map { "- [ ] " + $0 } }
        if !m.userSubtasks.isEmpty { lines += ["", "## User subtasks"] + m.userSubtasks.map { "- [ ] " + $0 } }
        if !m.blockedBy.isEmpty { lines += ["", "## Blockers"] + m.blockedBy.map { "- " + $0 } }
        return lines.joined(separator: "\n")
    }

    private func stageNotion(_ audit: ProjectAuditAssessment, items: [WorkItem], record: ProjectRecord, category: String?) throws -> String {
        guard let pageID = record.notionPageID else { return "No established Notion project binding" }
        let store = try ProjectGraphStore(database: db)
        guard var graph = try store.records().first(where: { $0.kind == .projects && $0.pageID.map(ProjectGraph.normalizedID) == ProjectGraph.normalizedID(pageID) }),
              let source = try store.read("sources", as: [ProjectGraphSource].self)?.first(where: { $0.id == graph.sourceID }) else {
            return "Proposed; bound Notion project is not in the reviewed graph"
        }
        var details: [String] = []
        for (name, id) in [("NEXT WORK", audit.nextWorkID), ("NEXT AGENT ACTION", audit.nextAgentActionID), ("NEXT USER ACTION", audit.nextUserActionID)] {
            if let item = items.first(where: { $0.id == id }) {
                let step = name == "NEXT AGENT ACTION" ? item.actionMetadata?.agentSubtasks.first : name == "NEXT USER ACTION" ? item.actionMetadata?.userSubtasks.first : nil
                details.append(name + ": " + (step ?? item.title))
            }
        }
        let owner = "pid:\(ProcessInfo.processInfo.processIdentifier):\(UUID().uuidString)"
        guard try store.acquire(owner: owner) else { return "Proposed; Notion coordinator is busy" }
        defer { try? store.release(owner: owner) }
        // Read again under the coordinator lease before comparing unsent edits.
        guard let current = try store.record(id: graph.id) else { return "Proposed; Notion project changed during staging" }
        graph = current
        guard let property = source.property(named: "Next Work Details"), source.writable(property.id) else {
            return "Proposed; writable Next Work Details property unavailable"
        }
        // Preserve an existing unsent local edit. The normal Send review compares
        // the new desired value with remote/baseline and handles remote conflicts.
        if graph.changes.contains(where: { $0.id == property.id && [.outgoing, .conflict].contains($0.state) }),
           graph.value("Next Work Details", source: source).display != details.joined(separator: "\n"),
           graph.value("Next Work Details", source: source).display != (try store.read("projectAuditNotionReceipt:" + record.id, as: String.self)) {
            return "Proposed; existing unsent Next Work Details preserved"
        }
        graph.set("Next Work Details", value: ProjectServiceBridge.text(details.joined(separator: "\n")), source: source)
        if let category, let field = source.property(named: "Next Work"), source.writable(field.id),
           field.definition["multi_select"]["options"].array.contains(where: { $0["name"].string == category }) {
            if !graph.changes.contains(where: { $0.id == field.id && [.outgoing, .conflict].contains($0.state) }) {
                graph.set("Next Work", value: ProjectJSON([["name": category]]), source: source)
            }
        }
        if let field = source.property(named: "Needs Next Work Analysis"), source.writable(field.id) {
            if !graph.changes.contains(where: { $0.id == field.id && [.outgoing, .conflict].contains($0.state) }) {
                graph.set("Needs Next Work Analysis", value: .bool(false), source: source)
            }
        }
        if let field = source.property(named: "status details"), source.writable(field.id),
           graph.value("status details", source: source).display.isEmpty,
           !graph.changes.contains(where: { $0.id == field.id && [.outgoing, .conflict].contains($0.state) }) {
            graph.set("status details", value: ProjectServiceBridge.text("Workspace audit \(audit.assessedAt.prefix(10)): \(audit.classification). \(audit.validationCoverage). \(audit.recommendation)"), source: source)
        }
        try store.save(graph)
        try store.write("projectAuditNotionReceipt:" + record.id, details.joined(separator: "\n"))
        return "Staged locally; reviewed Send to Notion required"
    }
}

public enum ProjectAssessmentScore {
    public static func name(_ raw: String) -> String { raw.replacingOccurrences(of: "([a-z])([A-Z])", with: "$1 $2", options: .regularExpression) }
    public static func explanation(_ key: String) -> String {
        switch key {
        case "FunctionalHealth": return "How reliably the project's current behavior works. A low score suggests repair before expansion."
        case "Maintainability": return "How easy the project is to understand, change and maintain."
        case "TestConfidence": return "How much validation supports confidence in the current behavior. See the assessment's validation coverage."
        case "Documentation": return "How well setup, usage and maintenance are explained."
        case "Completion": return "How far the project has progressed toward its intended scope; this is an assessment, not a task completion percentage."
        case "CurrentUtility": return "How useful the project is today."
        case "Uniqueness": return "How distinctive the project's contribution is."
        case "FuturePotential": return "How much value further development could unlock."
        case "EaseOfProgress": return "How readily the next useful improvement can be made."
        case "TechnicalRisk": return "Higher means MORE risk: technical uncertainty or fragility that may make changes harder. This scale runs in the opposite direction to the other scores."
        default: return "An audit assessment on a 1–10 scale."
        }
    }
}
