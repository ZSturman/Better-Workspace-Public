import SwiftUI
import QuickLookThumbnailing
import Quartz
import AppKit
import BetterWorkspaceCore

/// Shared Quick Look thumbnail cache. Used by the Inspiration gallery, Assets covers
/// and the ingest preview so they all render identically.
@MainActor
final class ThumbnailCache {
    static let shared = ThumbnailCache()
    private var cache: [String: NSImage] = [:]
    private var inFlight: Set<String> = []

    func cached(_ url: URL, size: CGFloat) -> NSImage? { cache[key(url, size)] }

    func thumbnail(for url: URL, size: CGFloat) async -> NSImage? {
        let k = key(url, size)
        if let hit = cache[k] { return hit }
        guard inFlight.contains(k) == false else { return nil }
        inFlight.insert(k)
        defer { inFlight.remove(k) }

        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: CGSize(width: size, height: size),
            scale: scale,
            representationTypes: .thumbnail
        )
        let image: NSImage? = await withCheckedContinuation { continuation in
            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { rep, _ in
                continuation.resume(returning: rep?.nsImage)
            }
        }
        if let image { cache[k] = image }
        return image
    }

    private func key(_ url: URL, _ size: CGFloat) -> String { "\(url.path)#\(Int(size))" }
}

struct ThumbnailImage: View {
    let url: URL
    let kind: FileKind
    var size: CGFloat = 120
    var cornerRadius: CGFloat = Theme.Radius.card
    /// `.fill` crops to a uniform square, which is what a gallery grid wants. `.fit`
    /// shows the whole image — use it anywhere the picture is the content rather than a
    /// tile, or a wide screenshot loses both its edges.
    var contentMode: ContentMode = .fill

    @State private var image: NSImage?

    private var isFitting: Bool { contentMode == .fit }

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(Theme.kindColor(kind).opacity(0.12))
                Image(systemName: kind.symbolName)
                    .font(.system(size: size * 0.24, weight: .light))
                    .foregroundStyle(Theme.kindColor(kind).opacity(0.75))
            }
        }
        .frame(maxWidth: size, maxHeight: size)
        .frame(width: isFitting ? nil : size, height: isFitting ? nil : size)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        .task(id: url.path) { @MainActor in
            image = await ThumbnailCache.shared.thumbnail(for: url, size: size)
        }
    }
}

/// Native Quick Look panel, driven from a SwiftUI action.
@MainActor
final class QuickLookController: NSObject, @preconcurrency QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    static let shared = QuickLookController()
    private var urls: [URL] = []

    func preview(_ urls: [URL]) {
        guard urls.isEmpty == false else { return }
        self.urls = urls
        guard let panel = QLPreviewPanel.shared() else { return }
        panel.dataSource = self
        panel.delegate = self
        panel.reloadData()
        if panel.isVisible { panel.orderOut(nil) } else { panel.makeKeyAndOrderFront(nil) }
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { urls.count }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        urls[index] as NSURL
    }
}
