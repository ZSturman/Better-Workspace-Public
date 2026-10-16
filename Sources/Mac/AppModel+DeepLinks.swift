import Foundation
import BetterWorkspaceCore

/// `betterworkspace://` links, as the desktop widgets send them.
///
/// Each one opens the place in this app that owns the thing, never a view of the
/// service's own: a project in Projects, an idea in Ideas, an intent folder as its area,
/// the day's work in Logs. A link to something that no longer exists opens Overview
/// rather than failing silently on a blank screen.
extension AppModel {

    enum DeepLink: Equatable {
        case project(serviceID: String)
        case item(serviceID: String)
        case intent(serviceID: String)
        case today
        case overview
        /// `betterworkspace://capture` (`?kind=idea`): the quick-capture panel.
        case capture(asIdea: Bool)

        init?(_ url: URL) {
            guard url.scheme == "betterworkspace" else { return nil }
            let id = url.pathComponents.dropFirst().first
            switch url.host {
            case "project": guard let id else { return nil }; self = .project(serviceID: id)
            case "item": guard let id else { return nil }; self = .item(serviceID: id)
            case "intent": guard let id else { return nil }; self = .intent(serviceID: id)
            case "today": self = .today
            case "capture":
                let kind = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "kind" }?.value
                self = .capture(asIdea: kind == "idea")
            case "activity", "diagnostics", "overview": self = .overview
            default: return nil
            }
        }
    }

    @MainActor
    func openDeepLink(_ url: URL) async {
        if let route = WidgetRoute(url: url) { await openWidgetRoute(route); return }
        guard let link = DeepLink(url) else { return }
        switch link {
        case let .project(serviceID):
            // A widget clicked while the app was closed launches it with the link, before
            // the first scan has finished; load what the link needs rather than give up.
            if projects().isEmpty { await refresh(area: .projects) }
            if let record = projectStore.record(watcherID: serviceID),
               let item = projects().first(where: { $0.url.canonicalPath == record.url.canonicalPath }) {
                openProjectWorkspace(for: item)
                return
            }
        case let .item(serviceID):
            if serviceIdeasByPath.isEmpty { await refreshBackgroundService() }
            if items(for: .ideas).isEmpty { await refresh(area: .ideas) }
            if let idea = serviceIdeasByPath.values.first(where: { $0.id == serviceID }),
               let item = items(for: .ideas).first(where: { $0.url.canonicalPath == idea.canonicalPath }) {
                navigate(to: .area(.ideas), selecting: item)
                return
            }
        case let .intent(serviceID):
            if folders.isEmpty { await refreshFolders() }
            if let path = await BackgroundServiceClient.shared.intentFolderPaths()?[serviceID],
               let name = workspace.areaName(containing: URL(fileURLWithPath: path).appendingPathComponent("x")),
               folder(named: name) != nil {
                selection = .folder(name)
                return
            }
        case .today:
            TestIsolation.defaults.set(LogsView.Mode.workLog.rawValue, forKey: "logsMode")
            selection = .area(.logs)
            return
        case let .capture(asIdea):
            QuickCaptureController.shared.show(asIdea: asIdea)
            return
        case .overview:
            break
        }
        selection = .overview
    }
    @MainActor
    func openWidgetRoute(_ route: WidgetRoute) async {
        switch route {
        case .project(let id):
            if projects().isEmpty { await refresh(area: .projects) }
            if let project = projects().first(where: { projectRecord(for: $0)?.id == id || projectRecord(for: $0)?.watcherID == id || workspaceRelativePath(for: $0.url) == id }) {
                openProjectWorkspace(for: project); return
            }
            statusMessage = "This pinned project is no longer available."
        case .task(let id):
            if isAwaitingWorkItems { await refreshWorkItems() }
            if let work = workItems.first(where: { $0.id == id }) { reveal(workItem: work); return }
            statusMessage = "This work item is no longer available."
        case .idea(let path):
            if items(for: .ideas).isEmpty { await refresh(area: .ideas) }
            if let item = items(for: .ideas).first(where: { workspaceRelativePath(for: $0.url) == path }) { navigate(to: .area(.ideas), selecting: item); return }
            statusMessage = "This idea is no longer available."
        case .review(let id):
            selection = .overview
            let controller = prepareOverviewInbox()
            if !id.isEmpty { await controller.selectWidgetItem(id: id) }
            widgetOverviewSection = "widget-review"
            TestIsolation.defaults.set(true, forKey: "overview.reviewExpanded")
            return
        case .capture(let name):
            await refreshIngest()
            selection = .ingest
            if !name.isEmpty {
                selectedIngestItem = ingestItems.first { $0.url.lastPathComponent == name }
                if selectedIngestItem == nil { statusMessage = "This capture has left the inbox." }
            }
            return
        case .charts:
            closeProjectWorkspace()
            var preferences = ProjectBrowserPreferences.load(); preferences.presentation = "charts"; preferences.save()
            widgetChartRequest = UUID(); selection = .area(.projects); return
        case .attention(let category):
            if category.hasPrefix("sync:") {
                let record = graphRecords.first { $0.id == String(category.dropFirst(5)) }
                let incoming = record?.changes.contains { $0.state == .incoming || $0.state == .conflict } == true
                selection = .overview
                reviewProjectSync(incoming ? .incoming : .outgoing, project: record?.kind == .projects ? record : nil, presenterID: "widget")
                return
            }
            selection = .overview; widgetOverviewSection = "widget-attention"; return
        case .overview: break
        }
        selection = .overview
    }

}
