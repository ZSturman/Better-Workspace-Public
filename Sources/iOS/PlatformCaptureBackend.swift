import Foundation
import UIKit
import BetterWorkspaceCore

/// The phone's side of the shared capture intents (`Sources/Intents`).
///
/// Everything goes through `MobileModel.shared` — the same Inbox write and capture
/// queue the Capture screen uses. A capture is successful once it is a file in the
/// shared Inbox; a chosen folder, idea or tags travel as a queued request that the
/// Mac applies when it syncs. The phone never touches the Workspace itself.
@MainActor
enum PlatformCaptureBackend {
    static func destinations() async -> [CaptureDestinationEntity] {
        await MobileModel.shared.intentCatalog().destinations
            .map { CaptureDestinationEntity(id: $0.path, name: $0.name) }
    }

    static func tags() async -> [CaptureTagEntity] {
        await MobileModel.shared.intentCatalog().tags
            .map { CaptureTagEntity(id: $0.id, name: $0.name) }
    }

    static func capture(_ request: CaptureIntentRequest) async throws -> String {
        let model = MobileModel.shared
        let catalog = await model.intentCatalog()
        var destination: MobileCaptureDestination?
        if let id = request.destinationID {
            guard let found = catalog.destinations.first(where: { $0.path == id }) else {
                throw CaptureIntentError.unknownFolder
            }
            destination = found
        }
        let tags = model.intentTags(ids: request.tags.filter { $0.isNew == false }.map(\.id),
                                    newNames: request.tags.filter(\.isNew).map(\.name))
        return try await model.captureFromIntent(
            text: request.text, title: request.title, link: request.link, files: request.files,
            destination: destination, kind: request.asIdea ? .idea : nil, tags: tags)
    }

    /// What is on the clipboard, asking only about the types present first (reading
    /// contents is what triggers the paste prompt). An image wins over text, and text
    /// that is a single URL becomes a link capture.
    static func clipboardRequest() async -> CaptureIntentRequest? {
        let pasteboard = UIPasteboard.general
        if pasteboard.hasImages, let image = pasteboard.image, let png = image.pngData() {
            return CaptureIntentRequest(files: [(data: png, filename: "Clipboard \(CaptureNaming.timestampName()).png")])
        }
        if pasteboard.hasURLs, let url = pasteboard.url {
            return CaptureIntentRequest(link: url.absoluteString)
        }
        if pasteboard.hasStrings, let string = pasteboard.string,
           string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            if (try? WorkspaceLink(title: "", url: string)) != nil {
                return CaptureIntentRequest(link: string.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            return CaptureIntentRequest(text: string)
        }
        return nil
    }
}
