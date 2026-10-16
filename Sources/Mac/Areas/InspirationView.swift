import SwiftUI
import BetterWorkspaceCore

/// Inspiration: 249 jpeg, 90 png, 22 webp, 9 mov — 17 images sitting loose at the top
/// level and 5 themed folders, one of which (`NEEDS TO BE ORGANIZED`) hides 355 files.
///
/// This is pixels, so it gets a gallery. The useful trick Finder can't do is **Flatten**:
/// dissolve the subfolders and show every image in the area at once, so the 355 buried
/// ones are browsable next to the loose ones.
struct InspirationView: View {
    @Environment(AppModel.self) private var model
    @State private var thumbSize: Double = 150
    @State private var flattened = false
    @State private var flatItems: [WorkspaceItem] = []
    @State private var loading = false
    @State private var drillPath: [WorkspaceItem] = []
    @State private var drillItems: [WorkspaceItem] = []

    private var topLevel: [WorkspaceItem] { model.items(for: .inspiration) }

    private var displayed: [WorkspaceItem] {
        if flattened { return flatItems }
        if drillPath.isEmpty == false { return drillItems }
        return topLevel
    }

    /// Not read yet, so an empty list here would be a false "nothing".
    private var showsLoading: Bool { loading || (displayed.isEmpty && drillPath.isEmpty && flattened == false
                                                && model.isAwaitingFirstRead(of: .inspiration)) }

    var body: some View {
        VStack(spacing: 0) {
            AreaHeader(title: "For Inspiration", subtitle: model.headerSubtitle(for: .inspiration),
                       symbol: model.settings(for: .inspiration).symbol, count: showsLoading ? nil : displayed.count) {
                HStack(spacing: Theme.Space.snug) {
                    Toggle(isOn: $flattened) {
                        Label("Flatten", systemImage: "square.stack.3d.down.right")
                    }
                    .toggleStyle(.button)
                    .accessibilityIdentifier("inspiration.flatten")
                    .help("Show every image and video in this area, including inside subfolders")

                    HStack(spacing: 5) {
                        Image(systemName: "photo").font(.system(size: 9)).foregroundStyle(.secondary)
                        Slider(value: $thumbSize, in: 90...260).frame(width: 110)
                        Image(systemName: "photo").font(.system(size: 14)).foregroundStyle(.secondary)
                    }
                }
            }

            if drillPath.isEmpty == false && flattened == false {
                breadcrumb
            }
            Divider()

            if showsLoading {
                LoadingAreaState(title: "Loading media…")
            } else if displayed.isEmpty {
                EmptyAreaState(symbol: "photo.on.rectangle.angled", title: "Nothing here",
                               message: "No images or video in this folder.")
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: Theme.Space.base) {
                        ForEach(displayed) { item in
                            cell(for: item)
                        }
                    }
                    .padding(Theme.Space.base)
                }
            }
        }
        .task(id: flattened) { if flattened { await loadFlat() } }
        // Anything added, removed or renamed below For Inspiration re-reads whichever
        // view is open, instead of leaving a drilled or flattened snapshot behind.
        .onChange(of: model.revision(ofArea: WorkspaceArea.inspiration.directoryName)) { _, _ in
            Task { @MainActor in
                if flattened { await loadFlat() } else { await reloadDrill() }
            }
        }
    }

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: CGFloat(thumbSize)), spacing: Theme.Space.snug)]
    }

    private func cell(for item: WorkspaceItem) -> some View {
        GalleryCell(item: item, size: thumbSize, isSelected: model.selectedItem?.id == item.id)
            .onTapGesture(count: 2) { open(item) }
            .onTapGesture { model.selectedItem = item }
            .contextMenu { ItemContextMenu(item: item) }
    }

    private var breadcrumb: some View {
        HStack(spacing: 4) {
            Button("For Inspiration") { drillPath = []; drillItems = [] }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
            ForEach(Array(drillPath.enumerated()), id: \.element.id) { index, crumb in
                crumbButton(crumb, index: index)
            }
            Spacer()
        }
        .font(.system(size: 11))
        .padding(.horizontal, Theme.Space.base)
        .padding(.bottom, Theme.Space.tight)
    }

    private func crumbButton(_ crumb: WorkspaceItem, index: Int) -> some View {
        let isLast = index == drillPath.count - 1
        return HStack(spacing: 4) {
            Image(systemName: "chevron.right")
                .font(.system(size: 8))
                .foregroundStyle(.tertiary)
            Button(crumb.name) { Task { await drill(to: index) } }
                .buttonStyle(.plain)
                .foregroundStyle(isLast ? Color.primary : Color.accentColor)
        }
    }

    private func open(_ item: WorkspaceItem) {
        if item.isDirectory {
            drillPath.append(item)
            drillItems = []
            Task { await reloadDrill() }
        } else {
            QuickLookController.shared.preview([item.url])
        }
    }

    @MainActor
    private func drill(to index: Int) async {
        drillPath = Array(drillPath.prefix(index + 1))
        await reloadDrill()
    }

    /// Reads the folder currently drilled into. Guarded, because two quick clicks can
    /// finish in either order and only the folder still on screen may fill it; and a
    /// failed read keeps what is shown, since an unreadable folder is not an empty one.
    @MainActor
    private func reloadDrill() async {
        guard let folder = drillPath.last else { drillItems = []; return }
        guard let read = try? await model.fs.items(inDirectory: folder.url),
              drillPath.last?.id == folder.id else { return }
        drillItems = read
    }

    @MainActor
    private func loadFlat() async {
        loading = true
        defer { loading = false }
        let root = model.workspace.url(for: .inspiration)
        flatItems = await model.fs.media(under: root)
    }
}

struct GalleryCell: View {
    @Environment(AppModel.self) private var model
    let item: WorkspaceItem
    let size: Double
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ZStack(alignment: .bottomTrailing) {
                if item.isDirectory {
                    FolderCover(item: item, size: size)
                } else {
                    ThumbnailImage(url: item.url, kind: item.kind, size: size)
                }
                if item.kind == .video {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(.white, .black.opacity(0.45))
                        .padding(5)
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.card)
                    .strokeBorder(isSelected ? Color.accentColor : Color.clear, lineWidth: 2)
            )

            Text(item.displayTitle)
                .font(.system(size: 11))
                .lineLimit(1)
                .foregroundStyle(isSelected ? .primary : .secondary)
            let tags = model.tags(for: item)
            if tags.isEmpty == false { TagChipRow(tags: tags, limit: 2) }
        }
        .frame(width: size)
    }
}

private struct FolderCover: View {
    @Environment(AppModel.self) private var model
    let item: WorkspaceItem
    let size: Double
    @State private var cover: URL?

    var body: some View {
        ZStack {
            if let cover {
                ThumbnailImage(url: cover, kind: .image, size: size)
                    .overlay(alignment: .topLeading) {
                        Image(systemName: "folder.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.white)
                            .padding(4)
                            .background(.black.opacity(0.4), in: Circle())
                            .padding(5)
                    }
            } else {
                RoundedRectangle(cornerRadius: Theme.Radius.card)
                    .fill(Theme.kindColor(.folder).opacity(0.12))
                    .frame(width: size, height: size)
                    .overlay {
                        VStack(spacing: 5) {
                            Image(systemName: "folder")
                                .font(.system(size: size * 0.22, weight: .light))
                            Text(Format.count(item.immediateChildCount, singular: "item"))
                                .font(.system(size: 10))
                        }
                        .foregroundStyle(Theme.kindColor(.folder).opacity(0.8))
                    }
            }
        }
        .task(id: item.url.path) { @MainActor in
            cover = await model.fs.representativeImage(in: item.url)
        }
    }
}
