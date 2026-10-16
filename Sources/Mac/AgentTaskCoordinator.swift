import AppKit
import Observation
import BetterWorkspaceCore

struct AgentProviderInfo: Decodable, Identifiable {
    struct Model: Decodable, Identifiable {
        let id: String; let label: String; let problem: String?
        init(id: String, label: String, problem: String? = nil) {
            self.id = id; self.label = label; self.problem = problem
        }
    }
    let id: String; let available: Bool; let models: [Model]; let usage: String; let exhausted: Bool; let problem: String
    var name: String { ["claude": "Claude", "codex": "Codex", "antigravity": "Antigravity", "lmstudio": "LM Studio"][id] ?? id }
}

struct AgentRunPresentation: Identifiable {
    let request: AgentTaskRequest
    let folder: URL
    let receipt: AgentTaskReceipt?
    let applied: Set<String>
    let conflicts: [String: String]
    var id: String { request.runID }
}

@MainActor @Observable final class AgentTaskCoordinator {
    var runs: [AgentRunPresentation] = []
    var providers: [AgentProviderInfo] = []
    var discovering = false
    var discoveryProblem: String?
    private var polling: Task<Void, Never>?
    private var refreshing = false
    private var root: URL {
        (TestIsolation.sandbox ?? Database.preferredURL().deletingLastPathComponent()).appendingPathComponent("AgentRuns", isDirectory: true).resolvingSymlinksInPath()
    }
    private var script: URL? { Bundle.main.url(forResource: "agent_tasks", withExtension: "py") }
    /// Explicit, opt-in acceptance only: regular UI fixtures still cannot contact providers.
    private var liveSmokeProvider: String? {
        #if DEBUG
        guard let sandbox = TestIsolation.sandbox, sandbox.lastPathComponent.hasPrefix("bw-ui-"),
              UUID(uuidString: String(sandbox.lastPathComponent.dropFirst(6))) != nil,
              let provider = ProcessInfo.processInfo.environment["BW_LIVE_AGENT_SMOKE"],
              ["claude", "codex", "antigravity", "lmstudio"].contains(provider) else { return nil }
        return provider
        #else
        return nil
        #endif
    }
    struct Acknowledgement: Codable { var applied: Set<String> = []; var conflicts: [String: String] = [:] }

    func start(model: AppModel) {
        guard polling == nil else { return }
        polling = Task { @MainActor [weak self, weak model] in
            while !Task.isCancelled {
                if let self, let model, !model.isAwaitingWorkItems { await self.refresh(model: model) }
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    func discover(endpoint: String) async {
        guard !discovering else { return }
        discovering = true; discoveryProblem = nil
        defer { discovering = false }
        guard !TestIsolation.isActive || liveSmokeProvider != nil else {
            providers = [AgentProviderInfo(id: "codex", available: true, models: [.init(id: "fixture", label: "Fixture model")], usage: "Isolated test — no provider contacted.", exhausted: false, problem: "")]
            return
        }
        guard let script else { discoveryProblem = "Agent runner is missing from this app build."; return }
        do {
            let data = try await Task.detached(priority: .utility) { try Self.capture(script: script, arguments: ["discover", endpoint]) }.value
            providers = try JSONDecoder().decode([AgentProviderInfo].self, from: data)
        } catch { discoveryProblem = error.localizedDescription }
    }

    nonisolated private static func capture(script: URL, arguments: [String]) throws -> Data {
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [script.path] + arguments
        process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw LaunchError.message("Provider discovery failed. Check Python 3 and the provider CLI installations.") }
        return data
    }
    enum LaunchError: LocalizedError {
        case message(String)
        var errorDescription: String? { if case .message(let value) = self { value } else { nil } }
    }
    nonisolated static func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    static func graphFingerprint(_ record: ProjectGraphRecord) -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return AgentTaskSnapshot.digest((try? encoder.encode(record)) ?? Data())
    }
    static func snapshot(_ entry: ProjectPlanEntry, model: AppModel) -> AgentTaskSnapshot {
        switch entry.origin {
        case .work(let work): return .init(id: entry.id, title: entry.title, body: work.body,
            fingerprint: AgentTaskSnapshot.fingerprint(work), workPath: work.url.canonicalPath)
        case .graph(let record):
            let body = model.graphSource(for: record).map { source in
                ["Description", "Notes", "Details"].map { record.value($0, source: source).display }.filter { !$0.isEmpty }.joined(separator: "\n")
            } ?? ""
            return .init(id: entry.id, title: entry.title, body: body, fingerprint: graphFingerprint(record), workPath: nil)
        }
    }

    func submit(_ request: AgentTaskRequest, model: AppModel) async throws {
        guard let script else { throw LaunchError.message("Agent runner is missing from this app build.") }
        guard model.projects().contains(where: { $0.url.canonicalPath == request.projectPath }),
              URL(fileURLWithPath: request.projectPath).resolvingSymlinksInPath().canonicalPath == request.projectPath else {
            throw LaunchError.message("Choose an existing local project without a symlink path.")
        }
        guard !request.tasks.isEmpty || !request.instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        // Test runs cannot execute a real provider or read its credentials.
        if TestIsolation.isActive {
            let lowCostModels = ["claude": "haiku", "codex": "gpt-6-luna", "antigravity": "gemini-3.8-flash-low"]
            guard let provider = liveSmokeProvider, request.provider == provider, let sandbox = TestIsolation.sandbox,
                  request.projectPath == sandbox.appendingPathComponent("Workspace/Projects/Fixture project").canonicalPath,
                  request.tasks.count == 1, request.tasks.first?.id == "live-smoke-\(provider)",
                  request.tasks.first?.title == "Create hello.txt",
                  provider == "lmstudio" || request.model == lowCostModels[provider] else {
                throw LaunchError.message("Provider execution is disabled except for an explicitly opted-in disposable live smoke fixture.")
            }
        }
        let folder = root.appendingPathComponent(request.runID, isDirectory: true)
        let launcher = folder.appendingPathComponent("launch.command")
        let requestURL = folder.appendingPathComponent("request.json")
        var data = try JSONEncoder().encode(request)
        if TestIsolation.isActive {
            var payload = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            payload["timeoutSeconds"] = request.provider == "lmstudio" ? 300 : 180
            data = try JSONSerialization.data(withJSONObject: payload)
        }
        let requestData = data
        try await Task.detached(priority: .userInitiated) {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try requestData.write(to: requestURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: requestURL.path)
            let command = "#!/bin/zsh\ncd -- " + Self.quote(request.projectPath) + "\n/usr/bin/python3 " + Self.quote(script.path)
                + " run " + Self.quote(requestURL.path) + "\n"
            try command.write(to: launcher, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: launcher.path)
        }.value
        do {
            try await NSWorkspace.shared.open([launcher], withApplicationAt: URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"), configuration: .init())
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
        await refresh(model: model)
    }

    private nonisolated static func loadRuns(root: URL) -> [AgentRunPresentation] {
        let fm = FileManager.default, decoder = JSONDecoder()
        let folders = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        return folders.compactMap { folder in
            guard UUID(uuidString: folder.lastPathComponent) != nil,
                  folder.resolvingSymlinksInPath().canonicalPath == folder.canonicalPath,
                  let data = try? boundedData(folder.appendingPathComponent("request.json")),
                  let request = try? decoder.decode(AgentTaskRequest.self, from: data), request.runID == folder.lastPathComponent else { return nil }
            let receipt = (try? boundedData(folder.appendingPathComponent("receipt.json"))).flatMap { try? decoder.decode(AgentTaskReceipt.self, from: $0) }
            let ack = (try? boundedData(folder.appendingPathComponent("ack.json"))).flatMap { try? decoder.decode(Acknowledgement.self, from: $0) } ?? .init()
            return .init(request: request, folder: folder, receipt: receipt, applied: ack.applied, conflicts: ack.conflicts)
        }
    }
    private nonisolated static func boundedData(_ url: URL) throws -> Data {
        guard url.resolvingSymlinksInPath().canonicalPath == url.canonicalPath,
              (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) < 4_000_000 else { throw LaunchError.message("Invalid agent run file.") }
        return try Data(contentsOf: url)
    }

    func refresh(model: AppModel) async {
        guard !refreshing else { return }
        refreshing = true; defer { refreshing = false }
        let root = root
        var loaded = await Task.detached(priority: .utility) { Self.loadRuns(root: root) }.value
        for index in loaded.indices {
            let run = loaded[index]
            guard let receipt = run.receipt else { continue }
            var ack = Acknowledgement(applied: run.applied, conflicts: run.conflicts)
            do {
                for completion in try receipt.validated(for: run.request) where !ack.applied.contains(completion.id) && ack.conflicts[completion.id] == nil {
                    guard let snapshot = run.request.tasks.first(where: { $0.id == completion.id }),
                          model.projects().contains(where: { $0.url.canonicalPath == run.request.projectPath }) else { continue }
                    do {
                        if let workPath = snapshot.workPath {
                            guard let current = model.workItems.first(where: { $0.id == snapshot.id && $0.url.canonicalPath == workPath }) else { throw LaunchError.message("Task moved or was removed. Review its completion manually.") }
                            if current.status != .completed {
                                guard AgentTaskSnapshot.fingerprint(current) == snapshot.fingerprint else { throw LaunchError.message("Task changed since submission. Review the agent evidence before completing it.") }
                                var done = current; done.status = .completed; done.completedAt = Date()
                                _ = try await model.saveWorkItem(done)
                            }
                        } else {
                            guard let current = model.graphRecords.first(where: { $0.id == snapshot.id && $0.locallyDeleted != true }) else { throw LaunchError.message("Graph task was removed.") }
                            if !model.graphRecordIsCompleted(current) {
                                guard Self.graphFingerprint(current) == snapshot.fingerprint else { throw LaunchError.message("Graph task changed since submission.") }
                                model.setGraphTask(current, done: true)
                                guard model.graphRecords.first(where: { $0.id == snapshot.id }).map({ model.graphRecordIsCompleted($0) }) == true else { throw LaunchError.message("Task completion could not be saved. Review manually.") }
                            }
                        }
                        ack.applied.insert(snapshot.id)
                    } catch { ack.conflicts[snapshot.id] = error.localizedDescription }
                }
            } catch { ack.conflicts["receipt"] = error.localizedDescription }
            if ack.applied != run.applied || ack.conflicts != run.conflicts {
                let data = try? JSONEncoder().encode(ack), path = run.folder.appendingPathComponent("ack.json")
                do { try await Task.detached { try data?.write(to: path, options: .atomic) }.value }
                catch { model.lastError = "Agent completion saved, but acknowledgement could not be recorded: \(error.localizedDescription)" }
            }
            loaded[index] = .init(request: run.request, folder: run.folder, receipt: receipt, applied: ack.applied, conflicts: ack.conflicts)
        }
        runs = loaded.sorted { $0.folder.lastPathComponent < $1.folder.lastPathComponent }
    }
}
