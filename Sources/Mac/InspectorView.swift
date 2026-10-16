import SwiftUI
import BetterWorkspaceCore

/// The shared inspector, with a context that follows the active destination.
///
/// Tags stay consistent across the app, but the useful controls do not: a work record
/// exposes its portable Markdown, an idea exposes its service-owned metadata, and a
/// text file exposes an explicit, conflict-aware editor.
struct InspectorView: View {
    @Environment(AppModel.self) private var model
    @State private var detail: ItemDetail?
    @State private var detailItemID: WorkspaceItem.ID?
    @State private var measuring = false

    var body: some View {
        Group {
            if let item = model.selectedItem {
                content(for: item)
            } else {
                VStack(spacing: Theme.Space.snug) {
                    Image(systemName: "sidebar.right")
                        .font(.system(size: 22, weight: .light))
                        .foregroundStyle(.tertiary)
                    Text("Nothing selected")
                        .font(.callout).foregroundStyle(.secondary)
                    Text(emptyPrompt)
                        .font(.caption).foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                }
                .padding(Theme.Space.loose)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        // The item *and* its area's change revision: the same selection with new
        // contents (a file added to a selected folder) must re-probe, not keep the
        // count from when it was clicked.
        .task(id: detailKey) { await loadDetail() }
    }

    private var detailKey: String {
        guard let item = model.selectedItem else { return "" }
        let area = model.workspace.areaName(containing: item.url) ?? ""
        return "\(item.id)#\(model.revision(ofArea: area))"
    }

    private func content(for item: WorkspaceItem) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.base) {
                header(item)

                context(item)

                if model.projectAudit(for: item) != nil {
                    ProjectAuditInspectorSummary(project: item)
                }

                if TextDocumentService.supportsEditing(item.url) {
                    Divider()
                    TextDocumentInspector(item: item)
                }

                TagEditor(
                    assigned: model.tags(for: item),
                    allTags: model.allTags,
                    onAssign: { model.assign(tag: $0, to: item) },
                    onUnassign: { model.unassign(tag: $0, from: item) },
                    onCreate: { model.createTag(named: $0) }
                )

                if let description = model.projectDescription(for: item) {
                    Divider()
                    ProjectDescriptionEditor(description: description) { model.setProjectDescription($0, for: item) }
                        .id("\(item.id)#\(description.oneLiner ?? "")#\(description.summary ?? "")")
                }

                if let idea = model.ideaRecord(for: item.url) {
                    Divider()
                    IdeaMetadataEditor(
                        idea: idea,
                        statuses: IdeaChanges.choices(suggested: IdeaChanges.suggestedStatuses, inUse: model.ideaValues(\.status)),
                        types: IdeaChanges.choices(suggested: IdeaChanges.suggestedTypes, inUse: model.ideaValues(\.type)),
                        impacts: IdeaChanges.choices(suggested: IdeaChanges.suggestedImpacts, inUse: model.ideaValues(\.impact)),
                        onSave: { changes in await model.updateIdea(idea, changes) }
                    )
                    .id(idea)
                }

                Divider()
                facts(item)
                Divider()
                actions(item)
            }
            .padding(Theme.Space.base)
        }
    }

    private var emptyPrompt: String {
        switch model.selection {
        case .overview: return "Select a project or next action to see its context."
        case .work: return "Select a work item to edit it here."
        case .folder(let name): return "Select an item in \(name) to inspect it here."
        case .tag: return "Select a tagged item to inspect it here."
        case .ingest, .none: return "Select an item in any area to tag and inspect it."
        }
    }

    @ViewBuilder
    private func context(_ item: WorkspaceItem) -> some View {
        if let workItem = model.workItems.first(where: { $0.url.canonicalPath == item.url.canonicalPath }) {
            HStack {
                Label("\(workItem.kind.displayName) · \(workItem.status.displayName) · \(workItem.stage.displayName)",
                      systemImage: workItem.kind.symbolName)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(workItem.status == .completed ? .green : .secondary)
                Spacer()
                Button("Edit") { model.edit(workItem: workItem) }
                    .controlSize(.small)
                    .accessibilityIdentifier("inspector.editWork")
            }
        } else if item.kind == .markdown || TextDocumentService.supportsEditing(item.url) {
            Label("Text file · edit directly below", systemImage: "pencil.line")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    private func header(_ item: WorkspaceItem) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.snug) {
            if item.kind.isVisualMedia {
                ThumbnailImage(url: item.url, kind: item.kind, size: 220)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
            HStack(spacing: Theme.Space.tight) {
                Image(systemName: showsProjectKind ? (detail?.projectKind.symbolName ?? item.kind.symbolName)
                                                   : item.kind.symbolName)
                    .foregroundStyle(Theme.kindColor(item.kind))
                Text(item.displayTitle)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(3)
                    .textSelection(.enabled)
            }
            if let name = model.workspace.areaName(containing: item.url),
               let folder = model.folder(named: name) {
                Label(folder.name, systemImage: folder.settings.symbol)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func facts(_ item: WorkspaceItem) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.tight) {
            Text("Details")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary).textCase(.uppercase)

            fact("Kind", kindLabel(for: item))
            if item.isDirectory {
                fact("Contains", Format.count(item.immediateChildCount, singular: "item"))
            } else {
                fact("Size", Format.bytes(item.byteSize))
            }
            fact("Changed", Format.shortDate(item.contentModifiedAt))
            if let created = item.createdAt { fact("Added", Format.shortDate(created)) }
            if detail?.isGitRepository == true {
                fact("Git", detail?.gitBranch ?? "repository")
            }
            if let count = detail?.recursiveFileCount, let bytes = detail?.recursiveByteSize {
                fact("Total", "\(count) files · \(Format.bytes(bytes))")
            } else if item.isDirectory {
                HStack {
                    Text("Total").font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 66, alignment: .leading)
                    if measuring {
                        ProgressView().controlSize(.mini)
                    } else {
                        Button("Measure") { Task { await measure(item) } }
                            .buttonStyle(.link).font(.system(size: 11))
                    }
                }
            }

            // The file identity is what keeps tags attached through a move; it is there
            // for anyone who needs it, without being a row everyone reads.
            fact("Path", item.url.path)
                .help(item.identity.map { "File ID \($0.key)" } ?? "")
        }
    }

    /// "Xcode", "Python", "Notes" only mean something for a working directory. Calling
    /// an empty Ideas folder "Empty" or a Reference folder "Media" is just noise.
    private var showsProjectKind: Bool {
        guard let item = model.selectedItem,
              let area = model.workspace.area(containing: item.url) else { return false }
        return area == .projects || area == .review
    }

    private func kindLabel(for item: WorkspaceItem) -> String {
        guard item.isDirectory else { return item.kind.displayName }
        if showsProjectKind, let kind = detail?.projectKind { return kind.rawValue }
        return "Folder"
    }

    private func fact(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.tight) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 66, alignment: .leading)
            Text(value)
                .font(.system(size: 11))
                .textSelection(.enabled)
                .lineLimit(4)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func actions(_ item: WorkspaceItem) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.tight) {
            Button { QuickLookController.shared.preview([item.url]) } label: {
                Label("Quick Look", systemImage: "eye").frame(maxWidth: .infinity, alignment: .leading)
            }
            Button { model.open(item.url) } label: {
                Label("Open", systemImage: "arrow.up.forward.app").frame(maxWidth: .infinity, alignment: .leading)
            }
            Button { model.revealInFinder(item.url) } label: {
                Label("Reveal in Finder", systemImage: "folder").frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    @MainActor
    private func loadDetail() async {
        guard let item = model.selectedItem else { detail = nil; detailItemID = nil; return }
        // Blank only for a different item. The same item re-probed after a change swaps
        // its new detail in place — clearing first made the inspector flash every time
        // another tool appended to a selected log.
        if detailItemID != item.id { detail = nil }
        let fresh = await model.probe.detail(for: item)
        guard model.selectedItem?.id == item.id else { return }
        detail = fresh
        detailItemID = item.id
    }

    @MainActor
    private func measure(_ item: WorkspaceItem) async {
        measuring = true
        defer { measuring = false }
        detail = await model.probe.deepDetail(for: item, fs: model.fs)
    }
}

/// A deliberately small editor for plain text only. It is opt-in (the person presses
/// Edit), capped, and compares exact source bytes before saving. This makes it safe to
/// edit a note in-place without turning the Workspace browser into a general IDE.
private struct TextDocumentInspector: View {
    @Environment(AppModel.self) private var model
    let item: WorkspaceItem
    @State private var snapshot: TextDocumentService.Snapshot?
    @State private var text = ""
    @State private var editing = false
    @State private var saving = false
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.tight) {
            HStack {
                Label("Text", systemImage: "doc.text")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if editing == false, snapshot != nil {
                    Button("Edit") { editing = true }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .accessibilityIdentifier("inspector.editText")
                }
            }

            if let message {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
            }

            if snapshot == nil, message == nil {
                HStack(spacing: Theme.Space.tight) {
                    ProgressView().controlSize(.small)
                    Text("Loading text…").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            } else if editing {
                TextEditor(text: $text)
                    .font(.system(size: 11, design: .monospaced))
                    .frame(minHeight: 220, maxHeight: 420)
                    .overlay(RoundedRectangle(cornerRadius: Theme.Radius.chip)
                        .strokeBorder(.secondary.opacity(0.28)))
                HStack {
                    Button("Cancel") {
                        text = snapshot?.text ?? ""
                        editing = false
                    }
                    Spacer()
                    Button("Reload") { Task { await load() } }
                        .disabled(saving)
                    Button("Save") { Task { await save() } }
                        .buttonStyle(.borderedProminent)
                        .disabled(saving || text == snapshot?.text)
                        .accessibilityIdentifier("inspector.saveText")
                }
                .controlSize(.small)
            } else if let snapshot, isMarkdown, snapshot.text.isEmpty == false {
                // Rendered, not raw: headings, lists, checklists, links. Edit shows the source.
                ScrollView {
                    MarkdownView(text: snapshot.text, baseSize: 12)
                        .padding(Theme.Space.tight)
                }
                .frame(maxHeight: 340)
                .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: Theme.Radius.chip))
                .accessibilityIdentifier("inspector.markdownPreview")
            } else if let snapshot {
                Text(snapshot.text.isEmpty ? "Empty text file" : snapshot.text)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(snapshot.text.isEmpty ? .tertiary : .secondary)
                    .lineLimit(10)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Theme.Space.tight)
                    .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: Theme.Radius.chip))
            }
        }
        .task(id: item.url.canonicalPath) { await load() }
    }

    private var isMarkdown: Bool {
        ["md", "markdown", "mdown"].contains(item.url.pathExtension.lowercased())
    }

    @MainActor
    private func load() async {
        editing = false
        message = nil
        do {
            let service = model.textDocumentService
            let fresh = try await Task.detached(priority: .userInitiated) {
                try service.read(at: item.url)
            }.value
            guard model.selectedItem?.url.canonicalPath == item.url.canonicalPath else { return }
            snapshot = fresh
            text = fresh.text
        } catch {
            guard model.selectedItem?.url.canonicalPath == item.url.canonicalPath else { return }
            snapshot = nil
            message = error.localizedDescription
        }
    }

    @MainActor
    private func save() async {
        guard let snapshot else { return }
        saving = true
        defer { saving = false }
        do {
            let service = model.textDocumentService
            let replacement = text
            let fresh = try await Task.detached(priority: .userInitiated) {
                try service.save(replacement, at: item.url, expecting: snapshot)
            }.value
            guard model.selectedItem?.url.canonicalPath == item.url.canonicalPath else { return }
            self.snapshot = fresh
            editing = false
            model.statusMessage = "Saved \(item.name)"
        } catch {
            message = error.localizedDescription
        }
    }
}

/// An idea's metadata — status, type, impact, one-liner, and whether it may be
/// resurfaced — edited here and saved by the background service, which owns it.
///
/// Values are free text in practice ("article", "concept", "to_write"), so each field
/// offers the service's suggestions and every value already in use, and takes anything
/// typed. Saving sends only what changed.
private struct IdeaMetadataEditor: View {
    let idea: IdeaRecord
    let statuses: [String]
    let types: [String]
    let impacts: [String]
    let onSave: (IdeaChanges) async -> Bool

    @State private var status = ""
    @State private var type = ""
    @State private var impact = ""
    @State private var oneLiner = ""
    @State private var keepSuggesting = true
    @State private var saving = false

    private var changes: IdeaChanges {
        .between(idea, status: status, type: type, impact: impact, oneLiner: oneLiner, keepSuggesting: keepSuggesting)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.tight) {
            Text("Idea")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            TextField("One-liner", text: $oneLiner, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))
                .lineLimit(1...3)
            field("Status", text: $status, choices: statuses)
            field("Type", text: $type, choices: types)
            field("Impact", text: $impact, choices: impacts)
            Toggle("Resurface while I work", isOn: $keepSuggesting)
                .font(.system(size: 12))
                .help("When off, the background service never brings this idea back on its own.")
            HStack {
                Spacer()
                if saving { ProgressView().controlSize(.small) }
                Button("Save") {
                    Task { @MainActor in
                        saving = true
                        _ = await onSave(changes)
                        saving = false
                    }
                }
                .disabled(changes.isEmpty || saving)
                .keyboardShortcut(.defaultAction)
            }
        }
        .onAppear(perform: load)
    }

    private func load() {
        status = idea.status ?? ""
        type = idea.type ?? ""
        impact = idea.impact ?? ""
        oneLiner = idea.oneLiner ?? ""
        keepSuggesting = idea.keepSuggesting
    }

    private func field(_ label: String, text: Binding<String>, choices: [String]) -> some View {
        LabeledContent(label) {
            HStack(spacing: 4) {
                TextField(label, text: text)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                Menu {
                    ForEach(choices, id: \.self) { choice in Button(choice) { text.wrappedValue = choice } }
                    if text.wrappedValue.isEmpty == false {
                        Divider()
                        Button("Clear") { text.wrappedValue = "" }
                    }
                } label: { Image(systemName: "chevron.up.chevron.down") }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .accessibilityLabel("\(label) choices")
            }
        }
        .font(.system(size: 12))
    }
}

/// A project's one-liner and summary.
private struct ProjectDescriptionEditor: View {
    let description: ProjectDescription
    let onSave: (ProjectDescription) -> Void

    @State private var oneLiner = ""
    @State private var summary = ""

    private var edited: ProjectDescription { ProjectDescription(oneLiner: oneLiner, summary: summary) }
    private var changed: Bool {
        oneLiner.trimmingCharacters(in: .whitespacesAndNewlines) != (description.oneLiner ?? "")
            || summary.trimmingCharacters(in: .whitespacesAndNewlines) != (description.summary ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.tight) {
            Text("Description")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            TextField("One-liner", text: $oneLiner, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))
                .lineLimit(1...3)
            TextField("Summary", text: $summary, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))
                .lineLimit(2...8)
            HStack {
                Spacer()
                Button("Save Description") { onSave(edited) }
                    .disabled(changed == false)
            }
        }
        .onAppear {
            oneLiner = description.oneLiner ?? ""
            summary = description.summary ?? ""
        }
    }
}
