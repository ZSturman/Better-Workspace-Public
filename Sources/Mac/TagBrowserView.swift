import SwiftUI
import BetterWorkspaceCore

/// What a single shared tag repository buys you: one tag, every area at once.
struct TagBrowserView: View {
    @Environment(AppModel.self) private var model
    let tag: Tag

    @State private var objects: [TaggedObject] = []

    private var missingCount: Int {
        objects.filter { FileManager.default.fileExists(atPath: $0.lastPath) == false }.count
    }

    private var grouped: [(String, [TaggedObject])] {
        Dictionary(grouping: objects, by: { $0.area ?? "Elsewhere" })
            .sorted { lhs, rhs in
                // Sidebar order, so a tag reads the same way the Workspace does; areas
                // no longer present sort after it, and loose items last.
                let order = model.folders.map(\.name)
                let left = lhs.key == "Elsewhere" ? Int.max : (order.firstIndex(of: lhs.key) ?? order.count)
                let right = rhs.key == "Elsewhere" ? Int.max : (order.firstIndex(of: rhs.key) ?? order.count)
                if left != right { return left < right }
                return lhs.key.localizedStandardCompare(rhs.key) == .orderedAscending
            }
    }

    private func objectRow(_ object: TaggedObject) -> some View {
        let exists = FileManager.default.fileExists(atPath: object.lastPath)
        // Name on top, location underneath — the path used to squeeze the name and the
        // Reveal button into whatever was left.
        return HStack(alignment: .firstTextBaseline, spacing: Theme.Space.snug) {
            Image(systemName: exists ? "doc" : "questionmark.square.dashed")
                .font(.system(size: 11))
                .foregroundStyle(exists ? Color.secondary : Color.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(object.displayName)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Text(exists ? object.lastPath : "Missing — \(object.lastPath)")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(exists ? .tertiary : .secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .help(object.lastPath)
            }
            Spacer(minLength: Theme.Space.snug)
            if exists {
                Button("Reveal") {
                    model.revealInFinder(URL(fileURLWithPath: object.lastPath))
                }
                .buttonStyle(.link)
                .font(.system(size: 10))
            }
        }
        .padding(.horizontal, Theme.Space.snug)
        .padding(.vertical, Theme.Space.tight)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
    }

    var body: some View {
        VStack(spacing: 0) {
            AreaHeader(title: tag.name, subtitle: nil,
                       symbol: "tag", count: objects.count) {
                if missingCount > 0 {
                    Button {
                        model.forgetMissing(tag: tag)
                        objects = model.objects(withTag: tag)
                    } label: {
                        Label("Forget \(missingCount) missing", systemImage: "trash")
                    }
                    .help("Removes this app's records for files that no longer exist. Nothing on disk is touched.")
                }
            }
            Divider()

            if objects.isEmpty {
                EmptyAreaState(symbol: "tag", title: "Not used yet",
                               message: "Assign “\(tag.name)” to an item in any area or in the ingest inbox.")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: Theme.Space.base) {
                        ForEach(grouped, id: \.0) { area, members in
                            VStack(alignment: .leading, spacing: Theme.Space.tight) {
                                HStack(spacing: Theme.Space.tight) {
                                    if let workspaceArea = WorkspaceArea(rawValue: area) {
                                        Image(systemName: workspaceArea.symbolName).font(.system(size: 11))
                                    }
                                    Text(area).font(.system(size: 12, weight: .semibold))
                                    Text("\(members.count)")
                                        .font(.system(size: 10).monospacedDigit())
                                        .foregroundStyle(.secondary)
                                }
                                ForEach(members, id: \.identityKey) { object in
                                    objectRow(object)
                                }
                            }
                        }
                    }
                    .padding(Theme.Space.base)
                }
            }
        }
        .task(id: tag.id) { @MainActor in objects = model.objects(withTag: tag) }
        .onChange(of: model.tagUsage) { _, _ in objects = model.objects(withTag: tag) }
    }
}
