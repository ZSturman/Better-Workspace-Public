import SwiftUI
import BetterWorkspaceCore

/// Projects has three purpose-built presentations. The table remains the compact,
/// operational view; cards and decisions make the same filesystem-backed projects
/// easier to browse and reason about without creating a second project database.
enum ProjectPresentation: String, CaseIterable, Identifiable, Codable {
    case table
    case portfolio
    case decide

    var id: Self { self }

    var title: String {
        switch self {
        case .table: return "Table"
        case .portfolio: return "Cards"
        case .decide: return "Decide"
        }
    }

    var symbolName: String {
        switch self {
        case .table: return "tablecells"
        case .portfolio: return "rectangle.grid.2x2"
        case .decide: return "scope"
        }
    }
}

/// The portfolio decision surface deliberately names every calculation.  It does not
/// manufacture an opaque recommendation from incomplete project data.
struct ProjectsDecisionView: View {
    @Environment(AppModel.self) private var model
    var candidates: [ProjectPortfolio.Candidate]? = nil
    var actionMenu: ((ProjectPortfolio.Candidate) -> AnyView)? = nil
    var inventory: AnyView? = nil
    let open: (ProjectPortfolio.Candidate) -> Void

    var body: some View {
        let preferences = model.scoringPreferences()
        let candidates = candidates ?? model.portfolioCandidates()
        let recommendation = ProjectPortfolio.recommend(candidates, preferences: preferences)
        let rankings = ProjectPortfolio.rankings(candidates, preferences: preferences)
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.loose) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("What should I work on?").font(.title2.weight(.semibold))
                    ProjectContextHelp(text: "Recommended Next picks from projects with open Now or Next work, using your search and filters. Each ranking card applies one lens to your ratings; its information button names the formula. Activity and staleness appear in Charts and the project workspace; they do not affect these ranks.")
                }
                if let recommendation {
                    DecisionRecommendation(recommendation: recommendation, actionMenu: actionMenu, open: open)
                } else if model.isAwaitingWorkItems || model.isAwaitingFirstRead(of: .projects) {
                    LoadingLabel(text: "Loading projects and work items…")
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, Theme.Space.loose)
                } else {
                    ContentUnavailableView("No actionable project", systemImage: "checklist",
                                           description: Text("Add an open Now or Next work item to an active, unblocked project."))
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 310), spacing: Theme.Space.base)], spacing: Theme.Space.base) {
                    ForEach(rankings) { ranking in DecisionRankingCard(ranking: ranking, actionMenu: actionMenu, open: open) }
                }
                if let inventory { inventory }
            }.padding(Theme.Space.loose)
        }
        .accessibilityIdentifier("projects.decide")
    }
}

private struct DecisionRecommendation: View {
    let recommendation: ProjectPortfolio.Recommendation
    var actionMenu: ((ProjectPortfolio.Candidate) -> AnyView)?
    let open: (ProjectPortfolio.Candidate) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Label("RECOMMENDED NEXT", systemImage: "sparkles").font(.caption.weight(.bold)).foregroundStyle(.tint)
                ProjectContextHelp(text: recommendation.explanation)
                Spacer(minLength: 0)
                if let actionMenu { actionMenu(recommendation.candidate) }
            }
            Button { open(recommendation.candidate) } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(recommendation.candidate.name).font(.title3.weight(.semibold))
                    if let action = recommendation.candidate.nextAction { Text(action.title).font(.headline) }
                    Text(recommendation.factors.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain)
        }
        .padding(Theme.Space.base)
        .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: Theme.Radius.panel))
    }
}

private struct DecisionRankingCard: View {
    let ranking: ProjectPortfolio.Ranking
    var actionMenu: ((ProjectPortfolio.Candidate) -> AnyView)?
    let open: (ProjectPortfolio.Candidate) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.snug) {
            HStack { Text(ranking.title).font(.headline); ProjectContextHelp(text: ranking.formula) }
            Divider()
            if ranking.items.isEmpty { Text("Rate eligible projects to populate this lens.").font(.caption).foregroundStyle(.tertiary) }
            ForEach(ranking.items, id: \.candidate.id) { item in
                HStack {
                Button { open(item.candidate) } label: {
                    HStack { Text(item.candidate.name).lineLimit(1); Spacer(); Text("\(Int(item.score.rounded()))").monospacedDigit(); if let supporting = item.supporting { Text(supporting).font(.caption2).foregroundStyle(.secondary) } }
                }.buttonStyle(.plain)
                if let actionMenu { actionMenu(item.candidate) }
                }
            }
        }.padding(Theme.Space.base).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: Theme.Radius.card))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card).strokeBorder(Color.secondary.opacity(0.14)))
    }
}

// MARK: - Portfolio

/// The portfolio view deliberately mirrors the information hierarchy of
/// zacharysturman.com: title, concise description, tags, and quiet recency metadata.
/// It does not read the web project's content or manufacture public-facing data.
struct ProjectsPortfolioView: View {
    @Environment(AppModel.self) private var model
    let rows: [ProjectsView.ProjectRow]
    let spaces: [WorkspaceItem]
    let query: String
    let group: ProjectPortfolioGroup
    let select: (WorkspaceItem) -> Void

    private let columns = [GridItem(.adaptive(minimum: 210, maximum: 310), spacing: Theme.Space.base)]

    var body: some View {
        if rows.isEmpty, model.isAwaitingFirstRead(of: .projects) {
            LoadingAreaState(title: "Loading projects…")
        } else if rows.isEmpty {
            EmptyAreaState(
                symbol: "rectangle.grid.2x2",
                title: query.isEmpty ? "No projects yet" : "No matching projects",
                message: query.isEmpty
                    ? "Add or classify a folder into Projects to see it here."
                    : "Nothing here matches “\(query)”."
            )
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.loose) {
                    ProjectSpacesStrip(spaces: spaces)

                    ForEach(groupedRows) { section in
                        VStack(alignment: .leading, spacing: Theme.Space.snug) {
                            if group != .none {
                                HStack {
                                    Text(section.title).font(.headline)
                                    Text("\(section.rows.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                }
                            }
                            LazyVGrid(columns: columns, alignment: .leading, spacing: Theme.Space.base) {
                                ForEach(section.rows) { row in
                                    PortfolioProjectCard(
                                        row: row,
                                        description: model.projectDescription(for: row.item),
                                        tags: model.tags(for: row.item)
                                    ) {
                                        select(row.item)
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(Theme.Space.base)
            }
        }
    }

    private struct CardGroup: Identifiable {
        let title: String
        let rows: [ProjectsView.ProjectRow]
        var id: String { title }
    }

    private var groupedRows: [CardGroup] {
        guard group != .none else { return [CardGroup(title: "All projects", rows: rows)] }
        let buckets = Dictionary(grouping: rows) { row -> String in
            switch group {
            case .domain: return row.metadata.domain ?? "Uncategorized"
            case .status: return row.metadata.status ?? "No status"
            case .phase: return row.metadata.phase ?? "No phase"
            case .priority: return row.metadata.portfolioPriorityLabel
            case .none: return "All projects"
            }
        }
        return buckets.map { CardGroup(title: $0.key, rows: $0.value) }
            .sorted { lhs, rhs in
                if lhs.title == "Uncategorized" || lhs.title == "No status" || lhs.title == "No phase" || lhs.title == "Untriaged" {
                    return false
                }
                if rhs.title == "Uncategorized" || rhs.title == "No status" || rhs.title == "No phase" || rhs.title == "Untriaged" {
                    return true
                }
                return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
            }
    }
}

private struct PortfolioProjectCard: View {
    @Environment(AppModel.self) private var model
    let row: ProjectsView.ProjectRow
    let description: ProjectDescription?
    let tags: [Tag]
    let showDetail: () -> Void
    @State private var toolCapability: ProjectToolCapability?

    private var summary: String? { description?.oneLiner ?? description?.summary }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.snug) {
            Button(action: showDetail) {
                VStack(alignment: .leading, spacing: Theme.Space.snug) {
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: Theme.Radius.card)
                        .fill(kindTint.opacity(0.15))
                        .frame(height: 118)
                    Image(systemName: row.kind.symbolName)
                        .font(.system(size: 30, weight: .light))
                        .foregroundStyle(kindTint)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    Text(row.kind.rawValue)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(.thinMaterial, in: Capsule())
                        .padding(8)
                }

                Text(row.name)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                Text(summary.map(MarkdownInline.summary) ?? AttributedString("No project description yet"))
                    .font(.system(size: 11))
                    .foregroundStyle(summary == nil ? .tertiary : .secondary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if tags.isEmpty == false {
                    TagChipRow(tags: tags, limit: 3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                    HStack {
                        Text(row.metadata.domain ?? row.metadata.status ?? Format.relativeDate(row.item.contentModifiedAt))
                        Spacer()
                        if row.metadata.portfolioPriority != nil {
                            Text(row.metadata.portfolioPriorityLabel)
                        } else {
                            Label("\(row.children)", systemImage: "folder")
                        }
                    }
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 236, alignment: .topLeading)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("projects.portfolio.\(row.id)")
            .accessibilityLabel("Open portfolio details for \(row.name)")

            if let toolCapability, toolCapability.canExplain || toolCapability.canFlowReview {
                Divider()
                HStack(spacing: Theme.Space.snug) {
                    if toolCapability.canExplain {
                        Button("Explain") { model.openProjectTool(.explain, for: row.item) }
                            .accessibilityIdentifier("projects.portfolio.\(row.id).explain")
                    }
                    if toolCapability.canFlowReview {
                        Button("User Flow") { model.openProjectTool(.flowReview, for: row.item) }
                            .accessibilityIdentifier("projects.portfolio.\(row.id).flowReview")
                    }
                    Spacer()
                }
                .buttonStyle(.borderless)
                .font(.system(size: 11, weight: .medium))
            }
        }
        .padding(Theme.Space.snug)
        .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: Theme.Radius.card))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card).strokeBorder(Color.secondary.opacity(0.16)))
        .task(id: row.item.url.canonicalPath) {
            toolCapability = await model.projectToolCapability(for: row.item)
        }
    }

    private var kindTint: Color {
        switch row.kind {
        case .xcode, .swiftPackage: return .orange
        case .node, .python, .web: return .blue
        case .media: return .purple
        case .notes: return .secondary
        case .empty, .folder: return .accentColor
        }
    }
}

private struct ProjectSpacesStrip: View {
    @Environment(AppModel.self) private var model
    let spaces: [WorkspaceItem]
    @State private var childrenBySpace: [String: [WorkspaceItem]] = [:]

    var body: some View {
        if spaces.isEmpty == false {
            VStack(alignment: .leading, spacing: Theme.Space.snug) {
                Text("Project spaces")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                HStack(alignment: .top, spacing: Theme.Space.snug) {
                    ForEach(spaces) { space in
                        ProjectSpaceCard(space: space, children: childrenBySpace[space.id] ?? [])
                    }
                }
            }
            .task(id: spaces.map(\.id)) {
                var loaded: [String: [WorkspaceItem]] = [:]
                for space in spaces {
                    if let children = await model.children(of: space.url) {
                        loaded[space.id] = children
                    }
                }
                childrenBySpace = loaded
            }
        }
    }
}

private struct ProjectSpaceCard: View {
    @Environment(AppModel.self) private var model
    let space: WorkspaceItem
    let children: [WorkspaceItem]

    private var role: ProjectFolderRole { space.projectFolderRole ?? .organizer }

    var body: some View {
        Button { model.open(space.url) } label: {
            VStack(alignment: .leading, spacing: 5) {
                Label(role.title, systemImage: role.symbolName)
                    .font(.system(size: 12, weight: .semibold))
                Text(role.summary)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                if children.isEmpty == false {
                    Text(children.prefix(3).map(\.displayTitle).joined(separator: " · "))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Theme.Space.snug)
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: Theme.Radius.card))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Open \(role.title)")
    }
}

private struct ProjectPortfolioDetail: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let project: WorkspaceItem

    private var workItems: [WorkItem] {
        guard let path = model.workspaceRelativePath(for: project.url) else { return [] }
        return model.workItems.filter { $0.projectPath == path }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    var body: some View {
        let description = model.projectDescription(for: project)
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.loose) {
                HStack(alignment: .top) {
                    Image(systemName: "folder.fill")
                        .font(.system(size: 34, weight: .light))
                        .foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(project.displayTitle).font(.title2.weight(.semibold))
                        Text(Format.relativeDate(project.contentModifiedAt))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Reveal in Finder") { model.revealInFinder(project.url) }
                    Button("Done") { dismiss() }
                }

                if let oneLiner = description?.oneLiner {
                    Text(MarkdownInline.attributed(oneLiner)).font(.headline)
                }
                if let summary = description?.summary {
                    MarkdownView(text: summary).foregroundStyle(.secondary)
                }
                let tags = model.tags(for: project)
                if tags.isEmpty == false {
                    FlowLayout(spacing: 5) { ForEach(tags) { TagChip(tag: $0) } }
                }

                Divider()
                HStack(spacing: Theme.Space.loose) {
                    ProjectFact(title: "Contents", value: Format.count(project.immediateChildCount, singular: "item"))
                    ProjectFact(title: "Planning records", value: "\(workItems.count)")
                    ProjectFact(title: "Score", value: model.score(for: project).flatMap { score in
                        score.projectScore.map { String(format: "%.0f", $0) }
                    } ?? "—")
                }

                if workItems.isEmpty == false {
                    VStack(alignment: .leading, spacing: Theme.Space.snug) {
                        Text("Connected plan").font(.headline)
                        ForEach(workItems) { item in
                            HStack {
                                Image(systemName: item.kind.symbolName).foregroundStyle(.tint)
                                Text(item.title).lineLimit(1)
                                Spacer()
                                Text(item.status.displayName).foregroundStyle(.secondary)
                            }
                            .font(.callout)
                            .contentShape(Rectangle())
                            .onTapGesture { model.open(item.url) }
                        }
                    }
                }
            }
            .padding(24)
        }
        .frame(minWidth: 560, minHeight: 360)
    }
}

private struct ProjectFact: View {
    let title: String
    let value: String
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.headline)
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Relationship map

struct ProjectsGraphView: View {
    @Environment(AppModel.self) private var model
    let projects: [WorkspaceItem]
    let spaces: [WorkspaceItem]
    let select: (WorkspaceItem) -> Void
    @State private var selectedProjectID: String?

    private var activeProject: WorkspaceItem? {
        if let selectedProjectID, let project = projects.first(where: { $0.id == selectedProjectID }) { return project }
        if let selected = model.selectedItem, projects.contains(selected) { return selected }
        return projects.first
    }

    private var linkedItems: [WorkItem] {
        guard let activeProject, let path = model.workspaceRelativePath(for: activeProject.url) else { return [] }
        return model.workItems
            .filter { $0.projectPath == path }
            .sorted { lhs, rhs in
                if lhs.kind != rhs.kind { return lhs.kind.rawValue < rhs.kind.rawValue }
                return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
            }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Theme.Space.snug) {
                Picker("Project", selection: Binding(
                    get: { selectedProjectID ?? activeProject?.id ?? "" },
                    set: { selectedProjectID = $0 }
                )) {
                    ForEach(projects) { project in Text(project.displayTitle).tag(project.id) }
                }
                .frame(maxWidth: 320)
                Text("Project → planning records · solid = parent · dashed = related")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if spaces.isEmpty == false {
                    Label("\(spaces.count) organizational spaces excluded", systemImage: "folder.badge.gearshape")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(Theme.Space.base)

            Divider()
            if let activeProject {
                if linkedItems.isEmpty, model.isAwaitingWorkItems {
                    LoadingAreaState(title: "Loading planning records…")
                } else if linkedItems.isEmpty {
                    EmptyAreaState(
                        symbol: "point.3.connected.trianglepath.dotted",
                        title: "No connected planning records",
                        message: "Add a task, feature, milestone, or goal with “\(activeProject.displayTitle)” as its project to draw its plan here."
                    )
                } else {
                    ProjectRelationshipGraph(project: activeProject, items: Array(linkedItems.prefix(18)), select: select)
                    if linkedItems.count > 18 {
                        Text("Showing the first 18 of \(linkedItems.count) connected planning records.")
                            .font(.caption).foregroundStyle(.secondary)
                            .padding(.bottom, Theme.Space.snug)
                    }
                }
            } else if model.isAwaitingFirstRead(of: .projects) {
                LoadingAreaState(title: "Loading projects…")
            } else {
                EmptyAreaState(symbol: "folder.badge.questionmark", title: "No projects yet", message: "Add a project folder to begin mapping its plan.")
            }
        }
        .accessibilityIdentifier("projects.map")
    }
}

struct ProjectRelationshipGraph: View {
    @Environment(AppModel.self) private var model
    let project: WorkspaceItem
    let items: [WorkItem]
    let select: (WorkspaceItem) -> Void

    private struct Node: Identifiable {
        let id: String
        let title: String
        let symbol: String
        let color: Color
        let url: URL?
        let isProject: Bool
    }

    private var nodes: [Node] {
        [Node(id: project.id, title: project.displayTitle, symbol: "folder.fill", color: .accentColor, url: project.url, isProject: true)]
            + items.map { item in
                Node(id: item.id, title: item.title, symbol: item.kind.symbolName,
                     color: color(for: item.kind), url: item.url, isProject: false)
            }
    }

    private var edges: [(String, String, Bool)] {
        let ids = Set(items.map(\.id))
        var result = items.map { (project.id, $0.id, false) }
        for item in items {
            if let parent = item.parentID, ids.contains(parent) { result.append((parent, item.id, false)) }
            for related in item.relatedIDs where ids.contains(related) { result.append((item.id, related, true)) }
        }
        return result
    }

    var body: some View {
        GeometryReader { proxy in
            let positions = graphPositions(for: nodes, in: proxy.size)
            ZStack {
                Canvas { context, _ in
                    for (from, to, dashed) in edges {
                        guard let start = positions[from], let end = positions[to] else { continue }
                        var path = Path()
                        path.move(to: start)
                        path.addLine(to: end)
                        context.stroke(path, with: .color(.secondary.opacity(0.38)),
                                       style: StrokeStyle(lineWidth: dashed ? 1 : 1.5, dash: dashed ? [4, 4] : []))
                    }
                }
                ForEach(nodes) { node in
                    if let point = positions[node.id] {
                        Button {
                            if node.isProject { select(project) }
                            if let url = node.url { model.open(url) }
                        } label: {
                            VStack(spacing: 3) {
                                Image(systemName: node.symbol)
                                    .font(.system(size: node.isProject ? 17 : 13, weight: .medium))
                                    .foregroundStyle(node.color)
                                Text(node.title)
                                    .font(.system(size: 10, weight: node.isProject ? .semibold : .regular))
                                    .lineLimit(2)
                                    .multilineTextAlignment(.center)
                            }
                            .frame(width: node.isProject ? 132 : 98, height: node.isProject ? 58 : 50)
                            .padding(5)
                            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(node.color.opacity(0.38)))
                        }
                        .buttonStyle(.plain)
                        .position(point)
                        .accessibilityLabel("Open \(node.title)")
                    }
                }
            }
        }
        .frame(minHeight: 430)
        .padding(Theme.Space.base)
    }

    private func graphPositions(for nodes: [Node], in size: CGSize) -> [String: CGPoint] {
        guard let root = nodes.first else { return [:] }
        var positions = [root.id: CGPoint(x: size.width / 2, y: 52)]
        let children = Array(nodes.dropFirst())
        let columns = min(4, max(1, Int(ceil(sqrt(Double(children.count))))))
        let rows = max(1, Int(ceil(Double(children.count) / Double(columns))))
        for (index, node) in children.enumerated() {
            let column = index % columns
            let row = index / columns
            let x = size.width * CGFloat(column + 1) / CGFloat(columns + 1)
            let y = 135 + CGFloat(row) * min(100, (size.height - 155) / CGFloat(rows))
            positions[node.id] = CGPoint(x: x, y: y)
        }
        return positions
    }

    private func color(for kind: WorkItemKind) -> Color {
        switch kind {
        case .task: return .blue
        case .feature: return .purple
        case .milestone: return .orange
        case .goal: return .green
        }
    }
}
