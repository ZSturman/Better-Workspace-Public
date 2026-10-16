import SwiftUI
import BetterWorkspaceCore

struct ProjectMetadataSuggestionSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let project: WorkspaceItem
    @AppStorage("projectZenAIEndpoint", store: TestIsolation.defaults) private var endpoint = LMStudioPreset.endpoint
    @AppStorage("projectZenAIModel", store: TestIsolation.defaults) private var modelID = ""
    @AppStorage("projectLMStudioSchema", store: TestIsolation.defaults) private var schema = true
    @State private var context = ""
    @State private var wantsLine = true
    @State private var wantsTags = true
    @State private var baseline: ProjectSuggestionBaseline?
    @State private var prepared: LMStudioPreparedRequest?
    @State private var suggestions: LMStudioSuggestions?
    @State private var line = ""
    @State private var selectLine = false
    @State private var selectedTagIDs = Set<String>()
    @State private var busy = false
    @State private var problem: String?
    @State private var task: Task<Void, Never>?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("LM Studio suggestions", systemImage: "sparkles").font(.title2.weight(.semibold))
                Spacer()
                Text(suggestions == nil ? "1 · Review input" : "2 · Choose changes").foregroundStyle(.secondary)
            }
            Text(project.displayTitle).font(.headline)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let suggestions { results(suggestions) }
                    else {
                        GroupBox("Local connection") { LMStudioConnectionFields().padding(4) }.disabled(busy)
                        HStack { Toggle("One-liner", isOn: $wantsLine); Toggle("Tags", isOn: $wantsTags) }.disabled(busy)
                        TextField("Additional context (optional)", text: $context, axis: .vertical)
                            .lineLimit(2...4).disabled(busy).accessibilityIdentifier("lmStudio.context")
                        Text("Only this project's name, saved one-liner, summary, category, domain, assigned tag names, existing tag IDs/names and your context are sent. No project files are read. The exact request appears below.")
                            .font(.caption).foregroundStyle(.secondary)
                        if let prepared {
                            ForEach(prepared.notices, id: \.self) { Text($0).font(.caption).foregroundStyle(.orange) }
                            GroupBox("Exact request to \(prepared.request.url!.absoluteString)") {
                                Text(prepared.preview).font(.system(size: 11, design: .monospaced))
                                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                                    .accessibilityIdentifier("lmStudio.payload")
                            }
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            if let problem { Text(problem).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("lmStudio.error") }
            Divider()
            HStack {
                Button(busy ? "Cancel generation" : "Cancel") {
                    task?.cancel()
                    if !busy { dismiss() }
                }.keyboardShortcut(.cancelAction).accessibilityIdentifier("lmStudio.cancel")
                Spacer()
                if let suggestions {
                    Button("Review input again") { self.suggestions = nil; selectedTagIDs = []; problem = nil }
                    Button("Apply selected (\(selectionCount))") { apply(suggestions) }
                        .buttonStyle(.borderedProminent).disabled(selectionCount == 0)
                        .accessibilityIdentifier("lmStudio.apply")
                } else {
                    Button("Prepare request") { prepare() }.disabled(busy || modelID.isEmpty || (!wantsLine && !wantsTags))
                        .accessibilityIdentifier("lmStudio.prepare")
                    Button(busy ? "Generating…" : "Generate") { generate() }
                        .buttonStyle(.borderedProminent).disabled(busy || prepared == nil)
                        .accessibilityIdentifier("lmStudio.generate")
                }
            }
        }.padding(20).frame(width: 700, height: 560)
            .onChange(of: endpoint) { _, _ in invalidate() }.onChange(of: modelID) { _, _ in invalidate() }
            .onChange(of: schema) { _, _ in invalidate() }.onChange(of: context) { _, _ in invalidate() }
            .onChange(of: wantsLine) { _, _ in invalidate() }.onChange(of: wantsTags) { _, _ in invalidate() }
            .onDisappear { task?.cancel() }
            .accessibilityElement(children: .contain).accessibilityIdentifier("lmStudio.sheet")
    }
    private var selectionCount: Int { (selectLine && !line.isEmpty ? 1 : 0) + selectedTagIDs.count }
    private func invalidate() { task?.cancel(); prepared = nil; suggestions = nil; problem = nil }
    private func prepare() {
        problem = nil
        guard let record = model.projectRecord(for: project) else { problem = "This project must be registered first."; return }
        let description = model.projectStore.description(for: record.id)
        let metadata = model.projectStore.metadata(for: record.id)
        let assigned = model.tagStore.tags(for: project.url)
        do {
            let input = LMStudioInput(name: project.displayTitle, description: description, category: metadata.projectType ?? "",
                                      domain: metadata.domain ?? "", assignedTags: assigned, catalog: model.tagStore.allTags(), context: context)
            prepared = try LMStudioRequest.prepare(endpoint: endpoint, model: modelID, input: input, oneLiner: wantsLine, tags: wantsTags, schema: schema)
            baseline = ProjectSuggestionBaseline(projectID: record.id, path: project.url.canonicalPath, description: description,
                                                  metadata: metadata, assignedTagIDs: Set(assigned.map(\.id)))
        } catch { prepared = nil; problem = error.localizedDescription }
    }
    private func generate() {
        guard let prepared else { return }
        busy = true; problem = nil
        task = Task { @MainActor in
            defer { busy = false }
            do {
                let result = try await LMStudioConnection.client.generate(prepared)
                try Task.checkCancellation()
                suggestions = result; line = result.oneLiner; selectLine = !line.isEmpty
                selectedTagIDs = Set(result.tags.filter { !$0.isNew && !(baseline?.assignedTagIDs.contains($0.existingID ?? "") ?? false) }.map(\.id))
            } catch is CancellationError {} catch { if !Task.isCancelled { problem = error.localizedDescription } }
        }
    }
    @ViewBuilder private func results(_ suggestions: LMStudioSuggestions) -> some View {
        Text("Nothing has been saved. Checked items will be applied to this project's private metadata. Existing assignments stay; linked Notion changes wait for Send.")
            .font(.callout).foregroundStyle(.secondary)
        if !suggestions.oneLiner.isEmpty {
            GroupBox("One-liner · replaces the saved one-liner") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Current: \(baseline?.description.oneLiner ?? "None")").font(.caption).foregroundStyle(.secondary)
                    Toggle("Apply one-liner", isOn: $selectLine).accessibilityIdentifier("lmStudio.selectLine")
                    TextField("Suggested one-liner", text: $line, axis: .vertical).lineLimit(2...3).accessibilityIdentifier("lmStudio.line")
                    Text("\(line.count)/240 characters").font(.caption).foregroundStyle(line.count > 240 ? .red : .secondary)
                }.padding(4)
            }
        }
        ForEach(suggestions.tags) { tag in
            let assigned = baseline?.assignedTagIDs.contains(tag.existingID ?? "") ?? false
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: tag.isNew ? "plus.circle.fill" : "tag.fill").foregroundStyle(tag.isNew ? .orange : .blue)
                VStack(alignment: .leading, spacing: 5) {
                    Text(tag.isNew ? "New tag proposal" : "Existing tag").font(.caption.weight(.semibold)).foregroundStyle(tag.isNew ? .orange : .blue)
                    if assigned { Label("\(tag.name) · already assigned", systemImage: "checkmark").foregroundStyle(.secondary) }
                    else {
                        Toggle(tag.isNew ? "Approve creation and add ‘\(tag.name)’" : "Add ‘\(tag.name)’", isOn: Binding(get: { selectedTagIDs.contains(tag.id) }, set: { if $0 { selectedTagIDs.insert(tag.id) } else { selectedTagIDs.remove(tag.id) } }))
                            .accessibilityIdentifier("lmStudio.tag.\(tag.name)")
                    }
                    Text(tag.reason).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }.padding(12).background((tag.isNew ? Color.orange : Color.blue).opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        }
        if suggestions.oneLiner.isEmpty && suggestions.tags.isEmpty { Text("The model found no supported suggestions. Add more context and prepare a new request.") }
        DisclosureGroup("Request used for these suggestions") { if let prepared { Text(prepared.preview).font(.system(size: 11, design: .monospaced)).textSelection(.enabled) } }
    }
    private func apply(_ suggestions: LMStudioSuggestions) {
        guard let baseline else { return }
        do {
            let selected = suggestions.tags.filter { selectedTagIDs.contains($0.id) }
            let fields = try ProjectMetadataSuggestions.apply(database: model.database, baseline: baseline,
                                                              oneLiner: selectLine ? line : nil, tags: selected,
                                                              approvedNewTagIDs: Set(selected.filter(\.isNew).map(\.id)))
            model.reloadMobilePlanningTags(at: project.url)
            if !fields.isEmpty { model.queueProjectGraphEdits(for: project, fields: fields); model.requestMobileCloudSync() }
            model.statusMessage = "Applied \(selectionCount) selected LM Studio suggestions locally."
            dismiss()
        } catch { problem = error.localizedDescription }
    }
}
