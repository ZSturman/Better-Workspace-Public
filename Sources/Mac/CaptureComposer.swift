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
    // The menu bar window can disappear while a picker is open. Keep the entire
    // draft, including its destination, on the app model rather than the view.
    var destinationID: String?
    var detailsExpanded = false
    @ObservationIgnored private var filePanel: NSOpenPanel?
    private var noteID = UUID()
    private var staged: [UUID: IngestItem] = [:]
    private var stagedIdea: IngestItem?
    var hasStagedIdea: Bool { stagedIdea != nil }
    var hasStagedNote: Bool { staged[noteID] != nil || hasStagedIdea }
    func isStaged(_ id: UUID) -> Bool { staged[id] != nil }

    var isEmpty: Bool { markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && link.isEmpty && attachments.isEmpty }

    func addFiles(_ urls: [URL]) {
        attachments += urls.map { .init(title: $0.deletingPathExtension().lastPathComponent, content: .file($0)) }
    }

    func removeAttachment(_ id: UUID) {
        guard !saving, !hasStagedIdea else { return }
        attachments.removeAll { $0.id == id }
        failed = false
        message = "Attachment removed. Your draft hasn’t been saved yet."
    }

    func chooseFiles() {
        guard !saving, !hasStagedIdea else { return }
        if let filePanel { filePanel.makeKeyAndOrderFront(nil); return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Add to draft"
        filePanel = panel
        NSApp.activate(ignoringOtherApps: true)
        // A nested runModal from MenuBarExtra leaves the picker unable to take
        // normal navigation events. Let AppKit run it asynchronously instead.
        panel.begin { [weak self] response in
            guard let self else { return }
            if response == .OK, !self.saving, !self.hasStagedIdea { self.addFiles(panel.urls) }
            self.filePanel = nil
        }
    }

    func pasteAttachments(from clipboard: NSPasteboard) -> Bool {
        guard !saving, !hasStagedIdea else { return false }
        if let urls = clipboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            addFiles(urls)
            return true
        }
        let png = clipboard.data(forType: .png) ?? NSImage(pasteboard: clipboard)?.tiffRepresentation
            .flatMap { NSBitmapImageRep(data: $0)?.representation(using: .png, properties: [:]) }
        guard let png else { return false }
        attachments.append(.init(title: CaptureNaming.timestampName(), content: .data(png, extension: "png")))
        return true
    }

    func paste() {
        guard !saving, !hasStagedIdea else { return }
        let clipboard = NSPasteboard.general
        if !pasteAttachments(from: clipboard), !hasStagedNote, let text = clipboard.string(forType: .string) {
            if (try? WorkspaceLink(title: "", url: text)) != nil { link = text.trimmingCharacters(in: .whitespacesAndNewlines) }
            else { markdown += (markdown.isEmpty ? "" : "\n") + text }
        }
    }

    func save(using model: AppModel, destination: WorkspaceFolder?, asIdea: Bool = false) async {
        guard !saving, !isEmpty else { return }
        saving = true
        defer { saving = false }
        let toIdeas = asIdea || destination?.name == WorkspaceArea.ideas.directoryName
        if toIdeas || (destination == nil && hasStagedIdea) {
            await saveIdea(using: model, toIdeas: toIdeas)
            return
        }
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
                if let destination, model.isWorkQueue(destination) {
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
                if let destination {
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
        message = ([count > 0 ? RecentCaptureHistory.savedMessage(count: count, destinationName: destination?.name) + "." : ""] + errors)
            .filter { !$0.isEmpty }.joined(separator: " ")
        if count > 0 { ideaRequested = false }
        model.statusMessage = message
        await model.refreshIngest()
        if count > 0, let destination {
            model.noteFiled(into: destination.name)
            await model.refresh(areaNamed: destination.name)
        }
    }

    private func saveIdea(using model: AppModel, toIdeas: Bool) async {
        do {
            guard staged.isEmpty else {
                throw IngestService.IngestError.moveFailed("Finish saving the staged captures to the Inbox first.")
            }
            let item: IngestItem
            if let stagedIdea { item = stagedIdea }
            else {
                let service = model.ingest
                let title = title, attachments = attachments
                let note = CaptureDraftEntry.note(id: noteID, title: title, markdown: markdown, url: link)
                item = try await Task.detached(priority: .userInitiated) {
                    try service.captureIdea(title: title, note: note, attachments: attachments)
                }.value
                stagedIdea = item
            }
            let tagIDs = Set(tags.map(\.id))
            let filed: IngestService.Filed?
            if toIdeas { filed = try await model.fileAsIdea(item, tagIDs: tagIDs) }
            else {
                for id in tagIDs { model.tagStore.assign(tagID: id, to: item.url, area: nil) }
                filed = nil
            }
            stagedIdea = nil
            title = ""; markdown = ""; link = ""; noteID = UUID()
            attachments = []; tags = []; links = .none; ideaRequested = false
            failed = filed?.originalKept == true
            message = failed ? "Saved to Ideas. The original copy is still in the Inbox."
                : RecentCaptureHistory.savedMessage(count: 1, destinationName: toIdeas ? WorkspaceArea.ideas.directoryName : nil) + "."
            if toIdeas {
                CaptureSaveNotifications.ideaSaved(title: item.title, originalKept: filed?.originalKept == true)
                model.noteFiled(into: WorkspaceArea.ideas.directoryName)
                await model.refresh(area: .ideas)
            }
        } catch {
            failed = true
            message = "Idea wasn’t saved. Your draft is still here. " + error.localizedDescription
        }
        model.statusMessage = message
        await model.refreshIngest()
    }
}

/// The same draft/editor is hosted by the status menu, main Inbox and hotkey panel.
struct CaptureComposer: View {
    @Environment(AppModel.self) private var model
    private var draft: CaptureComposerDraft { model.captureDraft }
    var compact = false
    var showFolderButtons = true
    var shortcutFocus = false

    private var destinations: [WorkspaceFolder] { DestinationOrder.destinations(model.folders) }

    var body: some View {
        @Bindable var draft = model.captureDraft
        VStack(alignment: .leading, spacing: 8) {
            if !compact { detailFields }
            CaptureTextEditor(text: $draft.markdown, editable: !draft.saving && !draft.hasStagedNote,
                              focusRequest: shortcutFocus ? draft.focusRequest : 0, pasteAttachments: draft.pasteAttachments)
                .frame(height: compact ? 72 : 100)
                .overlay(alignment: .topLeading) {
                    if draft.markdown.isEmpty { Text(compact ? "Write or paste anything…" : "Write Markdown or link notes…").font(.caption).foregroundStyle(.secondary).padding(5).allowsHitTesting(false) }
                }
            if !draft.attachments.isEmpty {
                ScrollView {
                    ForEach(draft.attachments) { entry in
                        HStack {
                            thumbnail(entry).frame(width: 32, height: 32)
                            TextField("Image or file title", text: Binding(
                                get: { draft.attachments.first { $0.id == entry.id }?.title ?? entry.title },
                                set: { title in
                                    if let index = draft.attachments.firstIndex(where: { $0.id == entry.id }) {
                                        draft.attachments[index].title = title
                                    }
                                }))
                                .disabled(draft.hasStagedIdea || draft.isStaged(entry.id))
                            Button { draft.removeAttachment(entry.id) } label: { Image(systemName: "xmark") }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Remove attachment \(entry.title)")
                                .accessibilityIdentifier("capture.removeAttachment.\(entry.id)")
                                .help("Remove this attachment from the draft; keep the text")
                                .disabled(draft.hasStagedIdea)
                        }
                    }
                }.frame(height: min(130, CGFloat(draft.attachments.count) * 40))
            }
            if compact {
                compactActions
            } else {
                HStack {
                    Button("Files…", action: draft.chooseFiles)
                        .accessibilityIdentifier("capture.files")
                        .disabled(draft.hasStagedIdea)
                    Button("Paste", action: draft.paste).accessibilityIdentifier("capture.paste")
                        .disabled(draft.hasStagedIdea)
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
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("capture.result")
            }
        }
        .textFieldStyle(.roundedBorder)
        .disabled(draft.saving)
        .onAppear {
            draft.detailsExpanded = draft.detailsExpanded || !draft.title.isEmpty || !draft.link.isEmpty || !draft.tags.isEmpty
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            guard !draft.saving, !draft.hasStagedIdea else { return false }
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in
                        if !draft.saving, !draft.hasStagedIdea { draft.addFiles([url]) }
                    }
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
                        .disabled(draft.isEmpty || (draft.hasStagedIdea && folder.name != WorkspaceArea.ideas.directoryName))
            }
            if split.rest.isEmpty == false {
                Menu(split.leading.isEmpty ? "Folder" : "More") {
                    ForEach(split.rest) { folder in
                        Button(folder.name) { save(folder) }
                            .disabled(draft.hasStagedIdea && folder.name != WorkspaceArea.ideas.directoryName)
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
        destinations.first { $0.id == draft.destinationID && isAvailableDestination($0) }
    }

    private var compactActions: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {
                Button(action: draft.chooseFiles) { Label("Files", systemImage: "paperclip") }
                    .accessibilityIdentifier("capture.files")
                    .disabled(draft.hasStagedIdea)
                Button(action: draft.paste) { Label("Paste", systemImage: "doc.on.clipboard") }
                    .accessibilityIdentifier("capture.paste")
                    .disabled(draft.hasStagedIdea)
                Spacer()
                Button {
                    draft.detailsExpanded.toggle()
                } label: {
                    Label("Details", systemImage: draft.detailsExpanded ? "chevron.up" : "chevron.down")
                }
                .accessibilityIdentifier("capture.details")
            }
            .buttonStyle(.borderless)
            .font(.system(size: 11))
            if draft.detailsExpanded {
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
                    let ideasName = WorkspaceArea.ideas.directoryName
                    let recent = split.leading.filter { $0.name != ideasName }
                    let more = split.rest.filter { $0.name != ideasName }
                    Button("Inbox") { draft.destinationID = nil }
                    if let ideas = destinations.first(where: { $0.name == ideasName }) {
                        Button("New Idea") { draft.destinationID = ideas.id }
                    }
                    if !recent.isEmpty {
                        Section("Recent") { ForEach(recent) { folder in destinationButton(folder) } }
                    }
                    if !more.isEmpty {
                        Menu("More") { ForEach(more) { folder in destinationButton(folder) } }
                    }
                } label: {
                    Text(selectedDestination?.name ?? "Inbox").lineLimit(1)
                }
                .accessibilityIdentifier("capture.destination")
                .accessibilityLabel("Save destination")
                .onChange(of: draft.destinationID) { _, _ in model.captureDraft.links = .none }
                .help("Choose where this capture will be saved")
                .frame(maxWidth: 170, alignment: .leading)
                Spacer(minLength: 8)
                Button(selectedDestination?.name == WorkspaceArea.ideas.directoryName ? "Save Idea"
                       : selectedDestination.flatMap { model.isWorkQueue($0) ? "Add \($0.settings.workItemKind.displayName)" : nil } ?? "Add") { save(selectedDestination) }
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

    private func destinationButton(_ folder: WorkspaceFolder) -> some View {
        Button(folder.name) { draft.destinationID = folder.id }
            .disabled(!isAvailableDestination(folder))
    }

    private func isAvailableDestination(_ folder: WorkspaceFolder) -> Bool {
        !draft.hasStagedIdea || folder.name == WorkspaceArea.ideas.directoryName
    }

    private func save(_ destination: WorkspaceFolder?) {
        Task { @MainActor in await draft.save(using: model, destination: destination) }
    }

    private func thumbnail(_ entry: CaptureDraftEntry) -> some View {
        CaptureAttachmentThumbnail(entry: entry)
    }
}

/// The plain-text editor owns the Paste action while it has keyboard focus.
/// Handle attachments there, and let AppKit handle text insertion and undo.
private struct CaptureTextEditor: NSViewRepresentable {
    @Binding var text: String
    let editable: Bool
    let focusRequest: Int
    let pasteAttachments: (NSPasteboard) -> Bool

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        let editor = Editor()
        editor.isRichText = false
        editor.importsGraphics = false
        editor.allowsUndo = true
        editor.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        editor.isVerticallyResizable = true
        editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true
        editor.setAccessibilityIdentifier("ingest.captureField")
        editor.delegate = context.coordinator
        scroll.documentView = editor
        scroll.hasVerticalScroller = true
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let editor = scroll.documentView as? Editor else { return }
        context.coordinator.text = $text
        editor.isEditable = editable
        editor.pasteAttachments = pasteAttachments
        if editor.string != text { editor.string = text }
        if editor.focusRequest != focusRequest {
            editor.focusRequest = focusRequest
            editor.focus()
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        init(text: Binding<String>) { self.text = text }
        func textDidChange(_ notification: Notification) {
            if let editor = notification.object as? NSTextView { text.wrappedValue = editor.string }
        }
    }

    final class Editor: NSTextView {
        var pasteAttachments: ((NSPasteboard) -> Bool)?
        var focusRequest: Int?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil { focus() }
        }

        func focus() {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isEditable else { return }
                self.window?.makeFirstResponder(self)
            }
        }

        override func paste(_ sender: Any?) {
            guard isEditable else { return }
            if pasteAttachments?(.general) != true { super.paste(sender) }
        }

        override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
            if item.action == #selector(paste(_:)), isEditable {
                let clipboard = NSPasteboard.general
                if clipboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
                    || NSImage.canInit(with: clipboard) { return true }
            }
            return super.validateUserInterfaceItem(item)
        }
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
                case .file(let url):
                    // Videos can be large or not yet downloaded. Never decode an
                    // arbitrary file as an image just to draw the attachment row.
                    guard let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .image) else { return nil }
                    return NSImage(contentsOf: url)
                case .data(let data, _): return NSImage(data: data)
                default: return nil
                }
            }.value
        }
    }
}
