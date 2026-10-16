import SwiftUI
import BetterWorkspaceCore

struct MobileIdeaPlanningEditor: View {
    @Environment(MobileWorkspaceModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let idea: MobileIdea
    @State private var planning = IdeaPlanning()
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                IdeaPlanningForm(planning: $planning, preferences: idea.scoringPreferences ?? .init())
                if let message = model.saveMessage { Text(message).font(.caption).foregroundStyle(.secondary).padding() }
                if idea.serviceID == nil { Text("The updated Mac and idea service must publish this idea before its scores can be saved.").font(.caption).padding() }
            }
            .navigationTitle("Priority & scoring").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        var value = planning; value.needsSetup = false
                        if value.potential == .project && value.project == nil { value.project = .init(oneLiner: idea.description ?? "") }
                        var original = idea; original.previews = nil
                        if model.savePlanning(MobilePlanningEdit(operation: .saveIdeaPlanning, title: idea.title, originalIdea: original, ideaPlanning: value)) { dismiss() }
                    }.disabled(idea.serviceID == nil).accessibilityIdentifier("idea.planning.save")
                }
            }.onAppear { planning = idea.planning ?? IdeaPlanning() }
        }
    }
}

struct MobileIdeaPreviewsSection: View {
    @Environment(MobileWorkspaceModel.self) private var model
    let idea: MobileIdea
    private var waiting: Bool { model.waitingPlanningDrafts.contains { $0.operation == .previewIdea && $0.originalIdea?.path == idea.path } }
    var body: some View {
        Section("File & media previews") {
            MobileFilePreviewCards(previews: idea.previews ?? [])
            if idea.previews?.isEmpty == true { Text("No local files with supported previews are available yet.").font(.caption).foregroundStyle(.secondary) }
            Button(waiting ? "Waiting for the Mac…" : "Load / refresh previews", systemImage: "photo.on.rectangle") {
                var original = idea; original.previews = nil
                _ = model.savePlanning(MobilePlanningEdit(operation: .previewIdea, title: idea.title, originalIdea: original))
            }.disabled(waiting).accessibilityIdentifier("idea.previews.load")
            Text("Up to six small previews, requested from your Mac. Original files remain in Ideas.").font(.caption).foregroundStyle(.secondary)
        }
    }
}
