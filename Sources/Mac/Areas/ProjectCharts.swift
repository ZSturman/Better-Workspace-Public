import SwiftUI
import Charts
import BetterWorkspaceCore

// Swift Charts over data the app already has: work records (their own dates and
// statuses), the background service's measurements and Work Log, and project scores.
// Nothing is stored for these charts; every view recomputes from the current state.

/// Restrained slate, ochre and teal, stepped separately for light and dark surfaces.
/// Checked for colour-blind separation and contrast; legends carry the names too.
private enum ChartPalette {
    static let open = adaptive(light: 0x4a6cb0, dark: 0x6688cc)
    static let inProgress = adaptive(light: 0xb8741a, dark: 0xc0801f)
    static let done = adaptive(light: 0x1f8a6c, dark: 0x24997a)
    private static func adaptive(light: Int, dark: Int) -> Color {
        func color(_ hex: Int) -> NSColor { NSColor(srgbRed: CGFloat(hex >> 16 & 0xff) / 255, green: CGFloat(hex >> 8 & 0xff) / 255, blue: CGFloat(hex & 0xff) / 255, alpha: 1) }
        return Color(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? color(dark) : color(light) })
    }
}

private struct ChartCard<Content: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            if let subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary) }
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct ChartEmpty: View {
    let text: String
    var body: some View {
        Text(text).font(.callout).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 80, alignment: .center)
            .multilineTextAlignment(.center)
    }
}

// MARK: - One project

/// Projects → a project → Insights: recorded progress and an optional pace estimate, how the work
/// is made up, and what the Work Log recorded.
struct ProjectInsightsView: View {
    @Environment(AppModel.self) private var model
    let project: WorkspaceItem
    @State private var showPaceEstimate = false

    private struct KindCount: Identifiable { let kind: String; let status: String; let count: Int; var id: String { kind + status } }
    private struct StageCount: Identifiable { let stage: String; let priority: String; let count: Int; var id: String { stage + priority } }
    private struct LogDay: Identifiable { let day: Date; let hours: Double; let sessions: Int; var id: Date { day } }

    var body: some View {
        let items = model.projectWorkItems(for: project)
        let progress = ProjectProgress.make(items)
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Insights").font(.title2.weight(.semibold))
                summary(progress)
                progressChart(progress)
                paceEstimate(progress)
                HStack(alignment: .top, spacing: 16) {
                    compositionChart(items)
                    stageChart(items)
                }
                workLogChart()
            }
            .padding(24).frame(maxWidth: 900, alignment: .leading).frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("projects.insights")
    }

    private func summary(_ progress: ProjectProgress) -> some View {
        HStack(spacing: 24) {
            stat("\(progress.open)", "open")
            stat("\(progress.completed)", "done")
            if let forecast = progress.forecast {
                stat(String(format: "%.1f", forecast.weeklyRate), "done per week (6 wk)")
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("projects.insights.summary")
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.title2.weight(.semibold).monospacedDigit())
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func progressChart(_ progress: ProjectProgress) -> some View {
        return ChartCard(title: "Progress over time", subtitle: "Recorded work · last 12 weeks. Bars show weekly completions; the line shows open items.") {
            if progress.weeks.allSatisfy({ $0.open == 0 && $0.completed == 0 }) {
                ChartEmpty(text: "No work records for this project yet.")
            } else {
                Chart {
                    ForEach(progress.weeks) { week in
                        BarMark(x: .value("Week", week.start, unit: .weekOfYear), y: .value("Completed", week.completed))
                            .foregroundStyle(by: .value("Series", "Completed that week"))
                        LineMark(x: .value("Week", week.start, unit: .weekOfYear), y: .value("Open", week.open))
                            .foregroundStyle(by: .value("Series", "Open"))
                            .interpolationMethod(.monotone)
                            .symbol(.circle)
                    }
                }
                .chartForegroundStyleScale(["Open": ChartPalette.open, "Completed that week": ChartPalette.done])
                .chartLegend(position: .bottom)
                .frame(height: 220)
                .accessibilityIdentifier("projects.insights.progress")
            }
        }
    }

    private func paceEstimate(_ progress: ProjectProgress) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { showPaceEstimate.toggle() } label: {
                Label("What if the recent pace continues?", systemImage: showPaceEstimate ? "chevron.down" : "chevron.right")
                    .font(.subheadline.weight(.medium))
            }.buttonStyle(.plain).accessibilityIdentifier("projects.insights.estimate.toggle")
            if showPaceEstimate { VStack(alignment: .leading, spacing: 8) {
                if let estimate = progress.forecast {
                    Text("Rough estimate: " + estimate.finish.formatted(date: .abbreviated, time: .omitted))
                        .font(.headline)
                    Text("\(estimate.remaining) open items ÷ " + String(format: "%.2f", estimate.weeklyRate) + " completions per week ≈ " + String(format: "%.1f", Double(estimate.remaining) / estimate.weeklyRate) + " weeks from today.")
                    Text("Pace is the average over six calendar weeks, including this partial week. Assumes no new work, similar item sizes and the same pace. It does not account for effort, dependencies or availability; this is not a deadline.")
                } else {
                    Text(progress.open == 0 ? "Nothing open to estimate." : "No completions in the last six calendar weeks. There is not enough activity to estimate a finish date.")
                }
            }.font(.caption).foregroundStyle(.secondary).padding(.top, 6) }
        }
        .padding(14).background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("projects.insights.estimate")
    }

    private func compositionChart(_ items: [WorkItem]) -> some View {
        let counts = Dictionary(grouping: items) { "\($0.kind.displayName)|\($0.status.displayName)" }
            .map { key, value -> KindCount in
                let parts = key.split(separator: "|").map(String.init)
                return KindCount(kind: parts[0], status: parts[1], count: value.count)
            }
            .sorted { $0.kind < $1.kind }
        return ChartCard(title: "Work by type") {
            if counts.isEmpty { ChartEmpty(text: "No work records yet.") } else {
                Chart(counts) { row in
                    BarMark(x: .value("Count", row.count), y: .value("Type", row.kind))
                        .foregroundStyle(by: .value("Status", row.status))
                }
                .chartForegroundStyleScale(["Open": ChartPalette.open, "In Progress": ChartPalette.inProgress,
                                            "Completed": ChartPalette.done])
                .chartLegend(position: .bottom)
                .frame(height: 170)
                .accessibilityIdentifier("projects.insights.composition")
            }
        }
    }

    private func stageChart(_ items: [WorkItem]) -> some View {
        let open = items.filter { $0.status != .completed }
        let counts = Dictionary(grouping: open) { "\($0.stage.displayName)|\($0.priority.rawValue.capitalized)" }
            .map { key, value -> StageCount in
                let parts = key.split(separator: "|").map(String.init)
                return StageCount(stage: parts[0], priority: parts[1], count: value.count)
            }
        let stageOrder = WorkItemStage.allCases.sorted { $0.rank < $1.rank }.map(\.displayName)
        return ChartCard(title: "Open work by stage") {
            if counts.isEmpty { ChartEmpty(text: "Nothing open.") } else {
                Chart(counts) { row in
                    BarMark(x: .value("Stage", row.stage), y: .value("Count", row.count))
                        .foregroundStyle(by: .value("Priority", row.priority))
                }
                .chartXScale(domain: stageOrder)
                .chartForegroundStyleScale(["High": Color.red, "Medium": Color.orange, "Low": Color.gray])
                .chartLegend(position: .bottom)
                .frame(height: 170)
                .accessibilityIdentifier("projects.insights.stages")
            }
        }
    }

    private func workLogChart() -> some View {
        let watcherID = model.projectRecord(for: project)?.watcherID
        let cutoff = Calendar.current.date(byAdding: .day, value: -56, to: Date()) ?? .distantPast
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let days: [LogDay] = model.workLogs
            .filter { watcherID != nil && $0.projectID == watcherID }
            .compactMap { entry in
                guard let day = formatter.date(from: entry.dateKey), day >= cutoff else { return nil }
                return LogDay(day: day, hours: entry.activeMinutes / 60, sessions: entry.sessionCount)
            }
        let total = days.map(\.hours).reduce(0, +)
        return ChartCard(title: "Work log · last 8 weeks",
                         subtitle: days.isEmpty ? nil : String(format: "%.1f active hours over %d days", total, days.count)) {
            if days.isEmpty {
                ChartEmpty(text: "No logged work for this project. The Work Log comes from the background service (Settings → Services).")
            } else {
                Chart(days) { day in
                    BarMark(x: .value("Day", day.day, unit: .day), y: .value("Hours", day.hours))
                        .foregroundStyle(ChartPalette.open.gradient)
                }
                .chartXScale(domain: cutoff...Date())
                .frame(height: 160)
                .accessibilityIdentifier("projects.insights.worklog")
            }
        }
    }
}
