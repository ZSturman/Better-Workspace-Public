import SwiftUI
import BetterWorkspaceCore

/// Assets: exactly two immediate children — `Data` (60 GB, dominated by one dump of
/// 4,338 mp4 files) and `Media` (726 MB across 13 named buckets like `svgs`,
/// `stockImages`, `portfolio`).
///
/// Listing 4,734 files here would be useless. The meaningful unit is the **bucket**, so
/// the top level is a library of collection cards — count, size, cover image — and you
/// drill in to a grid only when you've picked one.
struct AssetsView: View {
    @Environment(AppModel.self) private var model
    @State private var collections: [Collection] = []
    @State private var drilled: WorkspaceItem?
    @State private var drillItems: [WorkspaceItem] = []
    @State private var loading = true

    struct Collection: Identifiable {
        let library: WorkspaceItem
        let bucket: WorkspaceItem
        var cover: URL?
        var fileCount: Int?
        var byteSize: Int64?
        var id: String { bucket.id }
    }

    private var libraries: [WorkspaceItem] { model.items(for: .assets) }

    /// Not read yet, so an empty list here would be a false "nothing".
    private var showsLoading: Bool { loading || (collections.isEmpty && model.isAwaitingFirstRead(of: .assets)) }

    var body: some View {
        VStack(spacing: 0) {
            AreaHeader(title: "Assets", subtitle: model.headerSubtitle(for: .assets),
                       symbol: model.settings(for: .assets).symbol,
                       count: showsLoading ? nil : drilled == nil ? collections.count : drillItems.count) {
                if drilled != nil {
                    Button { drilled = nil; drillItems = [] } label: {
                        Label("All collections", systemImage: "chevron.left")
                    }
                }
            }
            Divider()

            if showsLoading {
                LoadingAreaState(title: "Loading collections…")
            } else if let drilled {
                drillView(drilled)
            } else if collections.isEmpty {
                EmptyAreaState(symbol: "shippingbox", title: "No collections",
                               message: "Assets holds libraries of media and data buckets.")
            } else {
                collectionGrid
            }
        }
        // Any change below Assets, not just a new library: a bucket added inside one
        // kept the old count and was never shown.
        .task(id: model.revision(ofArea: WorkspaceArea.assets.directoryName)) {
            await load()
            await reloadDrill()
        }
    }

    private var collectionGrid: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Theme.Space.loose) {
                ForEach(libraries) { library in
                    let members = collections.filter { $0.library.id == library.id }
                    if members.isEmpty == false {
                        VStack(alignment: .leading, spacing: Theme.Space.snug) {
                            HStack(spacing: Theme.Space.tight) {
                                Text(library.name).font(.system(size: 13, weight: .semibold))
                                Text("\(members.count)")
                                    .font(.system(size: 11).monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: Theme.Space.snug)],
                                      spacing: Theme.Space.snug) {
                                ForEach(members) { collection in
                                    CollectionCard(
                                        collection: collection,
                                        isSelected: model.selectedItem?.id == collection.bucket.id
                                    )
                                    .onTapGesture { model.selectedItem = collection.bucket }
                                    .onTapGesture(count: 2) { Task { await drill(collection.bucket) } }
                                    .contextMenu { ItemContextMenu(item: collection.bucket) }
                                }
                            }
                        }
                    }
                }
            }
            .padding(Theme.Space.base)
        }
    }

    private func drillView(_ bucket: WorkspaceItem) -> some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: Theme.Space.snug)],
                      spacing: Theme.Space.base) {
                ForEach(drillItems.prefix(600)) { item in
                    VStack(spacing: 4) {
                        ThumbnailImage(url: item.url, kind: item.kind, size: 130)
                        Text(item.name).font(.system(size: 10)).lineLimit(1).foregroundStyle(.secondary)
                    }
                    .onTapGesture(count: 2) { QuickLookController.shared.preview([item.url]) }
                    .contextMenu { ItemContextMenu(item: item) }
                }
            }
            .padding(Theme.Space.base)

            if drillItems.count > 600 {
                Text("Showing the first 600 of \(drillItems.count) items.")
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.bottom, Theme.Space.base)
            }
        }
    }

    @MainActor
    private func drill(_ bucket: WorkspaceItem) async {
        drilled = bucket
        drillItems = []
        await reloadDrill()
    }

    /// Only the bucket still open may fill the view, and a failed read keeps what is
    /// shown rather than presenting an unreadable bucket as empty.
    @MainActor
    private func reloadDrill() async {
        guard let bucket = drilled else { return }
        guard let read = try? await model.fs.items(inDirectory: bucket.url), drilled?.id == bucket.id else { return }
        drillItems = read
    }

    @MainActor
    private func load() async {
        // A spinner only the first time; a refresh swaps the content in place.
        loading = collections.isEmpty
        var found: [Collection] = []
        for library in libraries where library.isDirectory {
            let buckets = (try? await model.fs.items(inDirectory: library.url)) ?? []
            for bucket in buckets {
                found.append(Collection(library: library, bucket: bucket))
            }
        }
        collections = found
        loading = false

        // Covers and counts stream in after first paint — Assets is 61 GB.
        for (index, collection) in found.enumerated() {
            let cover = await model.fs.representativeImage(in: collection.bucket.url)
            await MainActor.run {
                if collections.indices.contains(index) { collections[index].cover = cover }
            }
        }
    }
}

private struct CollectionCard: View {
    @Environment(AppModel.self) private var model
    let collection: AssetsView.Collection
    let isSelected: Bool
    @State private var measured: (count: Int, bytes: Int64)?
    @State private var measuring = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack {
                if let cover = collection.cover {
                    ThumbnailImage(url: cover, kind: .image, size: 190, cornerRadius: 0)
                        .frame(height: 96)
                        .clipped()
                } else {
                    Rectangle()
                        .fill(Theme.kindColor(.folder).opacity(0.12))
                        .frame(height: 96)
                        .overlay {
                            Image(systemName: "shippingbox")
                                .font(.system(size: 24, weight: .light))
                                .foregroundStyle(Theme.kindColor(.folder).opacity(0.7))
                        }
                }
            }
            .frame(maxWidth: .infinity)
            .clipped()

            VStack(alignment: .leading, spacing: 4) {
                Text(collection.bucket.name)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                HStack(spacing: 5) {
                    Text(Format.count(collection.bucket.immediateChildCount, singular: "item"))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    if let measured {
                        Text("·").font(.system(size: 10)).foregroundStyle(.tertiary)
                        Text("\(measured.count) files · \(Format.bytes(measured.bytes))")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                    } else if measuring {
                        ProgressView().controlSize(.mini)
                    } else {
                        Button("size") { Task { await measure() } }
                            .buttonStyle(.link).font(.system(size: 10))
                    }
                }
                let tags = model.tags(for: collection.bucket)
                if tags.isEmpty == false { TagChipRow(tags: tags, limit: 2) }
            }
            .padding(Theme.Space.snug)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.card)
                .strokeBorder(isSelected ? Color.accentColor : Color.secondary.opacity(0.18),
                              lineWidth: isSelected ? 1.5 : 0.75)
        )
    }

    @MainActor
    private func measure() async {
        measuring = true
        defer { measuring = false }
        let count = await model.fs.recursiveFileCount(of: collection.bucket.url)
        let bytes = await model.fs.recursiveSize(of: collection.bucket.url)
        measured = (count, bytes)
    }
}
