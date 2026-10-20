import SwiftUI
import TipKit
import UIKit
import BetterWorkspaceCore

struct MobilePlanningStatusSection: View {
    @Environment(MobileWorkspaceModel.self) private var model
    var body: some View {
        if hasStatus {
            Section {
                if hasDrafts {
                    let waiting = model.waitingPlanningDrafts
                    if !waiting.isEmpty {
                        Label("\(waiting.count) change\(waiting.count == 1 ? "" : "s") waiting for the Mac", systemImage: "clock")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    ForEach(model.planningDrafts.filter { model.planningErrors[$0.id.uuidString] != nil }) { draft in
                        NavigationLink { MobileSavedDraftView(draft: draft) } label: {
                            Label("Review “\(draft.title)”", systemImage: "exclamationmark.circle")
                        }
                    }
                } else if case .ready = model.syncState {
                    if model.pendingIntentCount > 0 { SyncNotice(state: model.syncState, pendingIntentCount: model.pendingIntentCount) }
                } else { SyncNotice(state: model.syncState, pendingIntentCount: model.pendingIntentCount) }
            }
        }
    }
    /// Drafts worth mentioning: waiting for the Mac, or refused by it.
    private var hasDrafts: Bool {
        !model.waitingPlanningDrafts.isEmpty || model.planningDrafts.contains { model.planningErrors[$0.id.uuidString] != nil }
    }
    private var hasStatus: Bool {
        if hasDrafts || model.pendingIntentCount > 0 { return true }
        if case .ready = model.syncState { return false }
        return true
    }

}

private struct MobileSavedDraftView: View {
    @Environment(MobileWorkspaceModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let draft: MobilePlanningEdit
    var body: some View {
        List {
            Text(model.planningErrors[draft.id.uuidString] ?? "Waiting for the Mac.").foregroundStyle(.secondary)
            Section {
                Text(draft.title).font(.headline).textSelection(.enabled)
                if let change = draft.projectEdit {
                    Text(change.oneLiner).textSelection(.enabled)
                    MarkdownView(text: change.summary)
                    ForEach(change.ratings.keys.sorted(), id: \.self) { key in
                        LabeledContent(MetricDefinition.find(id: key)?.displayName ?? key, value: "\(change.ratings[key] ?? 0)/5")
                    }
                } else if let planning = draft.ideaPlanning {
                    LabeledContent("Priority", value: "\(planning.priority)/5")
                    LabeledContent("Potential", value: planning.potential?.title ?? "Just an idea")
                    ForEach(planning.ratings.keys.sorted(), id: \.self) { key in
                        LabeledContent(MetricDefinition.find(id: key)?.displayName ?? key, value: "\(planning.ratings[key] ?? 0)/5")
                    }
                } else if let kind = draft.ideaPromotion {
                    LabeledContent("Move entire folder to", value: kind.area)
                } else if let schedule = draft.captureReview {
                    LabeledContent("Priority", value: "\(schedule.priority)/5")
                    LabeledContent("Return", value: schedule.until?.formatted(date: .abbreviated, time: .shortened) ?? "Review now")
                } else if let review = draft.inboxReview {
                    LabeledContent("Folder", value: review.item.category)
                    LabeledContent("Decision", value: review.action == .done ? review.item.decision
                                   : review.action == .snooze ? "Deal with later" : review.action == .archive ? "Archive" : review.item.actions.retireTitle)
                } else {
                    MarkdownView(text: draft.work?.body ?? draft.description)
                }
                if let work = draft.work {
                    LabeledContent("Stage", value: work.stage.displayName)
                    LabeledContent("Status", value: work.status.displayName)
                    LabeledContent("Priority", value: work.priority.rawValue.capitalized)
                    if let path = work.projectPath { LabeledContent("Project", value: path) }
                }
            } header: { Label("Saved phone draft · not applied", systemImage: "iphone").foregroundStyle(.blue) }
            if let original = draft.originalWork, let latest = model.macWorkItems.first(where: { $0.id == original.id }) {
                Section {
                    Text(latest.title).font(.headline)
                    MarkdownView(text: latest.body ?? "")
                    LabeledContent("Stage", value: latest.stage.displayName)
                    LabeledContent("Status", value: latest.status.displayName)
                    LabeledContent("Priority", value: latest.priority.rawValue.capitalized)
                    if let modified = latest.modifiedAt { LabeledContent("Recorded edit", value: modified.formatted()) }
                } header: { Label("Current Mac snapshot", systemImage: "desktopcomputer").foregroundStyle(.purple) }
            }
            Text(draft.inboxReview == nil ? "Copy any changes you want to keep, refresh the record, then edit its current version."
                 : "Nothing was moved. Discard this decision; the item comes back to Overview when it is due.").foregroundStyle(.secondary)
            Button("Discard saved draft", role: .destructive) { model.discardPlanningDraft(draft.id); dismiss() }
        }.navigationTitle("Review draft")
    }
}

struct MobileWorkItemDetailView: View {
    @Environment(MobileWorkspaceModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let item: MobileWorkItem
    @State private var editing = false
    @State private var confirmingDelete = false
    /// The pushed value is frozen; the model's copy is what other screens edit.
    private var latest: MobileWorkItem? { model.snapshot.workItems.first { $0.id == item.id } }
    private var current: MobileWorkItem { latest ?? item }
    var body: some View {
        List {
            if latest == nil {
                // Deleted on the Mac, or by a refresh: say so rather than offering edits
                // the Mac could only refuse.
                Section {
                    Label("This item is no longer in your workspace.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("work-missing")
                }
            }
            Section {
                Text(MarkdownInline.attributed(current.title)).font(.title2.weight(.semibold)).textSelection(.enabled)
                if let body = current.body, !body.isEmpty { MarkdownView(text: body).accessibilityIdentifier("work-body") }
            }
            Section {
                LabeledContent("Stage", value: current.stage.displayName)
                LabeledContent("Status", value: current.status.displayName)
                LabeledContent("Priority", value: current.priority.rawValue.capitalized)
                if let due = current.dueDate { LabeledContent("Due", value: due.formatted(date: .abbreviated, time: .omitted)) }
                TagPills(tags: model.tags(for: current.tagIDs))
            }
            // Where it belongs, changed in place: each choice saves at once.
            Section {
                MobileWorkLinkPickers(kind: current.kind, links: current.links, excluding: current.id) { links in
                    model.setLinks(links, for: current)
                }
                .disabled(latest == nil)
            } header: {
                Text("Part of")
            } footer: {
                if current.needsAttention {
                    Text("No project yet. It is listed under Needs Attention until you choose one.")
                }
            }
            if latest != nil {
                Section {
                    Button(current.status == .completed ? "Reopen" : "Mark complete",
                           systemImage: current.status == .completed ? "arrow.uturn.backward.circle" : "checkmark.circle") {
                        model.toggleCompletion(of: current)
                    }
                    .accessibilityIdentifier("work-toggle-completion")
                    if current.kind == .task {
                        Button("Delete", systemImage: "trash", role: .destructive) { confirmingDelete = true }
                            .accessibilityIdentifier("work-delete")
                    } else {
                        Menu("More actions") {
                            Button("Delete…", systemImage: "trash", role: .destructive) { confirmingDelete = true }
                        }
                    }
                }
            }
        }
        .navigationTitle(current.kind.displayName)
        .refreshable { await model.refresh() }
        .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Edit") { editing = true }.disabled(latest == nil) } }
        .sheet(isPresented: $editing) { MobileWorkEditor(item: current) }
        .alert("Delete “\(current.title)”?", isPresented: $confirmingDelete) {
            Button("Delete", role: .destructive) { if model.trash(current) { dismiss() } }
        } message: {
            Text("Are you sure? Your Mac moves it to its recoverable Trash when online. Linked Notion pages stay in Notion.")
        }
    }
}

struct MobileWorkEditor: View {
    @Environment(MobileWorkspaceModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let original: MobileWorkItem?
    private let newID = UUID()
    @State private var title: String
    @State private var bodyText: String
    @State private var kind: WorkItemKind
    @State private var status: WorkItemStatus
    @State private var stage: WorkItemStage
    @State private var priority: WorkItemPriority
    @State private var projectPath: String
    @State private var featureIDs: [String]
    @State private var milestoneIDs: [String]
    /// Links are sent only when chosen here, so an edit never clears links the Mac set
    /// that this phone was not told about.
    @State private var linksTouched = false
    @State private var tags: Set<String>
    @State private var hasDueDate: Bool
    @State private var dueDate: Date
    @State private var error: String?

    init(item: MobileWorkItem? = nil, projectPath: String? = nil, kind: WorkItemKind = .task,
         title: String = "", description: String = "", tagIDs: Set<String> = []) {
        original = item
        _title = State(initialValue: item?.title ?? title)
        _bodyText = State(initialValue: item?.body ?? description)
        _kind = State(initialValue: item?.kind ?? kind)
        _status = State(initialValue: item?.status ?? .open)
        _stage = State(initialValue: item?.stage ?? .next)
        _priority = State(initialValue: item?.priority ?? .medium)
        _projectPath = State(initialValue: item?.projectPath ?? projectPath ?? "")
        _featureIDs = State(initialValue: item?.featureIDs ?? [])
        _milestoneIDs = State(initialValue: item?.milestoneIDs ?? [])
        _tags = State(initialValue: item?.tagIDs ?? tagIDs)
        _hasDueDate = State(initialValue: item?.dueDate != nil)
        _dueDate = State(initialValue: item?.dueDate ?? Date())
    }

    var body: some View {
        NavigationStack {
            Form {
                TipView(MobilePlanningSyncTip())
                Section {
                    TextField("\(kind.displayName) name", text: $title)
                        .font(.title3.weight(.semibold))
                        .accessibilityIdentifier("planning-title")
                    if original == nil || original?.body != nil {
                        TextEditor(text: $bodyText)
                            .frame(minHeight: 90)
                            .overlay(alignment: .topLeading) {
                                if bodyText.isEmpty {
                                    Text("Notes").foregroundStyle(.tertiary).padding(.top, 8).padding(.leading, 5).allowsHitTesting(false)
                                }
                            }
                            .accessibilityIdentifier("planning-description")
                    }
                }
                Section {
                    if kind != .milestone {
                        Picker("When", selection: $stage) { ForEach(WorkItemStage.allCases) { Text($0.displayName).tag($0) } }
                            .pickerStyle(.segmented)
                        Picker("Priority", selection: $priority) { ForEach(WorkItemPriority.allCases) { Text($0.rawValue.capitalized).tag($0) } }
                    }
                    MobileWorkLinkPickers(kind: kind, links: links, excluding: original?.id) { next in
                        projectPath = next.projectPath ?? ""
                        featureIDs = next.featureIDs
                        milestoneIDs = next.milestoneIDs
                        linksTouched = true
                    }
                }
                MobileDraftTagsSection(selected: $tags)
                Section {
                    DisclosureGroup("More Options") {
                        Picker("Type", selection: $kind) { ForEach(WorkItemKind.allCases) { Text($0.displayName).tag($0) } }
                        if original != nil {
                            Picker("Status", selection: $status) { ForEach(WorkItemStatus.allCases) { Text($0.displayName).tag($0) } }
                        }
                        Toggle("Due date", isOn: $hasDueDate)
                        if hasDueDate { DatePicker("Due", selection: $dueDate, displayedComponents: .date) }
                    }
                    .accessibilityIdentifier("planning-more-options")
                }
                if let error { Text(error).foregroundStyle(.red) }
            }
            .navigationTitle(original == nil ? "New \(kind.displayName)" : kind.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { save() }.disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
                ToolbarItem(placement: .keyboard) { Button("Done") { UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil) } }
            }
        }
    }
    private var links: WorkItemLinks {
        WorkItemLinks(projectPath: projectPath, featureIDs: featureIDs, milestoneIDs: milestoneIDs).applicable(to: kind)
    }

    private func save() {
        let send = original == nil || linksTouched
        let draft = MobileWorkItem(id: original?.id ?? newID.uuidString, path: original?.path ?? "To Do/\(newID.uuidString).bw.md",
            title: title.trimmingCharacters(in: .whitespacesAndNewlines), kind: kind, status: status, stage: stage,
            priority: priority, projectPath: projectPath.isEmpty ? nil : projectPath,
            dueDate: hasDueDate ? Date(timeIntervalSince1970: floor(dueDate.timeIntervalSince1970)) : nil, revision: original?.revision ?? 0, tagIDs: tags,
            body: original != nil && original?.body == nil ? nil : MobilePlanningFiles.normalizedWorkBody(bodyText),
            featureIDs: send ? links.featureIDs : nil, milestoneIDs: send ? links.milestoneIDs : nil)
        let edit = MobilePlanningEdit(id: original == nil ? newID : UUID(), operation: .saveWork, title: draft.title,
            description: bodyText, work: draft, originalWork: original, tagIDs: tags)
        if model.savePlanning(edit) { dismiss() } else { error = model.saveMessage }
    }
}

struct MobileIdeaDetailView: View {
    @Environment(MobileWorkspaceModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingDelete = false
    let idea: MobileIdea
    @State private var editing = false
    @State private var creatingFeature = false
    @State private var creatingProject = false
    @State private var scoring = false
    @State private var zenScoring = false
    @State private var promotion: IdeaPromotionKind?
    private var latest: MobileIdea? { model.snapshot.ideas.first { $0.id == idea.id } }
    private var current: MobileIdea { latest ?? idea }
    var body: some View {
        List {
            if latest == nil {
                Section {
                    Label("This idea is no longer in your workspace.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                }
            }
            Section {
                Text(MarkdownInline.attributed(current.title)).font(.title2.weight(.semibold)).textSelection(.enabled)
                if let description = current.description, !description.isEmpty { MarkdownView(text: description).accessibilityIdentifier("idea-description") }
                else { Text("Add a description to develop this idea.").foregroundStyle(.secondary) }
                TagPills(tags: model.tags(for: current.tagIDs))
            }
            if latest != nil {
                Section("Priority & potential") {
                    if current.planning?.needsSetup == true { Label("Set priority & score", systemImage: "sparkles").foregroundStyle(.orange) }
                    if let planning = current.planning {
                        LabeledContent("Priority", value: "\(planning.priority)/5")
                        if let potential = planning.potential { LabeledContent("Potential", value: potential.title) }
                        if let score = planning.score(preferences: current.scoringPreferences ?? .init()).projectScore { LabeledContent("Your score", value: "\(Int(score.rounded()))/100") }
                    }
                    Button("Zen mode", systemImage: "viewfinder") { zenScoring = true }.accessibilityIdentifier("idea.zen.open")
                    Button("Priority & scoring", systemImage: "slider.horizontal.3") { scoring = true }.accessibilityIdentifier("idea.planning.edit")
                }
            }
            MobileDownloadSection(entry: model.snapshot.entries.first { $0.path == current.path }
                ?? MobileWorkspaceEntry(path: current.path, parentPath: "Ideas", name: current.title, isDirectory: false, revision: current.revision, modifiedAt: current.modifiedAt))
            MobileIdeaPreviewsSection(idea: current)
            if let attachments = current.attachments, !attachments.isEmpty {
                Section {
                    ForEach(attachments) { file in
                        NavigationLink(value: MobileWorkspaceEntry(path: file.path, parentPath: current.path, name: file.name, isDirectory: file.isDirectory, revision: 0)) {
                            Label(file.name, systemImage: file.isDirectory ? "folder" : "doc")
                        }
                    }
                } header: { Text("Media & files") } footer: { Text("Original files are on your Mac.") }
            }
            if latest != nil {
                if model.snapshot.entries.first(where: { $0.path == current.path })?.isDirectory == true {
                    Section("Promote the complete folder") {
                        ForEach(IdeaPromotionKind.allCases) { kind in Button("Promote to " + kind.title + "…") { promotion = kind }.disabled(current.serviceID == nil).accessibilityIdentifier("idea.promote." + kind.rawValue) }
                    }
                }
                Section("Organize") {
                    if model.snapshot.entries.first(where: { $0.path == current.path })?.isDirectory != true {
                    Button("Create feature plan", systemImage: "sparkles") { creatingFeature = true }
                    Button("Create project plan", systemImage: "folder.badge.plus") { creatingProject = true }
                    }
                    Button("Delete idea", systemImage: "trash", role: .destructive) { confirmingDelete = true }
                        .accessibilityIdentifier("idea-delete")
                }
            }
        }
        .navigationTitle("Idea")
        .confirmationDialog("Delete idea “\(current.title)”?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Move to Trash", role: .destructive) { if model.trash(current) { dismiss() } }
            Button("Cancel", role: .cancel) {}
        } message: { Text("The idea and any files inside its folder move to your Mac’s recoverable Trash when online. Linked Notion pages stay in Notion.") }
        .refreshable { await model.refresh() }
        .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Edit") { editing = true }.disabled(latest == nil || (current.description == nil && current.serviceID == nil)) } }
        .fullScreenCover(isPresented: $zenScoring) { MobileIdeaPlanningEditor(idea: current, zenMode: true) }
        .sheet(isPresented: $scoring) { MobileIdeaPlanningEditor(idea: current) }
        .confirmationDialog("Promote “\(current.title)”?", isPresented: Binding(get: { promotion != nil }, set: { if !$0 { promotion = nil } }), titleVisibility: .visible) {
            if let kind = promotion {
                Button("Move entire folder to " + kind.area) {
                    var original = current; original.previews = nil
                    if model.savePlanning(MobilePlanningEdit(operation: .promoteIdea, title: current.title, originalIdea: original, ideaPromotion: kind)) { promotion = nil }
                }
            }
        } message: {
            if let kind = promotion { Text("Move \(current.path) to \(kind.area)/\(URL(fileURLWithPath: current.path).lastPathComponent), including all attachments. The Mac checks it is unchanged and refuses an existing destination. Remote Notion pages stay unchanged.") }
        }
        .sheet(isPresented: $editing) { MobileIdeaEditor(idea: current) }
        .sheet(isPresented: $creatingFeature) { MobileWorkEditor(kind: .feature, title: current.title, description: current.description ?? "", tagIDs: current.tagIDs) }
        .sheet(isPresented: $creatingProject) { MobileIdeaEditor(idea: current, operation: .createProject) }
    }
}

struct MobileIdeaEditor: View {
    @Environment(MobileWorkspaceModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let idea: MobileIdea?
    let operation: MobilePlanningEdit.Operation
    @State private var title: String
    @State private var description: String
    @State private var tags: Set<String>
    @State private var error: String?
    init(idea: MobileIdea? = nil, operation: MobilePlanningEdit.Operation? = nil) {
        self.idea = idea; self.operation = operation ?? (idea == nil ? .createIdea : .saveIdea)
        _title = State(initialValue: idea?.title ?? "")
        _description = State(initialValue: idea?.description ?? "")
        _tags = State(initialValue: idea?.tagIDs ?? [])
    }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Title", text: $title).accessibilityIdentifier("planning-title")
                }
                Section("Description") {
                    TextEditor(text: $description).frame(minHeight: 180).accessibilityIdentifier("planning-description")
                }
                MobileDraftTagsSection(selected: $tags)
                if let error { Text(error).foregroundStyle(.red) }
                Section {
                    Text(operation == .createProject ? "Creates a new project and a plan on your Mac. Your original idea and its files stay available." : "Saved on this phone first. Your Mac applies the change when it is online.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle(operation == .createProject ? "New project" : (idea == nil ? "New idea" : "Edit idea"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let edit = MobilePlanningEdit(operation: operation, title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                            description: description, originalIdea: idea, tagIDs: tags)
                        if model.savePlanning(edit) { dismiss() } else { error = model.saveMessage }
                    }.disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                ToolbarItem(placement: .keyboard) { Button("Done") { UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil) } }
            }
        }
    }
}

private struct MobileDraftTagsSection: View {
    @Environment(MobileWorkspaceModel.self) private var model
    @Binding var selected: Set<String>
    var body: some View {
        if !model.snapshot.tags.isEmpty {
            Section {
                DisclosureGroup("Tags\(selected.isEmpty ? "" : " (\(selected.count))")") {
                    ForEach(model.snapshot.tags) { tag in
                        Button { if selected.contains(tag.id) { selected.remove(tag.id) } else { selected.insert(tag.id) } } label: {
                            Label(tag.name, systemImage: selected.contains(tag.id) ? "checkmark.circle.fill" : "circle")
                        }
                    }
                }
            }
        }
    }
}
