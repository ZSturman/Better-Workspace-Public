import SwiftUI
import BetterWorkspaceCore

/// A review of values already fetched from Notion.  This is intentionally not a
/// live editor: dismissing it changes nothing, and applying selected fields never
/// contacts Notion again.
struct ProjectMetadataImportReview: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var selected: [String: Set<ProjectMetadataImport.Field>] = [:]
    @State private var page = 0
    @State private var expandedProjectIDs: Set<String> = []

    // A full project card includes up to 19 field-level comparisons.  Keep a small
    // page so the review remains fast and scannable even on the 158-link portfolio.
    private let pageSize = 5

    private var previews: [ProjectMetadataImport.Preview] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.isEmpty == false else { return model.projectMetadataImportPreviews }
        return model.projectMetadataImportPreviews.filter {
            $0.projectName.localizedCaseInsensitiveContains(query)
                || $0.changes.contains { $0.field.title.localizedCaseInsensitiveContains(query) }
        }
    }

    private var selectedFieldCount: Int { selected.values.reduce(0) { $0 + $1.count } }
    private var pageCount: Int { max(1, Int(ceil(Double(previews.count) / Double(pageSize)))) }
    private var pagePreviews: [ProjectMetadataImport.Preview] {
        let start = min(page * pageSize, previews.count)
        let end = min(start + pageSize, previews.count)
        return Array(previews[start..<end])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.base) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Import Project Metadata from Notion").font(.title3.weight(.semibold))
                    Text("Review the fetched values, then write only checked fields to local Better Workspace metadata. Nothing is sent to Notion.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button("Done") { dismiss() }
            }

            HStack(spacing: Theme.Space.snug) {
                Text("\(model.projectMetadataImportPreviews.count) linked projects")
                Text("\(selectedFieldCount) fields selected").foregroundStyle(.secondary)
                if model.projectMetadataImportUnavailableRelations > 0 {
                    Text("\(model.projectMetadataImportUnavailableRelations) remote relationships unavailable locally")
                        .foregroundStyle(.orange)
                }
                Spacer()
                Button("Select empty local values") { selectDefaults() }.buttonStyle(.bordered)
                Button("Import selected") {
                    _ = model.applyProjectMetadataImport(selected)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(selectedFieldCount == 0)
            }
            .font(.caption)

            TextField("Filter projects or fields", text: $query)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("projects.metadataImport.filter")
                .onChange(of: query) { _, _ in page = 0 }

            if previews.isEmpty {
                ContentUnavailableView("No linked project metadata matches", systemImage: "arrow.left.arrow.right",
                                        description: Text("The preview compares linked pages and unique exact local-directory or title matches."))
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: Theme.Space.snug) {
                        ForEach(pagePreviews) { preview in projectCard(preview) }
                    }
                    .padding(.vertical, 2)
                }
                HStack {
                    Text("Showing \(page * pageSize + 1)–\(min((page + 1) * pageSize, previews.count)) of \(previews.count)")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Previous") { page -= 1 }
                        .disabled(page == 0)
                    Button("Next") { page += 1 }
                        .disabled(page + 1 >= pageCount)
                }
            }
        }
        .padding(Theme.Space.loose)
        .frame(minWidth: 700, idealWidth: 860, minHeight: 500, idealHeight: 680)
        .onAppear(perform: selectDefaults)
    }

    @ViewBuilder
    private func projectCard(_ preview: ProjectMetadataImport.Preview) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(preview.projectName).font(.headline)
                    Spacer()
                    Text(preview.notionPageID).font(.caption2.monospaced()).foregroundStyle(.tertiary)
                }
                let visible = preview.changes.filter { $0.notion != nil || $0.local != nil }
                if visible.isEmpty {
                    Text("No curated metadata is present locally or in this Notion page.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    let fills = visible.filter { $0.state == .fill }.count
                    let conflicts = visible.filter { $0.state == .conflict }.count
                    HStack {
                        Text("\(fills) new")
                        if conflicts > 0 { Text("\(conflicts) conflicts").foregroundStyle(.orange) }
                        Spacer()
                        Button(expandedProjectIDs.contains(preview.projectID) ? "Hide fields" : "Review \(visible.count) fields") {
                            if expandedProjectIDs.contains(preview.projectID) {
                                expandedProjectIDs.remove(preview.projectID)
                            } else {
                                expandedProjectIDs.insert(preview.projectID)
                            }
                        }
                        .buttonStyle(.borderless)
                    }
                    .font(.caption)
                    if expandedProjectIDs.contains(preview.projectID) {
                        ForEach(visible) { change in
                            HStack(alignment: .top, spacing: Theme.Space.snug) {
                                Toggle(change.field.title, isOn: selectionBinding(preview.projectID, field: change.field))
                                    .toggleStyle(.checkbox)
                                    .frame(width: 154, alignment: .leading)
                                    .disabled(change.notion == nil || change.state == .equal)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text("Local: \(change.local ?? "—")")
                                    Text("Notion: \(change.notion ?? "—")")
                                        .foregroundStyle(change.notion == nil ? .tertiary : .secondary)
                                }
                                .font(.caption)
                                .lineLimit(2)
                                Spacer(minLength: 0)
                                Text(change.state.label)
                                    .font(.caption2.weight(.medium))
                                    .foregroundStyle(change.state.color)
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }
            }
            .padding(.vertical, 2)
        } label: { Text("Project") }
    }

    private func selectionBinding(_ projectID: String, field: ProjectMetadataImport.Field) -> Binding<Bool> {
        Binding(get: { selected[projectID, default: []].contains(field) }, set: { enabled in
            var fields = selected[projectID, default: []]
            if enabled { fields.insert(field) } else { fields.remove(field) }
            if fields.isEmpty { selected.removeValue(forKey: projectID) } else { selected[projectID] = fields }
        })
    }

    private func selectDefaults() {
        selected = Dictionary(uniqueKeysWithValues: model.projectMetadataImportPreviews.compactMap { preview in
            let fields = preview.defaultFields
            return fields.isEmpty ? nil : (preview.projectID, fields)
        })
    }
}

private extension ProjectMetadataImport.ChangeState {
    var label: String {
        switch self {
        case .equal: return "Same"
        case .fill: return "New"
        case .conflict: return "Conflict"
        case .localOnly: return "Keep local"
        }
    }

    var color: Color {
        switch self {
        case .equal: return .secondary
        case .fill: return .green
        case .conflict: return .orange
        case .localOnly: return .secondary
        }
    }
}
