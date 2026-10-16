import Foundation

/// Where the installed background service lives, and how its configuration is carried
/// over from the Workspace Watcher checkout it used to run from.
///
/// Pure: paths and text only. Installing (copying, building the virtualenv, launchd) is
/// `BackgroundServiceAgent` in the Mac app.
public struct BackgroundServiceLayout: Sendable {

    /// `~/Library/Application Support/BetterWorkspace/BackgroundService`.
    public let home: URL

    public init(home: URL) { self.home = home }

    public static func standard(userHome: URL = WorkspaceLocation.homeDirectory) -> Self {
        Self(home: userHome.appendingPathComponent("Library/Application Support/BetterWorkspace/BackgroundService"))
    }

    /// Replaced on every install.
    public var code: URL { home.appendingPathComponent("app") }
    public var launcher: URL { home.appendingPathComponent("run.sh") }
    public var venv: URL { home.appendingPathComponent("venv") }
    public var python: URL { venv.appendingPathComponent("bin/python") }
    /// The requirements the virtualenv was last built from; a difference means rebuild.
    public var venvRequirementsStamp: URL { venv.appendingPathComponent("bw-requirements.txt") }
    /// Kept across installs: written once, then the person's to edit.
    public var config: URL { home.appendingPathComponent("config.toml") }
    public var rules: URL { home.appendingPathComponent("rules.toml") }
    public var environment: URL { home.appendingPathComponent(".env") }

    /// The checkout the service ran from before it moved here.
    public static func legacyCheckout(userHome: URL = WorkspaceLocation.homeDirectory) -> URL {
        userHome.appendingPathComponent("Workspace/Projects/Workspace Watcher")
    }

    /// The old checkout's `config.toml`, adjusted to run from here.
    ///
    /// The one thing that cannot be carried over as written is `env_file`: relative,
    /// it is resolved against the code directory, which every install replaces. It is
    /// pointed at the `.env` beside this config instead. Everything else — the workspace
    /// root, the database path, the declared intent folders, the Notion and work-log
    /// switches — means the same here, so it is kept exactly, comments included.
    public func migratedConfig(from legacy: String) -> String {
        Self.header + Self.withoutRetiredSettings(repointingEnvironment(legacy))
    }

    /// Settings that pointed outside Better Workspace and are no longer read:
    /// `client_source` (the Task Management checkout the Notion client was loaded from,
    /// now part of the service) and the `[external_task_sync]` table (Better Projects'
    /// offline task queue). Dropped so the configuration names nothing that is gone;
    /// the service ignores them anyway, so this is tidiness, not a behaviour change.
    public static func withoutRetiredSettings(_ config: String) -> String {
        var lines: [String] = []
        var inRetiredTable = false
        // Comments after a retired table's last key usually introduce the next table,
        // so they are held and kept unless another retired key follows them.
        var held: [String] = []
        for line in config.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") {
                if inRetiredTable { lines += held; held = [] }
                inRetiredTable = trimmed.hasPrefix("[external_task_sync]")
                if inRetiredTable {
                    // The comment block touching the header describes the retired table.
                    while let last = lines.last?.trimmingCharacters(in: .whitespaces), last.hasPrefix("#") {
                        lines.removeLast()
                    }
                    continue
                }
            }
            if inRetiredTable {
                if trimmed.isEmpty || trimmed.hasPrefix("#") { held.append(line) } else { held = [] }
                continue
            }
            if trimmed.hasPrefix("client_source") && trimmed.contains("=") { continue }
            lines.append(line)
        }
        if inRetiredTable { lines += held }
        return lines.joined(separator: "\n")
    }

    private func repointingEnvironment(_ legacy: String) -> String {
        var lines: [String] = []
        for line in legacy.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("env_file"), let equals = trimmed.firstIndex(of: "=") {
                let value = trimmed[trimmed.index(after: equals)...]
                    .split(separator: "#", maxSplits: 1).first?
                    .trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"'")) ?? ""
                if value.hasPrefix("/") == false && value.hasPrefix("~") == false {
                    let indent = line.prefix { $0 == " " || $0 == "\t" }
                    lines.append("\(indent)env_file = \"\(environment.path)\" # moved from the Workspace Watcher checkout")
                    continue
                }
            }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }

    /// For a machine that never ran Workspace Watcher: the settings this app relies on,
    /// and the built-in defaults for everything else.
    public func freshConfig(workspaceRoot: URL) -> String {
        Self.header + """
        [workspace_watcher]
        workspace_root = "\(workspaceRoot.path)"
        rules_file = "rules.toml"

        [workspace_watcher.storage]
        database = "Logs/workspace-watcher/core.db"

        [workspace_watcher.intent_folders]
        excluded_roots = ["Logs/workspace-watcher"]

        [workspace_watcher.intent_folders.declared]
        "Ideas" = "Ideas"
        "For Inspiration" = "Inspiration"
        "For Reference" = "Reference"
        "Review" = "Review"
        "To Organize" = "Organize"

        [workspace_watcher.projects]
        write_documents = false

        [workspace_watcher.notion]
        enabled = false
        env_file = "\(environment.path)"

        """
    }

    static let header = """
    # Better Workspace background service configuration.
    # Written once by Better Workspace; yours to edit. Every key has a built-in default
    # (workspace_watcher/core_config.py). Restart the service after editing:
    # Settings → Background service, or `BetterWorkspace --service install`.

    """
}
