import Foundation
import AppKit
import UserNotifications
import BetterWorkspaceCore

/// Manages the Local AI Agent Completion Monitor as a per-user launchd agent.
///
/// The monitor is its own project (`~/Workspace/Projects/Local AI Agent Completion Monitor`,
/// Python, standard library only). This app owns its lifecycle and presentation:
/// - when enabled, installs the agent `com.zacharysturman.BetterWorkspace.AgentMonitor`
///   (`AgentMonitorAgent`): launchd starts it at login, keeps it running whether or not
///   this app is open, and restarts it after a crash; disabling removes it;
/// - passes the person's Settings as arguments, and this app's executable so the monitor
///   changes tasks only through `--agent-monitor apply` (`AgentMonitorBridge`);
/// - reads the monitor's `status.json` for Settings, and posts the notifications it
///   leaves in `outbox/` so a click opens this app at the project. When this app is not
///   running, the monitor opens it in the menu bar (no window) to deliver them.
///
/// Only the copy in /Applications manages the agent, so a development build never points
/// the login-time monitor at itself (the same rule as `LoginItem`).
@MainActor @Observable
final class AgentMonitorSupervisor {
    static let shared = AgentMonitorSupervisor()

    static let enabledKey = "agentMonitorEnabled"
    static let modeKey = "agentMonitorMode"            // "apply" | "preview"
    static let maxNewTasksKey = "agentMonitorMaxNewTasks"
    static let rootKey = "agentMonitorRoot"
    static let defaultMaxNewTasks = 3

    nonisolated static var defaultRoot: URL {
        WorkspaceLocation.homeDirectory.appendingPathComponent("Workspace/Projects/Local AI Agent Completion Monitor")
    }
    nonisolated static var stateDirectory: URL {
        WorkspaceLocation.homeDirectory.appendingPathComponent("Library/Application Support/LocalAIAgentCompletionMonitor")
    }

    private(set) var status: AgentMonitorStatus?
    /// launchd has the agent loaded with a live process.
    private(set) var isRunning = false
    private(set) var problem: String?
    private(set) var busy = false
    /// nil until known; false when macOS will not show this app's notifications.
    private(set) var notificationsAllowed: Bool?

    private var timer: Timer?
    private var started = false
    private weak var model: AppModel?
    private var lastAgentCheck = Date.distantPast

    private var defaults: UserDefaults { TestIsolation.defaults }
    var isEnabled: Bool { defaults.bool(forKey: Self.enabledKey) }
    var mode: String { defaults.string(forKey: Self.modeKey) == "preview" ? "preview" : "apply" }
    var maxNewTasks: Int {
        let value = defaults.object(forKey: Self.maxNewTasksKey) as? Int ?? Self.defaultMaxNewTasks
        return min(max(value, 0), 10)
    }
    var root: URL {
        if let custom = defaults.string(forKey: Self.rootKey), !custom.isEmpty { return URL(fileURLWithPath: (custom as NSString).expandingTildeInPath) }
        return Self.defaultRoot
    }
    var canManage: Bool { LoginItem.canManage() }
    var statusURL: URL { statusOverride ?? Self.stateDirectory.appendingPathComponent("status.json") }
    private var statusOverride: URL?
    var outbox: URL { Self.stateDirectory.appendingPathComponent("outbox", isDirectory: true) }

    /// Seconds since the monitor last wrote its status; nil when it never has.
    var heartbeatAge: TimeInterval? { status.map { Date().timeIntervalSince1970 - $0.heartbeat } }

    private func agent() -> AgentMonitorAgent {
        AgentMonitorAgent(root: root, mode: mode, maxNewTasks: maxNewTasks,
                          workspace: model?.workspace.root ?? WorkspaceLocation.resolved.root,
                          executable: Bundle.main.executableURL)
    }

    // MARK: Lifecycle

    func start(model: AppModel) {
        guard !started else { return }
        started = true
        self.model = model
        // An isolated test run must never start the real monitor or read its state.
        guard !TestIsolation.isActive else {
            #if DEBUG
            // `-bwAgentMonitorStatus <status.json>`: show a canned status, no process.
            if let fixture = TestIsolation.launchArgument("bwAgentMonitorStatus") {
                statusOverride = URL(fileURLWithPath: fixture)
                isRunning = isEnabled
                poll()
            }
            #endif
            return
        }
        AgentMonitorNotifications.shared.install()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in
            MainActor.assumeIsolated { AgentMonitorSupervisor.shared.poll() }
        }
        reconcileAgent()
        poll()
    }

    func setEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: Self.enabledKey)
        guard !TestIsolation.isActive else { return }
        if enabled { AgentMonitorNotifications.shared.requestAuthorization() }
        reconcileAgent(force: true)
    }

    /// Settings changed: the monitor reads them only at launch.
    func restart() {
        guard isEnabled, !TestIsolation.isActive else { return }
        reconcileAgent(force: true)
    }

    /// Makes launchd match the setting: installed with the current arguments when enabled,
    /// removed when disabled. Runs launchctl off the main thread.
    func reconcileAgent(force: Bool = false) {
        guard canManage else {
            problem = isEnabled ? "The copy of Better Workspace in /Applications runs the monitor." : nil
            return
        }
        let wanted = isEnabled
        let agent = agent()
        busy = true
        Task.detached(priority: .utility) {
            var failure: String?
            do {
                if wanted {
                    if force || !agent.isInstalledAsDefined() { try agent.install() }
                } else if agent.isInstalled() {
                    agent.uninstall()
                }
            } catch {
                failure = error.localizedDescription
            }
            let running = agent.loadedPID() != nil
            await MainActor.run {
                let me = AgentMonitorSupervisor.shared
                me.busy = false
                me.isRunning = running
                me.problem = failure
                me.lastAgentCheck = Date()
            }
        }
    }

    func shutdown() {
        // The monitor keeps running without this app; only the status timer stops.
        timer?.invalidate()
    }

    // MARK: Status and notifications

    func poll() {
        if let data = try? Data(contentsOf: statusURL),
           let decoded = try? JSONDecoder().decode(AgentMonitorStatus.self, from: data) {
            status = decoded
        }
        guard statusOverride == nil else { return }
        if isEnabled { deliverOutbox() }
        if !busy, Date().timeIntervalSince(lastAgentCheck) > 30 {
            lastAgentCheck = Date()
            UNUserNotificationCenter.current().getNotificationSettings { settings in
                let allowed: Bool? = switch settings.authorizationStatus {
                case .authorized, .provisional: true
                case .denied: false
                default: nil
                }
                Task { @MainActor in AgentMonitorSupervisor.shared.notificationsAllowed = allowed }
            }
            let agent = agent()
            Task.detached(priority: .utility) {
                let running = agent.loadedPID() != nil
                await MainActor.run { AgentMonitorSupervisor.shared.isRunning = running }
            }
        }
    }

    private func deliverOutbox() {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: outbox.path) else { return }
        for name in names.sorted() where name.hasSuffix(".json") && !name.hasPrefix(".") {
            let url = outbox.appendingPathComponent(name)
            defer { try? FileManager.default.removeItem(at: url) }
            guard let data = try? Data(contentsOf: url),
                  let payload = try? JSONDecoder().decode(AgentMonitorNotification.self, from: data) else { continue }
            AgentMonitorNotifications.shared.post(payload)
        }
    }

    // MARK: Logs

    var todaysLog: URL? {
        if let path = status?.logPath { return URL(fileURLWithPath: path) }
        let day = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withFullDate])
        return model?.workspace.root.appendingPathComponent("Logs/\(day)/agent-completion-monitor.log")
    }
}

/// `status.json`, as written by the monitor (agent_monitor/service.py → write_status).
/// Every field is optional so an older or newer monitor never breaks Settings.
struct AgentMonitorStatus: Decodable {
    struct LMStudio: Decodable { var available: Bool?; var model: String?; var error: String?; var ownedInstance: String? }
    struct Agent: Decodable, Identifiable {
        var name: String; var displayName: String?; var available: Bool?; var sessionsLastDay: Int?; var lastActivity: String?
        var id: String { name }
    }
    struct Next: Decodable { var id: String?; var title: String?; var ownerLabel: String? }
    struct Activity: Decodable, Identifiable {
        var at: String?; var agent: String?; var project: String?; var title: String?; var job: String?
        var new: Int?; var completed: Int?; var progressed: Int?; var open: Int?; var high: Int?; var deferred: Int?
        var reason: String?; var state: String?; var next: Next?
        var id: String { (job ?? "") + (at ?? "") }
    }
    struct Problem: Decodable, Identifiable {
        var at: String?; var `where`: String?; var message: String?
        var id: String { (at ?? "") + (message ?? "") }
    }
    var version: String?
    var pid: Int?
    var heartbeat: Double
    var mode: String?
    var phase: String?
    var waiting: String?
    var maxNewTasks: Int?
    var lmstudio: LMStudio?
    var bridgeAvailable: Bool?
    var agents: [Agent]?
    var pendingJobs: Int?
    var recent: [Activity]?
    var errors: [Problem]?
    var deferredCount: Int?
    var logPath: String?
    var historyDir: String?
}

/// One notification the monitor composed (agent_monitor/notify.py).
struct AgentMonitorNotification: Decodable {
    var id: String
    var title: String
    var subtitle: String
    var body: String
    var projectPath: String
    var taskID: String?
}

/// Posts the monitor's notifications and routes clicks into the app.
///
/// macOS shows a title, subtitle and about two lines, plus action buttons on hover or
/// under Options. The whole notification opens the project's Tasks; **Open Next Task**
/// (offered only when there is one) opens that task's editor. Nothing else is clickable.
final class AgentMonitorNotifications: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    static let shared = AgentMonitorNotifications()
    static let category = "agent-monitor"
    static let categoryWithTask = "agent-monitor.task"
    static let openTaskAction = "open-next-task"

    private var installed = false

    func install() {
        guard !installed else { return }
        installed = true
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let open = UNNotificationAction(identifier: Self.openTaskAction, title: "Open Next Task", options: [.foreground])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Self.category, actions: [], intentIdentifiers: []),
            UNNotificationCategory(identifier: Self.categoryWithTask, actions: [open], intentIdentifiers: []),
        ])
    }

    func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func post(_ payload: AgentMonitorNotification) {
        let content = UNMutableNotificationContent()
        content.title = payload.title
        content.subtitle = payload.subtitle
        content.body = payload.body
        content.threadIdentifier = "agent-monitor." + payload.projectPath
        content.categoryIdentifier = payload.taskID == nil ? Self.category : Self.categoryWithTask
        var info: [String: String] = ["projectPath": payload.projectPath]
        if let task = payload.taskID { info["taskID"] = task }
        content.userInfo = info
        let request = UNNotificationRequest(identifier: payload.id, content: content, trigger: nil)
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            if settings.authorizationStatus == .notDetermined {
                center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
                    if granted { center.add(request) { Self.record(payload, status: "authorized", error: $0) } }
                    else { Self.record(payload, status: "denied", error: nil) }
                }
            } else {
                let status = settings.authorizationStatus == .denied ? "denied" : "authorized"
                center.add(request) { Self.record(payload, status: status, error: $0) }
            }
        }
    }

    /// One line per notification in the monitor's state folder, so a missing banner can
    /// be told apart from one macOS was not allowed to show.
    private static func record(_ payload: AgentMonitorNotification, status: String, error: Error?) {
        let url = AgentMonitorSupervisor.stateDirectory.appendingPathComponent("delivered.log")
        let stamp = ISO8601DateFormatter().string(from: Date())
        let line = "\(stamp) \(payload.id) permission=\(status)\(error.map { " error=\($0.localizedDescription)" } ?? "") "
            + "\(payload.title) | \(payload.subtitle) | \(payload.body)\n"
        if let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size > 500_000 { try? FileManager.default.removeItem(at: url) }
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile(); handle.write(Data(line.utf8)); try? handle.close()
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        let project = info["projectPath"] as? String
        let task = response.actionIdentifier == Self.openTaskAction ? info["taskID"] as? String : nil
        let dismissed = response.actionIdentifier == UNNotificationDismissActionIdentifier
        completionHandler()
        guard let project, !dismissed else { return }
        Task { @MainActor in
            guard let model = AppDelegate.current?.model else { return }
            await model.openProjectTasks(projectPath: project, taskID: task)
        }
    }
}

/// The launchd definition for the monitor, in the shape `BackgroundServiceAgent` uses.
struct AgentMonitorAgent: Sendable {
    static let label = "com.zacharysturman.BetterWorkspace.AgentMonitor"

    let root: URL
    let mode: String
    let maxNewTasks: Int
    let workspace: URL
    let executable: URL?
    var home: URL = WorkspaceLocation.homeDirectory

    var plistURL: URL { home.appendingPathComponent("Library/LaunchAgents/\(Self.label).plist") }
    var stateDirectory: URL { home.appendingPathComponent("Library/Application Support/LocalAIAgentCompletionMonitor") }

    /// Better Workspace's bundled runtime when its background service is installed,
    /// else the Command Line Tools' Python (3.9+; the monitor uses only the standard library).
    var python: URL {
        let candidates = [BackgroundServiceLayout.standard(userHome: home).home.appendingPathComponent("runtime/bin/python3"),
                          URL(fileURLWithPath: "/usr/bin/python3"), URL(fileURLWithPath: "/opt/homebrew/bin/python3")]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) } ?? candidates[1]
    }

    /// Starts at login, restarts after a crash (not after a clean exit, such as finding
    /// another copy already running) at most every 30 s, and runs at background priority.
    func definition() -> [String: Any] {
        [
            "Label": Self.label,
            "AssociatedBundleIdentifiers": [BackgroundServiceAgent.appBundleIdentifier],
            "ProgramArguments": [python.path, "-B", root.appendingPathComponent("monitor.py").path, "run",
                                 "--mode", mode, "--max-new-tasks", String(maxNewTasks), "--workspace", workspace.path],
            "WorkingDirectory": root.path,
            "EnvironmentVariables": ["BETTER_WORKSPACE_EXECUTABLE": executable?.path ?? "", "PYTHONUNBUFFERED": "1"],
            "RunAtLoad": true,
            "KeepAlive": ["SuccessfulExit": false],
            "ProcessType": "Background",
            "LowPriorityIO": true,
            "Nice": 5,
            "ThrottleInterval": 30,
            "StandardOutPath": stateDirectory.appendingPathComponent("monitor.stdout.log").path,
            "StandardErrorPath": stateDirectory.appendingPathComponent("monitor.stderr.log").path,
        ]
    }

    func isInstalled() -> Bool { FileManager.default.fileExists(atPath: plistURL.path) }

    func isInstalledAsDefined() -> Bool {
        guard let current = NSDictionary(contentsOf: plistURL),
              let data = try? PropertyListSerialization.data(fromPropertyList: definition(), format: .xml, options: 0),
              let wanted = try? PropertyListSerialization.propertyList(from: data, format: nil) as? NSDictionary else { return false }
        return current == wanted && loadedPID() != nil
    }

    func install() throws {
        guard FileManager.default.fileExists(atPath: root.appendingPathComponent("monitor.py").path) else {
            throw BackgroundServiceAgent.Failure.programMissing(root.appendingPathComponent("monitor.py"))
        }
        try FileManager.default.createDirectory(at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
        // Keep the log bounded across restarts.
        for name in ["monitor.stdout.log", "monitor.stderr.log"] {
            let url = stateDirectory.appendingPathComponent(name)
            if let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size > 1_000_000 {
                try? FileManager.default.removeItem(at: url)
            }
        }
        let data = try PropertyListSerialization.data(fromPropertyList: definition(), format: .xml, options: 0)
        // bootout returns before the monitor has exited; bootstrap refuses a loaded job.
        _ = BackgroundServiceAgent.launchctl(["bootout", "\(BackgroundServiceAgent.domain)/\(Self.label)"])
        BackgroundServiceAgent.waitUntilUnloaded(Self.label)
        try data.write(to: plistURL, options: .atomic)
        try BackgroundServiceAgent.bootstrap(plistURL)
    }

    func uninstall() {
        _ = BackgroundServiceAgent.launchctl(["bootout", "\(BackgroundServiceAgent.domain)/\(Self.label)"])
        BackgroundServiceAgent.waitUntilUnloaded(Self.label)
        try? FileManager.default.removeItem(at: plistURL)
    }

    func loadedPID() -> Int? {
        let printed = BackgroundServiceAgent.launchctl(["print", "\(BackgroundServiceAgent.domain)/\(Self.label)"])
        return printed.status == 0 ? BackgroundServiceAgent.pid(in: printed.output) : nil
    }
}
