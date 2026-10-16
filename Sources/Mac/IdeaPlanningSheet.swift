import SwiftUI
import BetterWorkspaceCore

struct IdeaPlanningSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let item: WorkspaceItem
    @State private var planning = IdeaPlanning()
    @State private var original: IdeaPlanning?
    @State private var loaded = false
    @State private var saving = false
    @State private var error: String?
    var body: some View {
        VStack(spacing: 0) {
            HStack { Text("Idea planning · " + item.displayTitle).font(.headline); Spacer() }.padding()
            if loaded { IdeaPlanningForm(planning: $planning, preferences: model.scoringPreferences(), projectOptions: model.ideaProjectPropertyOptions()) }
            else {
                VStack(spacing: 12) {
                    Text("Idea decisions are saved by the background service.")
                    Button("Load from service") { Task { await load() } }
                    if let error { Text(error).font(.caption).foregroundStyle(.secondary) }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if let error, loaded { Text(error).font(.caption).foregroundStyle(.secondary).padding(.horizontal) }
            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Button("Save") { Task {
                    saving = true
                    var value = planning; value.needsSetup = false
                    if value.potential == .project && value.project == nil { value.project = .init(oneLiner: model.ideaRecord(for: item.url)?.oneLiner ?? "") }
                    if await model.saveIdeaPlanning(value, for: item, original: original) { dismiss() } else { error = model.lastError }
                    saving = false
                } }.disabled(!loaded || saving).buttonStyle(.borderedProminent).accessibilityIdentifier("idea.planning.save")
            }.padding()
        }.frame(width: 560, height: 460).task { await load() }
    }
    @MainActor private func load() async {
        await model.refreshIdeaPlanning()
        guard let record = model.ideaRecord(for: item.url) else { error = "Update/start the background service, then try again."; return }
        original = record.planning; planning = original ?? IdeaPlanning();
        if planning.potential == .project && planning.project == nil { planning.project = .init(oneLiner: record.oneLiner ?? "") }
        loaded = true
    }
}
