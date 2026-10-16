import AppIntents
import SwiftUI
import WidgetKit
import BetterWorkspaceCore

enum DashboardMode: String { case project, focus, charts, tasks, nextWork, review, captures, attention }
enum WidgetFocus: String, AppEnum {
    case almostDone, highestRated, revisit
    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Focus")
    static var caseDisplayRepresentations: [Self: DisplayRepresentation] = [.almostDone: "Almost Done", .highestRated: "Highest Rated", .revisit: "Needs a Revisit"]
}
enum WidgetContent: String, AppEnum {
    case projects, ideas, features, milestones
    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Content")
    static var caseDisplayRepresentations: [Self: DisplayRepresentation] = [.projects: "Projects", .ideas: "Ideas", .features: "Features", .milestones: "Milestones"]
}
enum WidgetChart: String, AppEnum {
    case progress, status
    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Chart")
    static var caseDisplayRepresentations: [Self: DisplayRepresentation] = [.progress: "Linked-task progress", .status: "Projects by status"]
}
enum WidgetQueue: String, AppEnum {
    case next, overdue, inProgress
    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Tasks")
    static var caseDisplayRepresentations: [Self: DisplayRepresentation] = [.next: "Next", .overdue: "Overdue", .inProgress: "In Progress"]
}
enum WidgetAttentionScope: String, AppEnum {
    case all, work, inbox, projects, failures
    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Attention")
    static var caseDisplayRepresentations: [Self: DisplayRepresentation] = [.all: "All", .work: "Work", .inbox: "Inboxes", .projects: "Projects", .failures: "Failures"]
}
enum WidgetReviewFolder: String, AppEnum {
    case all, study = "To Study", watch = "To Watch", lookup = "To Look Up", todo = "To Do", checkout = "To Check Out", read = "To Read"
    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Review folder")
    static var caseDisplayRepresentations: [Self: DisplayRepresentation] = [.all: "All eligible folders", .study: "To Study", .watch: "To Watch", .lookup: "To Look Up", .todo: "To Do", .checkout: "To Check Out", .read: "To Read"]
}
enum WidgetFocusDisplay: String, AppEnum {
    case chart, list
    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Display")
    static var caseDisplayRepresentations: [Self: DisplayRepresentation] = [.chart: "Chart", .list: "List"]
}

struct DashboardProjectEntity: AppEntity {
    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Project")
    static var defaultQuery = DashboardProjectQuery()
    let id: String
    let name: String
    var displayRepresentation: DisplayRepresentation { .init(title: "\(name)") }
}
struct DashboardProjectQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [DashboardProjectEntity] {
        let snapshot = WidgetDashboardRuntime.load()
        // Keep the configured identity resolvable when a project is removed. WidgetKit
        // must not turn an unavailable pin into the automatic first-project default.
        return identifiers.map { .init(id: $0, name: snapshot?.project(id: $0)?.name ?? "Unavailable project") }
    }
    func suggestedEntities() async throws -> [DashboardProjectEntity] {
        await WidgetDashboardRuntime.refresh()
        return (WidgetDashboardRuntime.load()?.projects ?? []).filter { !$0.focus.terminal }.prefix(50).map { .init(id: $0.id, name: $0.name) }
    }
    func entities(matching string: String) async throws -> [DashboardProjectEntity] {
        (WidgetDashboardRuntime.load()?.projects ?? []).filter { $0.name.localizedCaseInsensitiveContains(string) }.map { .init(id: $0.id, name: $0.name) }
    }
}
struct DashboardDestinationEntity: AppEntity {
    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Filing destination")
    static var defaultQuery = DashboardDestinationQuery()
    let id: String
    let name: String
    var displayRepresentation: DisplayRepresentation { .init(title: "\(name)") }
}
struct DashboardDestinationQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [DashboardDestinationEntity] {
        (WidgetDashboardRuntime.load()?.destinations ?? []).filter { identifiers.contains($0.path) }.map { .init(id: $0.path, name: $0.name) }
    }
    func suggestedEntities() async throws -> [DashboardDestinationEntity] {
        (WidgetDashboardRuntime.load()?.destinations ?? []).map { .init(id: $0.path, name: $0.name) }
    }
    func entities(matching string: String) async throws -> [DashboardDestinationEntity] {
        try await suggestedEntities().filter { $0.name.localizedCaseInsensitiveContains(string) }
    }
}

struct DashboardOptions {
    var mode: DashboardMode
    var projectID: String?
    var focus: OverviewFocus = .almostDone
    var content: OverviewContent = .projects
    var chart: WidgetChart = .progress
    var queue: WidgetTaskQueue = .next
    var attention: WidgetAttentionScope = .all
    var folder: WidgetReviewFolder = .all
    var display: WidgetFocusDisplay = .chart
    var destinations: [String] = []
    var scope: String { "\(mode.rawValue):\(projectID ?? "all"):\(folder.rawValue):\(destinations.joined(separator: "|"))" }
}
protocol DashboardConfig: WidgetConfigurationIntent { var options: DashboardOptions { get } }
struct DashboardProjectConfiguration: DashboardConfig {
    static var title: LocalizedStringResource = "Project Focus"
    @Parameter(title: "Project") var project: DashboardProjectEntity?
    var options: DashboardOptions { .init(mode: .project, projectID: project?.id) }
}
struct DashboardFocusConfiguration: DashboardConfig {
    static var title: LocalizedStringResource = "Bring Forward"
    @Parameter(title: "Content", default: .projects) var content: WidgetContent
    @Parameter(title: "Focus", default: .almostDone) var focus: WidgetFocus
    @Parameter(title: "Display", default: .chart) var display: WidgetFocusDisplay
    var options: DashboardOptions { .init(mode: .focus, focus: OverviewFocus(rawValue: focus.rawValue)!, content: OverviewContent(rawValue: content.rawValue)!, display: display) }
}
struct DashboardChartsConfiguration: DashboardConfig {
    static var title: LocalizedStringResource = "Project Charts"
    @Parameter(title: "Chart", default: .progress) var chart: WidgetChart
    var options: DashboardOptions { .init(mode: .charts, chart: chart) }
}
struct DashboardTasksConfiguration: DashboardConfig {
    static var title: LocalizedStringResource = "Tasks"
    @Parameter(title: "Queue", default: .next) var queue: WidgetQueue
    @Parameter(title: "Project") var project: DashboardProjectEntity?
    var options: DashboardOptions { .init(mode: .tasks, projectID: project?.id, queue: WidgetTaskQueue(rawValue: queue.rawValue)!) }
}
struct DashboardReviewConfiguration: DashboardConfig {
    static var title: LocalizedStringResource = "Inbox Review"
    @Parameter(title: "Folder", default: .all) var folder: WidgetReviewFolder
    var options: DashboardOptions { .init(mode: .review, folder: folder) }
}
struct DashboardCaptureConfiguration: DashboardConfig {
    static var title: LocalizedStringResource = "Capture Inbox"
    @Parameter(title: "First destination") var first: DashboardDestinationEntity?
    @Parameter(title: "Second destination") var second: DashboardDestinationEntity?
    @Parameter(title: "Third destination") var third: DashboardDestinationEntity?
    var options: DashboardOptions { .init(mode: .captures, destinations: [first, second, third].compactMap { $0?.id }) }
}
struct DashboardAttentionConfiguration: DashboardConfig {
    static var title: LocalizedStringResource = "Needs Attention"
    @Parameter(title: "Show", default: .all) var scope: WidgetAttentionScope
    var options: DashboardOptions { .init(mode: .attention, attention: scope) }
}

struct DashboardEntry: TimelineEntry {
    let date: Date
    let snapshot: WorkspaceDashboardSnapshot?
    let options: DashboardOptions
    let records: [WidgetCommandRecord]
    let confirmation: WidgetConfirmation?
    let cursor: Int
    let error: String?
    static func load(options: DashboardOptions) -> Self {
        let store = WidgetCommandStore.shared(appGroup: WidgetDashboardRuntime.appGroup)
        return Self(date: .now, snapshot: WidgetDashboardRuntime.load(), options: options,
            records: (try? store?.records()) ?? [], confirmation: try? store?.confirmation(scope: options.scope),
            cursor: (try? store?.value("cursor:" + options.scope, as: Int.self)) ?? 0,
            error: (try? store?.value("error:" + options.scope, as: String.self)) ?? (try? store?.value("transportError", as: String.self)))
    }
}
struct DashboardProvider<Configuration: DashboardConfig>: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> DashboardEntry { .init(date: .now, snapshot: nil, options: Configuration().options, records: [], confirmation: nil, cursor: 0, error: nil) }
    func snapshot(for configuration: Configuration, in context: Context) async -> DashboardEntry { .load(options: configuration.options) }
    func timeline(for configuration: Configuration, in context: Context) async -> Timeline<DashboardEntry> {
        await WidgetDashboardRuntime.refresh()
        let entry = DashboardEntry.load(options: configuration.options)
        let refresh = min(entry.confirmation?.expiresAt ?? .distantFuture, Date().addingTimeInterval(900))
        return Timeline(entries: [entry], policy: .after(refresh))
    }
}

struct DashboardProjectWidget: Widget {
    let kind = "WorkspaceProjectFocusWidget"
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: kind, intent: DashboardProjectConfiguration.self, provider: DashboardProvider<DashboardProjectConfiguration>()) { DashboardWidgetView(entry: $0) }
            .configurationDisplayName("Project Focus").description("A pinned project's linked tasks, progress, rating, and next action.").supportedFamilies(dashboardFamilies)
    }
}
struct BringForwardWidget: Widget {
    let kind = "WorkspaceBringForwardWidget"
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: kind, intent: DashboardFocusConfiguration.self, provider: DashboardProvider<DashboardFocusConfiguration>()) { DashboardWidgetView(entry: $0) }
            .configurationDisplayName("Bring Forward").description("Almost done, highest rated, or due for a revisit. Choose what to bring forward.").supportedFamilies(dashboardFamilies)
    }
}
struct ProjectChartsWidget: Widget {
    let kind = "WorkspaceProjectChartsWidget"
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: kind, intent: DashboardChartsConfiguration.self, provider: DashboardProvider<DashboardChartsConfiguration>()) { DashboardWidgetView(entry: $0) }
            .configurationDisplayName("Project Charts").description("Compare linked-task progress or the portfolio's project statuses.").supportedFamilies(dashboardFamilies)
    }
}
struct DashboardTasksWidget: Widget {
    let kind = "WorkspaceTasksWidget"
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: kind, intent: DashboardTasksConfiguration.self, provider: DashboardProvider<DashboardTasksConfiguration>()) { DashboardWidgetView(entry: $0) }
            .configurationDisplayName("Tasks").description("Next, overdue, or in-progress tasks. Complete a task without opening the app.").supportedFamilies(dashboardSummaryFamilies)
    }
}
struct InboxReviewWidget: Widget {
    let kind = "WorkspaceInboxReviewWidget"
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: kind, intent: DashboardReviewConfiguration.self, provider: DashboardProvider<DashboardReviewConfiguration>()) { DashboardWidgetView(entry: $0) }
            .configurationDisplayName("Inbox Review").description("Preview one item, choose a decision, and confirm it here. Offline decisions wait for Mac.").supportedFamilies(dashboardSummaryFamilies)
    }
}
struct CaptureInboxWidget: Widget {
    let kind = "WorkspaceCaptureInboxWidget"
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: kind, intent: DashboardCaptureConfiguration.self, provider: DashboardProvider<DashboardCaptureConfiguration>()) { DashboardWidgetView(entry: $0) }
            .configurationDisplayName("Capture Inbox").description("File a capture to one of three configured destinations after reviewing its destination.").supportedFamilies(dashboardFamilies)
    }
}
struct NeedsAttentionWidget: Widget {
    let kind = "WorkspaceNeedsAttentionWidget"
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: kind, intent: DashboardAttentionConfiguration.self, provider: DashboardProvider<DashboardAttentionConfiguration>()) { DashboardWidgetView(entry: $0) }
            .configurationDisplayName("Needs Attention").description("What needs a decision, why it matters, and where to address it.").supportedFamilies(dashboardSummaryFamilies)
    }
}
private var dashboardFamilies: [WidgetFamily] { [.systemSmall, .systemMedium, .systemLarge, .systemExtraLarge] }
private var dashboardSummaryFamilies: [WidgetFamily] {
    #if os(iOS)
    dashboardFamilies + [.accessoryRectangular]
    #else
    dashboardFamilies
    #endif
}
