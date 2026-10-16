import SwiftUI
import BetterWorkspaceCore

/// References: 6 tiny curated folders, each holding one to three real files —
/// usually a single Markdown document, sometimes a couple of reference images.
///
/// These exist to be *read*, so the interface is a reader: a narrow list on the left
/// and the document itself rendered on the right. No columns, no grid.
struct ReferencesView: View {
    @Environment(AppModel.self) private var model
    @State private var selected: WorkspaceItem?
    @State private var documentURL: URL?
    @State private var documentText: String?
    @State private var siblings: [WorkspaceItem] = []

    private var items: [WorkspaceItem] { model.items(for: .references) }

    /// Not read yet, so an empty list here would be a false "nothing".
    private var showsLoading: Bool { items.isEmpty && model.isAwaitingFirstRead(of: .references) }

    var body: some View {
        VStack(spacing: 0) {
            AreaHeader(title: "For Reference", subtitle: model.headerSubtitle(for: .references),
                       symbol: model.settings(for: .references).symbol, count: showsLoading ? nil : items.count)
            Divider()

            if showsLoading {
                LoadingAreaState(title: "Loading references…")
            } else if items.isEmpty {
                EmptyAreaState(symbol: "book.closed", title: "No reference material",
                               message: "Classify an ingest item into For Reference to see it here.")
            } else {
                HSplitView {
                    list
                        .frame(minWidth: 200, idealWidth: 250, maxWidth: 340)
                    reader
                        .frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .task(id: items.count) { if selected == nil { await select(items.first) } }
        // The open document is re-read when anything under For Reference changes, so an
        // edit made in another app shows up here instead of the text from first click.
        .onChange(of: model.revision(ofArea: WorkspaceArea.references.directoryName)) { _, _ in
            guard let current = selected else { return }
            let fresh = items.first { $0.id == current.id }
            Task { await load(fresh ?? current, resetting: false) }
        }
    }

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(items) { item in
                    Button { Task { await select(item) } } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: Theme.Space.tight) {
                                Image(systemName: item.isDirectory ? "folder" : item.kind.symbolName)
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                                Text(item.displayTitle)
                                    .font(.system(size: 13, weight: .medium))
                                    .lineLimit(2)
                                    .multilineTextAlignment(.leading)
                            }
                            let tags = model.tags(for: item)
                            if tags.isEmpty == false { TagChipRow(tags: tags, limit: 3) }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, Theme.Space.snug)
                        .padding(.vertical, Theme.Space.snug)
                        .background(selected?.id == item.id ? Color.accentColor.opacity(0.15) : .clear)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .contextMenu { ItemContextMenu(item: item) }
                    Divider()
                }
            }
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.35))
    }

    @ViewBuilder
    private var reader: some View {
        if let selected {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.base) {
                    Text(selected.displayTitle)
                        .font(.system(size: 22, weight: .semibold))

                    if siblings.count > 1 {
                        Text(siblings.map(\.name).joined(separator: " · "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if let documentText {
                        MarkdownView(text: documentText)
                    } else if let imageSiblings = imageSiblings, imageSiblings.isEmpty == false {
                        // A reference that *is* one image should be shown at a size worth
                        // reading, not as a thumbnail marooned in an empty pane.
                        let size: CGFloat = imageSiblings.count == 1 ? 460 : 190
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: size), spacing: Theme.Space.snug)],
                                  spacing: Theme.Space.base) {
                            ForEach(imageSiblings) { image in
                                VStack(spacing: 5) {
                                    ThumbnailImage(url: image.url, kind: image.kind,
                                                   size: size, contentMode: .fit)
                                    Text(image.name).font(.system(size: 10)).lineLimit(1)
                                        .foregroundStyle(.secondary)
                                }
                                .onTapGesture(count: 2) { QuickLookController.shared.preview([image.url]) }
                            }
                        }
                    } else {
                        Text("No readable document in this reference.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: 720, alignment: .leading)
                .padding(Theme.Space.loose)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        } else {
            EmptyAreaState(symbol: "doc.text", title: "Select a reference", message: "Pick an item to read it here.")
        }
    }

    private var imageSiblings: [WorkspaceItem]? {
        siblings.filter { $0.kind == .image }
    }

    @MainActor
    private func select(_ item: WorkspaceItem?) async {
        selected = item
        model.selectedItem = item
        guard let item else {
            documentText = nil; documentURL = nil; siblings = []
            return
        }
        await load(item, resetting: true)
    }

    /// Reads a reference's document and contents. Every result is checked against what
    /// is selected *now*: clicking two references quickly used to be able to show the
    /// first one's text under the second one's name.
    @MainActor
    private func load(_ item: WorkspaceItem, resetting: Bool) async {
        if resetting { documentText = nil; documentURL = nil; siblings = [] }
        var newSiblings: [WorkspaceItem] = []
        var newURL: URL?
        var newText: String?
        if item.isDirectory {
            newSiblings = (try? await model.fs.items(inDirectory: item.url)) ?? siblings
            if let doc = await model.fs.primaryDocument(in: item.url) {
                newURL = doc
                newText = await model.fs.readText(at: doc)
            }
        } else if item.kind == .markdown || item.kind == .document {
            newURL = item.url
            newText = await model.fs.readText(at: item.url)
        }
        guard selected?.id == item.id else { return }
        siblings = newSiblings
        documentURL = newURL
        documentText = newText
    }
}
