import SwiftUI
import AppKit
import WebKit
import QuickLookUI
import BetterWorkspaceCore

/// Mounted only while expanded. Collapsing tears down web/media/Quick Look work.
struct OverviewReviewPreview: View {
    let controller: OverviewInboxController
    let item: OverviewInboxItem
    let url: URL
    @State private var showSource = false
    @State private var link: URL?
    @State private var children: [WorkspaceInboxReview.ReviewItem] = []
    @State private var folderError: String?
    @State private var loadingFolder = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.tight) {
            FlowLayout(spacing: Theme.Space.tight) {
                Text(controller.selectedIsFolder ? "Folder · decisions apply to the whole folder" : ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file))
                Text("Modified \(item.modified.formatted(date: .abbreviated, time: .shortened))")
                if controller.snoozedCount > 0 { Text("\(controller.snoozedCount) snoozed") }
            }
            .font(.caption).foregroundStyle(.secondary)
            Text(item.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

            if controller.selectedIsFolder {
                folderPreview
            } else if let link = link ?? item.link {
                if let links = controller.document?.links, links.count > 1 {
                    Picker("Link", selection: Binding(get: { self.link ?? link }, set: { self.link = $0 })) {
                        ForEach(links, id: \.self) { Text($0.absoluteString).tag($0) }
                    }
                }
                Link(link.host ?? link.absoluteString, destination: link).font(.caption).lineLimit(2)
                ReviewWebsitePreview(url: link).frame(height: 320)
            } else if let document = controller.document, !document.source.isEmpty {
                ScrollView {
                    if showSource {
                        Text(document.source).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else { MarkdownView(text: document.body) }
                }
                .padding(10).frame(height: 260)
                .background(.background, in: RoundedRectangle(cornerRadius: 6))
            } else {
                ReviewQuickLookPreview(url: url).frame(height: 300)
            }

            if let document = controller.document {
                if let warning = document.warning { Text(warning).font(.caption).foregroundStyle(.orange) }
                if !document.source.isEmpty {
                    DisclosureGroup("Notes & details") {
                        VStack(alignment: .leading, spacing: 8) {
                            Toggle("Complete source", isOn: $showSource).toggleStyle(.switch).controlSize(.small)
                            if item.link != nil {
                                ScrollView {
                                    if showSource { Text(document.source).font(.system(.caption, design: .monospaced)).textSelection(.enabled) }
                                    else { MarkdownView(text: document.body) }
                                }.frame(maxHeight: 180)
                            }
                            ForEach(Array(document.metadata.enumerated()), id: \.offset) { _, pair in
                                Text("\(pair.0): \(pair.1)").font(.caption).textSelection(.enabled)
                            }
                        }.padding(.top, 6)
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("overview.toReview.preview")
    }

    private var folderPreview: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                if loadingFolder { ProgressView("Reading folder…") }
                else if let folderError { Text(folderError).foregroundStyle(.orange) }
                else if children.isEmpty { Text("No visible children. Hidden contents are included in whole-folder actions.").foregroundStyle(.secondary) }
                ForEach(children.prefix(20)) { child in
                    Label(child.name, systemImage: child.kind == .folder ? "folder" : "doc")
                        .font(.subheadline).textSelection(.enabled)
                }
                if children.count > 20 { Text("\(children.count - 20) more items · Open to browse the folder").font(.caption).foregroundStyle(.secondary) }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10).frame(maxHeight: 260)
        .task { @MainActor in
            loadingFolder = true
            defer { loadingFolder = false }
            do { children = try await controller.previewChildren() }
            catch is CancellationError {}
            catch { folderError = error.localizedDescription }
        }
    }
}

private struct ReviewWebsitePreview: NSViewRepresentable {
    let url: URL
    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        return view
    }
    func updateNSView(_ view: WKWebView, context: Context) {
        guard context.coordinator.loaded != url else { return }
        context.coordinator.loaded = url
        view.stopLoading()
        view.load(URLRequest(url: url))
    }
    static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) {
        view.stopLoading(); view.loadHTMLString("", baseURL: nil)
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator: NSObject, WKNavigationDelegate {
        var loaded: URL?
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = action.request.url, ["http", "https", "about"].contains(url.scheme?.lowercased() ?? "") else {
                decisionHandler(.cancel); return
            }
            if action.targetFrame == nil { webView.load(action.request); decisionHandler(.cancel) }
            else { decisionHandler(.allow) }
        }
    }
}

private struct ReviewQuickLookPreview: NSViewRepresentable {
    let url: URL
    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .normal)!
        view.shouldCloseWithWindow = false; view.autostarts = false
        return view
    }
    func updateNSView(_ view: QLPreviewView, context: Context) { view.previewItem = url as NSURL }
    static func dismantleNSView(_ view: QLPreviewView, coordinator: ()) { view.close() }
}
