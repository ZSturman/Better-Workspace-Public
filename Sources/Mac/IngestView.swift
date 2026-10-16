import SwiftUI
import UniformTypeIdentifiers
import AppKit
import BetterWorkspaceCore

/// The inbox processor.
///
/// Deliberately task-shaped rather than browse-shaped: a queue strip of what's waiting,
/// one item in focus, and a single confirm action that performs the move. Nothing is
/// ever moved without pressing that button (or its keyboard equivalent).
struct IngestView: View {
    @Environment(AppModel.self) private var model
    @State private var captureText = ""
    @State private var showingCapture = false
    @State private var isTargeted = false
    @State private var itemPendingDeletion: IngestItem?
    @FocusState private var captureFocused: Bool

    private var current: IngestItem? { model.currentIngestItem }

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            header
            Divider()

            if model.ingestStalled && model.ingestItems.isEmpty {
                stalledInbox
            } else if model.ingestItems.isEmpty, model.ingestScannedOnce == false {
                LoadingAreaState(title: "Reading the inbox…",
                                 message: "An iCloud inbox can take a few seconds to answer.")
            } else if model.ingestItems.isEmpty {
                if model.recentlyFiledIngest.isEmpty {
                    emptyInbox
                } else {
                    VStack(spacing: 0) {
                        emptyInbox.frame(maxHeight: 220)
                        Divider()
                        List { recentlyFiledSection }
                            .listStyle(.inset)
                    }
                }
            } else {
                HSplitView {
                    queueList
                        .frame(minWidth: 210, idealWidth: 250, maxWidth: 320, maxHeight: .infinity)
                    if let current {
                        // Keyed by the item so each one gets its own editing state. When
                        // these fields lived on IngestView, a newly captured item could
                        // shift which item was current and the in-flight title binding
                        // wrote the new item's title onto the previous item's record.
                        ProcessingPane(item: current, requestDeletion: { itemPendingDeletion = $0 })
                            .id(current.id)
                    } else {
                        VStack(spacing: 10) {
                            Label("Nothing due now", systemImage: "clock").font(.title3)
                            Text("Scheduled captures return on their chosen date. Select one in the queue to preview or change its schedule.")
                                .foregroundStyle(.secondary).multilineTextAlignment(.center)
                        }.frame(maxWidth: .infinity, maxHeight: .infinity).padding()
                    }
                }
            }
        }
        .background(
            isTargeted
                ? Color.accentColor.opacity(0.10)
                : Color.clear
        )
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
            handleDrop(providers)
            return true
        }
        .alert("Delete from Ingest?", isPresented: Binding(
            get: { itemPendingDeletion != nil },
            set: { if $0 == false { itemPendingDeletion = nil } }
        ), presenting: itemPendingDeletion) { item in
            Button("Delete", role: .destructive) {
                model.deleteIngestItem(item)
                itemPendingDeletion = nil
            }
            Button("Cancel", role: .cancel) { itemPendingDeletion = nil }
        } message: { item in
            Text("“\(item.title)” will move from the inbox to the recoverable Trash. This does not affect any already filed workspace item.")
        }
    }

    // MARK: - Header

    private var header: some View {
        AreaHeader(
            title: "Ingest",
            subtitle: inboxSubtitle,
            symbol: "tray.and.arrow.down",
            count: model.ingestScannedOnce ? model.unprocessedIngestCount : nil
        ) {
            HStack(spacing: Theme.Space.snug) {
                Button { showingCapture = true } label: {
                    Label("New Capture", systemImage: "square.and.pencil")
                }
                .help("Write a note or paste a link, image or file")
                .accessibilityIdentifier("ingest.newCapture")
                .popover(isPresented: $showingCapture) {
                    CaptureComposer().frame(width: 480).padding(16)
                }
                Button { openImportPanel() } label: {
                    Label("Import…", systemImage: "square.and.arrow.down")
                }
                Button { model.revealInFinder(model.ingest.location.inbox) } label: {
                    Label("Show Inbox in Finder", systemImage: "folder")
                }
                .labelStyle(.iconOnly)
                .help("Show the inbox in Finder (\(model.ingest.location.backingDescription): \(model.ingest.location.inbox.path))")
            }
        }
    }

    /// Only what needs saying: still looking, or items set aside. Where the inbox lives
    /// is in the folder button's tooltip.
    private var inboxSubtitle: String? {
        guard model.ingestLocationResolved else { return "Locating inbox…" }
        return model.deferredIngestCount > 0 ? "\(model.deferredIngestCount) skipped" : nil
    }

    // MARK: - Capture

    /// iCloud's file provider can take a long time to answer. Say so rather than
    /// claiming the inbox is empty.
    private var stalledInbox: some View {
        VStack(spacing: Theme.Space.snug) {
            ProgressView().controlSize(.small)
            Text("Waiting for iCloud").font(.title3.weight(.medium))
            Text("The inbox folder isn't answering yet. It will appear as soon as iCloud Drive responds.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button("Try again") { Task { await model.refreshIngest() } }
                .buttonStyle(.link)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(Theme.Space.section)
    }

    private var emptyInbox: some View {
        VStack(spacing: Theme.Space.snug) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 38, weight: .light))
                .foregroundStyle(.green.opacity(0.7))
            Text("Inbox zero").font(.title3.weight(.medium))
            Text("New captures wait here until you file them.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(Theme.Space.section)
    }

    // MARK: - Queue

    private var queueList: some View {
        VStack(spacing: 0) {
            HStack {
                Text("To file").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                Text("\(model.ingestItems.count)").font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
            }
            .padding(.horizontal, Theme.Space.base)
            .padding(.vertical, Theme.Space.tight)
            Divider()
            List {
                Section {
                ForEach(Array(model.ingestItems.enumerated()), id: \.element.id) { index, item in
                    Button { model.selectIngestItem(index) } label: {
                        HStack(alignment: .top, spacing: Theme.Space.tight) {
                            Image(systemName: item.state == .deferred ? "clock" : item.kind.symbolName)
                                .foregroundStyle(item.state == .deferred ? .secondary : Theme.kindColor(item.kind))
                                .frame(width: 16)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.title).lineLimit(2)
                                Text("\(item.source.displayName) · \(Format.relativeDate(item.capturedAt))")
                                    .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                                if item.state == .deferred {
                                    Text(item.reviewAfter.map { "Returns " + $0.formatted(date: .abbreviated, time: .omitted) } ?? "Skipped").font(.system(size: 10)).foregroundStyle(.secondary)
                                }
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, 3)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(item.id == current?.id ? Color.accentColor.opacity(0.18) : Color.clear)
                    .contextMenu {
                        Button("Delete from Ingest", role: .destructive) { itemPendingDeletion = item }
                    }
                    .accessibilityIdentifier("ingest.queue.\(item.id)")
                }
                }
                recentlyFiledSection
            }
            .listStyle(.sidebar)
        }
    }

    /// Already placed, so never counted or presented as waiting. Listed so a capture
    /// can still be tagged, edited or added to right after filing; selecting one opens
    /// the real item where it now lives.
    @ViewBuilder
    private var recentlyFiledSection: some View {
        if model.recentlyFiledIngest.isEmpty == false {
            Section("Recently filed") {
                ForEach(model.recentlyFiledIngest) { filed in
                    RecentlyFiledRow(record: filed.record, kind: filed.item.kind) {
                        model.openFiledIngest(filed)
                    }
                    .accessibilityIdentifier("ingest.filed.\(filed.record.title)")
                }
            }
        }
    }

    // MARK: - Actions

    private func handleDrop(_ providers: [NSItemProvider]) {
        for provider in providers {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in model.importURLs([url], source: .desktopDrop) }
            }
        }
    }

    private func pasteFromClipboard() {
        let pasteboard = NSPasteboard.general
        if let image = pasteboard.data(forType: .png) {
            model.importData(image, name: "Pasted Image", ext: "png")
            return
        }
        if let tiff = pasteboard.data(forType: .tiff),
           let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            model.importData(png, name: "Pasted Image", ext: "png")
            return
        }
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL], urls.isEmpty == false {
            model.importURLs(urls, source: .desktopImport)
            return
        }
        if let text = pasteboard.string(forType: .string) {
            captureText = captureText.isEmpty ? text : captureText + "\n" + text
        }
    }

    private func openImportPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Add to Inbox"
        if panel.runModal() == .OK {
            model.importURLs(panel.urls, source: .desktopImport)
        }
    }
}

/// Values and a closure only: a List cell must not look up the app model.
private struct RecentlyFiledRow: View {
    let record: FiledIngestRecord
    let kind: FileKind
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(alignment: .top, spacing: Theme.Space.tight) {
                Image(systemName: kind.symbolName)
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 3) {
                    Text(record.title).lineLimit(2)
                    Label(record.destinationName, systemImage: "checkmark.circle.fill")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.green)
                        .lineLimit(1)
                    Text("Filed \(Format.relativeDate(record.filedAt))")
                        .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.forward.square")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Filed in \(record.destinationName). Open it there to edit tags, text or attachments.")
    }
}

/// The focused item: preview, title, tags, destination, confirm.
private struct ProcessingPane: View {
    @Environment(AppModel.self) private var model
    let item: IngestItem
    let requestDeletion: (IngestItem) -> Void

    @State private var editingTitle = ""
    @State private var renameOnMove = ""
    /// Folder name of the chosen destination. A name, not a folder value, so a rename
    /// or a settings change elsewhere cannot leave a stale copy selected.
    @State private var chosenDestinationName: String?
    @State private var textPreview: String?
    @State private var showAllDestinations = false
    @State private var didLoad = false

    /// Below this width the preview and the classifier cannot both fit, and an
    /// overflowing classifier pushed File it off the window at 820×520.
    private static let splitMinimumWidth: CGFloat = 620

    var body: some View {
        GeometryReader { proxy in
            if proxy.size.width >= Self.splitMinimumWidth {
                HSplitView {
                    preview
                        .frame(minWidth: 280, idealWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
                    classifier
                        .frame(minWidth: 320, idealWidth: 420, maxWidth: 520, maxHeight: .infinity)
                }
            } else {
                // Narrow: filing comes first; the preview is one click away.
                VStack(spacing: 0) {
                    compactPreviewHeader
                    Divider()
                    classifier
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: item.id) {
            editingTitle = item.title
            renameOnMove = item.title
            chosenDestinationName = item.proposedDestination
            didLoad = true
            model.startDownloadingIngestItem(item)
            await loadPreview()
        }
    }

    // MARK: Preview

    private var compactPreviewHeader: some View {
        HStack(spacing: Theme.Space.tight) {
            Image(systemName: item.kind.symbolName).foregroundStyle(Theme.kindColor(item.kind))
            Text(item.url.lastPathComponent).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: Theme.Space.tight)
            Button("Quick Look") { QuickLookController.shared.preview([item.url]) }
                .buttonStyle(.link)
                .accessibilityIdentifier("ingest.quickLook")
        }
        .font(.system(size: 11))
        .padding(.horizontal, Theme.Space.base)
        .padding(.vertical, Theme.Space.tight)
    }

    private var preview: some View {
        VStack(spacing: 0) {
            HStack(spacing: Theme.Space.tight) {
                Image(systemName: item.source.symbolName).font(.system(size: 10))
                Text(item.source.displayName)
                Text("·")
                Text(Format.relativeDate(item.capturedAt))
                Text("·")
                Text(item.item.isDirectory
                     ? Format.count(item.item.immediateChildCount, singular: "item")
                     : Format.bytes(item.item.byteSize))
                Spacer()
                Text(item.url.lastPathComponent)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .padding(.horizontal, Theme.Space.base)
            .padding(.vertical, Theme.Space.tight)
            Divider()

            ScrollView {
                Group {
                    if item.item.isContentLocal == false {
                        // Selection has already asked iCloud to fetch this. Never show a
                        // second manual action: this is a transient loading state.
                        VStack(spacing: Theme.Space.snug) {
                            ProgressView().controlSize(.regular)
                            Image(systemName: "icloud.and.arrow.down")
                                .font(.system(size: 36, weight: .light))
                                .foregroundStyle(.secondary)
                            Text("Preparing preview").font(.headline)
                            Text("Downloading from iCloud. The preview appears automatically when it is ready.")
                                .font(.callout).foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, Theme.Space.section)
                    } else if let textPreview {
                        if item.kind == .markdown {
                            MarkdownView(text: textPreview)
                        } else {
                            Text(textPreview)
                                .font(.system(size: 12, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    } else if item.kind.isVisualMedia {
                        ThumbnailImage(url: item.url, kind: item.kind, size: 380, contentMode: .fit)
                            .frame(maxWidth: .infinity)
                    } else if item.item.isDirectory {
                        FolderManifest(url: item.url)
                    } else {
                        VStack(spacing: Theme.Space.snug) {
                            Image(systemName: item.kind.symbolName)
                                .font(.system(size: 40, weight: .light))
                                .foregroundStyle(Theme.kindColor(item.kind).opacity(0.7))
                            Text(item.kind.displayName).foregroundStyle(.secondary)
                            Button("Quick Look") { QuickLookController.shared.preview([item.url]) }
                                .buttonStyle(.link)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(Theme.Space.section)
                    }
                }
                .padding(Theme.Space.base)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
    }

    // MARK: Classifier

    private var classifier: some View {
        VStack(spacing: 0) {
            classifierScroll
            Divider()
            actionRow
                .padding(.horizontal, Theme.Space.base)
                .padding(.vertical, Theme.Space.snug)
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.35))
    }

    /// Everything editable, which grows with the number of destinations.
    private var classifierScroll: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.base) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Title")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary).textCase(.uppercase)
                    TextField("Title", text: $editingTitle)
                        .accessibilityIdentifier("ingest.titleField")
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { model.setIngestTitle(editingTitle, for: item) }
                        .onChange(of: editingTitle) { _, new in
                            // Only persist edits the user actually made, never the
                            // initial sync.
                            guard didLoad, new != item.title else { return }
                            model.setIngestTitle(new, for: item)
                            renameOnMove = new
                        }
                }

                // Exactly the same tag editor the Workspace inspector uses.
                TagEditor(
                    assigned: model.tags(for: item.item),
                    allTags: model.allTags,
                    onAssign: { model.assign(tag: $0, to: item.item) },
                    onUnassign: { model.unassign(tag: $0, from: item.item) },
                    onCreate: { model.createTag(named: $0) }
                )

                VStack(alignment: .leading, spacing: 5) {
                    Text("Destination")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary).textCase(.uppercase)
                    // The recently used few up front; the rest one click away, in the
                    // stable DestinationOrder.
                    destinationGrid(leadingDestinations, numbered: true)
                    if remainingDestinations.isEmpty == false {
                        Button {
                            showAllDestinations.toggle()
                        } label: {
                            Label(showAllDestinations ? "Fewer folders" : "More folders (\(remainingDestinations.count))",
                                  systemImage: showAllDestinations ? "chevron.up" : "chevron.down")
                                .font(.system(size: 11))
                        }
                        .buttonStyle(.borderless)
                        .accessibilityIdentifier("ingest.moreDestinations")
                        if showAllDestinations { destinationGrid(remainingDestinations, numbered: false) }
                    }
                }

                VStack(alignment: .leading, spacing: 5) {
                    Text("Filename on move")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary).textCase(.uppercase)
                    TextField("Name", text: $renameOnMove)
                        .accessibilityIdentifier("ingest.renameField")
                        .textFieldStyle(.roundedBorder)
                    if let destination = chosenDestination {
                        Text(verbatim: "→ \(destination.name)/\(resolvedFilename)")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }

            }
            .padding(Theme.Space.base)
        }
    }

    /// Skip, previous, next and File it, always on screen.
    ///
    /// These used to sit at the bottom of the same scroll view as the destination
    /// grid. Once the grid grew past a couple of rows they scrolled out of reach at
    /// the smallest supported window, which makes the queue unusable exactly when it
    /// is most cramped. The number of destinations is only going to keep growing, so
    /// they are pinned rather than merely made to fit today.
    private var actionRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: Theme.Space.tight) {
                    Menu("Priority \(item.priority)") {
                        ForEach(1...5, id: \.self) { value in
                            Button("\(value) · \(value == 5 ? "Highest" : value == 1 ? "Lowest" : "Priority")") {
                                model.scheduleIngestItem(item, priority: value, until: item.reviewAfter)
                            }
                        }
                    }.accessibilityIdentifier("ingest.priority")
                    Menu("Review later") {
                        ForEach([1, 3, 7, 30], id: \.self) { days in
                            Button("In \(days) day\(days == 1 ? "" : "s")") {
                                model.scheduleIngestItem(item, priority: item.priority, until: Date().addingTimeInterval(Double(days) * 86_400))
                            }
                        }
                        Button("Review now") { model.scheduleIngestItem(item, priority: item.priority, until: nil) }
                    }.accessibilityIdentifier("ingest.reviewLater")
                if let date = item.reviewAfter { Text("Returns " + date.formatted(date: .abbreviated, time: .omitted)).font(.caption).foregroundStyle(.secondary) }
                Spacer(minLength: 0)
            }
            HStack(spacing: Theme.Space.tight) {
                Button {
                    model.retreatIngestCursor()
                    } label: { Image(systemName: "chevron.left") }
                        .keyboardShortcut("[", modifiers: .command)
                        .help("Previous item")

                    Button {
                        model.advanceIngestCursor()
                    } label: { Image(systemName: "chevron.right") }
                        .keyboardShortcut("]", modifiers: .command)
                        .help("Next item")

                    if item.state == .pending {
                        Button("Skip") { model.deferIngestItem(item) }
                            .keyboardShortcut("s", modifiers: .command)
                            .help("Defer this item and move to the next")
                    } else {
                        Button("Un-skip") { model.undeferIngestItem(item) }
                    }

                    Button(role: .destructive) { requestDeletion(item) } label: {
                        Image(systemName: "trash")
                    }
                    .help("Delete from Ingest")

                    Spacer()

                    Button {
                        guard let destination = chosenDestination else { return }
                        model.classify(item, into: destination, renamingTo: renameOnMove)
                    } label: {
                        Label("File it", systemImage: "arrow.right.circle.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("ingest.fileItButton")
                    .keyboardShortcut(.return, modifiers: [])
                    .disabled(chosenDestination == nil || item.item.isContentLocal == false
                              || model.classifyingIDs.contains(item.id))
                    .help(item.item.isContentLocal ? "" : "Preparing from iCloud")
                }

            Text(chosenDestination == nil
                 ? "Pick a destination. Nothing moves until you confirm."
                 : "Press Return to move the real file into \(chosenDestination!.name).")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
    }

    private var resolvedFilename: String {
        let base = renameOnMove.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = base.isEmpty ? item.url.deletingPathExtension().lastPathComponent : base
        let ext = item.url.pathExtension
        return (item.item.isDirectory || ext.isEmpty) ? name : "\(name).\(ext)"
    }

    @MainActor
    private func loadPreview() async {
        textPreview = nil
        // A placeholder is never read: that would make the system download it first.
        guard item.item.isDirectory == false, item.item.isContentLocal else { return }
        switch item.kind {
        case .markdown, .document, .log, .code, .data:
            // Bounded and off the shared actor: an inbox file can still be mid-sync.
            let text = await FilesystemService.readText(at: item.url, maxBytes: 64 * 1024, timeout: .seconds(5))
            // The pane may have moved on to another capture while this read.
            guard Task.isCancelled == false else { return }
            textPreview = text
        default:
            break
        }
    }

    private func destinationGrid(_ destinations: [WorkspaceFolder], numbered: Bool) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 5), count: 3), spacing: 5) {
            ForEach(Array(destinations.enumerated()), id: \.element.id) { index, destination in
                Button {
                    chosenDestinationName = destination.name
                    model.ingest.setProposedDestination(folderNamed: destination.name, for: item)
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: destination.settings.symbol).font(.system(size: 13))
                        Text(destination.name).font(.system(size: 10, weight: .medium)).lineLimit(1)
                        if numbered, index < 9 { Text("⌘\(index + 1)").font(.system(size: 8)).foregroundStyle(.tertiary) }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, Theme.Space.tight)
                    .background(
                        RoundedRectangle(cornerRadius: 7)
                            .fill(chosenDestinationName == destination.name
                                  ? Color.accentColor.opacity(0.28)
                                  : Color.secondary.opacity(0.09))
                    )
                }
                .buttonStyle(.plain)
                .keyboardShortcut(numbered && index < 9
                                  ? KeyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command) : nil)
                .accessibilityIdentifier("ingest.destination.\(destination.name)")
            }
        }
    }

    /// Recently used destinations, plus the chosen one if it is not among them.
    private var leadingDestinations: [WorkspaceFolder] {
        let split = model.splitDestinations(limit: 6)
        guard let chosen = chosenDestination, split.leading.contains(where: { $0.id == chosen.id }) == false else {
            return split.leading
        }
        return split.leading + [chosen]
    }

    private var remainingDestinations: [WorkspaceFolder] {
        let leading = Set(leadingDestinations.map(\.id))
        return allDestinations.filter { leading.contains($0.id) == false }
    }

    /// A capture can go to any folder immediately below the Workspace root that its
    /// area settings offer. Nested folders are intentionally not destinations: the root
    /// folder is the app's unit of ownership and presentation.
    private var allDestinations: [WorkspaceFolder] {
        DestinationOrder.destinations(model.folders)
    }

    /// Resolved against the current folders every time. A remembered choice whose
    /// folder has since gone is no choice at all, and Return must not act on it.
    private var chosenDestination: WorkspaceFolder? {
        chosenDestinationName.flatMap(model.folder(named:))
    }
}

private struct FolderManifest: View {
    @Environment(AppModel.self) private var model
    let url: URL
    @State private var children: [WorkspaceItem] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Folder contents")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary).textCase(.uppercase)
            ForEach(children.prefix(60)) { child in
                HStack(spacing: Theme.Space.tight) {
                    Image(systemName: child.kind.symbolName)
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.kindColor(child.kind))
                        .frame(width: 13)
                    Text(child.name).font(.system(size: 11, design: .monospaced)).lineLimit(1)
                    Spacer()
                    Text(child.isDirectory ? Format.count(child.immediateChildCount, singular: "item")
                                           : Format.bytes(child.byteSize))
                        .font(.system(size: 10)).foregroundStyle(.tertiary)
                }
            }
            if children.count > 60 {
                Text("+\(children.count - 60) more").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            if children.isEmpty {
                Text("Empty folder").font(.system(size: 11)).foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: url.path) { @MainActor in
            children = (try? await model.fs.items(inDirectory: url)) ?? []
        }
    }
}
