import SwiftUI
import Charts
import AppKit
import BetterWorkspaceCore

/// Projects → Charts. Every chart reads the rows the shared Projects query already
/// produced, so search, filters and presets apply here exactly as in Table/Cards.
struct ProjectAnalyticsDashboard: View {
    let rows: [ProjectBrowserRow]
    let open: (ProjectBrowserRow) -> Void
    let drillDomain: (String) -> Void
    private static let defaultOrder = ProjectAnalytics.Metric.defaultOrder.map(\.rawValue).joined(separator: ",")
    @AppStorage("projects.charts.order", store: TestIsolation.defaults) private var order = Self.defaultOrder
    @AppStorage("projects.charts.days", store: TestIsolation.defaults) private var days = 30
    @AppStorage("projects.charts.limit", store: TestIsolation.defaults) private var limit = 10
    @AppStorage("projects.charts.activeOnly", store: TestIsolation.defaults) private var activeOnly = true
    @AppStorage("projects.charts.ascending", store: TestIsolation.defaults) private var ascending = false
    private var metrics: [ProjectAnalytics.Metric] { order.split(separator: ",").compactMap { .init(rawValue: String($0)) } }
    private func toggle(_ metric: ProjectAnalytics.Metric) {
        var next = metrics
        if next.contains(metric) { next.removeAll { $0 == metric } } else { next.append(metric) }
        order = next.map(\.rawValue).joined(separator: ",")
    }
    var body: some View {
        let records = rows.map(\.queryRecord)
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                ViewThatFits(in: .horizontal) {
                    HStack { controls; Spacer(minLength: 0) }
                    VStack(alignment: .leading, spacing: 8) { controls }
                }
                Text("\(rows.count) matching projects · search and filters apply" + (activeOnly ? " · finished projects hidden here" : ""))
                    .font(.caption).foregroundStyle(.secondary)
                if metrics.isEmpty { Text("Choose charts from Customize to build your dashboard.").foregroundStyle(.secondary) }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 380), spacing: 14, alignment: .top)], alignment: .leading, spacing: 14) {
                    ForEach(metrics, id: \.self) { metric in
                        ProjectAnalyticsChart(metric: metric, days: days,
                                              bars: ProjectAnalytics.bars(records, metric: metric, days: days, limit: limit, activeOnly: activeOnly, ascending: ascending)) { bar in
                            if metric == .domains { drillDomain(bar.title) }
                            else if let row = rows.first(where: { $0.id == bar.id }) { open(row) }
                        }
                    }
                }
            }.padding(20)
        }.accessibilityIdentifier("projects.charts")
    }
    @ViewBuilder private var controls: some View {
        Picker("Period", selection: $days) { Text("7 days").tag(7); Text("30 days").tag(30); Text("90 days").tag(90) }.fixedSize()
            .help("The window for observed hours, and how long a project must go without observed work to count as inactive.")
            .accessibilityIdentifier("projects.charts.period")
        Picker("Show", selection: $limit) { Text("Top 5").tag(5); Text("Top 10").tag(10); Text("Top 20").tag(20) }.fixedSize()
        Menu {
            Section("Charts") {
                ForEach(ProjectAnalytics.Metric.allCases, id: \.self) { metric in
                    Toggle(metric.title, isOn: Binding(get: { metrics.contains(metric) }, set: { _ in toggle(metric) }))
                }
            }
            Menu("Move chart to top") {
                ForEach(metrics, id: \.self) { metric in Button(metric.title) { order = ([metric] + metrics.filter { $0 != metric }).map(\.rawValue).joined(separator: ",") } }
            }.disabled(metrics.count < 2)
            Divider()
            Toggle("Hide finished projects", isOn: $activeOnly)
            Toggle("Smallest values first", isOn: $ascending)
            Divider()
            Button("Restore dashboard") { order = Self.defaultOrder; days = 30; limit = 10; ascending = false; activeOnly = true }
        } label: { Label("Customize", systemImage: "slider.horizontal.3") }
            .fixedSize().accessibilityIdentifier("projects.charts.customize")
    }
}

/// One restrained hue for every chart. Each chart is a single series, so color carries
/// no identity; titles and labels do. Validated for contrast on light and dark surfaces.
private enum AnalyticsPalette {
    static let bar = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0x24 / 255, green: 0x99 / 255, blue: 0x7a / 255, alpha: 1)
            : NSColor(srgbRed: 0x1f / 255, green: 0x8a / 255, blue: 0x6c / 255, alpha: 1)
    })
}

private struct ProjectAnalyticsChart: View {
    let metric: ProjectAnalytics.Metric
    let days: Int
    let bars: [ProjectAnalytics.Bar]
    let open: (ProjectAnalytics.Bar) -> Void
    @State private var hovered: String?
    private func format(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...1))) + (metric == .nearDone ? "%" : "")
    }
    private func label(_ bar: ProjectAnalytics.Bar) -> String {
        (bar.isLowerBound ? "≥ " : "") + format(bar.value)
    }
    private func detail(_ bar: ProjectAnalytics.Bar) -> String {
        // Percent is already in the unit, and inactivity qualifications must also
        // reach VoiceOver rather than being available only on pointer hover.
        (bar.isLowerBound ? "at least " : "") + bar.value.formatted(.number.precision(.fractionLength(0...1)))
            + " " + metric.unit + (bar.note.map { " · " + $0 } ?? "")
    }
    private var emptyText: String {
        switch metric {
        case .attention, .domains: return "No observed work in the last \(days) days for these projects. Missing measurements are never counted as zero."
        case .valueIdle: return "No project rated 60+ has gone \(days) days without observed work."
        case .stalled: return "No project with five or more open records has gone \(days) days without observed work. Try a shorter period."
        case .nearDone: return "No project has both open and completed recorded work."
        default: return "No matching projects have this evidence. Try broader filters; missing measurements are never counted as zero."
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(metric.title).font(.headline).lineLimit(1)
                ProjectContextHelp(text: metric.explanation)
                Spacer(minLength: 4)
                Text(metric.evidence).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            if bars.isEmpty {
                Text(emptyText).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).padding(.vertical, 12)
            } else {
                Chart(bars) { bar in
                    BarMark(x: .value(metric.unit, bar.value), y: .value("Project", bar.id), height: .fixed(14))
                        .cornerRadius(3)
                        .foregroundStyle(AnalyticsPalette.bar.opacity(hovered == nil || hovered == bar.id ? 1 : 0.4))
                        .annotation(position: .trailing, spacing: 4) {
                            Text(label(bar) + (bar.note?.contains("Provisional") == true ? "°" : "")).font(.caption2).foregroundStyle(.secondary)
                        }
                        // Swift Charts omits custom values from some accessibility
                        // clients' snapshots. Keep the complete qualification in the label.
                        .accessibilityLabel("\(bar.title), \(detail(bar))")
                }
                .chartYScale(domain: bars.map(\.id))
                .chartYAxis { AxisMarks(values: bars.map(\.id)) { value in AxisValueLabel { Text(bars.first { $0.id == value.as(String.self) }?.title ?? "").lineLimit(1).frame(maxWidth: 150, alignment: .trailing) } } }
                .chartXAxis { AxisMarks { _ in AxisGridLine().foregroundStyle(.quaternary); AxisValueLabel() } }
                .chartXAxisLabel(metric.unit)
                .chartXScale(domain: metric == .nearDone ? 0...100 : 0...((bars.map(\.value).max() ?? 1) * 1.15))
                .frame(height: CGFloat(max(110, bars.count * 26 + 40)))
                .chartOverlay { proxy in
                    GeometryReader { geometry in
                        Rectangle().fill(.clear).contentShape(Rectangle())
                            .onContinuousHover { phase in
                                if case .active(let point) = phase, let frame = proxy.plotFrame {
                                    hovered = proxy.value(atY: point.y - geometry[frame].origin.y, as: String.self)
                                } else { hovered = nil }
                            }
                            .onTapGesture { point in
                                if let frame = proxy.plotFrame, let id = proxy.value(atY: point.y - geometry[frame].origin.y, as: String.self), let bar = bars.first(where: { $0.id == id }) { open(bar) }
                            }
                    }
                }
                HStack {
                    if let selected = bars.first(where: { $0.id == hovered }) {
                        Text("\(selected.title) · \(detail(selected))").lineLimit(1)
                    } else {
                        Text(metric == .domains ? "Click a domain to list its projects" : "Click a bar to open the project")
                    }
                    Spacer(minLength: 4)
                    Menu(metric == .domains ? "Domains" : "Open") {
                        ForEach(bars) { bar in Button(bar.title) { open(bar) } }
                    }.menuStyle(.borderlessButton).fixedSize().accessibilityIdentifier("projects.charts.open." + metric.rawValue)
                }.font(.caption).foregroundStyle(.secondary)
            }
        }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.quaternary))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("projects.charts." + metric.rawValue)
    }
}
