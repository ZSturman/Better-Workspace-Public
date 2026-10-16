import Foundation

/// A deliberately small, read-only bridge from a Notion Projects page to the
/// metadata Better Workspace owns locally.  It never knows about a database, a
/// network request, or a project folder, which keeps previews deterministic and makes
/// a fetched page safe to review while offline.
public enum ProjectMetadataImport {
    /// Local fields that can be shown, selected, and applied independently.  Project
    /// priority is intentionally absent: the configured database's `tracking priority`
    /// is evidence from its old workflow, not a generic instruction to prioritize a
    /// project in Better Workspace.
    public enum Field: String, CaseIterable, Hashable, Sendable, Identifiable {
        case oneLiner, summary
        case domain, status, phase, completionModel, maintenanceCadence, projectType
        case workModes, currentWork, nextWork, recentWork, blockers, statusDetail
        case startedAt, lastUpdateAt, trackingPriority, relatedProjects
        case github, website, resources, collections, media, tasks, features, milestones, workLogs

        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .oneLiner: return "One liner"
            case .summary: return "Summary"
            case .domain: return "Domain"
            case .status: return "Status"
            case .phase: return "Phase"
            case .completionModel: return "Completion model"
            case .maintenanceCadence: return "Maintenance cadence"
            case .projectType: return "Project type"
            case .workModes: return "Work mode"
            case .currentWork: return "Current work"
            case .nextWork: return "Next work"
            case .recentWork: return "Recent work"
            case .blockers: return "Blocked by"
            case .statusDetail: return "Status details"
            case .startedAt: return "Started at"
            case .lastUpdateAt: return "Last update"
            case .trackingPriority: return "Tracking priority"
            case .relatedProjects: return "Related projects"
            case .github: return "GitHub"
            case .website: return "Website"
            case .resources: return "Linked resources"
            case .collections: return "Linked collections"
            case .media: return "Linked media"
            case .tasks: return "Linked tasks"
            case .features: return "Linked features"
            case .milestones: return "Linked milestones"
            case .workLogs: return "Linked work logs"
            }
        }
    }

    public enum ChangeState: String, Sendable, Hashable {
        /// Both sides contain the same normalized value, so importing changes nothing.
        case equal
        /// Notion has a value and local metadata is blank. Selected by default in UI.
        case fill
        /// Both sides have a different meaningful value. Never selected by default.
        case conflict
        /// The local value is retained; Notion has nothing useful for this field.
        case localOnly
    }

    public struct Change: Identifiable, Sendable, Hashable {
        public let field: Field
        public let local: String?
        public let notion: String?
        public let state: ChangeState
        public var id: String { field.rawValue }
    }

    /// Values held only in a fetched, in-memory preview until a person explicitly
    /// chooses fields to import. `relatedNotionPageIDs` is resolved to local project
    /// IDs by the app-model boundary, not by this pure mapper.
    public struct Values: Sendable, Hashable {
        public var metadata: ProjectMetadata
        public var description: ProjectDescription
        public var portfolioDetails: ProjectPortfolioDetails
        public var relatedNotionPageIDs: [String]

        public init(metadata: ProjectMetadata = .init(), description: ProjectDescription = .init(),
                    portfolioDetails: ProjectPortfolioDetails = .init(), relatedNotionPageIDs: [String] = []) {
            self.metadata = metadata
            self.description = description
            self.portfolioDetails = portfolioDetails
            self.relatedNotionPageIDs = relatedNotionPageIDs
        }
    }

    public struct Preview: Identifiable, Sendable, Hashable {
        public let projectID: String
        public let projectName: String
        public let notionPageID: String
        public let values: Values
        public let changes: [Change]
        public var id: String { projectID }
        public var selectableChanges: [Change] { changes.filter { $0.notion != nil && $0.state != .equal } }
        public var defaultFields: Set<Field> { Set(changes.filter { $0.state == .fill }.map(\.field)) }
    }

    /// Maps curated, display-safe page properties case-insensitively. Relation values
    /// remain references rather than copied pages, files, or media.
    public static func values(from page: NotionPage) -> Values {
        func key(_ aliases: [String]) -> String? {
            for alias in aliases {
                if page.properties[alias] != nil { return alias }
                if let match = page.properties.keys.first(where: { $0.caseInsensitiveCompare(alias) == .orderedSame }) {
                    return match
                }
            }
            return nil
        }
        /// Notion has evolved several of these columns between select, status, and
        /// multi-select.  Project grouping needs a display value rather than a schema
        /// assertion, so preserve every visible choice when a column is multi-select.
        func scalar(_ aliases: [String]) -> String? {
            guard let key = key(aliases) else { return nil }
            if let value = page.choice(key) ?? page.text(key) { return value }
            let values = page.choices(key)
            return values.isEmpty ? nil : values.joined(separator: ", ")
        }
        func choices(_ aliases: [String]) -> [String] {
            guard let key = key(aliases) else { return [] }
            let values = page.choices(key)
            if values.isEmpty == false { return values }
            if let value = page.choice(key) ?? page.text(key) { return [value] }
            return []
        }
        func date(_ aliases: [String]) -> Date? { key(aliases).flatMap { page.date($0) }.flatMap(parseDate) }
        func number(_ aliases: [String]) -> Double? { key(aliases).flatMap { page.number($0) } }
        func relations(_ aliases: [String]) -> [String] { key(aliases).map { page.relations($0) } ?? [] }

        var metadata = ProjectMetadata(
            domain: scalar(["Domain", "Domains", "Project Domain"]),
            status: scalar(["Status", "Project Status", "State"]),
            // `Stage` is a project lifecycle synonym only here.  Work-item stage
            // remains its own Now/Next/Later field in portable Markdown.
            phase: scalar(["Phase", "Project Phase", "Lifecycle Phase", "Project Stage", "Stage"]),
            completionModel: scalar(["Completion Model", "Completion"]),
            maintenanceCadence: scalar(["Maintenance Cadence", "Cadence"]),
            // The live database's Type is a multi-select.  The existing local field
            // is intentionally a single editable classification string, so preserve
            // multiple values visibly instead of silently discarding all but one.
            projectType: choices(["Type", "Project Type", "Types"]).joined(separator: ", ").nonEmpty,
            workModes: choices(["Work Mode", "Work Modes"]),
            currentWork: choices(["Current Work"]),
            nextWork: choices(["Next Work"]),
            recentWork: choices(["Recent Work"]),
            blockers: choices(["Blocked By"]),
            statusDetail: scalar(["Status Details", "Status Detail"]),
            startedAt: date(["Started At", "Start Date"]),
            lastUpdateAt: date(["Last Update At", "Last Update"]),
            trackingPriority: number(["tracking priority"])
        )
        // A page's native edit timestamp is a useful fallback only when there was no
        // curated `Last Update At` field. It remains a recorded import value, never a
        // live dependency.
        if metadata.lastUpdateAt == nil { metadata.lastUpdateAt = page.lastEditedTime }
        return Values(
            metadata: metadata,
            description: ProjectDescription(oneLiner: scalar(["One Liner", "One Line"]),
                                            summary: scalar(["Summary", "Description"])),
            portfolioDetails: ProjectPortfolioDetails(
                githubURL: scalar(["GitHub", "Github", "Repo Link", "Repository URL", "Repository", "Repo"]),
                websiteURL: scalar(["Website", "Project URL", "URL", "Live URL", "Download URL"]),
                resourceReferences: relations(["Resources", "Resource"]),
                collectionReferences: relations(["Collections", "Collection"]),
                mediaReferences: relations(["Media", "Assets", "Asset", "Images", "Image"]),
                taskReferences: relations(["Tasks", "Task"]),
                featureReferences: relations(["Features", "Feature"]),
                milestoneReferences: relations(["Milestones", "Milestone"]),
                workLogReferences: relations(["Work Log", "Work Logs"])
            ),
            relatedNotionPageIDs: relations(["Related Projects", "Related Project"])
        )
    }

    /// Fields actually supplied by a partial graph draft. Absence is different from
    /// an explicit empty value: editing a rating must not erase existing details.
    public static func suppliedFields(propertyNames: Set<String>, relationNames: Set<String> = []) -> Set<Field> {
        let aliases: [Field: [String]] = [
            .oneLiner: ["one liner", "one line"], .summary: ["summary", "description"],
            .domain: ["domain", "domains", "project domain"], .status: ["status", "project status", "state"],
            .phase: ["phase", "project phase", "lifecycle phase", "project stage", "stage"],
            .completionModel: ["completion model", "completion"], .maintenanceCadence: ["maintenance cadence", "cadence"],
            .projectType: ["type", "project type", "types"], .workModes: ["work mode", "work modes"],
            .currentWork: ["current work"], .nextWork: ["next work"], .recentWork: ["recent work"],
            .blockers: ["blocked by"], .statusDetail: ["status details", "status detail"],
            .startedAt: ["started at", "start date"], .lastUpdateAt: ["last update at", "last update"],
            .trackingPriority: ["tracking priority"], .relatedProjects: ["related projects", "related project"],
            .github: ["github", "repo link", "repository url", "repository", "repo"],
            .website: ["website", "project url", "url", "live url", "download url"],
            .resources: ["resources", "resource"], .collections: ["collections", "collection"],
            .media: ["media", "assets", "asset", "images", "image"], .tasks: ["tasks", "task"],
            .features: ["features", "feature"], .milestones: ["milestones", "milestone"], .workLogs: ["work log", "work logs"]]
        let keys = Set(propertyNames.map { $0.lowercased() })
        let relations = Set(relationNames.map { $0.lowercased() })
        return Set(aliases.compactMap { field, names -> Field? in
            guard names.contains(where: keys.contains) else { return nil }
            if [.github, .website].contains(field), names.contains(where: relations.contains) { return nil }
            return field
        })
    }

    public static func preview(projectID: String, projectName: String, notionPageID: String,
                               localMetadata: ProjectMetadata, localDescription: ProjectDescription,
                               localPortfolioDetails: ProjectPortfolioDetails = .init(),
                               localRelatedProjectNames: [String], page: NotionPage,
                               relatedNotionProjectNames: [String] = []) -> Preview {
        let proposed = values(from: page)
        let local = fieldValues(metadata: localMetadata, description: localDescription, portfolioDetails: localPortfolioDetails,
                                relatedNames: localRelatedProjectNames)
        let notion = fieldValues(metadata: proposed.metadata, description: proposed.description, portfolioDetails: proposed.portfolioDetails,
                                 relatedNames: relatedNotionProjectNames)
        let changes = Field.allCases.map { field -> Change in
            let left = local[field]
            let right = notion[field]
            let state: ChangeState
            switch (left, right) {
            case (nil, nil): state = .equal
            case (nil, _?): state = .fill
            case (_?, nil): state = .localOnly
            case let (a?, b?) where normalized(a) == normalized(b): state = .equal
            default: state = .conflict
            }
            return Change(field: field, local: left, notion: right, state: state)
        }
        return Preview(projectID: projectID, projectName: projectName, notionPageID: notionPageID,
                       values: proposed, changes: changes)
    }

    /// Applies only fields a person selected in the preview.  Callers own persistence
    /// and relationship-ID resolution, so this function cannot write or overwrite
    /// anything outside the explicitly selected local fields.
    public static func applying(_ fields: Set<Field>, values: Values,
                                to metadata: ProjectMetadata, description: ProjectDescription,
                                portfolioDetails: ProjectPortfolioDetails = .init()) -> (metadata: ProjectMetadata, description: ProjectDescription, portfolioDetails: ProjectPortfolioDetails) {
        var metadata = metadata
        var description = description
        var portfolioDetails = portfolioDetails
        for field in fields {
            switch field {
            case .oneLiner: description.oneLiner = values.description.oneLiner
            case .summary: description.summary = values.description.summary
            case .domain: metadata.domain = values.metadata.domain
            case .status: metadata.status = values.metadata.status
            case .phase: metadata.phase = values.metadata.phase
            case .completionModel: metadata.completionModel = values.metadata.completionModel
            case .maintenanceCadence: metadata.maintenanceCadence = values.metadata.maintenanceCadence
            case .projectType: metadata.projectType = values.metadata.projectType
            case .workModes: metadata.workModes = values.metadata.workModes
            case .currentWork: metadata.currentWork = values.metadata.currentWork
            case .nextWork: metadata.nextWork = values.metadata.nextWork
            case .recentWork: metadata.recentWork = values.metadata.recentWork
            case .blockers: metadata.blockers = values.metadata.blockers
            case .statusDetail: metadata.statusDetail = values.metadata.statusDetail
            case .startedAt: metadata.startedAt = values.metadata.startedAt
            case .lastUpdateAt: metadata.lastUpdateAt = values.metadata.lastUpdateAt
            case .trackingPriority: metadata.trackingPriority = values.metadata.trackingPriority
            case .relatedProjects: break // resolved by the app-model boundary
            case .github: portfolioDetails.githubURL = values.portfolioDetails.githubURL
            case .website: portfolioDetails.websiteURL = values.portfolioDetails.websiteURL
            case .resources: portfolioDetails.resourceReferences = values.portfolioDetails.resourceReferences
            case .collections: portfolioDetails.collectionReferences = values.portfolioDetails.collectionReferences
            case .media: portfolioDetails.mediaReferences = values.portfolioDetails.mediaReferences
            case .tasks: portfolioDetails.taskReferences = values.portfolioDetails.taskReferences
            case .features: portfolioDetails.featureReferences = values.portfolioDetails.featureReferences
            case .milestones: portfolioDetails.milestoneReferences = values.portfolioDetails.milestoneReferences
            case .workLogs: portfolioDetails.workLogReferences = values.portfolioDetails.workLogReferences
            }
        }
        return (metadata, description, portfolioDetails)
    }

    private static func fieldValues(metadata: ProjectMetadata, description: ProjectDescription,
                                    portfolioDetails: ProjectPortfolioDetails,
                                    relatedNames: [String]) -> [Field: String] {
        func list(_ values: [String]) -> String? {
            let cleaned = values.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            return cleaned.isEmpty ? nil : cleaned.sorted().joined(separator: ", ")
        }
        func date(_ value: Date?) -> String? {
            value.map { ISO8601DateFormatter().string(from: $0) }
        }
        return [
            .oneLiner: description.oneLiner, .summary: description.summary,
            .domain: metadata.domain, .status: metadata.status, .phase: metadata.phase,
            .completionModel: metadata.completionModel, .maintenanceCadence: metadata.maintenanceCadence,
            .projectType: metadata.projectType, .workModes: list(metadata.workModes),
            .currentWork: list(metadata.currentWork), .nextWork: list(metadata.nextWork),
            .recentWork: list(metadata.recentWork), .blockers: list(metadata.blockers),
            .statusDetail: metadata.statusDetail, .startedAt: date(metadata.startedAt),
            .lastUpdateAt: date(metadata.lastUpdateAt),
            .trackingPriority: metadata.trackingPriority.map { String($0) },
            .relatedProjects: list(relatedNames),
            .github: portfolioDetails.githubURL,
            .website: portfolioDetails.websiteURL,
            .resources: list(portfolioDetails.resourceReferences),
            .collections: list(portfolioDetails.collectionReferences),
            .media: list(portfolioDetails.mediaReferences),
            .tasks: list(portfolioDetails.taskReferences),
            .features: list(portfolioDetails.featureReferences),
            .milestones: list(portfolioDetails.milestoneReferences),
            .workLogs: list(portfolioDetails.workLogReferences),
        ].compactMapValues { $0?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty }
    }

    private static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func parseDate(_ raw: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: raw) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: raw) { return date }
        let day = DateFormatter()
        day.calendar = Calendar(identifier: .iso8601)
        day.timeZone = TimeZone(secondsFromGMT: 0)
        day.dateFormat = "yyyy-MM-dd"
        return day.date(from: raw)
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
