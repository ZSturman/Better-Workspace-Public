import SwiftUI
import BetterWorkspaceCore

struct ProjectSyncReviewView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let review: ProjectSyncReview
    @State private var selected = Set<String>()
    @State private var resolutions: [String: [String: Bool]] = [:]
    @State private var error: String?
    @State private var expanded = Set<String>()
    @State private var reconciliation: [String: String] = [:]
    @State private var search = ""
    @State private var type = "all"
    @State private var project = "all"
    @State private var expandedGroups: Set<ProjectSyncReviewPlan.Group> = [.relevant]
    @State private var expandedTypes: Set<String> = ["relevant.projects"]
    @State private var automaticChoiceMessage: String?
    @State private var limits: [String: Int] = [:]
    private var visible: [ProjectSyncReviewPlan.Entry] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return review.plan.entries.filter { entry in
            (type == "all" || entry.record.kind.rawValue == type) &&
            (project == "all" || (project == "unassigned" ? entry.projectIDs.isEmpty : entry.projectIDs.contains(project))) &&
            (query.isEmpty || ([entry.record.title, entry.record.kind.title] + entry.projectNames).contains { $0.localizedCaseInsensitiveContains(query) })
        }
    }
    private var visibleIDs: Set<String> { Set(visible.map(\.id)) }
    private var conflictsResolved: Bool {
        review.plan.entries.filter { selected.contains($0.id) }.allSatisfy { entry in
            entry.changes.filter { $0.state == .conflict }.allSatisfy { resolutions[entry.id]?[$0.id] != nil }
        }
    }
    private var choiceCounts: (local: Int, notion: Int, unresolved: Int) {
        var counts = (local: 0, notion: 0, unresolved: 0)
        for entry in review.plan.entries where selected.contains(entry.id) {
            for change in entry.changes where change.state != .equal {
                if let local = choice(for: change, recordID: entry.id) {
                    if local { counts.local += 1 } else { counts.notion += 1 }
                } else { counts.unresolved += 1 }
            }
        }
        return counts
    }
    private func choice(for change: ProjectFieldChange, recordID: String) -> Bool? {
        switch change.state {
        case .conflict: return resolutions[recordID]?[change.id]
        case .incoming, .equal: return false
        case .outgoing: return true
        }
    }
    private func chooseNewest() {
        var chosen = 0, unknown = 0
        for entry in review.plan.entries where selected.contains(entry.id) {
            for change in entry.changes where change.state == .conflict {
                if let local = entry.record.newestConflictChoice(for: change.id) {
                    resolutions[entry.id, default: [:]][change.id] = local
                    chosen += 1
                } else {
                    // Keep an existing manual decision when dates cannot decide.
                    unknown += 1
                }
            }
            if entry.changes.contains(where: { $0.state == .conflict }) {
                expandedGroups.insert(entry.group); expanded.insert(entry.id)
            }
        }
        automaticChoiceMessage = "Chose \(chosen) conflicting fields by date. \(unknown) have missing or tied dates; existing manual choices are kept. Review the marked choices before Apply."
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(review.createProjectOnly ? "Add project to Notion" : review.direction == .incoming ? "Get Notion Changes" : "Send to Notion").font(.title2.bold())
            if review.createProjectOnly {
                Text("Create only this project page. Related tasks, relationships and media stay pending for a separate Send review.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if review.plan.initialCount > 0 && review.direction == .incoming {
                Text("First import includes \(review.plan.initialCount.formatted()) existing Notion records. Select groups together; historical work is kept below.").font(.callout).foregroundStyle(.secondary)
            } else {
                Text("Review changes by project. Conflicts and failures come first.").foregroundStyle(.secondary)
            }
            Text("\(review.plan.entries.filter { $0.group == .attention }.count.formatted()) need attention · \(review.plan.recommendedIDs.count.formatted()) recommended · \(review.plan.entries.filter { $0.group == .history }.count.formatted()) historical or completed").font(.caption).foregroundStyle(.secondary)
            HStack {
                TextField("Search records or projects", text: $search).textFieldStyle(.roundedBorder).accessibilityIdentifier("projects.sync.search")
                Picker("Type", selection: $type) {
                    Text("All types").tag("all")
                    ForEach(ProjectEntityKind.allCases.filter { kind in review.records.contains { $0.kind == kind } }) { kind in Text(kind.title).tag(kind.rawValue) }
                }.labelsHidden().frame(width: 130).accessibilityIdentifier("projects.sync.type")
                Picker("Project", selection: $project) {
                    Text("All projects").tag("all")
                    Text("Unassigned").tag("unassigned")
                    ForEach(review.plan.projects) { item in Text("\(item.title) · \(item.count)").tag(item.id) }
                }.labelsHidden().frame(width: 175).accessibilityIdentifier("projects.sync.project")
            }
            HStack {
                Text("\(selected.count.formatted()) selected · \(visible.count.formatted()) shown").font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("projects.sync.selection")
                Spacer()
                Button("Select recommended") { selected = review.plan.recommendedIDs.intersection(visibleIDs) }.accessibilityIdentifier("projects.sync.recommended")
                Menu("Selection") {
                    Button("Select all without conflicts or warnings") { selected = review.plan.safeIDs.intersection(visibleIDs) }
                    Button("Clear selection") { selected = [] }
                }
            }.buttonStyle(.borderless)
            HStack {
                Label("Local", systemImage: "desktopcomputer").foregroundStyle(.blue)
                Label("Notion", systemImage: "cloud").foregroundStyle(.purple)
                Text("Checkmark = value to use").foregroundStyle(.secondary)
                Spacer()
                Button("Choose newest conflicts") { chooseNewest() }
                    .disabled(selected.isEmpty || model.graphBusy)
                    .accessibilityIdentifier("projects.sync.newest")
            }.font(.caption)
            if let automaticChoiceMessage { Text(automaticChoiceMessage).font(.caption).foregroundStyle(.secondary) }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(ProjectSyncReviewPlan.Group.allCases) { group in
                        let entries = visible.filter { $0.group == group }
                        if !entries.isEmpty { reviewGroup(group, entries: entries) }
                    }
                    if visible.isEmpty { ContentUnavailableView.search(text: search) }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("projects.sync.records")
            if selected.subtracting(visibleIDs).count > 0 {
                Text("\(selected.subtracting(visibleIDs).count.formatted()) selected records are hidden by filters. Select recommended again to limit selection to these results.").font(.caption).foregroundStyle(.orange)
            }
            let counts = choiceCounts
            Text("Apply uses: Local \(counts.local) fields · Notion \(counts.notion) fields · \(counts.unresolved) unresolved")
                .font(.caption.weight(.semibold)).accessibilityIdentifier("projects.sync.choices")
            Text(review.direction == .incoming ? "Get applies Notion choices here. Local choices stay here and remain pending for Send." : "Send writes Local choices to Notion. Notion choices keep the remote value and update the local record.")
                .font(.caption).foregroundStyle(.secondary)
            if !conflictsResolved { Text("Choose Local or Notion for selected conflicting fields before applying.").font(.caption).foregroundStyle(.orange) }
            if let error { Text(error).foregroundStyle(.red).font(.caption) }
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(model.graphBusy)
                Spacer()
                if model.graphBusy { ProgressView().controlSize(.small) }
                Button(review.createProjectOnly ? "Add to Notion" : "Apply \(selected.count.formatted()) Records") {
                    Task { @MainActor in
                        do { try await model.applyProjectSync(review, selected: selected, resolutions: resolutions); dismiss() }
                        catch { self.error = error.localizedDescription }
                    }
                }.buttonStyle(.borderedProminent).disabled(selected.isEmpty || !conflictsResolved || model.graphBusy).accessibilityIdentifier("projects.sync.apply")
            }
        }.padding(20).frame(width: 700, height: 580)
        .onAppear { selected = review.direction == .incoming ? review.plan.recommendedIDs : review.plan.safeIDs }
        .interactiveDismissDisabled(model.graphBusy)
    }
    @ViewBuilder private func reviewGroup(_ group: ProjectSyncReviewPlan.Group, entries: [ProjectSyncReviewPlan.Entry]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                if !expandedGroups.insert(group).inserted { expandedGroups.remove(group) }
            } label: {
                HStack {
                    Image(systemName: expandedGroups.contains(group) ? "chevron.down" : "chevron.right")
                    Text(group.title).fontWeight(.semibold)
                    Spacer()
                    Text("\(entries.count.formatted()) · \(entries.filter { selected.contains($0.id) }.count.formatted()) selected").foregroundStyle(.secondary)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityIdentifier("projects.sync.group.\(group.rawValue)")
            if expandedGroups.contains(group) {
                if group == .attention {
                    recordList(entries, key: group.rawValue)
                } else {
                    if group == .relevant { Text("Recommended: unfinished work and data connected to active or local projects.").font(.caption).foregroundStyle(.secondary) }
                    if group == .history { Text("Historical logs and completed work stay available. Select a source to import them together.").font(.caption).foregroundStyle(.secondary) }
                    ForEach(ProjectEntityKind.allCases) { kind in
                        let items = entries.filter { $0.record.kind == kind }
                        if !items.isEmpty {
                            let key = group.rawValue + "." + kind.rawValue
                            let ids = Set(items.map(\.id))
                            HStack {
                                Toggle("\(kind.title) · \(items.count.formatted())", isOn: Binding(get: { ids.isSubset(of: selected) }, set: { if $0 { selected.formUnion(ids) } else { selected.subtract(ids) } }))
                                    .toggleStyle(.checkbox).accessibilityIdentifier("projects.sync.batch.\(key)")
                                Spacer()
                                Text("\(ids.intersection(selected).count.formatted()) selected").font(.caption).foregroundStyle(.secondary)
                                Button(expandedTypes.contains(key) ? "Hide records" : "Show records") {
                                    if !expandedTypes.insert(key).inserted { expandedTypes.remove(key) }
                                }.buttonStyle(.borderless).accessibilityIdentifier("projects.sync.show.\(key)")
                            }
                            if expandedTypes.contains(key) { recordList(items, key: key) }
                        }
                    }
                }
            }
        }.padding(12).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    }
    @ViewBuilder private func recordList(_ entries: [ProjectSyncReviewPlan.Entry], key: String) -> some View {
        ForEach(Array(entries.prefix(limits[key] ?? (key == "relevant.projects" ? 5 : 10)))) { entry in recordRow(entry) }
        if entries.count > (limits[key] ?? (key == "relevant.projects" ? 5 : 10)) {
            Button("Show 20 more · \(entries.count - (limits[key] ?? (key == "relevant.projects" ? 5 : 10))) remaining") { limits[key] = (limits[key] ?? (key == "relevant.projects" ? 5 : 10)) + 20 }.buttonStyle(.borderless)
        }
    }
    private func recordRow(_ entry: ProjectSyncReviewPlan.Entry) -> some View {
        let record = entry.record
        return VStack(alignment: .leading, spacing: 8) {
            Toggle("\(record.title) · \(record.kind.title)", isOn: Binding(get: { selected.contains(record.id) }, set: {
                if $0 { selected.insert(record.id); if entry.group == .attention { expanded.insert(record.id) } }
                else { selected.remove(record.id) }
            })).disabled(record.ambiguousCreate).accessibilityIdentifier("projects.sync.record.\(record.id)")
            Text(entry.reason + (entry.projectNames.isEmpty || record.kind == .projects ? "" : " · " + entry.projectNames.prefix(2).joined(separator: ", "))).font(.caption).foregroundStyle(entry.group == .attention ? .orange : .secondary)
            ForEach(record.pendingUploads ?? []) { upload in Label("Upload \(upload.filename) · \(upload.byteCount / 1024) KB", systemImage: "arrow.up.doc").font(.caption) }
            if record.remoteArchived != (record.acknowledgedArchived ?? false) { Text(record.remoteArchived ? "Notion archived this page" : "Notion restored this page").font(.caption).foregroundStyle(.secondary) }
            if record.archiveRequested { Label("Archive this page in Notion", systemImage: "archivebox").foregroundStyle(.orange) }
            if record.ambiguousCreate {
                Text("Creation needs reconciliation; retrying could duplicate this record.").foregroundStyle(.orange)
                TextField("Created Notion page ID", text: Binding(get: { reconciliation[record.id] ?? "" }, set: { reconciliation[record.id] = $0 }))
                Button("Verify and link created page") { Task { @MainActor in
                    do {
                        guard let token = SecretStore.read() else { throw NotionClient.Failure.noCredentials }
                        let raw = reconciliation[record.id] ?? ""
                        let id = NotionSettings.databaseID(from: raw) ?? raw
                        try await NotionProjectSync(store: ProjectGraphStore(database: model.database), client: NotionClient(token: token)).reconcileCreation(recordID: record.id, pageID: id)
                        model.reloadProjectGraph(); dismiss()
                    } catch { self.error = error.localizedDescription }
                } }.disabled((reconciliation[record.id] ?? "").isEmpty || model.graphBusy)
            }
            DisclosureGroup("\(entry.changes.filter { $0.state != .equal }.count) fields\(entry.changes.contains { $0.state == .conflict } ? " · conflicts need review" : "")", isExpanded: Binding(get: { expanded.contains(record.id) }, set: { if $0 { expanded.insert(record.id) } else { expanded.remove(record.id) } })) {
                ForEach(entry.changes.filter { $0.state != .equal }) { change in fieldReview(change, record: record) }
            }
            if let error = record.error { Text(error).font(.caption).foregroundStyle(.red) }
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(selected.contains(record.id) ? Color.accentColor.opacity(0.06) : Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(selected.contains(record.id) ? Color.accentColor.opacity(0.5) : .clear))
    }
    private func fieldReview(_ change: ProjectFieldChange, record: ProjectGraphRecord) -> some View {
        let useLocal = choice(for: change, recordID: record.id)
        return VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(model.graphSource(for: record)?.name(for: change.id) ?? change.id).font(.subheadline.weight(.semibold))
                Spacer()
                if change.state == .conflict { Label("Conflict", systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
            }
            HStack(alignment: .top, spacing: 8) {
                valueChoice(change.local, local: true, chosen: useLocal == true, date: record.localFieldEditedAt?[change.id], change: change, record: record)
                valueChoice(change.remote, local: false, chosen: useLocal == false, date: record.editedAt, change: change, record: record)
            }
            if change.state == .conflict {
                Text("Last shared value: " + (change.baseline.display.isEmpty ? "(empty)" : change.baseline.display)).foregroundStyle(.secondary).textSelection(.enabled)
                Text("Newest compares the local field edit with Notion's page edit time, which may include edits to other fields. Missing or tied dates need a manual choice.")
                    .foregroundStyle(.secondary)
                if useLocal == nil { Text("Choose a value above").foregroundStyle(.orange) }
            }
            if !selected.contains(record.id) { Text("Record not selected — this field will not be applied.").foregroundStyle(.secondary) }
        }.font(.caption).padding(.vertical, 8)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("projects.sync.field.\(record.id).\(change.id)")
    }
    private func valueChoice(_ value: ProjectJSON, local: Bool, chosen: Bool, date: Date?, change: ProjectFieldChange, record: ProjectGraphRecord) -> some View {
        let color: Color = local ? .blue : .purple
        return Button {
            resolutions[record.id, default: [:]][change.id] = local
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Label(local ? "Local" : "Notion", systemImage: local ? "desktopcomputer" : "cloud").foregroundStyle(color).fontWeight(.semibold)
                    Spacer(minLength: 2)
                    if chosen { Image(systemName: "checkmark.circle.fill").foregroundStyle(color) }
                }
                Text(value.display.isEmpty ? "(empty)" : value.display).foregroundStyle(.primary).multilineTextAlignment(.leading).textSelection(.enabled)
                Text(date.map { (local ? "Field edited " : "Page edited ") + $0.formatted(date: .abbreviated, time: .standard) } ?? "Edit time unknown").foregroundStyle(.secondary).font(.caption2)
                Text(chosen ? (selected.contains(record.id) ? "Selected to use" : "Value chosen · record excluded") : change.state == .conflict ? "Click to choose" : "Not used in this review")
                    .foregroundStyle(chosen ? color : .secondary).font(.caption2.weight(.medium))
            }.frame(maxWidth: .infinity, alignment: .leading).padding(9)
                .background(color.opacity(chosen ? 0.12 : 0.03), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(color.opacity(chosen ? 0.9 : 0.2), lineWidth: chosen ? 2 : 1))
        }.buttonStyle(.plain).disabled(change.state != .conflict || model.graphBusy)
            .accessibilityIdentifier("projects.sync.choice.\(record.id).\(change.id)." + (local ? "local" : "notion"))
            .accessibilityAddTraits(chosen ? .isSelected : [])
    }
}

struct NotionProjectIntegrationView: View {
    @Environment(AppModel.self) private var model
    @AppStorage("projectGraphBackgroundChecks", store: TestIsolation.defaults) private var background = true
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Import project data from Notion").font(.headline)
                .help("Projects, work, media assets, resources, collections, versions, notes, ideas, posts and work logs")
            Text("\(model.graphReport?.workspaceName ?? "Notion") / \(model.graphSources.first { $0.kind == .projects }?.title ?? "Projects")")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Preview Notion Project Data") { Task { await model.checkProjectGraph(forceFull: true) } }
                    .disabled(!model.hasNotionToken || model.graphBusy)
                Button("Import Reviewed Changes…") { model.reviewProjectSync(.incoming) }
                    .disabled(model.graphPending(.incoming) == 0 || model.graphBusy)
            }
            Toggle("Sync automatically", isOn: Binding(get: { model.notionAutoSync }, set: { model.notionAutoSync = $0 }))
                .help("Changes move both ways on their own. Conflicts, deletions, uploads and background-service records always wait for you in the Sync Center.")
                .accessibilityIdentifier("settings.notionAutoSync")
            if !model.notionAutoSync {
                Toggle("Check for changes in the background every 15 minutes", isOn: $background)
                    .font(.caption)
            }
            Button("Open Sync Center") { model.showingSyncCenter = true }
            DisclosureGroup("Sources and import results") {
                ForEach(model.graphSources) { source in
                    HStack { Text(source.title); Spacer(); Text("\(model.graphReport?.counts[source.title] ?? 0) records").foregroundStyle(.secondary) }
                }
                DisclosureGroup("Configure related sources") {
                    ForEach(ProjectEntityKind.allCases) { kind in
                        TextField(kind.title, text: Binding(get: {
                            let overrides = TestIsolation.defaults.dictionary(forKey: NotionGraphConfiguration.sourceOverridesKey) as? [String: String] ?? [:]
                            return overrides[kind.rawValue] ?? model.graphSources.first { $0.kind == kind }?.id ?? ""
                        }, set: { value in
                            var overrides = TestIsolation.defaults.dictionary(forKey: NotionGraphConfiguration.sourceOverridesKey) as? [String: String] ?? [:]
                            overrides[kind.rawValue] = NotionSettings.databaseID(from: value) ?? value.trimmingCharacters(in: .whitespacesAndNewlines)
                            TestIsolation.defaults.set(overrides, forKey: NotionGraphConfiguration.sourceOverridesKey)
                        }))
                    }
                    Text("Clearing a configured source explicitly excludes that record type. Sources without an override are discovered through relations. Archived Social Posts remains a separate legacy migration source.").foregroundStyle(.secondary)
                }
                ForEach((model.graphReport?.failures ?? [:]).keys.sorted(), id: \.self) { source in
                    Text("\(source): \(model.graphReport?.failures[source] ?? "")").foregroundStyle(.red)
                }
                ForEach((model.graphReport?.referenceDetails ?? [:]).keys.sorted(), id: \.self) { name in
                    Text("\(name): \(model.graphReport?.referenceDetails?[name] ?? 0)").foregroundStyle(.secondary)
                }
                Text("\(model.graphReport?.unresolvedReferences ?? 0) references outside imported records; external sources remain links, including Automation Logs and legacy Social Posts.")
                    .foregroundStyle(.secondary)
            }.font(.caption)
        }.onAppear { model.reloadProjectGraph() }
        .sheet(item: Binding(get: { model.graphSyncReview?.presenterID == "settings" ? model.graphSyncReview : nil }, set: { model.graphSyncReview = $0 })) { ProjectSyncReviewView(review: $0) }
    }
}
