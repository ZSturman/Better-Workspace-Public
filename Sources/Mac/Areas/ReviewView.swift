import SwiftUI
import BetterWorkspaceCore

/// Review: only 8 items, but each is expensive to understand — `Check In` alone is
/// 14,628 files across 2.9 GB, and `Transactions Article` is 27 files of competing
/// article drafts.
///
/// Few items, high consequence per item, so this is a decision surface: one large card
/// each, with the recursive summary you'd otherwise have to go spelunking for.
struct ReviewView: View {
    @Environment(AppModel.self) private var model
    @State private var details: [String: ItemDetail] = [:]
    @State private var measuring: Set<String> = []

    private var items: [WorkspaceItem] { model.items(for: .review) }

    /// Not read yet, so an empty list here would be a false "nothing".
    private var showsLoading: Bool { items.isEmpty && model.isAwaitingFirstRead(of: .review) }

    var body: some View {
        VStack(spacing: 0) {
            AreaHeader(title: "Review", subtitle: model.headerSubtitle(for: .review),
                       symbol: model.settings(for: .review).symbol, count: showsLoading ? nil : items.count)
            Divider()

            if showsLoading {
                LoadingAreaState(title: "Loading Review…")
            } else if items.isEmpty {
                EmptyAreaState(symbol: "checkmark.seal", title: "Nothing to review",
                               message: "Items classified into Review will appear here as decision cards.")
            } else {
                ScrollView {
                    LazyVStack(spacing: Theme.Space.base) {
                        ForEach(items) { item in
                            ReviewCard(
                                item: item,
                                detail: details[item.url.path],
                                isMeasuring: measuring.contains(item.url.path),
                                isSelected: model.selectedItem?.id == item.id,
                                onSelect: { model.selectedItem = item },
                                onMeasure: { Task { await measure(item) } }
                            )
                        }
                    }
                    .padding(Theme.Space.base)
                }
            }
        }
        .task(id: model.revision(ofArea: WorkspaceArea.review.directoryName)) { @MainActor in
            for item in items {
                details[item.url.path] = await model.probe.detail(for: item)
            }
        }
    }

    @MainActor
    private func measure(_ item: WorkspaceItem) async {
        measuring.insert(item.url.path)
        defer { measuring.remove(item.url.path) }
        let deep = await model.probe.deepDetail(for: item, fs: model.fs)
        details[item.url.path] = deep
    }
}

private struct ReviewCard: View {
    @Environment(AppModel.self) private var model
    let item: WorkspaceItem
    let detail: ItemDetail?
    let isMeasuring: Bool
    let isSelected: Bool
    let onSelect: () -> Void
    let onMeasure: () -> Void
    @State private var toolCapability: ProjectToolCapability?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.snug) {
            HStack(alignment: .top, spacing: Theme.Space.snug) {
                Image(systemName: detail?.projectKind.symbolName ?? "folder")
                    .font(.system(size: 17, weight: .light))
                    .foregroundStyle(.tint)
                    .frame(width: 22)

                VStack(alignment: .leading, spacing: 3) {
                    Text(item.displayTitle).font(.system(size: 16, weight: .semibold))
                    HStack(spacing: Theme.Space.snug) {
                        Text(detail?.projectKind.rawValue ?? "Folder")
                        Text("·")
                        Text(Format.count(item.immediateChildCount, singular: "top-level item"))
                        Text("·")
                        Text("changed \(Format.relativeDate(item.contentModifiedAt))")
                        if detail?.isGitRepository == true {
                            Text("·")
                            Label(detail?.gitBranch ?? "repo", systemImage: "arrow.triangle.branch")
                        }
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    if let count = detail?.recursiveFileCount, let bytes = detail?.recursiveByteSize {
                        Text("\(count) files").font(.system(size: 12, weight: .medium).monospacedDigit())
                        Text(Format.bytes(bytes)).font(.system(size: 11)).foregroundStyle(.secondary)
                    } else if isMeasuring {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("Summarize", action: onMeasure)
                            .buttonStyle(.link)
                            .font(.system(size: 11))
                    }
                    if toolCapability?.canExplain == true {
                        Button("Explain") { model.openProjectTool(.explain, for: item) }
                            .buttonStyle(.link)
                            .font(.system(size: 11))
                    }
                    if toolCapability?.canFlowReview == true {
                        Button("Flow Review") { model.openProjectTool(.flowReview, for: item) }
                            .buttonStyle(.link)
                            .font(.system(size: 11))
                    }
                }
            }

            if let names = detail?.immediateNames, names.isEmpty == false {
                Text(names.prefix(12).joined(separator: "  ·  ") + (names.count > 12 ? "  ·  +\(names.count - 12) more" : ""))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .padding(.vertical, 5).padding(.horizontal, Theme.Space.snug)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
            }

            if let excerpt = detail?.readmeExcerpt, excerpt.isEmpty == false {
                Text(firstParagraph(excerpt))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }

            HStack(spacing: Theme.Space.tight) {
                let tags = model.tags(for: item)
                if tags.isEmpty {
                    Text("Untagged").font(.system(size: 11)).foregroundStyle(.tertiary)
                } else {
                    TagChipRow(tags: tags, limit: 6)
                }
                Spacer()
                Button("Reveal") { model.revealInFinder(item.url) }.buttonStyle(.link).font(.system(size: 11))
                Button("Open") { model.open(item.url) }.buttonStyle(.link).font(.system(size: 11))
                Button("Tag") { model.selectedItem = item; model.showInspector = true }
                    .buttonStyle(.link).font(.system(size: 11))
            }
        }
        .padding(Theme.Space.base)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.panel)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.5))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.panel)
                .strokeBorder(isSelected ? Color.accentColor : Color.secondary.opacity(0.18),
                              lineWidth: isSelected ? 1.5 : 0.75)
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .contextMenu { ItemContextMenu(item: item) }
        .task(id: item.url.canonicalPath) {
            toolCapability = await model.projectToolCapability(for: item)
        }
    }

    private func firstParagraph(_ text: String) -> String {
        let lines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.isEmpty == false && $0.hasPrefix("#") == false }
        return lines.prefix(2).joined(separator: " ")
    }
}
