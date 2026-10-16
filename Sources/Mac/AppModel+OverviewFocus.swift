import Foundation
import BetterWorkspaceCore

extension AppModel {
    @discardableResult
    func prepareOverviewInbox() -> OverviewInboxController {
        if let overviewInbox, overviewInbox.workspace.canonicalPath == workspace.root.canonicalPath { return overviewInbox }
        let controller = OverviewInboxController(workspace: workspace.root)
        overviewInbox = controller
        return controller
    }

    func rebuildOverviewFocus() {
        let tasks = workItems.filter { $0.kind == .task }
        let grouped = Dictionary(grouping: tasks, by: { $0.projectPath ?? "" })
        let sessions = Dictionary(grouping: recentSessions.filter { $0.activeSeconds >= Attention.meaningfulSessionSeconds }, by: \.projectID)
        let preferences = scoringPreferences()
        var result: [OverviewFocusItem] = projects().compactMap { project in
            guard let path = workspaceRelativePath(for: project.url) else { return nil }
            let linked = (grouped[path] ?? []) + (grouped[project.url.canonicalPath] ?? [])
            let metadata = projectMetadata(for: project)
            let score = score(for: project, preferences: preferences)
            let lastWorked = projectRecord(for: project)?.watcherID.flatMap { sessions[$0]?.map(\.endedAt).max() }
            return OverviewFocusItem(id: project.id, path: path, title: project.displayTitle, kind: .projects,
                score: (score?.coverage ?? 0) >= 0.5 ? score?.projectScore : nil,
                completed: linked.filter { $0.status == .completed }.count, total: linked.count,
                lastWorked: lastWorked, lastChanged: project.contentModifiedAt,
                terminal: metadata.isTerminal, blocked: metadata.isUnavailableForNextWork)
        }
        result += items(for: .ideas).compactMap { idea in
            workspaceRelativePath(for: idea.url).map { OverviewFocusItem(id: idea.id, path: $0, title: idea.displayTitle, kind: .ideas, score: ideaRecord(for: idea.url)?.planning?.score(preferences: preferences).projectScore, lastChanged: idea.contentModifiedAt) }
        }
        var linkedByID: [String: [WorkItem]] = [:]
        for task in tasks {
            for id in Set(task.featureIDs + task.milestoneIDs + task.parentIDs + [task.parentID].compactMap { $0 }) { linkedByID[id, default: []].append(task) }
        }
        result += workItems.filter { $0.kind == .feature || $0.kind == .milestone }.compactMap { work in
            guard let path = workspaceRelativePath(for: work.url) else { return nil }
            let linked = linkedByID[work.id] ?? []
            return OverviewFocusItem(id: work.id, path: path, title: work.title, kind: work.kind == .feature ? .features : .milestones,
                completed: linked.filter { $0.status == .completed }.count, total: linked.count,
                lastChanged: work.modifiedAt, terminal: work.status == .completed)
        }
        overviewFocusItems = result
    }

    func overviewDigest() -> OverviewDigest {
        var seen = Set<String>()
        var items: [OverviewFocusItem] = []
        for kind in OverviewContent.allCases {
            for focus in OverviewFocus.allCases {
                for item in OverviewRanking.items(overviewFocusItems, kind: kind, focus: focus).prefix(5) {
                    if seen.insert(item.id).inserted { items.append(item) }
                }
            }
        }
        return OverviewDigest(focusItems: items, inboxItem: overviewInbox?.mobileItem, inboxCheckedAt: overviewInbox?.checkedAt, reviewItems: overviewInbox?.reviewItems, reviewCount: overviewInbox?.verified == true ? overviewInbox?.dueCount : nil, attention: widgetProjectAttention(), captureReviews: ingestItems.prefix(30).map { item in
            MobileCaptureReview(capture: DashboardCapture(name: item.url.lastPathComponent, modified: item.item.rawModifiedAt ?? item.capturedAt), priority: item.priority, until: item.reviewAfter)
        })
    }

    func revealOverviewFocus(_ item: OverviewFocusItem) {
        if let work = workItems.first(where: { $0.id == item.id }) { reveal(workItem: work) }
        else if item.kind == .projects { reveal(projectPath: workspace.root.appendingPathComponent(item.path).canonicalPath) }
        else if let idea = items(for: .ideas).first(where: { $0.id == item.id }) {
            navigate(to: .area(.ideas), selecting: idea)
        }
    }
}
