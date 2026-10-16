import SwiftUI
import BetterWorkspaceCore

/// An area as a tree: subfolders open in place, one level at a time.
///
/// Most areas are folders of folders — For Reference, Review, Assets, Analytics — and a
/// flat list shows only their names. This lets someone see inside without losing their
/// place or switching to Finder. It is read-only by design: organized content is never
/// moved or restructured here, so there is no drag-to-reparent, only look, open, tag.
///
/// Built on the native hierarchical `List`, so selection, the disclosure triangles and
/// ←/→ to collapse and expand behave as in Finder. Children are read lazily: an
/// unexpanded folder holds one placeholder row, and that row appearing — which happens
/// only when someone expands the folder — is what triggers the read. Never recursive,
/// so a 70 GB asset library costs one directory read per expansion. A read that fails
/// or times out says so on that row; it is not shown as an empty folder.
struct AreaOutlineView: View {
    @Environment(AppModel.self) private var model
    /// The area's own items, already sorted, not yet filtered.
    let items: [WorkspaceItem]
    let query: String
    let sort: AreaSort
    /// The area's change revision (`AppModel.revision(ofArea:)`).
    let revision: Int

    @State private var children: [String: ChildState] = [:]

    private enum ChildState {
        case loading
        case loaded([WorkspaceItem])
        case unreadable
    }

    /// One row of the tree: an item, or a stand-in for a folder's not-yet-known contents.
    private struct Node: Identifiable {
        enum Content {
            case item(WorkspaceItem, path: String?)
            case reading(parent: WorkspaceItem)
            case unreadable(parent: WorkspaceItem)
            case empty
        }
        let id: String
        let content: Content
        var children: [Node]?
    }

    var body: some View {
        List(query.isEmpty ? tree : matches, children: \.children, selection: selection) { node in
            nodeRow(node)
        }
        .listStyle(.inset)
        // Double-click or Return opens, as in every other layout: a folder in Finder, a
        // file in its app. Expanding is the triangle or →.
        .contextMenu(forSelectionType: WorkspaceItem.ID.self) { ids in
            if let id = ids.first, let item = find(id) { ItemContextMenu(item: item) }
        } primaryAction: { ids in
            for id in ids { if let item = find(id) { model.open(item.url) } }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("area.outline")
        // A change anywhere in the area re-reads every folder already opened, in place,
        // so what is expanded stays expanded and stays true.
        .onChange(of: revision) { _, _ in reloadOpened() }
    }

    // MARK: Tree

    private func key(_ item: WorkspaceItem) -> String { item.url.canonicalPath }

    private func canExpand(_ item: WorkspaceItem) -> Bool {
        item.isDirectory && (item.immediateChildCount ?? 1) > 0
    }

    private var tree: [Node] { items.map(node) }

    private func node(_ item: WorkspaceItem) -> Node {
        var node = Node(id: item.id, content: .item(item, path: nil), children: nil)
        guard canExpand(item) else { return node }
        switch children[key(item)] {
        case .loaded(let list)?:
            node.children = list.isEmpty ? [Node(id: "empty:" + key(item), content: .empty)] : list.map(self.node)
        case .unreadable?:
            node.children = [Node(id: "unreadable:" + key(item), content: .unreadable(parent: item))]
        case nil, .loading?:
            node.children = [Node(id: "reading:" + key(item), content: .reading(parent: item))]
        }
        return node
    }

    @ViewBuilder
    private func nodeRow(_ node: Node) -> some View {
        switch node.content {
        case let .item(item, path):
            row(item, path: path)
        case .reading(let parent):
            HStack(spacing: Theme.Space.tight) {
                ProgressView().controlSize(.small)
                Text("Reading…").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            // Only ever on screen once the folder is expanded: that is the request.
            .onAppear { load(parent) }
        case .unreadable(let parent):
            HStack(spacing: Theme.Space.tight) {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                Text("Couldn't read this folder").font(.system(size: 11)).foregroundStyle(.secondary)
                Button("Try Again") { load(parent, retry: true) }.buttonStyle(.link).font(.system(size: 11))
            }
        case .empty:
            Text("Empty").font(.system(size: 11)).foregroundStyle(.tertiary)
        }
    }

    private func row(_ item: WorkspaceItem, path: String?) -> some View {
        HStack(spacing: Theme.Space.tight) {
            Image(systemName: item.kind.symbolName)
                .foregroundStyle(Theme.kindColor(item.kind))
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.displayTitle).lineLimit(1)
                if let path {
                    Text(path).font(.system(size: 10)).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.head)
                }
            }
            let tags = model.tags(for: item)
            if tags.isEmpty == false { TagChipRow(tags: tags, limit: 2) }
            Spacer(minLength: Theme.Space.tight)
            Text(item.isDirectory ? Format.count(item.immediateChildCount, singular: "item")
                                  : Format.bytes(item.byteSize))
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 72, alignment: .trailing)
            Text(Format.relativeDate(item.contentModifiedAt))
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .frame(width: 92, alignment: .trailing)
        }
        .contentShape(Rectangle())
    }

    // MARK: Loading

    private func load(_ item: WorkspaceItem, retry: Bool = false) {
        let path = key(item)
        // Already read, or being read: nothing to do. A failure waits for Try Again.
        if retry == false, children[path] != nil { return }
        children[path] = .loading
        let url = item.url
        let sort = sort
        Task { @MainActor in
            if let read = await model.children(of: url) {
                children[path] = .loaded(Self.ordered(read, by: sort))
            } else {
                children[path] = .unreadable
            }
        }
    }

    private func reloadOpened() {
        let sort = sort
        for (path, state) in children {
            guard case .loaded = state else { continue }
            Task { @MainActor in
                // A folder that has gone reads as nothing; one that failed keeps its rows.
                if let read = await model.children(of: URL(fileURLWithPath: path)) {
                    children[path] = .loaded(Self.ordered(read, by: sort))
                }
            }
        }
    }

    /// Folders first, as in Finder's list view, then the area's own sort.
    private static func ordered(_ items: [WorkspaceItem], by sort: AreaSort) -> [WorkspaceItem] {
        let sorted = items.sorted(by: sort)
        return sorted.filter(\.isDirectory) + sorted.filter { $0.isDirectory == false }
    }

    // MARK: Search

    /// While searching, a flat list of every match among what has been opened, each
    /// with the path to it. Nothing is walked on someone's behalf: expanding a folder is
    /// what brings its contents into reach, and the empty state says so.
    private var matches: [Node] {
        var found: [Node] = []
        func visit(_ list: [WorkspaceItem], trail: [String]) {
            for item in list {
                if item.displayTitle.localizedCaseInsensitiveContains(query) {
                    found.append(Node(id: item.id,
                                      content: .item(item, path: trail.isEmpty ? nil : trail.joined(separator: " › ")),
                                      children: nil))
                }
                if case .loaded(let inside)? = children[key(item)] {
                    visit(inside, trail: trail + [item.displayTitle])
                }
            }
        }
        visit(items, trail: [])
        return found
    }

    // MARK: Selection

    /// Selection spans every loaded level, so the inspector follows a nested file too.
    private var selection: Binding<String?> {
        Binding(
            get: { model.selectedItem?.id },
            set: { id in model.selectedItem = id.flatMap(find) }
        )
    }

    private func find(_ id: String) -> WorkspaceItem? {
        items.first(where: { $0.id == id })
            ?? children.values.lazy.compactMap { state -> WorkspaceItem? in
                if case .loaded(let list) = state { return list.first { $0.id == id } }
                return nil
            }.first
    }
}
