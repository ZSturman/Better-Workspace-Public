import SwiftUI
import AppKit
import BetterWorkspaceCore

/// Native sandboxed macOS destination of the same Store target as iPhone and iPad.
/// No launchd installer, Python, provider runner or unrestricted folder discovery.
@main
struct BetterWorkspaceStoreApp: App {
    @NSApplicationDelegateAdaptor(StoreWorkspaceApplicationDelegate.self) private var applicationDelegate
    @AppStorage("workspaceWelcomeCompleted") private var welcomed = false
    @State private var showsWelcome = false
    @State private var showsSample = false

    private var cloudAcceptance: Bool {
        #if DEBUG
        ProcessInfo.processInfo.environment["BW_RUN_NOTEBOOK_CLOUD_ACCEPTANCE"] == "1"
        #else
        false
        #endif
    }

    private var initialSize: CGSize {
        #if DEBUG
        let width = Double(TestIsolation.launchArgument("bwWindowWidth") ?? "") ?? 860
        let height = Double(TestIsolation.launchArgument("bwWindowHeight") ?? "") ?? 680
        return CGSize(width: max(620, min(width, 1600)), height: max(520, min(height, 1200)))
        #else
        return CGSize(width: 860, height: 680)
        #endif
    }

    var body: some Scene {
        workspaceScene
        Settings { WorkspacePrivacyView().frame(width: 580, height: 480) }
    }

    private var workspaceScene: some Scene {
        WindowGroup("My Workspace", id: "personal-workspace") {
            if let session = NotebookReleaseAcceptance.sessionID {
                NotebookReleaseAcceptanceView(sessionID: session)
            } else if NotebookReleaseAcceptance.previewSessionID != nil {
                PersonalWorkspaceView(sample: NotebookReleaseAcceptance.isSamplePreview, isolated: true)
            } else {
                PersonalWorkspaceView(sample: cloudAcceptance)
                    .frame(minWidth: 620, minHeight: 450)
                    .task { if !welcomed && !cloudAcceptance { showsWelcome = true } }
                    .sheet(isPresented: $showsWelcome) {
                        WorkspaceWelcomeView(platform: .storeMac, startPersonal: finishWelcome,
                            connect: nil, exploreSample: { finishWelcome(); showsSample = true })
                    }
                    .sheet(isPresented: $showsSample) { PersonalWorkspaceView(sample: true) }
                    .toolbar {
                        ToolbarItem(placement: .automatic) {
                            Button("Welcome", systemImage: "sparkles") { showsWelcome = true }
                        }
                    }
            }
        }
        .defaultSize(width: initialSize.width, height: initialSize.height)
    }

    private func finishWelcome() { welcomed = true; showsWelcome = false }
}

/// Closing the last development window can leave SwiftUI with an empty restored
/// window set. Use this app's normal New Window command when launch/reopen has no
/// visible main window. No keyboard events or other applications are involved.
@MainActor
final class StoreWorkspaceApplicationDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        DispatchQueue.main.async {
            self.ensureWorkspaceWindow()
            DispatchQueue.main.async { self.sizeVerificationWindow() }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { ensureWorkspaceWindow(); return false }
        return true
    }

    private func ensureWorkspaceWindow() {
        guard !NSApp.windows.contains(where: { $0.isVisible && $0.canBecomeMain }) else { return }
        for menu in NSApp.mainMenu?.items.compactMap(\.submenu) ?? [] {
            menu.update()
            if let index = menu.items.firstIndex(where: {
                $0.keyEquivalent == "n" && $0.keyEquivalentModifierMask.intersection([.command, .shift, .option, .control]) == .command && $0.isEnabled
            }) {
                menu.performActionForItem(at: index)
                return
            }
        }
    }

    private func sizeVerificationWindow() {
        guard NotebookReleaseAcceptance.previewSessionID != nil,
              let window = NSApp.windows.first(where: { $0.canBecomeMain }) else { return }
        let width = Double(TestIsolation.launchArgument("bwWindowWidth") ?? "") ?? 820
        let height = Double(TestIsolation.launchArgument("bwWindowHeight") ?? "") ?? 600
        let frame = NSRect(origin: window.frame.origin, size: NSSize(width: max(620, min(width, 1600)), height: max(520, min(height, 1200))))
        window.setFrame(window.constrainFrameRect(frame, to: window.screen), display: true)
    }
}
