import SwiftUI
import AppKit
import ServiceManagement
import TipKit
import BetterWorkspaceCore

@main
struct BetterWorkspaceApp: App {
    /// The delegate owns the model so it can start at launch. The main window is
    /// optional — a login launch never opens it — and the menu bar Ingest and the
    /// hotkey panel need a running model either way.
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    private var model: AppModel { delegate.model }

    init() {
        // `--migrate …` runs a migration headlessly and exits before any window exists.
        ProjectAuditCommand.runIfRequested()
        ProjectMediaCommand.runIfRequested()
        NotionGraphCommand.runIfRequested()
        MigrationCommand.runIfRequested()
        AppInstance.claimOrExit()
        if (TestIsolation.defaults.string(forKey: "projectZenAIEndpoint") ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            TestIsolation.defaults.set(LMStudioPreset.endpoint, forKey: "projectZenAIEndpoint")
        }
    }

    var body: some Scene {
        WindowGroup("Better Workspace", id: "workspace") {
            ContentView()
                .environment(model)
                // A login launch is menu bar only: the window SwiftUI opens at launch
                // hides itself before it is shown (`LaunchWindowSuppressor`).
                .background(LaunchWindowSuppressor())
                .frame(minWidth: 820, minHeight: 468)
                .onOpenURL { url in Task { @MainActor in await model.openDeepLink(url) } }
                .task {
                    delegate.start(model: model)
                }
        }
        .windowToolbarStyle(.unified)
        .defaultSize(width: 1240, height: 820)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Quick Capture…") { QuickCaptureController.shared.show() }
                    .keyboardShortcut(.space, modifiers: [.command, .option])
                Button("Import to Inbox…") { importToInbox() }
                    .keyboardShortcut("i", modifiers: [.command, .shift])
                Divider()
                Button("Reveal Inbox Folder in Finder") {
                    model.revealInFinder(model.ingest.location.inbox)
                }
                Button("Reveal Workspace in Finder") {
                    model.revealInFinder(model.workspace.root)
                }
            }
            CommandMenu("Go") {
                Button("Ingest Inbox") { model.selection = .ingest }
                    .keyboardShortcut("0", modifiers: [.command, .shift])
                Divider()
                // The first nine areas as the sidebar shows them, so the shortcuts follow
                // the folders that actually exist rather than a list compiled in.
                ForEach(Array(model.folders.filter { $0.settings.hidden == false }.prefix(9).enumerated()),
                        id: \.element.id) { index, folder in
                    Button(folder.name) { model.selection = .folder(folder.name) }
                        .keyboardShortcut(
                            KeyEquivalent(Character("\(index + 1)")),
                            modifiers: [.command, .shift]
                        )
                }
            }
        }

        // Keep ingest inserted independently of window visibility or app activation.
        MenuBarExtra("Better Workspace Ingest", systemImage: "tray.and.arrow.down", isInserted: .constant(true)) {
            MenuBarContent()
                .environment(model)
        }
        .menuBarExtraStyle(.window)

        Window("My Workspace", id: "personal-workspace") {
            PersonalWorkspaceView().frame(minWidth: 620, minHeight: 450)
        }.defaultSize(width: 860, height: 680)

        Settings {
            SettingsView()
                .environment(model)
        }
    }

    private func importToInbox() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Add to Inbox"
        if panel.runModal() == .OK { model.importURLs(panel.urls, source: .desktopImport) }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// For App Intents, which run in this process but outside any view.
    private(set) static weak var current: AppDelegate?
    lazy var model = AppModel()
    private var started = false

    /// Starts once, at launch, whether or not a window ever opens. The window's own
    /// call is a no-op after this.
    func start(model: AppModel) {
        guard started == false else { return }
        started = true
        model.start()
        QuickCaptureController.shared.configure(model: model)
    }

    override init() {
        super.init()
        Self.current = self
        // Single-window app with no document state worth restoring. Without this, an
        // abnormal quit leaves a modal "reopen windows?" prompt that blocks the window
        // from ever appearing — the app looks hung and UI automation cannot proceed.
        // Registering the default is the supported way to opt out; deleting the saved
        // state folder from `applicationWillFinishLaunching` instead left AppKit mid
        // restoration and it came back with no windows at all.
        UserDefaults.standard.register(defaults: ["ApplePersistenceIgnoreState": true])

        // SwiftUI aborts on an uncaught AppKit exception, and the crash report keeps the
        // backtrace but drops the reason — which makes layout bugs very hard to chase.
        NSSetUncaughtExceptionHandler { exception in
            let name = exception.name.rawValue
            let reason = exception.reason ?? "no reason"
            let frames = exception.callStackSymbols.prefix(25).joined(separator: "\n")
            FileHandle.standardError.write(Data("\nUNCAUGHT \(name): \(reason)\n\(frames)\n".utf8))
        }
    }

    /// Lets a launch argument pick the window size: `-bwWindowWidth 900 -bwWindowHeight 600`.
    ///
    /// Dragging the resize corner through the accessibility API does not actually resize
    /// a SwiftUI window here, so this is how the layout gets checked at sizes other than
    /// the default. Harmless in normal use, where the keys are absent.
    /// Contextual tips, shown once each when they become relevant. An isolated test run
    /// keeps its own tip store and shows none unless it asks with `-bwShowTips`.
    private func configureTips() {
        do {
            // Never the real app's tip store: an isolated run shares its bundle id.
            if let sandbox = TestIsolation.sandbox {
                if TestIsolation.launchArgument("bwShowTips") == nil { Tips.hideAllTipsForTesting() }
                try Tips.configure([.displayFrequency(.immediate),
                                    .datastoreLocation(.url(sandbox.appendingPathComponent("Tips", isDirectory: true)))])
                return
            }
            try Tips.configure([.displayFrequency(.immediate)])
        } catch {
            #if DEBUG
            print("TipKit setup failed: \(error.localizedDescription)")
            #endif
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Read while the launch event is still current.
        let launchedAtLogin = LoginItem.wasLaunchedAtLogin()
        configureTips()
        start(model: model)
        LoginItem.registerByDefaultIfNeeded()
        LoginItem.claimForInstalledCopyIfNeeded()
        // New Capture (Shortcuts, Spotlight, the widget) opens the quick-capture panel.
        NotificationCenter.default.addObserver(forName: CaptureLaunchRouter.notification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                guard let request = CaptureLaunchRouter.shared.take() else { return }
                QuickCaptureController.shared.show(asIdea: request.asIdea)
            }
        }
        // A control or shortcut that launched the app may have asked before anything
        // was listening; the router keeps that request until it is read.
        if let request = CaptureLaunchRouter.shared.take() {
            DispatchQueue.main.async { QuickCaptureController.shared.show(asIdea: request.asIdea) }
        }
        observeMainWindows()
        if !TestIsolation.isActive {
            DistributedNotificationCenter.default().addObserver(forName: AppInstance.reopenNotification,
                object: String(ProcessInfo.processInfo.processIdentifier), queue: .main) { _ in
                MainActor.assumeIsolated { Self.reopenWorkspace() }
            }
        }
        #if DEBUG
        if let spec = IntentTestHarness.requestedSpec {
            let model = model
            Task { @MainActor in
                // As a Shortcuts call into the running app finds it: Inbox located.
                for _ in 0..<200 where model.ingestLocationResolved == false {
                    try? await Task.sleep(for: .milliseconds(100))
                }
                let message = await IntentTestHarness.run(spec)
                model.statusMessage = message
                print("INTENT RESULT -> \(message)")
            }
        }
        #endif
        if launchedAtLogin {
            // Menu bar only: no Dock icon, and no main window — whether SwiftUI made it
            // already (closed here) or makes it later (it hides itself on attach).
            Self.suppressLaunchWindow = true
            NSApp.setActivationPolicy(.accessory)
            Self.closeMainWindows()
        }
        let defaults = UserDefaults.standard
        let width = defaults.integer(forKey: "bwWindowWidth")
        let height = defaults.integer(forKey: "bwWindowHeight")
        #if DEBUG
        openSettingsIfRequested()
        openURLIfRequested()
        observeTestReopen()
        #endif
        guard width > 0, height > 0 else { return }
        DispatchQueue.main.async {
            guard let window = NSApp.windows.first(where: { $0.canBecomeMain }) else { return }
            var frame = window.frame
            frame.size = NSSize(width: CGFloat(width), height: CGFloat(height))
            // Keep test windows on the primary display. A previous automation session
            // can leave the saved origin on a virtual display XCTest cannot capture.
            if let screen = NSScreen.screens.first {
                frame.origin = NSPoint(x: screen.visibleFrame.midX - frame.width / 2,
                                       y: screen.visibleFrame.midY - frame.height / 2)
            }
            window.setFrame(frame, display: true, animate: false)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    // MARK: - Menu bar utility

    /// True from a login launch until the person asks for the workspace (reopening the
    /// app, or Open Better Workspace in the menu bar).
    static var suppressLaunchWindow = UserDefaults.standard.bool(forKey: "bwLaunchedAtLogin")

    /// The main window — a `WindowGroup("…", id: "workspace")` window is identified
    /// `workspace-AppWindow-n`.
    static func isMainWorkspaceWindow(_ window: NSWindow) -> Bool {
        window.identifier?.rawValue.hasPrefix("workspace") == true
    }

    static func closeMainWindows() {
        for window in NSApp.windows where isMainWorkspaceWindow(window) { window.close() }
    }

    /// The Dock icon follows the main window. Without a window the app is a menu bar
    /// utility (`.accessory`); opening one makes it an ordinary app again.
    private func observeMainWindows() {
        let center = NotificationCenter.default
        center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { note in
            guard let window = note.object as? NSWindow else { return }
            MainActor.assumeIsolated {
                guard Self.isMainWorkspaceWindow(window), NSApp.activationPolicy() != .regular else { return }
                NSApp.setActivationPolicy(.regular)
            }
        }
        center.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { note in
            guard let closing = note.object as? NSWindow else { return }
            MainActor.assumeIsolated {
                guard Self.isMainWorkspaceWindow(closing) else { return }
                DispatchQueue.main.async {
                    let anyOpen = NSApp.windows.contains { $0 !== closing && $0.isVisible && Self.isMainWorkspaceWindow($0) }
                    if anyOpen == false { NSApp.setActivationPolicy(.accessory) }
                }
            }
        }
    }

    /// Opening the app again (Finder, Spotlight, a Dock click) while it runs in the menu
    /// bar brings the workspace back; SwiftUI opens a new window when none is visible.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        Self.suppressLaunchWindow = false
        NSApp.setActivationPolicy(.regular)
        return true
    }

    static func reopenWorkspace() {
        guard let delegate = NSApp.delegate else { return }
        let visible = NSApp.windows.contains { $0.isVisible && isMainWorkspaceWindow($0) }
        guard delegate.applicationShouldHandleReopen?(NSApp, hasVisibleWindows: visible) ?? true else { return }
        if visible {
            NSApp.windows.first(where: { $0.isVisible && isMainWorkspaceWindow($0) })?.makeKeyAndOrderFront(nil)
        } else if delegate.applicationShouldOpenUntitledFile?(NSApp) ?? true {
            _ = delegate.applicationOpenUntitledFile?(NSApp)
        }
    }

    #if DEBUG
    /// `-bwOpenSettings YES` opens Settings at launch.
    ///
    /// Settings is only reachable by Command-comma or the menu, and this app's test
    /// tooling is refused permission to send keystrokes, so without this the panel
    /// cannot be looked at on this machine at all.
    func openSettingsIfRequested() {
        guard UserDefaults.standard.bool(forKey: "bwOpenSettings") else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            // The selector's name has changed across releases and sending it to the
            // responder chain does not reliably find a target this early, so drive the
            // real menu item instead — whatever it happens to be called.
            guard let appMenu = NSApp.mainMenu?.items.first?.submenu,
                  let index = appMenu.items.firstIndex(where: {
                      $0.title.localizedCaseInsensitiveContains("Settings")
                          || $0.title.localizedCaseInsensitiveContains("Preferences")
                  })
            else { return }
            appMenu.performActionForItem(at: index)
        }
    }
    #endif

    #if DEBUG
    /// `-bwOpenURL <betterworkspace://…>` (isolated tests only): hand a link to this
    /// instance's own handler. `XCUIApplication.open(_:)` launches a second instance to
    /// deliver it, and a test then reads one instance while the link acted in the other.
    func openURLIfRequested() {
        guard TestIsolation.isActive, let value = TestIsolation.launchArgument("bwOpenURL"),
              let url = URL(string: value) else { return }
        Task { @MainActor [model] in await model.openDeepLink(url) }
    }
    #endif

    #if DEBUG
    /// Isolated tests only: a reopen addressed to this instance by its sandbox path.
    ///
    /// A real reopen is an Apple Event that Launch Services routes by bundle identifier.
    /// With the person's installed copy running, a test's reopen reached that app
    /// instead (it raised the real window), and the UI-test runner may not address a
    /// process directly. So this repeats what AppKit does with a delivered reopen, against
    /// `NSApp.delegate` (SwiftUI's own app delegate): ask `applicationShouldHandleReopen`
    /// (ours, forwarded), and if it agrees and no window is visible, open an untitled
    /// window -- which is where SwiftUI opens the workspace window.
    static let testReopenNotification = Notification.Name("com.zacharysturman.BetterWorkspace.test.reopen")

    func observeTestReopen() {
        guard let sandbox = TestIsolation.sandbox?.standardizedFileURL.path else { return }
        DistributedNotificationCenter.default().addObserver(forName: Self.testReopenNotification, object: nil, queue: .main) { note in
            guard let target = note.object as? String,
                  URL(fileURLWithPath: target).standardizedFileURL.path == sandbox else { return }
            MainActor.assumeIsolated {
                guard let delegate = NSApp.delegate else { return }
                let visible = NSApp.windows.contains { $0.isVisible && Self.isMainWorkspaceWindow($0) }
                guard delegate.applicationShouldHandleReopen?(NSApp, hasVisibleWindows: visible) ?? true, visible == false,
                      delegate.applicationShouldOpenUntitledFile?(NSApp) ?? true else { return }
                _ = delegate.applicationOpenUntitledFile?(NSApp)
            }
        }
    }
    #endif

    /// Dropping files onto the Dock icon, or "Open With", routes into the inbox.
    func application(_ application: NSApplication, open urls: [URL]) {
        model.importURLs(urls, source: .desktopDrop)
        model.selection = .ingest
        collapseToSingleWindow()
    }

    /// `WindowGroup` opens a window per URL handed to the app, so dropping three files
    /// on the Dock icon left three extra empty windows behind. This is a single-window
    /// app; keep the first and close the rest.
    private func collapseToSingleWindow() {
        DispatchQueue.main.async {
            let mainWindows = NSApp.windows.filter {
                $0.canBecomeMain && $0.isVisible && $0.className.contains("Panel") == false
            }
            guard mainWindows.count > 1 else { return }
            let keeper = mainWindows.first
            for window in mainWindows.dropFirst() { window.close() }
            keeper?.makeKeyAndOrderFront(nil)
        }
    }
}

/// Hides the main window the moment it is attached, while a login launch is in effect.
/// Closing it from `applicationDidFinishLaunching` alone was not enough: SwiftUI can
/// create the launch window seconds later, and it showed until then.
private struct LaunchWindowSuppressor: NSViewRepresentable {
    final class Probe: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window, AppDelegate.suppressLaunchWindow else { return }
            window.alphaValue = 0
            DispatchQueue.main.async {
                guard AppDelegate.suppressLaunchWindow else { window.alphaValue = 1; return }
                window.close()
                window.alphaValue = 1
            }
        }
    }

    func makeNSView(context: Context) -> Probe { Probe() }
    func updateNSView(_ nsView: Probe, context: Context) {}
}

/// Compact capture surface in the menu bar.
///
/// Usable with the main window closed: the delegate starts the model at launch. Write
/// or paste, optionally pick a folder and tags, and ⌘Return saves. Below it, the last
/// few captures say whether each is still waiting in the Inbox or where it was filed.
struct MenuBarContent: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @State private var showActivity = false
    @State private var openAtLogin = LoginItem.isEnabled
    @State private var loginItemProblem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Quick ingest").font(.system(size: 12, weight: .semibold))
                Spacer()
                Text(model.pendingIngestCount == 0 ? "Inbox clear" : "\(model.pendingIngestCount) to file")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .accessibilityIdentifier("menubar.toFileCount")
            }

            CaptureComposer(compact: true)

            recentCaptures

            if showActivity { ServiceActivityMenuSection() }

            Divider()
            HStack(spacing: 12) {
                Button("Open Better Workspace") { openWorkspace(selecting: nil) }
                    .accessibilityIdentifier("menubar.openWorkspace")
                Button("Process Inbox…") { openWorkspace(selecting: .ingest) }
                Spacer()
                Menu {
                    Toggle("Open at Login", isOn: Binding(get: { openAtLogin }, set: setOpenAtLogin))
                        .disabled(LoginItem.canManage() == false)
                        .help(LoginItem.canManage() ? "" : LoginItem.ManageError.notInstalledCopy.localizedDescription)
                    if LoginItem.needsApproval {
                        Button("Approve in Login Items…") { SMAppService.openSystemSettingsLoginItems() }
                    }
                    Button(showActivity ? "Hide activity" : "Show activity") { showActivity.toggle() }
                    Divider()
                    Button("Quit Better Workspace") { NSApp.terminate(nil) }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .accessibilityLabel("More")
                .accessibilityIdentifier("capture.more")
            }
            .buttonStyle(.borderless)
            .font(.system(size: 11))
            if let loginItemProblem {
                Text(loginItemProblem).font(.caption).foregroundStyle(.orange)
            }
        }
        .padding(14)
        .frame(width: 380)
        .onAppear { openAtLogin = LoginItem.isEnabled }
    }

    /// Waiting items first, then what was filed most recently. Five rows at most: this
    /// is a glance, and the Ingest window has the full lists.
    @ViewBuilder
    private var recentCaptures: some View {
        let waiting = Array(model.ingestItems.prefix(3))
        let filed = Array(model.recentlyFiledIngest.prefix(max(0, 5 - waiting.count)))
        if waiting.isEmpty == false || filed.isEmpty == false {
            VStack(alignment: .leading, spacing: 4) {
                Text("Recent").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                ForEach(waiting) { item in
                    recentRow(title: item.title, status: "Inbox · needs filing", symbol: "tray", tint: .orange) {
                        if let index = model.ingestItems.firstIndex(where: { $0.id == item.id }) { model.ingestCursor = index }
                        openWorkspace(selecting: .ingest)
                    }
                }
                ForEach(filed) { entry in
                    recentRow(title: entry.record.title, status: entry.record.destinationName,
                              symbol: "checkmark.circle.fill", tint: .green) {
                        openWorkspace(selecting: nil)
                        model.openFiledIngest(entry)
                    }
                }
            }
            .accessibilityIdentifier("menubar.recent")
        }
    }

    private func recentRow(title: String, status: String, symbol: String, tint: Color,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(title).lineLimit(1)
                Spacer(minLength: 6)
                Label(status, systemImage: symbol)
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(tint)
                    .lineLimit(1)
            }
            .font(.system(size: 11))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func openWorkspace(selecting selection: SidebarSelection?) {
        AppDelegate.suppressLaunchWindow = false
        if let selection { model.selection = selection }
        NSApp.setActivationPolicy(.regular)
        if NSApp.windows.contains(where: { AppDelegate.isMainWorkspaceWindow($0) && $0.isVisible }) == false {
            openWindow(id: "workspace")
        }
        NSApp.unhide(nil)
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first(where: AppDelegate.isMainWorkspaceWindow)?.makeKeyAndOrderFront(nil)
    }

    private func setOpenAtLogin(_ enabled: Bool) {
        do {
            try LoginItem.setEnabled(enabled)
            loginItemProblem = LoginItem.needsApproval
                ? "Approve Better Workspace in System Settings → General → Login Items." : nil
        } catch {
            loginItemProblem = "Open at Login could not be changed: \(error.localizedDescription)"
        }
        openAtLogin = LoginItem.isEnabled
    }
}

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    // `TestIsolation.defaults`: a test that touches Settings must not rewrite the real app's.
    @AppStorage(WorkspaceLocation.defaultsWorkspaceRootKey, store: TestIsolation.defaults) private var workspaceRoot = ""
    @AppStorage(WorkspaceLocation.defaultsIngestRootKey, store: TestIsolation.defaults) private var ingestRoot = ""
    @AppStorage(MobileCloudPublisher.enabledDefaultsKey, store: TestIsolation.defaults) private var mobileCloudSyncEnabled = false

    var body: some View {
        TabView {
            general
                .tabItem { Label("General", systemImage: "gearshape") }
            imports
                .tabItem { Label("Integrations", systemImage: "network") }
            Form {
                Section {
                    ScoringPreferenceEditor()
                } header: {
                    Text("Scoring")
                } footer: {
                    Text("Which ratings count toward a project’s score, and how much each group weighs.").font(.caption).foregroundStyle(.secondary)
                }
                ProjectZenAISettings()
            }.formStyle(.grouped)
                .tabItem { Label("Projects", systemImage: "folder") }
            services
                .tabItem { Label("Services", systemImage: "bolt.horizontal.circle") }
            WorkspacePrivacyView()
                .tabItem { Label("Privacy", systemImage: "hand.raised") }
        }
        .frame(width: 700, height: 560)
        .padding()
    }

    private var general: some View {
        Form {
            Section("Locations") {
                LabeledContent("Workspace") {
                    HStack {
                        Text(model.workspace.root.path).font(.system(size: 11, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                        Button { model.revealInFinder(model.workspace.root) } label: { Image(systemName: "arrow.right.circle") }
                            .buttonStyle(.borderless).help("Show in Finder")
                    }
                }
                LabeledContent("Ingest inbox") {
                    HStack {
                        Text(model.ingest.location.inbox.path).font(.system(size: 11, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                        Button { model.revealInFinder(model.ingest.location.inbox) } label: { Image(systemName: "arrow.right.circle") }
                            .buttonStyle(.borderless).help("Show in Finder")
                    }
                    .help(model.ingest.location.backingDescription
                          + (model.ingest.location.syncsWithMobile ? ", reachable from iPhone and iPad" : ""))
                }
            }
            Section("Menu bar") {
                OpenAtLoginToggle()
            }
            Section {
                DisclosureGroup("Advanced") {
                    TextField("Workspace root", text: $workspaceRoot, prompt: Text("~/Workspace"))
                    TextField("Ingest inbox", text: $ingestRoot, prompt: Text("Automatic (iCloud Drive)"))
                    LabeledContent("Private database") {
                        Text(model.database.url.path).font(.system(size: 11, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                            .textSelection(.enabled)
                    }
                    Text("Location changes take effect the next time Better Workspace opens.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var imports: some View {
        Form {
            Section("Better Projects") {
                LegacyImportControl()
            }
            Section("Notion") {
                NotionSettingsSection()
            }
        }
        .formStyle(.grouped)
    }

    private var services: some View {
        Form {
            Section("Background service") {
                BackgroundServiceSection()
            }
            Section("iPhone workspace index") {
                Toggle("Sync a workspace index with iPhone", isOn: $mobileCloudSyncEnabled)
                    .onChange(of: mobileCloudSyncEnabled) { _, enabled in
                        if enabled { model.requestMobileCloudSync() }
                    }
                    .help("An optional iCloud copy of the index, so iPhone and iPad can browse and plan. Your files stay the source of truth and everything works offline.")
            }
        }
        .formStyle(.grouped)
    }
}

/// Open at Login, from Settings: what keeps menu bar Ingest available after login.
struct OpenAtLoginToggle: View {
    @State private var enabled = LoginItem.isEnabled
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle("Open at Login", isOn: Binding(get: { enabled }, set: { value in
                do {
                    try LoginItem.setEnabled(value)
                    problem = LoginItem.needsApproval
                        ? "Waiting for approval in System Settings → General → Login Items." : nil
                } catch {
                    problem = error.localizedDescription
                }
                enabled = LoginItem.isEnabled
            }))
            .accessibilityIdentifier("settings.openAtLogin")
            .disabled(LoginItem.canManage() == false)
            .help("Starts quietly in the menu bar after you log in, with no window, so Ingest is always one click away.")
            if LoginItem.canManage() == false {
                Text(LoginItem.ManageError.notInstalledCopy.localizedDescription)
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let problem {
                Text(problem).font(.caption).foregroundStyle(.orange)
                if LoginItem.needsApproval {
                    Button("Open Login Items") { SMAppService.openSystemSettingsLoginItems() }
                }
            }
        }
        .onAppear { enabled = LoginItem.isEnabled }
    }
}

/// Bringing Better Projects' data across, from Settings.
///
/// Deliberately two steps. The first only looks — it reports what it found and changes
/// nothing — because "import my other app's data" is exactly the kind of action a
/// person wants to see the shape of before they agree to it.
struct LegacyImportControl: View {
    @Environment(AppModel.self) private var model
    @State private var preview: AppModel.LegacyImportSummary?
    @State private var result: AppModel.LegacyImportSummary?
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.tight) {
            Text("Project identity, Notion associations and manual ratings are read out of "
                 + "Better Projects' documents and cache into this app's own database. "
                 + "Nothing in your Workspace is written, moved or deleted.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let result {
                Label("Imported \(result.description).", systemImage: "checkmark.circle.fill")
                    .font(.caption).foregroundStyle(.green)
            } else if let preview {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Found \(preview.documents) project documents.").font(.caption)
                    Text("\(preview.notionLinksRecovered) Notion associations and "
                         + "\(preview.ratingsImported) ratings would be imported.")
                        .font(.caption).foregroundStyle(.secondary)
                    if preview.missingDirectories > 0 {
                        Text("\(preview.missingDirectories) name folders that no longer exist and will be skipped.")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    if preview.conflicts > 0 {
                        Text("\(preview.conflicts) disagree with an association already recorded "
                             + "and will be left alone.")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }
            }

            HStack(spacing: Theme.Space.tight) {
                Button("Check What's There") {
                    Task { @MainActor in
                        busy = true
                        result = nil
                        preview = await model.runLegacyImport(apply: false)
                        busy = false
                    }
                }
                Button("Import") {
                    Task { @MainActor in
                        busy = true
                        result = await model.runLegacyImport(apply: true)
                        preview = nil
                        busy = false
                    }
                }
                .disabled(preview == nil)
                if busy { ProgressView().controlSize(.small) }
            }
            .disabled(busy)
        }
    }
}
