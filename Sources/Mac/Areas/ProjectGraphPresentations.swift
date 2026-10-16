import SwiftUI
import AppKit
import BetterWorkspaceCore

enum SelectedProjectPresentation: String, CaseIterable, Identifiable {
    case workspace, portfolio, table, cards, decide
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

struct GraphSelectedProjectView: View {
    @Environment(AppModel.self) private var model
    let project: ProjectGraphRecord
    @State private var section = ProjectSection.tasks
    @State private var editing: ProjectGraphRecord?
    var body: some View {
        let current = model.graphRecords.first { $0.id == project.id } ?? project
        VStack(spacing: 0) {
            HStack {
                Button { model.openGraphProjectID = nil } label: { Label("All Projects", systemImage: "chevron.left") }.buttonStyle(.borderless)
                Text(current.title).font(.headline).lineLimit(1)
                Label(current.pageID == nil ? "Local draft" : "Notion-only", systemImage: "cloud").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Menu {
                    Button("Edit project") { editing = current }
                    Button("Link a local folder…") { link(current) }
                    if let id = current.pageID, let url = URL(string: "https://notion.so/" + id.replacingOccurrences(of: "-", with: "")) { Link("Open in Notion", destination: url) }
                } label: { Image(systemName: "ellipsis") }
                ProjectZenButton(project: current)
            }.padding(14)
            ProjectSectionPicker(selection: $section, sections: ProjectSection.allCases.filter { $0 != .insights })
            Divider()
            Group {
                switch section {
                case .tasks, .insights: ProjectPlanView(local: nil, graph: current)
                case .details: ProjectGraphRecordEditor(record: current, embedded: true)
                case .media: ProjectMediaGallery(project: current)
                case .portfolio: ProjectPortfolioPresentation(project: current)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }.sheet(item: $editing) { ProjectGraphRecordEditor(record: $0) }
        .task(id: project.id) { section = .tasks }
    }
    private func link(_ project: ProjectGraphRecord) {
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = false
        panel.message = "Choose this project's existing folder in your Workspace."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let item = model.projects().first(where: { $0.url.canonicalPath == url.canonicalPath }), let local = model.projectRecord(for: item) else { model.lastError = "Choose a project folder already visible in this Workspace."; return }
        if let existing = model.graphProject(for: item), existing.id != project.id { model.lastError = "This folder is already linked to another Notion project."; return }
        do {
            if let pageID = project.pageID { try model.projectStore.setExplicitNotionPageID(pageID, for: local.id) }
            var linked = project; linked.localProjectID = local.id; linked.localPath = url.canonicalPath
            model.saveGraphRecord(linked); model.openGraphProjectID = nil; model.openProjectWorkspace(for: item)
        } catch { model.lastError = error.localizedDescription }
    }
}

struct ProjectGraphContent: View {
    @Environment(AppModel.self) private var model
    let project: ProjectGraphRecord
    let presentation: SelectedProjectPresentation
    @State private var query = ""
    @State private var kind = "all"
    @State private var group = "kind"
    @State private var status = "all"
    @State private var filters: [String: String] = [:]
    @State private var columns = ["name", "kind", "status", "phase", "tags"]
    @State private var editing: ProjectGraphRecord?
    @State private var selection: String?
    @State private var sort = "name"
    @State private var ascending = true
    @State private var collapsed: Set<String> = []
    init(project: ProjectGraphRecord, presentation: SelectedProjectPresentation) {
        self.project = project; self.presentation = presentation
        let state = TestIsolation.defaults.dictionary(forKey: "projectQuery.\(project.id)") as? [String: String] ?? [:]
        _query = State(initialValue: state["query"] ?? ""); _kind = State(initialValue: state["kind"] ?? "all")
        _group = State(initialValue: state["group"] ?? "kind"); _status = State(initialValue: state["status"] ?? "all")
        _sort = State(initialValue: state["sort"] ?? "name"); _ascending = State(initialValue: state["ascending"] != "false")
        _filters = State(initialValue: TestIsolation.defaults.dictionary(forKey: "projectRelatedFilters.\(project.id)") as? [String: String] ?? [:])
        _columns = State(initialValue: TestIsolation.defaults.stringArray(forKey: "projectRelatedColumns.\(project.id)") ?? ["name", "kind", "status", "phase", "tags"])
        _collapsed = State(initialValue: Set(TestIsolation.defaults.stringArray(forKey: "projectGroups.\(project.id)") ?? []))
    }
    private func saveView() {
        TestIsolation.defaults.set(["query": query, "kind": kind, "group": group, "status": status, "sort": sort, "ascending": String(ascending)], forKey: "projectQuery.\(project.id)")
        TestIsolation.defaults.set(Array(collapsed), forKey: "projectGroups.\(project.id)")
        TestIsolation.defaults.set(filters, forKey: "projectRelatedFilters.\(project.id)")
        TestIsolation.defaults.set(columns, forKey: "projectRelatedColumns.\(project.id)")
    }
    private var records: [ProjectGraphRecord] {
        model.graphRelated(to: project).filter { record in
            (kind == "all" || record.kind.rawValue == kind) && (query.isEmpty || record.title.localizedCaseInsensitiveContains(query)) &&
            (status == "all" || value(record, "Status") == status) && filters.allSatisfy { key, choice in value(record, key).components(separatedBy: ", ").contains(choice) }
        }.sorted { lhs, rhs in
            let a = sort == "name" ? lhs.title : value(lhs, sort == "status" ? "Status" : sort == "phase" ? "Phase" : sort)
            let b = sort == "name" ? rhs.title : value(rhs, sort == "status" ? "Status" : sort == "phase" ? "Phase" : sort)
            return ascending ? a.localizedStandardCompare(b) == .orderedAscending : a.localizedStandardCompare(b) == .orderedDescending
        }
    }
    private func filterOptions(_ key: String) -> [String] {
        let related = model.graphRelated(to: project)
        let values = related.flatMap { value($0, key).components(separatedBy: ", ") }
        return Set(values.filter { !$0.isEmpty }).sorted()
    }
    private func value(_ record: ProjectGraphRecord, _ name: String) -> String { if name == "kind" { return record.kind.title }; return model.graphSource(for: record).map { record.value(name.hasPrefix("notion:") ? String(name.dropFirst(7)) : name, source: $0).display } ?? "" }
    private var groups: [(String, [ProjectGraphRecord])] {
        var map: [String: [ProjectGraphRecord]] = [:]
        for record in records {
            let keys = group == "none" ? ["Related records"] : value(record, group).components(separatedBy: ", ").filter { !$0.isEmpty }
            for key in keys.isEmpty ? ["Uncategorized"] : keys { map[key, default: []].append(record) }
        }
        return map.keys.sorted().map { ($0, map[$0]!) }
    }
    var body: some View {
        Group {
            if presentation == .portfolio { ProjectPortfolioPresentation(project: project) }
            else if presentation == .workspace { ProjectPlanView(local: nil, graph: project) }
            else {
                VStack(spacing: 0) {
                    HStack {
                        InlineSearchField(text: $query, prompt: "Search related records")
                        Menu {
                            Picker("Record type", selection: $kind) { Text("All types").tag("all"); ForEach(ProjectEntityKind.allCases.filter { $0 != .projects }) { Text($0.title).tag($0.rawValue) } }
                            Picker("Group", selection: $group) { Text("Type").tag("kind"); Text("Status").tag("Status"); Text("Phase").tag("Phase"); Text("Tags").tag("tags"); Text("Domain").tag("domain"); Text("Work mode").tag("Work Mode"); Text("Priority").tag("Priority"); Text("None").tag("none") }
                            Menu("Filters") {
                                ForEach(["domain", "Phase", "tags", "Work Mode", "Priority"], id: \.self) { key in
                                    Menu(key) {
                                        Button("All") { filters.removeValue(forKey: key) }
                                        ForEach(filterOptions(key), id: \.self) { option in Button(option) { filters[key] = option } }
                                    }
                                }
                            }
                            Menu("Sort") {
                                ForEach(["name", "kind", "Status", "Phase", "Priority"], id: \.self) { key in Button(key == "name" ? "Name" : key) { sort = key } }
                                Button(ascending ? "Descending" : "Ascending") { ascending.toggle() }
                            }
                            Menu("Columns") {
                                ForEach(["kind", "status", "phase", "tags"] + extraColumns, id: \.self) { key in
                                    Toggle(ProjectBrowserView.title(key), isOn: Binding(get: { columns.contains(key) }, set: { enabled in if enabled { columns.append(key) } else { columns.removeAll { $0 == key } } }))
                                }
                            }
                            Picker("Status", selection: $status) { Text("All statuses").tag("all"); ForEach(filterOptions("Status"), id: \.self) { Text($0).tag($0) } }
                        } label: { Label("View options", systemImage: "slider.horizontal.3") }
                        Spacer(); ProjectRecordCreateMenu(project: project)
                    }.padding(12)
                    if presentation == .table {
                        ProjectOutlineTable(groups: groups.map { name, records in (name, records.map { record in
                            ProjectBrowserRow(id: record.id, name: record.title, item: nil, graph: record,
                                values: tableValues(record), tags: [])
                        }) }, grouped: group != "none", columns: $columns, availableColumns: (["name", "kind", "status", "phase", "tags"] + extraColumns).map { ($0, ProjectBrowserView.title($0)) }, defaultColumns: ["name", "kind", "status", "phase", "tags"], widths: .constant([:]), collapsed: $collapsed, selection: $selection, sort: $sort, ascending: $ascending, open: { row in editing = row.graph }, action: { row, action in
                            if action == "notion", let id = row.graph?.pageID, let url = URL(string: "https://notion.so/" + id) { model.open(url) }
                            else { editing = row.graph }
                        })
                    } else { ScrollView {
                        LazyVStack(alignment: .leading, spacing: 18) {
                            if presentation == .decide { projectGaps }
                            ForEach(groups, id: \.0) { title, records in
                                DisclosureGroup(title, isExpanded: Binding(get: { !collapsed.contains(title) }, set: { expanded in if expanded { collapsed.remove(title) } else { collapsed.insert(title) } })) {
                                    if presentation == .cards {
                                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 210))], alignment: .leading) { ForEach(records) { record in row(record).padding(12).background(.quaternary, in: RoundedRectangle(cornerRadius: 8)) } }
                                    } else {
                                        ForEach(records.filter { presentation != .decide || !completed($0) }) { row($0); Divider() }
                                    }
                                }
                            }
                            if records.isEmpty { ContentUnavailableView("No matching records", systemImage: "rectangle.3.group", description: Text("Import related sources in Settings or add a record.")) }
                        }.padding(20)
                    }
                    }
                }
            }
        }.sheet(item: $editing) { ProjectGraphRecordEditor(record: $0) }
        .onChange(of: query) { _, _ in saveView() }.onChange(of: kind) { _, _ in saveView() }.onChange(of: group) { _, _ in saveView() }.onChange(of: status) { _, _ in saveView() }.onChange(of: sort) { _, _ in saveView() }.onChange(of: ascending) { _, _ in saveView() }.onChange(of: collapsed) { _, _ in saveView() }.onChange(of: columns) { _, _ in saveView() }.onChange(of: filters) { _, _ in saveView() }
    }
    private var extraColumns: [String] {
        let ids = Set(model.graphRelated(to: project).map(\.sourceID))
        return Array(Set(model.graphSources.filter { ids.contains($0.id) }.flatMap { $0.schema.object.keys }.map { "notion:" + $0 })).sorted()
    }
    private func tableValues(_ record: ProjectGraphRecord) -> [String: String] {
        var values = ["kind": record.kind.title, "status": value(record, "Status"), "phase": value(record, "Phase"), "tags": value(record, "tags")]
        guard let source = model.graphSource(for: record) else { return values }
        for key in columns where key.hasPrefix("notion:") {
            let name = String(key.dropFirst(7)), property = record.value(name, source: source)
            let type = property["type"].string ?? ""
            values[key] = type == "relation" ? "\(property["relation"].array.count) related" : type == "files" ? "\(property["files"].array.count) files" : property.display
        }
        return values
    }
    private var projectGaps: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Project details to complete").font(.headline)
            if let source = model.graphSource(for: project) {
                ForEach(["one liner", "summary", "domain", "Status", "Phase"].filter { project.value($0, source: source).display.isEmpty }, id: \.self) { field in
                    Button("Add \(field)") { editing = project }.buttonStyle(.borderless)
                }
            }
            Button("Review project details") { editing = project }.buttonStyle(.borderless)
        }
    }
    private func row(_ record: ProjectGraphRecord) -> some View {
        Button { editing = record } label: {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) { Text(record.title).font(.headline); Text(record.kind.title).font(.caption).foregroundStyle(.secondary) }
                Spacer(); Text([value(record, "Status"), value(record, "Phase"), value(record, "tags")].filter { !$0.isEmpty }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                Image(systemName: "pencil").font(.caption).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }.buttonStyle(.plain)
    }
    private func completed(_ record: ProjectGraphRecord) -> Bool { model.graphRecordIsCompleted(record) }
}

struct ProjectPortfolioPresentation: View {
    @Environment(AppModel.self) private var model
    let project: ProjectGraphRecord
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                let source = model.graphSource(for: project)
                Text(project.title).font(.largeTitle.weight(.semibold)).textSelection(.enabled)
                if let source {
                    let subtitle = project.value("subtitle", source: source).display.graphNonEmpty ?? project.value("one liner", source: source).display
                    if !subtitle.isEmpty { Text(subtitle).font(.title3).foregroundStyle(.secondary).textSelection(.enabled) }
                }
                let related = model.graphRelated(to: project)
                let media = model.graphMediaRelated(to: project)
                if !media.filter({ $0.kind == .resources }).isEmpty {
                    ViewThatFits {
                        HStack { resourceActions(media) }
                        VStack(alignment: .leading) { resourceActions(media) }
                    }
                }
                if media.contains(where: { $0.kind == .assets }) { ViewThatFits(in: .horizontal) { ProjectPrimaryMedia(project: project, role: "hero", height: 300).frame(minWidth: 640); ProjectPrimaryMedia(project: project, role: "portraitHero", height: 260) } }
                if let source {
                    let description = project.value("description", source: source).display.graphNonEmpty ?? project.value("summary", source: source).display
                    if !description.isEmpty { MarkdownView(text: description).frame(maxWidth: 780, alignment: .leading) }
                    let articles = project.value("articles", source: source).display.components(separatedBy: .whitespacesAndNewlines).compactMap(URL.init(string:)).filter { ["https", "http"].contains($0.scheme ?? "") }
                    if !articles.isEmpty { VStack(alignment: .leading, spacing: 8) { Text("Articles").font(.title2.weight(.semibold)); ForEach(articles, id: \.absoluteString) { url in Link(url.host ?? url.absoluteString, destination: url) } } }
                }
                if media.contains(where: { [.assets, .resources, .collections].contains($0.kind) }) { ProjectMediaGallery(project: project, editable: false).frame(height: 480) }
                ProjectNotionContentView(record: project)
                ForEach([ProjectEntityKind.posts, .notes, .workLogs, .versions], id: \.self) { kind in
                    let records = related.filter { $0.kind == kind }
                    if !records.isEmpty {
                        VStack(alignment: .leading, spacing: 10) { Text(kind.title).font(.title2.weight(.semibold)); ForEach(records) { record in
                            VStack(alignment: .leading, spacing: 4) { Text(record.title).font(.headline); if let source = model.graphSource(for: record) {
                                let detail = record.value("one liner", source: source).display
                                if !detail.isEmpty { Text(detail).foregroundStyle(.secondary) }
                                if kind == .workLogs { ForEach(["What Happened", "Problems", "Next Step"], id: \.self) { name in
                                    let text = record.value(name, source: source).display
                                    if !text.isEmpty { Text(name).font(.caption.weight(.semibold)); Text(text).font(.callout).foregroundStyle(.secondary).lineLimit(4) }
                                } }
                            } }
                        } }
                    }
                }
                if let source { Text(["domain", "Status", "Phase", "Type", "tags"].map { project.value($0, source: source).display }.filter { !$0.isEmpty }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary) }
            }.padding(24).frame(maxWidth: 1000, alignment: .leading).frame(maxWidth: .infinity)
        }
    }
    @ViewBuilder private func resourceActions(_ records: [ProjectGraphRecord]) -> some View {
        ForEach(records.filter { $0.kind == .resources }) { resource in
            if let source = model.graphSource(for: resource), let url = URL(string: resource.value("url", source: source).display), ["http", "https"].contains(url.scheme ?? "") {
                Link(resource.value("label", source: source).display.graphNonEmpty ?? resource.title, destination: url).buttonStyle(.bordered)
            }
        }
    }
}

// UI recommendation over the existing private graph; never materializes files.
extension AppModel {
    /// Work files by canonical path, for answering a bound graph record from its file.
    var workItemsByPath: [String: WorkItem] {
        Dictionary(workItems.map { ($0.url.canonicalPath, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// Done-ness of a planning record, from its work file when it has one.
    func graphRecordIsCompleted(_ record: ProjectGraphRecord, workByPath: [String: WorkItem]? = nil) -> Bool {
        guard let source = graphSource(for: record) else { return false }
        return ProjectGraphPlanning.isCompleted(record, source: source,
                                                localWork: ProjectGraphPlanning.boundWork(record, in: workByPath ?? workItemsByPath))
    }

    func projectGraphNextAction(for project: ProjectGraphRecord) -> ProjectGraphRecord? {
        // Until work files are read, a file's draft cannot be told from a Notion-only task.
        let candidates = graphRelated(to: project).filter { !isAwaitingWorkItems || $0.localPath == nil }
        return ProjectGraphPlanning.nextAction(among: candidates, allRecords: graphRecords,
                                        source: { self.graphSource(for: $0) }, workByPath: workItemsByPath)
    }
}
