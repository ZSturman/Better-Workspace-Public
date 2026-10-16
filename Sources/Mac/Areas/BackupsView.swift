import SwiftUI
import BetterWorkspaceCore

/// Backups: two opaque snapshots — an SD-card image (`Ender3v2_microsd`, 461 MB) and a
/// dated export (`telemetry-consolidation-20260917-214818`, 702 MB).
///
/// The only questions a person has here are *when*, *how big*, and *what's inside*, so
/// this is a vault list: date-led rows, an expandable manifest, and an explicit
/// read-only stance. Nothing in this view can modify anything.
struct BackupsView: View {
    @Environment(AppModel.self) private var model
    @State private var expanded: Set<String> = []
    @State private var details: [String: ItemDetail] = [:]
    @State private var measuring: Set<String> = []

    private var items: [WorkspaceItem] {
        model.items(for: .backups).sorted {
            ($0.contentModifiedAt ?? .distantPast) > ($1.contentModifiedAt ?? .distantPast)
        }
    }

    /// Not read yet, so an empty list here would be a false "nothing".
    private var showsLoading: Bool { items.isEmpty && model.isAwaitingFirstRead(of: .backups) }

    var body: some View {
        VStack(spacing: 0) {
            AreaHeader(title: "Backups", subtitle: model.headerSubtitle(for: .backups),
                       symbol: model.settings(for: .backups).symbol, count: showsLoading ? nil : items.count) {
                Label("Read-only", systemImage: "lock")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .help("This app never modifies backup contents")
            }
            Divider()

            if showsLoading {
                LoadingAreaState(title: "Loading backups…")
            } else if items.isEmpty {
                EmptyAreaState(symbol: "externaldrive", title: "No backups",
                               message: "Snapshots placed in Backups will be listed here.")
            } else {
                ScrollView {
                    LazyVStack(spacing: Theme.Space.snug) {
                        ForEach(items) { item in
                            snapshotRow(item)
                        }
                    }
                    .padding(Theme.Space.base)
                }
            }
        }
        .task(id: model.revision(ofArea: WorkspaceArea.backups.directoryName)) { @MainActor in
            for item in items { details[item.url.path] = await model.probe.detail(for: item) }
        }
    }

    private func snapshotRow(_ item: WorkspaceItem) -> some View {
        let isOpen = expanded.contains(item.id)
        let detail = details[item.url.path]
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Theme.Space.snug) {
                Button {
                    if isOpen { expanded.remove(item.id) } else { expanded.insert(item.id) }
                } label: {
                    Image(systemName: isOpen ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 12)
                }
                .buttonStyle(.plain)

                Image(systemName: "externaldrive.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(.tint)

                VStack(alignment: .leading, spacing: 2) {
                    Text(item.displayTitle).font(.system(size: 14, weight: .medium))
                    HStack(spacing: Theme.Space.tight) {
                        Text(Format.shortDate(item.contentModifiedAt))
                        Text("·")
                        Text(Format.count(item.immediateChildCount, singular: "top-level item"))
                        if let bytes = detail?.recursiveByteSize {
                            Text("·")
                            Text(Format.bytes(bytes))
                        }
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                }

                Spacer()

                let tags = model.tags(for: item)
                if tags.isEmpty == false { TagChipRow(tags: tags, limit: 3) }

                if detail?.recursiveByteSize == nil {
                    if measuring.contains(item.url.path) {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("Measure") { Task { await measure(item) } }
                            .buttonStyle(.link).font(.system(size: 11))
                    }
                }
                Button("Reveal") { model.revealInFinder(item.url) }
                    .buttonStyle(.link).font(.system(size: 11))
            }
            .padding(Theme.Space.snug)
            .contentShape(Rectangle())
            .onTapGesture { model.selectedItem = item }

            if isOpen, let names = detail?.immediateNames {
                Divider().padding(.leading, Theme.Space.loose)
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(names.prefix(40), id: \.self) { name in
                        HStack(spacing: Theme.Space.tight) {
                            Image(systemName: "doc").font(.system(size: 9)).foregroundStyle(.tertiary)
                            Text(name).font(.system(size: 11, design: .monospaced))
                        }
                    }
                    if names.count > 40 {
                        Text("+\(names.count - 40) more").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, Theme.Space.loose)
                .padding(.vertical, Theme.Space.snug)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.card)
                .strokeBorder(model.selectedItem?.id == item.id ? Color.accentColor : Color.secondary.opacity(0.18),
                              lineWidth: model.selectedItem?.id == item.id ? 1.5 : 0.75)
        )
        .contextMenu { ItemContextMenu(item: item) }
    }

    @MainActor
    private func measure(_ item: WorkspaceItem) async {
        measuring.insert(item.url.path)
        defer { measuring.remove(item.url.path) }
        details[item.url.path] = await model.probe.deepDetail(for: item, fs: model.fs)
    }
}
