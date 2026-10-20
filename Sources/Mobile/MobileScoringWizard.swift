import SwiftUI
import BetterWorkspaceCore

/// The same rubric and bindings as the form, with room to consider one answer.
struct MobileScoringWizard: View {
    let title: String
    @Binding var ratings: [String: Int]
    let preferences: ProjectScoringPreferences
    @State private var step = 0
    private var score: ProjectScore {
        ProjectScore(ratings: ratings, enabledMetricIDs: preferences.enabledMetricIDs,
            enabledGroups: MetricGroup.allGroups.filter { preferences.enabledGroupIDs.contains($0.id) }, groupWeights: preferences.groupWeights)
    }
    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Text(title).font(.subheadline).foregroundStyle(.secondary)
                    if step < score.activeMetrics.count {
                        let metric = score.activeMetrics[step]
                        ProgressView(value: Double(step), total: Double(max(1, score.activeMetrics.count)))
                        Text("Question \(step + 1) of \(score.activeMetrics.count)").font(.caption).foregroundStyle(.secondary)
                        Text(metric.question).font(.title2.bold()).accessibilityIdentifier("zen.question")
                        ForEach(metric.anchors, id: \.rating) { anchor in
                            Button { ratings[metric.id] = anchor.rating } label: {
                                HStack(alignment: .top, spacing: 14) {
                                    Image(systemName: ratings[metric.id] == anchor.rating ? "checkmark.circle.fill" : "circle").font(.title2)
                                    VStack(alignment: .leading, spacing: 6) {
                                        Text("\(anchor.rating) · \(anchor.label)").font(.headline)
                                        Text(anchor.description).font(.callout).foregroundStyle(.secondary)
                                    }
                                    Spacer(minLength: 0)
                                }.padding().frame(maxWidth: .infinity, alignment: .leading)
                                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 14))
                            }.buttonStyle(.plain).accessibilityIdentifier("zen.rating.\(anchor.rating)")
                                .accessibilityAddTraits(ratings[metric.id] == anchor.rating ? .isSelected : [])
                        }
                        Button("Clear answer") { ratings.removeValue(forKey: metric.id) }.disabled(ratings[metric.id] == nil)
                    } else {
                        Image(systemName: "checkmark.circle").font(.largeTitle).foregroundStyle(.tint)
                        Text("Ready to save").font(.largeTitle.bold())
                        LabeledContent("Score", value: score.projectScore.map { "\(Int($0.rounded()))/100" } ?? "Unrated")
                        LabeledContent("Answered", value: "\(score.answeredCount)/\(score.activeMetrics.count)")
                        Text("Use Save to send your evaluation to the Workspace. You can revisit questions or leave them unrated.").foregroundStyle(.secondary)
                    }
                }.padding(24).frame(maxWidth: 640).frame(maxWidth: .infinity)
            }
            HStack {
                Button("Back", systemImage: "chevron.left") { step = max(0, step - 1) }.disabled(step == 0)
                Spacer()
                if step < score.activeMetrics.count {
                    Button(ratings[score.activeMetrics[step].id] == nil ? "Skip" : "Next", systemImage: "chevron.right") { step += 1 }
                        .buttonStyle(.borderedProminent).accessibilityIdentifier("zen.next")
                }
            }.padding().background(.bar)
        }
    }
}
