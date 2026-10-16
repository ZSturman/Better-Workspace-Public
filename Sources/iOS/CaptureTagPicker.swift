import SwiftUI
import BetterWorkspaceCore

/// Picks tags by typing. As you type, existing tags narrow to the ones that match,
/// best first (`TagMatching`, the same ranking the Mac uses), so the existing tag is
/// always the nearest thing to tap and Return picks it. A new tag is created only from
/// the explicit Create row, or by Return when nothing close exists.
struct CaptureTagPicker: View {
    let tags: [Tag]
    let selectedIDs: Set<String>
    let toggle: (Tag) -> Void
    let create: (String) -> Void
    var focus: FocusState<Bool>.Binding

    @State private var query = ""

    private var trimmed: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var matches: [Tag] { Array(TagMatching.ranked(trimmed, in: tags).prefix(6)) }
    private var returnTarget: Tag? {
        if case .existing(let tag) = TagMatching.resolve(trimmed, in: tags) { return tag }
        return nil
    }
    private var canCreate: Bool {
        trimmed.isEmpty == false && TagMatching.equivalent(to: trimmed, in: tags) == nil
    }
    private var selected: [Tag] { tags.filter { selectedIDs.contains($0.id) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Tags").font(.caption.weight(.semibold)).foregroundStyle(.secondary)

            if selected.isEmpty == false {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(selected) { tag in
                            Button { toggle(tag) } label: {
                                Label(tag.name, systemImage: "xmark.circle.fill")
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .accessibilityLabel("Tag \(tag.name), selected")
                            .accessibilityHint("Removes this tag")
                        }
                    }
                }
            }

            // Matches sit above the field, never below it: below is where the
            // keyboard is, and suggestions hidden behind it help nobody.
            if trimmed.isEmpty == false {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(matches) { tag in
                        Button {
                            toggle(tag)
                            query = ""
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: selectedIDs.contains(tag.id) ? "checkmark.circle.fill" : "tag")
                                    .foregroundStyle(selectedIDs.contains(tag.id) ? Color.accentColor : .secondary)
                                Text(tag.name).foregroundStyle(.primary)
                                Spacer()
                                if tag.id == returnTarget?.id {
                                    Image(systemName: "return").font(.caption).foregroundStyle(.secondary)
                                        .accessibilityHidden(true)
                                }
                            }
                            .padding(.vertical, 8)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Tag \(tag.name)")
                        .accessibilityIdentifier("tag-suggestion")
                    }
                    if canCreate {
                        Button {
                            create(trimmed)
                            query = ""
                        } label: {
                            Label("Create “\(trimmed)”", systemImage: "plus.circle.fill")
                                .padding(.vertical, 8)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.tint)
                        .accessibilityIdentifier("create-capture-tag")
                    }
                }
            }

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Find or add a tag", text: $query)
                    .focused(focus)
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()
                    .submitLabel(.done)
                    .onSubmit(commit)
                    .accessibilityIdentifier("capture-tag-search")
                if query.isEmpty == false {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .foregroundStyle(.tertiary)
                        .accessibilityLabel("Clear tag search")
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 10))

            if trimmed.isEmpty {
                let unselected = tags.filter { selectedIDs.contains($0.id) == false }
                if unselected.isEmpty == false {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 7) {
                            ForEach(unselected) { tag in
                                Button { toggle(tag) } label: { Label(tag.name, systemImage: "tag") }
                                    .buttonStyle(.bordered)
                                    .tint(.secondary)
                                    .accessibilityLabel("Tag \(tag.name)")
                            }
                        }
                    }
                }
            }
        }
    }

    private func commit() {
        switch TagMatching.resolve(trimmed, in: tags) {
        case .existing(let tag):
            if selectedIDs.contains(tag.id) == false { toggle(tag) }
        case .create(let name):
            create(name)
        case .nothing:
            return
        }
        query = ""
    }
}
