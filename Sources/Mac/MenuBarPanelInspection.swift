#if DEBUG
import AppKit
import SwiftUI

/// `-bwMenuBarPanelInWindow YES` (DEBUG only): the menu bar extra's panel, in an
/// ordinary window.
///
/// The real panel is a MenuBarExtra window, which XCUITest cannot see on this machine
/// and which a window capture cannot reach either. This hosts the exact same view, with
/// the same model, so its content — the live session, resurfaced ideas, the inbox — can
/// be checked by a test and looked at. It does not stand in for the status item itself.
@MainActor
enum MenuBarPanelInspection {
    private static var window: NSWindow?

    static func presentIfRequested(model: AppModel) {
        guard UserDefaults.standard.bool(forKey: "bwMenuBarPanelInWindow"), window == nil else { return }
        let host = NSHostingController(rootView: MenuBarContent().environment(model))
        let panel = NSWindow(contentViewController: host)
        panel.title = "Menu Bar Panel (inspection)"
        panel.styleMask = [.titled, .closable]
        panel.setContentSize(host.view.fittingSize)
        panel.identifier = NSUserInterfaceItemIdentifier("menuBarPanelInspection")
        // Above other apps' windows, as the real panel is. Once the workspace window
        // closes the app is a menu bar utility and another app comes forward; an
        // ordinary window was then buried under it, which the real panel never is.
        panel.level = .floating
        panel.makeKeyAndOrderFront(nil)
        window = panel
    }
}
#endif
