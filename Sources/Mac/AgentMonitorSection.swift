import SwiftUI
import AppKit
import BetterWorkspaceCore

/// Settings → Services → Agent completion monitor: turn it on or off, see whether it and
/// LM Studio are working, what it did recently, and where its logs are.
struct AgentMonitorSection: View {
    @Environment(AppModel.self) private var model
    private var monitor: AgentMonitorSupervisor { AgentMonitorSupervisor.shared }
    @State private var enabled = AgentMonitorSupervisor.shared.isEnabled
    @State private var mode = AgentMonitorSupervisor.shared.mode
    @State private var maxNewTasks = AgentMonitorSupervisor.shared.maxNewTasks
    @State private var root = TestIsolation.defaults.string(forKey: AgentMonitorSupervisor.rootKey) ?? ""

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.snug) {
            Text("When Codex, Claude Code, GitHub Copilot or Antigravity finishes working on a project, a local "
                 + "LM Studio model reviews the session and updates that project’s To Do: verified work is "
                 + "completed, follow-ups are added and you get a notification. It runs in the background at "
                 + "login, even when Better Workspace is closed. Nothing leaves this Mac.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Toggle("Monitor coding agents", isOn: Binding(get: { enabled }, set: { value in
                enabled = value
                monitor.setEnabled(value)
            }))
            .accessibilityIdentifier("settings.agentMonitor.enabled")

            statusRows

            Picker("Task changes", selection: Binding(get: { mode }, set: { value in
                mode = value
                TestIsolation.defaults.set(value, forKey: AgentMonitorSupervisor.modeKey)
                monitor.restart()
            })) {
                Text("Update tasks automatically").tag("apply")
                Text("Preview only (log, change nothing)").tag("preview")
            }
            .accessibilityIdentifier("settings.agentMonitor.mode")

            Stepper(value: Binding(get: { maxNewTasks }, set: { value in
                maxNewTasks = value
                TestIsolation.defaults.set(value, forKey: AgentMonitorSupervisor.maxNewTasksKey)
                monitor.restart()
            }), in: 0...10) {
                LabeledContent("New tasks per session", value: maxNewTasks == 0 ? "None" : "Up to \(maxNewTasks)")
            }
            .help("Extra recommendations are kept as deferred suggestions and offered again in later sessions.")

            agentsRow
            recentActivity

            HStack(spacing: Theme.Space.tight) {
                Button("Open Today’s Log") {
                    if let log = monitor.todaysLog, FileManager.default.fileExists(atPath: log.path) { model.open(log) }
                    else { model.revealInFinder(model.workspace.root.appendingPathComponent("Logs")) }
                }
                .help("~/Workspace/Logs/<date>/agent-completion-monitor.log: every session, decision and task change.")
                Button("Show History") { model.revealInFinder(AgentMonitorSupervisor.stateDirectory) }
                    .help("The monitor’s private state: processed sessions, change receipts for undo, and notifications.")
                Spacer()
                if enabled {
                    Button("Restart") { monitor.restart() }
                }
            }

            DisclosureGroup("Advanced") {
                TextField("Monitor folder", text: $root, prompt: Text(AgentMonitorSupervisor.defaultRoot.path))
                    .onSubmit {
                        TestIsolation.defaults.set(root, forKey: AgentMonitorSupervisor.rootKey)
                        monitor.restart()
                    }
                Text("The Local AI Agent Completion Monitor project. Undo a session’s changes with "
                     + "`python3 monitor.py undo <job>` in that folder.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear {
            enabled = monitor.isEnabled; mode = monitor.mode; maxNewTasks = monitor.maxNewTasks
            monitor.poll()
        }
    }

    // MARK: Rows

    @ViewBuilder private var statusRows: some View {
        let status = monitor.status
        let age = monitor.heartbeatAge
        let alive = monitor.isRunning && (age ?? .infinity) < 90
        LabeledContent("Status") {
            Label(statusText(alive: alive, age: age), systemImage: alive ? "checkmark.circle.fill" : enabled ? "exclamationmark.circle" : "pause.circle")
                .foregroundStyle(alive ? .green : enabled ? .orange : .secondary)
                .font(.caption)
                .accessibilityIdentifier("settings.agentMonitor.status")
        }
        if enabled, let lm = status?.lmstudio {
            LabeledContent("LM Studio") {
                Label(lm.available == true ? (lm.model.map { "Available · \($0)" } ?? "Available, but no chat model is installed")
                                           : "Not running — finished sessions wait until it is",
                      systemImage: lm.available == true && lm.model != nil ? "cpu" : "exclamationmark.triangle")
                    .foregroundStyle(lm.available == true && lm.model != nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.orange))
                    .font(.caption).lineLimit(2)
            }
        }
        if enabled, monitor.notificationsAllowed == false {
            LabeledContent("Notifications") {
                HStack(spacing: 6) {
                    Text("Off for Better Workspace").font(.caption).foregroundStyle(.orange)
                    Button("Open Notification Settings") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=com.zacharysturman.BetterWorkspace") {
                            NSWorkspace.shared.open(url)
                        }
                    }.controlSize(.small)
                }
            }
        } else if enabled, monitor.notificationsAllowed == true {
            LabeledContent("Notifications") { Text("Allowed").font(.caption).foregroundStyle(.secondary) }
        }
        if let problem = monitor.problem, enabled {
            Text(problem).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
        }
        if enabled, let waiting = status?.waiting {
            Text(waiting + ((status?.pendingJobs ?? 0) > 0 ? " (\(status?.pendingJobs ?? 0) waiting)." : "."))
                .font(.caption).foregroundStyle(.orange)
        }
        if enabled, let errors = status?.errors, let latest = errors.first, let message = latest.message {
            Text("Last problem: " + message).font(.caption).foregroundStyle(.orange).lineLimit(3)
                .textSelection(.enabled)
        }
    }

    private func statusText(alive: Bool, age: TimeInterval?) -> String {
        guard enabled else { return "Off" }
        guard monitor.isRunning else { return monitor.busy ? "Starting…" : "Not running" }
        guard alive else { return age == nil ? "Starting…" : "Not responding" }
        let phase = monitor.status?.phase ?? "watching"
        let preview = monitor.status?.mode == "preview" ? " · preview only" : ""
        return (phase == "watching" ? "Watching" : phase.capitalized) + preview
    }

    @ViewBuilder private var agentsRow: some View {
        if let agents = monitor.status?.agents, !agents.isEmpty {
            LabeledContent("Agents") {
                VStack(alignment: .trailing, spacing: 2) {
                    ForEach(agents) { agent in
                        HStack(spacing: 4) {
                            Text(agent.displayName ?? agent.name)
                            Image(systemName: agent.available == true ? "checkmark.circle" : "minus.circle")
                                .foregroundStyle(agent.available == true ? AnyShapeStyle(.green) : AnyShapeStyle(.tertiary))
                            Text(agent.available == true ? "\(agent.sessionsLastDay ?? 0) today" : "not found")
                                .foregroundStyle(.secondary).monospacedDigit()
                        }
                        .font(.caption)
                    }
                }
            }
        }
    }

    @ViewBuilder private var recentActivity: some View {
        let recent = Array((monitor.status?.recent ?? []).prefix(5))
        if enabled, !recent.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("Recent").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(recent) { entry in
                    Button {
                        if let project = entry.project, !project.isEmpty {
                            Task { @MainActor in await model.openProjectTasks(projectPath: "Projects/" + project, taskID: nil) }
                        }
                    } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(entry.project ?? "—").fontWeight(.medium).lineLimit(1)
                            Text(describe(entry)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                            Spacer(minLength: 4)
                            Text(entry.agent.map(agentName) ?? "").foregroundStyle(.tertiary)
                        }
                        .font(.caption)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(entry.title ?? "")
                }
            }
            .accessibilityIdentifier("settings.agentMonitor.recent")
        }
    }

    private func describe(_ entry: AgentMonitorStatus.Activity) -> String {
        if let reason = entry.reason { return reason }
        var parts: [String] = []
        if let n = entry.new, n > 0 { parts.append("\(n) new") }
        if let n = entry.completed, n > 0 { parts.append("\(n) completed") }
        if let n = entry.progressed, n > 0 { parts.append("\(n) updated") }
        if let n = entry.deferred, n > 0 { parts.append("\(n) deferred") }
        if parts.isEmpty { parts.append("no task changes") }
        if let next = entry.next?.title { parts.append("next: " + next) }
        return parts.joined(separator: " · ")
    }

    private func agentName(_ raw: String) -> String {
        monitor.status?.agents?.first { $0.name == raw }?.displayName ?? raw
    }
}
