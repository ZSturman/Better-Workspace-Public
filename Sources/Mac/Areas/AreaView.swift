import SwiftUI
import AppKit
import BetterWorkspaceCore

/// Draws one area.
///
/// Two layers, one entry point. A folder with a purpose-built implementation gets it
/// when selected, except Analytics which is always its dashboard; every other folder —
/// including one made in Finder a minute ago — gets `ConfigurableAreaView`, driven
/// entirely by its resolved `AreaSettings`.
struct AreaView: View {
    let folder: WorkspaceFolder

    var body: some View {
        // Analytics was a generic list before it became a dashboard. Existing installs
        // can therefore carry an explicit `.list` preference; honoring that stale
        // preference would make the requested Analytics destination unreachable.
        if let area = folder.purposeBuilt,
           area == .analytics || folder.settings.layout == .purposeBuilt {
            PurposeBuiltAreaView(area: area)
        } else {
            ConfigurableAreaView(folder: folder)
        }
    }
}

/// The dedicated implementations. Adding a case here is the one code change a new
/// purpose-built area needs; nothing else in navigation, ingest or sync has to know.
private struct PurposeBuiltAreaView: View {
    let area: WorkspaceArea

    var body: some View {
        switch area {
        case .analytics: AnalyticsView()
        case .projects: ProjectsView()
        case .ideas: IdeasView()
        case .logs: LogsView()
        case .references: ReferencesView()
        case .inspiration: InspirationView()
        case .organize: OrganizeView()
        case .review: ReviewView()
        case .socialPosts: SocialPostsView()
        case .assets: AssetsView()
        case .backups: BackupsView()
        }
    }
}

// MARK: - Configurable areas

/// The generic experience, scoped to one real root folder. Its rows, actions and new
/// work records never bleed into a sibling folder, and every choice made here is kept
/// in this app's private area settings rather than in the folder.
struct ConfigurableAreaView: View {
    @Environment(AppModel.self) private var model
    let folder: WorkspaceFolder
    @State private var query = ""
    @State private var showingNewWorkItem = false
    @State private var showingSettings = false
    @State private var workStatus: WorkItemStatus?
    /// Completed work is kept, folded away at the end of the queue.
    @State private var showsCompletedWork = false
    @State private var workProjectPath: String?
    @State private var workSort = WorkQueueSort.priority

    private var settings: AreaSettings { folder.settings }

    /// What this folder's contents support right now.
    private var capabilities: AreaCapabilities { model.capabilities(for: folder) }

    /// The layout actually drawn: the chosen one while it still fits the contents, the
    /// list otherwise. Before the first read, the choice stands — unknown is not absent.
    private var layout: AreaLayout {
        guard model.hasLoaded(areaNamed: folder.name) else { return settings.layout }
        return capabilities.resolve(settings.layout, purposeBuilt: folder.purposeBuilt,
                                    isWorkQueue: settings.isWorkQueue)
    }

    private var dateBasis: AreaDateBasis { settings.dateBasis ?? capabilities.preferredDateBasis }

    private var items: [WorkspaceItem] {
        let visible = model.items(inArea: folder.name).filter {
            query.isEmpty || $0.displayTitle.localizedCaseInsensitiveContains(query)
        }
        return visible.sorted(by: settings.sort)
    }

    /// Work records anywhere below this folder, open ones first.
    private var queueWorkItems: [WorkItem] {
        let root = folder.url.canonicalPath
        return model.workItems.filter { $0.url.canonicalPath.hasPrefix(root + "/") }
    }

    private var workProjectChoices: [String] {
        Array(Set(queueWorkItems.compactMap(\.projectPath))).sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }
    }

    private var workItems: [WorkItem] {
        queueWorkItems
            .filter { item in
                (workStatus == nil || item.status == workStatus)
                    && (workProjectPath == nil || item.projectPath == workProjectPath)
                    && (query.isEmpty || item.title.localizedCaseInsensitiveContains(query)
                        || item.projectPath?.localizedCaseInsensitiveContains(query) == true)
            }
            .sorted(by: workOrder)
    }

    /// Not read yet: the work queue waits on the work-item walk, every other layout on
    /// this area's own listing.
    private var showsLoading: Bool {
        layout == .workQueue ? model.isAwaitingWorkItems : model.isAwaitingFirstRead(areaNamed: folder.name)
    }

    var body: some View {
        VStack(spacing: 0) {
            AreaHeader(title: folder.name,
                       subtitle: model.headerSubtitle(forFolderNamed: folder.name),
                       symbol: settings.symbol,
                       // An outline search matches nested items the top-level filter
                       // can't see, so its count stays the area's own.
                       count: showsLoading ? nil : layout == .workQueue ? workItems.filter(\.isOpen).count
                            : layout == .outline ? model.items(inArea: folder.name).count : items.count) {
                HStack(spacing: Theme.Space.snug) {
                    if layout == .workQueue {
                        Button { showingNewWorkItem = true } label: {
                            Label("New \(settings.workItemKind.displayName)", systemImage: "plus")
                        }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("area.newWorkItem")
                    }
                    layoutMenu
                    Button { showingSettings = true } label: {
                        Label("Area Settings", systemImage: "slider.horizontal.3")
                    }
                    .labelStyle(.iconOnly)
                    .help("How Better Workspace presents \(folder.name)")
                    .accessibilityIdentifier("area.settings")
                    Button { model.revealInFinder(folder.url) } label: {
                        Label("Show in Finder", systemImage: "folder")
                    }
                    .labelStyle(.iconOnly)
                    .help("Show \(folder.name) in Finder")
                }
            }
            Divider()

            if folder.isUnfamiliar {
                unfamiliarBanner
                Divider()
            }

            if layout != settings.layout {
                fallbackNote
                Divider()
            }

            filterBar

            switch layout {
            case .workQueue: workQueue
            case .table: table
            case .gallery: gallery
            case .timeline:
                if items.isEmpty { emptyState } else { AreaTimelineView(items: items, basis: dateBasis) }
            case .outline:
                AreaOutlineView(items: model.items(inArea: folder.name).sorted(by: settings.sort),
                                query: query, sort: settings.sort,
                                revision: model.revision(ofArea: folder.name))
            case .list, .purposeBuilt: list
            }
        }
        .sheet(isPresented: $showingNewWorkItem) {
            WorkItemEditor(mode: .create, kind: settings.workItemKind) { value in
                try await model.createWorkItem(kind: value.kind, title: value.title, body: value.body,
                                               status: value.status, stage: value.stage, priority: value.priority,
                                               projectPath: value.projectPath, parentID: value.parentID,
                                               relatedIDs: value.relatedIDs, featureIDs: value.featureIDs,
                                               milestoneIDs: value.milestoneIDs, in: folder.url)
            }
        }
        .sheet(isPresented: $showingSettings) {
            AreaSettingsSheet(folder: folder)
        }
        .onAppear { openFocusedWorkItemIfNeeded() }
        .onChange(of: model.focusedWorkItemPath) { _, _ in openFocusedWorkItemIfNeeded() }
    }

    // MARK: Chrome

    /// Switching view is the most common change, so it is one click from the header
    /// and saved like any other setting.
    private var layoutMenu: some View {
        Menu {
            ForEach(layoutChoices.available) { layout in
                Button {
                    var personal = folder.personal
                    personal.layout = layout
                    model.setConfiguration(personal, for: folder)
                } label: {
                    Label(layout.displayName, systemImage: layout.symbolName)
                }
            }
            // Shown, not hidden: the reason says what would make the view appear.
            if layoutChoices.unavailable.isEmpty == false {
                Section("Not available here") {
                    ForEach(layoutChoices.unavailable, id: \.layout) { choice in
                        Button {} label: {
                            Text(choice.layout.displayName)
                            Text(choice.reason)
                        }
                        .disabled(true)
                    }
                }
            }
        } label: {
            Label(layout.displayName, systemImage: layout.symbolName)
        }
        .menuIndicator(.visible)
        .fixedSize()
        .help("Change how this area is shown")
        .accessibilityIdentifier("area.layout")
    }

    private var layoutChoices: AreaLayoutChoices { folder.layoutChoices(given: capabilities) }

    private var fallbackNote: some View {
        HStack(spacing: Theme.Space.tight) {
            Image(systemName: "info.circle").foregroundStyle(.secondary)
            Text("\(settings.layout.displayName) doesn't fit right now: "
                 + (capabilities.availability(of: settings.layout, purposeBuilt: folder.purposeBuilt,
                                              isWorkQueue: settings.isWorkQueue).reason?.lowercasedFirst ?? "")
                 + ". Showing the list; your choice returns when it applies.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer()
        }
        .padding(.horizontal, Theme.Space.base)
        .padding(.vertical, Theme.Space.tight)
        .accessibilityIdentifier("area.layoutFallback")
    }

    private var unfamiliarBanner: some View {
        HStack(spacing: Theme.Space.snug) {
            Image(systemName: "sparkle").foregroundStyle(.tint)
            Text("New to Better Workspace. It's shown as a plain list until you choose otherwise.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer(minLength: Theme.Space.tight)
            Button("Set Up…") { showingSettings = true }
                .accessibilityIdentifier("area.setUp")
        }
        .padding(.horizontal, Theme.Space.base)
        .padding(.vertical, Theme.Space.snug)
        .background(Color.accentColor.opacity(0.06))
    }

    private var filterBar: some View {
        Group {
            if layout == .workQueue {
                // Queue filtering needs more than one control. Giving it a second
                // compact line keeps all of them usable in the 820pt window instead
                // of letting AppKit squeeze them out beside the search field.
                VStack(alignment: .leading, spacing: Theme.Space.tight) {
                    InlineSearchField(text: $query, prompt: "Search \(folder.name.lowercased())")
                    workQueueFilters
                }
            } else {
                HStack(spacing: Theme.Space.snug) {
                    InlineSearchField(text: $query, prompt: "Search \(folder.name.lowercased())")
                    Spacer()
                    if layout == .timeline {
                Picker("Date", selection: Binding(
                    get: { dateBasis },
                    set: { basis in
                        var personal = folder.personal
                        personal.dateBasis = basis
                        model.setConfiguration(personal, for: folder)
                    }
                )) {
                    ForEach(AreaDateBasis.allCases) { basis in
                        Text(basis.displayName).tag(basis)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .help("Lay items out by when they were added, or by when they last changed")
                .accessibilityIdentifier("area.dateBasis")
                    } else {
                Menu {
                    Picker("Sort", selection: Binding(
                        get: { settings.sort },
                        set: { sort in
                            var personal = folder.personal
                            personal.sort = sort
                            model.setConfiguration(personal, for: folder)
                        }
                    )) {
                        ForEach(AreaSort.allCases) { Text($0.displayName).tag($0) }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Label(settings.sort.displayName, systemImage: "arrow.up.arrow.down")
                        .font(.system(size: 11))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .accessibilityIdentifier("area.sort")
                    }
                }
            }
        }
        .padding(.horizontal, Theme.Space.base)
        .padding(.vertical, Theme.Space.snug)
    }

    private var workQueueFilters: some View {
        HStack(spacing: Theme.Space.tight) {
            Menu {
                Button("All projects") { workProjectPath = nil }
                if workProjectChoices.isEmpty == false { Divider() }
                ForEach(workProjectChoices, id: \.self) { path in
                    Button(path) { workProjectPath = path }
                }
            } label: {
                Label(workProjectPath ?? "All projects", systemImage: "folder")
            }
            .menuStyle(.borderlessButton)

            Menu {
                Button("All statuses") { workStatus = nil }
                Divider()
                ForEach(WorkItemStatus.allCases) { status in
                    Button(status.displayName) { workStatus = status }
                }
            } label: {
                Label(workStatus?.displayName ?? "All statuses", systemImage: "circle.lefthalf.filled")
            }
            .menuStyle(.borderlessButton)

            Menu {
                ForEach(WorkQueueSort.allCases) { option in
                    Button(option.title) { workSort = option }
                }
            } label: {
                Label(workSort.title, systemImage: "arrow.up.arrow.down")
            }
            .menuStyle(.borderlessButton)
        }
        .font(.system(size: 11))
        .fixedSize()
    }

    @ViewBuilder
    private var emptyState: some View {
        if showsLoading {
            LoadingAreaState(title: "Loading \(folder.name)…")
        } else {
            EmptyAreaState(symbol: settings.symbol,
                           title: query.isEmpty ? "Nothing here yet" : "No matching items",
                           message: "Items placed in \(folder.name) appear here. Ingest can file directly into this folder.")
        }
    }

    private var selection: Binding<WorkspaceItem.ID?> {
        Binding(get: { model.selectedItem?.id },
                set: { id in model.selectedItem = items.first(where: { $0.id == id }) })
    }

    // MARK: Layouts

    private var list: some View {
        Group {
            if items.isEmpty {
                emptyState
            } else {
                List(items, selection: selection) { item in
                    HStack(spacing: Theme.Space.snug) {
                        Image(systemName: item.kind.symbolName)
                            .foregroundStyle(Theme.kindColor(item.kind))
                            .frame(width: 18)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.displayTitle).lineLimit(1)
                            HStack(spacing: Theme.Space.tight) {
                                Text(sizeText(item))
                                Text("·")
                                Text(Format.relativeDate(item.contentModifiedAt))
                                let tags = model.tags(for: item)
                                if tags.isEmpty == false { TagChipRow(tags: tags, limit: 3) }
                            }
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        }
                    }
                    .contextMenu { ItemContextMenu(item: item) }
                    .onTapGesture(count: 2) { model.open(item.url) }
                }
                .listStyle(.inset)
            }
        }
    }

    private var table: some View {
        Group {
            if items.isEmpty {
                emptyState
            } else {
                Table(items, selection: selection) {
                    TableColumn("Name") { item in
                        HStack(spacing: Theme.Space.tight) {
                            Image(systemName: item.kind.symbolName)
                                .foregroundStyle(Theme.kindColor(item.kind))
                                .frame(width: 16)
                            Text(item.displayTitle).lineLimit(1)
                        }
                    }
                    .width(min: 160, ideal: 280)
                    TableColumn("Kind") { item in
                        Text(item.isDirectory ? "Folder" : item.kind.displayName)
                            .foregroundStyle(.secondary)
                    }
                    .width(min: 70, ideal: 95)
                    TableColumn("Size") { item in
                        Text(sizeText(item)).monospacedDigit().foregroundStyle(.secondary)
                    }
                    .width(min: 60, ideal: 80)
                    TableColumn("Modified") { item in
                        Text(Format.relativeDate(item.contentModifiedAt)).foregroundStyle(.secondary)
                    }
                    .width(min: 80, ideal: 110)
                    TableColumn("Tags") { item in
                        let tags = model.tags(for: item)
                        if tags.isEmpty == false { TagChipRow(tags: tags, limit: 2) }
                    }
                    .width(min: 60, ideal: 140)
                }
                .contextMenu(forSelectionType: WorkspaceItem.ID.self) { ids in
                    if let item = items.first(where: { ids.contains($0.id) }) {
                        ItemContextMenu(item: item)
                    }
                } primaryAction: { ids in
                    for item in items where ids.contains(item.id) { model.open(item.url) }
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("area.table")
            }
        }
    }

    private var gallery: some View {
        Group {
            if items.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: Theme.Space.snug)],
                              spacing: Theme.Space.base) {
                        ForEach(items) { item in
                            GalleryCell(item: item, size: 140, isSelected: model.selectedItem?.id == item.id)
                                .onTapGesture(count: 2) { model.open(item.url) }
                                .onTapGesture { model.selectedItem = item }
                                .contextMenu { ItemContextMenu(item: item) }
                        }
                    }
                    .padding(Theme.Space.base)
                }
            }
        }
    }

    /// Open features and milestones with no project, listed first until placed.
    private var attentionItems: [WorkItem] { workItems.filter(\.needsAttention) }

    /// Notes left loose in this folder, which the queue would otherwise never show.
    private var strandedNotes: [WorkspaceItem] {
        model.items(inArea: folder.name)
            .filter { $0.isDirectory == false && StrandedQueueNotes.isStranded($0.url) }
            .filter { query.isEmpty || $0.displayTitle.localizedCaseInsensitiveContains(query) }
            .sorted { $0.displayTitle.localizedStandardCompare($1.displayTitle) == .orderedAscending }
    }

    private var workQueue: some View {
        let attention = attentionItems
        let attentionIDs = Set(attention.map(\.id))
        let stranded = strandedNotes
        let rest = workItems.filter { attentionIDs.contains($0.id) == false }
        // Unless a status is chosen, finished work folds away below what is still open.
        let open = workStatus == nil ? rest.filter(\.isOpen) : rest
        let done = workStatus == nil ? rest.filter { !$0.isOpen } : []
        // Once for the whole list, not per row.
        let choices = LinkChoices(
            projects: model.projectLinkChoices,
            features: model.workLinkChoices(.feature, projectPath: nil, keeping: workItems.flatMap(\.featureIDs)),
            milestones: model.workLinkChoices(.milestone, projectPath: nil, keeping: workItems.flatMap(\.milestoneIDs)))
        return Group {
            if workItems.isEmpty, stranded.isEmpty, showsLoading {
                LoadingAreaState(title: "Loading work…", message: "Looking for work items across the Workspace.")
            } else if workItems.isEmpty, stranded.isEmpty {
                EmptyAreaState(symbol: settings.symbol,
                               title: query.isEmpty ? "No \(settings.workItemKind.displayName.lowercased())s yet"
                                                    : "No matching work",
                               message: "Create one here, or add a Better Workspace .bw.md file in Finder.")
            } else {
                List {
                    if attention.isEmpty == false || stranded.isEmpty == false {
                        Section {
                            ForEach(stranded) { note in strandedRow(note) }
                            ForEach(attention) { item in workRow(item, choices: choices) }
                        } header: {
                            Label("Needs Attention", systemImage: "exclamationmark.circle")
                                .foregroundStyle(.orange)
                                .help("Notes to convert, and work with no project yet")
                                .accessibilityIdentifier("workQueue.needsAttention")
                        }
                    }
                    if open.isEmpty == false {
                        Section {
                            ForEach(open) { item in workRow(item, choices: choices) }
                        } header: {
                            if attention.isEmpty == false || stranded.isEmpty == false {
                                Text(settings.workItemKind.displayName + "s")
                            }
                        }
                    }
                    if done.isEmpty == false {
                        Section {
                            if showsCompletedWork { ForEach(done) { item in workRow(item, choices: choices) } }
                        } header: {
                            Button { showsCompletedWork.toggle() } label: {
                                Label("Completed · \(done.count)", systemImage: showsCompletedWork ? "chevron.down" : "chevron.right")
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("workQueue.completed")
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
    }

    /// A note sitting loose in the queue folder, with a one-click conversion.
    private func strandedRow(_ note: WorkspaceItem) -> some View {
        HStack(spacing: Theme.Space.base) {
            Image(systemName: "doc.text").foregroundStyle(.secondary).frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                Text(note.displayTitle).lineLimit(1)
                Text("Note, not yet a \(settings.workItemKind.displayName.lowercased())")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .layoutPriority(1)
            Spacer()
            Button("Convert") { Task { @MainActor in await model.convertStrandedNote(note.url, in: folder) } }
                .accessibilityIdentifier("workQueue.convert.\(note.name)")
                .help("Make this note a \(settings.workItemKind.displayName.lowercased()); the note goes to the Trash")
            Button("Open") { model.open(note.url) }.buttonStyle(.link)
        }
        .contextMenu {
            ItemContextMenu(item: note)
        }
    }

    private struct LinkChoices {
        let projects: [WorkLinkChoice]
        let features: [WorkLinkChoice]
        let milestones: [WorkLinkChoice]
    }

    private func workRow(_ item: WorkItem, choices: LinkChoices) -> some View {
        let isCompleting = model.isPendingCompletion(item)
        let isComplete = item.status == .completed || isCompleting
        return HStack(spacing: Theme.Space.base) {
            Button { model.completeWorkItem(item) } label: {
                Image(systemName: isComplete ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isComplete ? .green : .secondary)
            }
            .buttonStyle(.plain)
            .help(isCompleting ? "Undo completion" : (isComplete ? "Reopen" : "Mark complete"))
            .accessibilityIdentifier("workItem.complete.\(item.id)")
            // Only when it says something: in a task queue, "task" is a given.
            if item.kind != settings.workItemKind {
                Image(systemName: item.kind.symbolName).foregroundStyle(.tint).frame(width: 18)
                    .help(item.kind.displayName)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .strikethrough(isComplete)
                    .foregroundStyle(isComplete ? .secondary : .primary)
                    .lineLimit(1)
                Text(workDetail(item))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .layoutPriority(1)
            Spacer(minLength: Theme.Space.tight)
            // Where it belongs, changeable in place.
            WorkLinkPickers(kind: item.kind, links: item.links, projects: choices.projects,
                            features: choices.features.filter { $0.id != item.id },
                            milestones: choices.milestones.filter { $0.id != item.id }) { model.setLinks($0, for: item) }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("workItem.links.\(item.id)")
            Button("Edit") { model.edit(workItem: item) }.buttonStyle(.link)
            if item.kind == .task {
                Button(role: .destructive) { model.requestDeletion(of: item) } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless).help("Move to Trash")
                    .accessibilityIdentifier("workItem.delete.\(item.id)")
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { model.inspect(workItem: item) }
        .contextMenu {
            if item.projectPath != nil {
                Button("Open Project") { model.revealProject(for: item) }
            }
            Button("Open File") { model.open(item.url) }
            if item.status != .completed { Button(isCompleting ? "Undo Completion" : "Mark Complete") { model.completeWorkItem(item) } }
            Divider()
            WorkDeletionMenu(item: item) { model.requestDeletion(of: $0) }
        }
    }

    /// Stage and priority; where it belongs is shown by the link menus beside it.
    private func workDetail(_ item: WorkItem) -> String {
        // Medium is the default; saying so on every row is noise.
        [item.stage.displayName, item.priority == .medium ? nil : item.priority.rawValue.capitalized + " priority"]
            .compactMap { $0 }.joined(separator: " · ")
    }

    private func workOrder(_ lhs: WorkItem, _ rhs: WorkItem) -> Bool {
        if lhs.isOpen != rhs.isOpen { return lhs.isOpen }
        switch workSort {
        case .priority:
            if lhs.priority != rhs.priority { return lhs.priority.rank < rhs.priority.rank }
        case .dueDate:
            if lhs.dueDate != rhs.dueDate { return (lhs.dueDate ?? .distantFuture) < (rhs.dueDate ?? .distantFuture) }
        case .title:
            break
        case .status:
            if lhs.status != rhs.status { return lhs.status.rawValue < rhs.status.rawValue }
        }
        return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
    }

    private func openFocusedWorkItemIfNeeded() {
        guard let path = model.focusedWorkItemPath,
              path.hasPrefix(folder.url.canonicalPath + "/"),
              let item = queueWorkItems.first(where: { $0.url.canonicalPath == path })
        else { return }
        model.focusedWorkItemPath = nil
        model.inspect(workItem: item)
    }

    private func sizeText(_ item: WorkspaceItem) -> String {
        item.isDirectory ? Format.count(item.immediateChildCount, singular: "item") : Format.bytes(item.byteSize)
    }
}

private enum WorkQueueSort: String, CaseIterable, Identifiable {
    case priority, dueDate, title, status
    var id: String { rawValue }
    var title: String {
        switch self {
        case .priority: "Priority"
        case .dueDate: "Due date"
        case .title: "Title"
        case .status: "Status"
        }
    }
}

extension Array where Element == WorkspaceItem {
    func sorted(by sort: AreaSort) -> [WorkspaceItem] {
        sorted { lhs, rhs in
            switch sort {
            case .name:
                return lhs.displayTitle.localizedStandardCompare(rhs.displayTitle) == .orderedAscending
            case .newest:
                return (lhs.contentModifiedAt ?? .distantPast) > (rhs.contentModifiedAt ?? .distantPast)
            case .oldest:
                return (lhs.contentModifiedAt ?? .distantFuture) < (rhs.contentModifiedAt ?? .distantFuture)
            case .largest:
                return lhs.byteSize > rhs.byteSize
            }
        }
    }
}

// MARK: - Settings

/// Edits one area's personal settings.
///
/// Every control shows the effective value and whether it is inherited. Changing a
/// field records only that field; "Use Defaults" removes the whole entry, so the area
/// goes back to following whatever Better Workspace ships.
struct AreaSettingsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let folder: WorkspaceFolder
    @State private var draft: AreaConfiguration

    init(folder: WorkspaceFolder) {
        self.folder = folder
        _draft = State(initialValue: folder.personal)
    }

    private var defaults: AreaConfiguration { AreaDefaults.configuration(forFolderNamed: folder.name) }
    private var choices: AreaLayoutChoices {
        folder.layoutChoices(given: model.capabilities(for: folder), isWorkQueue: effective.isWorkQueue)
    }
    private var effective: AreaSettings {
        AreaSettings(resolving: draft.layered(over: defaults), purposeBuilt: folder.purposeBuilt)
    }

    private static let symbolSuggestions = [
        "folder", "tray.full", "checklist", "book", "play.rectangle", "magnifyingglass", "doc.text",
        "photo.on.rectangle.angled", "calendar", "chart.xyaxis.line", "text.bubble", "graduationcap",
        "archivebox", "star", "flag", "bookmark",
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Theme.Space.snug) {
                Image(systemName: effective.symbol).font(.system(size: 20)).foregroundStyle(.tint)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text(folder.name).font(.title3.weight(.semibold))
                    Text(folder.purposeBuilt != nil ? "Has a purpose-built view" : "Configurable area")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(Theme.Space.loose)
            Divider()

            Form {
                Section {
                    Picker("View", selection: field(\.layout, fallback: effective.layout)) {
                        // What fits, plus whatever is chosen now even if it no longer
                        // does, so the picker never shows a blank selection.
                        ForEach(AreaLayout.allCases.filter { choices.available.contains($0) || $0 == effective.layout }) {
                            Label($0.displayName, systemImage: $0.symbolName).tag($0)
                        }
                    }
                    .accessibilityIdentifier("areaSettings.layout")
                    Text(effective.layout.explanation).font(.caption).foregroundStyle(.secondary)
                    if choices.unavailable.isEmpty == false {
                        Text("Not available for what \(folder.name) holds now: "
                             + choices.unavailable.map { "\($0.layout.displayName) (\($0.reason.lowercasedFirst))" }
                                .joined(separator: "; ") + ".")
                            .font(.caption).foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if effective.layout == .workQueue {
                        Picker("New items are", selection: field(\.workItemKind, fallback: effective.workItemKind)) {
                            ForEach(WorkItemKind.allCases) { Text($0.displayName).tag($0) }
                        }
                    }
                    if effective.layout != .workQueue && effective.layout != .purposeBuilt {
                        Picker("Sort", selection: field(\.sort, fallback: effective.sort)) {
                            ForEach(AreaSort.allCases) { Text($0.displayName).tag($0) }
                        }
                    }
                } header: { Text("Presentation") }

                Section {
                    TextField("Subtitle", text: Binding(
                        get: { draft.subtitle ?? defaults.subtitle ?? "" },
                        set: { draft.subtitle = $0 == (defaults.subtitle ?? "") ? nil : $0 }
                    ), prompt: Text("What this folder holds"))
                    LabeledContent("Symbol") {
                        HStack(spacing: 4) {
                            ForEach(Self.symbolSuggestions, id: \.self) { symbol in
                                Button {
                                    draft.symbol = symbol == (defaults.symbol ?? "folder") ? nil : symbol
                                } label: {
                                    Image(systemName: symbol)
                                        .frame(width: 20, height: 20)
                                        .background(effective.symbol == symbol ? Color.accentColor.opacity(0.25) : .clear,
                                                    in: RoundedRectangle(cornerRadius: 4))
                                }
                                .buttonStyle(.plain)
                                .help(symbol)
                            }
                        }
                    }
                } header: { Text("Identity") }

                Section {
                    Picker("Ingest destination", selection: field(\.ingest, fallback: effective.ingest)) {
                        ForEach(AreaIngestRole.allCases) { Text($0.displayName).tag($0) }
                    }
                    Toggle("Hide from sidebar", isOn: Binding(
                        get: { effective.hidden },
                        set: { draft.hidden = $0 == (defaults.hidden ?? false) ? nil : $0 }
                    ))
                } header: { Text("Behavior") } footer: {
                    Text("Saved privately in \(AreaConfigurationStore.fileName) beside Better Workspace's database. "
                         + "Nothing is written into \(folder.name).")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Button("Use Defaults") { draft = AreaConfiguration() }
                    .disabled(draft.isEmpty)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    var saved = draft
                    // Saving a new folder's settings unchanged is still an answer: it
                    // means "a list is right", and the set-up prompt should go away.
                    if saved.isEmpty && folder.isUnfamiliar { saved.layout = .list }
                    model.setConfiguration(saved, for: folder)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("areaSettings.save")
            }
            .padding(Theme.Space.base)
        }
        .frame(width: 520, height: 500)
    }

    /// A picker binding that stores only a departure from the default.
    private func field<Value: Equatable>(_ keyPath: WritableKeyPath<AreaConfiguration, Value?>,
                                         fallback: Value) -> Binding<Value> {
        Binding(
            get: { draft[keyPath: keyPath] ?? fallback },
            set: { value in
                // Choosing what the defaults already say clears the override, so the
                // area keeps following the defaults for that field.
                draft[keyPath: keyPath] = (defaults[keyPath: keyPath] == value) ? nil : value
            }
        )
    }
}

/// Every layout a folder could be shown in, split by whether its contents support it.
struct AreaLayoutChoices {
    struct Unavailable { let layout: AreaLayout; let reason: String }
    var available: [AreaLayout] = []
    var unavailable: [Unavailable] = []
}

extension WorkspaceFolder {
    /// `.purposeBuilt` is left out entirely for a folder without one: it is not a
    /// capability anyone could add by filing things there.
    func layoutChoices(given capabilities: AreaCapabilities, isWorkQueue: Bool? = nil) -> AreaLayoutChoices {
        var choices = AreaLayoutChoices()
        for layout in AreaLayout.allCases where layout != .purposeBuilt || purposeBuilt != nil {
            switch capabilities.availability(of: layout, purposeBuilt: purposeBuilt,
                                             isWorkQueue: isWorkQueue ?? settings.isWorkQueue) {
            case .available: choices.available.append(layout)
            case .unavailable(let reason): choices.unavailable.append(.init(layout: layout, reason: reason))
            }
        }
        return choices
    }
}

private extension String {
    var lowercasedFirst: String { prefix(1).lowercased() + dropFirst() }
}
