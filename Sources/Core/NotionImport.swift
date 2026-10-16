import Foundation
import CryptoKit

/// Bringing years of Notion history across, once.
///
/// This is a migration, not a synchronization. It reads Notion rows and writes local
/// files, and afterwards the local files are the home — nothing here keeps the two in
/// step, and nothing in the app requires the import to have happened.
///
/// Everything is planned before anything is written. A plan says exactly what would be
/// created and what is already there, because "import 977 tasks into my workspace" is
/// not a thing anyone should agree to sight unseen.
///
/// Idempotent by construction: a work item keeps the Notion page id as its own stable
/// id, and an idea is matched to an existing folder by name, so running the import
/// twice creates nothing the second time.
public enum NotionImport {

    // MARK: - What a plan contains

    public struct PlannedWorkItem: Sendable, Hashable {
        public let item: WorkItem
        public let directory: URL
        /// A work item already carrying this Notion id — re-running changes nothing.
        public let alreadyPresent: Bool
        /// The file this import may rewrite in place: an earlier import of the same page
        /// that nobody has edited since, whose Notion content has changed. Nil when the
        /// item is new, unchanged, or edited locally (then it is left alone).
        public var replacing: WorkItem? = nil
        /// Present, but edited here since it was imported, so this import leaves it be.
        public var keptLocalEdits = false
    }

    public struct PlannedIdea: Sendable, Hashable {
        public let title: String
        public let folder: URL
        public let body: String
        public let notionPageID: String
        /// A folder of this name is already in Ideas, so the import leaves it alone.
        public let alreadyPresent: Bool
        /// True when this came from a *project* whose status is Idea rather than from
        /// the Ideas database.
        public let fromProjectsDatabase: Bool
    }

    public struct PlannedSocialPost: Sendable, Hashable {
        public let post: SocialPost
        public let directory: URL
        /// The stable Notion page id is retained in the file. A second import never
        /// replaces local edits; it simply leaves that post alone.
        public let alreadyPresent: Bool
    }

    /// A conservative association proposed from the Notion Projects database.  It is
    /// kept in the preview and is not recorded until the person confirms Import.
    /// The local project remains a real directory; this only stores the optional
    /// Notion-page association in Better Workspace's private database.
    public struct PlannedProjectLink: Sendable, Hashable {
        public let notionPageID: String
        public let projectID: String

        public init(notionPageID: String, projectID: String) {
            self.notionPageID = notionPageID
            self.projectID = projectID
        }
    }

    public struct ProjectLinkResolution: Sendable, Hashable {
        public var links: [PlannedProjectLink] = []
        public var unmatchedCount = 0

        public init() {}
    }

    /// A planning row whose Notion Project relation could not be resolved safely.  It
    /// deliberately carries only Notion data and a reference to the related project;
    /// choosing a local directory is a separate, person-confirmed action.
    public struct UnresolvedPlanningItem: Identifiable, Sendable, Hashable {
        public let id: String
        public let kind: WorkItemKind
        public let title: String
        public let status: String?
        public let detail: String?

        public init(id: String, kind: WorkItemKind, title: String, status: String?, detail: String?) {
            self.id = id
            self.kind = kind
            self.title = title
            self.status = status
            self.detail = detail
        }
    }

    /// One unresolved Notion Project and every Feature or Milestone which names it.
    /// Grouping is important: mapping the project once restores all of its planning
    /// relationships on the next local re-plan.
    public struct UnresolvedProjectGroup: Identifiable, Sendable, Hashable {
        public let notionProjectID: String
        public let notionProjectName: String?
        public let items: [UnresolvedPlanningItem]

        public var id: String { notionProjectID }

        public init(notionProjectID: String, notionProjectName: String?, items: [UnresolvedPlanningItem]) {
            self.notionProjectID = notionProjectID
            self.notionProjectName = notionProjectName
            self.items = items
        }
    }

    public struct Plan: Sendable {
        public var tasks: [PlannedWorkItem] = []
        public var milestones: [PlannedWorkItem] = []
        public var features: [PlannedWorkItem] = []
        public var ideas: [PlannedIdea] = []
        public var socialPosts: [PlannedSocialPost] = []
        /// Exact directory/name matches to record alongside this import.  These make
        /// the linked Features and Milestones resolvable in the same confirmed run.
        public var projectLinks: [PlannedProjectLink] = []
        /// Things a person should see before agreeing: rows with no title, tasks whose
        /// project could not be matched to a local folder, truncated databases.
        public var warnings: [String] = []

        public var workItems: [PlannedWorkItem] { tasks + milestones + features }
        public var refreshCount: Int { workItems.filter { $0.replacing != nil }.count }
        public var keptLocalEditsCount: Int { workItems.filter(\.keptLocalEdits).count }
        public var newWorkItemCount: Int { workItems.filter { $0.alreadyPresent == false }.count }
        public var newIdeaCount: Int { ideas.filter { $0.alreadyPresent == false }.count }

        public var completedTaskCount: Int { tasks.filter { $0.item.status == .completed }.count }
        public var openTaskCount: Int { tasks.filter { $0.item.status != .completed }.count }

        public var newSocialPostCount: Int { socialPosts.filter { $0.alreadyPresent == false }.count }

        public var summary: String {
            "\(newWorkItemCount) work items, \(newIdeaCount) ideas and \(newSocialPostCount) social posts would be created"
        }
    }

    /// What to bring across. Tasks are separable because there are a great many of
    /// them and most are finished — importing a thousand closed tasks into a folder
    /// you have to live in is a choice, not a default.
    public struct Options: Sendable {
        public var includeTasks = true
        /// A small, relationship-preserving alternative to importing the entire task
        /// database: bring across only tasks directly attached to milestones that this
        /// same plan can safely import.
        public var includeTasksLinkedToIncludedMilestones = false
        public var includeCompletedTasks = false
        public var includeMilestones = true
        public var includeFeatures = true
        public var includeIdeas = true
        public var includeSocialPosts = true
        /// Projects whose Notion status is `Idea` become idea folders too.
        public var includeIdeaProjects = true
        /// Rewrite items imported before imports carried provenance, when their files
        /// have provably not changed since they were written (modification time equals
        /// creation time). A one-time upgrade, off by default.
        public var upgradeLegacyImports = false
        /// Import milestones and features whose Notion project has no local folder,
        /// unattached, as tasks already are. Their project is kept as `notion-project`
        /// provenance (and named in the body), and a later run attaches them once the
        /// project is linked. Off by default: linking first is the better outcome.
        public var includeUnlinkedPlanning = false

        public init() {}
    }

    /// Where each kind lands. These are the folders the workspace already has.
    public struct Destinations: Sendable {
        public let tasks: URL
        public let milestones: URL
        public let features: URL
        public let ideas: URL
        public let socialPosts: URL
        /// Work-item project references are portable workspace-relative paths. This
        /// root is present for the normal app import and optional for standalone tests
        /// or callers that deliberately do not have a WorkspaceLocation.
        public let workspaceRoot: URL?

        /// Each kind goes to the work queue configured for it, falling back to the
        /// folder the defaults name when no discovered folder is set up for that kind.
        public init(workspace: WorkspaceLocation, folders: [WorkspaceFolder] = []) {
            func queue(_ kind: WorkItemKind, _ fallback: String) -> URL {
                WorkQueueRouting.folder(for: kind, among: folders)?.url
                    ?? workspace.url(forArea: fallback)
            }
            tasks = queue(.task, "To Do")
            milestones = queue(.milestone, "Milestones")
            features = queue(.feature, "Features")
            ideas = workspace.url(for: .ideas)
            socialPosts = workspace.url(forArea: WorkspaceArea.socialPosts.directoryName)
            workspaceRoot = workspace.root
        }

        public init(tasks: URL, milestones: URL, features: URL, ideas: URL,
                    socialPosts: URL? = nil, workspaceRoot: URL? = nil) {
            self.tasks = tasks
            self.milestones = milestones
            self.features = features
            self.ideas = ideas
            self.socialPosts = socialPosts ?? ideas.deletingLastPathComponent().appendingPathComponent("Social Posts", isDirectory: true)
            self.workspaceRoot = workspaceRoot
        }
    }

    /// The Notion databases an import reads. All optional — a missing id is skipped,
    /// never an error, because someone may only want part of this.
    public struct Databases: Sendable {
        public var tasks: String?
        public var milestones: String?
        public var features: String?
        public var ideas: String?
        public var projects: String?
        public var socialPosts: String?

        public init(tasks: String? = nil, milestones: String? = nil, features: String? = nil,
                    ideas: String? = nil, projects: String? = nil, socialPosts: String? = nil) {
            self.tasks = tasks
            self.milestones = milestones
            self.features = features
            self.ideas = ideas
            self.projects = projects
            self.socialPosts = socialPosts
        }
    }

    /// Everything fetched from Notion, so planning stays a pure function of it.
    public struct Source: Sendable {
        public var tasks: [NotionPage] = []
        public var milestones: [NotionPage] = []
        public var features: [NotionPage] = []
        public var ideas: [NotionPage] = []
        public var projects: [NotionPage] = []
        public var socialPosts: [NotionPage] = []
        public var truncated: [String] = []

        public init() {}
    }

    /// Returns the small, relationship-closed planning slice for one Notion project.
    /// This is intentionally based on page IDs rather than titles: it is used by the
    /// command-line migration when someone wants to prove one local project before
    /// bringing across the rest of a large workspace.
    public static func scopedSource(_ source: Source, toProjectID projectID: String) -> Source {
        let wantedProjectID = normalizedID(projectID)
        func belongsToProject(_ page: NotionPage) -> Bool {
            Fields(page).relations(Alias.project).contains { normalizedID($0) == wantedProjectID }
        }

        var scoped = Source()
        scoped.projects = source.projects.filter { normalizedID($0.id) == wantedProjectID }
        scoped.milestones = source.milestones.filter(belongsToProject)
        scoped.features = source.features.filter(belongsToProject)

        let milestoneIDs = Set(scoped.milestones.map { normalizedID($0.id) })
        let featureIDs = Set(scoped.features.map { normalizedID($0.id) })
        let taskIDsNamedByPlanning = Set((scoped.milestones + scoped.features).flatMap {
            Fields($0).relations(Alias.task).map(normalizedID)
        })
        scoped.tasks = source.tasks.filter { task in
            belongsToProject(task)
                || taskIDsNamedByPlanning.contains(normalizedID(task.id))
                || Fields(task).relations(Alias.milestone).contains { milestoneIDs.contains(normalizedID($0)) }
                || Fields(task).relations(Alias.feature).contains { featureIDs.contains(normalizedID($0)) }
        }
        // Project-scoped imports are planning-only by definition: idea folders and
        // social posts do not participate in a project task graph.
        scoped.truncated = source.truncated
        return scoped
    }

    // MARK: - Planning

    /// Turns fetched rows into a plan. No network, no filesystem writes — only reads,
    /// to see what is already there.
    public static func plan(
        from source: Source,
        options: Options,
        destinations: Destinations,
        projectsByNotionID: [String: ProjectRecord],
        existingWorkItems: [WorkItem],
        existingIdeaNames: Set<String>,
        existingSocialPostIDs: Set<String> = [],
        projectLinks: [PlannedProjectLink] = []
    ) -> Plan {
        var plan = Plan()
        plan.projectLinks = projectLinks
        plan.warnings = source.truncated.map {
            "\($0) has more rows than one import could read; some would be missed."
        }
        let knownIDs = Set(existingWorkItems.map(\.id))
        let existingIdeas = Set(existingIdeaNames.map(normalized))

        // Notion exposes a relation on either side, depending on when and how a row
        // was created. Infer the inverse links from the complete import source so a
        // graph is connected even when the page currently being imported has an empty
        // reciprocal property.
        func inverseRelations(from pages: [NotionPage], relation: [String]) -> [String: [String]] {
            var result: [String: [String]] = [:]
            for page in pages {
                let pageID = normalizedID(page.id)
                for relatedID in Fields(page).relations(relation).map(normalizedID) {
                    guard result[relatedID, default: []].contains(pageID) == false else { continue }
                    result[relatedID, default: []].append(pageID)
                }
            }
            return result
        }

        func combinedIDs(_ primary: [String], _ inferred: [String]) -> [String] {
            var seen: Set<String> = []
            return (primary + inferred).compactMap { rawID in
                let id = normalizedID(rawID)
                return seen.insert(id).inserted ? id : nil
            }
        }

        let milestonesByTask = inverseRelations(from: source.milestones, relation: Alias.task)
        let featuresByTask = inverseRelations(from: source.features, relation: Alias.task)
        let featuresByMilestone = inverseRelations(from: source.features, relation: Alias.milestone)
        let tasksByMilestone = inverseRelations(from: source.tasks, relation: Alias.milestone)

        func projectPath(for page: NotionPage, relation: [String]) -> String? {
            guard let related = Fields(page).relations(relation).first,
                  let record = projectsByNotionID[normalizedID(related)] else { return nil }
            guard let root = destinations.workspaceRoot else { return record.lastPath }
            let rootPath = root.canonicalPath
            let path = record.url.canonicalPath
            guard path.hasPrefix(rootPath + "/") else { return nil }
            return MobileWorkspacePath.normalizedRelative(String(path.dropFirst(rootPath.count + 1)))
        }

        if options.includeTasks || options.includeTasksLinkedToIncludedMilestones {
            let importableMilestoneProjectPaths = Dictionary(
                source.milestones.compactMap { milestone -> (String, String)? in
                    guard let path = projectPath(for: milestone, relation: Alias.project) else { return nil }
                    return (normalizedID(milestone.id), path)
                },
                uniquingKeysWith: { first, _ in first }
            )
            var unmatched = 0
            for page in source.tasks {
                guard let title = page.title, title.isEmpty == false else { continue }
                let fields = Fields(page)
                let taskID = normalizedID(page.id)
                let milestones = combinedIDs(fields.relations(Alias.milestone), milestonesByTask[taskID] ?? [])
                let milestone = milestones.first
                if options.includeTasks == false {
                    guard let milestone, importableMilestoneProjectPaths[milestone] != nil else { continue }
                }
                let status = fields.status
                let duplicate = status?.lowercased() == "duplicate"
                let done = fields.flag(Alias.taskDone) || isFinished(status) || duplicate
                if done && options.includeCompletedTasks == false { continue }
                // The milestone relation is an authoritative fallback for legacy task
                // rows where Project was left blank, and keeps the task's project
                // navigation consistent with the milestone it accompanies.
                let path = projectPath(for: page, relation: Alias.project)
                    ?? milestone.flatMap { importableMilestoneProjectPaths[$0] }
                if path == nil { unmatched += 1 }
                // A task with no milestone but a feature still belongs somewhere. The
                // hierarchy is feature → milestone → task, so the feature is kept as a
                // relation rather than made the parent.
                let features = combinedIDs(fields.relations(Alias.feature), featuresByTask[taskID] ?? [])
                let item = WorkItem(
                    id: normalizedID(page.id),
                    kind: .task,
                    title: title,
                    status: done ? .completed : workStatus(status),
                    // Notion's own Work Stage is the person's decision; dates are only a
                    // fallback for rows that never had one.
                    stage: stage(forWorkStage: fields.choice(Alias.workStage))
                        ?? stage(forDueDate: fields.date(Alias.taskDoDate) ?? fields.date(Alias.taskDueDate)),
                    priority: priority(fields.choice(Alias.priority), number: fields.number(Alias.priority)),
                    projectPath: path,
                    // A subtask belongs to its task; otherwise a task belongs to its milestone.
                    parentID: fields.relations(Alias.parentTask).first.map(normalizedID) ?? milestone,
                    relatedIDs: features,
                    dueDate: parseDate(fields.date(Alias.taskDueDate) ?? fields.date(Alias.taskDoDate)),
                    completedAt: done ? parseDate(fields.date(Alias.dateCompleted)) : nil,
                    body: body(from: page, fields: [("Status", status),
                                                    ("Type", fields.choice(Alias.type)),
                                                    ("Work stage", fields.choice(Alias.workStage)),
                                                    ("Do date", fields.date(Alias.taskDoDate)),
                                                    ("Effort", fields.choice(Alias.effort)),
                                                    ("Impact", fields.choice(Alias.impact)),
                                                    ("Link", fields.text(Alias.url)),
                                                    ("Agent", fields.choice(["agent"])),
                                                    ("Agent status", fields.choice(["agent status"])),
                                                    ("Execution owner", fields.choice(["execution owner"])),
                                                    ("Execution result", fields.text(["execution result"])),
                                                    ("Details", fields.text(Alias.details))]),
                    extraFrontMatter: provenance(page, relations: [
                        // Kept even when no local folder matches, so the association can
                        // be audited, and is restored by a later run once one is linked.
                        ("notion-project", fields.relations(Alias.project)),
                        // Ideas are folders, not work items; their Notion page ids still
                        // resolve to local ideas through the background service's links.
                        ("notion-ideas", fields.relations(Alias.ideas)),
                        ("blocked-by", fields.relations(Alias.blockedBy)),
                        ("blocking", fields.relations(Alias.blocking)),
                    ]),
                    url: destinations.tasks.appendingPathComponent("placeholder")
                )
                plan.tasks.append(PlannedWorkItem(item: item, directory: destinations.tasks,
                                                  alreadyPresent: knownIDs.contains(item.id)))
            }
            if unmatched > 0 {
                plan.warnings.append("\(unmatched) tasks have no project this workspace recognizes; they import unattached.")
            }
        }

        let notionProjectTitles = Dictionary(
            source.projects.compactMap { page in page.title.map { (normalizedID(page.id), $0) } },
            uniquingKeysWith: { first, _ in first }
        )
        /// The Notion projects an unattached item belonged to, by name, for its body.
        func notionProjectNames(_ ids: [String]) -> String? {
            let names = ids.map { notionProjectTitles[normalizedID($0)] ?? $0 }
            return names.isEmpty ? nil : names.joined(separator: ", ")
        }

        if options.includeMilestones {
            var unmatched = 0
            var unattached = 0
            for page in source.milestones {
                guard let title = page.title, title.isEmpty == false else { continue }
                let fields = Fields(page)
                // A finished milestone imported as open would come back as current work.
                // The real database computes status with a formula, read as text.
                let status = fields.status
                let projectPath = projectPath(for: page, relation: Alias.project)
                let notionProjects = projectPath == nil ? fields.relations(Alias.project) : []
                if projectPath == nil {
                    guard options.includeUnlinkedPlanning else { unmatched += 1; continue }
                    unattached += 1
                }
                let item = WorkItem(
                    id: normalizedID(page.id),
                    kind: .milestone,
                    title: title,
                    status: isFinished(status) ? .completed : workStatus(status),
                    priority: priority(fields.choice(Alias.priority), number: fields.number(Alias.priority)),
                    projectPath: projectPath,
                    parentID: combinedIDs(fields.relations(Alias.feature),
                                          featuresByMilestone[normalizedID(page.id)] ?? []).first,
                    // Keep the database's explicit Tasks relation as well as the
                    // task rows' parent pointer: older Notion rows are occasionally
                    // one-sided, and the detail UI can still navigate either shape.
                    relatedIDs: combinedIDs(fields.relations(Alias.task),
                                            tasksByMilestone[normalizedID(page.id)] ?? []),
                    dueDate: parseDate(fields.date(Alias.milestoneDate)),
                    body: body(from: page, fields: [("Status", status),
                                                    ("Notion project", notionProjectNames(notionProjects)),
                                                    ("Do date", fields.date(Alias.doDateManual)),
                                                    ("Description", fields.text(Alias.summary))]),
                    extraFrontMatter: provenance(page, relations: [
                        ("notion-project", notionProjects),
                        ("depends-on", fields.relations(Alias.dependsOn)),
                        ("blocking", fields.relations(Alias.blocking)),
                    ]),
                    url: destinations.milestones.appendingPathComponent("placeholder")
                )
                plan.milestones.append(PlannedWorkItem(item: item, directory: destinations.milestones,
                                                       alreadyPresent: knownIDs.contains(item.id)))
            }
            if unmatched > 0 {
                plan.warnings.append("\(unmatched) milestones were skipped because their Notion project is not linked to a local project.")
            }
            if unattached > 0 {
                plan.warnings.append("\(unattached) milestones have no project this workspace recognizes; they import unattached.")
            }
        }

        if options.includeFeatures {
            var unmatched = 0
            var unattached = 0
            for page in source.features {
                guard let title = page.title, title.isEmpty == false else { continue }
                let fields = Fields(page)
                let status = fields.status
                let projectPath = projectPath(for: page, relation: Alias.project)
                let notionProjects = projectPath == nil ? fields.relations(Alias.project) : []
                if projectPath == nil {
                    guard options.includeUnlinkedPlanning else { unmatched += 1; continue }
                    unattached += 1
                }
                let item = WorkItem(
                    id: normalizedID(page.id),
                    kind: .feature,
                    title: title,
                    status: isFinished(status) ? .completed : workStatus(status),
                    priority: priority(fields.choice(Alias.priority), number: fields.number(Alias.priority)),
                    projectPath: projectPath,
                    parentID: fields.relations(Alias.parentFeature).first.map(normalizedID),
                    relatedIDs: fields.relations(Alias.milestone).map(normalizedID),
                    body: body(from: page, fields: [
                        ("Status", status),
                        ("Notion project", notionProjectNames(notionProjects)),
                        ("Phase", fields.choice(Alias.phase) ?? fields.text(Alias.phase)),
                        ("Summary", fields.text(Alias.summary)),
                        ("Outcome", fields.text(Alias.outcome)),
                        ("Success Criteria", fields.text(Alias.successCriteria)),
                        ("Current Focus", fields.text(Alias.currentFocus)),
                        ("Next Step", fields.text(Alias.nextStep)),
                    ]),
                    extraFrontMatter: provenance(page, relations: [
                        ("notion-project", notionProjects),
                        ("depends-on", fields.relations(Alias.dependsOn)),
                    ]),
                    url: destinations.features.appendingPathComponent("placeholder")
                )
                plan.features.append(PlannedWorkItem(item: item, directory: destinations.features,
                                                     alreadyPresent: knownIDs.contains(item.id)))
            }
            if unmatched > 0 {
                plan.warnings.append("\(unmatched) features were skipped because their Notion project is not linked to a local project.")
            }
            if unattached > 0 {
                plan.warnings.append("\(unattached) features have no project this workspace recognizes; they import unattached.")
            }
        }

        let existingByID = Dictionary(existingWorkItems.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        func finalize(_ planned: [PlannedWorkItem]) -> [PlannedWorkItem] {
            planned.map { entry in
                var entry = entry
                var item = entry.item
                item.extraFrontMatter.append("\(importHashKey): \(contentHash(item))")
                entry = PlannedWorkItem(item: item, directory: entry.directory, alreadyPresent: entry.alreadyPresent)
                guard entry.alreadyPresent, let existing = existingByID[item.id] else { return entry }
                let recorded = recordedHash(existing)
                let unedited: Bool
                if let recorded {
                    unedited = recorded == contentHash(existing)
                } else {
                    unedited = options.upgradeLegacyImports && isLegacyImport(existing) && isPristine(existing)
                }
                guard unedited else {
                    // Only a file this import wrote is ever a candidate; anything else
                    // with a matching id is someone's own record.
                    entry.keptLocalEdits = recorded != nil || isLegacyImport(existing)
                    return entry
                }
                if recorded != contentHash(item) { entry.replacing = existing }
                return entry
            }
        }
        plan.tasks = finalize(plan.tasks)
        plan.milestones = finalize(plan.milestones)
        plan.features = finalize(plan.features)

        if options.includeIdeas {
            for page in source.ideas {
                guard let title = page.title, title.isEmpty == false else { continue }
                plan.ideas.append(plannedIdea(title: title, page: page, destinations: destinations,
                                              existing: existingIdeas, fromProjects: false,
                                              fields: [
                                                ("One liner", page.text("one liner")),
                                                ("Status", page.choice("status")),
                                                ("Type", page.choice("type")),
                                                ("Impact", page.choice("impact")),
                                                ("Effort", page.choice("effort")),
                                                ("Notes", page.text("capture notes")),
                                                ("Tags", page.choices("tags").joined(separator: ", ")),
                                              ]))
            }
        }

        if options.includeIdeaProjects {
            for page in source.projects where page.choice("Status") == "Idea" {
                guard let title = page.title, title.isEmpty == false else { continue }
                plan.ideas.append(plannedIdea(title: title, page: page, destinations: destinations,
                                              existing: existingIdeas, fromProjects: true,
                                              fields: [
                                                ("One liner", page.text("one liner")),
                                                ("Summary", page.text("summary")),
                                                ("Domain", page.choice("domain")),
                                                ("Tags", page.choices("tags").joined(separator: ", ")),
                                              ]))
            }
        }

        if options.includeSocialPosts {
            for page in source.socialPosts {
                guard let title = page.title, title.isEmpty == false else { continue }
                let id = normalizedID(page.id)
                plan.socialPosts.append(PlannedSocialPost(
                    post: socialPost(from: page, title: title, id: id,
                                     destination: destinations.socialPosts),
                    directory: destinations.socialPosts,
                    alreadyPresent: existingSocialPostIDs.contains(id)
                ))
            }
        }

        return plan
    }

    /// Matches Notion projects to the directories Better Workspace has already
    /// discovered.  This deliberately has no fuzzy matching: a Local Directory must
    /// be exact, or the Notion title must name exactly one current local project.
    /// Existing associations are never replaced here.
    public static func resolveProjectLinks(
        notionProjects: [NotionPage],
        localProjects: [ProjectRecord],
        workspaceRoot: URL?
    ) -> ProjectLinkResolution {
        var resolution = ProjectLinkResolution()
        let existingByNotionID = Dictionary(
            localProjects.compactMap { record in
                record.notionPageID.map { (normalizedID($0), record.id) }
            },
            uniquingKeysWith: { first, _ in first }
        )
        var assignedLocalIDs = Set(existingByNotionID.values)

        for page in notionProjects {
            let pageID = normalizedID(page.id)
            if existingByNotionID[pageID] != nil { continue }

            // A record associated with another Notion page is deliberately not a
            // candidate. Replacing it based on a name would risk changing history.
            let available = localProjects.filter { $0.notionPageID == nil && assignedLocalIDs.contains($0.id) == false }
            var matches: [ProjectRecord] = []

            if let directory = text(page, named: "Local Directory"), directory.isEmpty == false {
                matches = available.filter { record in
                    directoryMatches(directory, record: record, workspaceRoot: workspaceRoot)
                }
                // A workspace root can move between Macs while a project directory
                // retains its name. A unique exact final component is still a
                // deterministic directory match; do not use it when two local
                // projects share that name.
                if matches.isEmpty {
                    let leaf = (directory as NSString).lastPathComponent
                    if leaf.isEmpty == false {
                        matches = available.filter { normalized($0.name) == normalized(leaf) }
                    }
                }
            }
            if matches.isEmpty, let title = page.title {
                let titleKey = normalized(title)
                matches = available.filter { normalized($0.name) == titleKey }
            }

            guard matches.count == 1, let match = matches.first else {
                resolution.unmatchedCount += 1
                continue
            }
            resolution.links.append(.init(notionPageID: pageID, projectID: match.id))
            assignedLocalIDs.insert(match.id)
        }
        return resolution
    }

    /// Produces the conservative mapping-review list after existing and exact automatic
    /// links have been accounted for.  This never proposes a match: it simply makes
    /// skipped Planning rows explainable and actionable by a person.
    public static func unresolvedPlanningGroups(
        from source: Source,
        linkedNotionProjectIDs: Set<String>,
        options: Options
    ) -> [UnresolvedProjectGroup] {
        let names = Dictionary(
            source.projects.compactMap { page in page.title.map { (normalizedID(page.id), $0) } },
            uniquingKeysWith: { first, _ in first }
        )
        var grouped: [String: [UnresolvedPlanningItem]] = [:]

        func add(_ page: NotionPage, kind: WorkItemKind) {
            guard let title = page.title, title.isEmpty == false else { return }
            let fields = Fields(page)
            let detail = fields.text(Alias.summary) ?? fields.text(Alias.details)
            let item = UnresolvedPlanningItem(id: normalizedID(page.id), kind: kind, title: title,
                                              status: fields.status, detail: detail)
            for projectID in fields.relations(Alias.project).map(normalizedID)
                where linkedNotionProjectIDs.contains(projectID) == false {
                grouped[projectID, default: []].append(item)
            }
        }

        if options.includeMilestones {
            source.milestones.forEach { add($0, kind: .milestone) }
        }
        if options.includeFeatures {
            source.features.forEach { add($0, kind: .feature) }
        }
        return grouped.map { projectID, items in
            UnresolvedProjectGroup(notionProjectID: projectID, notionProjectName: names[projectID], items: items)
        }
        .sorted { ($0.notionProjectName ?? $0.notionProjectID).localizedCaseInsensitiveCompare(
            $1.notionProjectName ?? $1.notionProjectID) == .orderedAscending }
    }

    // MARK: - Applying

    public struct Result: Sendable {
        public var workItemsCreated = 0
        /// Earlier imports rewritten because Notion changed and nobody had edited them.
        public var workItemsRefreshed = 0
        public var ideasCreated = 0
        public var socialPostsCreated = 0
        public var skippedExisting = 0
        public var failures: [String] = []
    }

    /// Writes the plan. Never overwrites: anything already present is skipped, so an
    /// interrupted import can simply be run again.
    @discardableResult
    public static func apply(_ plan: Plan, using service: WorkItemService = WorkItemService()) -> Result {
        var result = Result()
        let fm = FileManager.default

        for planned in plan.workItems {
            if let existing = planned.replacing {
                let item = planned.item
                let refreshed = WorkItem(id: item.id, kind: item.kind, title: item.title, status: item.status,
                                         stage: item.stage, priority: item.priority, projectPath: item.projectPath,
                                         parentID: item.parentID, relatedIDs: item.relatedIDs, dueDate: item.dueDate,
                                         completedAt: item.completedAt, body: item.body,
                                         extraFrontMatter: item.extraFrontMatter, url: existing.url,
                                         createdAt: existing.createdAt, modifiedAt: existing.modifiedAt)
                do {
                    // Refuses if the file changed after it was read for the plan.
                    _ = try service.update(refreshed)
                    result.workItemsRefreshed += 1
                } catch {
                    result.failures.append("\(item.title): \(error.localizedDescription)")
                }
                continue
            }
            guard planned.alreadyPresent == false else { result.skippedExisting += 1; continue }
            do {
                _ = try service.create(planned.item, in: planned.directory)
                result.workItemsCreated += 1
            } catch {
                result.failures.append("\(planned.item.title): \(error.localizedDescription)")
            }
        }

        for idea in plan.ideas {
            guard idea.alreadyPresent == false else { result.skippedExisting += 1; continue }
            do {
                try fm.createDirectory(at: idea.folder, withIntermediateDirectories: true)
                // The folder name is the idea; the note is only what Notion knew about it.
                let note = idea.folder.appendingPathComponent("\(CaptureNaming.safeFilename(idea.title)).md")
                if fm.fileExists(atPath: note.path) == false {
                    try idea.body.write(to: note, atomically: true, encoding: .utf8)
                }
                result.ideasCreated += 1
            } catch {
                result.failures.append("\(idea.title): \(error.localizedDescription)")
            }
        }
        for planned in plan.socialPosts {
            guard planned.alreadyPresent == false else { result.skippedExisting += 1; continue }
            do {
                _ = try SocialPostService().create(planned.post, in: planned.directory)
                result.socialPostsCreated += 1
            } catch {
                result.failures.append("\(planned.post.title): \(error.localizedDescription)")
            }
        }
        return result
    }

    // MARK: - Private

    private static func plannedIdea(
        title: String, page: NotionPage, destinations: Destinations,
        existing: Set<String>, fromProjects: Bool, fields: [(String, String?)]
    ) -> PlannedIdea {
        let folderName = CaptureNaming.safeFilename(title)
        return PlannedIdea(
            title: title,
            folder: destinations.ideas.appendingPathComponent(folderName, isDirectory: true),
            body: markdown(title: title, fields: fields, sourceURL: page.url),
            notionPageID: normalizedID(page.id),
            // Folders named before this import existed often keep the title as written
            // ("Zine: Notes on Attention"), where a new one would drop the colon.
            alreadyPresent: existing.contains(normalized(folderName)) || existing.contains(normalized(title)),
            fromProjectsDatabase: fromProjects
        )
    }

    /// Notion property labels are person-facing and therefore not consistently cased.
    private static func text(_ page: NotionPage, named name: String) -> String? {
        if let value = page.text(name) { return value }
        guard let key = page.properties.keys.first(where: { $0.caseInsensitiveCompare(name) == .orderedSame })
        else { return nil }
        return page.text(key)
    }

    private static func directoryMatches(_ raw: String, record: ProjectRecord, workspaceRoot: URL?) -> Bool {
        let candidate = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard candidate.isEmpty == false else { return false }
        let recordPath = record.url.canonicalPath

        // Absolute locations may include a home-directory shorthand. They still need
        // to resolve to the same current directory, not merely have a similar suffix.
        if candidate.hasPrefix("/") || candidate.hasPrefix("~") {
            return URL(fileURLWithPath: (candidate as NSString).expandingTildeInPath).canonicalPath == recordPath
        }
        guard let workspaceRoot else { return false }
        let rootPath = workspaceRoot.canonicalPath
        guard recordPath.hasPrefix(rootPath + "/") else { return false }
        let relative = String(recordPath.dropFirst(rootPath.count + 1))
        return MobileWorkspacePath.normalizedRelative(candidate) == MobileWorkspacePath.normalizedRelative(relative)
    }

    /// The Notion database is deliberately richer than this portable file format.
    /// Preserve the audience-facing payloads and posting evidence; leave transient
    /// generation checkboxes and implementation-only workflow history behind.
    private static func socialPost(from page: NotionPage, title: String, id: String,
                                   destination: URL) -> SocialPost {
        let posted = page.flag("posted")
        let scheduled = page.flag("scheduled")
        let ready = page.flag("ready")
        let error = page.text("posting error")
        let workflow = page.choice("Workflow Status")?.lowercased() ?? ""
        let status: SocialPostStatus
        if posted { status = .posted }
        else if scheduled { status = .scheduled }
        else if error?.isEmpty == false || workflow.contains("error") { status = .error }
        else if ready { status = .ready }
        else if workflow.contains("review") || workflow.contains("approval") { status = .review }
        else { status = .draft }

        // A date on one of the legacy rows is an old planning hint, not a promise to
        // publish. Only the workflow's explicit Scheduled checkbox earns a calendar slot.
        let scheduledAt = scheduled ? parseDate(page.date("post date")) : nil
        return SocialPost(
            id: id, title: title, status: status, platforms: page.choices("platform"),
            scheduledAt: scheduledAt,
            linkedInURL: page.text("LinkedIn URL").flatMap(URL.init(string:)),
            blueskyURL: page.text("Bluesky URL").flatMap(URL.init(string:)),
            linkedInContent: page.text("content") ?? "",
            blueskyContent: page.text("content short") ?? "",
            originalContent: page.text("content original") ?? "",
            sourceURL: page.url, postingError: error,
            url: destination.appendingPathComponent(CaptureNaming.safeFilename(title) + SocialPostService.fileSuffix)
        )
    }

    private static func body(from page: NotionPage, fields: [(String, String?)]) -> String {
        var lines: [String] = []
        for (label, value) in fields {
            guard let value, value.isEmpty == false else { continue }
            lines.append("**\(label):** \(value)")
        }
        if let url = page.url { lines.append("\n[Originally in Notion](\(url.absoluteString))") }
        return lines.joined(separator: "\n\n")
    }

    private static func markdown(title: String, fields: [(String, String?)], sourceURL: URL?) -> String {
        var lines = ["# \(title)", ""]
        for (label, value) in fields where (value?.isEmpty == false) {
            lines.append("**\(label):** \(value!)")
            lines.append("")
        }
        if let sourceURL { lines.append("[Originally in Notion](\(sourceURL.absoluteString))") }
        return lines.joined(separator: "\n")
    }

    // MARK: - Provenance and refresh

    public static let importHashKey = "notion-import-hash"

    /// A fingerprint of everything an import writes, so a later run can tell a file it
    /// wrote and nobody touched from one a person has edited.
    public static func contentHash(_ item: WorkItem) -> String {
        let iso = ISO8601DateFormatter()
        let extras = item.extraFrontMatter.filter { $0.hasPrefix(importHashKey + ":") == false }
        let parts = [item.kind.rawValue, item.title, item.status.rawValue, item.stage.rawValue,
                     item.priority.rawValue, item.projectPath ?? "", item.parentID ?? "",
                     item.relatedIDs.joined(separator: ","), item.dueDate.map(iso.string) ?? "",
                     item.completedAt.map(iso.string) ?? "",
                     item.body.trimmingCharacters(in: .whitespacesAndNewlines)] + extras
        let digest = SHA256.hash(data: Data(parts.joined(separator: "\u{1F}").utf8))
        return digest.prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    static func recordedHash(_ item: WorkItem) -> String? {
        let prefix = importHashKey + ":"
        return item.extraFrontMatter.first { $0.hasPrefix(prefix) }
            .map { String($0.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces) }
    }

    /// Written by an import from before imports recorded provenance.
    static func isLegacyImport(_ item: WorkItem) -> Bool {
        item.extraFrontMatter.contains { $0.hasPrefix("source:") } == false
            && item.body.contains("[Originally in Notion](")
    }

    /// Never modified since it was written: modification and creation times agree.
    static func isPristine(_ item: WorkItem) -> Bool {
        guard let created = item.createdAt, let modified = item.modifiedAt else { return false }
        return abs(modified.timeIntervalSince(created)) < 1
    }

    /// Notion hands the same id back with and without dashes depending on the surface.
    public static func normalizedID(_ id: String) -> String {
        id.replacingOccurrences(of: "-", with: "").lowercased()
    }

    /// The names each field goes by across the planning databases, matched ignoring
    /// case. The databases were not named alike ("Project" on features, "project" on
    /// tasks, "Due Date (Manual)" on milestones), and a name this misses is a field
    /// silently dropped from every imported item. These follow the alias tables Better
    /// Projects validated against the live schema (`PlanningSchema.swift` there).
    public enum Alias {
        public static let status = ["status"]
        public static let priority = ["priority"]
        public static let project = ["project", "projects"]
        public static let milestone = ["milestone", "milestones"]
        public static let feature = ["feature", "features"]
        public static let task = ["task", "tasks"]
        public static let parentTask = ["parent task", "parent item", "parent"]
        public static let parentFeature = ["parent feature"]
        public static let taskDone = ["complete", "completed", "done"]
        public static let taskDoDate = ["do date"]
        public static let taskDueDate = ["due date", "date", "target date"]
        public static let milestoneDate = ["due date (manual)", "target date", "due date", "date", "target"]
        public static let type = ["type"]
        public static let details = ["details", "description", "notes", "body"]
        public static let summary = ["summary", "description", "overview"]
        public static let outcome = ["outcome", "purpose", "why", "goal", "rationale"]
        public static let successCriteria = ["success criteria", "success", "acceptance criteria", "done when", "definition of done"]
        public static let currentFocus = ["current focus", "focus"]
        public static let nextStep = ["next step", "next"]
        public static let phase = ["phase"]
        public static let workStage = ["work stage", "stage"]
        public static let dateCompleted = ["date completed", "completed on", "completed at"]
        public static let blockedBy = ["blocked by"]
        public static let blocking = ["blocking", "blocks"]
        public static let dependsOn = ["depends on", "dependencies"]
        public static let effort = ["effort"]
        public static let impact = ["impact"]
        public static let url = ["url", "link"]
        public static let doDateManual = ["do date (manual)"]
        public static let ideas = ["ideas", "idea"]
    }

    /// A row read through `Alias` lists: the first name the row actually has wins.
    public struct Fields {
        public let page: NotionPage

        public init(_ page: NotionPage) { self.page = page }

        public func key(_ names: [String]) -> String? {
            for name in names {
                if page.properties[name] != nil { return name }
                if let match = page.properties.keys.first(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
                    return match
                }
            }
            return nil
        }

        /// Each accessor tries every name that is present, so a row carrying an empty
        /// "description" and a filled "notes" still yields the notes.
        private func first<T>(_ names: [String], _ read: (String) -> T?) -> T? {
            for name in names {
                if let key = key([name]), let value = read(key) { return value }
            }
            return nil
        }

        public func text(_ names: [String]) -> String? { first(names) { page.text($0) } }
        public func choice(_ names: [String]) -> String? { first(names) { page.choice($0) } }
        /// A status as a select, a Notion status, or a formula's text.
        public var status: String? { choice(Alias.status) ?? text(Alias.status) }
        public func number(_ names: [String]) -> Double? { first(names) { page.number($0) } }
        public func date(_ names: [String]) -> String? { first(names) { page.date($0) } }
        public func flag(_ names: [String]) -> Bool { first(names) { page.flag($0) ? true : nil } ?? false }
        public func relations(_ names: [String]) -> [String] {
            first(names) { key in page.relations(key).isEmpty ? nil : page.relations(key) } ?? []
        }
    }

    private static func isFinished(_ status: String?) -> Bool {
        guard let status = status?.lowercased() else { return false }
        return status.contains("complete") || status == "done" || status == "finished"
    }

    /// Work that Notion says is underway stays underway rather than being reset to open.
    private static func workStatus(_ status: String?) -> WorkItemStatus {
        guard let status = status?.lowercased() else { return .open }
        if status.contains("progress") || status.contains("review") || status == "active" || status == "doing"
            || status == "validating" { return .inProgress }
        return .open
    }

    private static func normalized(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Tasks and milestones use a select ("High"), features a 1–5 number.
    private static func priority(_ name: String?, number: Double? = nil) -> WorkItemPriority {
        switch name?.lowercased() {
        case let value? where value.contains("high") || value.contains("urgent"): return .high
        case let value? where value.contains("low"): return .low
        case .some: return .medium
        case nil:
            guard let number else { return .medium }
            if number >= 4 { return .high }
            if number <= 2 { return .low }
            return .medium
        }
    }

    /// Notion's Work Stage, when a row has one. "Recent" is work just finished or just
    /// touched, which belongs with what is next rather than in the backlog.
    private static func stage(forWorkStage raw: String?) -> WorkItemStage? {
        switch raw?.lowercased() {
        case "current"?, "now"?: return .now
        case "next"?, "recent"?: return .next
        case "backlog"?, "later"?: return .later
        default: return nil
        }
    }

    /// Where an imported record came from, kept in its front matter so a migration can
    /// be audited and re-run: the page, its timestamps, and relations Better Workspace
    /// has no first-class field for. Ids are in the same form as work-item ids.
    static func provenance(_ page: NotionPage, relations: [(String, [String])] = []) -> [String] {
        let iso = ISO8601DateFormatter()
        var lines = ["source: notion", "notion-id: \(page.id)"]
        if let url = page.url { lines.append("notion-url: \(url.absoluteString)") }
        if let created = page.createdTime { lines.append("notion-created: \(iso.string(from: created))") }
        if let edited = page.lastEditedTime { lines.append("notion-edited: \(iso.string(from: edited))") }
        for (key, ids) in relations where ids.isEmpty == false {
            lines.append("\(key): [\(ids.map(normalizedID).joined(separator: ", "))]")
        }
        return lines
    }

    /// A date that has already passed, or is within the week, is work for now.
    private static func stage(forDueDate raw: String?, now: Date = Date()) -> WorkItemStage {
        guard let date = parseDate(raw) else { return .later }
        let days = date.timeIntervalSince(now) / 86_400
        if days <= 0 { return .now }
        if days <= 7 { return .next }
        return .later
    }

    static func parseDate(_ raw: String?) -> Date? {
        guard let raw, raw.isEmpty == false else { return nil }
        let full = ISO8601DateFormatter()
        full.formatOptions = [.withInternetDateTime]
        if let date = full.date(from: raw) { return date }
        // Notion sends times with milliseconds ("2026-10-01T09:00:00.000-07:00"). Files
        // keep whole seconds, so the value is truncated to match what reads back.
        full.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = full.date(from: raw) { return Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded(.down)) }
        let dayOnly = DateFormatter()
        dayOnly.calendar = Calendar(identifier: .iso8601)
        dayOnly.timeZone = TimeZone(secondsFromGMT: 0)
        dayOnly.dateFormat = "yyyy-MM-dd"
        return dayOnly.date(from: raw)
    }
}
