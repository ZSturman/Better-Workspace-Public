import SwiftUI
import Charts
import BetterWorkspaceCore

struct MobileProjectAssessmentView: View {
    @Environment(MobileWorkspaceModel.self) private var model
    let project: MobileWorkspaceEntry
    @State private var expanded = Set<String>()
    @State private var selectedScore = "FunctionalHealth"
    @State private var audience = WorkActionAudience.all
    @State private var capability = "All capabilities"
    @State private var readiness = "All"
    private var current: MobileWorkspaceEntry { model.snapshot.entries.first { $0.id == project.id } ?? project }
    private var open: [MobileWorkItem] { model.allWorkItems(forProjectPath: project.path).filter { $0.status != .completed } }
    private func dependencies(_ item: MobileWorkItem) -> [String] {
        let completed = Set(model.snapshot.workItems.filter { $0.status == .completed }.flatMap { [$0.id, $0.importedNotionPageID].compactMap { $0 } })
        return (item.dependencyIDs ?? []).filter { !completed.contains($0) }
    }
    private func matches(_ item: MobileWorkItem) -> Bool {
        let meta = item.actionMetadata
        if capability != "All capabilities", meta?.requirements.contains(capability) != true { return false }
        if audience == .agent, meta?.isAgentReady != true { return false }
        if audience == .user, meta?.needsUser != true { return false }
        switch readiness {
        case "Agent ready": return meta?.isAgentReady == true && dependencies(item).isEmpty
        case "Needs you": return meta?.needsUser == true
        case "Blocked": return !(meta?.blockedBy.isEmpty ?? true) || !dependencies(item).isEmpty
        default: return true
        }
    }
    private var backlog: [MobileWorkItem] {
        open.filter(matches).sorted {
            let a = $0.actionMetadata?.actionScore ?? -1, b = $1.actionMetadata?.actionScore ?? -1
            return a != b ? a > b : $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
    }
    var body: some View {
        List {
            Section("Assessment") {
                if let audit = current.projectDetails?.assessment {
                    Text(audit.classification).font(.headline)
                    LabeledContent("Work priority", value: "\(audit.workPriorityScore)/100")
                    ProgressView(value: Double(audit.workPriorityScore), total: 100)
                    Text(audit.recommendation)
                    Text("\(audit.validationCoverage) · \(audit.confidence) confidence · Assessed \(audit.assessedAt.prefix(10))")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("Select a score. Higher is better except Technical Risk.").font(.caption).foregroundStyle(.secondary)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 135))], spacing: 10) {
                        ForEach(audit.scores.keys.sorted(), id: \.self) { key in
                            Button { selectedScore = key } label: {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(ProjectAssessmentScore.name(key)).font(.caption.weight(.semibold))
                                    Text("\(audit.scores[key] ?? 0)/10").font(.headline.monospacedDigit())
                                    ProgressView(value: Double(audit.scores[key] ?? 0), total: 10)
                                        .tint(key == "TechnicalRisk" ? .orange : .accentColor)
                                }.frame(maxWidth: .infinity, alignment: .leading).padding(10)
                                    .background((key == selectedScore ? Color.accentColor : Color.secondary).opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
                            }.buttonStyle(.plain).accessibilityIdentifier("project.audit.score." + key)
                                .accessibilityAddTraits(key == selectedScore ? .isSelected : [])
                        }
                    }
                    Text(ProjectAssessmentScore.explanation(selectedScore))
                        .font(.callout).accessibilityIdentifier("project.audit.scoreExplanation")
                } else {
                    Text("No assessment in this Mac snapshot. Assess the project on the Mac, then sync and refresh here.").foregroundStyle(.secondary)
                }
            }
            Section("Next actions") {
                ForEach([WorkActionAudience.all, .agent, .user], id: \.rawValue) { owner in
                    if let item = WorkItemRecommendation.nextMobileAction(in: model.allWorkItems(forProjectPath: project.path), allItems: model.snapshot.workItems, audience: owner) {
                        NavigationLink(value: item) {
                            VStack(alignment: .leading, spacing: 5) {
                                Label(owner == .all ? "Next work" : owner == .agent ? "Next agent action" : "Next user action", systemImage: owner == .agent ? "cpu" : owner == .user ? "person" : "arrow.right.circle")
                                    .font(.caption).foregroundStyle(.secondary)
                                Text(owner == .agent ? item.actionMetadata?.agentSubtasks.first ?? item.title : owner == .user ? item.actionMetadata?.userSubtasks.first ?? item.title : item.title)
                            }
                        }
                    } else { Text(owner == .all ? "No actionable work established yet." : owner == .agent ? "No independently actionable agent work established yet." : "No separate personal action established yet.").font(.caption).foregroundStyle(.secondary) }
                }
            }
            Section("Ranked backlog · \(backlog.count) of \(open.count) open") {
                Text("Highest action score first. Expand an action for reasoning and evidence; open it to work on it.").font(.caption).foregroundStyle(.secondary)
                Picker("Owner", selection: $audience) {
                    Text("Everyone").tag(WorkActionAudience.all); Text("Agent").tag(WorkActionAudience.agent); Text("You").tag(WorkActionAudience.user)
                }
                Picker("Capability", selection: $capability) {
                    Text("All capabilities").tag("All capabilities")
                    ForEach(Array(Set(open.flatMap { $0.actionMetadata?.requirements ?? [] })).sorted(), id: \.self) { Text($0).tag($0) }
                }
                Picker("Readiness", selection: $readiness) {
                    ForEach(["All", "Agent ready", "Needs you", "Blocked"], id: \.self) { Text($0).tag($0) }
                }.accessibilityIdentifier("project.audit.readiness")
                if backlog.isEmpty { Text("No open actions match these filters.").foregroundStyle(.secondary) }
                ForEach(Array(backlog.enumerated()), id: \.element.id) { rank, item in
                    VStack(alignment: .leading, spacing: 8) {
                        Text("#\(rank + 1) · \(item.title)").font(.headline)
                        if let meta = item.actionMetadata {
                            let blocked = !meta.blockedBy.isEmpty || !dependencies(item).isEmpty
                            Text("\(meta.priority) · \(meta.delegation) · \(meta.estimatedEffort)").font(.caption).foregroundStyle(.secondary)
                            HStack { ProgressView(value: Double(meta.actionScore), total: 100).tint(blocked ? .orange : .accentColor); Text("\(meta.actionScore)/100").font(.caption.monospacedDigit()) }
                            Text(blocked ? "Blocked · " + (meta.blockedBy + dependencies(item)).joined(separator: "; ") : meta.isAgentReady ? "Agent ready" : meta.needsUser ? "Needs your input" : "Review readiness")
                                .font(.caption).foregroundStyle(blocked ? .orange : .secondary)
                            Button(expanded.contains(item.id) ? "Hide details" : "Why this action?") {
                                if !expanded.insert(item.id).inserted { expanded.remove(item.id) }
                            }.accessibilityIdentifier("project.audit.expand." + item.id)
                            if expanded.contains(item.id) { VStack(alignment: .leading, spacing: 6) {
                                Text(meta.reason).accessibilityIdentifier("project.audit.reason." + item.id)
                                Text("Requires: " + (meta.requirements.isEmpty ? "No listed capabilities" : meta.requirements.joined(separator: ", ")))
                                Text("Agent executability \(meta.agentExecutability)% · Human involvement \(meta.humanInvolvement)%")
                                ForEach(meta.agentSubtasks, id: \.self) { Label($0, systemImage: "cpu") }
                                ForEach(meta.userSubtasks, id: \.self) { Label($0, systemImage: "person") }
                                Text("Evidence: " + meta.evidence.joined(separator: "; ")).foregroundStyle(.secondary)
                            }.font(.caption) }
                        } else { Text("No action score recorded; ranked after scored work.").font(.caption).foregroundStyle(.secondary) }
                        NavigationLink("Open action", value: item).accessibilityIdentifier("project.audit.open." + item.id)
                    }.padding(.vertical, 4)
                }
            }
        }.buttonStyle(.borderless).navigationTitle("Assessment & backlog")
    }
}

struct MobileProjectInsightsView: View {
    @Environment(MobileWorkspaceModel.self) private var model
    let project: MobileWorkspaceEntry
    @State private var selectedWeek: Date?
    private var items: [MobileWorkItem] { model.allWorkItems(forProjectPath: project.path) }
    private var recorded: [WorkItem] {
        model.macWorkItems.filter { $0.projectPath == project.path }.map {
            WorkItem(id: $0.id, kind: $0.kind, title: $0.title, status: $0.status, stage: $0.stage, priority: $0.priority,
                     completedAt: $0.completedAt, url: URL(fileURLWithPath: "/mobile-projection/" + $0.id),
                     createdAt: $0.createdAt, modifiedAt: $0.modifiedAt)
        }
    }
    var body: some View {
        let progress = ProjectProgress.make(recorded)
        let dated = recorded.contains { $0.createdAt != nil || $0.modifiedAt != nil || $0.completedAt != nil }
        List {
            Section {
                WorkProgressStrip(counts: WorkProgressCounts(items))
                Text("Counts include pending phone edits. History uses the last confirmed Mac snapshot, received \(model.snapshot.fetchedAt.formatted(date: .abbreviated, time: .shortened)).")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Progress over time") {
                if dated {
                    Text("Recorded work · last 12 weeks. Bars show weekly completions; the line shows open items. Touch the chart to inspect a week.").font(.caption).foregroundStyle(.secondary)
                    Chart {
                        ForEach(progress.weeks) { week in
                            BarMark(x: .value("Week", week.start, unit: .weekOfYear), y: .value("Completed", week.completed))
                                .foregroundStyle(by: .value("Series", "Completed that week"))
                            LineMark(x: .value("Week", week.start, unit: .weekOfYear), y: .value("Open", week.open))
                                .foregroundStyle(by: .value("Series", "Open")).symbol(.circle)
                        }
                    }.chartForegroundStyleScale(["Open": Color.accentColor, "Completed that week": .green])
                        .chartXSelection(value: $selectedWeek).frame(height: 220).accessibilityIdentifier("project.insights.history")
                    if let selectedWeek, let week = progress.weeks.min(by: { abs($0.start.timeIntervalSince(selectedWeek)) < abs($1.start.timeIntervalSince(selectedWeek)) }) {
                        Text("Week of \(week.start.formatted(date: .abbreviated, time: .omitted)): \(week.completed) completed · \(week.open) open · \(week.created) created")
                    }
                } else { Text("Recorded dates are not available in this snapshot. Sync from the updated Mac app, then refresh. No history or finish date is invented.").foregroundStyle(.secondary) }
            }
            Section {
                DisclosureGroup("What if the recent pace continues?") {
                    if dated, let estimate = progress.forecast {
                        Text("Rough estimate: " + estimate.finish.formatted(date: .abbreviated, time: .omitted)).font(.headline)
                        Text("\(estimate.remaining) open items ÷ " + String(format: "%.2f", estimate.weeklyRate) + " completions per week ≈ " + String(format: "%.1f", Double(estimate.remaining) / estimate.weeklyRate) + " weeks from today.")
                        Text("Pace averages six calendar weeks, including this partial week. Assumes no new work, similar item sizes and the same pace. Effort, dependencies and availability are not included; this is not a deadline.")
                    } else { Text("No recent recorded completions or nothing open to estimate.") }
                }.font(.caption).accessibilityIdentifier("project.insights.estimate")
            }
            Section("Work by type") {
                Chart(WorkItemKind.allCases, id: \.self) { kind in
                    ForEach(WorkItemStatus.allCases, id: \.self) { status in
                        BarMark(x: .value("Count", items.filter { $0.kind == kind && $0.status == status }.count), y: .value("Type", kind.displayName))
                            .foregroundStyle(by: .value("Status", status.displayName))
                    }
                }.chartForegroundStyleScale(["Open": Color.accentColor, "In Progress": .orange, "Completed": .green])
                    .frame(height: 180).accessibilityIdentifier("project.insights.types")
            }
            Section("Open work by stage") {
                Chart(WorkItemStage.allCases, id: \.self) { stage in
                    BarMark(x: .value("Stage", stage.displayName), y: .value("Open", items.filter { $0.status != .completed && $0.stage == stage }.count))
                }.frame(height: 170).accessibilityIdentifier("project.insights.stages")
            }
            Section { Text("Work Log and service measurement charts require the Mac's local records and are available in Mac Insights.").font(.caption).foregroundStyle(.secondary) }
        }.navigationTitle("Insights")
    }
}

#if DEBUG
/// Isolated UI fixture; never published or applied to the person's workspace.
enum MobileParityFixture {
    static let assessment = try! JSONDecoder().decode(MobileProjectAssessment.self, from: Data(#"{"assessedAt":"2026-10-09T12:00:00Z","classification":"Active project","recommendation":"Clarify the next screen before expanding scope.","scores":{"FunctionalHealth":7,"Maintainability":8,"TestConfidence":6,"Documentation":7,"Completion":6,"CurrentUtility":8,"Uniqueness":7,"FuturePotential":8,"EaseOfProgress":9,"TechnicalRisk":3},"workPriorityScore":88,"validationCoverage":"Targeted tests","confidence":"Medium"}"#.utf8))
    static let action = try! JSONDecoder().decode(WorkItemActionMetadata.self, from: Data(#"{"version":1,"fingerprint":"fixture","priority":"P1","actionScore":88,"delegation":"AGENT","tags":["Design"],"requirements":["SwiftUI"],"agentExecutability":90,"humanInvolvement":10,"estimatedEffort":"Small","category":"UI","reason":"The empty state needs a clear next action.","evidence":["Existing screen review"],"agentSubtasks":["Sketch the empty state"],"userSubtasks":[],"blockedBy":[],"isNextWork":true,"isNextAgentAction":true,"isNextUserAction":false}"#.utf8))
}
#endif
