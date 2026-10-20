import SwiftUI
import BetterWorkspaceCore

/// Projects: 383 working directories, 73 GB, 61 git repos — but 174 of them are
/// prose, not code.
///
/// With that many comparable rows, density wins: a sortable table whose columns are
/// exactly the discriminators the survey turned up — what kind of project it is,
/// whether it's a repo, and when it genuinely last changed (not the polluted directory
/// mtime). Recursive size is deliberately opt-in per row, because the area is 73 GB.
///
/// Consolidation added ten more possible columns — the project score, how much of it
/// has been answered, the Notion association, and the seven value groups. None of them
/// is on by default. The table you get is the table that was here before, and the rest
/// lives behind the Columns menu.
struct ProjectsView: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""
    @State private var kindFilter: ProjectKind?
    @State private var presentation: ProjectPresentation
    @State private var details: [String: ItemDetail] = [:]
    @State private var sortOrder: [KeyPathComparator<ProjectRow>]
    @State private var visibleColumns = ProjectColumnPreferences.load()
    @State private var ratingTarget: ProjectRecord?
    @State private var showOnlyRated: Bool
    @State private var domainFilter: String?
    @State private var statusFilter: String?
    @State private var phaseFilter: String?
    @State private var priorityFilter: ProjectPriorityFilter
    @State private var portfolioGroup: ProjectPortfolioGroup
    @State private var portfolioSort: ProjectPortfolioSort
    @State private var portfolioSortAscending: Bool
    @State private var showingMetadataImport = false
    @State private var preparingNotionProject = false
    @State private var notionProjectError: String?
    @State private var showingNotionSettings = false

    init() {
        let preferences = ProjectPortfolioPreferences.load()
        _presentation = State(initialValue: preferences.presentation)
        _showOnlyRated = State(initialValue: preferences.onlyRated)
        _domainFilter = State(initialValue: preferences.domain)
        _statusFilter = State(initialValue: preferences.status)
        _phaseFilter = State(initialValue: preferences.phase)
        _priorityFilter = State(initialValue: preferences.priority)
        _portfolioGroup = State(initialValue: preferences.group)
        _portfolioSort = State(initialValue: preferences.sort)
        _portfolioSortAscending = State(initialValue: preferences.sortAscending)
        _sortOrder = State(initialValue: [Self.comparator(for: preferences.sort, ascending: preferences.sortAscending)])
    }

    struct ProjectRow: Identifiable {
        let id: String
        let item: WorkspaceItem
        let name: String
        let kind: ProjectKind
        let isGit: Bool
        let branch: String
        let modified: Date
        let children: Int
        let record: ProjectRecord?
        let score: ProjectScore?
        let measurements: ProjectMeasurements?
        let metadata: ProjectMetadata
        let nextAction: WorkItem?

        var projectScore: RankedValue { RankedValue(score?.projectScore) }
        var coverage: RankedValue { RankedValue(score.map { $0.coverage * 100 }) }
        var domain: String { metadata.domain ?? "" }
        var status: String { metadata.status ?? "" }
        var portfolioPriority: RankedValue { RankedValue(metadata.portfolioPriority.map(Double.init)) }
        var notionSort: Int { record?.hasNotionLink == true ? 1 : 0 }
        var answeredCount: Int { score?.answeredCount ?? 0 }

        var ratedLabel: String {
            answeredCount == 0 ? "—" : "\(answeredCount)/\(MetricDefinition.all.count)"
        }

        func groupScore(_ column: ProjectColumn) -> RankedValue {
            guard let score, let group = MetricGroup.find(id: column.rawValue) else { return RankedValue(nil) }
            return RankedValue(score.groupScore(for: group))
        }

        /// Every optional column's value behind one accessor, so a single
        /// `TableColumnForEach` can render them all *and* sort each one correctly:
        /// `\ProjectRow.[column]` is a real key path, which a generated column
        /// otherwise cannot have.
        subscript(column: ProjectColumn) -> RankedValue {
            switch column {
            case .score: return projectScore
            case .coverage: return coverage
            case .notion: return RankedValue(Double(notionSort))
            default:
                if let dimension = column.dimension {
                    return RankedValue(measurements?.measurement(dimension)?.value)
                }
                return groupScore(column)
            }
        }
    }

    // MARK: - Rows

    private var rows: [ProjectRow] {
        var result = model.projects().map(makeRow)
        if let kindFilter { result = result.filter { $0.kind == kindFilter } }
        if let domainFilter { result = result.filter { $0.metadata.domain == domainFilter } }
        if let statusFilter { result = result.filter { $0.metadata.status == statusFilter } }
        if let phaseFilter { result = result.filter { $0.metadata.phase == phaseFilter } }
        switch priorityFilter {
        case .all: break
        case .untriaged: result = result.filter { $0.metadata.portfolioPriority == nil }
        default: result = result.filter { $0.metadata.portfolioPriority == priorityFilter.value }
        }
        if showOnlyRated { result = result.filter { $0.answeredCount > 0 } }
        if query.isEmpty == false {
            result = result.filter {
                $0.name.localizedCaseInsensitiveContains(query)
                    || model.tags(for: $0.item).contains { $0.name.localizedCaseInsensitiveContains(query) }
            }
        }
        return result.sorted(using: sortOrder)
    }

    private func makeRow(_ item: WorkspaceItem) -> ProjectRow {
        let detail = details[item.url.path]
        return ProjectRow(
            id: item.id,
            item: item,
            name: item.displayTitle,
            kind: detail?.projectKind ?? .folder,
            isGit: detail?.isGitRepository ?? false,
            branch: detail?.gitBranch ?? "",
            modified: item.contentModifiedAt ?? .distantPast,
            children: item.immediateChildCount ?? 0,
            record: model.projectRecord(for: item),
            score: model.score(for: item),
            measurements: model.measurements(for: item),
            metadata: model.projectMetadata(for: item), nextAction: model.projectNextAction(for: item)
        )
    }

    private var kindCounts: [(ProjectKind, Int)] {
        var counts: [ProjectKind: Int] = [:]
        for item in model.projects() {
            counts[details[item.url.path]?.projectKind ?? .folder, default: 0] += 1
        }
        return ProjectKind.allCases.compactMap { kind in counts[kind].map { (kind, $0) } }
    }

    // MARK: - Body

    var body: some View {
        Group {
            if let id = model.openGraphProjectID, let project = model.graphRecords.first(where: { $0.id == id }) {
                GraphSelectedProjectView(project: project).id(project.id)
            } else if let project = model.workspaceProject() {
                ProjectWorkspaceView(project: project).id(project.id)
            } else {
                VStack(spacing: 0) {
                    let setupIDs = model.projectStore.setupProjectIDs()
                    let newProjects = model.projects().filter { project in model.projectRecord(for: project).map { setupIDs.contains($0.id) } ?? false }
                    if !newProjects.isEmpty {
                        ScrollView(.horizontal) {
                            HStack {
                                ForEach(newProjects) { project in
                                    VStack(alignment: .leading, spacing: 8) {
                                    Button { model.openProjectWorkspace(for: project) } label: {
                                        VStack(alignment: .leading) {
                                            Label("New project created", systemImage: "sparkles").font(.caption).foregroundStyle(.orange)
                                            Text(project.displayTitle).font(.headline).lineLimit(2)
                                            Text("Add details, score, media and tasks").font(.caption).foregroundStyle(.secondary)
                                        }
                                    }.buttonStyle(.plain)
                                    if let id = model.graphProject(for: project)?.pageID ?? model.projectRecord(for: project)?.notionPageID,
                                       let url = URL(string: "https://www.notion.so/" + id) {
                                        Button("Open in Notion") { model.open(url) }.buttonStyle(.borderless)
                                    } else {
                                        Button(model.graphProject(for: project)?.ambiguousCreate == true ? "Review Notion creation…" : "Add to Notion…") {
                                            if !model.hasNotionToken || !model.graphSources.contains(where: { $0.kind == .projects }) {
                                                showingNotionSettings = true
                                            } else {
                                                preparingNotionProject = true
                                                Task { @MainActor in
                                                    defer { preparingNotionProject = false }
                                                    do { try await model.reviewNewProjectInNotion(project) }
                                                    catch { notionProjectError = error.localizedDescription }
                                                }
                                            }
                                        }.buttonStyle(.bordered).controlSize(.small)
                                            .disabled(preparingNotionProject || model.graphBusy)
                                            .accessibilityIdentifier("projects.new.notion." + project.id)
                                    }
                                    }.padding(12).frame(width: 280, alignment: .leading)
                                        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))
                                }
                            }.padding(.horizontal).padding(.vertical, 10)
                        }.frame(height: 142)
                        Divider()
                    }
                    ProjectBrowserView()
                }
            }
        }
        .alert("Couldn’t prepare Notion project", isPresented: Binding(get: { notionProjectError != nil }, set: { if !$0 { notionProjectError = nil } })) {
            Button("OK") { notionProjectError = nil }
        } message: { Text(notionProjectError ?? "") }
        .sheet(isPresented: $showingNotionSettings) {
            VStack(alignment: .leading, spacing: 16) {
                HStack { Text("Notion settings").font(.title2.bold()); Spacer(); Button("Done") { showingNotionSettings = false } }
                ScrollView { NotionSettingsSection().environment(model) }
            }.padding(20).frame(width: 660, height: 540)
        }
    }

    private var portfolioBrowser: some View {
        VStack(spacing: 0) {
            AreaHeader(title: "Projects", subtitle: model.headerSubtitle(for: .projects),
                       symbol: model.settings(for: .projects).symbol, count: rows.count) {
                HStack(spacing: Theme.Space.snug) {
                    InlineSearchField(text: $query, prompt: "Search projects and tags")
                    Button("Import metadata…") {
                        Task { @MainActor in
                            await model.planProjectMetadataImport()
                            showingMetadataImport = model.projectMetadataImportPreviews.isEmpty == false
                        }
                    }
                    .buttonStyle(.borderless)
                    .disabled(model.canPreviewProjectMetadataImport == false || model.notionBusy)
                    .help(model.canPreviewProjectMetadataImport
                          ? "Compare linked Notion Projects pages before importing selected local metadata."
                          : "Configure an optional Notion token and Projects database in Settings to import metadata.")
                    if presentation != .decide { kindMenu }
                    metadataMenus
                    sortMenu
                    if presentation == .table { columnsMenu }
                    projectSpacesMenu
                }
            }
            Divider()
            HStack {
                Picker("Project view", selection: $presentation) {
                    ForEach(ProjectPresentation.allCases) { view in
                        Label(view.title, systemImage: view.symbolName).tag(view)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 225)
                .accessibilityIdentifier("projects.presentation")
                if presentation == .portfolio {
                    Menu {
                        ForEach(ProjectPortfolioGroup.allCases) { option in
                            Button(option.title) { portfolioGroup = option }
                        }
                    } label: {
                        Label("Group: \(portfolioGroup.title)", systemImage: "rectangle.3.group")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
                Spacer()
            }
            .padding(.horizontal, Theme.Space.base)
            .padding(.vertical, Theme.Space.tight)
            .background(Color(nsColor: .windowBackgroundColor))
            Divider()
            switch presentation {
            case .table:
                table
            case .portfolio:
                ProjectsPortfolioView(rows: rows, spaces: model.projectSpaces(), query: query, group: portfolioGroup) { item in
                    model.openProjectWorkspace(for: item)
                }
            case .decide:
                ProjectsDecisionView { candidate in
                    if let project = model.portfolioProject(for: candidate) { model.openProjectWorkspace(for: project) }
                }
            }
        }
        // Re-read on any change below Projects: a `git checkout` changes a branch without
        // changing the number of projects, and the old count key never noticed.
        .task(id: model.revision(ofArea: WorkspaceArea.projects.directoryName)) { await loadDetails() }
        .sheet(item: $ratingTarget) { record in
            RatingSheet(record: record).environment(model)
        }
        .sheet(isPresented: $showingMetadataImport) {
            ProjectMetadataImportReview().environment(model)
        }
        .onChange(of: presentation) { _, _ in savePortfolioPreferences() }
        .onChange(of: domainFilter) { _, _ in savePortfolioPreferences() }
        .onChange(of: statusFilter) { _, _ in savePortfolioPreferences() }
        .onChange(of: phaseFilter) { _, _ in savePortfolioPreferences() }
        .onChange(of: priorityFilter) { _, _ in savePortfolioPreferences() }
        .onChange(of: portfolioGroup) { _, _ in savePortfolioPreferences() }
        .onChange(of: showOnlyRated) { _, _ in savePortfolioPreferences() }
        .onChange(of: portfolioSort) { _, _ in applyPortfolioSort() }
        .onChange(of: portfolioSortAscending) { _, _ in applyPortfolioSort() }
        .onChange(of: sortOrder) { _, order in captureTableSort(order) }
    }

    @ViewBuilder private var metadataMenus: some View {
        let domains = Set(model.projects().compactMap { model.projectMetadata(for: $0).domain }).sorted()
        let statuses = Set(model.projects().compactMap { model.projectMetadata(for: $0).status }).sorted()
        let phases = Set(model.projects().compactMap { model.projectMetadata(for: $0).phase }).sorted()
        if domains.isEmpty == false { metadataMenu("Domain", values: domains, selection: $domainFilter) }
        if statuses.isEmpty == false { metadataMenu("Status", values: statuses, selection: $statusFilter) }
        if phases.isEmpty == false { metadataMenu("Phase", values: phases, selection: $phaseFilter) }
        Menu {
            ForEach(ProjectPriorityFilter.allCases) { option in
                Button(option.title) { priorityFilter = option }
            }
        } label: { Label(priorityFilter.title, systemImage: "exclamationmark.circle") }
            .menuStyle(.borderlessButton).fixedSize()
        if activeFilterCount > 0 {
            Label("\(activeFilterCount) filters", systemImage: "line.3.horizontal.decrease.circle.fill")
                .font(.caption).foregroundStyle(.tint)
            Button("Reset filters") { resetFilters() }
                .buttonStyle(.borderless).font(.caption)
        }
    }

    private func metadataMenu(_ title: String, values: [String], selection: Binding<String?>) -> some View {
        Menu {
            Button("All \(title)s") { selection.wrappedValue = nil }
            Divider()
            ForEach(values, id: \.self) { value in Button(value) { selection.wrappedValue = value } }
        } label: { Label(selection.wrappedValue ?? title, systemImage: "line.3.horizontal.decrease.circle") }
            .menuStyle(.borderlessButton).fixedSize()
    }

    private var kindMenu: some View {
        Menu {
            Button("All kinds") { kindFilter = nil }
            Divider()
            ForEach(kindCounts, id: \.0) { kind, count in
                Button("\(kind.rawValue) (\(count))") { kindFilter = kind }
            }
        } label: {
            Label(kindFilter?.rawValue ?? "All kinds", systemImage: "line.3.horizontal.decrease.circle")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private var sortMenu: some View {
        Menu {
            Section("Sort by") {
                ForEach(ProjectPortfolioSort.allCases) { sort in
                    Button(sort.title) { portfolioSort = sort }
                }
            }
            Divider()
            Button(portfolioSortAscending ? "Descending" : "Ascending") { portfolioSortAscending.toggle() }
        } label: {
            Label("Sort: \(portfolioSort.title)", systemImage: portfolioSortAscending ? "arrow.up" : "arrow.down")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    /// `_Utilities`, `_Closed`, and `_Collections` are navigation spaces. Showing
    /// them here keeps them one click away without quietly treating them as projects.
    @ViewBuilder
    private var projectSpacesMenu: some View {
        let spaces = model.projectSpaces()
        if spaces.isEmpty == false {
            Menu {
                Section("Project spaces") {
                    ForEach(spaces) { space in
                        let role = space.projectFolderRole
                        Button {
                            model.open(space.url)
                        } label: {
                            Label(role?.title ?? space.displayTitle,
                                  systemImage: role?.symbolName ?? "folder")
                        }
                        .help(role?.summary ?? "Organizational folder")
                    }
                }
            } label: {
                Label("Spaces", systemImage: "folder.badge.gearshape")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityIdentifier("projects.spaces")
        }
    }

    /// Everything the table *can* show, behind one control.
    ///
    /// Scoring more than doubles the available columns. Putting them in a menu rather
    /// than on the screen is the difference between a project browser that gained some
    /// optional depth and a dashboard.
    private var columnsMenu: some View {
        Menu {
            Section("Scoring") {
                ForEach([ProjectColumn.score, .coverage, .notion]) { column in
                    Toggle(column.title, isOn: binding(for: column))
                }
                Toggle("Only rated projects", isOn: $showOnlyRated)
            }
            Section("Measured by the background service") {
                ForEach(ProjectColumn.measuredColumns) { column in
                    Toggle(column.title, isOn: binding(for: column))
                }
            }
            Section("Value groups") {
                ForEach(ProjectColumn.groupColumns) { column in
                    Toggle(column.title, isOn: binding(for: column))
                }
            }
            Divider()
            Button("Reset to Defaults") { resetColumns() }
        } label: {
            Label("Columns", systemImage: "tablecells")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Choose which columns the table shows")
    }

    // MARK: - Table

    private var selection: Binding<Set<String>> {
        Binding(
            get: { model.selectedItem.map { Set([$0.id]) } ?? [] },
            set: { ids in
                guard let id = ids.first, let row = rows.first(where: { $0.id == id }) else { return }
                model.selectedItem = row.item
            }
        )
    }

    private var table: some View {
        Table(rows, selection: selection, sortOrder: $sortOrder) {
            baseColumns
            optionalColumns
        }
        .tableStyle(.inset)
        .contextMenu(forSelectionType: String.self) { ids in
            rowMenu(for: ids)
        } primaryAction: { ids in
            if let id = ids.first, let row = rows.first(where: { $0.id == id }) {
                model.openProjectWorkspace(for: row.item)
            }
        }
    }

    // One generated group rather than conditional columns: `TableColumnBuilder`'s
    // `buildIf` needs macOS 14.4 and this app supports 14.0, so the optional columns
    // are produced by `TableColumnForEach` over whichever ones are switched on.

    @TableColumnBuilder<ProjectRow, KeyPathComparator<ProjectRow>>
    private var baseColumns: some TableColumnContent<ProjectRow, KeyPathComparator<ProjectRow>> {
        TableColumn("Name", value: \ProjectRow.name) { (row: ProjectRow) in
            ProjectNameCell(row: row, tags: model.tags(for: row.item))
        }
        .width(min: 220, ideal: 320)

        TableColumn("Kind", value: \ProjectRow.kind.rawValue) { (row: ProjectRow) in
            Text(row.kind.rawValue).foregroundStyle(.secondary)
        }
        .width(min: 70, ideal: 100)

        TableColumn("Domain", value: \ProjectRow.domain) { (row: ProjectRow) in
            Text(row.metadata.domain ?? "—").foregroundStyle(.secondary)
        }.width(min: 80, ideal: 110)

        TableColumn("Status", value: \ProjectRow.status) { (row: ProjectRow) in
            Text(row.metadata.status ?? "—").foregroundStyle(.secondary)
        }.width(min: 80, ideal: 105)

        TableColumn("Priority", value: \ProjectRow.portfolioPriority) { (row: ProjectRow) in
            Text(row.metadata.portfolioPriorityLabel).foregroundStyle(.secondary)
        }.width(min: 78, ideal: 100)

        TableColumn("Git", value: \ProjectRow.branch) { (row: ProjectRow) in
            GitCell(isRepository: row.isGit, branch: row.branch)
        }
        .width(min: 60, ideal: 110)

        TableColumn("Items", value: \ProjectRow.children) { (row: ProjectRow) in
            Text("\(row.children)")
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .width(min: 40, ideal: 55)

        TableColumn("Last activity", value: \ProjectRow.modified) { (row: ProjectRow) in
            Text(Format.relativeDate(row.item.contentModifiedAt))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .width(min: 80, ideal: 110)
    }

    @TableColumnBuilder<ProjectRow, KeyPathComparator<ProjectRow>>
    private var optionalColumns: some TableColumnContent<ProjectRow, KeyPathComparator<ProjectRow>> {
        TableColumnForEach(visibleOptionalColumns) { (column: ProjectColumn) in
            TableColumn(column.shortTitle, value: \ProjectRow.[column]) { (row: ProjectRow) in
                OptionalColumnCell(column: column, row: row)
            }
            .width(min: 44, ideal: column.idealWidth)
        }
    }

    private var visibleOptionalColumns: [ProjectColumn] {
        ProjectColumn.optional.filter { visibleColumns.contains($0) }
    }

    @ViewBuilder
    private func rowMenu(for ids: Set<String>) -> some View {
        if let id = ids.first, let row = rows.first(where: { $0.id == id }) {
            if let record = row.record {
                Button("Rate This Project…") { ratingTarget = record }
                if let url = record.notionURL {
                    Button("Open in Notion") { model.open(url) }
                }
                Divider()
            }
            if let capability = model.cachedProjectToolCapability(for: row.item) {
                if capability.canExplain { Button("Explain") { model.openProjectTool(.explain, for: row.item) } }
                if capability.canFlowReview { Button("Flow Review") { model.openProjectTool(.flowReview, for: row.item) } }
                if capability.canExplain || capability.canFlowReview { Divider() }
            }
            ItemContextMenu(item: row.item)
        }
    }

    // MARK: - Column preferences

    private func binding(for column: ProjectColumn) -> Binding<Bool> {
        Binding(
            get: { visibleColumns.contains(column) },
            set: { shown in
                if shown { visibleColumns.insert(column) } else { visibleColumns.remove(column) }
                ProjectColumnPreferences.save(visibleColumns)
            }
        )
    }

    private func resetColumns() {
        visibleColumns = ProjectColumn.defaultVisible
        showOnlyRated = false
        ProjectColumnPreferences.save(visibleColumns)
    }

    private var activeFilterCount: Int {
        [domainFilter != nil, statusFilter != nil, phaseFilter != nil,
         priorityFilter != .all, kindFilter != nil, showOnlyRated].filter { $0 }.count
    }

    private func resetFilters() {
        domainFilter = nil; statusFilter = nil; phaseFilter = nil
        priorityFilter = .all; kindFilter = nil; showOnlyRated = false
    }

    private func savePortfolioPreferences() {
        ProjectPortfolioPreferences(
            presentation: presentation, group: portfolioGroup, domain: domainFilter,
            status: statusFilter, phase: phaseFilter, priority: priorityFilter,
            onlyRated: showOnlyRated, sort: portfolioSort,
            sortAscending: portfolioSortAscending
        ).save()
    }

    private func applyPortfolioSort() {
        sortOrder = [Self.comparator(for: portfolioSort, ascending: portfolioSortAscending)]
        savePortfolioPreferences()
    }

    private func captureTableSort(_ order: [KeyPathComparator<ProjectRow>]) {
        guard let comparator = order.first, let sort = Self.sort(for: comparator) else { return }
        portfolioSort = sort
        portfolioSortAscending = comparator.order == .forward
        savePortfolioPreferences()
    }

    private static func comparator(for sort: ProjectPortfolioSort, ascending: Bool) -> KeyPathComparator<ProjectRow> {
        let order: SortOrder = ascending ? .forward : .reverse
        switch sort {
        case .name: return KeyPathComparator(\ProjectRow.name, order: order)
        case .kind: return KeyPathComparator(\ProjectRow.kind.rawValue, order: order)
        case .domain: return KeyPathComparator(\ProjectRow.domain, order: order)
        case .status: return KeyPathComparator(\ProjectRow.status, order: order)
        case .priority: return KeyPathComparator(\ProjectRow.portfolioPriority, order: order)
        case .modified: return KeyPathComparator(\ProjectRow.modified, order: order)
        }
    }

    private static func sort(for comparator: KeyPathComparator<ProjectRow>) -> ProjectPortfolioSort? {
        switch comparator.keyPath {
        case \ProjectRow.name: return .name
        case \ProjectRow.kind.rawValue: return .kind
        case \ProjectRow.domain: return .domain
        case \ProjectRow.status: return .status
        case \ProjectRow.portfolioPriority: return .priority
        case \ProjectRow.modified: return .modified
        default: return nil
        }
    }

    // MARK: - Detail probes

    /// Probes run after the list is already on screen, in small batches, so 383
    /// directory probes never block first paint.
    @MainActor
    private func loadDetails() async {
        let items = model.projects()
        var batch: [String: ItemDetail] = [:]
        for (index, item) in items.enumerated() {
            batch[item.url.path] = await model.probe.detail(for: item)
            if index % 25 == 24 {
                let snapshot = batch
                await MainActor.run { details.merge(snapshot) { _, new in new } }
                await Task.yield()
            }
        }
        let final = batch
        await MainActor.run { details.merge(final) { _, new in new } }
    }
}
