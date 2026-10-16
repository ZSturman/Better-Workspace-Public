import SwiftUI
import AppKit
import UniformTypeIdentifiers
import BetterWorkspaceCore

@MainActor
@Observable
final class CaptureComposerDraft {
    var title = ""
    var markdown = ""
    var link = ""
    var attachments: [CaptureDraftEntry] = []
    var tags: [Tag] = []
    /// Where the work goes when it is filed into a work queue. All optional.
    var links = WorkItemLinks.none
    var saving = false
    var message: String?
    var failed = false
    var focusRequest = 0
    /// Opened as New Idea: Save files the capture as an idea folder in Ideas.
    var ideaRequested = false
    private var noteID = UUID()
    private var staged: [UUID: IngestItem] = [:]
    var hasStagedNote: Bool { staged[noteID] != nil }
    func isStaged(_ id: UUID) -> Bool { staged[id] != nil }

    var isEmpty: Bool { markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && link.isEmpty && attachments.isEmpty }

    func addFiles(_ urls: [URL]) {
        attachments += urls.map { .init(title: $0.deletingPathExtension().lastPathComponent, content: .file($0)) }
    }

    func paste() {
        let clipboard = NSPasteboard.general
        if let urls = clipboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            addFiles(urls)
        } else if let data = clipboard.data(forType: .png) {
            attachments.append(.init(title: CaptureNaming.timestampName(), content: .data(data, extension: "png")))
        } else if let data = clipboard.data(forType: .tiff) {
            attachments.append(.init(title: CaptureNaming.timestampName(), content: .data(data, extension: "tiff")))
        } else if let text = clipboard.string(forType: .string) {
            if (try? WorkspaceLink(title: "", url: text)) != nil { link = text.trimmingCharacters(in: .whitespacesAndNewlines) }
            else { markdown += (markdown.isEmpty ? "" : "\n") + text }
        }
    }

    func save(using model: AppModel, destination: WorkspaceFolder?, asIdea: Bool = false) async {
        guard !saving, !isEmpty else { return }
        saving = true
        defer { saving = false }
        var entries = attachments
        if let note = CaptureDraftEntry.note(id: noteID, title: title, markdown: markdown, url: link) { entries.insert(note, at: 0) }
        let service = model.ingest
        var count = 0
        var errors: [String] = []
        for entry in entries {
            do {
                let previouslyCaptured = staged[entry.id]
                let item = try await Task.detached(priority: .userInitiated) {
                    if let previouslyCaptured { return previouslyCaptured }
                    return try service.capture(entry)
                }.value
                staged[entry.id] = item
                if let destination, model.isWorkQueue(destination), asIdea == false {
                    // A queue lists work items, never loose notes: this becomes one.
                    _ = try await model.promoteCapture(item, toQueue: destination, links: links,
                                                       tagIDs: Set(tags.map(\.id)))
                    staged.removeValue(forKey: entry.id)
                    if entry.id == noteID { title = ""; markdown = ""; link = ""; noteID = UUID() }
                    else { attachments.removeAll { $0.id == entry.id } }
                    count += 1
                    continue
                }
                for tag in tags { model.tagStore.assign(tagID: tag.id, to: item.url, area: nil) }
                if asIdea {
                    try model.fileAsIdea(item, tagIDs: Set(tags.map(\.id)))
                } else if let destination {
                    let filed = try await Task.detached(priority: .userInitiated) {
                        let unique = CaptureNaming.uniqueURL(in: destination.url,
                            base: item.url.deletingPathExtension().lastPathComponent, extension: item.url.pathExtension)
                        return try service.file(item, intoDirectory: destination.url,
                            renamingTo: unique.deletingPathExtension().lastPathComponent)
                    }.value
                    if filed.originalKept { errors.append("Filed \(entry.title), but its Inbox copy could not be removed.") }
                }
                staged.removeValue(forKey: entry.id)
                if entry.id == noteID { title = ""; markdown = ""; link = ""; noteID = UUID() }
                else { attachments.removeAll { $0.id == entry.id } }
                count += 1
            } catch { errors.append(error.localizedDescription) }
        }
        failed = !errors.isEmpty
        if isEmpty { tags = []; links = .none }
        let place = asIdea ? WorkspaceArea.ideas.directoryName : destination?.name
        message = ([count > 0 ? RecentCaptureHistory.savedMessage(count: count, destinationName: place) + "." : ""] + errors)
            .filter { !$0.isEmpty }.joined(separator: " ")
        if count > 0 { ideaRequested = false }
        model.statusMessage = message
        await model.refreshIngest()
        if count > 0, let destination {
            model.noteFiled(into: destination.name)
            await model.refresh(areaNamed: destination.name)
        }
        if count > 0, asIdea { await model.refresh(area: .ideas) }
    }
}

/// The same draft/editor is hosted by the status menu, main Inbox and hotkey panel.
struct CaptureComposer: View {
    @Environment(AppModel.self) private var model
    private var draft: CaptureComposerDraft { model.captureDraft }
    var compact = false
    var showFolderButtons = true
    var shortcutFocus = false
    @State private var detailsExpanded = false
    @State private var destinationID: String?
    @FocusState private var markdownFocused: Bool

    private var destinations: [WorkspaceFolder] { DestinationOrder.destinations(model.folders) }

    var body: some View {
        @Bindable var draft = model.captureDraft
        VStack(alignment: .leading, spacing: 8) {
            if !compact { detailFields }
            TextEditor(text: $draft.markdown)
                .focused($markdownFocused)
                .disabled(draft.hasStagedNote)
                .font(.system(size: 12, design: .monospaced))
                .frame(height: compact ? 72 : 100)
                .accessibilityIdentifier("ingest.captureField")
                .overlay(alignment: .topLeading) {
                    if draft.markdown.isEmpty { Text(compact ? "Write or paste anything…" : "Write Markdown or link notes…").font(.caption).foregroundStyle(.secondary).padding(5).allowsHitTesting(false) }
                }
            if !draft.attachments.isEmpty {
                ScrollView {
                    ForEach($draft.attachments) { $entry in
                        HStack {
                            thumbnail(entry).frame(width: 32, height: 32)
                            TextField("Image or file title", text: $entry.title)
                                .disabled(draft.isStaged(entry.id))
                            Button { draft.attachments.removeAll { $0.id == entry.id } } label: { Image(systemName: "xmark") }
                        }
                    }
                }.frame(height: min(130, CGFloat(draft.attachments.count) * 40))
            }
            if compact {
                compactActions
            } else {
                HStack {
                    Button("Files…", action: chooseFiles)
                    Button("Paste", action: draft.paste)
                    tagsMenu
                    Spacer()
                    if draft.ideaRequested {
                        Button("Save Idea") { Task { @MainActor in await draft.save(using: model, destination: nil, asIdea: true) } }
                            .buttonStyle(.borderedProminent)
                            .keyboardShortcut(.return, modifiers: .command)
                            .accessibilityIdentifier("capture.saveIdea")
                            .disabled(draft.isEmpty)
                    }
                    Button("Inbox") { save(nil) }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.return, modifiers: draft.ideaRequested ? [.command, .shift] : .command)
                        .accessibilityIdentifier("ingest.captureButton")
                        .accessibilityLabel("Save to Inbox")
                        .help("Save to the Inbox (⌘Return)")
                        .disabled(draft.isEmpty)
                }
                if !draft.tags.isEmpty { TagChipRow(tags: draft.tags, limit: 5) }
                folderRow
                // Folder buttons save at once, so where work belongs is chosen first.
                // It applies only when the folder is a work queue.
                HStack(spacing: 6) {
                    Text("If filed as work").font(.caption).foregroundStyle(.secondary)
                    model.linkPickers(kind: .task, links: draft.links) { model.captureDraft.links = $0 }
                    Spacer(minLength: 0)
                }
                .controlSize(.small)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("capture.links")
            }
            if let message = draft.message {
                Text(message).font(.caption).foregroundStyle(draft.failed ? Color.orange : Color.secondary)
                    .accessibilityIdentifier("capture.result")
            }
        }
        .textFieldStyle(.roundedBorder)
        .disabled(draft.saving)
        .onAppear {
            markdownFocused = true
            detailsExpanded = !draft.title.isEmpty || !draft.link.isEmpty || !draft.tags.isEmpty
        }
        .onChange(of: draft.focusRequest) { _, _ in
            if shortcutFocus { markdownFocused = true }
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in draft.addFiles([url]) }
                }
            }
            return true
        }
    }

    private var detailFields: some View {
        @Bindable var draft = model.captureDraft
        return VStack(spacing: 8) {
            TextField("Title (optional)", text: $draft.title)
                .disabled(draft.hasStagedNote)
                .accessibilityIdentifier("capture.title")
            TextField("URL (optional)", text: $draft.link)
                .disabled(draft.hasStagedNote)
                .accessibilityIdentifier("capture.url")
        }
    }

    /// Or straight into a folder: the few used most recently, the rest under More.
    private var folderRow: some View {
        let split = model.splitDestinations(limit: showFolderButtons ? 5 : 0)
        return HStack(spacing: 6) {
            Text("or file in").font(.caption).foregroundStyle(.secondary)
            ForEach(split.leading) { folder in
                Button(folder.name) { save(folder) }
                    .accessibilityIdentifier("capture.file.\(folder.name)")
                    .accessibilityLabel("Save to \(folder.name)")
                    .disabled(draft.isEmpty)
            }
            if split.rest.isEmpty == false {
                Menu(split.leading.isEmpty ? "Folder" : "More") {
                    ForEach(split.rest) { folder in
                        Button(folder.name) { save(folder) }
                    }
                }
                .fixedSize()
                .disabled(draft.isEmpty)
                .accessibilityIdentifier("capture.moreDestinations")
            }
            Spacer(minLength: 0)
        }
        .controlSize(.small)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("capture.destinations")
    }

    private var tagsMenu: some View {
        Menu("Tags") {
            ForEach(model.allTags) { tag in
                Button {
                    if draft.tags.contains(tag) { draft.tags.removeAll { $0.id == tag.id } }
                    else { draft.tags.append(tag) }
                } label: {
                    Label(tag.name, systemImage: draft.tags.contains(tag) ? "checkmark" : "tag")
                }
            }
            if model.allTags.isEmpty { Text("No tags yet") }
        }.fixedSize()
    }

    private var selectedDestination: WorkspaceFolder? {
        destinations.first { $0.id == destinationID }
    }

    private var compactActions: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {
                Button(action: chooseFiles) { Label("Files", systemImage: "paperclip") }
                Button(action: draft.paste) { Label("Paste", systemImage: "doc.on.clipboard") }
                Spacer()
                Button {
                    detailsExpanded.toggle()
                } label: {
                    Label("Details", systemImage: detailsExpanded ? "chevron.up" : "chevron.down")
                }
                .accessibilityIdentifier("capture.details")
            }
            .buttonStyle(.borderless)
            .font(.system(size: 11))
            if detailsExpanded {
                detailFields
            } else if !draft.title.isEmpty || !draft.link.isEmpty {
                // A URL pasted by the shared clipboard handler must stay visible,
                // even when the optional fields are collapsed.
                Text([draft.title, draft.link].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            // Always one line away: typing narrows to existing tags (TagMatching, as
            // everywhere else) and Return picks the best one.
            TagEditor(
                assigned: draft.tags,
                allTags: model.allTags,
                onAssign: { tag in if draft.tags.contains(tag) == false { draft.tags.append(tag) } },
                onUnassign: { tag in draft.tags.removeAll { $0.id == tag.id } },
                onCreate: { model.createTag(named: $0) },
                compact: true
            )
            HStack {
                Menu {
                    let split = model.splitDestinations(limit: 5)
                    Button("Inbox") { destinationID = nil }
                    Section("Recent") {
                        ForEach(split.leading) { folder in Button(folder.name) { destinationID = folder.id } }
                    }
                    if split.rest.isEmpty == false {
                        Menu("More") {
                            ForEach(split.rest) { folder in Button(folder.name) { destinationID = folder.id } }
                        }
                    }
                } label: {
                    Text(selectedDestination?.name ?? "Inbox").lineLimit(1)
                }
                .accessibilityIdentifier("capture.destination")
                .accessibilityLabel("Save destination")
                .onChange(of: destinationID) { _, _ in model.captureDraft.links = .none }
                .help("Choose where this capture will be saved")
                .frame(maxWidth: 170, alignment: .leading)
                Spacer(minLength: 8)
                Button(selectedDestination.map { model.isWorkQueue($0) } == true
                       ? "Add \(selectedDestination!.settings.workItemKind.displayName)" : "Add") { save(selectedDestination) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: .command)
                    .accessibilityIdentifier("ingest.captureButton")
                    .accessibilityLabel("Add to \(selectedDestination?.name ?? "Inbox")")
                    .disabled(draft.isEmpty)
            }
            // Filing into a queue makes a work item; where it belongs is optional.
            if let queue = selectedDestination, model.isWorkQueue(queue) {
                model.linkPickers(kind: queue.settings.workItemKind, links: draft.links) { model.captureDraft.links = $0 }
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("capture.links")
            }
        }
    }

    private func save(_ destination: WorkspaceFolder?) {
        Task { @MainActor in await draft.save(using: model, destination: destination) }
    }

    private func chooseFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.prompt = "Add to draft"
        if panel.runModal() == .OK { draft.addFiles(panel.urls) }
    }

    private func thumbnail(_ entry: CaptureDraftEntry) -> some View {
        CaptureAttachmentThumbnail(entry: entry)
    }
}

private struct CaptureAttachmentThumbnail: View {
    let entry: CaptureDraftEntry
    @State private var image: NSImage?
    var body: some View {
        Group {
            if let image { Image(nsImage: image).resizable().scaledToFit() }
            else { Image(systemName: "doc") }
        }.task(id: entry.id) { @MainActor in
            image = await Task.detached(priority: .utility) {
                switch entry.content {
                case .file(let url): return NSImage(contentsOf: url)
                case .data(let data, _): return NSImage(data: data)
                default: return nil
                }
            }.value
        }
    }
}
