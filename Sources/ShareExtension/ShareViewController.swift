import UIKit
import SwiftUI
import UniformTypeIdentifiers
import BetterWorkspaceCore

/// Share → Better Workspace.
///
/// Saves whatever was shared — text, a link, photos, files — as real files in the same
/// shared iCloud Inbox the app writes to (`MobileCaptureService`), then hands any chosen
/// folder, idea or tags to the same capture queue (`MobileCaptureQueue`, in the app
/// group) so the Mac files it on its next sync. Save is the only required tap.
final class ShareViewController: UIViewController {
    private let model = ShareCaptureModel()

    override func viewDidLoad() {
        super.viewDidLoad()
        model.finish = { [weak self] in self?.extensionContext?.completeRequest(returningItems: nil) }
        model.cancel = { [weak self] in
            self?.extensionContext?.cancelRequest(withError: CocoaError(.userCancelled))
        }
        let host = UIHostingController(rootView: ShareCaptureView(model: model))
        addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        host.didMove(toParent: self)
        let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? [])
            .flatMap { $0.attachments ?? [] }
        Task { await model.load(providers) }
    }
}

@MainActor
@Observable
final class ShareCaptureModel {
    struct SharedFile: Identifiable {
        let id = UUID()
        var name: String
        let data: Data
        let ext: String
        let isImage: Bool
    }

    var text = ""
    var link = ""
    var title = ""
    var files: [SharedFile] = []
    var loading = true
    var saving = false
    var error: String?
    var savedMessage: String?
    var destinationPath: String?
    var asIdea = false
    var tagIDs: Set<String> = []
    var newTagNames: [String] = []
    private(set) var catalog: MobileCaptureCatalog

    var finish: () -> Void = {}
    var cancel: () -> Void = {}

    private let queue = MobileCaptureQueue.shared()

    init() {
        catalog = queue.catalog() ?? MobileCaptureCatalog(tags: [], destinations: [])
    }

    var destination: MobileCaptureDestination? {
        asIdea ? nil : destinationPath.flatMap { path in catalog.destinations.first { $0.path == path } }
    }

    var placeName: String { asIdea ? "New idea" : (destination?.name ?? "Inbox") }

    var isEmpty: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && link.isEmpty && files.isEmpty
    }

    /// Tags shown in the picker: the catalog plus any typed here as new.
    var tags: [Tag] {
        catalog.tags + newTagNames.map { Tag(id: "new:" + $0, name: $0) }
    }

    func load(_ providers: [NSItemProvider]) async {
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
               provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) == false,
               let url = try? await provider.loadItem(forTypeIdentifier: UTType.url.identifier) as? URL {
                link = url.absoluteString
                if title.isEmpty, let name = provider.suggestedName { title = name }
            } else if let type = Self.fileType(of: provider) {
                if let file = await Self.loadFile(provider, type: type) { files.append(file) }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
                      let string = try? await provider.loadItem(forTypeIdentifier: UTType.plainText.identifier) as? String {
                if link.isEmpty, (try? WorkspaceLink(title: "", url: string)) != nil {
                    link = string.trimmingCharacters(in: .whitespacesAndNewlines)
                } else {
                    text += (text.isEmpty ? "" : "\n\n") + string
                }
            }
        }
        loading = false
    }

    private static func fileType(of provider: NSItemProvider) -> UTType? {
        for identifier in provider.registeredTypeIdentifiers {
            guard let type = UTType(identifier) else { continue }
            if type.conforms(to: .image) || type.conforms(to: .movie) || type.conforms(to: .pdf)
                || (type.conforms(to: .data) && type.conforms(to: .text) == false && type != .url) {
                return type
            }
        }
        return nil
    }

    private static func loadFile(_ provider: NSItemProvider, type: UTType) async -> SharedFile? {
        await withCheckedContinuation { continuation in
            _ = provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { url, _ in
                guard let url, let data = try? Data(contentsOf: url) else { continuation.resume(returning: nil); return }
                let ext = url.pathExtension.isEmpty ? (type.preferredFilenameExtension ?? "") : url.pathExtension
                let name = provider.suggestedName ?? url.deletingPathExtension().lastPathComponent
                continuation.resume(returning: SharedFile(name: name, data: data, ext: ext, isImage: type.conforms(to: .image)))
            }
        }
    }

    func toggleTag(_ tag: Tag) {
        if tag.id.hasPrefix("new:") {
            newTagNames.removeAll { $0 == tag.name }
        } else if tagIDs.contains(tag.id) {
            tagIDs.remove(tag.id)
        } else {
            tagIDs.insert(tag.id)
        }
    }

    /// Matches against names typed here as well as the catalog, so "Raspberry Pi"
    /// and then "raspberry pi" stay one new tag.
    func createTag(_ name: String) {
        if let existing = TagMatching.equivalent(to: name, in: tags) {
            if existing.id.hasPrefix("new:") == false { tagIDs.insert(existing.id) }
        } else {
            newTagNames.append(name)
        }
    }

    var selectedTagIDs: Set<String> { tagIDs.union(newTagNames.map { "new:" + $0 }) }

    /// Writes to the shared Inbox, queues the filing request, tries once to send it, and
    /// closes. A capture that is in the Inbox is saved, whether or not the request could
    /// be sent yet; the app sends anything still queued the next time it runs.
    func save() async {
        guard saving == false, isEmpty == false else { return }
        saving = true
        defer { saving = false }
        guard let inbox = await Self.inbox() else {
            error = "iCloud Drive is not available to Better Workspace. Open the app to finish setting up the Inbox."
            return
        }
        var entries: [CaptureDraftEntry] = []
        if let note = CaptureDraftEntry.note(id: UUID(), title: title, markdown: text, url: link) { entries.append(note) }
        for file in files {
            entries.append(CaptureDraftEntry(title: entries.isEmpty && title.isEmpty == false ? title : file.name,
                                             content: .data(file.data, extension: file.ext)))
        }
        let service = MobileCaptureService(inbox: inbox)
        let result = await Task.detached(priority: .userInitiated) { service.capture(entries) }.value
        guard result.saved.isEmpty == false else {
            error = result.failures.first?.message ?? "Nothing could be saved."
            return
        }
        let tags = queue.tags(named: newTagNames)
        let allTagIDs = tagIDs.union(tags.map(\.id))
        let kind: CaptureClassificationKind? = asIdea ? .idea : nil
        for saved in result.saved {
            queue.record(savedURL: saved.url, destination: destination, kind: kind, tagIDs: allTagIDs)
        }
        // Best effort, bounded: the share sheet should close promptly.
        let queue = self.queue
        await withTaskGroup(of: Void.self) { group in
            group.addTask { _ = await queue.flush(using: MobileCloudStore()) }
            group.addTask { try? await Task.sleep(for: .seconds(4)) }
            await group.next()
            group.cancelAll()
        }
        savedMessage = MobileCaptureQueue.savedMessage(count: result.saved.count, destination: destination, kind: kind)
        error = result.failures.isEmpty ? nil : result.failures.map(\.message).joined(separator: "\n")
        try? await Task.sleep(for: .milliseconds(700))
        finish()
    }

    private static func inbox() async -> URL? {
        let containerID = IngestLocation.ubiquityContainerID
        return await Task.detached(priority: .userInitiated) { () -> URL? in
            guard let container = FileManager.default.url(forUbiquityContainerIdentifier: containerID) else { return nil }
            let inbox = container.appendingPathComponent("Documents", isDirectory: true)
                .appendingPathComponent(IngestLocation.inboxName, isDirectory: true)
            try? FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
            return inbox
        }.value
    }
}

struct ShareCaptureView: View {
    @Bindable var model: ShareCaptureModel
    @FocusState private var tagSearchFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                if model.loading {
                    HStack { ProgressView(); Text("Reading what you shared…").foregroundStyle(.secondary) }
                }
                Section {
                    TextField("Title (optional)", text: $model.title)
                        .accessibilityIdentifier("share-title")
                    if model.link.isEmpty == false {
                        Label(model.link, systemImage: "link").lineLimit(2).font(.footnote)
                    }
                    TextField("Note", text: $model.text, axis: .vertical)
                        .lineLimit(2...6)
                        .accessibilityIdentifier("share-note")
                    ForEach($model.files) { $file in
                        HStack {
                            if file.isImage, let image = UIImage(data: file.data) {
                                Image(uiImage: image).resizable().scaledToFill()
                                    .frame(width: 40, height: 40).clipShape(RoundedRectangle(cornerRadius: 6))
                            } else {
                                Image(systemName: "doc").frame(width: 40, height: 40)
                            }
                            TextField("File title", text: $file.name).font(.footnote)
                        }
                    }
                }
                Section("Save to") {
                    Picker("Destination", selection: Binding(
                        get: { model.asIdea ? "idea:" : (model.destinationPath ?? "") },
                        set: { value in
                            model.asIdea = value == "idea:"
                            model.destinationPath = (value.isEmpty || value == "idea:") ? nil : value
                        })) {
                        Text("Inbox").tag("")
                        Label("New idea", systemImage: "lightbulb").tag("idea:")
                        ForEach(model.catalog.destinations) { destination in
                            Text(destination.name).tag(destination.path)
                        }
                    }
                    .accessibilityIdentifier("share-destination")
                    if model.catalog.destinations.isEmpty {
                        Text("Folders appear here once Better Workspace on your Mac has synced.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section {
                    CaptureTagPicker(tags: model.tags, selectedIDs: model.selectedTagIDs,
                                     toggle: model.toggleTag, create: model.createTag, focus: $tagSearchFocused)
                }
                if let error = model.error {
                    Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.footnote)
                }
                if let saved = model.savedMessage {
                    Label(saved, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        .accessibilityIdentifier("share-saved")
                }
            }
            .navigationTitle("Better Workspace")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { model.cancel() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(model.saving ? "Saving…" : "Save") { Task { await model.save() } }
                        .fontWeight(.semibold)
                        .disabled(model.isEmpty || model.saving || model.loading)
                        .accessibilityIdentifier("share-save")
                }
            }
        }
    }
}
