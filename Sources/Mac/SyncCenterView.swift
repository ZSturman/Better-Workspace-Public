import SwiftUI
import TipKit
import BetterWorkspaceCore

// MARK: - Sections

enum SyncSection: String, CaseIterable, Identifiable {
    case needsYou, ready, cleanup, deferred
    var id: String { rawValue }
    var title: String {
        switch self {
        case .needsYou: return "Needs You"
        case .ready: return "Ready"
        case .cleanup: return "Cleanup"
        case .deferred: return "Later"
        }
    }
    var symbol: String {
        switch self {
        case .needsYou: return "exclamationmark.circle"
        case .ready: return "checkmark.circle"
        case .cleanup: return "trash"
        case .deferred: return "clock"
        }
    }
}

extension AppModel {
    /// Every difference, in the section a person would look for it.
    var syncSections: [SyncSection: [ProjectSyncTriage.Item]] {
        _ = graphRevision
        var sections: [SyncSection: [ProjectSyncTriage.Item]] = [:]
        for item in syncTriage {
            let section: SyncSection
            if syncDeferred[item.id] == item.fingerprint { section = .deferred }
            else if item.bucket == .obsolete { section = .cleanup }
            else if item.bucket == .decision || (syncFailures[item.id]?.attempts ?? 0) >= ProjectAutoSyncPlanner.attemptsBeforeAttention { section = .needsYou }
            else { section = .ready }
            sections[section, default: []].append(item)
        }
        return sections
    }
}

// MARK: - Toolbar indicator

/// A small status in the toolbar; it opens the Sync Center.
struct SyncStatusButton: View {
    @Environment(AppModel.self) private var model
    private let tip = SendToNotionTip()

    var body: some View {
        let state = model.notionSyncState
        if state != .notConfigured {
            Button { tip.invalidate(reason: .actionPerformed); model.showingSyncCenter = true } label: { label(state) }
                .help(help(state))
                .accessibilityLabel("Notion sync")
                .accessibilityValue("\(model.syncSections[.needsYou]?.count ?? 0) need you, \(model.syncSections[.ready]?.count ?? 0) waiting")
                .accessibilityIdentifier("projects.sync")
                .popoverTip(tip, arrowEdge: .bottom)
                .contextMenu {
                    Button("Open Sync Center") { model.showingSyncCenter = true }
                    Button("Sync Now") { Task { await model.syncNow() } }.disabled(model.graphBusy)
                    Toggle("Sync Automatically", isOn: Binding(get: { model.notionAutoSync }, set: { model.notionAutoSync = $0 }))
                }
        }
    }

    @ViewBuilder private func label(_ state: NotionSyncState) -> some View {
        switch state {
        case .syncing:
            HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Syncing…").font(.caption) }
        case .upToDate:
            Image(systemName: "checkmark.icloud")
        case .waiting:
            Image(systemName: "arrow.triangle.2.circlepath")
                .overlay(alignment: .topTrailing) { Circle().fill(Color.accentColor).frame(width: 6, height: 6).offset(x: 3, y: -2) }
        case .attention(let count):
            HStack(spacing: 2) {
                Image(systemName: "exclamationmark.arrow.triangle.2.circlepath")
                Text(count > 999 ? "999+" : "\(count)").font(.caption2.monospacedDigit())
            }
            .foregroundStyle(.orange)
        case .unavailable:
            Image(systemName: "icloud.slash")
        case .notConfigured:
            EmptyView()
        }
    }

    private func help(_ state: NotionSyncState) -> String {
        switch state {
        case .syncing: return "Syncing with Notion"
        case .upToDate: return "In sync with Notion"
        case .waiting(let n): return "\(n) waiting to sync with Notion"
        case .attention(let n): return "\(n) \(n == 1 ? "difference needs" : "differences need") you"
        case .unavailable(let reason): return "Notion is unavailable: \(reason)"
        case .notConfigured: return ""
        }
    }

}

extension AppModel {
    /// A property value as a person reads it: names for related records, dates as dates.
    func syncDisplay(_ value: ProjectJSON) -> String {
        switch value["type"].string {
        case "relation":
            let names = value["relation"].array.compactMap { $0["id"].string }.map { id -> String in
                let key = ProjectGraph.normalizedID(id)
                return graphRecords.first { ProjectGraph.normalizedID($0.pageID ?? $0.id) == key }?.title ?? "Unknown record"
            }
            return names.count > 4 ? names.prefix(4).joined(separator: ", ") + " +\(names.count - 4)" : names.joined(separator: ", ")
        case "date":
            guard let start = value["date"]["start"].string, let date = ProjectDates.parse(start) else { return value.display }
            return start.count <= 10 ? date.formatted(date: .abbreviated, time: .omitted) : date.formatted(date: .abbreviated, time: .shortened)
        case "checkbox": return value["checkbox"].bool ? "Yes" : "No"
        case "files": return "\(value["files"].array.count) files"
        default: return value.display
        }
    }

    /// What Sync Now does in either mode: everything that may move on its own.
    func syncNow() async {
        if notionAutoSync { await runAutoSyncPass(); return }
        await checkProjectGraph()
        guard !syncFeedbackIsError else { return }
        let plan = syncPlan
        if !(plan.pull + plan.push).isEmpty { await applySync(plan.pull + plan.push) }
        else if !syncFeedbackIsError {
            var report = ProjectAutoSync.Report(); report.finishedAt = Date(); report.attention = plan.attention.count
            finishSyncFeedback(report)
            try? ProjectGraphStore(database: database).write(ProjectAutoSync.actionReportKey, report)
            reloadProjectGraph()
        }
    }
}

// MARK: - Sync Center

struct SyncCenterView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var section: SyncSection = .needsYou
    @State private var selection = Set<String>()
    @State private var query = ""
    @State private var project: String?
    @State private var category: ProjectSyncTriage.Category?
    @State private var kind: ProjectEntityKind?
    @State private var field: String?
    @State private var conflictsOnly = false
    @State private var choices: [String: [String: ProjectSyncTriage.Side]] = [:]
    @State private var pending: BulkAction?
    @State private var working = false
    @State private var showsLegacyReview = false

    private var sections: [SyncSection: [ProjectSyncTriage.Item]] { model.syncSections }

    private var visible: [ProjectSyncTriage.Item] {
        (sections[section] ?? []).filter { item in
            (project == nil || item.projectIDs.contains(project!))
                && (category == nil || item.category == category)
                && (kind == nil || item.record.kind == kind)
                && (field == nil || item.fields.contains { $0.name == field })
                && (!conflictsOnly || item.fields.contains { $0.state == .conflict })
                && (query.isEmpty || item.record.title.localizedCaseInsensitiveContains(query)
                    || item.projectIDs.contains { model.syncProjectName($0)?.localizedCaseInsensitiveContains(query) == true })
        }
    }

    private var selectedItems: [ProjectSyncTriage.Item] { visible.filter { selection.contains($0.id) } }

    var body: some View {
        VStack(spacing: 0) {
            header
            syncFeedbackBanner
            Divider()
            HStack(spacing: 0) {
                list.frame(width: 300)
                Divider()
                detail.frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity).clipped()
            }
        }
        .frame(minWidth: 780, idealWidth: 1040, maxWidth: 1400, minHeight: 470, idealHeight: 680, maxHeight: 1000)
        .onAppear { section = (sections[.needsYou] ?? []).isEmpty ? .ready : .needsYou }
        .onChange(of: section) { _, _ in selection = []; resetFilters() }
        .sheet(item: $pending) { action in BulkSummary(action: action, run: { await run(action) }) }
        .sheet(isPresented: $showsLegacyReview) { LegacyReviewLauncher() }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: Theme.Space.base) {
            statusLine
            Spacer()
            Picker("Sync", selection: Binding(get: { model.notionAutoSync }, set: { model.notionAutoSync = $0 })) {
                Text("Automatic").tag(true)
                Text("Manual").tag(false)
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            .help("Automatic applies safe changes; merges, conflicts, deletions and uploads wait for review")
            .accessibilityIdentifier("sync.mode")
            Button { Task { await model.syncNow() } } label: {
                if model.graphBusy { HStack { ProgressView().controlSize(.small); Text("Syncing…") } }
                else { Label("Sync Now", systemImage: "arrow.triangle.2.circlepath") }
            }
                .disabled(model.graphBusy)
                .accessibilityIdentifier("sync.now")
            Menu {
                Button("Check Notion for Changes") { Task { await model.checkProjectGraph() } }.disabled(model.graphBusy)
                Button("Merge All Multi-value Fields…") {
                    let items = model.syncTriage.filter { !ProjectSyncTriage.mergeChoices($0).isEmpty && model.syncDeferred[$0.id] != $0.fingerprint }
                    pending = .init(kind: .merge, items: items)
                }
                .disabled(model.graphBusy || model.syncTriage.allSatisfy { ProjectSyncTriage.mergeChoices($0).isEmpty })
                .accessibilityIdentifier("sync.mergeAll")
                Button("Detailed Review…") { showsLegacyReview = true }
            } label: { Image(systemName: "ellipsis.circle") }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .accessibilityIdentifier("sync.more")
            Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, Theme.Space.base).padding(.vertical, 10)
    }

    @ViewBuilder private var syncFeedbackBanner: some View {
        let report = [model.syncActionReport, model.syncReport].compactMap { $0 }.max { ($0.finishedAt ?? .distantPast) < ($1.finishedAt ?? .distantPast) }
        let isError = model.syncFeedbackIsError || (model.syncFeedback == nil && model.syncActivity == nil && (report?.failed.isEmpty == false || report?.readFailures.isEmpty == false))
        if let message = model.syncActivity ?? model.syncFeedback ?? report?.completionSummary {
            HStack(alignment: .top, spacing: 10) {
                if model.graphBusy { ProgressView().controlSize(.small) }
                else { Image(systemName: isError ? "exclamationmark.triangle.fill" : "checkmark.circle") }
                VStack(alignment: .leading, spacing: 3) {
                    Text(message).font(.callout).textSelection(.enabled).accessibilityIdentifier("sync.feedback")
                    if !model.graphBusy, let changes = model.syncLastChangesReport, changes.finishedAt != report?.finishedAt {
                        Text("Last applied changes: \(changes.sent.count) sent, \(changes.received.count) received, \(changes.mergedFields ?? 0) fields merged.\(changes.failed.isEmpty ? "" : " \(changes.failed.count) records need review.")\((changes.historicalLinkFieldsForReview ?? 0) == 0 ? "" : " \(changes.historicalLinkFieldsForReview!) historical link fields need review.")")
                            .font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("sync.lastChanges")
                    }
                    if !model.graphBusy, let finishedAt = report?.finishedAt {
                        Text("Last completed: \(finishedAt.formatted(date: .abbreviated, time: .standard))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .foregroundStyle(isError ? Color.orange : Color.primary)
            .padding(.horizontal, Theme.Space.base).padding(.vertical, 10)
            .background(isError ? Color.orange.opacity(0.08) : Color.accentColor.opacity(0.06))
            .accessibilityElement(children: .contain).accessibilityIdentifier("sync.feedbackBanner")
        }
    }

    private var statusLine: some View {
        let needs = sections[.needsYou]?.count ?? 0, ready = sections[.ready]?.count ?? 0
        return HStack(spacing: 10) {
            Image(systemName: model.graphBusy ? "arrow.triangle.2.circlepath" : needs > 0 ? "exclamationmark.circle.fill" : ready > 0 ? "arrow.triangle.2.circlepath.circle.fill" : "checkmark.circle.fill")
                .font(.title2).foregroundStyle(needs > 0 ? AnyShapeStyle(.orange) : ready > 0 ? AnyShapeStyle(.tint) : AnyShapeStyle(.green))
            VStack(alignment: .leading, spacing: 1) {
                Text(model.graphBusy ? "Syncing…" : needs > 0 ? "\(needs.formatted()) need you" : ready > 0 ? "\(ready.formatted()) ready to sync" : "Everything is in sync")
                    .font(.headline)
                    .accessibilityIdentifier("sync.status")
                Text(lastSynced).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var lastSynced: String {
        if let date = model.syncReport?.finishedAt ?? model.graphReport?.checkedAt { return "Checked \(date.formatted(.relative(presentation: .named)))" }
        return model.notionAutoSync ? "Automatic" : "Manual"
    }

    // MARK: Sidebar

    private var sectionPicker: some View {
        Picker("Section", selection: $section) {
            ForEach(SyncSection.allCases) { value in
                Text(value.title).tag(value)
            }
        }
        .pickerStyle(.segmented).labelsHidden().controlSize(.small)
        .frame(maxWidth: .infinity)
        .accessibilityIdentifier("sync.sections")
    }

    // MARK: List

    private var list: some View {
        VStack(spacing: 0) {
            filters
            Divider()
            let groups = Dictionary(grouping: visible, by: \.category)
            HStack {
                Text(sectionCaption).font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 12).padding(.vertical, 4)
            List(selection: $selection) {
                ForEach(ProjectSyncTriage.Category.allCases.filter { groups[$0] != nil }, id: \.self) { category in
                    let items = groups[category]!
                    Section {
                        ForEach(items.prefix(500)) { item in SyncRow(item: item, project: item.projectIDs.first.flatMap(model.syncProjectName)).tag(item.id) }
                        if items.count > 500 { Text("\(items.count - 500) more; filter to narrow").font(.caption).foregroundStyle(.secondary) }
                    } header: {
                        HStack {
                            Text("\(category.title) · \(items.count.formatted())")
                            Spacer()
                            Button("Select All") { selection.formUnion(items.map(\.id)) }
                                .buttonStyle(.link).font(.caption)
                                .accessibilityIdentifier("sync.selectAll.\(category.rawValue)")
                        }
                    }
                }
            }
            .listStyle(.inset)
            .overlay { if visible.isEmpty { emptyList } }
            .accessibilityElement(children: .contain).accessibilityIdentifier("sync.list")
        }
    }

    @ViewBuilder private var emptyList: some View {
        if (sections[section] ?? []).isEmpty {
            ContentUnavailableView(section == .needsYou ? "Nothing needs you" : section == .ready ? "Nothing waiting" : section == .cleanup ? "Nothing to clean up" : "Nothing set aside",
                                   systemImage: section.symbol)
        } else {
            ContentUnavailableView("No matches", systemImage: "line.3.horizontal.decrease.circle",
                                   description: Text("Clear the filters to see everything here."))
        }
    }

    private var filters: some View {
        let items = sections[section] ?? []
        let projects = Set(items.flatMap(\.projectIDs)).compactMap { id in model.syncProjectName(id).map { (id, $0) } }.sorted { $0.1.localizedStandardCompare($1.1) == .orderedAscending }
        let fieldNames = Set(items.flatMap { $0.fields.map(\.name) }).sorted()
        return VStack(alignment: .leading, spacing: 6) {
            sectionPicker
            InlineSearchField(text: $query, prompt: "Search records or projects")
            HStack(spacing: 8) {
                Menu {
                    Button("All projects") { project = nil }
                    Divider()
                    ForEach(projects.prefix(300), id: \.0) { id, name in Button(name) { project = id } }
                } label: { Text(project.flatMap(model.syncProjectName) ?? "Project").lineLimit(1) }
                Menu {
                    Button("All types") { kind = nil }
                    Divider()
                    ForEach(ProjectEntityKind.allCases.filter { value in items.contains { $0.record.kind == value } }) { value in Button(value.title) { kind = value } }
                } label: { Text(kind?.title ?? "Type") }
                Menu {
                    Button("All changes") { category = nil }
                    Divider()
                    ForEach(ProjectSyncTriage.Category.allCases.filter { value in items.contains { $0.category == value } }, id: \.self) { value in Button(value.title) { category = value } }
                    Divider()
                    Toggle("Conflicts only", isOn: $conflictsOnly)
                } label: { Text(category?.title ?? (conflictsOnly ? "Conflicts" : "Change")) }
                if !fieldNames.isEmpty {
                    Menu {
                        Button("All fields") { field = nil }
                        Divider()
                        ForEach(fieldNames, id: \.self) { name in Button(name) { field = name } }
                    } label: { Text(field ?? "Field") }
                }
                if project != nil || kind != nil || category != nil || field != nil || conflictsOnly {
                    Button { resetFilters() } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.borderless).help("Clear filters")
                }
            }
            .menuStyle(.borderlessButton).font(.caption).fixedSize()
        }
        .padding(10)
    }

    private var sectionCaption: String {
        let all = sections[section]?.count ?? 0
        return visible.count == all ? "\(all.formatted()) \(all == 1 ? "record" : "records")" : "\(visible.count.formatted()) of \(all.formatted())"
    }

    private func resetFilters() { project = nil; category = nil; kind = nil; field = nil; conflictsOnly = false; query = "" }

    // MARK: Detail

    @ViewBuilder private var detail: some View {
        let selected = selectedItems
        if selected.count == 1, let item = selected.first {
            SyncItemDetail(item: item, project: item.projectIDs.first.flatMap(model.syncProjectName),
                           choices: Binding(get: { choices[item.id] ?? defaults(item) }, set: { choices[item.id] = $0 }),
                           failure: model.syncFailures[item.id], deferred: section == .deferred,
                           act: { action in perform(action) })
                .id(item.id)
        } else if selected.count > 1 {
            BulkPanel(items: selected, act: { action in perform(action) })
        } else {
            overview
        }
    }

    private var overview: some View {
        VStack(alignment: .leading, spacing: Theme.Space.base) {
            let items = sections[section] ?? []
            if items.isEmpty {
                Spacer()
            } else {
                Text(section.title).font(.title2.weight(.semibold))
                let groups = Dictionary(grouping: items, by: \.category).sorted { $0.value.count > $1.value.count }
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                    ForEach(groups, id: \.key) { category, values in
                        GridRow {
                            Text(values.count.formatted()).font(.body.monospacedDigit()).gridColumnAlignment(.trailing)
                            Text(category.title)
                            Button("Select") { selection = Set(values.map(\.id)) }.buttonStyle(.link)
                        }
                    }
                }
                if section == .ready {
                    let safe = items.filter { $0.bucket == .automatic }
                    if !safe.isEmpty {
                        Button("Sync \(safe.count.formatted()) Safe Changes") { pending = .init(kind: .recommended, items: safe) }
                            .buttonStyle(.borderedProminent)
                            .accessibilityIdentifier("sync.applySafe")
                    }
                }
                Spacer()
            }
        }
        .padding(Theme.Space.loose)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// One record's action happens at once: its detail already shows what changes.
    /// Bulk actions and discarding drafts show a summary first.
    private func perform(_ proposed: BulkAction) {
        let action = BulkAction(kind: proposed.kind, items: proposed.items,
                                choices: Dictionary(uniqueKeysWithValues: proposed.items.map { ($0.id, choices[$0.id] ?? defaults($0)) }))
        if action.items.count > 1 || action.kind == .discard || action.kind == .merge { pending = action }
        else { Task { await run(action) } }
    }

    private func defaults(_ item: ProjectSyncTriage.Item) -> [String: ProjectSyncTriage.Side] {
        Dictionary(uniqueKeysWithValues: item.fields.compactMap { field in field.recommended.map { (field.id, $0) } })
    }

    // MARK: Running actions

    private func run(_ action: BulkAction) async {
        switch action.kind {
        case .recommended:
            let ready = action.items.filter(action.resolvable)
            await model.applySync(ready, choices: Dictionary(uniqueKeysWithValues: ready.map { ($0.id, action.choices[$0.id] ?? defaults($0)) }))
        case .merge:
            await model.applySync(action.items, mergesOnly: true)
        case .chosen:
            await model.applySync(action.items, choices: Dictionary(uniqueKeysWithValues: action.items.map { ($0.id, action.choices[$0.id] ?? defaults($0)) }))
        case .useNotion:
            await model.applySync(action.items, choices: Dictionary(uniqueKeysWithValues: action.items.map { item in
                (item.id, Dictionary(uniqueKeysWithValues: item.fields.filter { $0.state != .incoming }.map { ($0.id, .notion) }))
            }))
        case .useLocal:
            await model.applySync(action.items, choices: Dictionary(uniqueKeysWithValues: action.items.map { item in
                (item.id, Dictionary(uniqueKeysWithValues: item.fields.filter { $0.state == .conflict }.map { ($0.id, .local) }))
            }))
        case .later: model.deferSync(action.items)
        case .unlater: model.undeferSync(action.items)
        case .discard: model.discardSyncDrafts(action.items)
        case .cancelArchive: action.items.forEach(model.cancelArchiveRequest)
        }
        selection.subtract(action.items.map(\.id))
    }
}

// MARK: - Bulk actions and their summary

struct BulkAction: Identifiable {
    enum Kind { case recommended, chosen, merge, useNotion, useLocal, later, unlater, discard, cancelArchive }
    let id = UUID()
    let kind: Kind
    let items: [ProjectSyncTriage.Item]
    var choices: [String: [String: ProjectSyncTriage.Side]] = [:]

    /// Every field has a recommendation (or nothing to choose).
    func resolvable(_ item: ProjectSyncTriage.Item) -> Bool {
        !item.fields.contains { $0.recommended == nil } && item.category != .failed
    }

    var title: String {
        switch kind {
        case .recommended: return "Apply Recommended"
        case .chosen: return "Apply"
        case .merge: return "Merge Multi-value Fields"
        case .useNotion: return "Use Notion’s Values"
        case .useLocal: return "Use This Mac’s Values"
        case .later: return "Decide Later"
        case .unlater: return "Bring Back"
        case .discard: return "Discard Drafts"
        case .cancelArchive: return "Keep in Notion"
        }
    }

    /// What the action would do, counted, before it does it.
    var summary: [(String, Int)] {
        let affected = kind == .recommended ? items.filter(resolvable) : items
        var rows: [(String, Int)] = []
        func add(_ label: String, _ count: Int) { if count > 0 { rows.append((label, count)) } }
        switch kind {
        case .later, .unlater, .cancelArchive:
            add("Records", affected.count)
        case .merge:
            let mergeable = affected.filter { !ProjectSyncTriage.mergeChoices($0).isEmpty }
            add("Records", mergeable.count)
            add("Fields merged (keep values from both sides)", mergeable.reduce(0) { $0 + ProjectSyncTriage.mergeChoices($1).count })
            add("Skipped: no mergeable fields", affected.count - mergeable.count)
        case .discard:
            add("Drafts forgotten (never in Notion)", affected.filter { $0.record.pageID == nil }.count)
            add("Skipped: already in Notion", affected.filter { $0.record.pageID != nil }.count)
        default:
            let notionWins = kind == .useNotion
            func choice(_ item: ProjectSyncTriage.Item, _ field: ProjectSyncTriage.FieldDiff) -> ProjectSyncTriage.Side? {
                if kind == .useNotion { return .notion }
                if kind == .useLocal { return field.state == .incoming ? .notion : .local }
                return choices[item.id]?[field.id] ?? field.recommended
            }
            add("Fields merged (keep values from both sides)", affected.reduce(0) { count, item in
                count + item.fields.filter { choice(item, $0) == .merge }.count
            })
            add("Created in Notion", affected.filter { $0.record.pageID == nil && !notionWins }.count)
            add("Notion values replaced", affected.reduce(0) { count, item in
                count + item.fields.filter { choice(item, $0) == .local && !ProjectSyncTriage.isEmpty($0.notion) }.count
            })
            add("Fields filled in Notion", affected.reduce(0) { count, item in
                count + item.fields.filter { choice(item, $0) == .local && ProjectSyncTriage.isEmpty($0.notion) }.count
            })
            // A record received for the first time counts once, not once per field.
            add("Values taken from Notion", affected.filter { $0.category != .newInNotion && $0.record.pageID != nil }
                .reduce(0) { count, item in count + item.fields.filter { choice(item, $0) == .notion }.count })
            add("Records received", affected.filter { $0.category == .newInNotion }.count)
            add("Files uploaded", notionWins ? 0 : affected.reduce(0) { $0 + ($1.record.pendingUploads?.count ?? 0) })
            if kind == .recommended { add("Skipped: need a choice", items.count - affected.count) }
        }
        return rows
    }
}

private struct BulkSummary: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var model
    let action: BulkAction
    let run: () async -> Void
    @State private var running = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.base) {
            Text(action.title).font(.title3.weight(.semibold))
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                ForEach(action.summary, id: \.0) { label, count in
                    GridRow {
                        Text(count.formatted()).font(.body.monospacedDigit()).gridColumnAlignment(.trailing)
                        Text(label).foregroundStyle(label.hasPrefix("Skipped") ? .secondary : .primary)
                    }
                }
            }
            .accessibilityElement(children: .contain).accessibilityIdentifier("sync.summary")
            if action.summary.isEmpty { Text("Nothing to do.").foregroundStyle(.secondary) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(action.title) {
                    running = true
                    Task { @MainActor in await run(); running = false; dismiss() }
                }
                .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                .disabled(running || action.summary.allSatisfy { $0.0.hasPrefix("Skipped") })
                .accessibilityIdentifier("sync.summary.confirm")
            }
            if running {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(model.syncActivity ?? "Applying reviewed changes…").font(.caption)
                        .accessibilityIdentifier("sync.summary.progress")
                }
            }
        }
        .padding(20).frame(width: 380)
    }
}

private struct BulkPanel: View {
    let items: [ProjectSyncTriage.Item]
    let act: (BulkAction) -> Void

    var body: some View {
        let drafts = items.allSatisfy { $0.record.pageID == nil }
        let conflicts = items.reduce(0) { $0 + $1.fields.filter { $0.state == .conflict }.count }
        let unresolved = items.filter { $0.fields.contains { $0.recommended == nil } }.count
        VStack(alignment: .leading, spacing: Theme.Space.base) {
            Text("\(items.count.formatted()) selected").font(.title2.weight(.semibold))
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 4) {
                row("Send to Notion", items.filter(\.sendsToNotion).count)
                row("Receive from Notion", items.filter(\.receivesFromNotion).count)
                row("Conflicting fields", conflicts)
                row("Without a recommendation", unresolved)
            }
            VStack(alignment: .leading, spacing: 8) {
                Button("Apply Recommended") { act(.init(kind: .recommended, items: items)) }
                    .buttonStyle(.borderedProminent).disabled(unresolved == items.count)
                    .accessibilityIdentifier("sync.bulk.recommended")
                Button("Merge Multi-value Fields") { act(.init(kind: .merge, items: items)) }
                    .disabled(items.allSatisfy { ProjectSyncTriage.mergeChoices($0).isEmpty })
                    .accessibilityIdentifier("sync.bulk.merge")
                HStack {
                    Button("Use Notion’s Values") { act(.init(kind: .useNotion, items: items)) }
                        .disabled(items.allSatisfy { $0.record.pageID == nil })
                    Button("Use This Mac’s Values") { act(.init(kind: .useLocal, items: items)) }
                }
                HStack {
                    Button("Decide Later") { act(.init(kind: .later, items: items)) }
                    if drafts { Button("Discard Drafts", role: .destructive) { act(.init(kind: .discard, items: items)) } }
                }
            }
            Spacer()
        }
        .padding(Theme.Space.loose)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func row(_ label: String, _ count: Int) -> some View {
        if count > 0 { GridRow { Text(count.formatted()).monospacedDigit().gridColumnAlignment(.trailing); Text(label).foregroundStyle(.secondary) } }
    }
}

// MARK: - Rows and one record

private struct SyncRow: View {
    let item: ProjectSyncTriage.Item
    let project: String?

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: direction).foregroundStyle(item.fields.contains { $0.state == .conflict } ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.record.title).lineLimit(1)
                Text([project, item.record.kind.singular, fieldSummary ?? item.reason].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(.vertical, 2)
        .accessibilityIdentifier("sync.row.\(item.record.title)")
    }

    private var fieldSummary: String? {
        let names = item.fields.filter { $0.state != .incoming || item.category == .notionEdit }.map(\.name)
        guard !names.isEmpty, item.record.pageID != nil, item.category != .newInNotion else { return nil }
        return names.count <= 2 ? names.joined(separator: ", ") : "\(names.prefix(2).joined(separator: ", ")) +\(names.count - 2)"
    }

    private var direction: String {
        if item.fields.contains(where: { $0.state == .conflict }) { return "arrow.up.arrow.down" }
        if item.sendsToNotion { return "arrow.up" }
        return "arrow.down"
    }
}

private struct SyncItemDetail: View {
    @Environment(AppModel.self) private var model
    let item: ProjectSyncTriage.Item
    let project: String?
    @Binding var choices: [String: ProjectSyncTriage.Side]
    let failure: ProjectAutoSyncPlanner.Failure?
    let deferred: Bool
    let act: (BulkAction) -> Void
    @State private var showsDetails = false

    private var shownFields: [ProjectSyncTriage.FieldDiff] {
        // A new record shows what it would bring; an existing one only what differs.
        item.fields.filter { item.record.pageID == nil || item.category == .newInNotion || $0.state != .equal }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.base) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.record.title).font(.title2.weight(.semibold)).lineLimit(2).textSelection(.enabled)
                    Text([project, item.record.kind.singular, item.reason].compactMap { $0 }.joined(separator: " · "))
                        .foregroundStyle(.secondary)
                }
                if let failure {
                    Label("\(failure.message) · tried \(failure.attempts)×", systemImage: "exclamationmark.triangle.fill")
                        .font(.callout).foregroundStyle(.orange)
                }
                if !shownFields.isEmpty { fieldTable }
                actions
                DisclosureGroup("Technical details", isExpanded: $showsDetails) {
                    VStack(alignment: .leading, spacing: 4) {
                        LabeledContent("Notion page", value: item.record.pageID ?? "Not created yet")
                        LabeledContent("Notion edited", value: item.record.editedAt?.formatted(date: .abbreviated, time: .shortened) ?? "—")
                        LabeledContent("Category", value: "\(item.category.rawValue) · \(String(describing: item.bucket))")
                        if let error = item.record.error { LabeledContent("Last error", value: error) }
                        ForEach(item.record.pendingUploads ?? []) { upload in LabeledContent("Upload", value: upload.path) }
                    }
                    .font(.caption).textSelection(.enabled)
                }
                .font(.callout).foregroundStyle(.secondary)
            }
            .padding(Theme.Space.loose)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .contain).accessibilityIdentifier("sync.detail")
    }

    private var fieldTable: some View {
        Grid(alignment: .topLeading, horizontalSpacing: 10, verticalSpacing: 10) {
            GridRow {
                Text("Field"); Text("This Mac"); Text("Notion"); Text("Use")
            }
            .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Divider().gridCellUnsizedAxes(.horizontal)
            ForEach(shownFields) { field in
                GridRow {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(field.name).lineLimit(2)
                        if let note = field.note { Text(note).font(.caption2).foregroundStyle(.secondary).lineLimit(2) }
                    }
                    .frame(width: 105, alignment: .leading)
                    value(field.local, newer: field.newer == .local)
                    if field.mergeBlockedReason != nil && ProjectSyncTriage.isEmpty(field.notion) {
                        Text("No readable links").foregroundStyle(.secondary)
                            .help("Notion’s API returned no links. Review the retired linked records in Notion before choosing a value.")
                    } else { value(field.notion, newer: field.newer == .notion) }
                    chooser(field)
                }
            }
        }
        .accessibilityElement(children: .contain).accessibilityIdentifier("sync.fields")
    }

    private func value(_ json: ProjectJSON, newer: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(ProjectSyncTriage.isEmpty(json) ? "Empty" : model.syncDisplay(json))
                .foregroundStyle(ProjectSyncTriage.isEmpty(json) ? .tertiary : .primary)
                .lineLimit(4).textSelection(.enabled)
            if newer { Text("Newer").font(.caption2.weight(.semibold)).foregroundStyle(.tint) }
        }
        .frame(minWidth: 60, maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func chooser(_ field: ProjectSyncTriage.FieldDiff) -> some View {
        if (field.state == .incoming && field.merged == nil) || item.record.pageID == nil || item.category == .newInNotion {
            Text(field.state == .incoming || item.category == .newInNotion ? "Notion" : "This Mac").foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Picker("Use", selection: Binding(get: { choices[field.id] }, set: { choices[field.id] = $0 })) {
                    if field.merged != nil {
                        Text("Merge").tag(ProjectSyncTriage.Side?.some(.merge))
                    }
                    Text("This Mac").tag(ProjectSyncTriage.Side?.some(.local))
                    Text("Notion").tag(ProjectSyncTriage.Side?.some(.notion))
                    if field.recommended == nil { Text("Choose").tag(ProjectSyncTriage.Side?.none) }
                }
                .labelsHidden()
                .accessibilityIdentifier("sync.choose.\(field.name)")
                if field.recommended == .merge && choices[field.id] == .merge {
                    Text("Recommended").font(.caption2.weight(.semibold)).foregroundStyle(.tint)
                }
                if choices[field.id] == .merge, let merged = field.merged {
                    Text("Result: \(model.syncDisplay(merged))")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(4).textSelection(.enabled)
                        .accessibilityIdentifier("sync.mergePreview.\(field.name)")
                }
            }
            .frame(maxWidth: 160, alignment: .leading)
        }
    }

    @ViewBuilder private var actions: some View {
        let chosenAll = item.fields.allSatisfy { $0.state == .incoming || choices[$0.id] != nil || item.record.pageID == nil || item.category == .newInNotion }
        HStack {
            switch item.category {
            case .missingFile, .duplicate:
                Button("Discard Draft", role: .destructive) { act(.init(kind: .discard, items: [item])) }
                    .buttonStyle(.borderedProminent)
            case .archive where item.record.archiveRequested:
                Button("Archive in Notion") { act(.init(kind: .chosen, items: [item])) }.buttonStyle(.borderedProminent)
                Button("Keep in Notion") { act(.init(kind: .cancelArchive, items: [item])) }
            case .archive:
                Button(item.record.remoteArchived ? "Accept Archive" : "Accept Restore") { act(.init(kind: .chosen, items: [item])) }
                    .buttonStyle(.borderedProminent)
            default:
                Button(item.record.pageID == nil ? "Send to Notion" : item.category == .newInNotion ? "Bring Here" : "Apply") {
                    act(.init(kind: .chosen, items: [item]))
                }
                .buttonStyle(.borderedProminent).disabled(!chosenAll)
                .accessibilityIdentifier("sync.detail.apply")
                if !ProjectSyncTriage.mergeChoices(item).isEmpty {
                    Button("Merge Multi-value Fields") { act(.init(kind: .merge, items: [item])) }
                        .accessibilityIdentifier("sync.detail.merge")
                }
                if item.record.pageID == nil && item.category != .serviceRecord {
                    Button("Discard Draft", role: .destructive) { act(.init(kind: .discard, items: [item])) }
                }
            }
            Button(deferred ? "Bring Back" : "Decide Later") { act(.init(kind: deferred ? .unlater : .later, items: [item])) }
                .accessibilityIdentifier("sync.detail.later")
        }
    }
}

/// The detailed, record-by-record Get/Send review, kept for first imports and audits.
private struct LegacyReviewLauncher: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Detailed Review").font(.title3.weight(.semibold))
            HStack {
                Button("Changes to Send…") { model.reviewProjectSync(.outgoing, presenterID: "syncCenter") }
                Button("Changes to Receive…") { model.reviewProjectSync(.incoming, presenterID: "syncCenter") }
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(20).frame(width: 420)
        .sheet(item: Binding(get: { model.graphSyncReview?.presenterID == "syncCenter" ? model.graphSyncReview : nil }, set: { model.graphSyncReview = $0 })) { review in
            ProjectSyncReviewView(review: review).environment(model)
        }
    }
}
