import SwiftUI
import AppKit
import BetterWorkspaceCore

/// One navigation layer, organized around the reason for opening a project.
enum ProjectSection: String, CaseIterable, Identifiable {
    case tasks, insights, details, media, portfolio
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

struct ProjectSectionPicker: View {
    @Binding var selection: ProjectSection
    /// Notion-only projects have no local work records to chart, so no Insights.
    var sections: [ProjectSection] = ProjectSection.allCases
    var body: some View {
        Picker("Project view", selection: $selection) {
            ForEach(sections) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented).labelsHidden()
        .accessibilityIdentifier("projects.sections")
        .padding(.horizontal, 16).padding(.bottom, 12)
    }
}

struct ProjectWorkspaceView: View {
    @Environment(AppModel.self) private var model
    let project: WorkspaceItem
    @State private var section = ProjectSection.tasks
    @State private var capability: ProjectToolCapability?

    var body: some View {
        VStack(spacing: 0) {
            header
            ProjectSectionPicker(selection: $section)
            Divider()
            Group {
                switch section {
                case .tasks: ProjectPlanView(local: project, graph: model.graphProject(for: project))
                case .insights: ProjectInsightsView(project: project)
                case .details: ProjectWorkspaceDetails(project: project)
                case .media: ProjectWorkspaceFiles(project: project)
                case .portfolio:
                    if let graph = model.graphProject(for: project) { ProjectPortfolioPresentation(project: graph) }
                    else { ProjectLocalRelatedPresentation(project: project, presentation: .portfolio) }
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // A container, or this identifier replaces every control's own inside it.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("projects.workspace")
        .task(id: project.id) { @MainActor in
            section = .tasks
            capability = await model.projectToolCapability(for: project)
        }
    }

    private var header: some View {
        HStack(spacing: Theme.Space.snug) {
            Button { model.closeProjectWorkspace() } label: { Label("All Projects", systemImage: "chevron.left") }
                .buttonStyle(.borderless).fixedSize()
            Text(model.graphProject(for: project).flatMap { $0.local.isEmpty ? nil : $0.title } ?? project.displayTitle)
                .font(.system(size: 18, weight: .semibold)).lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading).layoutPriority(1)
            ProjectZenButton(item: project, project: model.graphProject(for: project))
            Menu("Actions") {
                if capability?.canExplain == true { Button("Explain") { model.openProjectTool(.explain, for: project) } }
                if capability?.canFlowReview == true { Button("User Flow") { model.openProjectTool(.flowReview, for: project) } }
                if let record = model.projectRecord(for: project), let url = record.notionURL { Button("Open in Notion") { model.open(url) } }
                Button("Reveal in Finder") { model.revealInFinder(project.url) }
                Divider()
                Button("Delete project…", role: .destructive) { model.requestDeletion(of: project) }
            }.menuStyle(.borderlessButton).fixedSize()
        }.padding(.horizontal, Theme.Space.base).padding(.vertical, Theme.Space.snug)
    }
}

/// The Next Action, workable in place: complete it, fix its wording, or delete it,
/// without opening the inspector. Completing has the usual short undo window, after
/// which the card moves on to the next action.
struct NextActionControls: View {
    @Environment(AppModel.self) private var model
    let item: WorkItem
    @State private var editing = false
    @State private var draft = ""
    @State private var confirmingDelete = false
    @State private var saving = false
    @FocusState private var titleFocused: Bool

    private var pending: Bool { model.isPendingCompletion(item) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if editing {
                TextField("Task", text: $draft, axis: .vertical)
                    .font(.title2.weight(.medium))
                    .textFieldStyle(.plain)
                    .lineLimit(1...4)
                    .focused($titleFocused)
                    .onSubmit(saveTitle)
                    .onExitCommand { editing = false }
                    .accessibilityIdentifier("projects.nextAction.titleField")
                HStack {
                    Button("Save", action: saveTitle)
                        .keyboardShortcut(.defaultAction)
                        .disabled(saving || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("projects.nextAction.saveTitle")
                    Button("Cancel") { editing = false }.keyboardShortcut(.cancelAction)
                }
            } else {
                Text(item.title)
                    .font(.title2.weight(.medium))
                    .strikethrough(pending)
                    .foregroundStyle(pending ? .secondary : .primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .onTapGesture(count: 2, perform: beginEditing)
                    .help("Double-click to edit")
                    .accessibilityIdentifier("projects.nextAction.title")
            }
            Text([item.stage.displayName, item.priority == .medium && item.actionMetadata == nil ? nil : "\(item.actionPriorityLabel) priority"]
                    .compactMap { $0 }.joined(separator: " · "))
                .font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Button { model.completeWorkItem(item) } label: {
                    Label(pending ? "Undo" : "Complete", systemImage: pending ? "arrow.uturn.backward" : "checkmark.circle")
                }
                .buttonStyle(.borderedProminent)
                .help(pending ? "Keep it open" : "Mark complete; the next action takes its place")
                .accessibilityIdentifier("projects.nextAction.complete")
                Button("Edit") { model.edit(workItem: item) }
                    .disabled(editing || pending)
                    .help("Edit every detail. Double-click the title to rename it here.")
                    .accessibilityIdentifier("projects.nextAction.edit")
                Spacer()
                if item.kind == .task {
                    Button(role: .destructive) { confirmingDelete = true } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless).foregroundStyle(.secondary)
                        .disabled(pending)
                        .help("Move this task to the Trash")
                        .accessibilityLabel("Delete")
                        .accessibilityIdentifier("projects.nextAction.delete")
                } else {
                    Menu("More actions") {
                        Button("Delete…", role: .destructive) { confirmingDelete = true }
                    }.disabled(pending)
                }
            }
        }
        .confirmationDialog("Delete “\(item.title)”?", isPresented: $confirmingDelete) {
            Button("Move to Trash", role: .destructive) { model.deleteWorkItem(item) }
                .accessibilityIdentifier("projects.nextAction.confirmDelete")
        } message: {
            Text("Are you sure? This file goes to the recoverable Trash. Linked Notion pages stay in Notion.")
        }
    }

    private func beginEditing() {
        guard pending == false else { return }
        draft = item.title
        editing = true
        titleFocused = true
    }

    private func saveTitle() {
        guard saving == false else { return }
        saving = true
        Task { @MainActor in
            defer { saving = false }
            do {
                try await model.renameWorkItem(item, to: draft)
                editing = false
            } catch {
                model.lastError = error.localizedDescription
            }
        }
    }
}

private struct ProjectWorkspaceScore: View {
    @Environment(AppModel.self) private var model
    let project: WorkspaceItem
    var body: some View {
        if let record = model.projectRecord(for: project),
           let score = model.score(for: project, preferences: model.scoringPreferences()) {
            ProjectWorkspaceScoreContent(record: record, score: score, preferences: model.scoringPreferences())
        } else {
            ContentUnavailableView("No project record", systemImage: "chart.bar.xaxis")
        }
    }
}

private struct ProjectWorkspaceScoreContent: View {
    @Environment(AppModel.self) private var model
    let record: ProjectRecord
    let score: ProjectScore
    let preferences: ProjectScoringPreferences

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.base) {
                HStack {
                    VStack(alignment: .leading) {
                        Text("Project Score").font(.title2.weight(.semibold))
                        Text("\(score.answeredCount) of \(score.activeMetrics.count) metrics rated · neutralized by coverage")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(score.projectScore.map { "\(Int($0.rounded()))" } ?? "—")
                        .font(.system(size: 34, weight: .bold).monospacedDigit())
                }
                ForEach(enabledGroups) { group in
                    WorkspaceCard(title: group.displayName.uppercased()) {
                        Text("Group score: \(score.groupScore(for: group).map { String(Int($0.rounded())) } ?? "—")")
                            .font(.caption).foregroundStyle(.secondary)
                        ForEach(group.metrics.filter { preferences.enabledMetricIDs.contains($0.id) }) { metric in
                            ProjectScoreMetricRow(record: record, score: score, metric: metric)
                        }
                    }
                }
            }
            .padding(Theme.Space.loose)
        }
    }

    private var enabledGroups: [MetricGroup] {
        MetricGroup.allGroups.filter {
            preferences.enabledGroupIDs.contains($0.id) &&
            $0.metrics.contains { preferences.enabledMetricIDs.contains($0.id) }
        }
    }
}

struct ScoringPreferenceEditor: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let preferences = model.scoringPreferences()
        VStack(alignment: .leading, spacing: Theme.Space.snug) {
                ForEach(MetricGroup.allGroups) { group in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Toggle(group.displayName, isOn: groupEnabledBinding(group, preferences))
                            Spacer()
                            Stepper("\(Int((preferences.groupWeights[group.id] ?? 0).rounded()))%",
                                    value: groupWeightBinding(group, preferences), in: 0...100, step: 5)
                                .frame(width: 135)
                        }
                        HStack(spacing: 8) {
                            ForEach(group.metrics) { metric in
                                Toggle(metric.displayName, isOn: metricEnabledBinding(metric, preferences))
                                    .toggleStyle(.checkbox).font(.caption)
                            }
                        }
                    }
                    .padding(.vertical, 3)
                }
        }
        .help("Enabled metrics and group weights apply to every project ranking on this Mac.")
    }

    private func groupEnabledBinding(_ group: MetricGroup, _ preferences: ProjectScoringPreferences) -> Binding<Bool> {
        Binding(get: { preferences.enabledGroupIDs.contains(group.id) }, set: { enabled in
            var updated = preferences
            if enabled { updated.enabledGroupIDs.insert(group.id) } else { updated.enabledGroupIDs.remove(group.id) }
            model.setScoringPreferences(updated)
        })
    }

    private func metricEnabledBinding(_ metric: MetricDefinition, _ preferences: ProjectScoringPreferences) -> Binding<Bool> {
        Binding(get: { preferences.enabledMetricIDs.contains(metric.id) }, set: { enabled in
            var updated = preferences
            if enabled { updated.enabledMetricIDs.insert(metric.id) } else { updated.enabledMetricIDs.remove(metric.id) }
            model.setScoringPreferences(updated)
        })
    }

    private func groupWeightBinding(_ group: MetricGroup, _ preferences: ProjectScoringPreferences) -> Binding<Double> {
        Binding(get: { preferences.groupWeights[group.id] ?? MetricGroup.defaultWeights[group.id] ?? 0 }, set: { weight in
            var updated = preferences
            updated.groupWeights[group.id] = weight
            model.setScoringPreferences(updated)
        })
    }
}

private struct ProjectScoreMetricRow: View {
    @Environment(AppModel.self) private var model
    let record: ProjectRecord
    let score: ProjectScore
    let metric: MetricDefinition
    @State private var showAnchors = false

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(metric.displayName)
                    Button { showAnchors.toggle() } label: { Image(systemName: "info.circle") }
                        .buttonStyle(.borderless).foregroundStyle(.secondary)
                        .popover(isPresented: $showAnchors) { MetricAnchorGuide(metric: metric) }
                }
                Text(metric.direction.shortLabel).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            ForEach(1...5, id: \.self) { rating in
                Button("\(rating)") { model.setRating(rating, metric: metric, for: record) }
                    .buttonStyle(.bordered)
                    .tint(score.rating(for: metric) == rating ? .accentColor : .secondary)
                    .controlSize(.small)
                    .help(metric.anchors.first(where: { $0.rating == rating })?.description ?? "Rate \(rating)")
            }
            Button { model.setRating(nil, metric: metric, for: record) } label: { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
        }
    }
}

private struct MetricAnchorGuide: View {
    let metric: MetricDefinition
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(metric.displayName).font(.headline)
            Text(metric.question).font(.callout).foregroundStyle(.secondary)
            ForEach(metric.anchors, id: \.rating) { anchor in
                Text("\(anchor.rating) — \(anchor.label): \(anchor.description)").font(.caption)
            }
        }
        .padding().frame(width: 320, alignment: .leading)
    }
}

private struct ProjectWorkspaceDetails: View {
    @Environment(AppModel.self) private var model
    let project: WorkspaceItem
        @State private var metadata = ProjectMetadata()
    @State private var description = ProjectDescription()
    @State private var related = Set<String>()
    @State private var relationQuery = ""
    @State private var pickingRelated = false
    @State private var showingSuggestions = false
    var body: some View {
        VStack(spacing: 0) {
        ScrollView { VStack(alignment: .leading, spacing: Theme.Space.base) {
            WorkspaceCard(title: "About") {
                DetailText("One-line summary", value: $description.oneLiner); DetailText("Description", value: $description.summary, multiline: true)
                choice("Status", path: \.status, option: "Status"); choice("Phase", path: \.phase, option: "Phase")
                choice("Type", path: \.projectType, option: "Type"); choice("Domain", path: \.domain, option: "domain")
            }
            DisclosureGroup("Lifecycle") { WorkspaceCard(title: "") {
                choice("Completion model", path: \.completionModel, option: "Completion Model")
                    .help("How the project ends: finite, maintained, ongoing, versioned…")
                choice("Maintenance cadence", path: \.maintenanceCadence, option: "Maintenance Cadence")
            } }
            DisclosureGroup("Current work") { WorkspaceCard(title: "") {
                DetailText("Working on", string: commaBinding(\.currentWork)).help("Kinds of work under way, separated by commas")
                DetailText("Up next", string: commaBinding(\.nextWork)).help("Kinds of work that come next, separated by commas")
                DetailText("Blocked by", string: commaBinding(\.blockers)).help("What is holding the project up, separated by commas")
                DetailText("Status detail", value: $metadata.statusDetail, multiline: true)
            } }
            DisclosureGroup("Priority") { WorkspaceCard(title: "") {
                Picker("Portfolio priority", selection: Binding(get: { metadata.portfolioPriority ?? 0 }, set: { metadata.portfolioPriority = $0 == 0 ? nil : $0 })) {
                    Text("Untriaged").tag(0)
                    Text("1 — Someday").tag(1)
                    Text("2 — Low").tag(2)
                    Text("3 — Normal").tag(3)
                    Text("4 — High").tag(4)
                    Text("5 — Critical").tag(5)
                }
                .pickerStyle(.menu)
                .help("Kept on this Mac. In Decide it breaks ties after Now/Next and before task priority.")
            } }
            DisclosureGroup("Related projects · \(related.count)") { WorkspaceCard(title: "") {
                ForEach(relatedItems) { other in
                    HStack {
                        Text(other.displayTitle).lineLimit(1)
                        Spacer()
                        Button { if let id = model.projectRecord(for: other)?.id { related.remove(id) } } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless).foregroundStyle(.secondary).help("Remove link")
                    }
                }
                if relatedItems.isEmpty { Text("None").foregroundStyle(.secondary) }
                Button { pickingRelated = true } label: { Label("Add Related Project", systemImage: "plus") }
                    .buttonStyle(.borderless)
                    .popover(isPresented: $pickingRelated, arrowEdge: .trailing) { relatedPicker }
            } }
            DisclosureGroup("Ratings") { ProjectWorkspaceScore(project: project).frame(height: 340) }
        }.padding(Theme.Space.loose).frame(maxWidth: 760, alignment: .leading).labeledContentStyle(AlignedLabelStyle()) }
            Divider()
            HStack {
                Button { showingSuggestions = true } label: { Label("Suggest…", systemImage: "sparkles") }
                    .disabled(hasUnsavedDetails)
                    .help(hasUnsavedDetails ? "Save or revert your changes first" : "Suggest details with LM Studio")
                    .accessibilityIdentifier("project.lmStudio.open")
                Spacer()
                Button("Revert") { load() }.disabled(!hasUnsavedDetails)
                Button("Save") { model.setProjectDescription(description, for: project); model.saveProjectMetadata(metadata, relatedProjectIDs: related, for: project) }
                    .buttonStyle(.borderedProminent).disabled(!hasUnsavedDetails)
                    .accessibilityIdentifier("project.details.save")
            }
            .padding(.horizontal, Theme.Space.loose).padding(.vertical, 10)
        }.onAppear { load() }
        .sheet(isPresented: $showingSuggestions, onDismiss: { load() }) { ProjectMetadataSuggestionSheet(project: project) }
    }
    private func choice(_ title: String, path: WritableKeyPath<ProjectMetadata, String?>, option: String) -> some View {
        let values = model.projects().compactMap { model.projectMetadata(for: $0)[keyPath: path] }
        return WorkspaceChoiceField(title, selection: Binding(get: { metadata[keyPath: path] ?? "" },
            set: { metadata[keyPath: path] = $0.isEmpty ? nil : $0 }), suggestions: values + (model.ideaProjectPropertyOptions()[option] ?? []), identifier: "project.details." + option, store: TestIsolation.defaults)
    }
    private var hasUnsavedDetails: Bool {
        description != (model.projectDescription(for: project) ?? ProjectDescription()) || metadata != model.projectMetadata(for: project) || related != Set(model.relatedProjects(for: project).compactMap { model.projectRecord(for: $0)?.id })
    }
    private func load() { metadata = model.projectMetadata(for: project); description = model.projectDescription(for: project) ?? ProjectDescription(); related = Set(model.relatedProjects(for: project).compactMap { model.projectRecord(for: $0)?.id }) }
    private func commaBinding(_ path: WritableKeyPath<ProjectMetadata, [String]>) -> Binding<String> { Binding(get: { metadata[keyPath: path].joined(separator: ", ") }, set: { metadata[keyPath: path] = $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }) }
    private var relatedItems: [WorkspaceItem] {
        model.projects().filter { model.projectRecord(for: $0).map { related.contains($0.id) } ?? false }
            .sorted { $0.displayTitle.localizedStandardCompare($1.displayTitle) == .orderedAscending }
    }

    private var relatedPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            InlineSearchField(text: $relationQuery, prompt: "Search projects")
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(relationshipCandidates) { other in
                        if let record = model.projectRecord(for: other) {
                            Button {
                                if related.contains(record.id) { related.remove(record.id) } else { related.insert(record.id) }
                            } label: {
                                HStack {
                                    Image(systemName: related.contains(record.id) ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(related.contains(record.id) ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                                    Text(other.displayTitle).lineLimit(1)
                                    Spacer()
                                }.padding(.vertical, 4).contentShape(Rectangle())
                            }.buttonStyle(.plain)
                        }
                    }
                    if relationshipCandidates.isEmpty { Text("No project matches “\(relationQuery)”.").font(.callout).foregroundStyle(.secondary) }
                }
            }.frame(maxHeight: 260)
        }.padding(14).frame(width: 320)
    }

    private var relationshipCandidates: [WorkspaceItem] {
        let candidates = model.projects().filter { $0.id != project.id }
        let matching = candidates.filter { item in
            relationQuery.isEmpty || item.displayTitle.localizedCaseInsensitiveContains(relationQuery)
        }
        return matching.sorted { lhs, rhs in
            let lhsRelated = model.projectRecord(for: lhs).map { related.contains($0.id) } ?? false
            let rhsRelated = model.projectRecord(for: rhs).map { related.contains($0.id) } ?? false
            if lhsRelated != rhsRelated { return lhsRelated }
            return lhs.displayTitle.localizedStandardCompare(rhs.displayTitle) == .orderedAscending
        }.prefix(relationQuery.isEmpty ? 12 : 40).map { $0 }
    }
}

/// Labels in one column, so every field starts in the same place.
private struct AlignedLabelStyle: LabeledContentStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.base) {
            configuration.label.foregroundStyle(.secondary).frame(width: 130, alignment: .trailing)
            configuration.content.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct DetailText: View {
    let label: String; var value: Binding<String?>? = nil; var string: Binding<String>? = nil; var multiline = false
    init(_ label: String, value: Binding<String?>, multiline: Bool = false) { self.label = label; self.value = value; self.multiline = multiline }
    init(_ label: String, string: Binding<String>) { self.label = label; self.string = string }
    var body: some View { LabeledContent(label) { if let string { TextField(label, text: string) } else if let value { if multiline { TextEditor(text: Binding(get: { value.wrappedValue ?? "" }, set: { value.wrappedValue = $0.isEmpty ? nil : $0 })).frame(minHeight: 70) } else { TextField(label, text: Binding(get: { value.wrappedValue ?? "" }, set: { value.wrappedValue = $0.isEmpty ? nil : $0 })) } } } }
}

struct ProjectWorkspaceActivity: View {
    @Environment(AppModel.self) private var model
    let project: WorkspaceItem
    var body: some View { let record = model.projectRecord(for: project); let sessions = record?.watcherID.map { id in model.recentSessions.filter { $0.projectID == id } } ?? []
        return ScrollView { VStack(alignment: .leading, spacing: Theme.Space.base) { Text("Activity").font(.title2.weight(.semibold)); WorkspaceCard(title: "OBSERVED WORK") { if sessions.isEmpty { Text("No observed sessions are available. Filesystem recency is shown separately and is not treated as proof of work.").foregroundStyle(.secondary) } else { ForEach(sessions) { session in VStack(alignment: .leading) { Text(Format.relativeDate(session.endedAt)); Text("\(Format.duration(seconds: session.activeSeconds)) · \(session.interestingFiles.prefix(3).joined(separator: ", "))").font(.caption).foregroundStyle(.secondary) } } } }; WorkspaceCard(title: "FILESYSTEM") { Text("Last content change: \(Format.relativeDate(project.contentModifiedAt))").foregroundStyle(.secondary) } }.padding(Theme.Space.loose) }
    }
}

private struct ProjectWorkspaceFiles: View {
    @Environment(AppModel.self) private var model
    let project: WorkspaceItem
    @State private var children: [WorkspaceItem] = []
    @State private var showFiles = false
    @State private var importing = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("Media view", selection: $showFiles) { Text("Gallery").tag(false); Text("Files").tag(true) }
                    .pickerStyle(.segmented).frame(width: 180)
                Spacer()
                if model.graphProject(for: project) == nil {
                    Button("Add media file…") { chooseFile() }.disabled(importing)
                }
            }.padding(12)
            if !showFiles, let graph = model.graphProject(for: project) { ProjectMediaGallery(project: graph) }
            else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Text(showFiles ? "Project files" : "Media").font(.title2.weight(.semibold))
                        if !showFiles {
                            let media = children.filter { [.image, .video, .audio].contains($0.kind) || $0.url.pathExtension.lowercased() == "pdf" }
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 180))], alignment: .leading, spacing: 14) {
                                ForEach(media) { child in
                                    Button { model.open(child.url) } label: {
                                        VStack(alignment: .leading, spacing: 8) {
                                            ThumbnailImage(url: child.url, kind: child.kind, size: 180, contentMode: .fit).frame(height: 140)
                                            Text(child.displayTitle).lineLimit(2)
                                        }.frame(maxWidth: .infinity, alignment: .leading)
                                    }.buttonStyle(.plain)
                                }
                            }
                            if media.isEmpty { Text("No media in this folder yet. Add a file or use Media/ or docs/images/ for project captures.").foregroundStyle(.secondary) }
                            Text("Link an Assets source in Settings to assign thumbnails, icons and collection relationships.").font(.caption).foregroundStyle(.secondary)
                        } else {
                            ForEach(children) { child in
                                Button { model.open(child.url) } label: {
                                    Label(child.displayTitle, systemImage: child.kind.symbolName).frame(maxWidth: .infinity, alignment: .leading)
                                }.buttonStyle(.plain)
                            }
                            if children.isEmpty { Text("No direct contents loaded.").foregroundStyle(.secondary) }
                        }
                    }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }.task(id: "\(model.revision(ofArea: "Projects"))-\(showFiles)") { await load() }
    }
    @MainActor private func load() async {
        if let result = await model.children(of: project.url) {
            children = result
            // Explicit, bounded media roots; do not crawl arbitrary project contents.
            if !showFiles, model.graphProject(for: project) == nil {
                for relative in ["Media", "docs/images"] {
                    let folder = project.url.appendingPathComponent(relative)
                    if folder.canonicalPath.hasPrefix(project.url.canonicalPath + "/"),
                       folder.resolvingSymlinksInPath().canonicalPath.hasPrefix(project.url.resolvingSymlinksInPath().canonicalPath + "/"),
                       FileManager.default.fileExists(atPath: folder.path), let media = await model.children(of: folder) {
                        children.append(contentsOf: media.filter { $0.url.resolvingSymlinksInPath().canonicalPath.hasPrefix(project.url.resolvingSymlinksInPath().canonicalPath + "/") })
                    }
                }
            }
        }
    }
    private func chooseFile() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.message = "Add a copy of this media file to the project through ingest. The original is retained."
        guard panel.runModal() == .OK, let selected = panel.url else { return }
        let ingest = model.ingest, destination = project.url
        importing = true
        Task { @MainActor in
            defer { importing = false }
            do {
                _ = try await Task.detached {
                    let imported = try ingest.importItem(at: selected)
                    return try ingest.classify(imported, intoDirectory: destination, renamingTo: nil)
                }.value
                await load()
            } catch { model.lastError = error.localizedDescription }
        }
    }
}

private struct WorkspaceCard<Content: View>: View { let title: String; var emphasized = false; @ViewBuilder let content: Content; var body: some View { VStack(alignment: .leading, spacing: Theme.Space.snug) { if !title.isEmpty { Text(title).font(.headline) }; content }.padding(Theme.Space.base).frame(maxWidth: .infinity, alignment: .leading).background(emphasized ? Color.accentColor.opacity(0.08) : Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: Theme.Radius.card)).overlay(RoundedRectangle(cornerRadius: Theme.Radius.card).strokeBorder(Color.secondary.opacity(0.14))) } }

