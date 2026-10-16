import SwiftUI
import BetterWorkspaceCore

/// Native dashboard over ordinary exports in `Analytics`. Folders are data sources,
/// not web applications: add daily CSVs, spreadsheets, JSON exports or reports and
/// Better Workspace presents their freshness and contents without a local server.
struct AnalyticsView: View {
    @Environment(AppModel.self) private var model
    @State private var selectedSourceID: WorkspaceItem.ID?

    private var items: [WorkspaceItem] { model.items(for: .analytics) }
    private var sources: [WorkspaceItem] { items.filter(\.isDirectory) }
    private var looseExports: [WorkspaceItem] { items.filter { $0.isDirectory == false } }
    private var selectedSource: WorkspaceItem? { sources.first(where: { $0.id == selectedSourceID }) }
    private var newestExport: Date? { items.compactMap(\.contentModifiedAt).max() }

    /// Not read yet, so an empty list here would be a false "nothing".
    private var showsLoading: Bool { items.isEmpty && model.isAwaitingFirstRead(of: .analytics) }

    var body: some View {
        VStack(spacing: 0) {
            AreaHeader(title: "Analytics", subtitle: nil, symbol: "chart.xyaxis.line", count: showsLoading ? nil : sources.count) {
                HStack(spacing: Theme.Space.tight) {
                    Button { Task { await model.refresh(area: .analytics) } } label: { Label("Refresh analytics", systemImage: "arrow.clockwise") }
                        .labelStyle(.iconOnly).help("Refresh the Analytics folder")
                    Button { model.revealInFinder(model.workspace.url(for: .analytics)) } label: { Label("Show analytics files in Finder", systemImage: "folder") }
                        .labelStyle(.iconOnly)
                }
            }
            Divider()
            if let source = selectedSource {
                AnalyticsSourceDetail(source: source, onBack: { selectedSourceID = nil })
            } else if showsLoading {
                LoadingAreaState(title: "Loading analytics…")
            } else if items.isEmpty {
                EmptyAreaState(symbol: "chart.xyaxis.line", title: "No analytics exports yet",
                               message: "Add folders for data sources, then drop daily CSV, spreadsheet, JSON, or report exports inside them.")
            } else {
                dashboard
            }
        }
        .onChange(of: sources.map(\.id)) { _, ids in
            if let selectedSourceID, ids.contains(selectedSourceID) == false { self.selectedSourceID = nil }
        }
    }

    private var dashboard: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.loose) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: Theme.Space.snug)], spacing: Theme.Space.snug) {
                    AnalyticsMetricCard(title: "Data sources", value: "\(sources.count)", symbol: "folder")
                    AnalyticsMetricCard(title: "Loose exports", value: "\(looseExports.count)", symbol: "doc.text")
                    AnalyticsMetricCard(title: "Last updated", value: newestExport.map(Format.relativeDate) ?? "—", symbol: "clock")
                }
                if sources.isEmpty == false {
                    VStack(alignment: .leading, spacing: Theme.Space.snug) {
                        Text("Data sources").font(.headline).accessibilityIdentifier("analytics.dataSources")
                        Text("Each folder is a source. Open one to inspect the exports Better Workspace is reading.")
                            .font(.callout).foregroundStyle(.secondary)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: Theme.Space.snug)], spacing: Theme.Space.snug) {
                            ForEach(sources) { source in
                                AnalyticsSourceCard(source: source)
                                    .onTapGesture { selectedSourceID = source.id }
                                    .contextMenu { ItemContextMenu(item: source) }
                                    .accessibilityIdentifier("analytics.source.\(source.id)")
                            }
                        }
                    }
                }
                if looseExports.isEmpty == false {
                    VStack(alignment: .leading, spacing: Theme.Space.snug) {
                        Text("Unsorted exports").font(.headline)
                        Text("Move these into a source folder when you know where they belong.")
                            .font(.callout).foregroundStyle(.secondary)
                        AnalyticsExportList(items: looseExports)
                            .frame(minHeight: 140)
                    }
                }
            }
            .padding(Theme.Space.section)
        }
    }
}

private struct AnalyticsMetricCard: View {
    let title: String
    let value: String
    let symbol: String
    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.tight) {
            Image(systemName: symbol).foregroundStyle(.tint)
            Text(value).font(.system(size: 28, weight: .semibold)).monospacedDigit()
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 102, alignment: .leading)
        .padding(Theme.Space.base)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.7), in: RoundedRectangle(cornerRadius: Theme.Radius.card))
    }
}

private struct AnalyticsSourceCard: View {
    @Environment(AppModel.self) private var model
    let source: WorkspaceItem
    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.snug) {
            HStack { Image(systemName: "folder.fill").foregroundStyle(.tint); Spacer(); Text(Format.relativeDate(source.contentModifiedAt)).font(.caption).foregroundStyle(.secondary) }
            Text(source.name).font(.system(size: 15, weight: .semibold)).lineLimit(2)
            Text(Format.count(source.immediateChildCount, singular: "export")).font(.caption).foregroundStyle(.secondary)
            let tags = model.tags(for: source)
            if tags.isEmpty == false { TagChipRow(tags: tags, limit: 3) }
        }
        .frame(maxWidth: .infinity, minHeight: 128, alignment: .leading)
        .padding(Theme.Space.base)
        .background(Color.accentColor.opacity(0.07), in: RoundedRectangle(cornerRadius: Theme.Radius.card))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card).strokeBorder(Color.secondary.opacity(0.16)))
        .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
    }
}

private struct AnalyticsSourceDetail: View {
    @Environment(AppModel.self) private var model
    let source: WorkspaceItem
    let onBack: () -> Void
    @State private var exports: [WorkspaceItem] = []
    @State private var unavailable = false
    private var latest: Date? { exports.compactMap(\.contentModifiedAt).max() }
    private var dataExports: Int { exports.filter { $0.kind == .data || $0.kind == .spreadsheet }.count }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Theme.Space.snug) {
                Button { onBack() } label: { Label("All sources", systemImage: "chevron.left") }
                Divider().frame(height: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text(source.name).font(.headline)
                    Text("\(exports.count) exports · \(dataExports) data files · updated \(latest.map(Format.relativeDate) ?? "—")").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button { model.revealInFinder(source.url) } label: { Label("Reveal", systemImage: "folder") }.labelStyle(.iconOnly)
            }
            .padding(.horizontal, Theme.Space.base).padding(.vertical, Theme.Space.snug)
            Divider()
            if unavailable {
                EmptyAreaState(symbol: "exclamationmark.triangle", title: "Couldn't read this source", message: "Try again after its storage provider responds.")
            } else if exports.isEmpty {
                EmptyAreaState(symbol: "tray", title: "No exports in this source", message: "Add exported data files here; they will appear in this dashboard automatically.")
            } else { AnalyticsExportList(items: exports) }
        }
        .task(id: source.id) { await load() }
    }

    @MainActor private func load() async {
        guard let read = await model.children(of: source.url) else { unavailable = true; return }
        exports = read.sorted { ($0.contentModifiedAt ?? .distantPast) > ($1.contentModifiedAt ?? .distantPast) }
        unavailable = false
    }
}

private struct AnalyticsExportList: View {
    @Environment(AppModel.self) private var model
    let items: [WorkspaceItem]
    var body: some View {
        List(items) { item in
            HStack(spacing: Theme.Space.snug) {
                Image(systemName: item.kind.symbolName).foregroundStyle(Theme.kindColor(item.kind)).frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name).lineLimit(1)
                    Text("\(item.kind.displayName) · \(item.isDirectory ? Format.count(item.immediateChildCount, singular: "item") : Format.bytes(item.byteSize)) · \(Format.relativeDate(item.contentModifiedAt))")
                        .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
            }
            .contentShape(Rectangle()).onTapGesture { model.selectedItem = item }
            .onTapGesture(count: 2) { model.open(item.url) }
            .contextMenu { ItemContextMenu(item: item) }
        }
        .listStyle(.inset)
    }
}
