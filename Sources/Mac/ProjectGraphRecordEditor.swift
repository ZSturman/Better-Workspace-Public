import SwiftUI
import TipKit
import BetterWorkspaceCore

struct ProjectRecordCreateMenu: View {
    @Environment(AppModel.self) private var model
    let project: ProjectGraphRecord
    var kinds: [ProjectEntityKind] = [.features, .milestones, .tasks, .resources, .collections, .notes, .ideas, .versions, .posts, .workLogs]
    @State private var draft: ProjectGraphRecord?
    var body: some View {
        Menu {
            ForEach(kinds.filter { kind in model.graphSources.contains { $0.kind == kind } }) { kind in
                Button("New \(kind.singular)") { draft = model.newGraphRecord(kind, in: project) }
            }
        } label: { Label("Add", systemImage: "plus") }
        .sheet(item: $draft) { ProjectGraphRecordEditor(record: $0) }
    }
}

/// Creates and edits one planning record.
///
/// It leads with what makes the record what it is — its name, what it is for, a few
/// essentials and the relationships that matter for its kind (`ProjectRecordProfile`)
/// — and keeps every other property, untouched, under More Options. Save keeps the
/// change on this Mac; nothing reaches Notion until it is reviewed in Send to Notion.
struct ProjectGraphRecordEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let record: ProjectGraphRecord
    var embedded = false
    @State private var draft: ProjectGraphRecord
    @State private var savedLocal: [String: ProjectJSON]
    @State private var textEdits: [String: String] = [:]
    @State private var error: String?
    @State private var confirmArchive = false
    @State private var showMore = false
    @State private var moreQuery = ""
    /// Records made from an Add button. Written only when this record is saved, so
    /// Cancel leaves nothing behind.
    @State private var newRecords: [ProjectGraphRecord] = []

    init(record: ProjectGraphRecord, embedded: Bool = false) {
        self.record = record; self.embedded = embedded
        _draft = State(initialValue: record); _savedLocal = State(initialValue: record.local)
    }

    private var source: ProjectGraphSource? { model.graphSource(for: record) }
    private var profile: ProjectRecordProfile? {
        source.map { ProjectRecordProfile.make(kind: record.kind, source: $0, sources: model.graphSources) }
    }
    /// Not yet saved even locally. A draft that is saved but not yet sent is not new.
    private var isNew: Bool { !model.graphRecords.contains { $0.id == record.id } }
    private var isDirty: Bool { draft.local != savedLocal || !newRecords.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.base) {
                    if !embedded { header }
                    if let source, let profile { content(source, profile) }
                    if let error { Label(error, systemImage: "exclamationmark.triangle.fill").font(.callout).foregroundStyle(.orange) }
                }
                .padding(embedded ? Theme.Space.loose : 20)
                .frame(maxWidth: embedded ? 760 : .infinity, alignment: .leading)
            }
            Divider()
            footer.padding(.horizontal, 20).padding(.vertical, 12)
        }
        .frame(width: embedded ? nil : 560)
        .frame(maxWidth: embedded ? .infinity : nil, maxHeight: embedded ? .infinity : nil, alignment: .topLeading)
        .frame(minHeight: embedded ? nil : 300, idealHeight: embedded ? nil : 520, maxHeight: embedded ? nil : 640)
        .confirmationDialog("Archive “\(record.title)” in Notion?", isPresented: $confirmArchive) {
            Button("Archive When I Send", role: .destructive) { draft.archiveRequested = true; save() }
        } message: { Text("It is archived only when you review and approve it in Send to Notion. Local files are kept.") }
    }

    // MARK: Layout

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(isNew ? "New \(record.kind.singular)" : record.kind.singular)
                .font(.headline).foregroundStyle(.secondary)
            Spacer()
            if let source, let status = computedStatus(source) {
                Text(status).font(.caption.weight(.medium)).padding(.horizontal, 8).padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())
                    .help("Notion works this out from the record's tasks and dates")
            }
        }
    }

    @ViewBuilder private func content(_ source: ProjectGraphSource, _ profile: ProjectRecordProfile) -> some View {
        if let title = profile.title {
            TextField("\(record.kind.singular) name", text: textBinding(title, type: "title", source: source), axis: .vertical)
                .font(.system(size: 20, weight: .semibold)).textFieldStyle(.plain).lineLimit(1...3)
                .accessibilityIdentifier("projects.property." + (source.property(named: title)?.id ?? title))
                .accessibilityLabel("Name")
        }
        if let description = profile.description {
            TextField(description.prompt ?? description.label, text: textBinding(description.name, type: "rich_text", source: source), axis: .vertical)
                .textFieldStyle(.plain).lineLimit(2...8).foregroundStyle(.primary)
                .accessibilityIdentifier("projects.property." + (source.property(named: description.name)?.id ?? description.name))
                .accessibilityLabel(description.label)
                .help(description.name == description.label ? "" : "Saved to Notion’s “\(description.name)” property")
        }
        if !profile.essentials.isEmpty {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: Theme.Space.base, verticalSpacing: 8) {
                ForEach(profile.essentials) { field in
                    GridRow {
                        Text(field.label).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                        fieldControl(field.name, label: field.label, prompt: field.prompt, source: source)
                    }
                }
            }
            .padding(.top, 4)
        }
        ForEach(profile.relations) { relation in
            RelationEditor(title: relation.noun, values: relationIDs(relation.name, source: source),
                           candidates: { model.relationCandidates(target: relation.target, for: draft, excluding: newRecords) },
                           newRecords: newRecords,
                           create: { title in addNew(relation, title: title, source: source) },
                           set: { setRelation(relation.name, ids: $0, source: source) })
        }
        moreOptions(source, profile)
    }

    private func moreOptions(_ source: ProjectGraphSource, _ profile: ProjectRecordProfile) -> some View {
        DisclosureGroup(isExpanded: $showMore) {
            VStack(alignment: .leading, spacing: 10) {
                if profile.advanced.count > 8 {
                    InlineSearchField(text: $moreQuery, prompt: "Find an option").accessibilityIdentifier("projects.editor.findOption")
                }
                let names = profile.advanced.filter { moreQuery.isEmpty || $0.localizedCaseInsensitiveContains(moreQuery) || profile.label(for: $0).localizedCaseInsensitiveContains(moreQuery) }
                ForEach(names, id: \.self) { name in advancedRow(name, profile: profile, source: source) }
                if names.isEmpty { Text("No option matches “\(moreQuery)”.").font(.callout).foregroundStyle(.secondary) }
                if !profile.computed.isEmpty {
                    DisclosureGroup("Calculated by Notion") {
                        ForEach(profile.computed, id: \.self) { name in
                            LabeledContent(profile.label(for: name), value: draft.value(name, source: source).display.graphNonEmpty ?? "—")
                        }
                    }
                }
                if record.pageID != nil {
                    DisclosureGroup("Page content") { ProjectNotionContentView(record: record) }
                }
            }
            .padding(.top, 6)
        } label: {
            Text("More Options").font(.callout.weight(.medium))
        }
        .accessibilityIdentifier("projects.editor.moreOptions")
        .padding(.top, 4)
    }

    @ViewBuilder private func advancedRow(_ name: String, profile: ProjectRecordProfile, source: ProjectGraphSource) -> some View {
        let label = profile.label(for: name)
        if source.property(named: name)?.definition["type"].string == "relation" {
            let target = source.property(named: name)?.definition["relation"]["data_source_id"].string
            if let kind = model.graphSources.first(where: { $0.id == target })?.kind {
                RelationEditor(title: label, values: relationIDs(name, source: source),
                               candidates: { model.relationCandidates(target: kind, for: draft, excluding: newRecords) },
                               newRecords: newRecords, compact: true,
                               create: nil, set: { setRelation(name, ids: $0, source: source) })
            } else {
                LabeledContent(label, value: "\(relationIDs(name, source: source).count) linked")
            }
        } else {
            LabeledContent(label) { fieldControl(name, label: label, prompt: nil, source: source) }
        }
    }

    private var footer: some View {
        HStack {
            if record.pageID != nil {
                Menu {
                    Button("Archive in Notion…", role: .destructive) { confirmArchive = true }
                } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help("More actions")
            }
            Spacer()
            if embedded {
                Button("Revert") { revert() }.disabled(!isDirty)
            } else {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Button("Save") { save() }
                .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                .disabled(embedded && !isDirty)
                .accessibilityIdentifier("projects.editor.save")
        }
    }

    // MARK: Field controls

    @ViewBuilder private func fieldControl(_ name: String, label: String, prompt: String?, source: ProjectGraphSource) -> some View {
        let schema = source.property(named: name)?.definition ?? .null
        let type = schema["type"].string ?? ""
        let id = "projects.property." + (schema["id"].string ?? name)
        switch type {
        case "title", "rich_text", "url":
            TextField(prompt ?? label, text: textBinding(name, type: type, source: source), axis: .vertical)
                .lineLimit(1...4).accessibilityIdentifier(id)
        case "number":
            TextField(prompt ?? label, text: textBinding(name, type: type, source: source)).accessibilityIdentifier(id)
        case "date":
            dateControl(name, source: source).accessibilityIdentifier(id)
        case "checkbox":
            Toggle(label, isOn: Binding(get: { draft.value(name, source: source)[type].bool },
                                        set: { draft.set(name, value: .bool($0), source: source) })).labelsHidden()
                .accessibilityIdentifier(id)
        case "select", "status":
            Picker(label, selection: Binding(get: { draft.value(name, source: source)[type]["name"].string ?? "" },
                                             set: { draft.set(name, value: $0.isEmpty ? .null : ProjectJSON(["name": $0]), source: source) })) {
                Text("None").tag("")
                ForEach(options(schema, type), id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden().fixedSize().accessibilityIdentifier(id)
        case "multi_select":
            let selected = draft.value(name, source: source)[type].array.compactMap { $0["name"].string }
            Menu {
                ForEach(options(schema, type), id: \.self) { option in
                    Toggle(option, isOn: Binding(get: { selected.contains(option) }, set: { enabled in
                        var values = draft.value(name, source: source)[type].array.filter { $0["name"].string != option }
                        if enabled { values.append(ProjectJSON(["name": option])) }
                        draft.set(name, value: .array(values), source: source)
                    }))
                }
            } label: {
                Text(selected.isEmpty ? "None" : selected.joined(separator: ", ")).lineLimit(1)
                    .foregroundStyle(selected.isEmpty ? .secondary : .primary)
            }
            .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier(id)
        case "files":
            Text("\(draft.value(name, source: source)[type].array.count) files").foregroundStyle(.secondary)
        default:
            Text(draft.value(name, source: source).display.graphNonEmpty ?? "—").foregroundStyle(.secondary)
        }
    }

    private func options(_ schema: ProjectJSON, _ type: String) -> [String] {
        schema[type]["options"].array.compactMap { $0["name"].string }
    }

    /// A date is optional: Add sets one, the clear button removes it. A range's end and
    /// time zone are kept as they were.
    @ViewBuilder private func dateControl(_ name: String, source: ProjectGraphSource) -> some View {
        let value = draft.value(name, source: source)["date"]
        if let start = value["start"].string, let date = DateFormatter.recordDay.date(from: String(start.prefix(10))) ?? ProjectDates.parse(start) {
            HStack(spacing: 4) {
                DatePicker("", selection: Binding(get: { date }, set: { setDate(name, $0, source: source) }), displayedComponents: .date)
                    .labelsHidden().fixedSize()
                Button { draft.set(name, value: .null, source: source) } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless).foregroundStyle(.secondary).help("Remove date")
            }
        } else {
            Button("Add Date") { setDate(name, Date(), source: source) }.buttonStyle(.link)
        }
    }

    private func setDate(_ name: String, _ date: Date, source: ProjectGraphSource) {
        var value = draft.value(name, source: source)["date"].object
        value["start"] = .string(DateFormatter.recordDay.string(from: date))
        draft.set(name, value: .object(value), source: source)
    }

    private func textBinding(_ name: String, type: String, source: ProjectGraphSource) -> Binding<String> {
        Binding(get: { textEdits[name] ?? draft.value(name, source: source).display }, set: { text in
            textEdits[name] = text
            let value: ProjectJSON
            switch type {
            case "title", "rich_text": value = ProjectJSON(text.isEmpty ? [] : [["type": "text", "text": ["content": text]]])
            case "number":
                if text.trimmingCharacters(in: .whitespaces).isEmpty { value = .null }
                else { guard let number = Double(text), number.isFinite else { return }; value = .number(number) }
            default: value = text.isEmpty ? .null : .string(text)
            }
            draft.set(name, value: value, source: source)
        })
    }

    private func computedStatus(_ source: ProjectGraphSource) -> String? {
        guard let id = source.property(named: "status")?.id, !source.writable(id) else { return nil }
        return draft.value("status", source: source).display.graphNonEmpty
    }

    // MARK: Relationships

    private func relationIDs(_ name: String, source: ProjectGraphSource) -> [String] {
        draft.value(name, source: source)["relation"].array.compactMap { $0["id"].string }
    }

    private func setRelation(_ name: String, ids: [String], source: ProjectGraphSource) {
        var seen = Set<String>()
        let unique = ids.filter { seen.insert(ProjectGraph.normalizedID($0)).inserted }
        draft.set(name, value: ProjectJSON(unique.map { ["id": $0] }), source: source)
        newRecords.removeAll { new in !draft.local.values.contains { $0["relation"].array.contains { $0["id"].string == new.id } } }
    }

    /// A new record of the relation's kind, in the same project, linked to this one.
    private func addNew(_ relation: ProjectRecordProfile.Relation, title: String, source: ProjectGraphSource) {
        guard let targetSource = model.graphSources.first(where: { $0.kind == relation.target }) else { return }
        var child = ProjectGraphRecord(sourceID: targetSource.id, kind: relation.target)
        if let name = targetSource.schema.object.first(where: { $0.value["type"].string == "title" })?.key {
            child.set(name, value: ProjectServiceBridge.text(title), source: targetSource)
        }
        for project in model.projectIDs(of: draft) {
            for (name, schema) in targetSource.schema.object where schema["type"].string == "relation"
                && model.graphSources.first(where: { $0.id == schema["relation"]["data_source_id"].string })?.kind == .projects {
                child.set(name, value: ProjectJSON([["id": project]]), source: targetSource)
            }
        }
        newRecords.append(child)
        setRelation(relation.name, ids: relationIDs(relation.name, source: source) + [child.id], source: source)
    }

    // MARK: Save

    private func revert() {
        draft = model.graphRecords.first { $0.id == record.id } ?? record
        savedLocal = draft.local; textEdits = [:]; newRecords = []; error = nil
    }

    private func save() {
        guard let source else { return }
        let title = draft.title
        guard title != "Untitled", !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            error = "Give this \(record.kind.singular.lowercased()) a name."; return
        }
        if let current = model.graphRecords.first(where: { $0.id == record.id }), current.local != savedLocal {
            error = "This \(record.kind.singular.lowercased()) changed while it was open. Close it and open it again to see the latest version."; return
        }
        for (name, text) in textEdits where !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let type = source.property(named: name)?.definition["type"].string
            let label = profile?.label(for: name) ?? name
            if type == "number", Double(text)?.isFinite != true { error = "Enter a number for \(label), or clear it."; return }
            if type == "url", URL(string: text)?.scheme == nil { error = "Enter a complete link for \(label), starting with https://."; return }
        }
        for child in newRecords { model.saveGraphRecord(child) }
        draft.editedAt = Date()
        model.saveGraphRecord(draft)
        savedLocal = draft.local; newRecords = []
        if model.hasNotionToken { NotionSyncGuidance.savedLocally() }
        if !embedded { dismiss() }
    }
}

// MARK: - Relationship editing

struct RelationCandidate: Identifiable {
    let record: ProjectGraphRecord
    /// "Active · Hue Light Control"
    let detail: String
    let inScope: Bool
    let isDone: Bool
    var id: String { record.id }
    /// The id a relation stores: the Notion page once there is one.
    var linkID: String { record.pageID ?? record.id }
}

extension AppModel {
    /// The project page ids `record` belongs to, or its own id when it is a project.
    func projectIDs(of record: ProjectGraphRecord) -> [String] {
        if record.kind == .projects { return [record.pageID ?? record.id] }
        guard let source = graphSource(for: record),
              let projects = graphSources.first(where: { $0.kind == .projects }) else { return [] }
        return source.schema.object.keys.filter { source.property(named: $0)?.definition["relation"]["data_source_id"].string == projects.id }
            .flatMap { record.value($0, source: source)["relation"].array.compactMap { $0["id"].string } }
    }

    /// Records `record` could link to, those in its project first. A record in no
    /// project is in scope everywhere, since there is nothing to scope it to.
    func relationCandidates(target: ProjectEntityKind, for record: ProjectGraphRecord, excluding pending: [ProjectGraphRecord]) -> [RelationCandidate] {
        let scope = Set(projectIDs(of: record).map(ProjectGraph.normalizedID))
        let projectTitles = Dictionary(graphRecords.filter { $0.kind == .projects }.map { (ProjectGraph.normalizedID($0.pageID ?? $0.id), $0.title) },
                                       uniquingKeysWith: { first, _ in first })
        let workByPath = workItemsByPath
        return (graphRecords + pending).filter { candidate in
            candidate.kind == target && candidate.id != record.id && candidate.locallyDeleted != true
                && !candidate.remoteArchived && !candidate.archiveRequested && candidate.acknowledgedArchived != true
        }
        .map { candidate in
            let projects = Set(projectIDs(of: candidate).map(ProjectGraph.normalizedID))
            let done = graphRecordIsCompleted(candidate, workByPath: workByPath)
            let status = graphSource(for: candidate).map { candidate.value("Status", source: $0).display } ?? ""
            let inScope = scope.isEmpty || projects.isEmpty || !scope.isDisjoint(with: projects)
            let projectName = inScope ? nil : projects.compactMap { projectTitles[$0] }.first
            let detail = [done ? "Done" : status.graphNonEmpty, projectName].compactMap { $0 }.joined(separator: " · ")
            return RelationCandidate(record: candidate, detail: detail, inScope: inScope, isDone: done)
        }
        .sorted { lhs, rhs in
            if lhs.isDone != rhs.isDone { return !lhs.isDone }
            return lhs.record.title.localizedStandardCompare(rhs.record.title) == .orderedAscending
        }
    }
}

/// Linked records of one relationship, with Add (create new or link existing) and Remove.
private struct RelationEditor: View {
    @Environment(AppModel.self) private var model
    let title: String
    let values: [String]
    let candidates: () -> [RelationCandidate]
    let newRecords: [ProjectGraphRecord]
    var compact = false
    /// nil when this relationship only links existing records.
    let create: ((String) -> Void)?
    let set: ([String]) -> Void
    @State private var picking = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(compact ? title : title + "s").font(compact ? .body : .headline).foregroundStyle(compact ? .secondary : .primary)
                Spacer()
                Button { picking = true } label: { Label("Add \(title)", systemImage: "plus") }
                    .buttonStyle(.borderless).labelStyle(compact ? AnyLabelStyle(.iconOnly) : AnyLabelStyle(.titleAndIcon))
                    .help(create == nil ? "Link an existing \(title.lowercased())" : "Create a \(title.lowercased()) or link an existing one")
                    .accessibilityIdentifier("projects.editor.add.\(title)")
                    .popover(isPresented: $picking, arrowEdge: .trailing) {
                        RelationPicker(noun: title, linked: Set(values.map(ProjectGraph.normalizedID)), candidates: candidates(),
                                       create: create.map { create in { create($0); picking = false } },
                                       toggle: toggle)
                    }
            }
            ForEach(values, id: \.self) { id in
                HStack(spacing: 6) {
                    Text(name(of: id)).lineLimit(1)
                    if newRecords.contains(where: { $0.id == id }) { Text("New").font(.caption2.weight(.medium)).foregroundStyle(.tint) }
                    Spacer()
                    Button { set(values.filter { $0 != id }) } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless).foregroundStyle(.secondary).help("Remove link")
                        .accessibilityLabel("Remove \(name(of: id))")
                }
                .padding(.leading, compact ? 0 : 2)
            }
        }
        .padding(.top, compact ? 0 : 6)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("projects.editor.relation.\(title)")
    }

    private func name(of id: String) -> String {
        let key = ProjectGraph.normalizedID(id)
        return (newRecords + model.graphRecords).first { ProjectGraph.normalizedID($0.pageID ?? $0.id) == key || ProjectGraph.normalizedID($0.id) == key }?.title ?? "Unavailable record"
    }

    private func toggle(_ candidate: RelationCandidate) {
        let key = ProjectGraph.normalizedID(candidate.linkID)
        if values.contains(where: { ProjectGraph.normalizedID($0) == key }) { set(values.filter { ProjectGraph.normalizedID($0) != key }) }
        else { set(values + [candidate.linkID]) }
    }
}

private struct AnyLabelStyle: LabelStyle {
    private let make: (Configuration) -> AnyView
    init<S: LabelStyle>(_ style: S) { make = { AnyView(style.makeBody(configuration: $0)) } }
    func makeBody(configuration: Configuration) -> some View { make(configuration) }
}

/// Create a new record, or search this project's existing ones. Other projects' records
/// are an explicit choice, not the default list.
private struct RelationPicker: View {
    let noun: String
    let linked: Set<String>
    let candidates: [RelationCandidate]
    let create: ((String) -> Void)?
    let toggle: (RelationCandidate) -> Void
    @State private var creating: Bool
    @State private var name = ""
    @State private var query = ""
    @State private var everywhere = false
    @FocusState private var focused: Bool

    init(noun: String, linked: Set<String>, candidates: [RelationCandidate], create: ((String) -> Void)?, toggle: @escaping (RelationCandidate) -> Void) {
        self.noun = noun; self.linked = linked; self.candidates = candidates; self.create = create; self.toggle = toggle
        // "Add Task" usually means a new task; milestones and features are usually shared,
        // so linking comes first for them when there is something to link.
        let linkFirst = noun != "Task" && candidates.contains { $0.inScope && !$0.isDone }
        _creating = State(initialValue: create != nil && !linkFirst)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if create != nil {
                Picker("", selection: $creating) {
                    Text("New \(noun)").tag(true)
                    Text("Existing").tag(false)
                }
                .pickerStyle(.segmented).labelsHidden()
                .accessibilityIdentifier("projects.relationPicker.mode")
            }
            if creating, let create {
                TextField("\(noun) name", text: $name).textFieldStyle(.roundedBorder).focused($focused)
                    .onSubmit { submit(create) }
                    .accessibilityIdentifier("projects.relationPicker.name")
                HStack {
                    Spacer()
                    Button("Add") { submit(create) }.keyboardShortcut(.defaultAction)
                        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            } else {
                existing
            }
        }
        .padding(14).frame(width: 340)
        .onAppear { focused = true }
    }

    private var existing: some View {
        let visible = candidates.filter { (everywhere || $0.inScope || isLinked($0)) && (query.isEmpty || $0.record.title.localizedCaseInsensitiveContains(query)) }
        let hidden = candidates.filter { !$0.inScope }.count
        return VStack(alignment: .leading, spacing: 8) {
            InlineSearchField(text: $query, prompt: "Search \(noun.lowercased())s").focused($focused)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(visible.prefix(200)) { candidate in
                        Button { toggle(candidate) } label: {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Image(systemName: isLinked(candidate) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(isLinked(candidate) ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(candidate.record.title).lineLimit(2).foregroundStyle(candidate.isDone ? .secondary : .primary)
                                    if !candidate.detail.isEmpty { Text(candidate.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.vertical, 5).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("projects.relationPicker.candidate.\(candidate.record.title)")
                    }
                    if visible.isEmpty {
                        Text(query.isEmpty ? "No \(noun.lowercased())s in this project yet." : "No \(noun.lowercased()) matches “\(query)”.")
                            .font(.callout).foregroundStyle(.secondary).padding(.vertical, 8)
                    }
                }
            }
            .frame(minHeight: 60, maxHeight: 260)
            if hidden > 0 {
                Toggle("Include other projects (\(hidden))", isOn: $everywhere).toggleStyle(.checkbox).font(.caption)
                    .help("Link a \(noun.lowercased()) that belongs to a different project")
            }
        }
    }

    private func isLinked(_ candidate: RelationCandidate) -> Bool { linked.contains(ProjectGraph.normalizedID(candidate.linkID)) }

    private func submit(_ create: (String) -> Void) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        create(trimmed)
    }
}

// MARK: - Guidance

/// Saving keeps changes on this Mac. Once someone has saved something that could go to
/// Notion, say once where Send lives; never before, never again.
enum NotionSyncGuidance {
    static let savedLocalChange = Tips.Event(id: "notion.saved-local-change")
    static func savedLocally() { savedLocalChange.sendDonation() }
}

struct SendToNotionTip: Tip {
    var title: Text { Text("Send to Notion when you’re ready") }
    var message: Text? { Text("Saved changes stay on this Mac. Review and send them from here.") }
    var image: Image? { Image(systemName: "arrow.up.circle") }
    var rules: [Rule] { #Rule(NotionSyncGuidance.savedLocalChange) { $0.donations.count >= 1 } }
    var options: [Option] { [MaxDisplayCount(1)] }
}

extension String { var graphNonEmpty: String? { isEmpty ? nil : self } }

extension DateFormatter {
    static let recordDay: DateFormatter = {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"; return formatter
    }()
}
