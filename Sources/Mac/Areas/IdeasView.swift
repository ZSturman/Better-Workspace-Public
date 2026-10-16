import SwiftUI
import BetterWorkspaceCore

/// Ideas are a lightweight working notebook. The idea folders and files remain normal
/// filesystem objects, but this area intentionally permits explicit editing, creation
/// and attachment import so an idea can grow without a Finder round trip.
struct IdeasView: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""
    @State private var sort: Sort = .priority
    @State private var creation: IdeaCreation?

    enum Sort: String, CaseIterable, Identifiable {
        case priority = "Priority & score"
        case newest = "Newest"
        case oldest = "Oldest"
        case alphabetical = "A–Z"
        var id: String { rawValue }
    }

    private var items: [WorkspaceItem] {
        var result = model.items(for: .ideas)
        if query.isEmpty == false {
            result = result.filter { item in
                let idea = model.ideaRecord(for: item.url)
                let described = [idea?.oneLiner, idea?.status, idea?.type, idea?.impact, idea?.planning?.potential?.title, idea?.planning?.project?.metadata.domain, idea?.planning?.project?.metadata.projectType, idea?.planning?.project?.metadata.phase, idea?.planning?.project?.oneLiner, idea?.planning?.project?.summary].compactMap { $0 }
                return item.displayTitle.localizedCaseInsensitiveContains(query)
                    || described.contains { $0.localizedCaseInsensitiveContains(query) }
                    || model.tags(for: item).contains { $0.name.localizedCaseInsensitiveContains(query) }
            }
        }
        switch sort {
        case .priority:
            let preferences = model.scoringPreferences()
            let keys = Dictionary(uniqueKeysWithValues: result.map { item in
                let planning = model.ideaRecord(for: item.url)?.planning
                return (item.id, (planning?.priority ?? 3, planning?.score(preferences: preferences).projectScore ?? -.infinity))
            })
            result.sort { lhs, rhs in
                let a = keys[lhs.id]!, b = keys[rhs.id]!
                if a.0 != b.0 { return a.0 > b.0 }
                if a.1 != b.1 { return a.1 > b.1 }
                return lhs.displayTitle.localizedStandardCompare(rhs.displayTitle) == .orderedAscending
            }
        case .newest:
            result.sort { ($0.contentModifiedAt ?? .distantPast) > ($1.contentModifiedAt ?? .distantPast) }
        case .oldest:
            result.sort { ($0.contentModifiedAt ?? .distantFuture) < ($1.contentModifiedAt ?? .distantFuture) }
        case .alphabetical:
            result.sort { $0.displayTitle.localizedStandardCompare($1.displayTitle) == .orderedAscending }
        }
        return result
    }

    /// Not read yet, so an empty list here would be a false "nothing".
    private var showsLoading: Bool { items.isEmpty && model.isAwaitingFirstRead(of: .ideas) }

    var body: some View {
        let scoringPreferences = model.scoringPreferences()
        VStack(spacing: 0) {
            AreaHeader(title: "Ideas", subtitle: model.headerSubtitle(for: .ideas), symbol: model.settings(for: .ideas).symbol, count: showsLoading ? nil : items.count) {
                HStack(spacing: Theme.Space.snug) {
                    InlineSearchField(text: $query, prompt: "Search ideas")
                    Picker("", selection: $sort) {
                        ForEach(Sort.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .frame(width: 150)
                    Menu {
                        Button { creation = .note } label: { Label("New Note", systemImage: "doc.badge.plus") }
                        Button { creation = .folder } label: { Label("New Folder", systemImage: "folder.badge.plus") }
                        Divider()
                        Button { importFromFinder() } label: { Label("Add Files…", systemImage: "plus.rectangle.on.folder") }
                    } label: {
                        Label("Add to Ideas", systemImage: "plus")
                    }
                    .accessibilityIdentifier("ideas.add")
                }
            }
            Divider()

            if showsLoading {
                LoadingAreaState(title: "Loading ideas…")
            } else if items.isEmpty {
                EmptyAreaState(
                    symbol: "lightbulb",
                    title: query.isEmpty ? "No ideas yet" : "No matching ideas",
                    message: query.isEmpty
                        ? "Capture something in the inbox and classify it as an Idea."
                        : "Nothing here matches “\(query)”."
                )
            } else {
                HSplitView {
                    List(items, selection: selectedIdeaID) { item in
                        let idea = model.ideaRecord(for: item.url)
                        IdeaRow(item: item, idea: idea,
                                isSelected: model.selectedItem?.id == item.id, tags: model.tags(for: item), scoringPreferences: scoringPreferences,
                                notionPromotion: idea.flatMap { model.showsNotionIdeaPromotion($0) ? model.notionIdeaPromotionStatus($0) : nil })
                            .tag(item.id)
                            .contentShape(Rectangle())
                            .onTapGesture { model.selectedItem = item }
                            .contextMenu { ItemContextMenu(item: item) }
                    }
                    .listStyle(.sidebar)
                    .frame(minWidth: 230, idealWidth: 310, maxWidth: 390, maxHeight: .infinity)

                    IdeaWorkspacePane(item: selectedIdea)
                        .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .sheet(item: $creation) { kind in
            IdeaNameSheet(kind: kind, targetName: targetDirectory.lastPathComponent,
                          canClassify: targetDirectory.canonicalPath == model.workspace.url(for: .ideas).canonicalPath) { name, potential in
                let target = targetDirectory
                Task { @MainActor in
                    do {
                        let item: WorkspaceItem
                        switch kind {
                        case .note: item = try await model.createIdeaNote(named: name, in: target)
                        case .folder: item = try await model.createIdeaFolder(named: name, in: target)
                        }
                        if let potential { await model.classifyCreatedIdea(item, as: potential) }
                    } catch { model.lastError = error.localizedDescription }
                }
            }
        }
    }

    private var selectedIdea: WorkspaceItem? {
        guard let selected = model.selectedItem,
              model.workspace.areaName(containing: selected.url) == WorkspaceArea.ideas.directoryName else { return nil }
        return selected
    }

    private var selectedIdeaID: Binding<WorkspaceItem.ID?> {
        Binding(get: { selectedIdea?.id }, set: { id in model.selectedItem = items.first(where: { $0.id == id }) })
    }

    /// Add into a selected idea folder, or beside a selected loose idea file. This is
    /// resolved from the live URL rather than a copied folder model.
    private var targetDirectory: URL {
        guard let selected = selectedIdea else { return model.workspace.url(for: .ideas) }
        return selected.isDirectory ? selected.url : selected.url.deletingLastPathComponent()
    }

    private func importFromFinder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Add to Ideas"
        guard panel.runModal() == .OK else { return }
        let target = targetDirectory
        Task {
            do { _ = try await model.importIdeaItems(panel.urls, into: target) }
            catch { model.lastError = error.localizedDescription }
        }
    }
}

private enum IdeaCreation: String, Identifiable {
    case note, folder
    var id: String { rawValue }
    var title: String { self == .note ? "New Idea Note" : "New Idea Folder" }
    var prompt: String { self == .note ? "Note name" : "Folder name" }
}

private struct IdeaNameSheet: View {
    @Environment(\.dismiss) private var dismiss
    let kind: IdeaCreation
    let targetName: String
    let canClassify: Bool
    let save: (String, IdeaPromotionKind?) -> Void
    @State private var potential: IdeaPromotionKind?
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.base) {
            Text(kind.title).font(.title3.weight(.semibold))
            Text("It will be created in \(targetName).")
                .font(.callout).foregroundStyle(.secondary)
            TextField(kind.prompt, text: $name).textFieldStyle(.roundedBorder)
            if canClassify {
                Picker("Classification", selection: $potential) {
                    Text("Unclassified").tag(IdeaPromotionKind?.none)
                    ForEach(IdeaPromotionKind.allCases) { kind in Text("Potential " + kind.title).tag(Optional(kind)) }
                }.accessibilityIdentifier("idea.creation.classification")
            }
            HStack { Spacer(); Button("Cancel") { dismiss() }; Button("Create") { save(name, potential); dismiss() }.buttonStyle(.borderedProminent).disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
        }
        .padding(Theme.Space.section)
        .frame(width: 360)
    }
}

private struct IdeaWorkspacePane: View {
    @Environment(AppModel.self) private var model
    let item: WorkspaceItem?
    @State private var children: [WorkspaceItem] = []
    @State private var couldNotLoad = false
    @State private var scoring = false
    @State private var promotion: IdeaPromotionKind?

    var body: some View {
        Group {
            if let item {
                if item.isDirectory {
                    folder(item)
                } else if IdeaFileService.isEditableText(item.url) {
                    IdeaTextEditor(item: item)
                } else {
                    unsupportedFile(item)
                }
            } else {
                EmptyAreaState(symbol: "lightbulb", title: "Select an idea", message: "Choose an idea to edit its note, attachments, folders, and tags.")
            }
        }
        .task(id: item?.id) { await loadChildren() }
        .safeAreaInset(edge: .top) {
            if let item {
                HStack {
                    Button("Details…", systemImage: "slider.horizontal.3") { scoring = true }.accessibilityIdentifier("idea.planning.edit")
                    Spacer()
                    Menu {
                        if let idea = model.ideaRecord(for: item.url) {
                            if model.showsNotionIdeaPromotion(idea), let status = model.notionIdeaPromotionStatus(idea) {
                                Button("Review Notion promotion (" + status + ")…") { promotion = .project }
                                    .accessibilityIdentifier("idea.notion.reviewPromotion")
                                Button("Remind me after another Notion change") { model.deferNotionIdeaPromotion(idea) }
                                Divider()
                            }
                            Menu("Classification") {
                                Button("Unclassified") { classify(idea, item: item, as: nil) }
                                ForEach(IdeaPromotionKind.allCases) { kind in Button("Potential " + kind.title) { classify(idea, item: item, as: kind) } }
                            }
                            if idea.planning?.potential == .project {
                                Button("Retry Notion sync") { Task { await model.checkProjectGraph(); await model.synchronizePotentialIdeaProjects(only: idea.id) } }.disabled(model.graphBusy)
                                if let error = model.potentialProjectRecord(for: idea)?.error { Text(error) }
                            }
                            Divider()
                        }
                        ForEach(IdeaPromotionKind.allCases) { kind in Button("Move to " + kind.area + "…") { promotion = kind }.disabled(!item.isDirectory) }
                    } label: {
                        let review = model.ideaRecord(for: item.url).map { model.showsNotionIdeaPromotion($0) } ?? false
                        Label(review ? "Notion review…" : "Idea actions", systemImage: review ? "arrow.up.forward.circle" : "ellipsis.circle")
                    }.accessibilityIdentifier("idea.promote").help("Set classification, retry optional Notion sync, or review a complete-folder promotion.")
                }.padding(10)
            }
        }
        .sheet(isPresented: $scoring) { if let item { IdeaPlanningSheet(item: item) } }
        .confirmationDialog("Promote this idea?", isPresented: Binding(get: { promotion != nil }, set: { if !$0 { promotion = nil } }), titleVisibility: .visible) {
            if let item, let kind = promotion {
                Button("Move entire folder to " + kind.area) { _ = model.queueIdeaPromotion(item, kind: kind); promotion = nil }
            }
            Button("Cancel", role: .cancel) { promotion = nil }
        } message: {
            if let item, let kind = promotion { Text("Move the complete folder:\nFrom: \(item.url.canonicalPath)\nTo: \(model.workspace.root.appendingPathComponent(kind.area).appendingPathComponent(item.url.lastPathComponent).canonicalPath)\nExisting destinations are never overwritten. A linked potential project keeps its Notion page; its directory update retries if offline.") }
        }
    }

    private func classify(_ idea: IdeaRecord, item: WorkspaceItem, as kind: IdeaPromotionKind?) {
        let original = idea.planning
        var planning = original ?? IdeaPlanning()
        planning.potential = kind
        if kind == .project && planning.project == nil { planning.project = .init(oneLiner: idea.oneLiner ?? "") }
        Task { _ = await model.saveIdeaPlanning(planning, for: item, original: original) }
    }

    private func folder(_ item: WorkspaceItem) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            detailHeader(item, subtitle: "Folder · \(Format.count(item.immediateChildCount, singular: "item"))")
            TagEditor(assigned: model.tags(for: item), allTags: model.allTags,
                      onAssign: { model.assign(tag: $0, to: item) }, onUnassign: { model.unassign(tag: $0, from: item) },
                      onCreate: { model.createTag(named: $0) })
                .padding(.horizontal, Theme.Space.base).padding(.vertical, Theme.Space.snug)
            Divider()
            if couldNotLoad {
                EmptyAreaState(symbol: "exclamationmark.triangle", title: "Couldn't read this folder", message: "Try again after its storage provider responds.")
            } else if children.isEmpty {
                EmptyAreaState(symbol: "folder", title: "Empty idea folder", message: "Use Add to Ideas to put notes, media, files, or folders here.")
            } else {
                List(children) { child in
                    HStack(spacing: Theme.Space.snug) {
                        Image(systemName: child.kind.symbolName).foregroundStyle(Theme.kindColor(child.kind)).frame(width: 18)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(child.name).lineLimit(1)
                            Text(child.isDirectory ? Format.count(child.immediateChildCount, singular: "item") : Format.bytes(child.byteSize))
                                .font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { model.selectedItem = child }
                    .contextMenu { ItemContextMenu(item: child) }
                }
                .listStyle(.inset)
            }
        }
    }

    private func unsupportedFile(_ item: WorkspaceItem) -> some View {
        VStack(spacing: Theme.Space.base) {
            if item.kind.isVisualMedia { ThumbnailImage(url: item.url, kind: item.kind, size: 280, contentMode: .fit) }
            Image(systemName: item.kind.symbolName).font(.system(size: 36, weight: .light)).foregroundStyle(Theme.kindColor(item.kind))
            Text(item.name).font(.headline).lineLimit(2)
            Text("Use Quick Look or Open to work with this \(item.kind.displayName.lowercased()) file.").foregroundStyle(.secondary)
            HStack { Button("Quick Look") { QuickLookController.shared.preview([item.url]) }; Button("Open") { model.open(item.url) } }
            TagEditor(assigned: model.tags(for: item), allTags: model.allTags,
                      onAssign: { model.assign(tag: $0, to: item) }, onUnassign: { model.unassign(tag: $0, from: item) },
                      onCreate: { model.createTag(named: $0) })
                .frame(maxWidth: 420)
        }
        .padding(Theme.Space.section)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func detailHeader(_ item: WorkspaceItem, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(item.displayTitle).font(.title3.weight(.semibold)).lineLimit(2)
            Text(subtitle).font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, Theme.Space.base).padding(.vertical, Theme.Space.snug)
    }

    @MainActor
    private func loadChildren() async {
        guard let item, item.isDirectory else { children = []; couldNotLoad = false; return }
        guard let read = await model.children(of: item.url), model.selectedItem?.id == item.id else { couldNotLoad = true; return }
        children = read
        couldNotLoad = false
    }
}

private struct IdeaTextEditor: View {
    @Environment(AppModel.self) private var model
    let item: WorkspaceItem
    @State private var text = ""
    @State private var snapshot: TextDocumentService.Snapshot?
    @State private var loaded = false
    @State private var saving = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) { Text(item.name).font(.system(size: 15, weight: .semibold)); Text("Editing the actual file in Ideas").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Button("Open") { model.open(item.url) }
                Button { Task { await save() } } label: {
                    if saving { ProgressView().controlSize(.small) } else { Text("Save") }
                }
                    .buttonStyle(.borderedProminent).disabled(loaded == false || saving)
                    .accessibilityIdentifier("ideas.save")
            }
            .padding(.horizontal, Theme.Space.base).padding(.vertical, Theme.Space.snug)
            Divider()
            if loaded {
                TextEditor(text: $text).font(.system(size: 13, design: .monospaced)).padding(Theme.Space.snug)
            } else {
                ProgressView("Loading note…").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            TagEditor(assigned: model.tags(for: item), allTags: model.allTags,
                      onAssign: { model.assign(tag: $0, to: item) }, onUnassign: { model.unassign(tag: $0, from: item) },
                      onCreate: { model.createTag(named: $0) })
                .padding(.horizontal, Theme.Space.base).padding(.vertical, Theme.Space.snug)
        }
        .task(id: item.id) { await load() }
    }

    @MainActor private func load() async {
        do {
            let service = model.textDocumentService
            let fresh = try await Task.detached(priority: .userInitiated) { try service.read(at: item.url) }.value
            guard model.selectedItem?.id == item.id else { return }
            snapshot = fresh
            text = fresh.text
            loaded = true
        } catch {
            model.lastError = error.localizedDescription
            loaded = false
        }
    }

    @MainActor private func save() async {
        saving = true; defer { saving = false }
        guard let snapshot else { return }
        do { self.snapshot = try await model.saveIdeaText(text, to: item.url, expecting: snapshot) }
        catch { model.lastError = error.localizedDescription }
    }
}

private struct IdeaRow: View {
    let item: WorkspaceItem
    let idea: IdeaRecord?
    let isSelected: Bool
    let tags: [Tag]
    let scoringPreferences: ProjectScoringPreferences
    /// The linked Notion project's new status, when it offers a reviewed promotion.
    var notionPromotion: String? = nil

    /// True when the folder holds something beyond another app's metadata.
    private var hasContent: Bool { (item.immediateChildCount ?? 0) > 0 }

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Space.snug) {
            Circle()
                .fill(hasContent ? Color.accentColor.opacity(0.75) : Color.secondary.opacity(0.28))
                .frame(width: 7, height: 7)
                .padding(.top, 7)

            VStack(alignment: .leading, spacing: 5) {
                if let notionPromotion {
                    Label("Notion status is \(notionPromotion) · review promotion", systemImage: "arrow.up.forward.circle")
                        .font(.caption).foregroundStyle(.tint).accessibilityIdentifier("idea.row.notionPromotion")
                }
                if idea?.planning?.needsSetup == true { Label("Set priority & score", systemImage: "sparkles").font(.caption).foregroundStyle(.orange) }
                if let planning = idea?.planning {
                    Text("Priority \(planning.priority)/5" + (planning.potential.map { " · Potential " + $0.title } ?? "") + (planning.score(preferences: scoringPreferences).projectScore.map { " · \(Int($0.rounded()))/100" } ?? "")).font(.caption).foregroundStyle(.secondary)
                }
                Text(item.displayTitle)
                    .font(.system(size: 15, weight: .medium))
                    .lineLimit(2)
                    .foregroundStyle(.primary)

                if let oneLiner = idea?.planning?.project?.oneLiner ?? idea?.oneLiner, !oneLiner.isEmpty {
                    Text(MarkdownInline.attributed(oneLiner))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                HStack(spacing: Theme.Space.snug) {
                    Text(Format.relativeDate(item.contentModifiedAt))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    if hasContent {
                        Label(Format.count(item.immediateChildCount, singular: "file"),
                              systemImage: "paperclip")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    if item.isDirectory == false {
                        Text(item.fileExtension.uppercased())
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    if let idea { IdeaFacts(idea: idea) }
                    if tags.isEmpty == false { TagChipRow(tags: tags) }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.Space.base)
        .padding(.vertical, Theme.Space.snug)
        .background(isSelected ? Color.accentColor.opacity(0.13) : .clear)
    }
}

/// Status, type and impact as quiet labels — words, not colours, because the values are
/// free text ("exploring", "concept", "Medium") and inventing a palette for them would
/// claim a meaning they do not have.
private struct IdeaFacts: View {
    let idea: IdeaRecord

    var body: some View {
        let facts = [idea.status, idea.type, idea.impact.map { "\($0) impact" }].compactMap { $0 }
        if facts.isEmpty == false {
            Text(facts.joined(separator: " · "))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .accessibilityLabel("Status and type: \(facts.joined(separator: ", "))")
        }
        if idea.keepSuggesting == false {
            Image(systemName: "bell.slash")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .help("Not resurfaced while you work")
        }
    }
}
