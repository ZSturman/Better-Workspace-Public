import AppKit
import BetterWorkspaceCore

/// The Mac's side of the shared capture intents (`Sources/Intents`).
///
/// The same path as the menu bar composer: `IngestService` writes the capture into the
/// Inbox, then — when a folder is chosen — files it there at once (or makes it an idea
/// folder in Ideas). Tags go on before filing so they follow the item.
@MainActor
enum PlatformCaptureBackend {
    private static var model: AppModel? { AppDelegate.current?.model }

    static func destinations() async -> [CaptureDestinationEntity] {
        guard let model else { return [] }
        if model.folders.isEmpty { await model.refreshFolders() }
        return DestinationOrder.destinations(model.folders).map { CaptureDestinationEntity(id: $0.name, name: $0.name) }
    }

    static func tags() async -> [CaptureTagEntity] {
        guard let model else { return [] }
        if model.allTags.isEmpty { model.reloadTags() }
        return model.allTags.map { CaptureTagEntity(id: $0.id, name: $0.name) }
    }

    static func capture(_ request: CaptureIntentRequest) async throws -> String {
        guard let model else { throw CaptureIntentError.nothingToCapture }
        var destination: WorkspaceFolder?
        if let id = request.destinationID {
            if model.folders.isEmpty { await model.refreshFolders() }
            guard let folder = model.folder(named: id) else { throw CaptureIntentError.unknownFolder }
            destination = folder
        }
        var tags = request.tags.filter { $0.isNew == false }.compactMap { entity in model.allTags.first { $0.id == entity.id } }
        for entity in request.tags where entity.isNew {
            let existing = TagMatching.equivalent(to: entity.name, in: model.allTags)
            if let tag = existing ?? model.createTag(named: entity.name), tags.contains(tag) == false { tags.append(tag) }
        }

        var entries: [CaptureDraftEntry] = []
        if let note = CaptureDraftEntry.note(id: UUID(), title: request.title ?? "", markdown: request.text ?? "",
                                             url: request.link ?? "") {
            entries.append(note)
        }
        for file in request.files {
            let base = (file.filename as NSString).deletingPathExtension
            let named = entries.isEmpty ? (request.title ?? "") : ""
            entries.append(CaptureDraftEntry(title: named.isEmpty ? base : named,
                                             content: .data(file.data, extension: (file.filename as NSString).pathExtension)))
        }
        guard entries.isEmpty == false else { throw CaptureIntentError.nothingToCapture }

        let service = model.ingest
        var count = 0
        for entry in entries {
            let item = try await Task.detached(priority: .userInitiated) { try service.capture(entry) }.value
            if let destination, model.isWorkQueue(destination), request.asIdea == false {
                _ = try await model.promoteCapture(item, toQueue: destination, tagIDs: Set(tags.map(\.id)))
                count += 1
                continue
            }
            for tag in tags { model.tagStore.assign(tagID: tag.id, to: item.url, area: nil) }
            if request.asIdea {
                try model.fileAsIdea(item, tagIDs: Set(tags.map(\.id)))
            } else if let destination {
                _ = try await Task.detached(priority: .userInitiated) {
                    let unique = CaptureNaming.uniqueURL(in: destination.url,
                        base: item.url.deletingPathExtension().lastPathComponent, extension: item.url.pathExtension)
                    return try service.file(item, intoDirectory: destination.url,
                                            renamingTo: unique.deletingPathExtension().lastPathComponent)
                }.value
            }
            count += 1
        }
        await model.refreshIngest()
        if let destination {
            model.noteFiled(into: destination.name)
            await model.refresh(areaNamed: destination.name)
        }
        if request.asIdea { await model.refresh(area: .ideas) }
        let place = request.asIdea ? WorkspaceArea.ideas.directoryName : destination?.name
        return RecentCaptureHistory.savedMessage(count: count, destinationName: place)
    }

    static func clipboardRequest() async -> CaptureIntentRequest? {
        let pasteboard = NSPasteboard.general
        if let png = pasteboard.data(forType: .png) {
            return CaptureIntentRequest(files: [(data: png, filename: "Clipboard \(CaptureNaming.timestampName()).png")])
        }
        if let tiff = pasteboard.data(forType: .tiff), let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            return CaptureIntentRequest(files: [(data: png, filename: "Clipboard \(CaptureNaming.timestampName()).png")])
        }
        if let text = pasteboard.string(forType: .string),
           text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            if (try? WorkspaceLink(title: "", url: text)) != nil {
                return CaptureIntentRequest(link: text.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            return CaptureIntentRequest(text: text)
        }
        return nil
    }
}
