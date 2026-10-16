import SwiftUI
import BetterWorkspaceCore

enum MobileWidgetDestination: Hashable {
    case charts(String), attention(String), review, unavailable(String)
}

/// Exact widget routes retain their identity, even when their record has gone.
struct MobileWidgetDestinationView: View {
    @Environment(MobileWorkspaceModel.self) private var model
    let destination: MobileWidgetDestination
    private var dashboard: WorkspaceDashboardSnapshot {
        var value = WorkspaceDashboardSnapshot.make(from: model.snapshot)
        if let cached = WidgetDashboardRuntime.load() {
            value.captureCount = cached.captureCount
            value.captureUpdatedAt = cached.captureUpdatedAt
        }
        return value
    }
    var body: some View {
        switch destination {
        case .unavailable(let message):
            ContentUnavailableView("Record unavailable", systemImage: "questionmark.folder", description: Text(message))
        case .review:
            List {
                if model.widgetReviewItemID != nil && model.overviewInboxItem == nil {
                    Text("This review item changed, has a pending decision, or is no longer available. Return to Overview to review the next item.")
                } else { MobileOverviewInboxSection() }
                MobilePlanningStatusSection()
            }.navigationTitle("Inbox Review")
                .onDisappear { model.widgetReviewItemID = nil }
        case .charts(let mode):
            List {
                if mode == "status" {
                    let groups = Dictionary(grouping: dashboard.projects) { $0.status ?? "No status" }
                    ForEach(groups.keys.sorted(), id: \.self) { status in
                        LabeledContent(status, value: String(groups[status]?.count ?? 0))
                    }
                } else {
                    ForEach(dashboard.projects) { project in
                        Button { model.widgetNavigation = project.route } label: {
                            VStack(alignment: .leading) {
                                Text(project.name).font(.headline)
                                if project.focus.total > 0 {
                                    ProgressView(value: project.focus.fraction)
                                    Text("\(project.focus.completed)/\(project.focus.total) linked tasks done").font(.caption)
                                } else { Text("No linked tasks yet").font(.caption).foregroundStyle(.secondary) }
                            }
                        }.buttonStyle(.plain)
                    }
                }
            }.navigationTitle("Project Charts")
        case .attention(let category):
            if category.hasPrefix("sync:") {
                ContentUnavailableView("Review sync on Mac", systemImage: "arrow.triangle.2.circlepath", description: Text("Resolve these conflicts in Better Workspace on Mac."))
            } else {
            List {
                ForEach(dashboard.attentionItems().filter { accepts($0, category: category) }) { item in
                    Button { model.widgetNavigation = item.route } label: {
                        VStack(alignment: .leading) {
                            Text(item.title).font(.headline)
                            Text(item.reason).font(.caption).foregroundStyle(.secondary)
                        }
                    }.buttonStyle(.plain)
                }
                MobilePlanningStatusSection()
            }.navigationTitle("Needs Attention")
            }
        }
    }
    private func accepts(_ item: WidgetAttentionItem, category: String) -> Bool {
        switch category {
        case "work": item.category == .overdue || item.category == .blocked
        case "inbox": item.category == .inbox
        case "projects": item.category == .project
        case "failures", "failure": item.category == .failure
        default: true
        }
    }
}
