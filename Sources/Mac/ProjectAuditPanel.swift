import SwiftUI
import BetterWorkspaceCore

struct ProjectAuditPanel: View {
    @Environment(AppModel.self) private var model
    let project: WorkspaceItem
    @State private var audience = WorkActionAudience.all
    @State private var requirement = "All capabilities"
    @State private var availability = "All"
    @State private var selectedScore = "FunctionalHealth"
    @State private var expandedItems = Set<String>()

    var body: some View {
        if let audit = model.projectAudit(for: project) {
            VStack(alignment: .leading, spacing: 14) {
                Text("WORKSPACE AUDIT").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                HStack {
                    Text(audit.classification).font(.headline)
                    Spacer()
                    Text("Work priority \(audit.workPriorityScore)/100").font(.subheadline.monospacedDigit())
                }
                ProgressView(value: Double(audit.workPriorityScore), total: 100).tint(.accentColor)
                    .accessibilityLabel("Work priority \(audit.workPriorityScore) out of 100")
                Text(audit.recommendation)
                Text("\(audit.validationCoverage) · \(audit.confidence) confidence · Assessed \(audit.assessedAt.prefix(10))")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Select a score to understand it. Scores run from 1–10; higher is better except Technical Risk.")
                    .font(.caption).foregroundStyle(.secondary)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 145))], alignment: .leading, spacing: 8) {
                    ForEach(audit.scores.keys.sorted(), id: \.self) { key in scoreTile(key, value: audit.scores[key] ?? 0) }
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(ProjectAssessmentScore.name(selectedScore)).font(.subheadline.weight(.semibold))
                    Text(ProjectAssessmentScore.explanation(selectedScore)).font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(10)
                    .background(Color.accentColor.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                    .accessibilityIdentifier("project.audit.scoreExplanation")
                ForEach([WorkActionAudience.all, .agent, .user], id: \.rawValue) { owner in
                    if let action = model.projectNextAction(for: project, audience: owner) {
                        Button { model.inspect(workItem: action) } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Label(owner == .all ? "NEXT WORK" : owner == .agent ? "NEXT AGENT ACTION" : "NEXT USER ACTION",
                                      systemImage: owner == .agent ? "cpu" : owner == .user ? "person" : "arrow.right.circle")
                                    .font(.caption.weight(.semibold))
                                Text(actionText(action, owner: owner)).font(.headline)
                                if let meta = action.actionMetadata { Text("\(meta.priority) · \(meta.delegation) · \(meta.estimatedEffort)").font(.caption).foregroundStyle(.secondary) }
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(10)
                        }.buttonStyle(.plain).background(Color.accentColor.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                    } else if owner != .all {
                        Text(owner == .agent ? "No independently actionable agent work is established yet." : "No separate personal action is established yet.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                if !audit.notes.isEmpty || !audit.commands.isEmpty {
                    DisclosureGroup("Assessment notes & validation commands") {
                        ForEach(audit.notes.indices, id: \.self) { index in Text(audit.notes[index]).font(.caption) }
                        ForEach(audit.commands.indices, id: \.self) { index in Text(audit.commands[index]).font(.caption.monospaced()).textSelection(.enabled) }
                    }
                }
                Divider()
                HStack { Text("Ranked backlog").font(.headline); Spacer(); Text("\(backlog.count) of \(openItems.count) open").font(.caption).foregroundStyle(.secondary) }
                Text("Highest action score first. Expand an action for its reasoning and evidence, or open it to work on it.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Picker("Owner", selection: $audience) { Text("Everyone").tag(WorkActionAudience.all); Text("Agent").tag(WorkActionAudience.agent); Text("You").tag(WorkActionAudience.user) }.accessibilityLabel("Owner").frame(maxWidth: .infinity)
                    Picker("Capability", selection: $requirement) { Text("All capabilities").tag("All capabilities"); ForEach(requirements, id: \.self) { Text($0).tag($0) } }.frame(maxWidth: .infinity)
                }
                HStack {
                    ForEach(["All", "Agent ready", "Needs you", "Blocked"], id: \.self) { filter in
                        Button { availability = filter } label: {
                            Text(filter + " · " + String(openItems.filter { matchesAvailability($0, filter: filter) }.count))
                                .font(.caption.weight(availability == filter ? .semibold : .regular))
                                .padding(.horizontal, 9).padding(.vertical, 6)
                                .background(availability == filter ? Color.accentColor.opacity(0.16) : Color.primary.opacity(0.04), in: Capsule())
                        }.buttonStyle(.plain).accessibilityAddTraits(availability == filter ? .isSelected : [])
                            .accessibilityIdentifier("project.audit.filter." + filter)
                    }
                }
                if backlog.isEmpty { Text("No open actions match these filters.").font(.callout).foregroundStyle(.secondary) }
                ForEach(Array(backlog.enumerated()), id: \.element.id) { rank, item in backlogCard(item, rank: rank + 1) }
            }.padding(16).background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 12))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("project.audit.panel")
        }
    }

    private func scoreTile(_ key: String, value: Int) -> some View {
        let color: Color = key == "TechnicalRisk" ? (value >= 7 ? .orange : .blue) : (value <= 3 ? .orange : .accentColor)
        return Button { selectedScore = key } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack { Text(ProjectAssessmentScore.name(key)).font(.caption); Spacer(minLength: 2); if selectedScore == key { Image(systemName: "checkmark.circle.fill").font(.caption).foregroundStyle(color) } }
                Text("\(value)/10").font(.title3.weight(.semibold).monospacedDigit())
                ProgressView(value: Double(value), total: 10).tint(color)
                Text(key == "TechnicalRisk" ? "Higher = more risk" : "Higher = better").font(.caption2).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(10)
                .background(color.opacity(selectedScore == key ? 0.12 : 0.04), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(selectedScore == key ? color : .clear, lineWidth: 1.5))
        }.buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(ProjectAssessmentScore.name(key))
            .accessibilityValue("\(value) out of 10. " + (key == "TechnicalRisk" ? "Higher means more risk" : "Higher is better"))
            .accessibilityAddTraits(.isButton)
            .accessibilityIdentifier("project.audit.score." + key)
            .accessibilityAddTraits(selectedScore == key ? .isSelected : [])
    }

    private func backlogCard(_ item: WorkItem, rank: Int) -> some View {
        let meta = item.actionMetadata
        let blocked = !(meta?.blockedBy.isEmpty ?? true) || !unresolvedDependencies(item).isEmpty
        let color: Color = blocked ? .orange : meta?.priority == "P0" ? .red : .accentColor
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                Text("#\(rank)").font(.headline.monospacedDigit()).foregroundStyle(color).frame(width: 32)
                VStack(alignment: .leading, spacing: 5) {
                    Text(item.title).font(.subheadline.weight(.semibold))
                    Text(item.stage.displayName + " · " + (meta?.delegation ?? "Unspecified owner") + " · " + (meta?.estimatedEffort ?? "Effort unknown"))
                        .font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading)
                Text(item.actionPriorityLabel).font(.caption.weight(.semibold)).padding(5).background(color.opacity(0.12), in: Capsule())
            }
            if let meta {
                HStack { ProgressView(value: Double(meta.actionScore), total: 100).tint(color); Text("\(meta.actionScore)/100").font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
                Text(blocked ? "Blocked · " + (meta.blockedBy + unresolvedDependencies(item)).joined(separator: "; ") : meta.isAgentReady ? "Agent ready" : meta.needsUser ? "Needs your input" : "Review readiness")
                    .font(.caption.weight(.medium)).foregroundStyle(blocked ? .orange : .secondary)
            }
            HStack {
                Button(expandedItems.contains(item.id) ? "Hide details" : "Why this action?") {
                    if !expandedItems.insert(item.id).inserted { expandedItems.remove(item.id) }
                }.accessibilityIdentifier("project.audit.expand." + item.id)
                Spacer()
                Button("Open action") { model.inspect(workItem: item) }.accessibilityIdentifier("project.audit.open." + item.id)
            }.font(.caption).buttonStyle(.borderless)
            if expandedItems.contains(item.id), let meta {
                Divider()
                Text(meta.reason).font(.callout)
                Text("Requires: " + (meta.requirements.isEmpty ? "No listed capabilities" : meta.requirements.joined(separator: ", "))).font(.caption)
                Text("Tags: " + meta.tags.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary)
                Text("Agent executability \(meta.agentExecutability)% · Human involvement \(meta.humanInvolvement)%").font(.caption)
                ForEach(meta.agentSubtasks.indices, id: \.self) { index in Label(meta.agentSubtasks[index], systemImage: "cpu").font(.caption) }
                ForEach(meta.userSubtasks.indices, id: \.self) { index in Label(meta.userSubtasks[index], systemImage: "person").font(.caption) }
                Text("Evidence: " + meta.evidence.joined(separator: "; ")).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }.padding(12).background(color.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(color.opacity(0.18)))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("project.audit.action." + item.id)
    }
    private var openItems: [WorkItem] { model.projectWorkItems(for: project).filter(\.isOpen) }
    private func unresolvedDependencies(_ item: WorkItem) -> [String] {
        let completed = Set(model.workItems.filter { !$0.isOpen }.flatMap { [$0.id, $0.importedNotionPageID].compactMap { $0 } })
        return item.dependencyIDs.filter { !completed.contains($0) }
    }
    private var requirements: [String] { Array(Set(openItems.flatMap { $0.actionMetadata?.requirements ?? [] })).sorted() }
    private func matchesAvailability(_ item: WorkItem, filter: String) -> Bool {
        switch filter {
        case "Agent ready": return item.actionMetadata?.isAgentReady == true && unresolvedDependencies(item).isEmpty
        case "Needs you": return item.actionMetadata?.needsUser == true
        case "Blocked": return !(item.actionMetadata?.blockedBy.isEmpty ?? true) || !unresolvedDependencies(item).isEmpty
        default: return true
        }
    }
    private var backlog: [WorkItem] {
        openItems.filter { item in
            guard matchesAvailability(item, filter: availability) else { return false }
            if requirement != "All capabilities", !(item.actionMetadata?.requirements.contains(requirement) ?? false) { return false }
            switch audience { case .all: return true; case .agent: return item.actionMetadata?.isAgentReady == true; case .user: return item.actionMetadata?.needsUser == true }
        }.sorted { a, b in
            let left = a.actionMetadata?.actionScore ?? -1, right = b.actionMetadata?.actionScore ?? -1
            if left != right { return left > right }
            return a.title.localizedStandardCompare(b.title) == .orderedAscending
        }
    }
    private func actionText(_ item: WorkItem, owner: WorkActionAudience) -> String {
        if owner == .agent { return item.actionMetadata?.agentSubtasks.first ?? item.title }
        if owner == .user { return item.actionMetadata?.userSubtasks.first ?? item.title }
        return item.title
    }
}

/// The ordinary single-selection inspector uses the same assessment and
/// recommendations as the full project workspace.
struct ProjectAuditInspectorSummary: View {
    @Environment(AppModel.self) private var model
    let project: WorkspaceItem
    var body: some View {
        if let audit = model.projectAudit(for: project) {
            VStack(alignment: .leading, spacing: 10) {
                Text(audit.classification).font(.headline)
                Text("Health \(audit.scores["FunctionalHealth"] ?? 0)/10 · Work priority \(audit.workPriorityScore)/100").font(.caption)
                Text(audit.validationCoverage).font(.caption).foregroundStyle(.secondary)
                ForEach([WorkActionAudience.all, .agent, .user], id: \.rawValue) { owner in
                    if let item = model.projectNextAction(for: project, audience: owner) {
                        Button { model.inspect(workItem: item) } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(owner == .all ? "NEXT WORK" : owner == .agent ? "NEXT AGENT ACTION" : "NEXT USER ACTION").font(.caption.weight(.semibold))
                                Text(owner == .agent ? item.actionMetadata?.agentSubtasks.first ?? item.title : owner == .user ? item.actionMetadata?.userSubtasks.first ?? item.title : item.title).font(.callout).lineLimit(4)
                                Text(item.actionPriorityLabel + " · " + (item.actionMetadata?.delegation ?? "Unspecified owner")).font(.caption).foregroundStyle(.secondary)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }.buttonStyle(.plain)
                    }
                }
                Button("Open assessment and backlog") { model.openProjectWorkspace(for: project) }.buttonStyle(.bordered)
            }.padding(10).background(Color.accentColor.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
            .accessibilityIdentifier("project.audit.inspector")
        }
    }
}
