import SwiftUI
import UIKit
import TipKit
import BetterWorkspaceCore

enum MobileWorkspaceTab: Hashable, CaseIterable, Identifiable {
    case overview, projects, work, ideas, capture
    var id: Self { self }
    var title: String {
        switch self {
        case .overview: "Overview"
        case .projects: "Projects"
        case .work: "Work"
        case .ideas: "Ideas"
        case .capture: "Ingest"
        }
    }
    var symbolName: String {
        switch self {
        case .overview: "rectangle.3.group"
        case .projects: "square.stack.3d.up"
        case .work: "checklist"
        case .ideas: "lightbulb"
        case .capture: "tray.and.arrow.down"
        }
    }
}

struct MobileWorkspaceRootView: View {
    @Environment(MobileWorkspaceModel.self) private var model
    @Binding var selectedTab: MobileWorkspaceTab
    let captureRequest: Int
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var sidebarVisibility: NavigationSplitViewVisibility = .all
    /// Each section's navigation, held here so the iPad sidebar — which rebuilds the
    /// detail when the section changes — returns to the page you left, as tabs do.
    @Environment(MobileModel.self) private var captureModel
    private var tabs: [MobileWorkspaceTab] {
        MobileWorkspaceTab.allCases.filter { !model.isSample || $0 != .capture }
    }
    @State private var paths: [MobileWorkspaceTab: NavigationPath] = [:]
    private func path(_ tab: MobileWorkspaceTab) -> Binding<NavigationPath> {
        // A section being swapped out writes back an empty path as it is torn down;
        // only the section on screen may change its own navigation.
        Binding(get: { paths[tab] ?? NavigationPath() }, set: { if tab == selectedTab { paths[tab] = $0 } })
    }
    var body: some View {
        Group {
        if UIDevice.current.userInterfaceIdiom == .pad && horizontalSizeClass == .regular {
            NavigationSplitView(columnVisibility: $sidebarVisibility) {
                // Choosing the section already shown returns to its top, as a tab does.
                List(selection: Binding<MobileWorkspaceTab?>(get: { selectedTab }, set: { tab in
                    guard let tab else { return }
                    if tab == selectedTab { paths[tab] = NavigationPath() } else { selectedTab = tab }
                })) {
                    ForEach(tabs) { tab in
                        Label(tab.title, systemImage: tab.symbolName).tag(tab)
                            .accessibilityIdentifier("workspace-sidebar-\(tab.title.lowercased())")
                    }
                }.navigationTitle("Better Workspace")
            } detail: { content(selectedTab) }
            .navigationSplitViewStyle(.balanced)
        } else {
            TabView(selection: $selectedTab) {
                ForEach(tabs) { tab in
                    content(tab).tabItem { Label(tab.title, systemImage: tab.symbolName) }.tag(tab)
                }
            }
        }
        }
        .onChange(of: model.widgetNavigation) { _, _ in applyWidgetNavigation() }
        .onChange(of: model.snapshot.fetchedAt) { _, _ in applyWidgetNavigation() }
        .task { applyWidgetNavigation() }
    }
    private func applyWidgetNavigation() {
        guard let route = model.widgetNavigation else { return }
        if model.syncState == .loading {
            switch route { case .project, .task, .idea: return; default: break }
        }
        var navigation = NavigationPath()
        switch route {
        case .project(let id):
            selectedTab = .projects
            if let project = model.snapshot.entries.first(where: { $0.parentPath == "Projects" && ($0.projectDetails?.projectID == id || $0.projectDetails?.serviceID == id || $0.path == id) }) { navigation.append(project) }
            else { navigation.append(MobileWidgetDestination.unavailable("This pinned project is no longer available.")) }
        case .task(let id):
            selectedTab = .work
            if let work = model.snapshot.workItems.first(where: { $0.id == id }) { navigation.append(work) }
            else { navigation.append(MobileWidgetDestination.unavailable("This work item is no longer available.")) }
        case .idea(let path):
            selectedTab = .ideas
            if let idea = model.snapshot.ideas.first(where: { $0.path == path }) { navigation.append(idea) }
            else { navigation.append(MobileWidgetDestination.unavailable("This idea is no longer available.")) }
        case .review(let id): selectedTab = .overview; model.widgetReviewItemID = id.isEmpty ? nil : id; navigation.append(MobileWidgetDestination.review)
        case .capture(let name): selectedTab = .capture; captureModel.widgetCaptureName = name.isEmpty ? nil : name; captureModel.refreshRecent()
        case .charts(let mode): selectedTab = .overview; navigation.append(MobileWidgetDestination.charts(mode))
        case .attention(let category): selectedTab = .overview; navigation.append(MobileWidgetDestination.attention(category))
        case .overview: selectedTab = .overview
        }
        paths[selectedTab] = navigation
        model.widgetNavigation = nil
    }
    @ViewBuilder private func content(_ tab: MobileWorkspaceTab) -> some View {
        switch tab {
        case .overview: MobileOverviewView(path: path(.overview))
        case .projects: MobileProjectsView(path: path(.projects))
        case .work: WorkItemsMobileView(path: path(.work))
        case .ideas: NavigationStack(path: path(.ideas)) { IdeasMobileView().mobilePlanningDestinations() }
        case .capture: CaptureScreen(captureRequest: captureRequest)
        }
    }
}

private enum MobileOverviewDestination: Hashable { case projects, ideas, workspace, tags, analytics }

private struct MobileOverviewView: View {
    @Environment(MobileWorkspaceModel.self) private var model
    @Binding var path: NavigationPath
    @State private var newIdea = false
    @State private var showsSample = false
    @State private var showsCustomization = false
    @State private var layoutValue = ""
    @State private var layoutLoaded = false
    private let supportedSections: [OverviewSectionID] = [.nextAction, .attention, .review, .focus, .projects, .ideas, .pending]
    private var visibleSections: [OverviewSectionID] {
        OverviewLayout.load(layoutValue, defaultOrder: supportedSections).visible(in: supportedSections)
    }
    private var projects: [MobileWorkspaceEntry] {
        model.entries(in: "Projects").filter(\.isDirectory).sorted { lhs, rhs in
            let left = model.workItems(forProjectPath: lhs.path).first { $0.stage != .later }
            let right = model.workItems(forProjectPath: rhs.path).first { $0.stage != .later }
            if let left, let right { return MobileWorkspaceModel.workComesFirst(left, right) }
            if (left != nil) != (right != nil) { return left != nil }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }
    var body: some View {
        NavigationStack(path: $path) {
            List {
                // Transfer failures and queued changes remain visible even when
                // Overview sections are hidden or reordered.
                Section { SyncNotice(state: model.syncState, pendingIntentCount: model.pendingIntentCount) }
                ForEach(visibleSections) { section in
                switch section {
                case .nextAction:
                Section("Next up") {
                    if let item = model.recommendedWorkItem {
                        NavigationLink(value: item) { MobileWorkRow(item: item) }
                            .accessibilityIdentifier("overview-next-work")
                    } else if model.syncState == .loading {
                        MobileLoadingState(title: "Loading your workspace…")
                    } else {
                        Text("Choose the next step for a project, or record a new idea.")
                            .foregroundStyle(.secondary)
                    }
                    let progress = WorkProgressCounts(model.filteredWorkItems())
                    if progress.total > 0 {
                        WorkProgressStrip(counts: progress).accessibilityIdentifier("overview-progress")
                    }
                }
                case .attention:
                if !model.projectChoices.filter({ $0.projectDetails?.needsSetup == true }).isEmpty || model.filteredIdeas().contains(where: { $0.planning?.needsSetup == true }) {
                    Section("Needs Attention") {
                        ForEach(model.projectChoices.filter { $0.projectDetails?.needsSetup == true }.prefix(3)) { project in
                            NavigationLink(value: project) { MobileProjectRow(project: project) }
                        }
                        ForEach(model.filteredIdeas().filter { $0.planning?.needsSetup == true }.sorted(by: IdeaRanking.comesFirst).prefix(3)) { idea in
                            NavigationLink(value: idea) { MobileIdeaRow(idea: idea) }
                        }
                        NavigationLink("All ideas", value: MobileOverviewDestination.ideas)
                    }
                }
                case .review: MobileOverviewInboxSection()
                case .focus: MobileOverviewFocusSection(path: $path)
                case .projects:
                Section("Projects to move forward") {
                    ForEach(projects.prefix(3)) { project in
                        NavigationLink(value: project) { MobileProjectRow(project: project) }
                    }
                    NavigationLink("All projects", value: MobileOverviewDestination.projects)
                        .accessibilityIdentifier("overview-all-projects")
                }
                case .ideas:
                Section("Ideas to bring forward") {
                    ForEach(model.filteredIdeas().sorted(by: IdeaRanking.comesFirst).prefix(3)) { idea in
                        NavigationLink(value: idea) { MobileIdeaRow(idea: idea) }
                    }
                    Button("Record an idea", systemImage: "plus") { newIdea = true }
                }
                case .pending: MobilePlanningStatusSection()
                default: EmptyView()
                }
                }
                if visibleSections.isEmpty { Text("Choose sections with Customize Overview in the menu.").foregroundStyle(.secondary) }
            }
            .navigationTitle("Overview")
            .mobilePlanningDestinations()
            .navigationDestination(for: MobileOverviewDestination.self) { destination in
                switch destination {
                case .projects: MobileProjectsList()
                case .ideas: IdeasMobileView()
                case .workspace: WorkspaceIndexView()
                case .tags: TagCatalogView()
                case .analytics: AnalyticsMobileView()
                }
            }
            .toolbar {
                MobileRefreshToolbar()
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Customize Overview", systemImage: "slider.horizontal.3") { showsCustomization = true }
                            .accessibilityIdentifier("overview.customize")
                        if !model.isSample {
                            Button("Welcome & capabilities", systemImage: "questionmark.circle") {
                                NotificationCenter.default.post(name: .init("BetterWorkspace.ShowWelcome"), object: nil)
                            }
                        }
                        NavigationLink("Browse folders", value: MobileOverviewDestination.workspace)
                        NavigationLink("Filter by tags", value: MobileOverviewDestination.tags)
                        NavigationLink("Analytics", value: MobileOverviewDestination.analytics)
                        NavigationLink { WorkspacePrivacyView() } label: { Text("Privacy & Support") }
                        if !model.isSample {
                            Button("Explore sample workspace") { showsSample = true }
                                .accessibilityIdentifier("workspace.sample.open")
                        }
                    } label: { Image(systemName: "ellipsis.circle") }
                    .accessibilityLabel("More workspace views")
                }
            }
            .task {
                layoutValue = model.overviewDefaults.string(forKey: "overview.layout.connected") ?? ""
                layoutLoaded = true
            }
            .onChange(of: layoutValue) { _, value in
                if layoutLoaded { model.overviewDefaults.set(value, forKey: "overview.layout.connected") }
            }
            .sheet(isPresented: $showsCustomization) { OverviewCustomizationView(encoded: $layoutValue, supported: supportedSections) }
            .sheet(isPresented: $newIdea) { MobileIdeaEditor() }
            .fullScreenCover(isPresented: $showsSample) { MobileSampleWorkspaceView() }
            .refreshable { await model.refresh() }
        }
    }
}

private struct MobileProjectsView: View {
    @Binding var path: NavigationPath
    var body: some View { NavigationStack(path: $path) { MobileProjectsList().mobilePlanningDestinations() } }
}

private struct MobileProjectsList: View {
    @Environment(MobileWorkspaceModel.self) private var model
    @State private var query = ""
    @State private var newProject = false
    private var projects: [MobileWorkspaceEntry] {
        model.entries(in: "Projects").filter { $0.isDirectory && (query.isEmpty || $0.name.localizedCaseInsensitiveContains(query)) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    var body: some View {
        List {
            if projects.isEmpty, model.syncState == .loading { MobileLoadingState(title: "Loading projects…") }
            else if projects.isEmpty { Text("Create a project to start organizing its work.").foregroundStyle(.secondary) }
            ForEach(projects) { project in
                NavigationLink(value: project) { MobileProjectRow(project: project) }
                    .accessibilityIdentifier("mobile-project-\(project.path)")
            }
        }
        .navigationTitle("Projects")
        .searchable(text: $query, prompt: "Find a project")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { Button("New project", systemImage: "plus") { newProject = true } }
        }
        .sheet(isPresented: $newProject) { MobileIdeaEditor(operation: .createProject) }
        .refreshable { await model.refresh() }
    }
}

struct MobileProjectRow: View {
    @Environment(MobileWorkspaceModel.self) private var model
    let project: MobileWorkspaceEntry
    var body: some View {
        let all = model.allWorkItems(forProjectPath: project.path)
        VStack(alignment: .leading, spacing: 5) {
            Text(project.name).font(.headline)
            if project.projectDetails?.needsSetup == true { Label("New project created · add details and score", systemImage: "sparkles").font(.caption).foregroundStyle(.orange) }
            if let score = project.projectDetails?.rankingScore { Text("Score \(Int(score.rounded()))/100").font(.caption).foregroundStyle(.secondary) }
            // The same next action the project page and the Mac show.
            if let next = WorkItemRecommendation.nextMobileAction(in: model.workItems(forProjectPath: project.path), allItems: model.snapshot.workItems) {
                Text(MarkdownInline.attributed(next.title)).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
            } else if !all.isEmpty, all.allSatisfy({ $0.status == .completed }) {
                Text("All caught up").font(.subheadline).foregroundStyle(.secondary)
            }
            let progress = WorkProgressCounts(all)
            if progress.total > 0 {
                WorkProgressStrip(counts: progress, showsCaption: false, height: 5)
                    .accessibilityIdentifier("project-row-progress")
            }
        }.padding(.vertical, 4)
            .modifier(MobileProjectDeletionActions(project: project))
    }
}

/// What to work on next, first; then what is active, what it adds up to, and — folded
/// away — what is done. Each item appears once.
struct MobileProjectDetailView: View {
    @Environment(MobileWorkspaceModel.self) private var model
    let project: MobileWorkspaceEntry
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingDelete = false
    @State private var creatingKind: WorkItemKind?
    @State private var editingProject = false
    @State private var showsAllActive = false
    @State private var showsCompleted = false
    private var current: MobileWorkspaceEntry { model.snapshot.entries.first { $0.id == project.id } ?? project }
    private var open: [MobileWorkItem] { model.workItems(forProjectPath: current.path) }
    private var all: [MobileWorkItem] { model.allWorkItems(forProjectPath: current.path) }
    private var next: MobileWorkItem? { WorkItemRecommendation.nextMobileAction(in: open, allItems: model.snapshot.workItems) }
    private static let visibleActive = 5

    var body: some View {
        List {
            Section {
                if current.projectDetails?.needsSetup == true { Label("New project created", systemImage: "sparkles") }
                Button("Details & scoring", systemImage: "slider.horizontal.3") { editingProject = true }
                    .accessibilityIdentifier("project.score.edit")
                if let score = current.projectDetails?.rankingScore { LabeledContent("Your score", value: "\(Int(score.rounded()))/100") }
            }
            MobileProjectPreviewsSection(project: current)
            upNext
            activeSection
            groupsSection
            completedSection
            aboutSection
            // Charts and an assessment of nothing are empty screens; offered once there is work.
            if !all.isEmpty { Section {
                NavigationLink { MobileProjectInsightsView(project: current) } label: {
                    Label("Insights", systemImage: "chart.xyaxis.line")
                }.accessibilityIdentifier("project.insights.open")
                NavigationLink { MobileProjectAssessmentView(project: current) } label: {
                    Label("Assessment & Ranked Backlog", systemImage: "chart.bar.xaxis")
                }.accessibilityIdentifier("project.assessment.open")
            } }
            MobileTagAssignmentSection(entry: current)
        }
        .navigationTitle(current.name)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    ForEach(WorkItemKind.allCases) { kind in
                        Button("New \(kind.displayName)", systemImage: kind.symbolName) { creatingKind = kind }
                            .accessibilityIdentifier("project-add-\(kind.rawValue)")
                    }
                } label: { Image(systemName: "plus") }
                .accessibilityLabel("Add")
                .accessibilityIdentifier("project-add")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Delete project…", systemImage: "trash", role: .destructive) { confirmingDelete = true }
                } label: { Image(systemName: "ellipsis.circle") }
                .accessibilityLabel("Manage project")
            }
        }
        .alert("Delete project “\(current.name)”?", isPresented: $confirmingDelete) {
            Button("Move entire project to Trash", role: .destructive) { if model.trash(current) { dismiss() } }
            Button("Cancel", role: .cancel) {}
        } message: { Text(MobileProjectDeletionActions.message) }
        .refreshable { await model.refresh() }
        .sheet(item: $creatingKind) { kind in MobileWorkEditor(projectPath: current.path, kind: kind) }
        .sheet(isPresented: $editingProject) { MobileProjectScoreEditor(project: current) }
    }

    private var upNext: some View {
        Section {
            if let next {
                NavigationLink(value: next) { MobileWorkRow(item: next, showsProject: false) }
                    .accessibilityIdentifier("project-next-action")
            } else if all.isEmpty {
                Button("Add the first task", systemImage: "plus") { creatingKind = .task }
            } else if open.isEmpty {
                Label("All caught up", systemImage: "checkmark.circle").foregroundStyle(.secondary)
            } else {
                Text("Nothing is up next. Set a task to Now or Next.").foregroundStyle(.secondary)
            }
            let progress = WorkProgressCounts(all)
            if progress.total > 0 { WorkProgressStrip(counts: progress).accessibilityIdentifier("project-progress") }
        } header: { Text("Up Next") }
    }

    @ViewBuilder private var activeSection: some View {
        let active = open.filter { ($0.kind == .task || $0.kind == .goal) && $0.id != next?.id }
        if !active.isEmpty {
            Section("Active") {
                ForEach(showsAllActive ? active : Array(active.prefix(Self.visibleActive))) { item in
                    NavigationLink(value: item) { MobileWorkRow(item: item, showsProject: false) }
                }
                if active.count > Self.visibleActive {
                    Button(showsAllActive ? "Show fewer" : "Show all \(active.count)") { showsAllActive.toggle() }
                }
            }
        }
    }

    @ViewBuilder private var groupsSection: some View {
        let groups = open.filter { $0.kind == .feature || $0.kind == .milestone }
        if !groups.isEmpty {
            Section("Features & Milestones") {
                ForEach(groups) { group in
                    NavigationLink(value: group) {
                        let members = all.filter { ($0.featureIDs ?? []).contains(group.id) || ($0.milestoneIDs ?? []).contains(group.id) }
                        HStack {
                            Label { Text(MarkdownInline.attributed(group.title)) } icon: { Image(systemName: group.kind.symbolName) }
                            Spacer()
                            if !members.isEmpty {
                                Text("\(members.filter { $0.status == .completed }.count)/\(members.count)")
                                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder private var completedSection: some View {
        let done = all.filter { $0.status == .completed }.sorted { ($0.completedAt ?? .distantPast) > ($1.completedAt ?? .distantPast) }
        if !done.isEmpty {
            Section {
                DisclosureGroup("Completed · \(done.count)", isExpanded: $showsCompleted) {
                    ForEach(done.prefix(50)) { item in NavigationLink(value: item) { MobileWorkRow(item: item, showsProject: false) } }
                }
                .accessibilityIdentifier("project-completed")
            }
        }
    }

    @ViewBuilder private var aboutSection: some View {
        let details = current.projectDetails
        let hasMore = details?.status != nil || details?.phase != nil || details?.githubURL != nil || details?.websiteURL != nil
        if details?.oneLiner != nil || !(details?.summary ?? "").isEmpty || hasMore {
            Section("About") {
                if let line = details?.oneLiner { Text(MarkdownInline.attributed(line)) }
                if let summary = details?.summary, !summary.isEmpty { MarkdownView(text: summary).foregroundStyle(.secondary) }
                if hasMore {
                    DisclosureGroup("Details") {
                        if let status = details?.status { LabeledContent("Status", value: status) }
                        if let phase = details?.phase { LabeledContent("Phase", value: phase) }
                        if let github = details?.githubURL, let url = URL(string: github) { Link("GitHub", destination: url) }
                        if let website = details?.websiteURL, let url = URL(string: website) { Link("Website", destination: url) }
                    }
                }
            }
        }
    }
}

struct MobileWorkRow: View {
    @Environment(MobileWorkspaceModel.self) private var model
    let item: MobileWorkItem
    /// Inside a project page its name is a given.
    var showsProject = true
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(MarkdownInline.attributed(item.title)).font(.headline)
                .foregroundStyle(item.status == .completed ? .secondary : .primary)
            Text([item.status == .completed ? "Done" : item.stage.displayName,
                  showsProject ? item.projectPath.map { model.projectName(for: $0) } : nil].compactMap { $0 }.joined(separator: " · "))
                .font(.caption).foregroundStyle(.secondary)
        }.padding(.vertical, 3)
            .modifier(MobileWorkDeletionActions(item: item))
    }
}

private struct WorkItemsMobileView: View {
    @Environment(MobileWorkspaceModel.self) private var model
    @State private var newWork = false
    @State private var showCompleted = false
    @State private var pendingDelete: MobileWorkItem?
    @State private var query = ""
    @Binding var path: NavigationPath

    /// Thousands of records are normal here, so the list is computed once per render
    /// and searchable; a search also reaches completed work.
    private var visible: [MobileWorkItem] {
        let items = model.filteredWorkItems()
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return items }
        return items.filter { item in
            item.title.localizedCaseInsensitiveContains(query)
                || item.projectPath.map { model.projectName(for: $0).localizedCaseInsensitiveContains(query) } == true
        }
    }

    var body: some View {
        let visible = visible
        let attention = visible.filter(\.needsAttention).sorted(by: MobileWorkspaceModel.workComesFirst)
        let open = visible.filter { $0.status != .completed && $0.needsAttention == false }
        let completed = visible.filter { $0.status == .completed }
        NavigationStack(path: $path) {
            List {
                MobilePlanningStatusSection()
                let progress = WorkProgressCounts(visible)
                if progress.total > 0 {
                    Section { WorkProgressStrip(counts: progress).accessibilityIdentifier("work-progress") }
                }
                // Features and milestones with no project yet: placed with one tap.
                if attention.isEmpty == false {
                    Section {
                        ForEach(attention) { item in attentionRow(item) }
                    } header: {
                        Label("Needs Attention", systemImage: "exclamationmark.circle").foregroundStyle(.orange)
                            .accessibilityIdentifier("work-needs-attention")
                    }
                }
                ForEach(WorkItemStage.allCases) { stage in
                    let items = open.filter { $0.stage == stage }.sorted(by: MobileWorkspaceModel.workComesFirst)
                    if !items.isEmpty {
                        Section(stage.displayName) {
                            ForEach(items) { item in row(item) }
                        }
                    }
                }
                if open.isEmpty {
                    if model.syncState == .loading {
                        MobileLoadingState(title: "Loading work…")
                    } else if !query.isEmpty {
                        Text(completed.isEmpty ? "No work matches “\(query)”." : "Nothing open matches “\(query)”.").foregroundStyle(.secondary)
                    } else {
                        Text("Add work, then choose what to do now or next.").foregroundStyle(.secondary)
                    }
                }
                if !completed.isEmpty {
                    DisclosureGroup("Completed (\(completed.count))", isExpanded: Binding(
                        get: { showCompleted || !query.isEmpty }, set: { showCompleted = $0 })) {
                        ForEach(completed) { item in row(item) }
                    }
                }
            }
            .navigationTitle("Work")
            // Always shown: with thousands of records a drawer that hides on scroll
            // leaves no way to search without scrolling back to the top.
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Find work")
            .confirmationDialog("Delete “\(pendingDelete?.title ?? "")”?", isPresented: Binding(
                get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }), titleVisibility: .visible) {
                Button("Delete", role: .destructive) { if let item = pendingDelete { model.trash(item) }; pendingDelete = nil }
            } message: {
                Text("Are you sure? Your Mac moves it to its recoverable Trash when online. Linked Notion pages stay in Notion.")
            }
            .mobilePlanningDestinations()
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("New work", systemImage: "plus") { newWork = true } } }
            .sheet(isPresented: $newWork) { MobileWorkEditor() }
            .refreshable { await model.refresh() }
        }
    }
}

extension WorkItemsMobileView {
    /// The usual row, with its project one menu away.
    private func attentionRow(_ item: MobileWorkItem) -> some View {
        HStack {
            row(item)
            Menu {
                ForEach(model.projectChoices) { project in
                    Button(project.name) {
                        var links = item.links; links.projectPath = project.path
                        model.setLinks(links, for: item)
                    }
                }
            } label: {
                Label("Choose project", systemImage: "folder.badge.plus").labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            .accessibilityIdentifier("work-choose-project")
        }
    }

    /// Swipe right to complete or reopen, left to delete: the same actions as the
    /// detail screen, without opening it.
    private func row(_ item: MobileWorkItem) -> some View {
        NavigationLink(value: item) { MobileWorkRow(item: item) }
            .swipeActions(edge: .leading) {
                Button(item.status == .completed ? "Reopen" : "Complete",
                       systemImage: item.status == .completed ? "arrow.uturn.backward" : "checkmark") {
                    model.toggleCompletion(of: item)
                }.tint(item.status == .completed ? .orange : .green)
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                Button("Delete", systemImage: "trash") { pendingDelete = item }.tint(.red)
            }
    }
}

private struct IdeasMobileView: View {
    @Environment(MobileWorkspaceModel.self) private var model
    @State private var query = ""
    @State private var newIdea = false
    @State private var deletingIdea: MobileIdea?
    var body: some View {
        List {
            MobilePlanningStatusSection()
            let activity = WeeklyCounts(dates: model.filteredIdeas().compactMap(\.modifiedAt))
            if activity.total > 0, query.isEmpty {
                Section {
                    WeeklyActivityChart(counts: activity, title: "Ideas updated, last 8 weeks", color: .yellow)
                        .accessibilityIdentifier("ideas-activity")
                }
            }
            ForEach(model.filteredIdeas().filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) }.sorted(by: IdeaRanking.comesFirst)) { idea in
                NavigationLink(value: idea) { MobileIdeaRow(idea: idea) }
                    .accessibilityIdentifier("mobile-idea-\(idea.path)")
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button("Delete", systemImage: "trash", role: .destructive) { deletingIdea = idea }
                    }
            }
            if model.filteredIdeas().isEmpty, model.syncState == .loading { MobileLoadingState(title: "Loading ideas…") }
            else if model.filteredIdeas().isEmpty { Text("Record an idea. Add detail now, organize it when you are ready.").foregroundStyle(.secondary) }
        }
        .navigationTitle("Ideas")
        .confirmationDialog("Delete idea “\(deletingIdea?.title ?? "")”?", isPresented: Binding(
            get: { deletingIdea != nil }, set: { if !$0 { deletingIdea = nil } }), titleVisibility: .visible) {
            Button("Move to Trash", role: .destructive) { if let idea = deletingIdea { model.trash(idea) }; deletingIdea = nil }
            Button("Cancel", role: .cancel) { deletingIdea = nil }
        } message: { Text("The idea and any files inside its folder move to your Mac’s recoverable Trash when online.") }
        .searchable(text: $query, prompt: "Find an idea")
        .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("New idea", systemImage: "plus") { newIdea = true } } }
        .sheet(isPresented: $newIdea) { MobileIdeaEditor() }
        .refreshable { await model.refresh() }
    }
}

extension View {
    func mobilePlanningDestinations() -> some View {
        self.navigationDestination(for: MobileWidgetDestination.self) { MobileWidgetDestinationView(destination: $0) }
            .navigationDestination(for: MobileWorkItem.self) { MobileWorkItemDetailView(item: $0) }
            .navigationDestination(for: MobileIdea.self) { MobileIdeaDetailView(idea: $0) }
            .navigationDestination(for: MobileWorkspaceEntry.self) { entry in
                if entry.parentPath == "Projects" { MobileProjectDetailView(project: entry) }
                else if entry.isDirectory { FolderContentsView(parentPath: entry.path, title: entry.name) }
                else { WorkspaceEntryDetail(entry: entry) }
            }
    }
}

private struct AnalyticsMobileView: View {
    @Environment(MobileWorkspaceModel.self) private var model
    private var items: [MobileWorkspaceEntry] { model.entries(in: WorkspaceArea.analytics.directoryName) }
    private var sources: [MobileWorkspaceEntry] { items.filter(\.isDirectory) }
    private var exports: [MobileWorkspaceEntry] { items.filter { $0.isDirectory == false } }

    var body: some View {
        List {
            Section { SyncNotice(state: model.syncState, pendingIntentCount: model.pendingIntentCount) }
            Section("At a glance") {
                LabeledContent("Data sources", value: "\(sources.count)")
                LabeledContent("Loose exports", value: "\(exports.count)")
                LabeledContent("Last updated", value: items.compactMap(\.modifiedAt).max()?.formatted(.relative(presentation: .named)) ?? "—")
            }
            if sources.isEmpty == false { Section("Data sources") { ForEach(sources) { AnalyticsRow(entry: $0) } } }
            if exports.isEmpty == false { Section("Unsorted exports") { ForEach(exports) { AnalyticsRow(entry: $0) } } }
            if items.isEmpty, model.syncState == .loading {
                MobileLoadingState(title: "Loading analytics…")
            } else if items.isEmpty {
                ContentUnavailableView("No analytics yet", systemImage: "chart.xyaxis.line",
                                       description: Text("Add an analytics source or export on your Mac to see it here."))
                    .listRowBackground(Color.clear)
            }
        }
        .navigationTitle("Analytics")
    }
}

private struct AnalyticsRow: View {
    @Environment(MobileWorkspaceModel.self) private var model
    let entry: MobileWorkspaceEntry
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: entry.isDirectory ? "folder.fill" : "doc.text")
                .foregroundStyle(entry.isDirectory ? Color.accentColor : Color.secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.name)
                Text(entry.modifiedAt.map { "Updated \($0.formatted(.relative(presentation: .named)))" } ?? "No update date")
                    .font(.caption).foregroundStyle(.secondary)
                TagPills(tags: model.tags(for: entry.tagIDs))
            }
        }
    }
}

struct MobileIdeaRow: View {
    @Environment(MobileWorkspaceModel.self) private var model
    let idea: MobileIdea

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if idea.planning?.needsSetup == true { Label("Set priority & score", systemImage: "sparkles").font(.caption).foregroundStyle(.orange) }
            if let planning = idea.planning {
                Text("Priority \(planning.priority)/5" + (planning.potential.map { " · Potential " + $0.title } ?? "") + (planning.score(preferences: idea.scoringPreferences ?? .init()).projectScore.map { " · \(Int($0.rounded()))/100" } ?? "")).font(.caption).foregroundStyle(.secondary)
            }
            Text(MarkdownInline.attributed(idea.title))
            if let description = idea.description, !description.isEmpty {
                Text(MarkdownInline.summary(description)).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
            }
            TagPills(tags: model.tags(for: idea.tagIDs))
        }.modifier(MobileIdeaDeletionActions(idea: idea))
    }
}

struct MobileRefreshToolbar: ToolbarContent {
    var body: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) { MobileRefreshButton() }
    }
}

struct MobileRefreshButton: View {
    @Environment(MobileWorkspaceModel.self) private var model
    var body: some View {
        Button { Task { await model.refresh() } } label: { Image(systemName: "arrow.clockwise") }
            .accessibilityLabel("Refresh workspace index")
            .accessibilityValue(syncDescription)
    }
    private var syncDescription: String {
        let state: String
        switch model.syncState {
        // To the second, so two refreshes within a minute can be told apart.
        case .ready(let date): state = "Synced \(date.formatted(date: .numeric, time: .standard))"
        case .cached(_, let reason): state = "Offline. " + reason
        case .unavailable(let reason): state = reason
        case .loading: state = "Loading"
        }
        // Device tests wait on this to know a change has left the phone.
        var value = model.pendingIntentCount > 0 ? state + " · \(model.pendingIntentCount) waiting to send" : state
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "BWTestMobilePlanning") || UserDefaults.standard.bool(forKey: "BWShowRefreshCount") {
            value += " · refreshes \(model.refreshRequests)" + (model.refreshing ? " · refreshing" : "")
        }
        #endif
        return value
    }

}

private struct WorkspaceIndexView: View {
    @Environment(MobileWorkspaceModel.self) private var model

    var body: some View {
        FolderContentsView(parentPath: nil, title: "Workspace")
            .task { MobileWorkspaceGuidance.viewedBrowse.sendDonation() }
    }
}

private struct FolderContentsView: View {
    @Environment(MobileWorkspaceModel.self) private var model
    let parentPath: String?
    let title: String

    private var entries: [MobileWorkspaceEntry] {
        model.filtered(model.snapshot.entries.filter { $0.parentPath == parentPath })
    }

    var body: some View {
        List {
            Section {
                SyncNotice(state: model.syncState, pendingIntentCount: model.pendingIntentCount)
            }

            if model.selectedTagIDs.isEmpty == false {
                Section("Filtering by tags") { TagFilterStrip() }
            }

            if entries.isEmpty, model.syncState == .loading {
                MobileLoadingState(title: "Loading…")
            } else if entries.isEmpty {
                ContentUnavailableView("No items", systemImage: "folder",
                                       description: Text(emptyDescription))
                    .listRowBackground(Color.clear)
            } else {
                Section {
                    ForEach(entries) { entry in
                        NavigationLink(value: entry) {
                            WorkspaceEntryRow(entry: entry)
                        }
                        // A stable row identifier lets device tests tap the actual
                        // navigation control, rather than an un-hittable Text child
                        // whose label happens to match the folder name.
                        .accessibilityIdentifier("workspace-entry-\(entry.path)")
                        .modifier(MobileEntryDeletionActions(entry: entry))
                    }
                }
            }
        }
        .navigationTitle(title)
    }

    private var emptyDescription: String {
        if model.selectedTagIDs.isEmpty == false { return "No items match these tags." }
        if case .unavailable = model.syncState {
            return "Your saved folders will appear when syncing resumes."
        }
        return "This folder has no synced items yet."
    }
}

private struct WorkspaceEntryRow: View {
    @Environment(MobileWorkspaceModel.self) private var model
    let entry: MobileWorkspaceEntry

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: entry.isDirectory ? "folder.fill" : "doc")
                .foregroundStyle(entry.isDirectory ? Color.accentColor : Color.secondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.name)
                TagPills(tags: model.tags(for: entry.tagIDs))
            }
        }
    }
}

private struct WorkspaceEntryDetail: View {
    @Environment(MobileWorkspaceModel.self) private var model
    let entry: MobileWorkspaceEntry

    /// The model's copy, not the one captured when this row was pushed.
    ///
    /// `navigationDestination` hands over a value, and that value never changes again —
    /// so applying a tag left the checkmark unticked and the revision stale, and the
    /// screen gave no sign the tap had done anything. People then tap again, which is
    /// how one intended change becomes two queued intents. Falls back to the pushed
    /// value for an entry a refresh has since dropped, so the view still renders.
    private var current: MobileWorkspaceEntry {
        model.snapshot.entries.first { $0.id == entry.id } ?? entry
    }

    var body: some View {
        List {
            Section {
                DisclosureGroup("File location") { Text(current.path).font(.footnote).textSelection(.enabled) }
            }
            MobileTagAssignmentSection(entry: current)
        }
        .navigationTitle(current.name)
        .task {
            MobileWorkspaceGuidance.hasOpenedEntry = true
            MobileWorkspaceGuidance.openedEntry.sendDonation()
        }
    }
}

/// Tags are readable at a glance; assignment controls appear only when requested.
struct MobileTagAssignmentSection: View {
    @Environment(MobileWorkspaceModel.self) private var model
    let entry: MobileWorkspaceEntry
    var body: some View {
        Section("Tags") {
            TagPills(tags: model.tags(for: entry.tagIDs))
            DisclosureGroup("Edit tags") {
                ForEach(model.snapshot.tags) { tag in
                    Button { model.toggle(tagID: tag.id, on: entry) } label: {
                        Label(tag.name, systemImage: entry.tagIDs.contains(tag.id) ? "checkmark.circle.fill" : "circle")
                    }
                    .accessibilityLabel("Toggle tag \(tag.name)")
                    .accessibilityValue(entry.tagIDs.contains(tag.id) ? "Selected" : "Not selected")
                }
            }
        }
    }
}

private struct TagCatalogView: View {
    @Environment(MobileWorkspaceModel.self) private var model

    var body: some View {
        List {
            Section {
                SyncNotice(state: model.syncState, pendingIntentCount: model.pendingIntentCount)
            }
            if model.snapshot.tags.isEmpty, model.syncState == .loading {
                MobileLoadingState(title: "Loading tags…")
            } else if model.snapshot.tags.isEmpty {
                ContentUnavailableView("No tags yet", systemImage: "tag",
                                       description: Text("Tags created on the Mac will appear here."))
                    .listRowBackground(Color.clear)
            } else {
                Section("Filter workspace") {
                    ForEach(model.snapshot.tags) { tag in
                        Button {
                            model.toggleFilter(tag.id)
                        } label: {
                            HStack {
                                Image(systemName: model.selectedTagIDs.contains(tag.id) ? "checkmark.circle.fill" : "circle")
                                Text(tag.name)
                                Spacer()
                                Text("\(model.snapshot.entries.filter { $0.tagIDs.contains(tag.id) }.count)")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .accessibilityLabel("Filter by tag \(tag.name)")
                    }
                }
            }
        }
        .navigationTitle("Tags")
        .task {
            MobileWorkspaceGuidance.hasViewedTags = true
            MobileWorkspaceGuidance.viewedTags.sendDonation()
        }
    }
}

private struct TagFilterStrip: View {
    @Environment(MobileWorkspaceModel.self) private var model

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack {
                ForEach(model.snapshot.tags.filter { model.selectedTagIDs.contains($0.id) }) { tag in
                    Button(tag.name) { model.toggleFilter(tag.id) }
                        .buttonStyle(.bordered)
                }
            }
        }
    }
}

struct TagPills: View {
    let tags: [Tag]

    var body: some View {
        if tags.isEmpty == false {
            HStack(spacing: 4) {
                ForEach(tags.prefix(3)) { tag in
                    Text(tag.name)
                        .font(.caption2)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.quaternary, in: Capsule())
                }
            }
        }
    }
}

/// Says which of three things the list below is: live, the last index this phone
/// received, or nothing at all.  An unreachable CloudKit is an ordinary state here, so
/// it is reported in the same place and the same shape as a successful sync.
struct SyncNotice: View {
    let state: MobileWorkspaceModel.SyncState
    let pendingIntentCount: Int

    var body: some View {
        switch state {
        case .loading:
            // Each list says what it is loading in place of its empty state; a second,
            // generic spinner here would only repeat it.
            EmptyView()
        case .ready:
            if pendingIntentCount > 0 {
                Label("Changes waiting to sync", systemImage: "clock")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        case .cached(let date, _):
            Label("Offline · saved \(date.formatted(.relative(presentation: .named)))", systemImage: "icloud.slash")
                .font(.footnote).foregroundStyle(.secondary)
        case .unavailable:
            Label("Sync unavailable · capture still works", systemImage: "icloud.slash")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }
}

/// Shown instead of an empty state while the first snapshot is still arriving, so an
/// empty list is never read as "nothing synced".
private struct MobileLoadingState: View {
    let title: String

    var body: some View {
        HStack(spacing: 10) {
            ProgressView()
            Text(title).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("mobile-loading")
    }
}
