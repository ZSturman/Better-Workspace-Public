import SwiftUI
import BetterWorkspaceCore

/// Project, Feature and Milestone on the phone: each optional, each one tap. Rows for a
/// `Form` or `List` section — the work editor, a record's detail, a capture.
struct MobileWorkLinkPickers: View {
    @Environment(MobileWorkspaceModel.self) private var model
    let kind: WorkItemKind
    let links: WorkItemLinks
    var excluding: String?
    /// Outside a `Form` a menu picker shows only its value ("None"), so it says which it is.
    var labeled = false
    let onChange: (WorkItemLinks) -> Void

    var body: some View {
        row("Project") { projectPicker }
        if WorkItemLinks.offersFeature(for: kind) {
            row("Feature") {
                picker("Feature", kind: .feature, ids: links.featureIDs) { var next = links; next.featureIDs = $0; onChange(next) }
                    .accessibilityIdentifier("work-link-feature")
            }
        }
        if WorkItemLinks.offersMilestone(for: kind) {
            row("Milestone") {
                picker("Milestone", kind: .milestone, ids: links.milestoneIDs) { var next = links; next.milestoneIDs = $0; onChange(next) }
                    .accessibilityIdentifier("work-link-milestone")
            }
        }
    }

    @ViewBuilder
    private func row<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        if labeled {
            LabeledContent(title) { content().labelsHidden() }
        } else {
            content()
        }
    }

    private var projectPicker: some View {
        Picker("Project", selection: Binding(
            get: { links.projectPath ?? "" },
            set: { var next = links; next.projectPath = $0.isEmpty ? nil : $0; onChange(next) })) {
            Text("No project").tag("")
            ForEach(model.projectChoices) { Text($0.name).tag($0.path) }
            // A project this phone has not been sent yet still shows by name.
            if let path = links.projectPath, model.projectChoices.contains(where: { $0.path == path }) == false {
                Text(model.projectName(for: path)).tag(path)
            }
        }
        .accessibilityIdentifier("work-link-project")
    }

    /// One choice on the phone. A record linked to several keeps the others: only the
    /// first is replaced.
    private func picker(_ title: String, kind: WorkItemKind, ids: [String],
                        set: @escaping ([String]) -> Void) -> some View {
        let choices = model.linkChoices(kind, projectPath: links.projectPath, keeping: ids, excluding: excluding)
        return Picker(title, selection: Binding(
            get: { ids.first ?? "" },
            set: { id in set(id.isEmpty ? Array(ids.dropFirst()) : [id] + ids.dropFirst().filter { $0 != id }) })) {
            Text("None").tag("")
            ForEach(choices) { Text($0.title).tag($0.id) }
            if let first = ids.first, choices.contains(where: { $0.id == first }) == false {
                Text(model.workTitle(for: first)).tag(first)
            }
        }
    }
}
