import SwiftUI
import BetterWorkspaceCore

/// Rating a project, one question at a time.
///
/// Twenty-one metrics is a lot to answer in a grid of dropdowns, which is why almost
/// nothing in the portfolio has ever been rated. So this asks one question, shows what
/// each of the five answers would *mean* for that particular metric, and takes a single
/// keystroke: 1–5 answers and moves on, ← → step, ⌫ clears, Esc leaves.
///
/// Nothing here is mandatory. Every metric can be skipped, and a skipped metric stays
/// genuinely unanswered rather than defaulting to the middle — the score already knows
/// how to discount a thinly rated project.
struct RatingSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let record: ProjectRecord

    @State private var index = 0
    @FocusState private var focused: Bool

    private var metrics: [MetricDefinition] { MetricDefinition.all }
    private var metric: MetricDefinition { metrics[min(index, metrics.count - 1)] }
    private var group: MetricGroup? { MetricGroup.find(id: metric.groupID) }
    private var ratings: [String: Int] { model.ratingsByProject[record.id] ?? [:] }
    private var current: Int? { ratings[metric.id] }
    private var score: ProjectScore { ProjectScore(ratings: ratings) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            question
            Divider()
            footer
        }
        .frame(width: 560)
        .background(Color(nsColor: .windowBackgroundColor))
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onAppear { focused = true }
        .onKeyPress { press in handle(press) }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: Theme.Space.tight) {
            HStack(alignment: .firstTextBaseline) {
                Text(record.name)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
                Spacer(minLength: Theme.Space.tight)
                Text("\(score.answeredCount) of \(metrics.count) answered")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }
            ProgressView(value: Double(score.answeredCount), total: Double(metrics.count))
                .progressViewStyle(.linear)
        }
        .padding(.horizontal, Theme.Space.base)
        .padding(.vertical, Theme.Space.snug)
    }

    // MARK: - The question

    private var question: some View {
        VStack(alignment: .leading, spacing: Theme.Space.snug) {
            HStack(spacing: Theme.Space.tight) {
                if let group {
                    Text(group.displayName.uppercased())
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.tint)
                }
                Text(metric.direction.shortLabel)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Color.secondary.opacity(0.14), in: Capsule())
                    .help(metric.direction.explanation)
                Spacer()
                Text("\(index + 1) / \(metrics.count)")
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(.tertiary)
            }

            Text(metric.displayName).font(.system(size: 17, weight: .semibold))
            Text(metric.question)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 3) {
                ForEach(metric.anchors, id: \.rating) { anchor in
                    answerRow(anchor)
                }
            }
            .padding(.top, Theme.Space.hair)
        }
        .padding(.horizontal, Theme.Space.base)
        .padding(.vertical, Theme.Space.snug)
    }

    private func answerRow(_ anchor: RatingAnchor) -> some View {
        let selected = current == anchor.rating
        return Button {
            answer(anchor.rating)
        } label: {
            HStack(alignment: .top, spacing: Theme.Space.snug) {
                Text("\(anchor.rating)")
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundStyle(selected ? Color.white : .secondary)
                    .frame(width: 18, height: 18)
                    .background(selected ? Color.accentColor : Color.secondary.opacity(0.14), in: Circle())
                VStack(alignment: .leading, spacing: 1) {
                    Text(anchor.label).font(.system(size: 12, weight: selected ? .semibold : .regular))
                    Text(anchor.description)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Theme.Space.tight)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? Color.accentColor.opacity(0.12) : Color.clear,
                        in: RoundedRectangle(cornerRadius: Theme.Radius.chip))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("rating.\(metric.id).\(anchor.rating)")
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: Theme.Space.tight) {
            Button { step(-1) } label: { Image(systemName: "chevron.left") }
                .disabled(index == 0)
            Button { step(1) } label: { Image(systemName: "chevron.right") }
                .disabled(index >= metrics.count - 1)

            Button("Clear") { answer(nil, advance: false) }
                .disabled(current == nil)

            Spacer()

            if let projectScore = score.projectScore {
                VStack(alignment: .trailing, spacing: 0) {
                    Text("\(Int(projectScore.rounded()))")
                        .font(.system(size: 15, weight: .semibold).monospacedDigit())
                    Text("project score").font(.system(size: 9)).foregroundStyle(.secondary)
                }
                .help("The weighted rating, discounted by how much you have answered")
            }

            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, Theme.Space.base)
        .padding(.vertical, Theme.Space.snug)
    }

    // MARK: - Behaviour

    private func answer(_ value: Int?, advance: Bool = true) {
        model.setRating(value, metric: metric, for: record)
        if advance, index < metrics.count - 1 { index += 1 }
    }

    private func step(_ delta: Int) {
        index = min(max(index + delta, 0), metrics.count - 1)
    }

    private func handle(_ press: KeyPress) -> KeyPress.Result {
        switch press.key {
        case "1", "2", "3", "4", "5":
            answer(Int(String(press.characters)) ?? nil)
            return .handled
        case .leftArrow, .upArrow: step(-1); return .handled
        case .rightArrow, .downArrow, .space: step(1); return .handled
        case .delete, .deleteForward: answer(nil, advance: false); return .handled
        case .escape: dismiss(); return .handled
        default: return .ignored
        }
    }
}
