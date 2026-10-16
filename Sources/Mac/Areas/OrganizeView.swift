import SwiftUI
import BetterWorkspaceCore

/// Organize: 180 items, 56 GB, modification dates spanning 2022-12 to today, and
/// absolutely nothing in common — pdf, xlsx, heic, zip, stl, csv, wav, ics, docx, dmg,
/// blend, mp4, plus 44 folders.
///
/// The only axes that mean anything here are *how old* and *how big*, so this is a
/// triage table led by an age histogram. Finder will sort by date; it won't tell you
/// that eleven things have been sitting untouched since December 2022.
struct OrganizeView: View {
    @Environment(AppModel.self) private var model
    @State private var query = ""
    @State private var kindFilter: FileKind?
    @State private var ageFilter: String?
    @State private var sortOrder = [KeyPathComparator(\Row.modified, order: .forward)]
    @State private var sizes: [String: Int64] = [:]

    struct Row: Identifiable {
        let id: String
        let item: WorkspaceItem
        let name: String
        let kindName: String
        let modified: Date
        let age: String
        let size: Int64
    }

    private var allRows: [Row] {
        model.items(for: .organize).map { item in
            Row(id: item.id, item: item, name: item.displayTitle,
                kindName: item.isDirectory ? "Folder" : (item.fileExtension.isEmpty ? item.kind.displayName : item.fileExtension.uppercased()),
                modified: item.contentModifiedAt ?? .distantPast,
                age: Format.ageBand(item.contentModifiedAt),
                size: sizes[item.url.path] ?? item.byteSize)
        }
    }

    private var rows: [Row] {
        var result = allRows
        if let kindFilter { result = result.filter { $0.item.kind == kindFilter } }
        if let ageFilter { result = result.filter { $0.age == ageFilter } }
        if query.isEmpty == false { result = result.filter { $0.name.localizedCaseInsensitiveContains(query) } }
        return result.sorted(using: sortOrder)
    }

    private var ageHistogram: [(String, Int)] {
        var counts: [String: Int] = [:]
        for row in allRows { counts[row.age, default: 0] += 1 }
        return Format.ageBandOrder.compactMap { band in counts[band].map { (band, $0) } }
    }

    private var kindCounts: [(FileKind, Int)] {
        var counts: [FileKind: Int] = [:]
        for item in model.items(for: .organize) { counts[item.kind, default: 0] += 1 }
        return counts.sorted { $0.value > $1.value }.map { ($0.key, $0.value) }
    }

    /// Not read yet, so an empty list here would be a false "nothing".
    private var showsLoading: Bool { rows.isEmpty && model.isAwaitingFirstRead(of: .organize) }

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            AreaHeader(title: "To Organize", subtitle: model.headerSubtitle(for: .organize),
                       symbol: model.settings(for: .organize).symbol, count: showsLoading ? nil : rows.count) {
                HStack(spacing: Theme.Space.snug) {
                    InlineSearchField(text: $query, prompt: "Search the backlog", width: 180)
                    Menu {
                        Button("All types") { kindFilter = nil }
                        Divider()
                        ForEach(kindCounts, id: \.0) { kind, count in
                            Button("\(kind.displayName) (\(count))") { kindFilter = kind }
                        }
                    } label: {
                        Label(kindFilter?.displayName ?? "All types", systemImage: "line.3.horizontal.decrease.circle")
                    }
                    .menuStyle(.borderlessButton).fixedSize()

                    Button {
                        Task { await computeSizes() }
                    } label: {
                        Label("Sizes", systemImage: "ruler")
                    }
                    .fixedSize()
                    .help("Measure folder sizes. This area holds tens of gigabytes, so it is opt-in.")
                }
            }

            ageStrip
            Divider()

            if showsLoading {
                LoadingAreaState(title: "Loading To Organize…")
            } else if rows.isEmpty {
                EmptyAreaState(symbol: "tray", title: "Nothing to triage", message: "This filter matches no items.")
            } else {
                Table(rows, selection: Binding(
                    get: { model.selectedItem.map { Set([$0.id]) } ?? [] },
                    set: { ids in
                        if let id = ids.first, let row = rows.first(where: { $0.id == id }) {
                            model.selectedItem = row.item
                        }
                    }
                ), sortOrder: $sortOrder) {
                    TableColumn("Name", value: \.name) { row in
                        HStack(spacing: Theme.Space.tight) {
                            Image(systemName: row.item.kind.symbolName)
                                .foregroundStyle(Theme.kindColor(row.item.kind))
                                .frame(width: 14)
                            Text(row.name).lineLimit(1)
                            let tags = model.tags(for: row.item)
                            if tags.isEmpty == false { TagChipRow(tags: tags, limit: 2) }
                        }
                    }
                    .width(min: 220, ideal: 340)

                    TableColumn("Type", value: \.kindName) { row in
                        Text(row.kindName).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    .width(min: 55, ideal: 80)

                    TableColumn("Size", value: \.size) { row in
                        Text(row.size > 0 ? Format.bytes(row.size) : (row.item.isDirectory ? "—" : "0 bytes"))
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    .width(min: 60, ideal: 80)

                    TableColumn("Age", value: \.modified) { row in
                        Text(Format.shortDate(row.item.contentModifiedAt))
                            .font(.system(size: 11))
                            .foregroundStyle(row.age == "Over 2 years" ? .orange : .secondary)
                    }
                    .width(min: 80, ideal: 110)
                }
                .tableStyle(.inset)
                .contextMenu(forSelectionType: String.self) { ids in
                    if let id = ids.first, let row = rows.first(where: { $0.id == id }) {
                        ItemContextMenu(item: row.item)
                    }
                } primaryAction: { ids in
                    if let id = ids.first, let row = rows.first(where: { $0.id == id }) {
                        QuickLookController.shared.preview([row.item.url])
                    }
                }
            }
        }
    }

    /// The thing Finder won't show you: the shape of the backlog by age.
    private var ageStrip: some View {
        HStack(spacing: Theme.Space.tight) {
            ForEach(ageHistogram, id: \.0) { band, count in
                Button {
                    ageFilter = (ageFilter == band) ? nil : band
                } label: {
                    VStack(spacing: 2) {
                        Text("\(count)")
                            .font(.system(size: 13, weight: .semibold).monospacedDigit())
                        Text(band)
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 7)
                            .fill(ageFilter == band ? Color.accentColor.opacity(0.22) : Color.secondary.opacity(0.09))
                    )
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("organize.ageBand.\(band)")
            }
        }
        .padding(.horizontal, Theme.Space.base)
        .padding(.bottom, Theme.Space.snug)
    }

    @MainActor
    private func computeSizes() async {
        for item in model.items(for: .organize) where item.isDirectory {
            let size = await model.fs.recursiveSize(of: item.url)
            await MainActor.run { sizes[item.url.path] = size }
        }
    }
}
