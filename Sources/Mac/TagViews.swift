import SwiftUI
import BetterWorkspaceCore

struct TagChip: View {
    let tag: Tag
    var onRemove: (() -> Void)?

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(Theme.tagColor(tag))
                .frame(width: 6, height: 6)
            Text(tag.name)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark")
                        .font(.system(size: 7, weight: .bold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Remove “\(tag.name)”")
                .accessibilityLabel("Remove \(tag.name)")
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 2.5)
        .background(Theme.tagColor(tag).opacity(0.16), in: RoundedRectangle(cornerRadius: Theme.Radius.chip))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.chip)
                .strokeBorder(Theme.tagColor(tag).opacity(0.3), lineWidth: 0.5)
        )
    }
}

/// A compact, non-interactive row of tags used inside dense lists and tables.
struct TagChipRow: View {
    let tags: [Tag]
    var limit: Int = 4

    var body: some View {
        HStack(spacing: 4) {
            ForEach(tags.prefix(limit)) { TagChip(tag: $0) }
            if tags.count > limit {
                Text("+\(tags.count - limit)")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// The shared tag editor.
///
/// Identical wherever it appears — the Workspace inspector, the ingest processor, the
/// quick-capture panel — because the requirement is one tagging interaction, not nine.
struct TagEditor: View {
    let assigned: [Tag]
    let allTags: [Tag]
    let onAssign: (Tag) -> Void
    let onUnassign: (Tag) -> Void
    let onCreate: (String) -> Tag?
    /// The menu bar's single-line form: no heading or empty message, and suggestions
    /// only while typing, so the capture panel stays short.
    var compact = false

    @State private var search = ""
    @FocusState private var searchFocused: Bool

    private var assignedIDs: Set<String> { Set(assigned.map(\.id)) }

    /// Ranked by `TagMatching`, exactly as the phone ranks them.
    private var matches: [Tag] {
        if compact, search.trimmingCharacters(in: .whitespaces).isEmpty { return [] }
        return TagMatching.ranked(search, in: allTags.filter { assignedIDs.contains($0.id) == false })
    }

    private var resolution: TagMatching.Resolution { TagMatching.resolve(search, in: allTags) }

    /// The tag Return will pick, marked so Return never picks a surprise.
    private var returnTarget: Tag? {
        if case .existing(let tag) = resolution { return tag }
        return nil
    }

    private var canCreate: Bool {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty == false && TagMatching.equivalent(to: query, in: allTags) == nil
    }

    /// What was typed is a tag this item already has, perhaps spelled differently.
    /// Said out loud, or the field would seem to ignore Return.
    private var alreadyAssigned: Tag? {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let tag = TagMatching.equivalent(to: query, in: allTags), assignedIDs.contains(tag.id) else { return nil }
        return tag
    }

    private func suggestionRow(_ tag: Tag) -> some View {
        Button { onAssign(tag); search = "" } label: {
            HStack(spacing: Theme.Space.tight) {
                Circle().fill(Theme.tagColor(tag)).frame(width: 6, height: 6)
                Text(tag.name).font(.system(size: 12))
                Spacer()
                if tag.id == returnTarget?.id {
                    Image(systemName: "return")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                        .help("Return adds this tag")
                } else {
                    Image(systemName: "plus")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 6).padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("tag.suggestion")
        .accessibilityLabel("Tag \(tag.name)")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.snug) {
            if compact == false {
                Text("Tags")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
            }

            if assigned.isEmpty {
                if compact == false {
                    Text("No tags yet")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            } else {
                FlowLayout(spacing: 5) {
                    ForEach(assigned) { tag in
                        TagChip(tag: tag, onRemove: { onUnassign(tag) })
                    }
                }
            }

            HStack(spacing: Theme.Space.tight) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                TextField(compact ? "Add tags" : "Search or create a tag", text: $search)
                    .accessibilityIdentifier("tag.searchField")
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .focused($searchFocused)
                    .onSubmit(commit)
                if search.isEmpty == false {
                    Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 7).padding(.vertical, 5)
            .background(Color.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: 6))

            if let alreadyAssigned {
                Text("“\(alreadyAssigned.name)” is already added")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            if matches.isEmpty == false {
                if compact {
                    // Not a ScrollView: the menu bar panel sizes itself to its content,
                    // and a short plain list always claims its full height there.
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(matches.prefix(5)) { suggestionRow($0) }
                    }
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(matches) { suggestionRow($0) }
                        }
                    }
                    .frame(maxHeight: 150)
                }
            }

            if canCreate {
                Button(action: create) {
                    HStack(spacing: 5) {
                        Image(systemName: "plus.circle.fill")
                        Text("Create “\(search.trimmingCharacters(in: .whitespacesAndNewlines))”")
                            .lineLimit(1)
                    }
                    .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("tag.createButton")
                .foregroundStyle(.tint)
            }
        }
    }

    /// Return: an existing tag when one is a good match, otherwise a new one.
    private func commit() {
        switch resolution {
        case .existing(let existing):
            if assignedIDs.contains(existing.id) == false { onAssign(existing) }
        case .create(let name):
            if let created = onCreate(name) { onAssign(created) }
        case .nothing:
            return
        }
        search = ""
    }

    /// The explicit Create button: makes exactly what was typed, even when it is the
    /// start of an existing name. A same-name tag is still reused, never duplicated.
    private func create() {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.isEmpty == false else { return }
        if let existing = TagMatching.equivalent(to: query, in: allTags) {
            if assignedIDs.contains(existing.id) == false { onAssign(existing) }
        } else if let created = onCreate(query) {
            onAssign(created)
        }
        search = ""
    }
}

/// The sidebar's New Tag field. Typing lists the tags that already match
/// (`TagMatching`), and a name that is an existing tag in all but spelling — case,
/// spacing, a plural — opens that tag instead of making a second one.
///
/// Takes values and closures, never the model: it sits inside the sidebar `List`.
struct NewTagField: View {
    let allTags: [Tag]
    let onCreate: (String) -> Void
    let onShow: (Tag) -> Void
    let onDone: () -> Void

    @State private var name = ""
    @FocusState private var focused: Bool

    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var existing: Tag? { TagMatching.equivalent(to: trimmed, in: allTags) }
    private var matches: [Tag] {
        trimmed.isEmpty ? [] : Array(TagMatching.ranked(trimmed, in: allTags).prefix(5))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            TextField("New tag", text: $name)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11))
                .focused($focused)
                .accessibilityIdentifier("sidebar.newTagField")
                .onSubmit(commit)
                .onExitCommand(perform: onDone)
            if let existing {
                Text("“\(existing.name)” already exists — Return opens it")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            ForEach(matches) { tag in
                Button { onShow(tag); onDone() } label: {
                    HStack(spacing: Theme.Space.tight) {
                        Circle().fill(Theme.tagColor(tag)).frame(width: 6, height: 6)
                        Text(tag.name).font(.system(size: 11))
                        Spacer()
                        Text("Existing").font(.system(size: 9)).foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("sidebar.newTagSuggestion")
                .accessibilityLabel("Existing tag \(tag.name)")
            }
        }
        .onAppear { focused = true }
    }

    private func commit() {
        guard trimmed.isEmpty == false else { onDone(); return }
        if let existing { onShow(existing) } else { onCreate(trimmed) }
        name = ""
        onDone()
    }
}
