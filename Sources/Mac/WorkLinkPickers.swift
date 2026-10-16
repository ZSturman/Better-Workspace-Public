import SwiftUI
import BetterWorkspaceCore

/// Project, Feature and Milestone, each optional and one click away.
///
/// The same control wherever work is made or placed: the work-item editor, the capture
/// composers, queue rows and Needs Attention. It takes values and a setter, never the
/// model, so it is safe inside a `List` row.
struct WorkLinkPickers: View {
    let kind: WorkItemKind
    let links: WorkItemLinks
    let projects: [WorkLinkChoice]
    let features: [WorkLinkChoice]
    let milestones: [WorkLinkChoice]
    let onChange: (WorkItemLinks) -> Void
    /// Rows and the menu bar want small borderless menus; the editor, full-size ones.
    var compact = true

    var body: some View {
        HStack(spacing: compact ? 10 : Theme.Space.base) {
            projectMenu
            if WorkItemLinks.offersFeature(for: kind) {
                multiMenu(title: "Feature", symbol: "sparkles", choices: features, selected: links.featureIDs) { ids in
                    var next = links; next.featureIDs = ids; onChange(next)
                }
                .accessibilityIdentifier("workLink.feature")
            }
            if WorkItemLinks.offersMilestone(for: kind) {
                multiMenu(title: "Milestone", symbol: "flag.checkered", choices: milestones, selected: links.milestoneIDs) { ids in
                    var next = links; next.milestoneIDs = ids; onChange(next)
                }
                .accessibilityIdentifier("workLink.milestone")
            }
        }
        .font(.system(size: compact ? 11 : 12))
    }

    /// Compact menus give way before a row's title does: each truncates past a width.
    private var menuWidth: CGFloat? { compact ? 150 : nil }

    private var projectTitle: String {
        guard let path = links.projectPath else { return "No project" }
        return projects.first { $0.id == path }?.title ?? (path as NSString).lastPathComponent
    }

    /// The symbol is decoration: as a `Label`, its name ("move" for a folder) became
    /// what VoiceOver read for the whole menu.
    private func menuLabel(_ text: String, symbol: String, empty: Bool) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol).accessibilityHidden(true)
            Text(text).lineLimit(1)
        }
        .foregroundStyle(empty ? .secondary : .primary)
    }

    private var projectMenu: some View {
        Menu {
            Button { var next = links; next.projectPath = nil; onChange(next) } label: {
                if links.projectPath == nil { Label("No project", systemImage: "checkmark") } else { Text("No project") }
            }
            Divider()
            ForEach(projects) { project in
                Button { var next = links; next.projectPath = project.id; onChange(next) } label: {
                    if links.projectPath == project.id { Label(project.title, systemImage: "checkmark") } else { Text(project.title) }
                }
            }
        } label: {
            menuLabel(projectTitle, symbol: "folder", empty: links.projectPath == nil)
        }
        .menuStyle(.borderlessButton)
        .fixedSize(horizontal: compact == false, vertical: false)
        .frame(maxWidth: menuWidth, alignment: .leading)
        .help("Which project this belongs to (optional)")
        .accessibilityIdentifier("workLink.project")
        .accessibilityLabel("Project: \(projectTitle)")
    }

    private func toggle(_ choice: WorkLinkChoice, selected: [String], set: @escaping ([String]) -> Void, showsProject: Bool) -> some View {
        Toggle(isOn: Binding(
            get: { selected.contains(choice.id) },
            set: { on in set(on ? selected + [choice.id] : selected.filter { $0 != choice.id }) }
        )) {
            Text(showsProject ? choice.detail.map { "\(choice.title) — \($0)" } ?? choice.title : choice.title)
        }
    }

    private func multiMenu(title: String, symbol: String, choices: [WorkLinkChoice], selected: [String],
                           set: @escaping ([String]) -> Void) -> some View {
        let names = selected.map { id in choices.first { $0.id == id }?.title ?? id }
        let label = names.isEmpty ? "No \(title.lowercased())" : names.count == 1 ? names[0] : "\(names.count) \(title.lowercased())s"
        return Menu {
            if selected.isEmpty == false {
                Button("Clear") { set([]) }
                Divider()
            }
            // This project's first; another project's only when asked for.
            let project = links.projectPath.map { ($0 as NSString).lastPathComponent }
            let here = choices.filter { project == nil || $0.detail == nil || $0.detail == project || selected.contains($0.id) }
            let elsewhere = choices.filter { choice in !here.contains { $0.id == choice.id } }
            if here.isEmpty {
                Text(project == nil ? "No open \(title.lowercased())s" : "No open \(title.lowercased())s in \(project!)")
            }
            ForEach(here) { choice in toggle(choice, selected: selected, set: set, showsProject: project == nil) }
            if !elsewhere.isEmpty {
                Divider()
                Menu("Other Projects") {
                    ForEach(elsewhere) { choice in toggle(choice, selected: selected, set: set, showsProject: true) }
                }
            }
        } label: {
            menuLabel(label, symbol: symbol, empty: selected.isEmpty)
        }
        .menuStyle(.borderlessButton)
        .fixedSize(horizontal: compact == false, vertical: false)
        .frame(maxWidth: menuWidth, alignment: .leading)
        .help("Which \(title.lowercased()) this belongs to (optional)")
        .accessibilityLabel("\(title): \(label)")
    }
}

extension AppModel {
    /// Pickers for `links`, with choices drawn from current projects and open work.
    func linkPickers(kind: WorkItemKind, links: WorkItemLinks, excluding id: String? = nil, compact: Bool = true,
                     onChange: @escaping (WorkItemLinks) -> Void) -> WorkLinkPickers {
        WorkLinkPickers(kind: kind, links: links, projects: projectLinkChoices,
                        features: workLinkChoices(.feature, projectPath: links.projectPath, keeping: links.featureIDs, excluding: id),
                        milestones: workLinkChoices(.milestone, projectPath: links.projectPath, keeping: links.milestoneIDs, excluding: id),
                        onChange: onChange, compact: compact)
    }
}
