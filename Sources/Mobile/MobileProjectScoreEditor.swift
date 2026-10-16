import SwiftUI
import ImageIO
import BetterWorkspaceCore

struct MobileProjectScoreEditor: View {
    @Environment(MobileWorkspaceModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let project: MobileWorkspaceEntry
    @State private var ratings: [String: Int] = [:]
    @State private var oneLiner = ""
    @State private var summary = ""
    @State private var original: MobileProjectDetails?
    private enum NotesField: Hashable { case oneLiner, summary }
    @FocusState private var notesField: NotesField?

    var body: some View {
        NavigationStack {
            Form {
                Section("Project details") {
                    TextField("One-liner", text: $oneLiner, axis: .vertical).focused($notesField, equals: .oneLiner)
                        .accessibilityIdentifier("project.score.oneLiner")
                    TextField("Summary", text: $summary, axis: .vertical).lineLimit(3...8).focused($notesField, equals: .summary)
                }
                if let original {
                    let score = MobileProjectDetails(path: project.path, ratings: ratings, scoringPreferences: original.scoringPreferences).currentScore
                    Section {
                        LabeledContent("Project score") {
                            Text(score.projectScore.map { "\(Int($0.rounded()))/100" } ?? "Unrated")
                                .accessibilityIdentifier("project.score.value")
                        }
                        LabeledContent("Answered", value: "\(score.answeredCount)/\(score.activeMetrics.count)")
                        Text("Higher project scores bring that project's eligible tasks forward. Cost and risk ratings count in the opposite direction.").font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(score.enabledGroups) { group in
                        Section(group.displayName) {
                            ForEach(group.metrics.filter { score.enabledMetricIDs.contains($0.id) }) { metric in
                                VStack(alignment: .leading, spacing: 8) {
                                    Text(metric.question).font(.subheadline)
                                    Picker(metric.displayName, selection: Binding(get: { ratings[metric.id] ?? 0 }, set: { value in
                                        if value == 0 { ratings.removeValue(forKey: metric.id) } else { ratings[metric.id] = value }
                                    })) {
                                        Text("Unrated").tag(0)
                                        ForEach(metric.anchors, id: \.rating) { anchor in
                                            Text("\(anchor.rating) · \(anchor.label)").tag(anchor.rating)
                                        }
                                    }.accessibilityIdentifier("project.score.\(metric.id)")
                                    if let value = ratings[metric.id], let anchor = metric.anchor(for: value) {
                                        Text(anchor.description).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                } else {
                    Text("Refresh from the updated Mac app to receive editable project scores.").foregroundStyle(.secondary)
                }
                if let message = model.saveMessage { Section { Text(message).font(.caption) } }
            }
            .navigationTitle("Details & scoring").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("Done") { notesField = nil }.accessibilityIdentifier("project.score.keyboardDone") }
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        guard let original else { return }
                        // Keep command payloads compact: previews are disposable, not edit originals.
                        var baseline = original; baseline.previews = nil
                        let change = MobileProjectEdit(original: baseline, ratings: ratings,
                            oneLiner: oneLiner.trimmingCharacters(in: .whitespacesAndNewlines), summary: summary.trimmingCharacters(in: .whitespacesAndNewlines))
                        if model.savePlanning(MobilePlanningEdit(operation: .saveProject, title: project.name, projectEdit: change)) { dismiss() }
                    }.disabled(original?.ratings == nil).accessibilityIdentifier("project.score.save")
                }
            }
            .onAppear {
                original = project.projectDetails
                ratings = original?.ratings ?? [:]; oneLiner = original?.oneLiner ?? ""; summary = original?.summary ?? ""
            }
        }
    }
}

struct MobileProjectPreviewsSection: View {
    @Environment(MobileWorkspaceModel.self) private var model
    let project: MobileWorkspaceEntry
    private var waiting: Bool { model.waitingPlanningDrafts.contains { $0.operation == .previewProject && $0.originalEntry?.path == project.path } }
    var body: some View {
        Section("Files & media previews") {
            MobileFilePreviewCards(previews: project.projectDetails?.previews ?? [])
            if project.projectDetails?.previews?.isEmpty == true {
                Text("No locally available files with supported previews were found in these folders.").font(.caption).foregroundStyle(.secondary)
            }
            Button(waiting ? "Waiting for the Mac…" : "Load / refresh previews", systemImage: "photo.on.rectangle") {
                var details = project.projectDetails; details?.previews = nil
                let request = MobileWorkspaceEntry(path: project.path, parentPath: project.parentPath, name: project.name, isDirectory: project.isDirectory, revision: project.revision, projectDetails: details)
                _ = model.savePlanning(MobilePlanningEdit(operation: .previewProject, title: project.name, originalEntry: request))
            }.disabled(waiting).accessibilityIdentifier("project.previews.load")
            Text("Up to six small previews from the project root, Media and docs/images. Cached from your Mac when requested; originals stay there. Open full files and play videos on the Mac.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct MobileFilePreviewCards: View {
    let previews: [MobileFilePreview]
    var body: some View {
        ForEach(Array(previews.prefix(6))) { preview in
                VStack(alignment: .leading, spacing: 8) {
                    Text(preview.name).font(.headline)
                    if let data = preview.jpeg, let image = thumbnail(data) {
                        Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 240).accessibilityLabel("Preview of " + preview.name)
                    }
                    if let text = preview.text { Text(String(text.prefix(4_096))).font(.callout).lineLimit(12).textSelection(.enabled) }
                    Text(preview.path).font(.caption).foregroundStyle(.secondary)
                }.accessibilityIdentifier("project.filePreview")
            }
    }
    private func thumbnail(_ data: Data) -> UIImage? {
        guard data.count <= 32_768, let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int,
              (1...320).contains(width), (1...320).contains(height),
              let bitmap = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        return UIImage(cgImage: bitmap)
    }

}
