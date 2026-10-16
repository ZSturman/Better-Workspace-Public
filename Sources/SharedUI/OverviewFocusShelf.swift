import SwiftUI
import BetterWorkspaceCore

/// One focus, three items, one visual measure. Shared by Mac, iPhone and iPad.
struct OverviewFocusShelf: View {
    let items: [OverviewFocusItem]
    let onSelect: (OverviewFocusItem) -> Void
    @AppStorage private var focusRaw: String
    @AppStorage private var contentRaw: String
    @AppStorage private var chart: Bool
    @AppStorage private var compare: Bool
    @State private var width: CGFloat = 0
    private var focus: OverviewFocus { OverviewFocus(rawValue: focusRaw) ?? .almostDone }
    private var content: OverviewContent { OverviewContent(rawValue: contentRaw) ?? .projects }
    private var comparison: OverviewFocus { focus == .highestRated ? .almostDone : .highestRated }

    init(items: [OverviewFocusItem], defaults: UserDefaults = .standard, onSelect: @escaping (OverviewFocusItem) -> Void) {
        self.items = items; self.onSelect = onSelect
        _focusRaw = AppStorage(wrappedValue: OverviewFocus.almostDone.rawValue, "overview.focus", store: defaults)
        _contentRaw = AppStorage(wrappedValue: OverviewContent.projects.rawValue, "overview.content", store: defaults)
        _chart = AppStorage(wrappedValue: true, "overview.chart", store: defaults)
        _compare = AppStorage(wrappedValue: false, "overview.compare", store: defaults)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Wraps rather than choosing between layouts: a ViewThatFits here gave the
            // Mac's Overview column a minimum wider than the 820pt window.
            FlowLayout(spacing: 8) { contentPicker; focusPicker; presentationMenu }
            if compare {
                // Side by side only when each column keeps a readable width. Chosen from
                // the measured width: ViewThatFits widens the Mac column's minimum.
                let layout = width >= 564 ? AnyLayout(HStackLayout(alignment: .top, spacing: 24))
                                          : AnyLayout(VStackLayout(alignment: .leading, spacing: 18))
                layout { ranked(focus); ranked(comparison) }
            } else { ranked(focus) }
        }
        .background(GeometryReader { proxy in
            Color.clear.onAppear { width = proxy.size.width }.onChange(of: proxy.size.width) { width = $1 }
        })
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("overview.focusShelf")
    }

    private var contentPicker: some View {
        Picker("Show", selection: $contentRaw) {
            ForEach(OverviewContent.allCases) { Text($0.title).tag($0.rawValue) }
        }.labelsHidden().compactInList().accessibilityLabel("Focus content").accessibilityIdentifier("overview.focusContent")
    }
    private var focusPicker: some View {
        Picker("Bring forward", selection: $focusRaw) {
            ForEach(OverviewFocus.allCases) { Text($0.title).tag($0.rawValue) }
        }.labelsHidden().compactInList().accessibilityLabel("Bring forward").accessibilityIdentifier("overview.focusPicker")
    }
    private var presentationMenu: some View {
        Menu {
            Toggle("Show charts", isOn: $chart)
            Toggle("Compare two focuses", isOn: $compare)
        } label: { Label("View", systemImage: "chart.bar").compactLabel() }
        .compactInList()
        .accessibilityIdentifier("overview.focusView")
    }

    @ViewBuilder private func ranked(_ lens: OverviewFocus) -> some View {
        let ranked = Array(OverviewRanking.items(items, kind: content, focus: lens).prefix(3))
        VStack(alignment: .leading, spacing: 10) {
            if compare { Text(lens.title).font(.subheadline.weight(.semibold)) }
            if ranked.isEmpty {
                Text(emptyMessage(lens)).font(.subheadline).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(ranked) { item in
                    Button { onSelect(item) } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Text(item.title).font(.subheadline.weight(.medium)).lineLimit(2)
                                Spacer(minLength: 8)
                                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                            }
                            Text(item.reason(lens)).font(.caption).foregroundStyle(.secondary)
                            if chart { mark(item, lens: lens) }
                        }
                        .padding(.vertical, 4).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("overview.focusItem.\(item.id)")
                }
                Text(lens == .almostDone ? "Progress counts linked tasks, not total project completion." : lens == .highestRated ? "Your manual scores · completed work excluded" : "Track spans 90 days. Recorded work when known, otherwise file changes.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func emptyMessage(_ lens: OverviewFocus) -> String {
        switch lens {
        case .highestRated: return content == .projects ? "Rate projects to compare them here. A score counts once at least half its criteria are rated." : "Manual scores are kept for projects. Choose Projects to compare ratings."
        case .almostDone: return content == .ideas ? "Ideas have no completion measure. Try Needs a revisit." : "No unfinished items with completed linked tasks yet. Try another focus."
        case .revisit: return "No activity evidence yet. Unknown activity is not treated as inactivity."
        }
    }

    private func mark(_ item: OverviewFocusItem, lens: OverviewFocus) -> some View {
        let fraction: Double = {
            switch lens {
            case .almostDone: return item.fraction
            case .highestRated: return (item.score ?? 0) / 100
            case .revisit:
                // A fixed 90-day track, so one item alone still reads as "recent" or
                // "long ago" instead of always sitting at the end of its own scale.
                let age = max(0, Date().timeIntervalSince(item.lastWorked ?? item.lastChanged ?? Date()))
                return age / (OverviewFocusItem.revisitHorizonDays * 86_400)
            }
        }()
        return GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(.secondary.opacity(0.15))
                if lens == .revisit {
                    Circle().fill(Color.accentColor).frame(width: 8, height: 8)
                        .offset(x: max(0, geometry.size.width - 8) * min(1, max(0, fraction)))
                } else {
                    Capsule().fill(Color.accentColor).frame(width: geometry.size.width * min(1, max(0, fraction)))
                }
            }
        }.frame(height: 8).accessibilityHidden(true)
    }
}

private extension Label where Title == Text, Icon == Image {
    @ViewBuilder func compactLabel() -> some View {
        #if os(iOS)
        labelStyle(.titleAndIcon)
        #else
        self
        #endif
    }
}

private extension View {
    /// In an iOS List row a picker must be menu-style and pinned to its ideal width, or it
    /// renders as a row with its label. On macOS an explicit menu style (or a forced
    /// title-and-icon label) reports a very wide ideal size to FlowLayout and pushed the
    /// Overview column off the 820pt window, so both are iOS-only.
    @ViewBuilder func compactInList() -> some View {
        #if os(iOS)
        pickerStyle(.menu).fixedSize()
        #else
        self
        #endif
    }
}
