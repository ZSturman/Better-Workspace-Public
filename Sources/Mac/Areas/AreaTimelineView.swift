import SwiftUI
import BetterWorkspaceCore

/// An area laid out along time: a month-density rail to see the shape of the whole
/// history and jump through it, above a month-sectioned list to act on items.
///
/// Adapted from the Logs rail and the catalog's activity-stream pattern. Two things
/// keep it honest: the rail keeps empty months, because a gap is information, and each
/// row says when its date came from the item's name rather than from the disk.
struct AreaTimelineView: View {
    @Environment(AppModel.self) private var model
    let items: [WorkspaceItem]
    let basis: AreaDateBasis

    @State private var focusedMonth: Date?

    private struct Entry: Identifiable {
        let item: WorkspaceItem
        let date: ItemDate
        var id: WorkspaceItem.ID { item.id }
    }

    private struct Month: Identifiable {
        let start: Date
        var entries: [Entry]
        var id: Date { start }
    }

    private var calendar: Calendar { .current }

    /// Newest month first; within a month, newest item first.
    private var months: [Month] {
        let dated = items.compactMap { item in ItemDates.date(of: item, basis: basis).map { Entry(item: item, date: $0) } }
        let grouped = Dictionary(grouping: dated) { calendar.dateInterval(of: .month, for: $0.date.date)?.start ?? $0.date.date }
        return grouped
            .map { Month(start: $0.key, entries: $0.value.sorted { $0.date.date > $1.date.date }) }
            .sorted { $0.start > $1.start }
    }

    private var undated: [WorkspaceItem] {
        items.filter { ItemDates.date(of: $0, basis: basis) == nil }
    }

    private var selection: Binding<WorkspaceItem.ID?> {
        Binding(get: { model.selectedItem?.id },
                set: { id in model.selectedItem = items.first(where: { $0.id == id }) })
    }

    var body: some View {
        let months = months
        VStack(spacing: 0) {
            if months.isEmpty == false {
                MonthDensityRail(counts: Dictionary(uniqueKeysWithValues: months.map { ($0.start, $0.entries.count) }),
                                 focused: focusedMonth ?? months.first?.start,
                                 basis: basis) { month in
                    focusedMonth = month
                }
                Divider()
            }
            ScrollViewReader { proxy in
                List(selection: selection) {
                    ForEach(months) { month in
                        Section {
                            ForEach(month.entries) { entry in
                                row(entry)
                            }
                        } header: {
                            header(month)
                        }
                    }
                    if undated.isEmpty == false {
                        Section {
                            ForEach(undated) { item in
                                row(Entry(item: item, date: ItemDate(date: .distantPast, source: .created)), dated: false)
                            }
                        } header: {
                            Text("No \(basis.displayName.lowercased()) date")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .listStyle(.inset)
                // Double-click or Return opens, as in the table layout.
                .contextMenu(forSelectionType: WorkspaceItem.ID.self) { ids in
                    if let item = items.first(where: { ids.contains($0.id) }) { ItemContextMenu(item: item) }
                } primaryAction: { ids in
                    for item in items where ids.contains(item.id) { model.open(item.url) }
                }
                .onChange(of: focusedMonth) { _, month in
                    guard let month, let first = months.first(where: { $0.start == month })?.entries.first else { return }
                    withAnimation(.easeInOut(duration: 0.2)) { proxy.scrollTo(first.id, anchor: .top) }
                }
            }
        }
        // A container, so the identifier names this view instead of overwriting every
        // child's — including the rail's own.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("area.timeline")
    }

    // MARK: Pieces

    private func header(_ month: Month) -> some View {
        HStack(spacing: Theme.Space.snug) {
            Text(month.start, format: .dateTime.month(.wide).year())
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.primary)
            Text(Format.count(month.entries.count, singular: "item"))
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.secondary)
            KindMixBar(kinds: month.entries.map(\.item.kind))
                .frame(width: 64, height: 4)
            Spacer()
        }
        .padding(.vertical, 2)
    }

    private func row(_ entry: Entry, dated: Bool = true) -> some View {
        let item = entry.item
        return HStack(spacing: Theme.Space.snug) {
            VStack(spacing: 0) {
                if dated {
                    Text(entry.date.date, format: .dateTime.day())
                        .font(.system(size: 14, weight: .semibold).monospacedDigit())
                    Text(entry.date.date, format: .dateTime.weekday(.abbreviated))
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                } else {
                    Text("—").foregroundStyle(.tertiary)
                }
            }
            .frame(width: 30)

            Image(systemName: item.kind.symbolName)
                .foregroundStyle(Theme.kindColor(item.kind))
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.displayTitle).lineLimit(1)
                HStack(spacing: Theme.Space.tight) {
                    Text(item.isDirectory ? Format.count(item.immediateChildCount, singular: "item")
                                          : Format.bytes(item.byteSize))
                    if dated && entry.date.source == .name {
                        Text("·")
                        Text("date from name")
                            .help("This date is written in the item's name, which is kept when a file is copied. "
                                  + "Its creation date on disk is \(Format.shortDate(item.createdAt)).")
                    }
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: Theme.Space.tight)
            let tags = model.tags(for: item)
            if tags.isEmpty == false { TagChipRow(tags: tags, limit: 2) }
        }
        .padding(.vertical, 1)
        .contentShape(Rectangle())
        .id(item.id)
    }
}

/// Months from the oldest item to now, one bar each, height by count.
///
/// Empty months are kept as a baseline tick so a quiet stretch reads as quiet rather
/// than being squeezed out. A square-root scale keeps a month with one item visible
/// next to a month with fifty.
private struct MonthDensityRail: View {
    let counts: [Date: Int]
    let focused: Date?
    let basis: AreaDateBasis
    let select: (Date) -> Void

    private var calendar: Calendar { .current }
    private static let barWidth: CGFloat = 10
    private static let maxHeight: CGFloat = 34

    private var span: [Date] {
        guard let first = counts.keys.min() else { return [] }
        let nowMonth = calendar.dateInterval(of: .month, for: Date())?.start ?? Date()
        let last = max(counts.keys.max() ?? first, nowMonth)
        var months: [Date] = []
        var cursor = first
        while cursor <= last, months.count < 1200 {
            months.append(cursor)
            guard let next = calendar.date(byAdding: .month, value: 1, to: cursor) else { break }
            cursor = next
        }
        return months
    }

    var body: some View {
        let span = span
        let peak = Double(counts.values.max() ?? 1)
        HStack(spacing: Theme.Space.snug) {
            VStack(alignment: .leading, spacing: 2) {
                Text(basis.displayName.uppercased())
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text("\(counts.values.reduce(0, +)) over \(span.count) mo")
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .fixedSize()
            }
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .bottom, spacing: 3) {
                        ForEach(span, id: \.self) { month in
                            bar(month, count: counts[month] ?? 0, peak: peak)
                                .id(month)
                        }
                    }
                    .padding(.horizontal, Theme.Space.tight)
                }
                .onAppear { if let last = span.last { proxy.scrollTo(last, anchor: .trailing) } }
            }
        }
        .padding(.horizontal, Theme.Space.base)
        .padding(.vertical, Theme.Space.tight)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.18))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("area.timeline.rail")
    }

    private func bar(_ month: Date, count: Int, peak: Double) -> some View {
        let isFocused = focused == month
        let height = count == 0 ? 2 : max(4, Self.maxHeight * sqrt(Double(count) / peak))
        let isJanuary = calendar.component(.month, from: month) == 1
        return Button { if count > 0 { select(month) } } label: {
            VStack(spacing: 3) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(count == 0 ? Color.secondary.opacity(0.18)
                          : (isFocused ? Color.accentColor : Color.accentColor.opacity(0.45)))
                    .frame(width: Self.barWidth, height: height)
                    .frame(height: Self.maxHeight, alignment: .bottom)
                // A year label on each January, and on the first month shown.
                Text(isJanuary || month == span.first ? month.formatted(.dateTime.year(.twoDigits)) : " ")
                    .font(.system(size: 8).monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .fixedSize()
                    .frame(width: Self.barWidth)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(count == 0)
        .help("\(month.formatted(.dateTime.month(.wide).year())) · \(Format.count(count, singular: "item"))")
        .accessibilityLabel("\(month.formatted(.dateTime.month(.wide).year())), \(Format.count(count, singular: "item"))")
    }
}

/// What kinds of thing arrived in a period, as a single proportional strip in the same
/// kind colours the rows use.
private struct KindMixBar: View {
    let kinds: [FileKind]

    var body: some View {
        let counts = Dictionary(grouping: kinds, by: { $0 }).mapValues(\.count)
            .sorted { $0.value > $1.value }
        GeometryReader { geometry in
            HStack(spacing: 1) {
                ForEach(counts, id: \.key) { kind, count in
                    Theme.kindColor(kind)
                        .frame(width: max(2, geometry.size.width * CGFloat(count) / CGFloat(max(kinds.count, 1)) - 1))
                        .help("\(count) \(kind.displayName.lowercased())")
                }
            }
        }
        .clipShape(Capsule())
    }
}
