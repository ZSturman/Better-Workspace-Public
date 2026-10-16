import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import UIKit
import TipKit
import BetterWorkspaceCore
import QuickLook

struct CaptureScreen: View {
    @Environment(MobileModel.self) private var model
    let captureRequest: Int

    @State private var text = ""
    @State private var title = ""
    @State private var link = ""
    @State private var saving = false
    @State private var loadingPhotos = false
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var organizing = false
    @State private var addingLink = false
    @State private var showingFileImporter = false
    @State private var choosingFolder = false
    @State private var showingCamera = false
    @State private var openedCapture: RecentCaptureRow?
    private enum CaptureField: Hashable { case note, title, link, attachment(UUID) }
    @FocusState private var focusedField: CaptureField?
    @FocusState private var tagSearchFocused: Bool
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if model.isResolving {
                        resolvingCard
                    } else if model.isReady == false {
                        setupCard
                    }

                    captureCard

                    if model.recentRows.isEmpty == false { recentSection }
                }
                .padding(16)
                // A single readable column. Without it the cards stretch the full width
                // in landscape and on iPad, which left the note field a thin ribbon and
                // stranded everything else.
                .frame(maxWidth: 640)
                .frame(maxWidth: .infinity)
            }
            // Scrolling and the keyboard accessory both provide an explicit way out.
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Ingest")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        choosingFolder = true
                        showingFileImporter = true
                    } label: {
                        Image(systemName: "folder.badge.gearshape")
                    }
                    .accessibilityLabel("Choose inbox folder")
                }
                // Explicit escape from the keyboard — a capture app should never trap you.
                ToolbarItem(placement: .keyboard) {
                    HStack {
                        Spacer()
                        Button("Done") { focusedField = nil; tagSearchFocused = false }
                            .fontWeight(.semibold)
                    }
                }
            }
            // One presenter serves files and folders; stacked importers suppress the first sheet.
            .fileImporter(isPresented: $showingFileImporter,
                          allowedContentTypes: choosingFolder ? [.folder] : [.item],
                          allowsMultipleSelection: choosingFolder == false) { result in
                if case .success(let urls) = result {
                    if choosingFolder, let folder = urls.first {
                        model.setDestination(folder)
                    } else {
                        model.stageFiles(urls)
                    }
                }
            }
            .onChange(of: photoItems) { _, items in
                Task { await loadPhotos(items) }
            }
            .sheet(isPresented: $showingCamera) {
                CameraPicker { image in
                    guard let data = image.jpegData(compressionQuality: 0.92) else {
                        model.errorMessage = "The camera photo could not be saved."
                        return
                    }
                    let name = "Camera \(Date().formatted(.dateTime.year().month().day().hour().minute().second()))"
                    model.stageImageData(data, name: name, ext: "jpg")
                }
                .ignoresSafeArea()
            }
            .sheet(item: $openedCapture) { row in
                RecentCaptureSheet(row: row)
                    .environment(model)
            }
            .task {
                IngestGuidance.viewedCaptureScreen()
                model.setInboxMonitoring(active: scenePhase == .active)
                openWidgetCapture()
            }
            .onChange(of: model.widgetCaptureName) { _, _ in openWidgetCapture() }
            .onChange(of: model.recentRows) { _, _ in openWidgetCapture() }
            .onChange(of: captureRequest) { _, _ in
                focusedField = .note
            }
            .onChange(of: scenePhase) { _, phase in
                model.setInboxMonitoring(active: phase == .active)
            }
            .overlay(alignment: .bottom) { statusToast }
            .disabled(saving)
        }
    }

    // MARK: - Setup

    private var resolvingCard: some View {
        HStack(spacing: 10) {
            ProgressView()
            Text("Connecting to iCloud…")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
    }

    private var setupCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Pick the shared inbox folder", systemImage: "exclamationmark.triangle.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.orange)
            Text("iCloud isn't available, so captures have nowhere to sync. Turn on iCloud Drive for this app, or pick a folder yourself — captures are written there as real files and the Mac picks them up.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Button {
                choosingFolder = true
                showingFileImporter = true
            } label: {
                Label("Choose Folder", systemImage: "folder")
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(14)
        .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 14))
    }

    // MARK: - Text capture

    private var captureCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("New capture").font(.subheadline.weight(.semibold))
                Spacer()
                Label(model.inboxDescription, systemImage: "tray.and.arrow.down")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .layoutPriority(-1)
                    .help(model.inboxDescription)
            }

            TextField("Title (optional)", text: $title)
                .focused($focusedField, equals: .title)
                .accessibilityIdentifier("capture-title")
            if addingLink || !link.isEmpty {
            TextField("URL (optional)", text: $link)
                .focused($focusedField, equals: .link)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityIdentifier("capture-url")
            }
            TextEditor(text: $text)
                // Tall in portrait, short in landscape — a fixed 130 swallowed most of a
                // landscape screen and left nothing else visible.
                .frame(minHeight: verticalSizeClass == .compact ? 88 : 130)
                .focused($focusedField, equals: .note)
                .accessibilityIdentifier("capture-text")
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
                .overlay(alignment: .topLeading) {
                    if text.isEmpty {
                        Text("What would you like to record?")
                            .foregroundStyle(.tertiary)
                            .padding(14)
                            .allowsHitTesting(false)
                    }
                }

            attachmentRow
            if model.draftAttachments.isEmpty == false { draftAttachmentsSection }

            DisclosureGroup("Organize · \(selectedDestinationName)", isExpanded: $organizing) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Label("Destination", systemImage: "folder")
                        .font(.footnote.weight(.semibold))
                    Spacer()
                }

                destinationMenu

                // A work queue makes the capture a work item there; where it belongs is
                // optional, and anything without a project waits under Needs Attention.
                if let kind = model.selectedCaptureDestination?.workItemKind {
                    VStack(alignment: .leading, spacing: 4) {
                        MobileWorkLinkPickers(kind: kind, links: model.selectedCaptureLinks.applicable(to: kind), labeled: true) {
                            model.selectedCaptureLinks = $0
                        }
                    }
                    .pickerStyle(.menu)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("capture-work-links")
                }

                CaptureTagPicker(
                    tags: model.availableTags,
                    selectedIDs: model.selectedCaptureTagIDs,
                    toggle: { model.toggleCaptureTag($0.id) },
                    create: { model.createCaptureTag(named: $0) },
                    focus: $tagSearchFocused
                )
                if model.availableTags.isEmpty, let message = model.classificationCloudMessage {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                }
                if let message = model.classificationDeliveryMessage {
                    Label(message, systemImage: "clock.arrow.circlepath")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .accessibilityIdentifier("classification-delivery-status")
                }
            }
            .padding(12)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
            }

            HStack(spacing: 10) {
                Button("Add link", systemImage: "link") { addingLink = true; focusedField = .link }
                    .buttonStyle(.borderless)

                Spacer()

                Button {
                    guard !saving else { return }
                    saving = true
                    Task { @MainActor in
                        let result = await model.saveDraft(note: text, title: title, link: link)
                        if result.noteSaved { text = ""; title = ""; link = "" }
                        if result.complete { focusedField = nil; tagSearchFocused = false }
                        saving = false
                    }
                } label: {
                    Label("Save", systemImage: "arrow.down.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(saving || loadingPhotos || model.isReady == false || (text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && link.isEmpty && model.draftAttachments.isEmpty))
            }
            // Until the next capture starts: the toast fades in seconds, this does not.
            if let receipt = model.lastSaveReceipt, text.isEmpty, title.isEmpty, link.isEmpty, model.draftAttachments.isEmpty {
                Label(receipt, systemImage: "checkmark.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("capture-receipt")
            }
        }
        .padding(14)
        .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.secondary.opacity(0.18)))
    }

    private var destinationMenu: some View {
        Menu {
            Button("Inbox") { model.selectedCaptureDestinationPath = nil; model.selectedCaptureKind = nil }
            Button("New idea", systemImage: "lightbulb") {
                model.selectedCaptureDestinationPath = nil
                model.selectedCaptureKind = .idea
            }
            if model.workspaceFolders.isEmpty == false {
                // The few used most recently up front; the rest under More.
                let split = model.splitDestinations(limit: 5)
                Section("Recent") {
                    ForEach(split.leading) { destination in
                        Button(destination.name) {
                            model.selectedCaptureKind = nil
                            model.selectedCaptureLinks = .none
                            model.selectCaptureDestination(destination)
                        }
                    }
                }
                if split.rest.isEmpty == false {
                    Menu("More") {
                        ForEach(split.rest) { destination in
                            Button(destination.name) {
                                model.selectedCaptureKind = nil
                                model.selectedCaptureLinks = .none
                                model.selectCaptureDestination(destination)
                            }
                        }
                    }
                }
            }
        } label: {
            Label(selectedDestinationName, systemImage: model.selectedCaptureKind == .idea ? "lightbulb" : "folder")
        }
        .buttonStyle(.bordered)
        .accessibilityLabel("Destination")
    }

    private var selectedDestinationName: String {
        if model.selectedCaptureKind == .idea { return "New idea" }
        guard let path = model.selectedCaptureDestinationPath,
              let destination = model.workspaceFolders.first(where: { $0.path == path })
        else { return "Inbox" }
        return destination.name
    }

    // MARK: - Attachments

    private var attachmentRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Attach").font(.subheadline.weight(.semibold))
            HStack(spacing: 10) {
                PhotosPicker(selection: $photoItems, maxSelectionCount: 10, matching: .any(of: [.images, .videos])) {
                    attachmentTile(symbol: "photo.on.rectangle", title: "Photos")
                }
                .disabled(model.isReady == false)

                Button { choosingFolder = false; showingFileImporter = true } label: {
                    attachmentTile(symbol: "doc", title: "Files")
                }
                .disabled(model.isReady == false)


                Button { pasteAttachment() } label: {
                    attachmentTile(symbol: "doc.on.clipboard.fill", title: "Paste media")
                }
                .disabled(model.isReady == false)

                Button { showingCamera = true } label: {
                    attachmentTile(symbol: "camera", title: "Camera")
                }
                .disabled(model.isReady == false || UIImagePickerController.isSourceTypeAvailable(.camera) == false)
            }
        }
    }

    private var draftAttachmentsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Ready to save")
                .font(.footnote.weight(.semibold))
            ForEach(model.draftAttachments) { attachment in
                HStack(spacing: 10) {
                    if attachment.isImage, let image = UIImage(contentsOfFile: attachment.url.path) {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 52, height: 52)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    } else {
                        Image(systemName: "doc")
                            .frame(width: 52, height: 52)
                            .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 8))
                    }
                    TextField("Image or file title", text: Binding(
                        get: { model.draftAttachments.first(where: { $0.id == attachment.id })?.name ?? attachment.name },
                        set: { model.renameDraftAttachment(attachment.id, title: $0) }
                    )).font(.footnote)
                        .focused($focusedField, equals: .attachment(attachment.id))
                        .accessibilityIdentifier("capture-attachment-title")
                    Spacer()
                    Button(role: .destructive) { model.removeDraftAttachment(attachment) } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .accessibilityLabel("Remove \(attachment.name)")
                }
            }
        }
        .padding(12)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
    }

    private func attachmentTile(symbol: String, title: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: 20, weight: .light))
            Text(title).font(.caption2)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    private func openWidgetCapture() {
        guard let name = model.widgetCaptureName else { return }
        if let row = model.recentRows.first(where: { $0.name == name }) {
            openedCapture = row; model.widgetCaptureName = nil
        } else { model.statusMessage = "The capture is not in this phone's last inbox listing. Pull to refresh or check its status on Mac." }
    }

    // MARK: - Recent

    /// Everything recently ingested, wherever it went. Each row says where that is,
    /// so something already filed is never presented as waiting in the Inbox.
    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Recently Added").font(.subheadline.weight(.semibold))
                Spacer()
                if model.needsFilingCount > 0 {
                    Label("\(model.needsFilingCount) to file", systemImage: "tray")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("recent-needs-filing-count")
                }
            }

            ForEach(model.recentRows) { row in
                Button { openedCapture = row } label: {
                    HStack(spacing: 10) {
                        Image(systemName: model.recentCapture(for: row)?.kind.symbolName ?? "doc")
                            .foregroundStyle(.tint)
                            .frame(width: 20)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.name).font(.footnote).lineLimit(1)
                            RecentPlacementLabel(placement: row.placement)
                        }
                        Spacer()
                        Text(row.date.formatted(.relative(presentation: .named)))
                            .font(.caption2).foregroundStyle(.tertiary)
                            .lineLimit(1)
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("recent-capture")
                .accessibilityHint(row.placement.isPlaced ? "Add tags" : "File or tag")
                .padding(.vertical, 6)
                .padding(.horizontal, 10)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
                .contextMenu {
                    if let capture = model.recentCapture(for: row) {
                        Button(role: .destructive) { model.delete(capture) } label: {
                            Label("Delete from Inbox", systemImage: "trash")
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var statusToast: some View {
        if let message = model.errorMessage ?? model.statusMessage {
            let isError = model.errorMessage != nil
            HStack(spacing: 8) {
                Image(systemName: isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(isError ? .orange : .green)
                Text(message).font(.footnote)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(.regularMaterial, in: Capsule())
            .padding(.bottom, 12)
            .task(id: message) {
                try? await Task.sleep(for: .seconds(3))
                model.statusMessage = nil
                model.errorMessage = nil
            }
        }
    }

    // MARK: - Helpers

    @MainActor
    private func loadPhotos(_ items: [PhotosPickerItem]) async {
        guard !items.isEmpty else { return }
        loadingPhotos = true
        defer { loadingPhotos = false }
        for item in items {
            guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
            let ext = item.supportedContentTypes.first?.preferredFilenameExtension ?? "jpg"
            let name = "Photo \(Date().formatted(.dateTime.year().month().day().hour().minute().second()))"
            model.stageImageData(data, name: name, ext: ext)
        }
        photoItems = []
    }

    private enum PastePayload: Sendable {
        case images([(data: Data, ext: String)])
        case text(String)
    }

    /// Pastes without freezing the app.
    ///
    /// Reading pasteboard *contents* puts up the system "Allow Paste?" alert, and the
    /// accessor blocks until it is answered. Doing that on the main actor froze the whole
    /// UI behind the alert — keyboard, scrolling and animation all stopped, and under
    /// automation the app stopped answering accessibility queries entirely and was
    /// spindumped. `hasImages`/`hasStrings` are the documented way to ask what is there
    /// without touching contents, so they decide first and the blocking read happens off
    /// the main actor. Asking only about the type that is actually present also stops the
    /// old code prompting twice for a text-only clipboard.
    private func pasteAttachment() {
        let pasteboard = UIPasteboard.general
        let hasImages = pasteboard.hasImages
        let hasStrings = pasteboard.hasStrings
        guard hasImages || hasStrings else {
            model.errorMessage = "Nothing usable on the clipboard."
            return
        }
        Task { @MainActor in
            let payload = await Task.detached(priority: .userInitiated) { () -> PastePayload? in
                if hasImages {
                    var images: [(data: Data, ext: String)] = []
                    for item in UIPasteboard.general.items {
                        for (typeName, value) in item {
                            if let type = UTType(typeName), type.conforms(to: .image), let data = value as? Data {
                                images.append((data, type.preferredFilenameExtension ?? "png"))
                                break
                            }
                        }
                    }
                    if images.isEmpty {
                        images = (UIPasteboard.general.images ?? []).compactMap { image in
                            image.pngData().map { ($0, "png") }
                        }
                    }
                    if !images.isEmpty { return .images(images) }
                }
                if hasStrings, let string = UIPasteboard.general.string,
                   string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                    return .text(string)
                }
                return nil
            }.value

            switch payload {
            case .images(let images):
                for image in images { model.stageImageData(image.data, name: "Pasted Image", ext: image.ext) }
            case .text(let string):
                if (try? WorkspaceLink(title: "", url: string)) != nil { link = string.trimmingCharacters(in: .whitespacesAndNewlines) }
                else { text = text.isEmpty ? string : text + "\n" + string }
            case nil:
                // `hasImages`/`hasStrings` already said there was something to paste, so
                // reaching here means the read came back empty — almost always because
                // the system paste prompt was declined. Saying the clipboard is empty
                // would be telling the user the opposite of what happened.
                model.errorMessage = "Paste was not allowed, so nothing was saved."
            }
        }
    }
}

/// Where a recent capture is, in words and colour: waiting, on its way, or placed.
private struct RecentPlacementLabel: View {
    let placement: RecentCapturePlacement

    var body: some View {
        switch placement {
        case .needsFiling:
            Label("Inbox · Needs filing", systemImage: "tray")
                .font(.caption2.weight(.medium)).foregroundStyle(.orange)
        case .filing(let destination):
            Label("\(destination) · Filing when your Mac syncs", systemImage: "arrow.right.circle")
                .font(.caption2).foregroundStyle(.secondary)
        case .filed(let destination, _):
            Label(destination, systemImage: "checkmark.circle.fill")
                .font(.caption2.weight(.medium)).foregroundStyle(.green)
        case .filedOnMac:
            Label("Filed on your Mac", systemImage: "checkmark.circle")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }
}

/// Follow-up for one recent capture. Something still in the Inbox can be tagged and
/// filed; something already filed can be tagged where it now lives. Its text and files
/// are edited on the Mac, which is the only device with the Workspace itself.
private struct RecentCaptureSheet: View {
    @Environment(MobileModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let row: RecentCaptureRow

    @State private var tagIDs: Set<String> = []
    @State private var destinationPath: String?
    @State private var reviewPriority = 3
    @State private var reviewDate = Date().addingTimeInterval(86_400)
    @FocusState private var tagSearchFocused: Bool

    private var destination: MobileModel.WorkspaceDestination? {
        destinationPath.flatMap { path in model.workspaceFolders.first { $0.path == path } }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Name", value: row.name)
                    LabeledContent("Added", value: row.date.formatted(date: .abbreviated, time: .shortened))
                    HStack {
                        Text("Status")
                        Spacer()
                        RecentPlacementLabel(placement: row.placement)
                    }
                }
                switch row.placement {
                case .needsFiling:
                    if let capture = model.recentCapture(for: row) { fileSections(for: capture) }
                case .filing(let name):
                    Section {
                        Text("Your Mac moves this into \(name) the next time it syncs. Once it is filed you can add tags here.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                case .filed(let name, let path):
                    if let path, model.publishedEntry(atPath: path) != nil {
                        Section {
                            CaptureTagPicker(
                                tags: model.availableTags,
                                selectedIDs: model.tagIDs(ofFiledPath: path),
                                toggle: { model.toggleTag($0.id, onFiledPath: path) },
                                create: { name in
                                    if let tag = model.tagForName(name) { model.toggleTag(tag.id, onFiledPath: path) }
                                },
                                focus: $tagSearchFocused
                            )
                        } footer: {
                            Text("Filed in \(name). Edit its text or add files on your Mac.")
                        }
                    } else {
                        Section {
                            Text("Filed in \(name). Tags can be added here once your Mac's index shows it there.")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                case .filedOnMac:
                    Section {
                        Text("This left the Inbox on your Mac. Find it in its folder there to tag or edit it.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle(row.placement.isPlaced ? "Filed capture" : "In the Inbox")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                if case .needsFiling = row.placement, let capture = model.recentCapture(for: row) {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(destination == nil ? "Save Tags" : "File") {
                            model.classify(capture, tagIDs: tagIDs, destination: destination)
                            dismiss()
                        }
                        .disabled(destination == nil && tagIDs.isEmpty)
                        .accessibilityIdentifier("recent-capture-confirm")
                    }
                }
                ToolbarItem(placement: .keyboard) {
                    HStack { Spacer(); Button("Done") { tagSearchFocused = false }.fontWeight(.semibold) }
                }
            }
        }
    }

    @ViewBuilder
    private func fileSections(for capture: MobileModel.RecentCapture) -> some View {
        CaptureFilePreviewSection(capture: capture)

        Section("Priority & return date") {
            Picker("Priority", selection: $reviewPriority) {
                ForEach(1...5, id: \.self) { Text("\($0) · \($0 == 5 ? "Highest" : $0 == 1 ? "Lowest" : "Priority")").tag($0) }
            }
            DatePicker("Show again", selection: $reviewDate, in: Date()..., displayedComponents: [.date])
            Button("Save priority & return date") { model.schedule(capture, priority: reviewPriority, until: Calendar.current.startOfDay(for: reviewDate)) }
            Button("Review now") { model.schedule(capture, priority: reviewPriority, until: nil) }
            if let message = model.classificationCloudMessage { Text(message).font(.caption).foregroundStyle(.secondary) }
        }.onAppear {
            if let settings = model.reviewSettings(for: capture) {
                reviewPriority = settings.priority
                reviewDate = max(settings.until ?? Date().addingTimeInterval(86_400), Date())
            }
        }
        Section {
            CaptureTagPicker(
                tags: model.availableTags,
                selectedIDs: tagIDs,
                toggle: { tag in
                    if tagIDs.contains(tag.id) { tagIDs.remove(tag.id) } else { tagIDs.insert(tag.id) }
                },
                create: { name in if let tag = model.tagForName(name) { tagIDs.insert(tag.id) } },
                focus: $tagSearchFocused
            )
        }
        Section("File into") {
            if model.workspaceFolders.isEmpty {
                Text("Workspace folders appear here once your Mac syncs.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            ForEach(model.workspaceFolders) { folder in
                Button {
                    destinationPath = destinationPath == folder.path ? nil : folder.path
                } label: {
                    HStack {
                        Label(folder.name, systemImage: "folder")
                        Spacer()
                        if destinationPath == folder.path {
                            Image(systemName: "checkmark").foregroundStyle(.tint)
                        }
                    }
                }
                .foregroundStyle(.primary)
                .accessibilityIdentifier("file-into-\(folder.name)")
            }
        }
    }
}

private struct CameraPicker: UIViewControllerRepresentable {
    let onImage: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.cameraCaptureMode = .photo
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker

        init(parent: CameraPicker) { self.parent = parent }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage { parent.onImage(image) }
            parent.dismiss()
        }
    }
}

/// Quick Look manages one selected file. Bundle captures expose only immediate,
/// locally available children, read with the same file-provider timeout as Ingest.
private struct CaptureFilePreviewSection: View {
    let capture: MobileModel.RecentCapture
    @State private var files: [URL] = []
    @State private var previewURL: URL?
    var body: some View {
        Section("Preview") {
            ForEach(files, id: \.self) { url in
                Button(url.lastPathComponent, systemImage: "doc.richtext") { previewURL = url }
            }
            if files.isEmpty { Text("A preview appears when this capture is available locally.").font(.caption).foregroundStyle(.secondary) }
        }
        .quickLookPreview($previewURL)
        .task(id: capture.url) { @MainActor in
            let url = capture.url
            let values = await Task.detached(priority: .utility) { try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .ubiquitousItemDownloadingStatusKey]) }.value
            guard values?.isSymbolicLink != true else { return }
            if values?.isDirectory != true {
                if values?.ubiquitousItemDownloadingStatus == nil || values?.ubiquitousItemDownloadingStatus == .current { files = [url] }
                return
            }
            guard let children = await FilesystemService.items(inDirectory: url, timeout: .seconds(2)) else { return }
            files = await Task.detached(priority: .utility) {
                Array(children.filter { !$0.isDirectory && $0.isContentLocal && $0.url.resolvingSymlinksInPath().canonicalPath.hasPrefix(url.canonicalPath + "/") }.prefix(12).map(\.url))
            }.value
        }
    }
}
