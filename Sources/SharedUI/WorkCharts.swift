import SwiftUI
import Charts
import BetterWorkspaceCore

/// Open work by stage, then completed, as one thin bar — small enough to sit inside a
/// list row or under a heading, so progress is visible where the work is rather than
/// on a separate charts screen. Shared by the Mac and iPhone/iPad apps.
struct WorkProgressStrip: View {
    let counts: WorkProgressCounts
    /// The "1 now · 2 next · 40% done" line. Rows that are already busy leave it out.
    var showsCaption = true
    var height: CGFloat = 8

    static let palette: KeyValuePairs<String, Color> = [
        "Now": .red, "Next": .orange, "Later": .gray.opacity(0.6), "Done": .green,
    ]

    private struct Segment: Identifiable {
        let name: String
        let count: Int
        var id: String { name }
    }

    private var segments: [Segment] {
        [Segment(name: "Now", count: counts.now), Segment(name: "Next", count: counts.next),
         Segment(name: "Later", count: counts.later), Segment(name: "Done", count: counts.completed)]
            .filter { $0.count > 0 }
    }

    var caption: String {
        var parts: [String] = []
        if counts.now > 0 { parts.append("\(counts.now) now") }
        if counts.next > 0 { parts.append("\(counts.next) next") }
        if counts.later > 0 { parts.append("\(counts.later) later") }
        if counts.open == 0 { parts.append("nothing open") }
        parts.append("\(Int((counts.fractionDone * 100).rounded()))% done")
        return parts.joined(separator: " · ")
    }

    var body: some View {
        if counts.total > 0 {
            VStack(alignment: .leading, spacing: 4) {
                Chart(segments) { segment in
                    BarMark(x: .value("Items", segment.count), y: .value("Work", "All"))
                        .foregroundStyle(by: .value("Stage", segment.name))
                }
                .chartForegroundStyleScale(domain: Self.palette.map(\.key), range: Self.palette.map(\.value))
                .chartXScale(domain: 0...counts.total)
                .chartXAxis(.hidden).chartYAxis(.hidden).chartLegend(.hidden)
                .chartPlotStyle { $0.clipShape(Capsule()) }
                .frame(height: height)
                if showsCaption {
                    Text(caption).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Work progress")
            .accessibilityValue(caption)
        }
    }
}

/// A few weeks of activity as small bars, newest on the right. Meant to sit beside the
/// list it summarizes; says nothing when there was no activity at all.
struct WeeklyActivityChart: View {
    let counts: WeeklyCounts
    let title: String
    var color: Color = .accentColor
    var height: CGFloat = 44

    var body: some View {
        if counts.total > 0 {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Spacer()
                    Text("\(counts.weeks.last?.count ?? 0) this week").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
                Chart(counts.weeks) { week in
                    BarMark(x: .value("Week", week.start, unit: .weekOfYear), y: .value("Count", week.count))
                        .foregroundStyle(week.id == counts.weeks.last?.id ? color : color.opacity(0.45))
                        .cornerRadius(2)
                }
                .chartXAxis(.hidden).chartYAxis(.hidden)
                .frame(height: height)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(title)
            .accessibilityValue("\(counts.total) in \(counts.weeks.count) weeks, \(counts.weeks.last?.count ?? 0) this week")
        }
    }
}
