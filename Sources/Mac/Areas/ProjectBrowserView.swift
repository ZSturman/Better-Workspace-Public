import SwiftUI
import AppKit
import BetterWorkspaceCore

struct ProjectBrowserRow: Identifiable {
    let id: String
    let name: String
    let item: WorkspaceItem?
    let graph: ProjectGraphRecord?
    var values: [String: String]
    var tags: [String]
    /// Built with the row so Decide never has to rebuild every project's candidate.
    var candidate: ProjectPortfolio.Candidate? = nil
    var queryRecord: ProjectQueryRecord {
        var selections = ["tags": tags]
        for key in ["type", "workMode", "currentWork", "nextWork", "blockers"] {
            selections[key] = value(key).components(separatedBy: ", ").filter { !$0.isEmpty }
        }
        return .init(id: id, name: name, values: values, selections: selections)
    }
    func value(_ key: String) -> String { key == "name" ? name : values[key] ?? "" }
}

/// The last rows built, kept for the app's lifetime so coming back to Projects shows
/// them at once while a newer build runs. Memory only: rows are derived from Workspace
/// and Notion content, which is never cached to disk.
enum ProjectBrowserCache {
    static var rows: [ProjectBrowserRow] = []
    static var capabilities: [String: ProjectToolCapability] = [:]
    static var kinds: [String: ProjectKind] = [:]
    /// The build `rows` is complete for; nil while a build has not finished.
    static var key: String?
}

/// Rows after search, filters and sort. Recomputed when one of those changes, never in
/// `body` — a body pass reads it several times.
struct ProjectBrowserVisibleRows {
    var rows: [ProjectBrowserRow] = []
    var groups: [(String, [ProjectBrowserRow])] = []
    var byCandidateID: [String: ProjectBrowserRow] = [:]
}

struct ProjectBrowserBuildProgress: Equatable {
    var phase: String
    var done: Int
    var total: Int
}
struct ProjectBrowserPreferences: Codable, Equatable {
    var query: String?
    var presentation = "table"
    var group = "none"
    var sort = "lastUpdate"
    var ascending = false
    var filters: [String: String] = [:]
    var columns = ["name", "domain", "status", "phase", "type", "tags", "lastUpdate"]
    static let defaultColumns = ["name", "domain", "status", "phase", "type", "tags", "lastUpdate"]
    var propertyFilters: [ProjectPropertyFilter]?
    var matchAny: Bool?
    var activity: ProjectActivityFilter?
    var focusedDomain: String?
    var secondarySort: ProjectSortRule?
    var columnWidths: [String: Double]?
    var collapsed: Set<String> = []
    static func load() -> Self {
        guard let data = TestIsolation.defaults.data(forKey: "projectsBrowser.v2"), var state = try? JSONDecoder().decode(Self.self, from: data) else {
            var migrated = Self()
            if TestIsolation.defaults.data(forKey: ProjectPortfolioPreferences.defaultsKey) != nil {
                let old = ProjectPortfolioPreferences.load()
                migrated.presentation = old.presentation.rawValue == "portfolio" ? "cards" : old.presentation.rawValue; migrated.group = old.group.rawValue
                migrated.sort = old.sort == .modified ? "lastUpdate" : old.sort.rawValue; migrated.ascending = old.sortAscending
                migrated.filters["domain"] = old.domain; migrated.filters["status"] = old.status; migrated.filters["phase"] = old.phase
                if old.onlyRated { migrated.filters["rated"] = "Yes" }
                if let priority = old.priority.value { migrated.filters["priority"] = String(priority) }
                else if old.priority == .untriaged { migrated.filters["priority"] = "Untriaged" }
            }
            migrated.propertyFilters = migrated.filters.map { .init(field: $0.key, values: [$0.value == "Untriaged" ? "Not set" : $0.value]) }
            migrated.filters = [:]
            return migrated
        }
        if state.propertyFilters == nil {
            state.propertyFilters = state.filters.map { .init(field: $0.key, values: [$0.value == "Untriaged" ? "Not set" : $0.value]) }
            state.filters = [:]
        }
        state.columns = state.columns.reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
        if !state.columns.contains("name") { state.columns.insert("name", at: 0) }
        return state
    }
    func save() { if let data = try? JSONEncoder().encode(self) { TestIsolation.defaults.set(data, forKey: "projectsBrowser.v2") } }
}

struct ProjectBrowserView: View {
    @Environment(AppModel.self) private var model
    @State private var preferences = ProjectBrowserPreferences.load()
    @State private var query = ProjectBrowserPreferences.load().query ?? ""
    @State private var showingFilters = false
    @State private var showingUnranked = false
    @State private var savedViews = ProjectSavedView.load()
    @State private var savingView = false
    @State private var savedViewName = ""
    @State private var newProject: ProjectGraphRecord?
    @State private var selection: String?
    @State private var capabilities = ProjectBrowserCache.capabilities
    @State private var kinds = ProjectBrowserCache.kinds
    @State private var cachedRows: [ProjectBrowserRow] = ProjectBrowserCache.rows
    /// False until `cachedRows` has been built once; before then it is empty because it
    /// has not been computed, not because nothing matches.
    @State private var rowsBuilt = ProjectBrowserCache.rows.isEmpty == false
    @State private var rowsGeneration = 0
    @State private var visible = ProjectBrowserVisibleRows()
    @State private var visibleBuilt = false
    /// Non-nil while rows are being rebuilt; the rows on screen stay until it finishes.
    @State private var progress: ProjectBrowserBuildProgress?

    /// Projects not listed yet, or listed but not yet turned into rows.
    private var showsLoading: Bool {
        rows.isEmpty && (model.isAwaitingFirstRead(of: .projects) || (rowsBuilt == false && model.projects().isEmpty == false) || (rowsBuilt && visibleBuilt == false))
    }
    private var buildKey: String { "\(model.revision(ofArea: "Projects"))-\(model.projectViewRevision)-\(model.graphRevision)" }
    private struct VisibleKey: Hashable {
        let domainScope: String?, query: String, rules: [ProjectPropertyFilter], matchAny: Bool, activity: ProjectActivityFilter, secondary: ProjectSortRule?, sort: String, ascending: Bool, group: String, generation: Int
    }
    static let fields: [(String, String)] = [
        ("name", "Name"), ("domain", "Domain"), ("status", "Status"), ("phase", "Phase"), ("type", "Type"), ("tags", "Tags"), ("lastUpdate", "Last Update"),
        ("oneLiner", "One Liner"), ("currentWork", "Current Work"), ("nextWork", "Next Work"), ("blockers", "Blocked By"), ("workMode", "Work Mode"),
        ("completionModel", "Completion Model"), ("maintenanceCadence", "Maintenance Cadence"), ("startedAt", "Started At"),
        ("priority", "Local Priority"), ("score", "Score"), ("coverage", "Rated"), ("assets", "Assets"), ("resources", "Resources"),
        ("collections", "Collections"), ("features", "Features"), ("milestones", "Milestones"), ("tasks", "Tasks"), ("openWork", "Open work items"), ("source", "Source"),
        ("kind", "Kind"), ("summary", "Summary"), ("statusDetail", "Status details"), ("recentWork", "Recent Work"),
        ("effort", "Observed hours"), ("active7d", "Active 7d"), ("lastWorked", "Last worked"), ("consistency", "Consistency"),
        ("personalValue", "Personal value"), ("financialValue", "Financial value"), ("professionalValue", "Professional value"),
        ("learningGrowth", "Learning & growth"), ("strategicValue", "Strategic value"), ("timeExecution", "Time & execution"), ("riskConsequences", "Risk")]
    static let groupFields = ["none", "domain", "status", "phase", "tags", "type", "workMode", "priority"]
    static func title(_ key: String) -> String { key == "rated" ? "Has ratings" : key == "none" ? "No grouping" : fields.first { $0.0 == key }?.1 ?? (key.hasPrefix("notion:") ? String(key.dropFirst(7)) : key) }

    private var allRows: [ProjectBrowserRow] { cachedRows }
    /// Builds rows a chunk at a time, handing the main thread back between chunks so the
    /// window stays usable (switching area cancels this). Nil when cancelled.
    @MainActor private func makeRows() async -> [ProjectBrowserRow]? {
        let scoring = model.scoringPreferences()
        let formatter = ISO8601DateFormatter()
        let local = model.projects()
        let workByPath = Dictionary(grouping: model.workItems.filter { $0.projectPath != nil }, by: { $0.projectPath! })
        let logsByID = Dictionary(grouping: model.workLogs.filter { $0.projectID != nil }, by: { $0.projectID! })
        let knownWorkPaths = Set(model.workItems.map { $0.url.path })
        let representedGraphs = Set(local.compactMap { model.graphProject(for: $0)?.id })
        let logDateFormatter = DateFormatter(); logDateFormatter.locale = Locale(identifier: "en_US_POSIX"); logDateFormatter.dateFormat = "yyyy-MM-dd"
        let notionOnly = model.graphRecords.filter { $0.kind == .projects && !representedGraphs.contains($0.id) && !IdeaProjectBridge.isPotentialRecord($0) && $0.localProjectID == nil && (!$0.local.isEmpty || !$0.remote.isEmpty) && !($0.acknowledgedArchived ?? false) }
        let total = local.count + notionOnly.count
        var rows: [ProjectBrowserRow] = []
        rows.reserveCapacity(total)
        for (index, item) in local.enumerated() {
            if index.isMultiple(of: 20) {
                guard await yieldForBuild(phase: "Updating projects", done: index, total: total) else { return nil }
            }
            var row = makeRow(item, scoring: scoring, formatter: formatter)
            row.candidate = model.portfolioCandidate(for: item, preferences: scoring)
            let path = model.workspaceRelativePath(for: item.url) ?? ""
            let work = (workByPath[path] ?? []) + (workByPath[item.url.path] ?? [])
            addWorkMetrics(work, graph: row.graph, knownPaths: knownWorkPaths, to: &row.values)
            if let watcher = model.projectRecord(for: item)?.watcherID, let logs = logsByID[watcher] {
                let now = Date()
                for days in [7, 30, 90] {
                    let cutoff = logDateFormatter.string(from: Calendar.current.date(byAdding: .day, value: -(days - 1), to: now) ?? now)
                    let today = logDateFormatter.string(from: now)
                    let hours = logs.filter { log in
                        let day = String(log.dateKey.prefix(10))
                        return day >= cutoff && day <= today
                    }.reduce(0) { $0 + max(0, $1.activeMinutes) / 60 }
                    row.values["hours\(days)"] = String(hours)
                }
            }
            rows.append(row)
        }
        for (index, graph) in notionOnly.enumerated() {
            if index.isMultiple(of: 20) {
                guard await yieldForBuild(phase: "Updating Notion projects", done: local.count + index, total: total) else { return nil }
            }
            guard let source = model.graphSource(for: graph) else { continue }
            var values: [String: String] = ["source": "Notion-only"]
            for (key, name) in [("domain", "domain"), ("status", "Status"), ("phase", "Phase"), ("type", "Type"), ("tags", "tags"), ("lastUpdate", "last update at"), ("oneLiner", "one liner"), ("currentWork", "Current Work"), ("nextWork", "Next Work"), ("blockers", "Blocked By"), ("workMode", "Work Mode"), ("completionModel", "Completion Model"), ("maintenanceCadence", "Maintenance Cadence"), ("startedAt", "started at")] {
                values[key] = graph.value(name, source: source).display
            }
            addCounts(graph, to: &values)
            addWorkMetrics([], graph: graph, knownPaths: [], to: &values)
            addNotionProperties(graph, to: &values)
            rows.append(.init(id: graph.id, name: graph.title, item: nil, graph: graph, values: values, tags: values["tags", default: ""].components(separatedBy: ", ").filter { !$0.isEmpty },
                              candidate: notionCandidate(for: graph, preferences: scoring)))
        }
        return rows
    }
    /// Publishes progress and lets queued events (clicks, typing, area switches) run.
    @MainActor private func yieldForBuild(phase: String, done: Int, total: Int) async -> Bool {
        progress = .init(phase: phase, done: done, total: total)
        do { try await Task.sleep(for: .milliseconds(1)) } catch { return false }
        return Task.isCancelled == false
    }
    @MainActor private func makeRow(_ item: WorkspaceItem, scoring: ProjectScoringPreferences, formatter: ISO8601DateFormatter) -> ProjectBrowserRow {
            let metadata = model.projectMetadata(for: item), graph = model.graphProject(for: item)
            let score = model.score(for: item, preferences: scoring)
            let tags = model.tags(for: item).map(\.name)
            var values: [String: String] = [:]
            values["domain"] = metadata.domain ?? ""
            values["status"] = metadata.status ?? ""
            values["phase"] = metadata.phase ?? ""
            values["type"] = metadata.projectType ?? ""
            values["tags"] = tags.joined(separator: ", ")
            values["lastUpdate"] = (metadata.lastUpdateAt ?? item.contentModifiedAt).map { formatter.string(from: $0) } ?? ""
            values["oneLiner"] = model.projectDescription(for: item)?.oneLiner ?? ""
            values["currentWork"] = metadata.currentWork.joined(separator: ", ")
            values["nextWork"] = metadata.nextWork.joined(separator: ", ")
            values["blockers"] = metadata.blockers.joined(separator: ", ")
            values["workMode"] = metadata.workModes.joined(separator: ", ")
            values["completionModel"] = metadata.completionModel ?? ""
            values["maintenanceCadence"] = metadata.maintenanceCadence ?? ""
            values["startedAt"] = metadata.startedAt.map { ISO8601DateFormatter().string(from: $0) } ?? ""
            values["priority"] = metadata.portfolioPriority.map { String($0) } ?? ""
            values["score"] = score?.projectScore.map { String(Int($0.rounded())) } ?? ""
            values["rated"] = (score?.coverage ?? 0) > 0 ? "Yes" : "No"
            values["coverage"] = score.map { String(Int($0.coverage * 100)) + "%" } ?? ""
            values["source"] = graph == nil ? "Local" : "Local + Notion"
            values["summary"] = model.projectDescription(for: item)?.summary ?? ""
            values["statusDetail"] = metadata.statusDetail ?? ""
            values["recentWork"] = metadata.recentWork.joined(separator: ", ")
            values["kind"] = kinds[item.id]?.rawValue ?? ""
            for column in ProjectColumn.measuredColumns {
                if let dimension = column.dimension, let measurement = model.measurements(for: item)?.measurement(dimension) {
                    values["help:" + column.rawValue] = [measurement.isProvisional ? "Provisional observation" : nil, measurement.explanation].compactMap { $0 }.joined(separator: " · ")
                    let rawValue = column == .effort ? measurement.rawValue : measurement.rawValue ?? measurement.value
                    if measurement.isKnown, let raw = rawValue {
                        values["provisional:" + column.rawValue] = measurement.isProvisional ? "true" : "false"
                        values[column.rawValue] = (measurement.isLowerBound ? "≥ " : "") + String(format: "%.1f", raw) + (measurement.isProvisional ? "°" : "")
                        values["sort:" + column.rawValue] = String(raw)
                        if measurement.isLowerBound { values["bound:" + column.rawValue] = "lower" }
                    }
                }
            }
            for group in MetricGroup.allGroups { if let value = score?.groupScore(for: group) { values[group.id] = String(Int(value.rounded())) } }
            values["canExplain"] = capabilities[item.id]?.canExplain == true ? "true" : "false"
            values["canFlow"] = capabilities[item.id]?.canFlowReview == true ? "true" : "false"
            if let graph { addCounts(graph, to: &values); addNotionProperties(graph, to: &values) }
            return .init(id: item.id, name: graph.flatMap { $0.local.isEmpty ? nil : $0.title } ?? item.displayTitle, item: item, graph: graph, values: values, tags: tags)
    }
    private func addWorkMetrics(_ work: [WorkItem], graph: ProjectGraphRecord?, knownPaths: Set<String>, to values: inout [String: String]) {
        var open = work.filter { $0.status != .completed }.count
        var completed = work.count - open
        if let graph {
            for record in model.graphRelated(to: graph) where [.tasks, .features, .milestones].contains(record.kind) {
                if let path = record.localPath, knownPaths.contains(path) { continue }
                guard let source = model.graphSource(for: record) else { continue }
                let status = ProjectViewQuery.normalize(record.value("Status", source: source).display)
                if ["done", "complete", "completed"].contains(status) || record.value("Complete", source: source)["checkbox"].bool { completed += 1 }
                else if !record.remoteArchived && record.locallyDeleted != true { open += 1 }
            }
        }
        if !model.isAwaitingWorkItems || graph != nil {
            values["openWork"] = String(open); values["completedWork"] = String(completed)
        }
    }
    private func addNotionProperties(_ project: ProjectGraphRecord, to values: inout [String: String]) {
        guard let source = model.graphSource(for: project) else { return }
        for (name, schema) in source.schema.object {
            let value = project.value(name, source: source), type = schema["type"].string ?? ""
            if type == "relation" { values["notion:" + name] = "\(value["relation"].array.count) related" }
            else if type == "files" { values["notion:" + name] = "\(value["files"].array.count) files" }
            else { values["notion:" + name] = value.display }
        }
    }
    private func addCounts(_ project: ProjectGraphRecord, to values: inout [String: String]) {
        let related = model.graphRelated(to: project)
        for kind in [ProjectEntityKind.assets, .resources, .collections, .tasks, .features, .milestones] {
            values[kind.rawValue] = String(related.filter { $0.kind == kind }.count)
        }
    }
    private func notionCandidate(for project: ProjectGraphRecord, preferences: ProjectScoringPreferences) -> ProjectPortfolio.Candidate? {
        guard let source = model.graphSource(for: project), let page = project.notionPage(source: source) else { return nil }
        let metadata = ProjectMetadataImport.values(from: page).metadata
        let ratings = MetricDefinition.all.reduce(into: [String: Int]()) { result, metric in if let raw = Double(project.value(metric.displayName, source: source).display) { result[metric.id] = Int(raw) } }
        let score = ProjectScore(ratings: ratings, enabledMetricIDs: preferences.enabledMetricIDs, enabledGroups: MetricGroup.allGroups.filter { preferences.enabledGroupIDs.contains($0.id) }, groupWeights: preferences.groupWeights)
        let work = model.graphRelated(to: project).filter { $0.kind == .tasks }.compactMap { record -> WorkItem? in
            guard let source = model.graphSource(for: record), let pageID = record.pageID, let url = URL(string: "https://notion.so/" + pageID),
                  let stage = WorkItemStage(rawValue: record.value("Work Stage", source: source).display.lowercased()) else { return nil }
            let status = record.value("Status", source: source).display.lowercased()
            guard !["done", "complete", "completed"].contains(status), !record.value("Complete", source: source)["checkbox"].bool else { return nil }
            return WorkItem(id: record.id, kind: .task, title: record.title, stage: stage, priority: WorkItemPriority(rawValue: record.value("Priority", source: source).display.lowercased()) ?? .medium, url: url)
        }
        return .init(id: project.id, name: project.title, metadata: metadata, score: score, nextAction: WorkItemRecommendation.nextAction(in: work), activityAgeDays: nil)
    }
    private var decisionCandidates: [ProjectPortfolio.Candidate] { rows.compactMap(\.candidate) }
    private var rows: [ProjectBrowserRow] { visible.rows }
    private var groups: [(String, [ProjectBrowserRow])] { visible.groups }
    private var visibleKey: VisibleKey {
        .init(domainScope: preferences.focusedDomain, query: query, rules: preferences.propertyFilters ?? [], matchAny: preferences.matchAny ?? false, activity: preferences.activity ?? .all, secondary: preferences.secondarySort, sort: preferences.sort, ascending: preferences.ascending, group: preferences.group, generation: rowsGeneration)
    }
    private static func visibleRows(_ allRows: [ProjectBrowserRow], query: String, preferences: ProjectBrowserPreferences) -> ProjectBrowserVisibleRows {
        let records = Dictionary(uniqueKeysWithValues: allRows.map { ($0.id, $0.queryRecord) })
        let sorts = [ProjectSortRule(field: preferences.sort, ascending: preferences.ascending)] + (preferences.secondarySort.map { [$0] } ?? [])
        let rows = allRows.filter { row in
            (preferences.focusedDomain == nil || records[row.id]!.selected("domain").contains(preferences.focusedDomain!)) && ProjectViewQuery.matches(records[row.id]!, query: query, filters: preferences.propertyFilters ?? [], matchAny: preferences.matchAny ?? false, activity: preferences.activity ?? .all)
        }.sorted { ProjectViewQuery.orderedBefore(records[$0.id]!, records[$1.id]!, sorts: sorts) }
        var groups: [(String, [ProjectBrowserRow])]
        if preferences.group == "none" { groups = [("All projects", rows)] } else {
            var grouped: [String: [ProjectBrowserRow]] = [:]
            for row in rows {
                let keys = row.value(preferences.group).components(separatedBy: ", ").filter { !$0.isEmpty }
                for key in keys.isEmpty ? ["Uncategorized"] : keys { grouped[key, default: []].append(row) }
            }
            groups = grouped.keys.sorted().map { ($0, grouped[$0]!) }
        }
        var byCandidateID: [String: ProjectBrowserRow] = [:]
        for row in rows { if let id = row.candidate?.id, byCandidateID[id] == nil { byCandidateID[id] = row } }
        return .init(rows: rows, groups: groups, byCandidateID: byCandidateID)
    }
    @MainActor private func setRows(_ rows: [ProjectBrowserRow], key: String?) {
        cachedRows = rows
        rowsBuilt = true
        rowsGeneration += 1
        ProjectBrowserCache.rows = rows
        ProjectBrowserCache.key = key
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Picker("Project view", selection: $preferences.presentation) {
                    Text("Table").tag("table"); Text("Cards").tag("cards"); Text("Decide").tag("decide"); Text("Charts").tag("charts")
                }.pickerStyle(.segmented).labelsHidden().frame(width: 260).accessibilityIdentifier("projects.presentation")
                options
                Button { showingFilters.toggle() } label: {
                    Label(activeFilterCount == 0 ? "Filter" : "Filter · \(activeFilterCount)", systemImage: activeFilterCount == 0 ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                        .labelStyle(.iconOnly)
                }.buttonStyle(.borderless).help(activeFilterCount == 0 ? "Filter projects" : "Filter projects · \(activeFilterCount) active")
                    .accessibilityIdentifier("projects.filterButton")
                    .popover(isPresented: $showingFilters, arrowEdge: .bottom) { ProjectFilterEditor(preferences: $preferences, rows: allRows) }
                Spacer(minLength: 0)
                if let progress, showsLoading == false {
                    // Rows on screen are the previous build; say so instead of freezing them silently.
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        ViewThatFits {
                            Text("\(progress.phase)… \(progress.done) of \(progress.total)").fixedSize()
                            Text("Updating…").fixedSize()
                        }
                    }.font(.caption).foregroundStyle(.secondary)
                        .help("Showing the projects already loaded while newer data is gathered.")
                        .accessibilityIdentifier("projects.updating")
                }
                InlineSearchField(text: $query, prompt: "Search projects and tags").frame(minWidth: 140, maxWidth: 240)
            }.padding(.horizontal, 16).padding(.vertical, 10)
            HStack(spacing: 8) {
                Text("\(rows.count) of \(allRows.count) projects").foregroundStyle(.secondary)
                if !query.isEmpty { Button("Clear search") { query = "" } }
                if preferences.activity != nil && preferences.activity != .all {
                    Button { preferences.activity = .all } label: { Label(preferences.activity!.title, systemImage: "xmark.circle.fill") }
                }
                if let domain = preferences.focusedDomain { Button { preferences.focusedDomain = nil } label: { Label("Domain: " + domain, systemImage: "xmark.circle.fill") } }
                ScrollView(.horizontal) {
                    HStack {
                        ForEach((preferences.propertyFilters ?? []).filter { !$0.values.isEmpty }) { rule in
                            Button { preferences.propertyFilters?.removeAll { $0.id == rule.id } } label: {
                                Label("\(Self.title(rule.field)) \(rule.operation.title.lowercased()): \(rule.values.sorted().joined(separator: ", "))", systemImage: "xmark.circle.fill")
                            }
                        }
                    }
                }.scrollIndicators(.hidden)
                if activeFilterCount > 1 { Button("Clear all") { clearFilters() }.accessibilityIdentifier("projects.filters.clearAll") }
            }.font(.caption).buttonStyle(.borderless).padding(.horizontal, 16).padding(.bottom, 8)
            Divider()
            if showsLoading {
                LoadingAreaState(title: "Loading projects…", message: progress.map { "\($0.phase): \($0.done) of \($0.total). You can switch areas while this runs." })
            } else if rows.isEmpty { ContentUnavailableView("No matching projects", systemImage: "folder", description: Text("Change your search or filters, or import project data in Settings.")) }
            else if preferences.presentation == "charts" {
                ProjectAnalyticsDashboard(rows: rows, open: open, drillDomain: { domain in
                    preferences.focusedDomain = domain; preferences.presentation = "table"
                })
            }
            else if preferences.presentation == "table" {
                ProjectOutlineTable(groups: groups, grouped: preferences.group != "none", columns: $preferences.columns, availableColumns: availableColumns, widths: Binding(get: { preferences.columnWidths ?? [:] }, set: { preferences.columnWidths = $0 }), collapsed: $preferences.collapsed,
                    selection: $selection, sort: $preferences.sort, ascending: $preferences.ascending, open: open, action: action)
                    .accessibilityIdentifier("projects.table")
            } else if preferences.presentation == "decide" {
                ProjectsDecisionView(candidates: decisionCandidates, actionMenu: { candidate in
                    AnyView(Menu("Actions") {
                        if let row = visible.byCandidateID[candidate.id] {
                            Button("Open project") { open(row) }
                            if row.value("canExplain") == "true" { Button("Explain") { action(row, "explain") } }
                            if row.value("canFlow") == "true" { Button("User Flow") { action(row, "flow") } }
                            if row.item != nil { Button("Reveal in Finder") { action(row, "finder") }; Divider(); Button("Delete project…", role: .destructive) { action(row, "delete") } }
                            if row.graph?.pageID != nil { Button("Open in Notion") { action(row, "notion") } }
                        }
                    }.menuStyle(.borderlessButton).fixedSize())
                }, inventory: AnyView(decisionInventory)) { candidate in
                    if let row = visible.byCandidateID[candidate.id] { open(row) }
                }
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        ForEach(groups, id: \.0) { name, group in
                            if preferences.group != "none" {
                                Button { toggleGroup(name) } label: { Label("\(name) · \(group.count)", systemImage: preferences.collapsed.contains(name) ? "chevron.right" : "chevron.down") }.buttonStyle(.plain).font(.headline)
                            }
                            if !preferences.collapsed.contains(name) || preferences.group == "none" {
                                LazyVGrid(columns: [GridItem(.adaptive(minimum: 220, maximum: 330))], spacing: 14) {
                                    ForEach(group) { row in ProjectBrowserCard(row: row, capability: capabilities[row.id], open: { open(row) }, action: { action(row, $0) }) }
                                }
                            }
                        }
                    }.padding(18)
                }.accessibilityIdentifier("projects.portfolio")
            }
        }
        .alert("Save project view", isPresented: $savingView) {
            TextField("View name", text: $savedViewName).accessibilityIdentifier("projects.savedView.name")
            Button("Save") {
                let name = savedViewName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { return }
                savedViews.removeAll { $0.name == name }
                savedViews.append(.init(name: name, preferences: preferences)); ProjectSavedView.save(savedViews)
            }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Remembers filters, search, sorting, grouping, columns and presentation on this Mac.") }
        .sheet(item: $newProject) { ProjectGraphRecordEditor(record: $0) }
        .onChange(of: query) { _, value in preferences.query = value }
        .onChange(of: preferences) { _, state in state.save() }
        .task(id: visibleKey) { @MainActor in
            // Debounce typing; clearing the search (or any other change) applies at once.
            if query.isEmpty == false, visibleBuilt { do { try await Task.sleep(for: .milliseconds(150)) } catch { return } }
            visible = Self.visibleRows(cachedRows, query: query, preferences: preferences)
            visibleBuilt = true
        }
        .onChange(of: model.widgetChartRequest) { _, _ in preferences.presentation = "charts" }
        .task(id: buildKey) { @MainActor in
            let key = buildKey
            // The cached rows are already this build; nothing to gather.
            guard ProjectBrowserCache.key != key || rowsBuilt == false else { return }
            defer { if Task.isCancelled == false { progress = nil } }
            guard let rows = await makeRows() else { return }
            setRows(rows, key: nil)
            let local = model.projects()
            var resolved: [String: ProjectToolCapability] = [:]
            var resolvedKinds: [String: ProjectKind] = [:]
            for (index, item) in local.enumerated() {
                if index.isMultiple(of: 20) { progress = .init(phase: "Checking project tools", done: index, total: local.count) }
                if Task.isCancelled { return }
                resolved[item.id] = await model.projectToolCapability(for: item)
                resolvedKinds[item.id] = await ItemProbe.shared.detail(for: item).projectKind
            }
            if Task.isCancelled { return }
            capabilities = resolved; kinds = resolvedKinds
            ProjectBrowserCache.capabilities = resolved; ProjectBrowserCache.kinds = resolvedKinds
            // Patch the three values that depended on them instead of rebuilding every row.
            setRows(cachedRows.map { row in
                var row = row
                guard let item = row.item else { return row }
                row.values["kind"] = resolvedKinds[item.id]?.rawValue ?? ""
                row.values["canExplain"] = resolved[item.id]?.canExplain == true ? "true" : "false"
                row.values["canFlow"] = resolved[item.id]?.canFlowReview == true ? "true" : "false"
                return row
            }, key: key)
        }
    }
    /// Decide's rankings only show projects that can be ranked. This lists the matching
    /// projects that cannot appear above, with the rule that excludes each one.
    private var decisionInventory: some View {
        let scoring = model.scoringPreferences()
        let excluded = rows.compactMap { row -> (ProjectBrowserRow, String)? in
            guard let candidate = row.candidate else { return (row, "No ratings or work recorded here") }
            return ProjectPortfolio.exclusionReason(candidate, preferences: scoring).map { (row, $0) }
        }
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Button { withAnimation(.snappy) { showingUnranked.toggle() } } label: {
                    Label("Not in any ranking · \(excluded.count)", systemImage: showingUnranked ? "chevron.down" : "chevron.right").font(.headline)
                }.buttonStyle(.plain).accessibilityIdentifier("projects.decide.unranked")
                ProjectContextHelp(text: "Projects that match your search and filters but cannot appear in Recommended Next or any ranking: unrated projects without open Now or Next work, projects with too few ratings for a lens, and paused, blocked or finished projects. Open one to rate it or add work.")
            }
            if showingUnranked {
                if excluded.isEmpty { Text("Every matching project can appear above.").font(.caption).foregroundStyle(.secondary) }
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(excluded, id: \.0.id) { row, reason in
                        HStack {
                            Button { open(row) } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(row.name).font(.body.weight(.medium))
                                    Text(reason).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                            }.buttonStyle(.plain)
                            Menu("Actions") { Button("Open project") { open(row) }; if row.item != nil { Button("Reveal in Finder") { action(row, "finder") } }; if row.graph?.pageID != nil { Button("Open in Notion") { action(row, "notion") } } }.menuStyle(.borderlessButton).fixedSize()
                        }.padding(.horizontal, 12).padding(.vertical, 8).background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
        }
    }
    private func toggleGroup(_ name: String) { if preferences.collapsed.contains(name) { preferences.collapsed.remove(name) } else { preferences.collapsed.insert(name) } }
    private func open(_ row: ProjectBrowserRow) { if let item = row.item { model.openProjectWorkspace(for: item) } else { model.openGraphProjectID = row.graph?.id } }
    private func action(_ row: ProjectBrowserRow, _ action: String) {
        if action == "open" { open(row); return }
        if let item = row.item {
            if action == "explain" { model.openProjectTool(.explain, for: item) }
            if action == "flow" { model.openProjectTool(.flowReview, for: item) }
            if action == "finder" { model.revealInFinder(item.url) }
            if action == "delete" { model.requestDeletion(of: item) }
        }
        if action == "notion", let id = row.graph?.pageID, let url = URL(string: "https://www.notion.so/" + id.replacingOccurrences(of: "-", with: "")) { model.open(url) }
    }
    private var availableColumns: [(String, String)] {
        Self.fields + (model.graphSources.first { $0.kind == .projects }?.schema.object.keys.sorted().map { ("notion:" + $0, $0) } ?? [])
    }
    private var activeFilterCount: Int {
        (preferences.propertyFilters ?? []).filter { !$0.values.isEmpty }.count
            + (preferences.activity.map { $0 == .all ? 0 : 1 } ?? 0) + (preferences.focusedDomain == nil ? 0 : 1)
    }
    private func clearFilters() { preferences.propertyFilters = []; preferences.activity = .all; preferences.matchAny = false; preferences.focusedDomain = nil }
    private func applyPreset(_ activity: ProjectActivityFilter) {
        let terminal = Set(allRows.map { $0.value("status") }.filter { ProjectMetadata(status: $0).isTerminal })
            .union(["Complete", "Completed", "Abandoned", "Deprecated", "Archived"])
        preferences.propertyFilters = [.init(field: "status", operation: .excludes, values: terminal)]
        preferences.activity = activity; preferences.matchAny = false; preferences.focusedDomain = nil
        if activity == .all { preferences.sort = "lastUpdate"; preferences.ascending = false }
    }
    private var options: some View {
        Menu {
            Button("Filters…") { showingFilters = true }.accessibilityIdentifier("projects.filters")
            Menu("Presets") {
                Button("All Projects") { clearFilters(); query = "" }
                Button("Active Projects") { applyPreset(.all) }
                Button("Needs Attention") { applyPreset(.stalled) }
                Button("Recently Worked On") { applyPreset(.recent); preferences.sort = "lastWorked"; preferences.ascending = true }
                Button("Outstanding Work") { applyPreset(.unfinished); preferences.group = "domain" }
            }
            Menu("Saved views") {
                ForEach(savedViews) { view in Button(view.name) { preferences = view.preferences; query = preferences.query ?? "" } }
                Divider()
                Button("Save current view…") { savedViewName = ""; savingView = true }
                if !savedViews.isEmpty { Menu("Delete saved view") { ForEach(savedViews) { view in Button(view.name) { savedViews.removeAll { $0.id == view.id }; ProjectSavedView.save(savedViews) } } } }
            }
            Menu("Group") { ForEach(Self.groupFields, id: \.self) { key in Button(Self.title(key)) { preferences.group = key }.accessibilityIdentifier("projects.groupBy." + key) } }
            Menu("Sort") {
                ForEach(Self.fields, id: \.0) { key, title in Button(title) { preferences.sort = key } }
                Menu("Then by") {
                    Button("None") { preferences.secondarySort = nil }
                    ForEach(Self.fields, id: \.0) { key, title in Button(title) { preferences.secondarySort = .init(field: key) } }
                    if preferences.secondarySort != nil { Button("Reverse secondary direction") { preferences.secondarySort?.ascending.toggle() } }
                }
                Divider(); Button(preferences.ascending ? "Descending" : "Ascending") { preferences.ascending.toggle() }
            }
            Menu("Columns") {
                Button("Restore default columns") { preferences.columns = ProjectBrowserPreferences.defaultColumns; preferences.columnWidths = [:] }
                Divider()
                ForEach(Self.fields.filter { $0.0 != "name" }, id: \.0) { key, title in
                    Toggle(title, isOn: Binding(get: { preferences.columns.contains(key) }, set: { enabled in
                        if enabled { preferences.columns.append(key) } else { preferences.columns.removeAll { $0 == key } }
                    }))
                }
                if let source = model.graphSources.first(where: { $0.kind == .projects }) {
                    Menu("Other Notion properties") {
                        ForEach(source.schema.object.keys.sorted(), id: \.self) { name in
                            let key = "notion:" + name
                            Toggle(name, isOn: Binding(get: { preferences.columns.contains(key) }, set: { enabled in if enabled { preferences.columns.append(key) } else { preferences.columns.removeAll { $0 == key } } }))
                        }
                    }
                }
            }
            if let source = model.graphSources.first(where: { $0.kind == .projects }) {
                Divider()
                Button("New project…") { newProject = .init(sourceID: source.id, kind: .projects) }
            }
            Divider(); Button("Reset view options") { preferences = .init(); query = "" }
            if !model.projectSpaces().isEmpty { Menu("Project spaces") { ForEach(model.projectSpaces()) { space in Button(space.displayTitle) { model.open(space.url) } } } }
        } label: { Label("View options", systemImage: "slider.horizontal.3") }
            .menuStyle(.borderlessButton).fixedSize().accessibilityIdentifier("projects.viewOptions")
    }
}

struct ProjectBrowserCard: View {
    @Environment(AppModel.self) private var model
    let row: ProjectBrowserRow
    let capability: ProjectToolCapability?
    let open: () -> Void
    let action: (String) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button(action: open) {
                VStack(alignment: .leading, spacing: 10) {
                    if let project = row.graph { ProjectPrimaryMedia(project: project, role: "thumbnail", height: 130) }
                    else { RoundedRectangle(cornerRadius: 8).fill(.quaternary).frame(height: 130).overlay(Image(systemName: "folder").font(.largeTitle).foregroundStyle(.secondary)) }
                    Text(row.name).font(.headline).lineLimit(2)
                    Text(row.value("oneLiner").isEmpty ? "No description yet" : row.value("oneLiner")).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    Text([row.value("domain"), row.value("status"), row.value("phase")].filter { !$0.isEmpty }.joined(separator: " · ")).font(.caption2).foregroundStyle(.secondary)
                    if !row.tags.isEmpty { Text(row.tags.prefix(3).joined(separator: " · ")).font(.caption2).foregroundStyle(.secondary) }
                    if row.item == nil { Label("Notion-only", systemImage: "cloud").font(.caption2).foregroundStyle(.secondary) }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.buttonStyle(.plain).accessibilityIdentifier("projects.portfolio.\(row.id)")
            HStack {
                if capability?.canExplain == true { Button("Explain") { action("explain") } }
                if capability?.canFlowReview == true { Button("User Flow") { action("flow") } }
                Spacer()
                Menu { Button("Open project", action: open); if row.item != nil { Button("Reveal in Finder") { action("finder") }; Divider(); Button("Delete project…", role: .destructive) { action("delete") } }; if row.graph?.pageID != nil { Button("Open in Notion") { action("notion") } } } label: { Image(systemName: "ellipsis") }
            }.font(.caption).buttonStyle(.borderless)
        }.padding(12).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.quaternary))
            .contextMenu { if let item = row.item { ItemContextMenu(item: item) } }
    }
}
