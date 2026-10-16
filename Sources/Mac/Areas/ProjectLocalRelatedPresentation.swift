import SwiftUI
import BetterWorkspaceCore

struct ProjectLocalRelatedPresentation: View {
    @Environment(AppModel.self) private var model
    let project: WorkspaceItem
    let presentation: SelectedProjectPresentation
    @State private var newWork = false
    @State private var query = ""
    private var records: [WorkItem] { model.projectWorkItems(for: project).filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) } }
    var body: some View {
        VStack(spacing: 0) {
            if presentation == .portfolio {
                ScrollView { VStack(alignment: .leading, spacing: 20) {
                    Text(project.displayTitle).font(.largeTitle.weight(.semibold))
                    if let description = model.projectDescription(for: project) {
                        if let line = description.oneLiner { Text(MarkdownInline.attributed(line)).font(.title3) }
                        if let summary = description.summary { MarkdownView(text: summary).foregroundStyle(.secondary) }
                    }
                    let details = model.projectPortfolioDetails(for: project)
                    if let link = details.githubURL, let url = URL(string: link) { Link("GitHub", destination: url) }
                    if let link = details.websiteURL, let url = URL(string: link) { Link("Website", destination: url) }

                }.padding(24).frame(maxWidth: .infinity, alignment: .leading) }
            } else {
                HStack { InlineSearchField(text: $query, prompt: "Search work"); Spacer(); Button { newWork = true } label: { Label("Add work", systemImage: "plus") } }.padding(12)
                ScrollView { LazyVStack(alignment: .leading, spacing: 14) {
                    if presentation == .decide, let next = model.projectNextAction(for: project) { Text("Next action").font(.headline); row(next) }
                    ForEach(WorkItemKind.allCases) { kind in
                        let items = records.filter { $0.kind == kind && $0.isOpen }
                        if !items.isEmpty { Text(kind.displayName + "s").font(.headline)
                            if presentation == .cards { LazyVGrid(columns: [GridItem(.adaptive(minimum: 210))]) { ForEach(items) { row($0).padding(12).background(.quaternary, in: RoundedRectangle(cornerRadius: 8)) } } }
                            else { ForEach(items.filter { child in child.parentID == nil || !records.contains(where: { parent in parent.id == child.parentID && parent.kind == kind }) }) { branch($0, visited: []) } }
                        }
                    }
                    let done = records.filter { !$0.isOpen }
                    if !done.isEmpty { DisclosureGroup("Completed work · \(done.count)") { ForEach(done) { row($0) } } }
                    if records.isEmpty { ContentUnavailableView("No linked work", systemImage: "checklist", description: Text("Add a task, feature or milestone to this project.")) }
                }.padding(20) }
            }
        }.sheet(isPresented: $newWork) { WorkItemEditor(mode: .create, projectPath: model.workspaceRelativePath(for: project.url)) { value in try await model.createWorkItem(value) } }
    }
    private func branch(_ record: WorkItem, visited: Set<String>) -> AnyView {
        let path = visited.union([record.id])
        let children = records.filter { ($0.parentID == record.id || $0.parentIDs.contains(record.id) || $0.featureIDs.contains(record.id) || $0.milestoneIDs.contains(record.id)) && !path.contains($0.id) && $0.isOpen }
        return AnyView(Group {
            if children.isEmpty || path.count > 12 { row(record) }
            else { DisclosureGroup { ForEach(children) { branch($0, visited: path) } } label: { row(record) } }
        })
    }
    private func row(_ item: WorkItem) -> some View {
        Button { model.edit(workItem: item) } label: {
            HStack { Image(systemName: item.kind.symbolName); Text(item.title).lineLimit(2); Spacer(); Text("\(item.stage.displayName) · \(item.status.displayName)").font(.caption).foregroundStyle(.secondary); Image(systemName: "pencil").font(.caption) }.padding(.vertical, 4)
        }.buttonStyle(.plain)
            .contextMenu {
                Button("Open file") { model.open(item.url) }
                Divider()
                WorkDeletionMenu(item: item) { model.requestDeletion(of: $0) }
            }
    }
}
