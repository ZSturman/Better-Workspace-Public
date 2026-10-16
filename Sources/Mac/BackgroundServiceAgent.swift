import Foundation
import CryptoKit
import Darwin
import BetterWorkspaceCore

/// Installs, starts and inspects Better Workspace's background service.
///
/// The service is a per-user launchd agent, so it starts at login and keeps running —
/// watching the Workspace, closing sessions, drafting the work log, resurfacing ideas —
/// whether or not this app's window is open.
///
/// It ships inside the app (`Contents/Resources/BackgroundService`, from the repo's
/// `BackgroundService/`) and is installed into
/// `~/Library/Application Support/BetterWorkspace/BackgroundService/` with its own
/// bundled offline runtime and configuration (`BackgroundServiceLayout`). It began as Workspace
/// Watcher's daemon and ran from that checkout; installing moves it here once, carrying
/// the old `config.toml`, `rules.toml` and `.env` across, and retires Workspace Watcher's
/// agents into the migration archive. Its data stays in `~/Workspace/Logs/workspace-watcher`.
struct BackgroundServiceAgent {

    static let label = "com.zacharysturman.BetterWorkspace.BackgroundService"
    /// The labels Workspace Watcher installed. Both are retired on install.
    static let legacyDaemonLabel = "com.zacharysturman.workspace-watcher"
    static let legacyMenuBarLabel = "com.zacharysturman.workspace-watcher-menubar"
    /// Development only: run the service straight from a source directory holding its
    /// own `run.sh` and `.venv` (as the Workspace Watcher checkout did) instead of the
    /// installed copy.
    static let serviceRootDefaultsKey = "backgroundServiceRoot"
    static let appBundleIdentifier = "com.zacharysturman.BetterWorkspace"
    /// `tomllib` arrived in 3.11.
    static let minimumPython = (3, 11)

    let layout: BackgroundServiceLayout
    let developmentRoot: URL?
    let home: URL
    let bundled: URL?

    init(defaults: UserDefaults = .standard, home: URL = WorkspaceLocation.homeDirectory,
         bundled: URL? = Bundle.main.resourceURL?.appendingPathComponent("BackgroundService")) {
        self.home = home
        self.layout = .standard(userHome: home)
        self.bundled = bundled
        if let custom = defaults.string(forKey: Self.serviceRootDefaultsKey), custom.isEmpty == false {
            developmentRoot = URL(fileURLWithPath: custom)
        } else {
            developmentRoot = nil
        }
    }

    var launchAgents: URL { home.appendingPathComponent("Library/LaunchAgents") }
    var plistURL: URL { launchAgents.appendingPathComponent("\(Self.label).plist") }
    func legacyPlistURL(_ label: String) -> URL { launchAgents.appendingPathComponent("\(label).plist") }
    /// What launchd runs.
    var program: URL { developmentRoot?.appendingPathComponent("run.sh") ?? layout.launcher }
    var workingDirectory: URL { developmentRoot ?? layout.home }
    /// The service keeps its logs beside its database, as it always has.
    var logDirectory: URL { home.appendingPathComponent("Workspace/Logs/workspace-watcher") }
    var migrationDirectory: URL { home.appendingPathComponent("Library/Application Support/BetterWorkspace/Migration") }
    var retiredAgentsDirectory: URL { migrationDirectory.appendingPathComponent("retired-launch-agents") }
    var legacyCheckout: URL { BackgroundServiceLayout.legacyCheckout(userHome: home) }

    // MARK: - Definition

    /// The agent, as launchd will run it. Same policy as before adoption: start at login,
    /// restart after a crash but not after a clean exit, and wait thirty seconds between
    /// restarts so a broken install cannot spin.
    func definition() -> [String: Any] {
        [
            "Label": Self.label,
            // Login Items in System Settings names an agent after its program unless
            // it is attributed to an app; without this it is listed as "run.sh".
            "AssociatedBundleIdentifiers": [Self.appBundleIdentifier],
            "ProgramArguments": [program.path, "run"],
            "WorkingDirectory": workingDirectory.path,
            "EnvironmentVariables": ["BETTER_WORKSPACE_EXECUTABLE": Bundle.main.executableURL?.path ?? ""],
            "RunAtLoad": true,
            "KeepAlive": ["SuccessfulExit": false],
            "ProcessType": "Background",
            "ThrottleInterval": 30,
            "StandardOutPath": logDirectory.appendingPathComponent("background-service.stdout.log").path,
            "StandardErrorPath": logDirectory.appendingPathComponent("background-service.stderr.log").path,
        ]
    }

    // MARK: - State

    struct Status: Sendable {
        var installed: Bool
        var loaded: Bool
        var pid: Int?
        /// The program the installed agent actually runs.
        var runningProgram: String?
        var legacyDaemonLoaded: Bool
        var legacyMenuBarLoaded: Bool
        var bundledServicePresent: Bool
        var legacyCheckoutPath: String
        /// False when the installed program is older or newer than this app's bundled
        /// copy (an app update does not replace the running service); nil when unknown.
        var codeMatchesBundle: Bool? = nil

        /// Still launched from the Workspace Watcher checkout rather than the installed
        /// copy — the state before the move, which an install fixes.
        var runsFromLegacyCheckout: Bool {
            runningProgram?.hasPrefix(legacyCheckoutPath + "/") == true
        }

        /// Who is actually running the service right now.
        var owner: String {
            if loaded { return runsFromLegacyCheckout ? "Better Workspace (from the Workspace Watcher checkout)" : "Better Workspace" }
            if legacyDaemonLoaded { return "Workspace Watcher (not yet adopted)" }
            return "nobody"
        }
    }

    func status() -> Status {
        let own = Self.launchctl(["print", "\(Self.domain)/\(Self.label)"])
        let installedProgram = (NSDictionary(contentsOf: plistURL)?["ProgramArguments"] as? [String])?.first
        return Status(
            installed: FileManager.default.fileExists(atPath: plistURL.path),
            loaded: own.status == 0,
            pid: own.status == 0 ? Self.pid(in: own.output) : nil,
            runningProgram: installedProgram,
            legacyDaemonLoaded: Self.launchctl(["print", "\(Self.domain)/\(Self.legacyDaemonLabel)"]).status == 0,
            legacyMenuBarLoaded: Self.launchctl(["print", "\(Self.domain)/\(Self.legacyMenuBarLabel)"]).status == 0,
            bundledServicePresent: bundled.map { FileManager.default.fileExists(atPath: $0.appendingPathComponent("run.sh").path) } ?? false,
            legacyCheckoutPath: legacyCheckout.path,
            codeMatchesBundle: installedCodeMatchesBundle()
        )
    }

    /// Compares the installed service's Python sources with this app's bundled copy.
    /// nil for a development root, a missing bundle or a missing installation.
    func installedCodeMatchesBundle() -> Bool? {
        guard developmentRoot == nil, let bundled,
              let shipped = Self.codeDigest(bundled.appendingPathComponent("workspace_watcher")),
              let installed = Self.codeDigest(layout.code.appendingPathComponent("workspace_watcher")) else { return nil }
        return shipped == installed
    }

    /// Relative path → SHA-256 of every `.py` file; caches and Finder files are ignored.
    static func codeDigest(_ root: URL) -> [String: String]? {
        guard FileManager.default.fileExists(atPath: root.path),
              let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return nil }
        var digest: [String: String] = [:]
        let depth = root.standardizedFileURL.pathComponents.count
        for case let file as URL in files where file.pathExtension == "py" {
            guard let data = try? Data(contentsOf: file) else { return nil }
            let relative = file.standardizedFileURL.pathComponents.dropFirst(depth).joined(separator: "/")
            digest[relative] = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
        return digest.isEmpty ? nil : digest
    }

    // MARK: - Install

    enum Failure: LocalizedError {
        case bundleMissing
        case programMissing(URL)
        case noPython
        case environment(String)
        case launchctl(String)

        var errorDescription: String? {
            switch self {
            case .bundleMissing:
                return "This copy of Better Workspace does not contain the background service."
            case .programMissing(let url):
                return "The background service program is not at \(url.path)."
            case .noPython:
                return "The background service needs Python 3.11 or later (for example from Homebrew: brew install python)."
            case .environment(let message):
                return "Could not prepare the background service's Python environment: \(message)"
            case .launchctl(let message):
                return "launchd refused the background service: \(message)"
            }
        }
    }

    /// Installs the bundled service, carries the old configuration across once, and
    /// starts it under this app's label. Safe to run again: it refreshes the code,
    /// rebuilds the virtualenv only when the requirements changed, and restarts.
    ///
    /// The old daemon is stopped *before* the new one starts. The service holds an
    /// instance lock and a fixed port, so two copies would not run side by side — the
    /// second would exit and launchd would restart it every thirty seconds.
    func install() throws {
        let fm = FileManager.default
        if let developmentRoot {
            guard fm.isExecutableFile(atPath: developmentRoot.appendingPathComponent("run.sh").path) else {
                throw Failure.programMissing(developmentRoot.appendingPathComponent("run.sh"))
            }
        } else {
            try installFiles()
        }
        try fm.createDirectory(at: launchAgents, withIntermediateDirectories: true)
        try fm.createDirectory(at: logDirectory, withIntermediateDirectories: true)

        let data = try PropertyListSerialization.data(fromPropertyList: definition(), format: .xml, options: 0)
        let previous = try? Data(contentsOf: plistURL)
        var retired: [(label: String, from: URL, to: URL)] = []
        do {
            for label in [Self.legacyDaemonLabel, Self.legacyMenuBarLabel] {
                if let moved = try retire(label) { retired.append((label, moved.from, moved.to)) }
            }
            // bootstrap refuses a job that is still loaded, and `bootout` returns before
            // the service has finished its graceful shutdown, so wait for it to go.
            _ = Self.launchctl(["bootout", "\(Self.domain)/\(Self.label)"])
            Self.waitUntilUnloaded(Self.label)
            try data.write(to: plistURL, options: .atomic)
            try Self.bootstrap(plistURL)
        } catch {
            // Never leave the machine with no service at all: put back whatever was
            // running before — this app's previous definition, or Workspace Watcher's.
            if let previous {
                try? previous.write(to: plistURL, options: .atomic)
                try? Self.bootstrap(plistURL)
            } else {
                try? fm.removeItem(at: plistURL)
            }
            for agent in retired.reversed() {
                try? fm.moveItem(at: agent.to, to: agent.from)
                try? Self.bootstrap(agent.from)
            }
            throw error
        }
    }

    /// Code, launcher, virtualenv and — once — configuration, in the installed layout.
    /// Nothing the running service uses is touched until every new piece is ready.
    func installFiles() throws {
        let fm = FileManager.default
        guard let bundled, fm.fileExists(atPath: bundled.appendingPathComponent("workspace_watcher").path) else {
            throw Failure.bundleMissing
        }
        try fm.createDirectory(at: layout.home, withIntermediateDirectories: true)

        // Code: stage beside, then swap.
        let staged = layout.home.appendingPathComponent("app.staging")
        try? fm.removeItem(at: staged)
        try fm.createDirectory(at: staged, withIntermediateDirectories: true)
        try fm.copyItem(at: bundled.appendingPathComponent("workspace_watcher"),
                        to: staged.appendingPathComponent("workspace_watcher"))
        try fm.copyItem(at: bundled.appendingPathComponent("requirements.txt"),
                        to: staged.appendingPathComponent("requirements.txt"))

        // Public downloads carry their runtime and dependencies. Never use pip or
        // require a system Python when that verified payload is present.
        let requirements = try String(contentsOf: staged.appendingPathComponent("requirements.txt"), encoding: .utf8)
        let built = try? String(contentsOf: layout.venvRequirementsStamp, encoding: .utf8)
        if try installEmbeddedRuntime(from: bundled) == false,
           fm.isExecutableFile(atPath: layout.python.path) == false || built != requirements {
            try buildEnvironment(requirements: staged.appendingPathComponent("requirements.txt"), text: requirements)
        }

        // Configuration, once. Afterwards it is the person's file.
        if fm.fileExists(atPath: layout.config.path) == false {
            let legacyConfig = legacyCheckout.appendingPathComponent("config.toml")
            let text = (try? String(contentsOf: legacyConfig, encoding: .utf8))
                .map(layout.migratedConfig(from:))
                ?? layout.freshConfig(workspaceRoot: home.appendingPathComponent("Workspace"))
            try text.write(to: layout.config, atomically: true, encoding: .utf8)
        }
        if fm.fileExists(atPath: layout.rules.path) == false {
            let legacyRules = legacyCheckout.appendingPathComponent("rules.toml")
            try fm.copyItem(at: fm.fileExists(atPath: legacyRules.path)
                                ? legacyRules : bundled.appendingPathComponent("rules.default.toml"),
                            to: layout.rules)
        }
        // The Notion token for work-log and idea sync. Copied, never read here; the
        // copy is readable by its owner only, which the original was not.
        let legacyEnvironment = legacyCheckout.appendingPathComponent(".env")
        if fm.fileExists(atPath: layout.environment.path) == false, fm.fileExists(atPath: legacyEnvironment.path) {
            try fm.copyItem(at: legacyEnvironment, to: layout.environment)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: layout.environment.path)
        }

        // Swap the code and launcher in last.
        try? fm.removeItem(at: layout.code)
        try fm.moveItem(at: staged, to: layout.code)
        let launcher = layout.home.appendingPathComponent("run.sh.staging")
        try? fm.removeItem(at: launcher)
        try fm.copyItem(at: bundled.appendingPathComponent("run.sh"), to: launcher)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launcher.path)
        if fm.fileExists(atPath: layout.launcher.path) {
            _ = try fm.replaceItemAt(layout.launcher, withItemAt: launcher)
        } else { try fm.moveItem(at: launcher, to: layout.launcher) }
    }

    /// Stage the selected architecture and prove imports before activating it.
    /// Runtime updates never replace config, tokens, the database or workspace files.
    private func installEmbeddedRuntime(from bundle: URL) throws -> Bool {
        let fm = FileManager.default
        let payload = bundle.appendingPathComponent("PythonRuntime")
        guard fm.fileExists(atPath: payload.path) else { return false }
        #if arch(arm64)
        let architecture = "arm64"
        #else
        let architecture = "x86_64"
        #endif
        let source = payload.appendingPathComponent(architecture + "/python")
        guard fm.isExecutableFile(atPath: source.appendingPathComponent("bin/python3").path) else {
            throw Failure.environment("The bundled service runtime is incomplete for this Mac. Download a complete release.")
        }
        let manifest = try String(contentsOf: payload.appendingPathComponent("manifest.json"), encoding: .utf8)
        let expected = manifest + "\nApp build: " + (Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown")
        let installed = layout.home.appendingPathComponent("runtime")
        let stamp = layout.home.appendingPathComponent("runtime-version.txt")
        if (try? String(contentsOf: stamp, encoding: .utf8)) == expected,
           fm.isExecutableFile(atPath: installed.appendingPathComponent("bin/python3").path) { return true }
        let staged = layout.home.appendingPathComponent("runtime.staging-" + UUID().uuidString)
        defer { try? fm.removeItem(at: staged) }
        try fm.copyItem(at: source, to: staged)
        let check = Self.run(staged.appendingPathComponent("bin/python3"),
            ["-B", "-I", "-c", "import sys,ssl,sqlite3,tomllib,watchdog; assert sys.version_info >= (3,13)"], timeout: 30)
        guard check.status == 0 else { throw Failure.environment("Bundled service verification failed: " + check.output) }
        if fm.fileExists(atPath: installed.path) {
            _ = try fm.replaceItemAt(installed, withItemAt: staged)
        } else { try fm.moveItem(at: staged, to: installed) }
        try expected.write(to: stamp, atomically: true, encoding: .utf8)
        return true
    }

    /// A fresh virtualenv from a Python new enough to run the service. A virtualenv
    /// records its own path, so it is built at its final name with the old one moved
    /// aside, and the old one comes back if anything fails.
    private func buildEnvironment(requirements: URL, text: String) throws {
        let fm = FileManager.default
        guard let python = Self.suitablePython() else { throw Failure.noPython }
        let old = layout.home.appendingPathComponent("venv.previous")
        try? fm.removeItem(at: old)
        if fm.fileExists(atPath: layout.venv.path) { try fm.moveItem(at: layout.venv, to: old) }
        do {
            let created = Self.run(python, ["-m", "venv", layout.venv.path], timeout: 120)
            guard created.status == 0 else { throw Failure.environment(created.output) }
            let install = Self.run(layout.python,
                                   ["-m", "pip", "install", "--quiet", "--disable-pip-version-check", "-r", requirements.path],
                                   timeout: 600)
            guard install.status == 0 else {
                throw Failure.environment(install.output.split(separator: "\n").suffix(3).joined(separator: " "))
            }
            try text.write(to: layout.venvRequirementsStamp, atomically: true, encoding: .utf8)
            try? fm.removeItem(at: old)
        } catch {
            try? fm.removeItem(at: layout.venv)
            if fm.fileExists(atPath: old.path) { try? fm.moveItem(at: old, to: layout.venv) }
            throw error
        }
    }

    /// The first Python 3.11+ among the usual places. `/usr/bin/python3` is the system's
    /// 3.9 on most Macs, so Homebrew's comes first.
    static func suitablePython() -> URL? {
        let candidates = ["/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/usr/bin/python3"]
        let check = "import sys; sys.exit(0 if sys.version_info >= (\(minimumPython.0), \(minimumPython.1)) else 1)"
        return candidates.lazy
            .map { URL(fileURLWithPath: $0) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) && run($0, ["-c", check], timeout: 20).status == 0 }
    }

    static func run(_ executable: URL, _ arguments: [String], timeout: TimeInterval) -> (status: Int32, output: String) {
        // A blocking pipe read prevents checking the deadline when a child is silent.
        // An owned private log also avoids pipe-buffer deadlocks during pip fallback.
        let log = FileManager.default.temporaryDirectory.appendingPathComponent("bw-service-process-" + UUID().uuidString)
        guard FileManager.default.createFile(atPath: log.path, contents: nil, attributes: [.posixPermissions: 0o600]),
              let handle = try? FileHandle(forWritingTo: log) else { return (-1, "Could not create a private process log") }
        defer { try? handle.close(); try? FileManager.default.removeItem(at: log) }
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = handle
        process.standardError = handle
        do { try process.run() } catch { return (-1, error.localizedDescription) }
        let deadline = Date().addingTimeInterval(timeout)
        var timedOut = false
        while process.isRunning {
            if Date() > deadline {
                timedOut = true; process.terminate()
                let grace = Date().addingTimeInterval(2)
                while process.isRunning && Date() < grace { Thread.sleep(forTimeInterval: 0.05) }
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                break
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        process.waitUntilExit()
        let output = (try? Data(contentsOf: log)) ?? Data()
        return (timedOut ? -1 : process.terminationStatus,
                (timedOut ? "timed out\n" : "") + String(decoding: output.suffix(1_048_576), as: UTF8.self))
    }

    /// Waits for launchd to finish unloading a job, so the next bootstrap is not refused.
    static func waitUntilUnloaded(_ label: String, timeout: TimeInterval = 30) {
        let deadline = Date().addingTimeInterval(timeout)
        while launchctl(["print", "\(domain)/\(label)"]).status == 0, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.25)
        }
    }

    /// Bootstraps a definition, retrying briefly: launchd can refuse for a moment after
    /// an unload even once `print` no longer finds the job.
    static func bootstrap(_ plist: URL, attempts: Int = 8) throws {
        var last = ""
        for attempt in 1...attempts {
            let result = launchctl(["bootstrap", domain, plist.path])
            if result.status == 0 { return }
            last = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            if attempt < attempts { Thread.sleep(forTimeInterval: 1) }
        }
        throw Failure.launchctl(last)
    }

    /// Stops the service and removes its agent. Data, configuration and the installed
    /// program are untouched.
    func uninstall() {
        _ = Self.launchctl(["bootout", "\(Self.domain)/\(Self.label)"])
        Self.waitUntilUnloaded(Self.label)
        try? FileManager.default.removeItem(at: plistURL)
    }

    /// Unloads one of Workspace Watcher's agents and moves its definition into the
    /// archive, so nothing re-launches it at the next login.
    private func retire(_ label: String) throws -> (from: URL, to: URL)? {
        _ = Self.launchctl(["bootout", "\(Self.domain)/\(label)"])
        // The old daemon holds the instance lock and the port until it has exited.
        Self.waitUntilUnloaded(label)
        let source = legacyPlistURL(label)
        guard FileManager.default.fileExists(atPath: source.path) else { return nil }
        try FileManager.default.createDirectory(at: retiredAgentsDirectory, withIntermediateDirectories: true)
        var destination = retiredAgentsDirectory.appendingPathComponent(source.lastPathComponent)
        if FileManager.default.fileExists(atPath: destination.path) {
            let stamp = Int(Date().timeIntervalSince1970)
            destination = retiredAgentsDirectory.appendingPathComponent("\(label)-\(stamp).plist")
        }
        try FileManager.default.moveItem(at: source, to: destination)
        return (source, destination)
    }

    // MARK: - Notion credential

    /// The Notion token the background service already uses, from its own `.env`, for
    /// a migration run with no token in this app's Keychain. Read here and handed to the
    /// Notion client only; never printed or stored anywhere else.
    func notionToken(variable: String = "NOTION_API_KEY") -> String? {
        if let value = ProcessInfo.processInfo.environment[variable], value.isEmpty == false { return value }
        guard let text = try? String(contentsOf: layout.environment, encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("#") == false, let equals = trimmed.firstIndex(of: "=") else { continue }
            var key = trimmed[..<equals].trimmingCharacters(in: .whitespaces)
            if key.hasPrefix("export ") { key = String(key.dropFirst(7)).trimmingCharacters(in: .whitespaces) }
            guard key == variable else { continue }
            let value = trimmed[trimmed.index(after: equals)...].trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            return value.isEmpty ? nil : value
        }
        return nil
    }

    // MARK: - launchctl

    static var domain: String { "gui/\(getuid())" }

    static func launchctl(_ arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { return (-1, error.localizedDescription) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    static func pid(in printed: String) -> Int? {
        for line in printed.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("pid = "), let value = Int(trimmed.dropFirst(6)) { return value }
        }
        return nil
    }
}
