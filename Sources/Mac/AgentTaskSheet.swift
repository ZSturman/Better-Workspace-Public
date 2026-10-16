import SwiftUI
import BetterWorkspaceCore

/// Submit is the explicit authorization to let the selected agent work in this project.
struct AgentTaskSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let project: WorkspaceItem
    let graph: ProjectGraphRecord?
    @AppStorage("agentTaskProvider", store: TestIsolation.defaults) private var provider = "codex"
    @AppStorage("projectZenAIEndpoint", store: TestIsolation.defaults) private var endpoint = LMStudioPreset.endpoint
    @State private var modelID = ""
    @State private var effort = ""
    @State private var instructions = ""
    @State private var sequential = true
    @State private var networkAccess = false
    @State private var interactive = true
    @State private var selected: [String] = []
    @State private var submitting = false
    @State private var problem: String?

    private var coordinator: AgentTaskCoordinator { model.agentTasks }
    private var entries: [ProjectPlanEntry] { model.projectPlan(local: project, graph: graph).all.filter { !$0.isDone && $0.kind == .task } }
    private var info: AgentProviderInfo? { coordinator.providers.first { $0.id == provider } }
    private var localModelProblem: String? {
        guard provider == "lmstudio" else { return nil }
        return info?.models.first { $0.id == modelID }?.problem.flatMap { $0.isEmpty ? nil : $0 }
    }
    private var orderedEntries: [ProjectPlanEntry] {
        selected.compactMap { id in entries.first { $0.id == id } } + entries.filter { !selected.contains($0.id) }
    }
    private var projectRuns: [AgentRunPresentation] { coordinator.runs.filter { $0.request.projectPath == project.url.canonicalPath } }
    private var busyIDs: Set<String> {
        Set(projectRuns.filter { $0.receipt == nil || $0.receipt?.state == "running" }.flatMap { $0.request.tasks.map(\.id) })
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading) {
                    Text("Run tasks with an agent").font(.title2.weight(.semibold))
                    Text(project.displayTitle).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Select tasks").font(.headline)
                    if entries.isEmpty { Text("No open tasks. You can still submit instructions below.").foregroundStyle(.secondary) }
                    ForEach(orderedEntries) { entry in
                        HStack {
                            Toggle(entry.title, isOn: Binding(get: { selected.contains(entry.id) }, set: { value in
                                if value { selected.append(entry.id) } else { selected.removeAll { $0 == entry.id } }
                            }))
                            .disabled(busyIDs.contains(entry.id))
                            .accessibilityIdentifier("agentTasks.task.\(entry.id)")
                            if busyIDs.contains(entry.id) { Text("In a run").font(.caption).foregroundStyle(.secondary) }
                            if sequential, let index = selected.firstIndex(of: entry.id) {
                                Text("\(index + 1)").monospacedDigit().foregroundStyle(.secondary)
                                Button { selected.swapAt(index, index - 1) } label: { Image(systemName: "arrow.up") }
                                    .disabled(index == 0).help("Move task earlier").accessibilityLabel("Move \(entry.title) earlier")
                                Button { selected.swapAt(index, index + 1) } label: { Image(systemName: "arrow.down") }
                                    .disabled(index == selected.count - 1).help("Move task later").accessibilityLabel("Move \(entry.title) later")
                            }
                        }.padding(.vertical, 2)
                    }
                    Toggle("Run sequentially in this order", isOn: $sequential).accessibilityIdentifier("agentTasks.sequential")
                    Text(sequential ? "Each task starts after the previous one succeeds. A blocked task stops the sequence." : "The agent chooses the execution order. Parallel execution is optional.")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("Additional instructions").font(.headline)
                    TextEditor(text: $instructions).font(.body).frame(height: 100)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                        .accessibilityIdentifier("agentTasks.instructions")
                    HStack {
                        Picker("Provider", selection: $provider) {
                            ForEach(["claude", "codex", "antigravity", "lmstudio"], id: \.self) { id in
                                let name = ["claude": "Claude", "codex": "Codex", "antigravity": "Antigravity", "lmstudio": "LM Studio"][id]!
                                let available = coordinator.providers.first { $0.id == id }
                                Text(name + (available?.exhausted == true ? " · some limits reached" : available?.available == false ? " · unavailable" : "")).tag(id)
                            }
                        }.accessibilityIdentifier("agentTasks.provider")
                        Button(coordinator.discovering ? "Checking…" : "Refresh providers") {
                            Task { await coordinator.discover(endpoint: endpoint) }
                        }.disabled(coordinator.discovering)
                    }
                    if provider == "codex" || provider == "lmstudio" {
                        Toggle("Allow network access for project commands", isOn: $networkAccess)
                            .accessibilityIdentifier("agentTasks.network")
                        Text("Enable for package downloads and online checks. File writes remain restricted to the project sandbox.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if provider == "antigravity" {
                        Toggle("Review command approvals in Terminal", isOn: $interactive)
                            .accessibilityIdentifier("agentTasks.interactive")
                        Text(interactive ? "Terminal shows Antigravity’s approval prompts. Approve the requested commands there; verified completion is saved automatically." : "Headless runs cannot ask for approval. Commands without an existing provider allow rule will be blocked.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if let info {
                        Text(info.usage).font(.caption).foregroundStyle(info.exhausted ? .orange : .secondary)
                        if !info.problem.isEmpty { Text(info.problem).font(.caption).foregroundStyle(.orange) }
                        Picker("Model", selection: $modelID) {
                            Text("Provider default").tag("")
                            ForEach(info.models) { Text($0.label).tag($0.id) }
                            if !modelID.isEmpty && !info.models.contains(where: { $0.id == modelID }) { Text(modelID).tag(modelID) }
                        }.accessibilityIdentifier("agentTasks.model")
                    }
                    TextField("Exact model ID (optional)", text: $modelID)
                        .help("Use an exact provider model ID. Names such as Sol High are a model plus a reasoning setting; use the discovered model and High below.")
                    if let localModelProblem { Text(localModelProblem).font(.caption).foregroundStyle(.orange) }
                    if provider != "lmstudio" {
                        Picker("Reasoning effort", selection: $effort) {
                            Text("Provider default").tag("")
                            ForEach(["low", "medium", "high", "xhigh", "max"], id: \.self) { Text($0.capitalized).tag($0) }
                        }
                    } else {
                        TextField("LM Studio endpoint", text: $endpoint)
                        Text("Uses Codex CLI’s local agent tools with the selected LM Studio model. The server must be running. Load the model with at least 32K context for agent tools; nothing is downloaded.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if let problem = problem ?? coordinator.discoveryProblem { Text(problem).foregroundStyle(.red).textSelection(.enabled) }
                    if !projectRuns.isEmpty {
                        Divider()
                        Text("Runs and completion evidence").font(.headline)
                        ForEach(projectRuns) { run in
                            VStack(alignment: .leading, spacing: 5) {
                                HStack {
                                    Text("\(run.request.provider.capitalized) · \(run.receipt?.state ?? "Waiting for Terminal")").font(.headline)
                                    Spacer()
                                    Button("Show run files") { NSWorkspace.shared.open(run.folder) }
                                }
                                Text("\(run.applied.count)/\(run.request.tasks.count) tasks marked complete").font(.caption)
                                if let receipt = run.receipt {
                                    Text(receipt.summary).font(.caption).textSelection(.enabled)
                                    ForEach(receipt.completed, id: \.id) { completion in
                                        Text("\(run.request.tasks.first { $0.id == completion.id }?.title ?? completion.id): \(completion.evidence)")
                                            .font(.caption).textSelection(.enabled)
                                    }
                                }
                                ForEach(run.conflicts.keys.sorted(), id: \.self) { id in Text(run.conflicts[id] ?? "").font(.caption).foregroundStyle(.orange) }
                            }.padding(10).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }
            }
            Divider()
            HStack(alignment: .center) {
                Text("Submit opens Terminal and authorizes project edits. Provider permissions still apply. Only successful task reports are completed locally.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(submitting ? "Submitting…" : "Submit") { submit() }
                    .buttonStyle(.borderedProminent).accessibilityIdentifier("agentTasks.submit")
                    .disabled(submitting || info?.available != true || (selected.isEmpty && instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) || (provider == "lmstudio" && modelID.isEmpty) || localModelProblem != nil)
            }
        }.padding(20).frame(width: 680, height: 460)
            .task { await coordinator.discover(endpoint: endpoint); await coordinator.refresh(model: model) }
            .onChange(of: provider) { _, _ in modelID = ""; effort = "" }
    }
    private func submit() {
        let current = entries
        let tasks = selected.compactMap { id in current.first { $0.id == id }.map { AgentTaskCoordinator.snapshot($0, model: model) } }
        guard tasks.count == selected.count, Set(selected).isDisjoint(with: busyIDs) else { problem = "Selected tasks changed or already have a run. Review the selection."; return }
        submitting = true; problem = nil
        let request = AgentTaskRequest(projectPath: project.url.canonicalPath, provider: provider, model: modelID,
            effort: provider == "lmstudio" ? "" : effort, endpoint: endpoint, sequential: sequential, instructions: instructions, tasks: tasks,
            networkAccess: networkAccess, interactive: interactive)
        Task { @MainActor in
            defer { submitting = false }
            do { try await coordinator.submit(request, model: model); selected = []; instructions = "" }
            catch { problem = error.localizedDescription }
        }
    }
}
