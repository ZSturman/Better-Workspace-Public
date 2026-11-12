import SwiftUI
import AppKit
import WebKit
import Observation
import BetterWorkspaceCore

@MainActor @Observable
final class WorkspaceWebSession {
    var currentURL: URL?
    var title = ""
    var loading = false
    var canGoBack = false
    var canGoForward = false
    var error: String?
    var requestedURL: URL?
    @ObservationIgnored weak var view: WKWebView?
    func back() { view?.goBack() }
    func forward() { view?.goForward() }
    func reload() {
        if view?.reload() == nil, let requestedURL { view?.load(URLRequest(url: requestedURL)) }
    }
}

/// Shared by root webpages and the existing Inbox Review preview. Each mount owns
/// an ephemeral web session; no script bridges, local-file access or download writes.
struct WorkspaceWebsiteView: NSViewRepresentable {
    let url: URL
    var session: WorkspaceWebSession? = nil
    func makeCoordinator() -> Coordinator { Coordinator(session: session) }
    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator; view.uiDelegate = context.coordinator
        view.allowsBackForwardNavigationGestures = true
        session?.view = view
        return view
    }
    func updateNSView(_ view: WKWebView, context: Context) {
        guard context.coordinator.loaded != url else { return }
        context.coordinator.loaded = url
        session?.requestedURL = url
        view.stopLoading()
        guard WorkspaceWebPolicy.webpage(url.absoluteString) != nil else {
            session?.error = "This address cannot be displayed. Use an HTTP or HTTPS webpage."
            return
        }
        view.load(URLRequest(url: url))
    }
    static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) {
        view.navigationDelegate = nil; view.uiDelegate = nil
        view.stopLoading(); view.loadHTMLString("", baseURL: nil)
        coordinator.session?.view = nil
    }
    @MainActor final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        var loaded: URL?
        let session: WorkspaceWebSession?
        init(session: WorkspaceWebSession?) { self.session = session }
        private func update(_ view: WKWebView) {
            session?.currentURL = view.url
            session?.title = view.title ?? ""
            session?.canGoBack = view.canGoBack; session?.canGoForward = view.canGoForward
        }
        func webView(_ view: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            session?.loading = true; session?.error = nil; update(view)
        }
        func webView(_ view: WKWebView, didCommit navigation: WKNavigation!) { update(view) }
        func webView(_ view: WKWebView, didFinish navigation: WKNavigation!) {
            session?.loading = false; update(view)
        }
        func webView(_ view: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { failed(view, error) }
        func webView(_ view: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { failed(view, error) }
        private func failed(_ view: WKWebView, _ error: Error) {
            guard (error as NSError).code != NSURLErrorCancelled else { return }
            session?.loading = false; session?.error = error.localizedDescription; update(view)
        }
        func webViewWebContentProcessDidTerminate(_ view: WKWebView) {
            session?.loading = false; session?.error = "The webpage stopped responding. Reload to try again."
        }
        func webView(_ view: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = action.request.url, WorkspaceWebPolicy.allowsNavigation(url) else {
                session?.loading = false
                if action.targetFrame?.isMainFrame != false { session?.error = "This link is not a supported webpage. Open the site in your browser for additional actions." }
                decisionHandler(.cancel); return
            }
            if action.shouldPerformDownload {
                session?.loading = false; session?.error = "Open this page in your browser to download files."; decisionHandler(.cancel)
            } else if action.targetFrame == nil {
                view.load(action.request); decisionHandler(.cancel)
            } else { decisionHandler(.allow) }
        }
        func webView(_ view: WKWebView, decidePolicyFor response: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
            guard response.canShowMIMEType else {
                session?.loading = false; session?.error = "Open this page in your browser to download this content."
                decisionHandler(.cancel); return
            }
            if let http = response.response as? HTTPURLResponse, http.statusCode >= 400 {
                session?.error = "The website returned an error (\(http.statusCode)). Reload or open it in your browser."
            }
            decisionHandler(.allow)
        }
        func webView(_ view: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) { completionHandler() }
        func webView(_ view: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) { completionHandler(false) }
        func webView(_ view: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) { completionHandler(nil) }
    }
}

struct WorkspaceWebpageDetail: View {
    let item: WorkspaceRootItem
    @State private var chosen: URL?
    @State private var browser = WorkspaceWebSession()
    private var url: URL? { chosen ?? item.links.first }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button { browser.back() } label: { Image(systemName: "chevron.left") }
                    .disabled(!browser.canGoBack).accessibilityLabel("Back").accessibilityIdentifier("rootWeb.back")
                Button { browser.forward() } label: { Image(systemName: "chevron.right") }
                    .disabled(!browser.canGoForward).accessibilityLabel("Forward").accessibilityIdentifier("rootWeb.forward")
                Button { browser.reload() } label: { Image(systemName: "arrow.clockwise") }
                    .disabled(url == nil).accessibilityLabel("Reload webpage").accessibilityIdentifier("rootWeb.reload")
                Text(browser.currentURL?.host ?? url?.host ?? item.title).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
                if browser.loading { ProgressView().controlSize(.small) }
                Button("Open in Browser") {
                    if let current = browser.currentURL ?? url, WorkspaceWebPolicy.webpage(current.absoluteString) != nil { NSWorkspace.shared.open(current) }
                }.disabled(url == nil).accessibilityIdentifier("rootWeb.external")
            }.padding(10)
            if item.links.count > 1 {
                Picker("Webpage", selection: Binding(get: { url ?? item.links[0] }, set: { chosen = $0 })) {
                    ForEach(item.links, id: \.self) { Text($0.absoluteString).tag($0) }
                }.padding(.horizontal)
            }
            if let warning = item.warning ?? browser.error {
                Text(warning).font(.callout).foregroundStyle(.orange).padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading).accessibilityIdentifier("rootWeb.error")
            }
            Divider()
            if let url { WorkspaceWebsiteView(url: url, session: browser).accessibilityIdentifier("rootWeb.content") }
            else { ContentUnavailableView("Webpage unavailable", systemImage: "globe", description: Text("Check this shortcut's address, then refresh the workspace.")) }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
