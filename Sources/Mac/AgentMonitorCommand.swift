import Foundation
import BetterWorkspaceCore

/// `BetterWorkspace --agent-monitor apply <manifest.json> [--workspace <root>]`
///
/// The Local AI Agent Completion Monitor's only way to change tasks. Runs headlessly and
/// exits before any window or second app instance exists. Prints the JSON response
/// (`AgentMonitorBridge.Response`); exits 1 with a message on stderr when the manifest
/// itself is refused. No network, Notion or database access.
enum AgentMonitorCommand {
    static func runIfRequested() {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "--agent-monitor") else { return }
        do {
            guard args.indices.contains(index + 2), args[index + 1] == "apply" else {
                throw AgentMonitorBridge.Failure.invalid("Use --agent-monitor apply <manifest.json> [--workspace <root>]")
            }
            let workspace: WorkspaceLocation
            if let i = args.firstIndex(of: "--workspace"), args.indices.contains(i + 1) {
                workspace = .init(root: URL(fileURLWithPath: args[i + 1]))
            } else {
                workspace = .resolved
            }
            let manifest = try JSONDecoder().decode(AgentMonitorBridge.Manifest.self,
                                                    from: Data(contentsOf: URL(fileURLWithPath: args[index + 2])))
            // Same routing as every other place a task is filed: the configured task queue.
            let areas = AreaConfigurationStore(url: AreaConfigurationStore.defaultURL())
            let folders = WorkspaceFolderDiscovery().folders(in: workspace, store: areas) ?? []
            let queues = folders.filter { $0.settings.layout == .workQueue }.map(\.url)
            let taskQueue = WorkQueueRouting.folder(for: .task, among: folders)?.url ?? workspace.url(forArea: "To Do")
            // Tests only: a folder that stands in for the system Trash when an undo removes a task.
            let trash = args.firstIndex(of: "--trash").flatMap { args.indices.contains($0 + 1) ? URL(fileURLWithPath: args[$0 + 1]) : nil }
            let response = try AgentMonitorBridge.apply(manifest, workspace: workspace, queues: queues, taskQueue: taskQueue, trash: trash)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            print(String(decoding: try encoder.encode(response), as: UTF8.self))
            exit(0)
        } catch {
            fputs("Agent monitor: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
}
