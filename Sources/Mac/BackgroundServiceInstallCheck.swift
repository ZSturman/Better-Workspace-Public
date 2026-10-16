import Foundation
import BetterWorkspaceCore

/// `--service verify-install`: a fresh installation of this app's bundled service into a
/// temporary home, exercised on a spare port. It uses the real installer for the files,
/// virtualenv and first-run configuration, then starts that copy's API and round-trips
/// an idea with potential-project planning through the app's own client.
///
/// Nothing touches the person's installation: no launch agent is written or loaded,
/// port 8765 and the running service are left alone, and the temporary home (with its
/// own empty Workspace) is removed afterwards unless `--keep` is given.
enum BackgroundServiceInstallCheck {
    private static func say(_ line: String) { FileHandle.standardOutput.write(Data((line + "\n").utf8)) }

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func run(keep: Bool) async -> Int32 {
        let fm = FileManager.default
        // realpath, not resolvingSymlinksInPath: the latter maps /private/var back to /var,
        // and the service compares the canonical paths the client sends.
        let temporary = realpath(fm.temporaryDirectory.path, nil).map { pointer in defer { free(pointer) }; return String(cString: pointer) } ?? fm.temporaryDirectory.path
        let root = URL(fileURLWithPath: temporary).appendingPathComponent("bw-service-install-\(UUID().uuidString)")
        let home = root.appendingPathComponent("home")
        var server: Process?
        defer {
            server?.terminate(); server?.waitUntilExit()
            if keep { say("Kept \(root.path)") } else { try? fm.removeItem(at: root) }
        }
        do {
            let agent = BackgroundServiceAgent(home: home)
            let layout = agent.layout
            let started = Date()
            try agent.installFiles()
            say("Installed bundled service files into a temporary home in \(Int(Date().timeIntervalSince(started)))s")

            func require(_ condition: Bool, _ message: String) throws { if !condition { throw Failure(message: message) } }
            try require(fm.isExecutableFile(atPath: layout.launcher.path), "Launcher missing or not executable")
            try require(fm.isExecutableFile(atPath: layout.python.path), "Virtualenv Python missing")
            let config = try String(contentsOf: layout.config, encoding: .utf8)
            try require(config.contains("workspace_root = \"\(home.appendingPathComponent("Workspace").path)\""), "Fresh config does not point at the new home's Workspace")
            try require(config.contains("write_documents = false"), "Fresh config would write Project.betterproject")
            try require(fm.fileExists(atPath: layout.rules.path), "rules.toml missing")
            try require(!fm.fileExists(atPath: layout.environment.path), "A fresh install must not invent a Notion token file")
            try require(agent.installedCodeMatchesBundle() == true, "Installed code differs from the bundled copy")
            let plist = try PropertyListSerialization.data(fromPropertyList: agent.definition(), format: .xml, options: 0)
            let definition = try PropertyListSerialization.propertyList(from: plist, format: nil) as? [String: Any]
            try require((definition?["ProgramArguments"] as? [String])?.first == layout.launcher.path, "Launch agent would not run the installed launcher")
            try require(!fm.fileExists(atPath: agent.plistURL.path), "The check must not write a launch agent")
            say("Verified launcher, virtualenv, fresh config and rules, code identity and launch agent definition (not loaded)")

            // Start the installed copy's API on a spare port against the temporary Workspace.
            let ideas = home.appendingPathComponent("Workspace/Ideas/Install check")
            try fm.createDirectory(at: ideas, withIntermediateDirectories: true)
            try "A fresh-install check idea.".write(to: ideas.appendingPathComponent("Notes.md"), atomically: true, encoding: .utf8)
            // The running service indexes at startup; the API alone does not.
            let scan = try runInstalled(layout, ["core", "--config", layout.config.path, "intents", "scan", "--initialize-items"], log: root.appendingPathComponent("scan.log"))
            try require(scan == 0, "Indexing the temporary Workspace failed: \((try? String(contentsOf: root.appendingPathComponent("scan.log"), encoding: .utf8)) ?? "")")
            let port = try freePort()
            let log = root.appendingPathComponent("service.log")
            fm.createFile(atPath: log.path, contents: nil)
            let process = Process()
            process.executableURL = layout.python
            process.arguments = ["-m", "workspace_watcher", "core-api", "--config", layout.config.path, "--port", String(port)]
            process.currentDirectoryURL = layout.home
            var environment = ProcessInfo.processInfo.environment
            environment["PYTHONPATH"] = layout.code.path
            process.environment = environment
            let output = try FileHandle(forWritingTo: log)
            process.standardOutput = output; process.standardError = output
            try process.run()
            server = process
            let base = URL(string: "http://127.0.0.1:\(port)")!
            var healthy = false
            for _ in 0..<60 where process.isRunning {
                if await BackgroundServiceClient.shared.health(baseURL: base, timeout: 1) != nil { healthy = true; break }
                try await Task.sleep(for: .milliseconds(500))
            }
            let serviceLog = { (try? String(contentsOf: log, encoding: .utf8)) ?? "" }
            try require(healthy, "The installed service did not answer on port \(port): \(serviceLog().suffix(800))")
            say("Installed service answered on port \(port) (the running service on 8765 was not touched)")

            guard let registered = await BackgroundServiceClient.shared.registerIdea(at: ideas, baseURL: base) else { throw Failure(message: "Registering an idea failed: \(serviceLog().suffix(800))") }
            var planning = IdeaPlanning(priority: 4, potential: .project, needsSetup: false)
            planning.project = IdeaProjectDetails(metadata: .init(domain: "Technology", phase: "Planning", projectType: "Application"),
                                                  oneLiner: "Fresh install check", summary: "Round-trips potential-project details.")
            var changes = IdeaChanges(); changes.planning = planning; changes.expectedPlanning = registered.planning; changes.checksPlanning = true
            guard let updated = await BackgroundServiceClient.shared.updateIdea(id: registered.id, changes, baseURL: base) else { throw Failure(message: "Saving potential-project planning failed: \(serviceLog().suffix(800))") }
            try require(updated.planning == planning, "The service changed the planning it was given")
            let listed = await BackgroundServiceClient.shared.ideas(baseURL: base)?.first { $0.id == registered.id }
            try require(listed?.planning?.project == planning.project, "Potential-project details did not persist")
            try require(fm.contentsOfDirectory(atPath: ideas.path) == ["Notes.md"], "The service wrote beside the idea's files")
            say("Registered an idea and round-tripped potential-project planning; no files were written beside it")
            say("Fresh install check passed")
            return 0
        } catch {
            say("Fresh install check failed: \(error.localizedDescription)")
            return 1
        }
    }

    /// Runs the installed copy's Python with its own code, as `run.sh` does.
    private static func runInstalled(_ layout: BackgroundServiceLayout, _ arguments: [String], log: URL) throws -> Int32 {
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let process = Process()
        process.executableURL = layout.python
        process.arguments = ["-m", "workspace_watcher"] + arguments
        process.currentDirectoryURL = layout.home
        var environment = ProcessInfo.processInfo.environment
        environment["PYTHONPATH"] = layout.code.path
        process.environment = environment
        let output = try FileHandle(forWritingTo: log)
        process.standardOutput = output; process.standardError = output
        try process.run(); process.waitUntilExit()
        return process.terminationStatus
    }

    /// A port the kernel just handed out, released for the service to bind.
    private static func freePort() throws -> Int {
        let socketFD = socket(AF_INET, SOCK_STREAM, 0)
        guard socketFD >= 0 else { throw Failure(message: "No socket for a free port") }
        defer { close(socketFD) }
        var address = sockaddr_in(); address.sin_family = sa_family_t(AF_INET); address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(socketFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard bound == 0 else { throw Failure(message: "Could not find a free port") }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(socketFD, $0, &length) } }
        return Int(UInt16(bigEndian: address.sin_port))
    }
}
