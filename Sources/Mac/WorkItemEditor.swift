import SwiftUI
import BetterWorkspaceCore

/// Creates and edits one portable work record (a `.bw.md` file): a task, feature,
/// milestone or goal.
///
/// It is laid out like the planning-record editor: a name, notes, a few essentials,
/// where it belongs, and — for a feature or milestone — its tasks. Type, parent, related
/// work and dependencies are under More Options. Every choice of other work is searched
/// and limited to the same project unless other projects are asked for.
struct WorkItemEditor: View {
    enum Mode { case create, edit(WorkItem) }
    struct Value {
        var kind: WorkItemKind; var title: String; var body: String; var status: WorkItemStatus
        var stage: WorkItemStage; var priority: WorkItemPriority; var projectPath: String?
        var parentID: String?; var relatedIDs: [String]
        var featureIDs: [String] = []; var milestoneIDs: [String] = []
        var dependencyIDs: [String] = []
    }
    let mode: Mode
    /// Create mode only: writes the new record and returns it. Edit mode saves through
    /// the model so it can offer the conflict choices below.
    let create: ((Value) async throws -> WorkItem)?
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var kind: WorkItemKind
    @State private var title: String
    @State private var notes: String
    /// Existing notes open rendered; new ones open for writing.
    @State private var previewingNotes: Bool
    @State private var status: WorkItemStatus
    @State private var stage: WorkItemStage
    @State private var priority: WorkItemPriority
    @State private var projectPath: String
    @State private var parentID: String
    @State private var relatedItemIDs: Set<String>
    @State private var dependencyIDs: Set<String>
    @State private var featureIDs: [String]
    @State private var milestoneIDs: [String]
    @State private var tags: [Tag] = []
    /// A feature's or milestone's tasks: existing ones linked here, and new ones to make.
    @State private var memberIDs: Set<String> = []
    @State private var newTaskTitles: [String] = []
    @State private var showMore = false
    /// The record as last read from disk — what a save is checked against.
    @State private var base: WorkItem?
    @State private var saving = false
    @State private var problem: Problem?

    /// Why the last save did not happen. The sheet stays open with the person's edits
    /// intact; it used to close first and report afterwards, losing what they typed.
    enum Problem { case changedOnDisk, missing, other(String) }

    init(mode: Mode, kind initialKind: WorkItemKind = .task, projectPath initialProjectPath: String? = nil,
         create: ((Value) async throws -> WorkItem)? = nil) {
        self.mode = mode; self.create = create
        let item: WorkItem? = if case let .edit(value) = mode { value } else { nil }
        _base = State(initialValue: item)
        _kind = State(initialValue: item?.kind ?? initialKind); _title = State(initialValue: item?.title ?? "")
        _notes = State(initialValue: item?.body ?? "")
        _previewingNotes = State(initialValue: (item?.body ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
        _status = State(initialValue: item?.status ?? .open)
        _stage = State(initialValue: item?.stage ?? .next); _priority = State(initialValue: item?.priority ?? .medium)
        _projectPath = State(initialValue: item?.projectPath ?? initialProjectPath ?? "")
        _parentID = State(initialValue: item?.parentID ?? "")
        _relatedItemIDs = State(initialValue: Set(item?.relatedIDs ?? []))
        _dependencyIDs = State(initialValue: Set(item?.dependencyIDs ?? []))
        _featureIDs = State(initialValue: item?.featureIDs ?? [])
        _milestoneIDs = State(initialValue: item?.milestoneIDs ?? [])
    }

    private var isNew: Bool { base == nil }
    private var groupsTasks: Bool { kind == .feature || kind == .milestone }

    private var value: Value {
        Value(kind: kind, title: title, body: notes, status: status, stage: stage, priority: priority,
              projectPath: projectPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : projectPath,
              parentID: parentID.isEmpty ? nil : parentID, relatedIDs: relatedItemIDs.sorted(),
              featureIDs: links.featureIDs, milestoneIDs: links.milestoneIDs, dependencyIDs: dependencyIDs.sorted())
    }

    /// Project, feature and milestone as the pickers see them, trimmed to what this kind can hold.
    private var links: WorkItemLinks {
        WorkItemLinks(projectPath: projectPath, featureIDs: featureIDs, milestoneIDs: milestoneIDs).applicable(to: kind)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.base) {
                    Text(isNew ? "New \(kind.displayName)" : kind.displayName).font(.headline).foregroundStyle(.secondary)
                    TextField("\(kind.displayName) name", text: $title, axis: .vertical)
                        .font(.system(size: 20, weight: .semibold)).textFieldStyle(.plain).lineLimit(1...3)
                        .accessibilityIdentifier("workItem.title")
                    notesField
                    essentials
                    if groupsTasks { tasksSection }
                    moreOptions
                    if let problem { problemView(problem) }
                }
                .padding(20)
            }
            Divider()
            footer.padding(.horizontal, 20).padding(.vertical, 12)
        }
        .frame(width: 560)
        .frame(minHeight: 320, idealHeight: 520, maxHeight: 680)
        .task { @MainActor in
            guard let base else { return }
            tags = model.tags(forWorkAt: base.url)
            memberIDs = Set(members(of: base).map(\.id))
        }
    }

    // MARK: Sections

    /// Notes are Markdown: rendered when there are some, written in place otherwise.
    @ViewBuilder private var notesField: some View {
        if previewingNotes && !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                MarkdownView(text: notes).frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("workItem.notesPreview")
                Button("Edit Notes") { previewingNotes = false }.buttonStyle(.link).font(.callout)
                    .accessibilityIdentifier("workItem.editNotes")
            }
        } else {
            TextField("Notes", text: $notes, axis: .vertical)
                .textFieldStyle(.plain).lineLimit(3...12)
                .help("Markdown")
                .accessibilityIdentifier("workItem.notes")
        }
    }

    private var essentials: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: Theme.Space.base, verticalSpacing: 8) {
            if !isNew {
                GridRow {
                    label("Status")
                    Picker("Status", selection: $status) { ForEach(WorkItemStatus.allCases) { Text($0.displayName).tag($0) } }
                        .labelsHidden().fixedSize()
                        .disabled(base.map(model.isComputedNotionMilestone) ?? false)
                        .help(base.map(model.isComputedNotionMilestone) == true ? "Notion works this out from the milestone’s tasks and dates" : "")
                }
            }
            if kind != .milestone {
                GridRow {
                    label("When")
                    Picker("When", selection: $stage) { ForEach(WorkItemStage.allCases) { Text($0.displayName).tag($0) } }
                        .pickerStyle(.segmented).labelsHidden().fixedSize()
                        .help("Now and Next are eligible to be the next action; Later is not")
                        .accessibilityIdentifier("workItem.stage")
                }
                GridRow {
                    label("Priority")
                    Picker("Priority", selection: $priority) { ForEach(WorkItemPriority.allCases) { Text($0.rawValue.capitalized).tag($0) } }
                        .pickerStyle(.segmented).labelsHidden().fixedSize()
                }
            }
            GridRow {
                label("Part of")
                model.linkPickers(kind: kind, links: links, excluding: base?.id, compact: false) { next in
                    projectPath = next.projectPath ?? ""
                    featureIDs = next.featureIDs
                    milestoneIDs = next.milestoneIDs
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("workItem.links")
            }
            GridRow {
                label("Tags")
                TagEditor(assigned: tags, allTags: model.allTags,
                          onAssign: { tag in if !tags.contains(tag) { tags.append(tag) } },
                          onUnassign: { tag in tags.removeAll { $0.id == tag.id } },
                          onCreate: { model.createTag(named: $0) }, compact: true)
            }
        }
    }

    private func label(_ text: String) -> some View {
        Text(text).foregroundStyle(.secondary).gridColumnAlignment(.trailing).fixedSize()
    }

    /// A feature's or milestone's tasks: add new ones by name, or link open tasks.
    private var tasksSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Tasks").font(.headline)
                Spacer()
                WorkPickerButton(title: "Add Task", symbol: "plus", candidates: taskCandidates, selected: memberIDs,
                                 projectPath: value.projectPath, allowsNew: true,
                                 onNew: { newTaskTitles.append($0) },
                                 onToggle: { id in if memberIDs.contains(id) { memberIDs.remove(id) } else { memberIDs.insert(id) } })
                    .accessibilityIdentifier("workItem.addTask")
            }
            ForEach(model.workItems.filter { memberIDs.contains($0.id) }) { task in
                memberRow(task.title, done: !task.isOpen) { memberIDs.remove(task.id) }
            }
            ForEach(Array(newTaskTitles.enumerated()), id: \.offset) { index, name in
                memberRow(name, isNew: true) { newTaskTitles.remove(at: index) }
            }
            if memberIDs.isEmpty && newTaskTitles.isEmpty {
                Text("No tasks yet").font(.callout).foregroundStyle(.tertiary)
            }
        }
        .padding(.top, 4)
    }

    private func memberRow(_ name: String, done: Bool = false, isNew: Bool = false, remove: @escaping () -> Void) -> some View {
        HStack(spacing: 6) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle").foregroundStyle(.tertiary)
            Text(name).lineLimit(1).foregroundStyle(done ? .secondary : .primary)
            if isNew { Text("New").font(.caption2.weight(.medium)).foregroundStyle(.tint) }
            Spacer()
            Button(action: remove) { Image(systemName: "minus.circle") }
                .buttonStyle(.borderless).foregroundStyle(.secondary).help("Remove from this \(kind.displayName.lowercased())")
        }
    }

    private var moreOptions: some View {
        DisclosureGroup(isExpanded: $showMore) {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: Theme.Space.base, verticalSpacing: 10) {
                GridRow {
                    label("Type")
                    Picker("Type", selection: $kind) { ForEach(WorkItemKind.allCases) { Text($0.displayName).tag($0) } }
                        .labelsHidden().fixedSize()
                        .disabled(base?.importedNotionPageID != nil)
                        .help(base?.importedNotionPageID != nil ? "Linked to a Notion record, whose type cannot change here" : "")
                }
                GridRow {
                    label("Part of task")
                    WorkPickerButton(title: parentTitle, symbol: nil, candidates: workCandidates(excluding: []), selected: parentID.isEmpty ? [] : [parentID],
                                     projectPath: value.projectPath, allowsNew: false, single: true,
                                     onNew: { _ in }, onToggle: { id in parentID = parentID == id ? "" : id })
                }
                GridRow {
                    label("Waiting on")
                    WorkPickerButton(title: summary(dependencyIDs, none: "Nothing"), symbol: nil, candidates: workCandidates(excluding: []),
                                     selected: dependencyIDs, projectPath: value.projectPath, allowsNew: false,
                                     onNew: { _ in }, onToggle: { id in if dependencyIDs.contains(id) { dependencyIDs.remove(id) } else { dependencyIDs.insert(id) } })
                        .help("It is not the next action until these are complete")
                }
                GridRow {
                    label("Related")
                    WorkPickerButton(title: summary(relatedItemIDs, none: "None"), symbol: nil, candidates: workCandidates(excluding: []),
                                     selected: relatedItemIDs, projectPath: value.projectPath, allowsNew: false,
                                     onNew: { _ in }, onToggle: { id in if relatedItemIDs.contains(id) { relatedItemIDs.remove(id) } else { relatedItemIDs.insert(id) } })
                }
            }
            .padding(.top, 6)
        } label: {
            Text("More Options").font(.callout.weight(.medium))
        }
        .accessibilityIdentifier("workItem.moreOptions")
    }

    private var footer: some View {
        HStack {
            if let base {
                Menu {
                    Button("Open File") { model.open(base.url) }
                    Button("Reveal in Finder") { model.revealInFinder(base.url) }
                    if base.projectPath != nil { Button("Open Project") { model.revealProject(for: base); dismiss() } }
                } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("More actions")
            }
            Spacer()
            Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            Button("Save") { Task { await save() } }
                .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                .disabled(saving || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("workItem.save")
        }
    }

    // MARK: Candidates

    private var parentTitle: String {
        parentID.isEmpty ? "None" : model.workItems.first { $0.id == parentID }?.title ?? "Unavailable"
    }

    private func summary(_ ids: Set<String>, none: String) -> String {
        let names = model.workItems.filter { ids.contains($0.id) }.map(\.title)
        return names.isEmpty ? none : names.count == 1 ? names[0] : "\(names.count) items"
    }

    private func workCandidates(excluding: Set<String>) -> [WorkItem] {
        model.workItems.filter { $0.id != base?.id && !excluding.contains($0.id) }
    }

    private var taskCandidates: [WorkItem] {
        model.workItems.filter { $0.kind == .task && $0.id != base?.id && ($0.isOpen || memberIDs.contains($0.id)) }
    }

    private func members(of item: WorkItem) -> [WorkItem] {
        model.workItems.filter { $0.id != item.id && ($0.featureIDs.contains(item.id) || $0.milestoneIDs.contains(item.id)) }
    }

    // MARK: Problems and saving

    @ViewBuilder
    private func problemView(_ problem: Problem) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.tight) {
            switch problem {
            case .changedOnDisk:
                Label("This file changed in Finder or another editor while you were editing.",
                      systemImage: "exclamationmark.triangle.fill")
                HStack {
                    Button("Use the Version on Disk") { reloadFromDisk() }
                        .help("Discard your edits here and show what the file says now")
                    Button("Replace It with Mine") { Task { await save(overwriting: true) } }
                        .help("Save what is in this window over the other change")
                        .accessibilityIdentifier("workItem.overwrite")
                }
            case .missing:
                Label("This file was moved or deleted outside Better Workspace.", systemImage: "questionmark.folder.fill")
                Button("Save as New") { Task { await saveAsNew() } }
                    .help("Write your edits as a new record in the same folder")
                    .accessibilityIdentifier("workItem.saveAsNew")
            case .other(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill")
            }
        }
        .font(.callout)
        .foregroundStyle(.orange)
        // A container, or this identifier replaces the buttons' own.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("workItem.problem")
    }

    @MainActor
    private func save(overwriting: Bool = false) async {
        saving = true
        defer { saving = false }
        do {
            let saved: WorkItem
            switch mode {
            case .create:
                guard let create else { return }
                saved = try await create(value)
            case .edit:
                guard var updated = base else { return }
                if overwriting, let current = model.workItemService.read(at: updated.url) {
                    // Chosen explicitly: check against what is on disk now, not the
                    // snapshot the editor opened with.
                    updated = current
                }
                updated.kind = kind; updated.title = title; updated.body = notes
                updated.status = status; updated.stage = stage; updated.priority = priority
                updated.projectPath = value.projectPath
                updated.parentID = parentID.isEmpty ? nil : parentID
                updated.relatedIDs = relatedItemIDs.sorted()
                updated.dependencyIDs = dependencyIDs.sorted()
                updated.featureIDs = value.featureIDs; updated.milestoneIDs = value.milestoneIDs
                saved = try await model.saveWorkItem(updated)
            }
            model.setTags(tags, forWorkAt: saved.url)
            if groupsTasks { try await saveMembers(of: saved) }
            dismiss()
        } catch WorkItemService.WorkItemError.changedOnDisk {
            problem = .changedOnDisk
        } catch WorkItemService.WorkItemError.missing {
            problem = .missing
        } catch {
            problem = .other(error.localizedDescription)
        }
    }

    /// Links and unlinks existing tasks, then makes the new ones, in this record's project.
    @MainActor
    private func saveMembers(of group: WorkItem) async throws {
        let keyPath: WritableKeyPath<WorkItem, [String]> = group.kind == .milestone ? \.milestoneIDs : \.featureIDs
        let before = Set(members(of: group).map(\.id))
        for id in memberIDs.symmetricDifference(before) {
            guard var task = model.workItems.first(where: { $0.id == id }) else { continue }
            if memberIDs.contains(id) { task[keyPath: keyPath].append(group.id) } else { task[keyPath: keyPath].removeAll { $0 == group.id } }
            try await model.saveWorkItem(task)
        }
        for name in newTaskTitles where !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            var task = Value(kind: .task, title: name, body: "", status: .open, stage: .next, priority: .medium,
                             projectPath: group.projectPath, parentID: nil, relatedIDs: [])
            task[keyPath: group.kind == .milestone ? \Value.milestoneIDs : \Value.featureIDs] = [group.id]
            try await model.createWorkItem(task)
        }
        newTaskTitles = []
    }

    private func reloadFromDisk() {
        guard let url = base?.url, let current = model.workItemService.read(at: url) else {
            problem = .missing
            return
        }
        base = current
        kind = current.kind; title = current.title; notes = current.body; status = current.status
        stage = current.stage; priority = current.priority; projectPath = current.projectPath ?? ""
        parentID = current.parentID ?? ""
        relatedItemIDs = Set(current.relatedIDs); dependencyIDs = Set(current.dependencyIDs)
        featureIDs = current.featureIDs; milestoneIDs = current.milestoneIDs
        problem = nil
    }

    @MainActor
    private func saveAsNew() async {
        guard let url = base?.url else { return }
        do {
            let v = value
            let saved = try await model.createWorkItem(kind: v.kind, title: v.title, body: v.body, status: v.status,
                                                       stage: v.stage, priority: v.priority, projectPath: v.projectPath,
                                                       parentID: v.parentID, relatedIDs: v.relatedIDs,
                                                       featureIDs: v.featureIDs, milestoneIDs: v.milestoneIDs,
                                                       dependencyIDs: v.dependencyIDs, in: url.deletingLastPathComponent())
            model.setTags(tags, forWorkAt: saved.url)
            dismiss()
        } catch {
            problem = .other(error.localizedDescription)
        }
    }
}

/// Chooses other work by searching, limited to `projectPath` until other projects are
/// asked for. Optionally names a new task instead.
struct WorkPickerButton: View {
    let title: String
    let symbol: String?
    let candidates: [WorkItem]
    let selected: Set<String>
    let projectPath: String?
    let allowsNew: Bool
    var single = false
    let onNew: (String) -> Void
    let onToggle: (String) -> Void
    @State private var open = false

    var body: some View {
        Button { open = true } label: {
            if let symbol { Label(title, systemImage: symbol) } else { Text(title).lineLimit(1) }
        }
        .buttonStyle(.borderless)
        .popover(isPresented: $open, arrowEdge: .trailing) {
            WorkPicker(candidates: candidates, selected: selected, projectPath: projectPath, allowsNew: allowsNew,
                       onNew: { onNew($0); open = false },
                       onToggle: { onToggle($0); if single { open = false } })
        }
    }
}

private struct WorkPicker: View {
    let candidates: [WorkItem]
    let selected: Set<String>
    let projectPath: String?
    let allowsNew: Bool
    let onNew: (String) -> Void
    let onToggle: (String) -> Void
    @State private var creating: Bool
    @State private var name = ""
    @State private var query = ""
    @State private var everywhere = false
    @FocusState private var focused: Bool

    init(candidates: [WorkItem], selected: Set<String>, projectPath: String?, allowsNew: Bool,
         onNew: @escaping (String) -> Void, onToggle: @escaping (String) -> Void) {
        self.candidates = candidates; self.selected = selected; self.projectPath = projectPath
        self.allowsNew = allowsNew; self.onNew = onNew; self.onToggle = onToggle
        _creating = State(initialValue: allowsNew)
    }

    private func inScope(_ item: WorkItem) -> Bool { projectPath == nil || item.projectPath == projectPath }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if allowsNew {
                Picker("", selection: $creating) { Text("New Task").tag(true); Text("Existing").tag(false) }
                    .pickerStyle(.segmented).labelsHidden()
            }
            if creating && allowsNew {
                TextField("Task name", text: $name).textFieldStyle(.roundedBorder).focused($focused)
                    .onSubmit(submit).accessibilityIdentifier("workPicker.name")
                HStack { Spacer(); Button("Add", action: submit).keyboardShortcut(.defaultAction).disabled(name.trimmingCharacters(in: .whitespaces).isEmpty) }
            } else {
                existing
            }
        }
        .padding(14).frame(width: 340)
        .onAppear { focused = true }
    }

    private var existing: some View {
        let visible = candidates
            .filter { everywhere || inScope($0) || selected.contains($0.id) }
            .filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) }
            .sorted { lhs, rhs in
                if selected.contains(lhs.id) != selected.contains(rhs.id) { return selected.contains(lhs.id) }
                if lhs.isOpen != rhs.isOpen { return lhs.isOpen }
                return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
            }
        let hidden = candidates.filter { !inScope($0) }.count
        return VStack(alignment: .leading, spacing: 8) {
            InlineSearchField(text: $query, prompt: "Search work")
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(visible.prefix(200)) { item in
                        Button { onToggle(item.id) } label: {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Image(systemName: selected.contains(item.id) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(selected.contains(item.id) ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(item.title).lineLimit(2).foregroundStyle(item.isOpen ? .primary : .secondary)
                                    Text(detail(item)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.vertical, 5).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    if visible.isEmpty {
                        Text(query.isEmpty ? "Nothing in this project yet." : "Nothing matches “\(query)”.")
                            .font(.callout).foregroundStyle(.secondary).padding(.vertical, 8)
                    }
                }
            }
            .frame(minHeight: 60, maxHeight: 260)
            if projectPath != nil, hidden > 0 {
                Toggle("Include other projects (\(hidden))", isOn: $everywhere).toggleStyle(.checkbox).font(.caption)
            }
        }
    }

    private func detail(_ item: WorkItem) -> String {
        var parts = [item.kind.displayName, item.isOpen ? item.stage.displayName : "Done"]
        if !inScope(item), let project = item.projectPath { parts.append((project as NSString).lastPathComponent) }
        return parts.joined(separator: " · ")
    }

    private func submit() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onNew(trimmed)
    }
}
