import SwiftUI
import AppKit
import BetterWorkspaceCore

/// All totals and rankings use the shared Projects query, never a second folder scan.
struct ProjectAnalyticsDashboard: View {
    let rows: [ProjectBrowserRow]
    let open: (ProjectBrowserRow) -> Void
    let drillDomain: (String) -> Void
    private static let defaultOrder = ProjectAnalytics.Metric.defaultOrder.map(\.rawValue).joined(separator: ",")
    // Retain the old order key as the visibility list; sections now have a fixed order.
    @AppStorage("projects.charts.order", store: TestIsolation.defaults) private var order = Self.defaultOrder
    @AppStorage("projects.charts.days", store: TestIsolation.defaults) private var days = 30
    @AppStorage("projects.charts.limit", store: TestIsolation.defaults) private var limit = 5
    @AppStorage("projects.charts.activeOnly", store: TestIsolation.defaults) private var activeOnly = true
    private var metrics: [ProjectAnalytics.Metric] { order.split(separator: ",").compactMap { .init(rawValue: String($0)) } }
    private let sections: [(String, String, [ProjectAnalytics.Metric])] = [
        ("Needs review", "Projects worth revisiting before you take on more.", [.stalled, .valueIdle, .idle]),
        ("Work remaining", "Recorded scope and progress, rather than estimates of effort.", [.backlog, .nearDone]),
        ("Time spent", "Where the work log observed activity in the selected period.", [.attention, .domains])
    ]

    var body: some View {
        let records = rows.map(\.queryRecord)
        let summary = ProjectAnalytics.summary(records, days: days, activeOnly: activeOnly)
        GeometryReader { geometry in
            let wide = min(geometry.size.width - 48, 1440) >= 1000
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Project insights").font(.title2.bold())
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 16) { selectionControls; finishedToggle; Spacer(); customize }
                            VStack(alignment: .leading, spacing: 10) {
                                selectionControls
                                HStack { finishedToggle; Spacer(); customize }
                            }
                        }
                        Text("Search and project filters apply. Work counts are current; activity uses the selected period.")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .top), count: wide ? 4 : 2), spacing: 12) {
                        summaryTile("Projects in scope", value: summary.projectCount.formatted(), detail: activeOnly ? "Finished projects hidden" : "All matching projects")
                        summaryTile("Outstanding work", value: number(summary.openWork), detail: "Recorded in \(summary.workCoverage) of \(summary.projectCount) projects")
                        summaryTile("Needing review", value: summary.reviewCount.formatted(), detail: "Inactive scope or high value · \(days)+ days")
                        summaryTile("Observed hours", value: number(summary.observedHours), detail: "Measured in \(summary.observationCoverage) of \(summary.projectCount) projects")
                    }.accessibilityIdentifier("projects.charts.summary")
                    if metrics.isEmpty {
                        Text("Choose charts from Customize to build your dashboard.").foregroundStyle(.secondary)
                    }
                    ForEach(sections, id: \.0) { section in
                        let visible = section.2.filter { metrics.contains($0) }
                        if !visible.isEmpty {
                            VStack(alignment: .leading, spacing: 12) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(section.0).font(.title3.bold())
                                    Text(section.1).font(.callout).foregroundStyle(.secondary)
                                }
                                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .top), count: wide ? 2 : 1), alignment: .leading, spacing: 16) {
                                    ForEach(visible, id: \.self) { metric in
                                        ProjectAnalyticsChart(metric: metric, days: days,
                                            bars: ProjectAnalytics.bars(records, metric: metric, days: days, limit: limit, activeOnly: activeOnly)) { bar in
                                                if metric == .domains { drillDomain(bar.title) }
                                                else if let row = rows.first(where: { $0.id == bar.id }) { open(row) }
                                            }
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(24).frame(maxWidth: 1488).frame(maxWidth: .infinity)
            }
        }.accessibilityIdentifier("projects.charts")
    }

    private func number(_ value: Double?) -> String {
        value.map { $0.formatted(.number.precision(.fractionLength(0...1))) } ?? "—"
    }
    private func summaryTile(_ title: String, value: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.callout).foregroundStyle(.secondary)
            Text(value).font(.system(size: 28, weight: .semibold, design: .rounded)).monospacedDigit()
            Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).padding(16)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
            .accessibilityElement(children: .combine)
    }
    private var selectionControls: some View {
        HStack(spacing: 16) {
            Picker("Period", selection: $days) { Text("7 days").tag(7); Text("30 days").tag(30); Text("90 days").tag(90) }
                .fixedSize().accessibilityIdentifier("projects.charts.period")
                .help("Activity window and the minimum inactivity age for Needs review. Work remaining is a current snapshot.")
            Picker("Show", selection: $limit) { Text("Top 5").tag(5); Text("Top 10").tag(10); Text("Top 20").tag(20) }.fixedSize()
        }
    }
    private var finishedToggle: some View {
        Toggle("Hide finished projects", isOn: $activeOnly).toggleStyle(.checkbox).fixedSize()
    }
    private var customize: some View {
        Menu {
            ForEach(ProjectAnalytics.Metric.allCases, id: \.self) { metric in
                Toggle(metric.title, isOn: Binding(get: { metrics.contains(metric) }, set: { enabled in
                    var next = metrics.filter { $0 != metric }
                    if enabled { next.append(metric) }
                    order = next.map(\.rawValue).joined(separator: ",")
                }))
            }
            Divider()
            Button("Restore dashboard") { order = Self.defaultOrder; days = 30; limit = 5; activeOnly = true }
        } label: { Label("Customize", systemImage: "slider.horizontal.3") }
            .fixedSize().accessibilityIdentifier("projects.charts.customize")
    }
}

private struct ProjectAnalyticsChart: View {
    let metric: ProjectAnalytics.Metric
    let days: Int
    let bars: [ProjectAnalytics.Bar]
    let open: (ProjectAnalytics.Bar) -> Void
    @State private var hovered: String?
    private var maximum: Double { metric == .nearDone || metric == .valueIdle ? 100 : max(bars.map(\.value).max() ?? 1, 1) }
    private func detail(_ bar: ProjectAnalytics.Bar) -> String {
        let unit: String
        if bar.value == 1 {
            switch metric {
            case .backlog, .stalled: unit = "open record"
            case .attention, .domains: unit = "hour"
            case .idle: unit = "day"
            default: unit = metric.unit
            }
        } else { unit = metric.unit }
        return (bar.isLowerBound ? "at least " : "") + bar.value.formatted(.number.precision(.fractionLength(0...1))) + " " + unit
    }
    private var emptyText: String {
        switch metric {
        case .attention, .domains: return "No observed work in the last \(days) days. Missing observations do not mean no work."
        case .valueIdle: return "No rated project meets the 60+ score and \(days)+ days inactive threshold."
        case .stalled: return "No project has 5+ open records and \(days)+ days without observed work."
        case .nearDone: return "No project has both open and completed recorded work."
        default: return "No matching projects have this evidence."
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(metric.title).font(.headline).fixedSize(horizontal: false, vertical: true)
                    ProjectContextHelp(text: metric.explanation)
                    Spacer(minLength: 0)
                }
                Text(metric.evidence).font(.caption).foregroundStyle(.secondary)
            }
            if bars.isEmpty {
                Text(emptyText).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(spacing: 14) {
                    ForEach(bars) { bar in
                        Button { open(bar) } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                HStack(alignment: .firstTextBaseline, spacing: 12) {
                                    Text(bar.title).font(.callout.weight(.medium)).multilineTextAlignment(.leading)
                                        .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
                                    Text((bar.isLowerBound ? "≥ " : "") + bar.value.formatted(.number.precision(.fractionLength(0...1))) + (metric == .nearDone ? "%" : ""))
                                        .font(.callout.weight(.semibold)).monospacedDigit().fixedSize()
                                }
                                GeometryReader { geometry in
                                    ZStack(alignment: .leading) {
                                        Capsule().fill(.quaternary)
                                        Capsule().fill(Color.accentColor.opacity(hovered == bar.id ? 1 : 0.75))
                                            .frame(width: max(2, geometry.size.width * min(bar.value / maximum, 1)))
                                    }
                                }.frame(height: 7).accessibilityHidden(true)
                                HStack(alignment: .top) {
                                    Text(bar.note ?? (metric == .domains ? "Show projects in this domain" : detail(bar)))
                                        .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.leading)
                                    Spacer(minLength: 4)
                                    Image(systemName: "arrow.up.right").font(.caption2).foregroundStyle(.tertiary)
                                }
                            }.contentShape(Rectangle())
                        }
                        .buttonStyle(.plain).onHover { hovered = $0 ? bar.id : nil }
                        .help(metric == .domains ? "Show projects in \(bar.title)" : "Open \(bar.title)")
                        .accessibilityLabel("\(bar.title), \(detail(bar))\(bar.note.map { ", " + $0 } ?? "")")
                        .accessibilityIdentifier("projects.charts.row.\(metric.rawValue).\(bar.id)")
                    }
                }
                HStack {
                    Text(metric.unit).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Menu(metric == .domains ? "Domains" : "Open") {
                        ForEach(bars) { bar in Button(bar.title) { open(bar) } }
                    }.menuStyle(.borderlessButton).fixedSize().accessibilityIdentifier("projects.charts.open." + metric.rawValue)
                }
            }
        }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.quaternary))
            .accessibilityElement(children: .contain).accessibilityIdentifier("projects.charts." + metric.rawValue)
    }
}
