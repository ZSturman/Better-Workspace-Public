import SwiftUI
import BetterWorkspaceCore

/// One rubric on Mac and mobile. Potential type is a label, never a move action.
struct IdeaPlanningForm: View {
    @Binding var planning: IdeaPlanning
    let preferences: ProjectScoringPreferences
    var projectOptions: [String: [String]] = [:]
    var choiceDefaults: UserDefaults? = nil
    @State private var showingRatings = false
    var body: some View {
        let score = planning.score(preferences: preferences)
        Form {
            Section("What this idea could become") {
                Picker("Potential", selection: $planning.potential) {
                    Text("Unclassified").tag(IdeaPromotionKind?.none)
                    ForEach(IdeaPromotionKind.allCases) { kind in Text("Potential " + kind.title).tag(Optional(kind)) }
                }.accessibilityIdentifier("idea.planning.potential").accessibilityHint("Classification keeps the item in Ideas. Promotion requires a separate confirmation to move its complete folder.")
                Picker("Priority", selection: $planning.priority) {
                    ForEach(1...5, id: \.self) { Text("\($0) · \($0 == 5 ? "Highest" : $0 == 1 ? "Lowest" : "Priority")").tag($0) }
                }.accessibilityIdentifier("idea.planning.priority")
            }
            Section("Classification") {
                    projectProperty("Domain", keyPath: \.domain, optionKey: "domain")
                    projectProperty("Type", keyPath: \.projectType, optionKey: "Type")
                    projectProperty("Status", keyPath: \.status, optionKey: "Status")
                    projectProperty("Phase", keyPath: \.phase, optionKey: "Phase")
            }
            if planning.potential == .project {
                Section("Potential project") {
                    LabeledContent("One-liner") {
                        TextField("One-liner", text: Binding(get: { planning.project?.oneLiner ?? "" }, set: { ensureProject(); planning.project?.oneLiner = $0 }), prompt: Text("What it is, in a sentence"))
                            .labelsHidden().multilineTextAlignment(.trailing)
                            .accessibilityIdentifier("idea.project.oneLiner")
                    }
                    DisclosureGroup("Summary & synchronization") {
                        TextField("Summary", text: Binding(get: { planning.project?.summary ?? "" }, set: { ensureProject(); planning.project?.summary = $0 }), axis: .vertical).lineLimit(3...8)
                            .accessibilityIdentifier("idea.project.summary")
                        Toggle("Sync to Notion Projects as Idea", isOn: Binding(get: { planning.project?.automaticNotionSync ?? true }, set: { ensureProject(); planning.project?.automaticNotionSync = $0 }))
                        Text("When Notion is connected, saving queues these details and this idea’s actual directory. Local changes are kept if sync fails. A status change in Notion offers a reviewed move; it never moves files automatically.").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Section("Your evaluation") {
                LabeledContent("Score", value: score.projectScore.map { "\(Int($0.rounded()))/100" } ?? "Unrated")
                LabeledContent("Answered", value: "\(score.answeredCount)/\(score.activeMetrics.count)")
                Text("Priority comes first, then your score. Cost and risk ratings lower the score; missing answers reduce its confidence.").font(.caption).foregroundStyle(.secondary)
            }
            DisclosureGroup("Project ratings", isExpanded: $showingRatings) {
            ForEach(score.enabledGroups) { group in
                Section(group.displayName) {
                    ForEach(group.metrics.filter { score.enabledMetricIDs.contains($0.id) }) { metric in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(metric.question).font(.subheadline)
                            Picker(metric.displayName, selection: Binding(get: { planning.ratings[metric.id] ?? 0 }, set: { value in
                                if value == 0 { planning.ratings.removeValue(forKey: metric.id) } else { planning.ratings[metric.id] = value }
                            })) {
                                Text("Unrated").tag(0)
                                ForEach(metric.anchors, id: \.rating) { anchor in Text("\(anchor.rating) · \(anchor.label)").tag(anchor.rating) }
                            }.accessibilityIdentifier("idea.planning." + metric.id)
                            if let value = planning.ratings[metric.id], let anchor = metric.anchor(for: value) {
                                Text(anchor.description).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            }
        }.formStyle(.grouped)
    }
    private func ensureProject() { if planning.project == nil { planning.project = .init() } }
    private func projectProperty(_ title: String, keyPath: WritableKeyPath<ProjectMetadata, String?>, optionKey: String) -> some View {
        WorkspaceChoiceField(title, selection: Binding(
            get: { planning.project?.metadata[keyPath: keyPath] ?? "" },
            set: { ensureProject(); planning.project?.metadata[keyPath: keyPath] = $0.isEmpty ? nil : $0 }),
            suggestions: projectOptions[optionKey] ?? [], identifier: "idea.project." + optionKey, store: choiceDefaults)
    }
}
