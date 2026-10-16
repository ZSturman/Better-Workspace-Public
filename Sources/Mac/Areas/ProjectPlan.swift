import SwiftUI
import BetterWorkspaceCore

/// A project's planning records from both stores — work files and the Notion graph —
/// with each thing listed once.
///
/// A task made here is a `.bw.md` file *and* its pending Notion draft; a task imported
/// from Notion is a graph record *and*, after a reviewed Get, a file. Listing both is
/// what showed one task in four places. The file wins wherever it exists.
struct ProjectPlanEntry: Identifiable {
    enum Origin { case work(WorkItem), graph(ProjectGraphRecord) }
    let origin: Origin
    let id: String
    let title: String
    let kind: WorkItemKind
    let isDone: Bool
    /// "Now · High priority", or empty.
    let detail: String
    let completedAt: Date?
    let stageRank: Int
    let priorityRank: Int
    /// Every id this entry answers to: its own, its Notion page, its graph record.
    let keys: Set<String>
    /// Features, milestones and parents it names.
    let parentKeys: Set<String>
    /// Tasks and features it names as its own (Notion relations run both ways).
    let childKeys: Set<String>
    /// Ids of what it waits on; whether those are finished is the plan's to say.
    var dependencyKeys: Set<String> = []
    /// How many of those are still open.
    var waitingOn = 0
    var displayDetail: String { waitingOn > 0 ? "Waiting on \(waitingOn) task\(waitingOn == 1 ? "" : "s")" : detail }

    var workItem: WorkItem? { if case let .work(item) = origin { item } else { nil } }
    var graphRecord: ProjectGraphRecord? { if case let .graph(record) = origin { record } else { nil } }
}

struct ProjectPlan {
    var next: ProjectPlanEntry?
    /// Open tasks, the next one excluded, most immediate first.
    var tasks: [ProjectPlanEntry] = []
    /// Open features and milestones.
    var groups: [ProjectPlanEntry] = []
    /// Everything finished, most recent first.
    var done: [ProjectPlanEntry] = []
    var all: [ProjectPlanEntry] = []

    /// Open tasks; features and milestones are what tasks add up to, not more to do.
    var openCount: Int { all.filter { !$0.isDone && $0.kind != .feature && $0.kind != .milestone }.count }
    var doneCount: Int { done.filter { $0.kind != .feature && $0.kind != .milestone }.count }
    var isEmpty: Bool { all.isEmpty }

    func members(of group: ProjectPlanEntry) -> [ProjectPlanEntry] {
        all.filter { entry in
            entry.id != group.id && (entry.kind == .task || entry.kind == .goal)
                && (!entry.parentKeys.isDisjoint(with: group.keys) || !group.childKeys.isDisjoint(with: entry.keys))
        }
    }
}

extension AppModel {
    func projectPlan(local: WorkspaceItem?, graph: ProjectGraphRecord?) -> ProjectPlan {
        let workByPath = workItemsByPath
        let work = local.map { projectWorkItems(for: $0) } ?? []
        let materialized = Set(workItems.compactMap { $0.importedNotionPageID.map(ProjectGraph.normalizedID) })
        let graphOnly = (graph.map { graphRelated(to: $0) } ?? []).filter { record in
            [.tasks, .features, .milestones].contains(record.kind)
                && ProjectGraphPlanning.boundWork(record, in: workByPath) == nil
                && (!isAwaitingWorkItems || record.localPath == nil)
                && !(record.pageID.map { materialized.contains(ProjectGraph.normalizedID($0)) } ?? false)
                && record.locallyDeleted != true && !record.remoteArchived && !record.archiveRequested
        }
        var entries = work.filter { $0.kind != .goal || $0.isOpen }.map(planEntry)
        entries += graphOnly.compactMap { planEntry($0, workByPath: workByPath) }

        // Waiting on unfinished work reads as such, and sorts after what can start now.
        // Only dependencies known to be open count; one finished elsewhere is not waited on.
        let open = Set(entries.filter { !$0.isDone }.flatMap(\.keys))
            .union(workItems.filter(\.isOpen).flatMap { [$0.id, $0.importedNotionPageID].compactMap { $0 }.map(ProjectGraph.normalizedID) })
        entries = entries.map { entry in
            let waiting = entry.dependencyKeys.intersection(open).count
            guard !entry.isDone, waiting > 0 else { return entry }
            var copy = entry
            copy.waitingOn = waiting
            return copy
        }
        var plan = ProjectPlan(all: entries)
        let nextID = local.flatMap { projectNextAction(for: $0)?.id }
            ?? graph.flatMap { projectGraphNextAction(for: $0)?.id }
        plan.next = entries.first { $0.id == nextID && !$0.isDone }
        plan.tasks = entries.filter { !$0.isDone && ($0.kind == .task || $0.kind == .goal) && $0.id != plan.next?.id }
            .sorted { ($0.waitingOn > 0 ? 1 : 0, $0.stageRank, $0.priorityRank, $0.title.lowercased()) < ($1.waitingOn > 0 ? 1 : 0, $1.stageRank, $1.priorityRank, $1.title.lowercased()) }
        plan.groups = entries.filter { !$0.isDone && ($0.kind == .feature || $0.kind == .milestone) }
            .sorted { ($0.kind == .milestone ? 0 : 1, $0.title.lowercased()) < ($1.kind == .milestone ? 0 : 1, $1.title.lowercased()) }
        plan.done = entries.filter(\.isDone).sorted { ($0.completedAt ?? .distantPast) > ($1.completedAt ?? .distantPast) }
        return plan
    }

    private func planEntry(_ item: WorkItem) -> ProjectPlanEntry {
        let id = ProjectGraph.normalizedID
        let detail = item.isOpen ? [item.stage.displayName, item.priority == .medium ? nil : "\(item.priority.rawValue.capitalized) priority"]
            .compactMap { $0 }.joined(separator: " · ") : ""
        return ProjectPlanEntry(
            origin: .work(item), id: item.id, title: item.title, kind: item.kind, isDone: !item.isOpen,
            detail: detail, completedAt: item.completedAt, stageRank: item.stage.rank, priorityRank: item.priority.rank,
            keys: Set([id(item.id)] + [item.importedNotionPageID.map(id)].compactMap { $0 }),
            parentKeys: Set((item.featureIDs + item.milestoneIDs + item.parentIDs + [item.parentID].compactMap { $0 }).map(id)),
            childKeys: [], dependencyKeys: Set(item.dependencyIDs.map(id)))
    }

    private func planEntry(_ record: ProjectGraphRecord, workByPath: [String: WorkItem]) -> ProjectPlanEntry? {
        guard let source = graphSource(for: record) else { return nil }
        let id = ProjectGraph.normalizedID
        func relations(_ names: [String]) -> Set<String> {
            Set(names.flatMap { record.value($0, source: source)["relation"].array.compactMap { $0["id"].string } }.map(id))
        }
        let kind: WorkItemKind = record.kind == .features ? .feature : record.kind == .milestones ? .milestone : .task
        let done = graphRecordIsCompleted(record, workByPath: workByPath)
        let stage = record.value("Work Stage", source: source).display
        let priority = record.value("Priority", source: source).display
        let stageRank = ["now": 0, "current": 0, "next": 1, "backlog": 2, "later": 2].first { $0.key == stage.lowercased() }?.value ?? 3
        let priorityRank = ["urgent": 0, "high": 0, "medium": 1, "low": 2].first { $0.key == priority.lowercased() }?.value ?? 1
        let status = kind == .milestone ? record.value("status", source: source).display : ""
        let detail = done ? "" : [stage.isEmpty ? nil : stage, priority.isEmpty || priority == "Medium" ? nil : "\(priority) priority", status.isEmpty ? nil : status]
            .compactMap { $0 }.joined(separator: " · ")
        let completedAt = record.value("date completed", source: source)["date"]["start"].string.flatMap(ProjectDates.parse)
        return ProjectPlanEntry(
            origin: .graph(record), id: record.id, title: record.title, kind: kind, isDone: done, detail: detail,
            completedAt: completedAt ?? (done ? record.editedAt : nil), stageRank: stageRank, priorityRank: priorityRank,
            keys: Set([id(record.id)] + [record.pageID.map(id)].compactMap { $0 }),
            parentKeys: relations(["Features", "Feature", "Milestones", "Milestone", "Parent Feature", "Parent Task", "Parent task", "Parent", "Parent item"]),
            childKeys: kind == .task ? [] : relations(["Tasks", "Child Features"]),
            dependencyKeys: relations(["Dependencies", "Blocked by", "depends on"]))
    }

    /// Marks a Notion-only task done (or open) here. Like every graph edit it stays local
    /// until it is reviewed in Send to Notion.
    func setGraphTask(_ record: ProjectGraphRecord, done: Bool) {
        guard let source = graphSource(for: record) else { return }
        var draft = graphRecords.first { $0.id == record.id } ?? record
        if source.property(named: "complete")?.definition["type"].string == "checkbox" { draft.set("complete", value: .bool(done), source: source) }
        if let field = source.property(named: "Status"), let type = field.definition["type"].string, ["status", "select"].contains(type) {
            let wanted = done ? ["done", "complete", "completed"] : ["todo", "to do", "not started", "open", "planned"]
            if let name = field.definition[type]["options"].array.compactMap({ $0["name"].string }).first(where: { wanted.contains($0.lowercased()) }) {
                draft.set("Status", value: ProjectJSON(["name": name]), source: source)
            }
        }
        if done, source.property(named: "date completed")?.definition["type"].string == "date" {
            draft.set("date completed", value: ProjectJSON(["start": ISO8601DateFormatter.planDay.string(from: Date())]), source: source)
        }
        saveGraphRecord(draft)
        statusMessage = done ? "Completed “\(record.title)”" : "Reopened “\(record.title)”"
    }

    /// Brings a task forward: Now for a work file, Notion's most immediate stage for a draft.
    func bringForward(_ entry: ProjectPlanEntry) {
        switch entry.origin {
        case .work(let item):
            var current = workItems.first { $0.id == item.id } ?? item
            current.stage = .now
            updateWorkItem(current)
        case .graph(let record):
            guard let source = graphSource(for: record), let field = source.property(named: "Work Stage"),
                  let options = Optional(field.definition["select"]["options"].array.compactMap { $0["name"].string }),
                  let name = options.first(where: { ["now", "current"].contains($0.lowercased()) }) ?? options.first(where: { $0.lowercased() == "next" })
            else { return }
            var draft = graphRecords.first { $0.id == record.id } ?? record
            draft.set("Work Stage", value: ProjectJSON(["name": name]), source: source)
            saveGraphRecord(draft)
        }
    }

    /// A new planning record of `kind` already related to `project`, ready for the editor.
    func newGraphRecord(_ kind: ProjectEntityKind, in project: ProjectGraphRecord) -> ProjectGraphRecord? {
        guard let source = graphSources.first(where: { $0.kind == kind }) else { return nil }
        var record = ProjectGraphRecord(sourceID: source.id, kind: kind)
        for (name, schema) in source.schema.object where schema["type"].string == "relation" && schema["relation"]["data_source_id"].string == project.sourceID {
            record.set(name, value: ProjectJSON([["id": project.pageID ?? project.id]]), source: source)
        }
        return record
    }
}

private extension ISO8601DateFormatter {
    static let planDay: ISO8601DateFormatter = { let f = ISO8601DateFormatter(); f.formatOptions = [.withFullDate]; return f }()
}

// MARK: - The Tasks tab

/// "What should I work on next?" first; then what is active, what it rolls up into,
/// and, out of the way, what is finished.
struct ProjectPlanView: View {
    @Environment(AppModel.self) private var model
    let local: WorkspaceItem?
    let graph: ProjectGraphRecord?
    @State private var showAllTasks = false
    @State private var showDone = false
    @State private var showAssessment = false
    @State private var showActivity = false
    @State private var showingAgentTasks = false
    @State private var creating: WorkItemKind?
    @State private var editingGraph: ProjectGraphRecord?

    private static let visibleTasks = 6

    var body: some View {
        let plan = model.projectPlan(local: local, graph: graph)
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.loose) {
                header(plan)
                hero(plan)
                if let local, !model.projectMetadata(for: local).blockers.isEmpty {
                    Label(model.projectMetadata(for: local).blockers.joined(separator: " · "), systemImage: "exclamationmark.circle")
                        .foregroundStyle(.orange)
                }
                if !plan.tasks.isEmpty { activeSection(plan) }
                if !plan.groups.isEmpty { groupsSection(plan) }
                if !plan.done.isEmpty { completedSection(plan) }
                if let local { moreSection(local) }
            }
            .padding(24).frame(maxWidth: 820, alignment: .leading).frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .accessibilityIdentifier("projects.plan")
        .sheet(item: $creating) { kind in creationSheet(kind) }
        .sheet(item: $editingGraph) { ProjectGraphRecordEditor(record: $0) }
        .sheet(isPresented: $showingAgentTasks) {
            if let local { AgentTaskSheet(project: local, graph: graph) }
        }
    }

    // MARK: Header and the next action

    private func header(_ plan: ProjectPlan) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Up Next").font(.title2.weight(.semibold))
            if plan.openCount > 0 {
                Text("\(plan.openCount) open · \(plan.doneCount) done")
                    .font(.callout).foregroundStyle(.secondary)
                    .accessibilityIdentifier("projects.progress")
            }
            Spacer()
            Button("Run with Agent…") { showingAgentTasks = true }
                .disabled(local == nil)
                .help(local == nil ? "Link a local project folder to run an agent." : "Select tasks, instructions, provider and model")
                .accessibilityIdentifier("projects.plan.agent")
            addMenu
        }
    }

    private var addMenu: some View {
        Menu {
            Button { add(.task) } label: { Label("New Task", systemImage: WorkItemKind.task.symbolName) }
            Button { add(.feature) } label: { Label("New Feature", systemImage: WorkItemKind.feature.symbolName) }
            Button { add(.milestone) } label: { Label("New Milestone", systemImage: WorkItemKind.milestone.symbolName) }
        } label: {
            Label("Add Task", systemImage: "plus")
        } primaryAction: { add(.task) }
        .menuStyle(.borderlessButton).fixedSize()
        .help("Add a task. Use the arrow for a feature or milestone.")
        .accessibilityIdentifier("projects.plan.add")
    }

    @ViewBuilder private func hero(_ plan: ProjectPlan) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let next = plan.next {
                if let item = next.workItem {
                    NextActionControls(item: item).id(item.id)
                } else if let record = next.graphRecord {
                    Text(record.title).font(.title2.weight(.medium)).fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("projects.nextAction.title")
                    if !next.detail.isEmpty { Text(next.detail).font(.caption).foregroundStyle(.secondary) }
                    HStack {
                        Button { model.setGraphTask(record, done: true) } label: { Label("Complete", systemImage: "checkmark.circle") }
                            .buttonStyle(.borderedProminent).accessibilityIdentifier("projects.nextAction.complete")
                        Button("Open") { editingGraph = record }
                    }
                }
            } else if model.isAwaitingWorkItems && local != nil {
                HStack(spacing: Theme.Space.snug) { ProgressView().controlSize(.small); Text("Loading tasks…").foregroundStyle(.secondary) }
            } else if plan.isEmpty {
                emptyHero(symbol: "checklist", title: "No tasks yet", message: "Add the first thing to do for this project.")
            } else if plan.openCount == 0 {
                emptyHero(symbol: "checkmark.circle", title: "All caught up", message: "Everything here is done. Add a task when there is more.")
            } else {
                emptyHero(symbol: "arrow.up.circle", title: "Nothing is up next",
                          message: "Bring a task forward from Active below to make it the next action.", showsAdd: false)
            }
        }
        .padding(Theme.Space.base).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(plan.next == nil ? 0.04 : 0.08), in: RoundedRectangle(cornerRadius: Theme.Radius.card))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card).strokeBorder(Color.accentColor.opacity(0.18)))
        // Contain, not inherit: otherwise every control inside reports this id.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("projects.nextAction")
    }

    private func emptyHero(symbol: String, title: String, message: String, showsAdd: Bool = true) -> some View {
        HStack(alignment: .center, spacing: Theme.Space.base) {
            Image(systemName: symbol).font(.system(size: 26)).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.title3.weight(.medium))
                Text(message).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            if showsAdd { Button("Add Task") { add(.task) }.accessibilityIdentifier("projects.plan.emptyAdd") }
        }
    }

    // MARK: Sections

    private func activeSection(_ plan: ProjectPlan) -> some View {
        let shown = showAllTasks ? plan.tasks : Array(plan.tasks.prefix(Self.visibleTasks))
        return PlanSection(title: "Active", count: plan.tasks.count) {
            ForEach(shown) { row($0) }
            if plan.tasks.count > Self.visibleTasks {
                Button(showAllTasks ? "Show fewer" : "Show all \(plan.tasks.count)") { showAllTasks.toggle() }
                    .buttonStyle(.link).padding(.top, 4)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("projects.plan.active")
    }

    private func groupsSection(_ plan: ProjectPlan) -> some View {
        PlanSection(title: "Features & Milestones", count: plan.groups.count) {
            ForEach(plan.groups) { group in
                PlanGroupRow(group: group, members: plan.members(of: group), row: { row($0, indented: true) }, open: { open(group) })
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("projects.plan.groups")
    }

    private func completedSection(_ plan: ProjectPlan) -> some View {
        DisclosureGroup(isExpanded: $showDone) {
            VStack(alignment: .leading, spacing: 0) { ForEach(plan.done.prefix(50)) { row($0) } }
            if plan.done.count > 50 { Text("Showing the 50 most recent").font(.caption).foregroundStyle(.secondary) }
        } label: {
            Text("Completed · \(plan.done.count)").font(.headline).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("projects.plan.completed")
    }

    @ViewBuilder private func moreSection(_ local: WorkspaceItem) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.snug) {
            if model.projectAudit(for: local) != nil {
                foldButton("Assessment & ranked backlog", isOpen: $showAssessment)
                if showAssessment { ProjectAuditPanel(project: local) }
            }
            foldButton("Activity", isOpen: $showActivity)
            if showActivity { ProjectWorkspaceActivity(project: local).frame(height: 280) }
        }
    }

    /// A whole-row toggle: the content below is built only once it is opened.
    private func foldButton(_ title: String, isOpen: Binding<Bool>) -> some View {
        Button { isOpen.wrappedValue.toggle() } label: {
            Label(title, systemImage: isOpen.wrappedValue ? "chevron.down" : "chevron.right")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Rows and actions

    private func row(_ entry: ProjectPlanEntry, indented: Bool = false) -> some View {
        PlanRow(entry: entry, pending: entry.workItem.map(model.isPendingCompletion) ?? false,
                toggle: { toggle(entry) }, open: { open(entry) }, bringForward: { model.bringForward(entry) },
                delete: entry.workItem.map { item in { model.requestDeletion(of: item) } }, marksNotionOnly: local != nil)
            .padding(.leading, indented ? 22 : 0)
    }

    private func toggle(_ entry: ProjectPlanEntry) {
        switch entry.origin {
        case .work(let item): model.completeWorkItem(item)
        case .graph(let record): model.setGraphTask(record, done: !entry.isDone)
        }
    }

    private func open(_ entry: ProjectPlanEntry) {
        switch entry.origin {
        case .work(let item): model.edit(workItem: item)
        case .graph(let record): editingGraph = record
        }
    }

    private func add(_ kind: WorkItemKind) {
        if local == nil, let graph {
            let entity: ProjectEntityKind = kind == .feature ? .features : kind == .milestone ? .milestones : .tasks
            editingGraph = model.newGraphRecord(entity, in: graph)
        } else {
            creating = kind
        }
    }

    @ViewBuilder private func creationSheet(_ kind: WorkItemKind) -> some View {
        if let local {
            WorkItemEditor(mode: .create, kind: kind, projectPath: model.workspaceRelativePath(for: local.url)) { value in
                try await model.createWorkItem(value)
            }
        }
    }
}

/// A quiet section heading with a count, and its rows.
private struct PlanSection<Content: View>: View {
    let title: String
    let count: Int
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(title).font(.headline)
                Text("\(count)").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            }
            .padding(.bottom, 4)
            content
        }
    }
}

/// One task: a completion circle, its title, and when it is planned for.
private struct PlanRow: View {
    let entry: ProjectPlanEntry
    let pending: Bool
    let toggle: () -> Void
    let open: () -> Void
    let bringForward: () -> Void
    let delete: (() -> Void)?
    /// In a project with files, a task that exists only in Notion is worth marking.
    var marksNotionOnly = false

    var body: some View {
        HStack(spacing: 8) {
            if entry.kind == .task || entry.kind == .goal {
                Button(action: toggle) {
                    Image(systemName: entry.isDone || pending ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(entry.isDone ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tint))
                }
                .buttonStyle(.plain)
                .help(entry.isDone ? "Reopen" : "Mark complete")
                .accessibilityLabel(entry.isDone ? "Reopen \(entry.title)" : "Complete \(entry.title)")
            } else {
                Image(systemName: entry.kind.symbolName).foregroundStyle(.secondary).frame(width: 16)
            }
            Button(action: open) {
                HStack {
                    Text(entry.title).lineLimit(1).foregroundStyle(entry.isDone ? .secondary : .primary)
                    Spacer(minLength: 8)
                    if entry.isDone, let date = entry.completedAt {
                        Text(Format.relativeDate(date)).font(.caption).foregroundStyle(.tertiary)
                    } else if !entry.displayDetail.isEmpty {
                        Text(entry.displayDetail).font(.caption).foregroundStyle(entry.waitingOn > 0 ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary)).lineLimit(1)
                    }
                    if marksNotionOnly, case .graph = entry.origin {
                        Image(systemName: "cloud").font(.caption2).foregroundStyle(.tertiary)
                            .help("Only in Notion; no task file yet")
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 5)
        .contextMenu {
            if entry.kind == .task { Button(entry.isDone ? "Reopen" : "Complete", action: toggle) }
            if !entry.isDone, entry.kind == .task { Button("Make Next Action", action: bringForward) }
            Button("Open", action: open)
            if let delete { Divider(); Button("Delete…", role: .destructive, action: delete) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("projects.plan.row.\(entry.title)")
    }
}

/// A feature or milestone with its progress; its open tasks on demand.
private struct PlanGroupRow<Row: View>: View {
    let group: ProjectPlanEntry
    let members: [ProjectPlanEntry]
    let row: (ProjectPlanEntry) -> Row
    let open: () -> Void
    @State private var expanded = false

    var body: some View {
        let done = members.filter(\.isDone).count
        let openMembers = members.filter { !$0.isDone }
        DisclosureGroup(isExpanded: $expanded) {
            ForEach(openMembers) { row($0) }
            if openMembers.isEmpty { Text(members.isEmpty ? "No tasks yet" : "All tasks done").font(.caption).foregroundStyle(.secondary).padding(.leading, 22) }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: group.kind.symbolName).foregroundStyle(.secondary).frame(width: 16)
                Button(action: open) { Text(group.title).lineLimit(1) }.buttonStyle(.plain)
                Spacer(minLength: 8)
                if !members.isEmpty {
                    ProgressView(value: Double(done), total: Double(members.count)).frame(width: 60)
                    Text("\(done)/\(members.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                } else if !group.detail.isEmpty {
                    Text(group.detail).font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 3)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("projects.plan.group.\(group.title)")
    }
}
