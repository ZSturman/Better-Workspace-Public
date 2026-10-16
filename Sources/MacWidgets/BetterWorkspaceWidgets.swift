// Moved from Workspace Watcher's widget extension (macOS/Workspace Watcher Widgets at
// a835dc6) when Better Workspace absorbed the background service. Unchanged apart from
// the URL scheme (betterworkspace://, handled by AppModel.openDeepLink), the widget
// kinds, and wording that named the old app.
import AppIntents
import SwiftUI
import WidgetKit
import BetterWorkspaceCore

private let refreshInterval: TimeInterval = 15 * 60

struct WorkspaceWidgetEntry: TimelineEntry {
    let date: Date
    let snapshot: WorkspaceWidgetSnapshot?
}

struct SnapshotProvider: TimelineProvider {
    func placeholder(in context: Context) -> WorkspaceWidgetEntry { WorkspaceWidgetEntry(date: .now, snapshot: nil) }
    func getSnapshot(in context: Context, completion: @escaping (WorkspaceWidgetEntry) -> Void) { Task { completion(await current()) } }
    func getTimeline(in context: Context, completion: @escaping (Timeline<WorkspaceWidgetEntry>) -> Void) {
        Task { completion(Timeline(entries: [await current()], policy: .after(.now.addingTimeInterval(refreshInterval)))) }
    }
    private func current() async -> WorkspaceWidgetEntry { WorkspaceWidgetEntry(date: .now, snapshot: await WorkspaceWidgetStore.load()) }
}

struct ConfiguredEntry<Configuration: WidgetConfigurationIntent>: TimelineEntry {
    let date: Date
    let configuration: Configuration
    let snapshot: WorkspaceWidgetSnapshot?
}

struct ConfiguredProvider<Configuration: WidgetConfigurationIntent>: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> ConfiguredEntry<Configuration> { ConfiguredEntry(date: .now, configuration: Configuration(), snapshot: nil) }
    func snapshot(for configuration: Configuration, in context: Context) async -> ConfiguredEntry<Configuration> { await current(configuration) }
    func timeline(for configuration: Configuration, in context: Context) async -> Timeline<ConfiguredEntry<Configuration>> {
        Timeline(entries: [await current(configuration)], policy: .after(.now.addingTimeInterval(refreshInterval)))
    }
    private func current(_ configuration: Configuration) async -> ConfiguredEntry<Configuration> { ConfiguredEntry(date: .now, configuration: configuration, snapshot: configuration is ProjectFocusConfiguration && WidgetDashboardRuntime.load() != nil ? nil : await WorkspaceWidgetStore.load()) }
}

@main
struct BetterWorkspaceWidgets: WidgetBundle {
    var body: some Widget {
        WorkNextWidget()
        CurrentSessionWidget()
        IntentInboxWidget()
        ResurfacerWidget()
        ProjectFocusWidget()
        RecentActivityWidget()
        WorkspacePulseWidget()
        TodayWorkWidget()
        WorkspaceHealthWidget()
        QuickCaptureWidget()
        BringForwardWidget()
        ProjectChartsWidget()
        DashboardTasksWidget()
        InboxReviewWidget()
        CaptureInboxWidget()
        NeedsAttentionWidget()
        if #available(macOS 26.0, *) {
            NewCaptureControl()
            NewIdeaControl()
        }
    }
}

// MARK: - Menu bar and Control Center

/// Ingest that is there even when Better Workspace is not running: add it to the menu
/// bar or Control Center (System Settings → Control Center, or Edit Controls). A tap
/// launches the app if needed and opens the quick-capture panel, exactly like the
/// app's own menu bar item, which exists only while the app runs.
@available(macOS 26.0, *)
struct NewCaptureControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.zacharysturman.BetterWorkspace.Mac.NewCapture") {
            ControlWidgetButton(action: OpenCaptureIntent(asIdea: false)) {
                Label("Ingest", systemImage: "tray.and.arrow.down")
            }
        }
        .displayName("Better Workspace Ingest")
        .description("Opens the quick-capture panel, launching Better Workspace if it is not running.")
    }
}

@available(macOS 26.0, *)
struct NewIdeaControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.zacharysturman.BetterWorkspace.Mac.NewIdea") {
            ControlWidgetButton(action: OpenCaptureIntent(asIdea: true)) {
                Label("New Idea", systemImage: "lightbulb")
            }
        }
        .displayName("New Idea")
        .description("Opens the quick-capture panel ready to record an idea.")
    }
}

// MARK: - Quick Capture

/// Opens the quick-capture panel (`betterworkspace://capture`) — the same panel as the
/// menu bar and ⌥⌘Space — from the desktop or Notification Center.
struct QuickCaptureWidget: Widget {
    let kind = "com.zacharysturman.betterworkspace.quick-capture"
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: QuickCaptureProvider()) { _ in QuickCaptureWidgetView() }
            .configurationDisplayName("Quick Capture")
            .description("Capture a thought or an idea into Better Workspace in one click.")
            .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct QuickCaptureEntry: TimelineEntry { let date: Date }

struct QuickCaptureProvider: TimelineProvider {
    func placeholder(in context: Context) -> QuickCaptureEntry { QuickCaptureEntry(date: .now) }
    func getSnapshot(in context: Context, completion: @escaping (QuickCaptureEntry) -> Void) { completion(QuickCaptureEntry(date: .now)) }
    func getTimeline(in context: Context, completion: @escaping (Timeline<QuickCaptureEntry>) -> Void) {
        completion(Timeline(entries: [QuickCaptureEntry(date: .now)], policy: .never))
    }
}

struct QuickCaptureWidgetView: View {
    @Environment(\.widgetFamily) private var family
    private let capture = URL(string: "betterworkspace://capture")!
    private let idea = URL(string: "betterworkspace://capture?kind=idea")!

    var body: some View {
        Group {
            if family == .systemMedium {
                HStack(spacing: 10) {
                    Link(destination: capture) { button("Capture", "square.and.pencil") }
                    Link(destination: idea) { button("New Idea", "lightbulb") }
                }
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Image(systemName: "square.and.pencil").font(.system(size: 28, weight: .semibold))
                    Spacer(minLength: 0)
                    Text("Capture").font(.title3.weight(.bold))
                    Text("⌥⌘Space anywhere").font(.caption).opacity(0.8)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .widgetURL(capture)
            }
        }
        .foregroundStyle(.white)
        .containerBackground(for: .widget) {
            LinearGradient(colors: [Color(red: 0.16, green: 0.42, blue: 0.95), Color(red: 0.36, green: 0.27, blue: 0.86)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }

    private func button(_ title: String, _ symbol: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: symbol).font(.title2.weight(.semibold))
            Text(title).font(.subheadline.weight(.semibold))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.white.opacity(0.18), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

// MARK: - Widget definitions

struct WorkNextWidget: Widget {
    let kind = "com.zacharysturman.betterworkspace.work-next"
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: kind, intent: WorkNextConfiguration.self, provider: ConfiguredProvider<WorkNextConfiguration>()) { entry in
            WorkNextView(snapshot: entry.snapshot, count: entry.configuration.count.value, tag: entry.configuration.tag)
        }
        .configurationDisplayName("Pick Up Where You Left Off")
        // Deliberately not "your ranked queue": there is no single project
        // score in this system, and the ratings a real recommendation would
        // need are unknown for the whole portfolio. Recency is measured, so
        // recency is what this promises.
        .description("The projects you worked on most recently, and the next thing waiting in each.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .systemExtraLarge])
    }
}

struct CurrentSessionWidget: Widget {
    let kind = "com.zacharysturman.betterworkspace.current-session"
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: SnapshotProvider()) { SessionView(snapshot: $0.snapshot) }
            .configurationDisplayName("Current Work Session")
            .description("What you are working on right now, automatically tracked.")
            .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct IntentInboxWidget: Widget {
    let kind = "com.zacharysturman.betterworkspace.intent-inbox"
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: kind, intent: IntentInboxConfiguration.self, provider: ConfiguredProvider<IntentInboxConfiguration>()) { entry in
            IntentInboxView(snapshot: entry.snapshot, intentID: entry.configuration.intent?.id, count: entry.configuration.count.value)
        }
        .configurationDisplayName("Intent Inbox")
        .description("A configurable view of an intent folder such as To Fix or To Review.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .systemExtraLarge])
    }
}

struct ResurfacerWidget: Widget {
    let kind = "com.zacharysturman.betterworkspace.resurfacer"
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: SnapshotProvider()) { ResurfacerView(snapshot: $0.snapshot) }
            .configurationDisplayName("Resurfacer")
            .description("A real item the background service chose to bring back.")
            .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct ProjectFocusWidget: Widget {
    let kind = "com.zacharysturman.betterworkspace.project-focus"
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: kind, intent: ProjectFocusConfiguration.self, provider: ConfiguredProvider<ProjectFocusConfiguration>()) { entry in
            if WidgetDashboardRuntime.load() != nil {
                DashboardWidgetView(entry: .load(options: DashboardOptions(mode: .project, projectID: entry.configuration.project?.id)))
            } else { ProjectFocusView(snapshot: entry.snapshot, projectID: entry.configuration.project?.id) }
        }
        .configurationDisplayName("Project Focus")
        .description("Keep one project visible: when you last worked on it, what is next, and how it is filed.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .systemExtraLarge])
    }
}

struct RecentActivityWidget: Widget {
    let kind = "com.zacharysturman.betterworkspace.recent-activity"
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: kind, intent: ActivityConfiguration.self, provider: ConfiguredProvider<ActivityConfiguration>()) { entry in
            RecentActivityView(snapshot: entry.snapshot, scope: entry.configuration.scope)
        }
        .configurationDisplayName("Recent Activity")
        .description("A curated timeline of meaningful workspace changes.")
        .supportedFamilies([.systemMedium, .systemLarge, .systemExtraLarge])
    }
}

struct WorkspacePulseWidget: Widget {
    let kind = "com.zacharysturman.betterworkspace.workspace-pulse"
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: SnapshotProvider()) { PulseView(snapshot: $0.snapshot) }
            .configurationDisplayName("Portfolio Pulse")
            .description("How big the portfolio is, how much of it saw work this week, and how much is still unfiled.")
            .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .systemExtraLarge])
    }
}

struct TodayWorkWidget: Widget {
    let kind = "com.zacharysturman.betterworkspace.today-work"
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: SnapshotProvider()) { TodayView(snapshot: $0.snapshot) }
            .configurationDisplayName("Today's Work")
            .description("Actual completed session evidence for today.")
            .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct WorkspaceHealthWidget: Widget {
    let kind = "com.zacharysturman.betterworkspace.workspace-health"
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: SnapshotProvider()) { HealthView(snapshot: $0.snapshot) }
            .configurationDisplayName("Workspace Health")
            .description("Actionable watcher and integration problems only.")
            .supportedFamilies([.systemSmall, .systemMedium])
    }
}

// MARK: - Views

private struct WidgetShell<Content: View>: View {
    let title: String; let symbol: String; @ViewBuilder var content: Content
    init(_ title: String, symbol: String, @ViewBuilder content: () -> Content) { self.title = title; self.symbol = symbol; self.content = content() }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: symbol).font(.caption).foregroundStyle(.secondary).widgetAccentable()
            content
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).containerBackground(for: .widget) { Color.clear }
    }
}

private struct WidgetUnavailable: View {
    var body: some View { ContentUnavailableView("Waiting for the background service", systemImage: "eye.slash", description: Text("Better Workspace starts it at login; open Settings → Background service if it is not running.")) }
}

private struct WorkNextView: View {
    @Environment(\.widgetFamily) private var family
    let snapshot: WorkspaceWidgetSnapshot?; let count: Int; let tag: String?
    var projects: [WidgetProject] { guard let snapshot else { return [] }; return snapshot.projects.filter { project in tag.map { requested in project.tags.contains { tag in tag.display.caseInsensitiveCompare(requested) == .orderedSame } } ?? true }.prefix(count).map { $0 } }
    var body: some View {
        WidgetShell("Pick up where you left off", symbol: "arrow.uturn.backward") {
            if snapshot == nil { WidgetUnavailable() } else if let project = projects.first {
                // Every row carries its next action. Showing it only for the
                // first row left a medium widget half empty while the rows
                // below it said nothing but a name and a date.
                if family == .systemSmall { projectRow(project, detail: true) } else { ForEach(projects) { projectRow($0, detail: true) } }
            } else { ContentUnavailableView("No recent work", systemImage: "checkmark.circle", description: Text("Projects appear here once the background service has observed real file activity in them.")) }
        }.widgetURL(projects.first.flatMap(projectURL))
    }
    @ViewBuilder private func projectRow(_ project: WidgetProject, detail: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                if project.hasActiveSession { Circle().fill(.green).frame(width: 6, height: 6) }
                Text(project.name).font(.headline).lineLimit(1)
                Spacer()
                // Days since real activity, not a score: the score was a
                // blend this system deliberately does not treat as canonical.
                Text(project.recencyLabel).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            if detail && !project.nextAction.isEmpty {
                Text(project.nextAction).font(.caption).foregroundStyle(.secondary).lineLimit(family == .systemSmall ? 3 : 1)
            }
            if family != .systemSmall && project.openGoalsCount > 0 { Text("\(project.openGoalsCount) open goal\(project.openGoalsCount == 1 ? "" : "s")").font(.caption2).foregroundStyle(.secondary) }
        }
    }
}

private struct SessionView: View {
    @Environment(\.widgetFamily) private var family
    let snapshot: WorkspaceWidgetSnapshot?
    var body: some View {
        WidgetShell("Current session", symbol: "timer") {
            if let session = snapshot?.session {
                if session.active, let project = session.project, let info = session.session {
                    Text(project.name).font(.headline).lineLimit(2)
                    Text(info.startedAt, style: .timer).font(.title2.monospacedDigit()).foregroundStyle(.secondary)
                    if let done = session.goalsCompleted, let total = session.goalsTotal, total > 0 { Text("Goals \(done)/\(total)").font(.caption).foregroundStyle(.secondary) }
                    if family != .systemSmall { ForEach(session.goals.filter { $0.completed == 0 }.prefix(2)) { goal in Button(intent: CompleteGoalIntent(goalID: goal.id)) { Label(goal.text, systemImage: "circle") }.buttonStyle(.plain).lineLimit(1) } }
                } else { ContentUnavailableView("No active session", systemImage: "moon.zzz", description: Text("Open the suggested project to begin from real workspace activity.")) }
            } else { WidgetUnavailable() }
        }.widgetURL(snapshot?.session.project.flatMap { projectURL(id: $0.id) })
    }
}

private struct IntentInboxView: View {
    @Environment(\.widgetFamily) private var family
    let snapshot: WorkspaceWidgetSnapshot?; let intentID: String?; let count: Int
    var selected: WidgetIntentFolder? { guard let snapshot else { return nil }; return intentID.flatMap { id in snapshot.intents.first { $0.id == id } } ?? snapshot.intents.first }
    var body: some View {
        WidgetShell(selected?.name ?? "Intent Inbox", symbol: "tray.full") {
            if snapshot == nil { WidgetUnavailable() } else if let folder = selected {
                Text("\(folder.count) needing attention").font(family == .systemSmall ? .title2 : .caption).foregroundStyle(.secondary)
                if family != .systemSmall { ForEach(folder.items.prefix(count)) { item in Text(item.title).font(.subheadline).lineLimit(1) } } else if let item = folder.items.first { Text(item.title).font(.caption).lineLimit(3) }
            } else { ContentUnavailableView("No intent folders", systemImage: "tray", description: Text("Declare intent folders in the background service's config.toml.")) }
        }.widgetURL(selected.flatMap { intentURL($0.id) })
    }
}

private struct ResurfacerView: View {
    @Environment(\.widgetFamily) private var family
    let snapshot: WorkspaceWidgetSnapshot?
    var body: some View {
        WidgetShell("Bring this back", symbol: "arrow.clockwise") {
            if let item = snapshot?.resurfaced.first { Text(item.title).font(.headline).lineLimit(family == .systemSmall ? 3 : 2); Text(item.why).font(.caption).foregroundStyle(.secondary).lineLimit(2); if family != .systemSmall { Text("[[\(item.intent)]]").font(.caption2).foregroundStyle(.secondary) } }
            else if snapshot == nil { WidgetUnavailable() }
            else { ContentUnavailableView("Nothing due", systemImage: "checkmark.circle", description: Text("The resurfacer has no eligible item right now.")) }
        }.widgetURL(snapshot?.resurfaced.first.flatMap { itemURL($0.id) })
    }
}

private struct ProjectFocusView: View {
    @Environment(\.widgetFamily) private var family
    let snapshot: WorkspaceWidgetSnapshot?; let projectID: String?
    var project: WidgetProject? { guard let snapshot else { return nil }; return projectID.map { id in snapshot.projects.first { $0.id == id } } ?? snapshot.projects.first }
    var body: some View {
        WidgetShell("Project focus", symbol: "scope") {
            if let project {
                Text(project.name).font(.headline).lineLimit(2)
                HStack {
                    Text(project.daysSinceLastSession == nil ? "Not started" : "Worked \(project.recencyLabel == "today" ? "today" : "\(project.recencyLabel) ago")")
                    Spacer()
                    if project.hasActiveSession { Text("Active now").foregroundStyle(.green) }
                    else if project.isCurrent { Text("Current").foregroundStyle(.green) }
                }.font(.caption).foregroundStyle(.secondary)
                Text(project.nextAction).font(.caption).lineLimit(family == .systemSmall ? 3 : 2)
                if family != .systemSmall {
                    let facets = [project.domain, project.statusLabel].compactMap { $0 } + project.tags.map(\.display)
                    if !facets.isEmpty { Text(facets.joined(separator: " · ")).font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
                }
            }
            else if snapshot == nil { WidgetUnavailable() } else { ContentUnavailableView("Choose a project", systemImage: "scope", description: Text("Edit this widget to pin a project.")) }
        }.widgetURL(project.flatMap(projectURL))
    }
}

private struct RecentActivityView: View {
    let snapshot: WorkspaceWidgetSnapshot?; let scope: ActivityScope
    var events: [WidgetActivity] { (snapshot?.activity ?? []).filter { event in switch scope { case .meaningful: true; case .sessions: event.type.contains("session"); case .projects: event.type.contains("project") } } }
    var body: some View {
        WidgetShell("Recent activity", symbol: "clock.arrow.circlepath") {
            if snapshot == nil { WidgetUnavailable() } else if events.isEmpty { ContentUnavailableView("No recent activity", systemImage: "clock", description: Text("Meaningful changes will appear here.")) } else { ForEach(events.prefix(4)) { event in HStack(alignment: .firstTextBaseline) { Text(event.summary).font(.caption).lineLimit(1); Spacer(); Text(event.at, style: .relative).font(.caption2).foregroundStyle(.secondary) } } }
        }.widgetURL(URL(string: "betterworkspace://activity"))
    }
}

private struct PulseView: View {
    @Environment(\.widgetFamily) private var family
    let snapshot: WorkspaceWidgetSnapshot?
    var body: some View {
        WidgetShell("Portfolio pulse", symbol: "waveform.path.ecg") {
            if let snapshot {
                HStack(spacing: 4) {
                    // "Worked this week" and "unfiled" are the two questions
                    // this portfolio can actually answer. `Attention` stayed
                    // at zero because it needs goals nothing has set.
                    //
                    // A small widget fits two of these, not three: at three
                    // columns "Projects" was too wide for its share and
                    // SwiftUI broke it mid-word, rendering "Project s".
                    metric(family == .systemSmall ? "Total" : "Projects", snapshot.counts.projects)
                    if let active = snapshot.counts.active7d { metric("Worked", active) }
                    if family != .systemSmall, let unfiled = snapshot.counts.unfiledProjects { metric("Unfiled", unfiled) }
                }
                if snapshot.session.active, let project = snapshot.session.project {
                    Label(project.name, systemImage: "circle.fill").font(.caption).foregroundStyle(.green).lineLimit(1)
                } else if snapshot.today.sessionCount > 0 {
                    Text("\(snapshot.today.sessionCount) session\(snapshot.today.sessionCount == 1 ? "" : "s") today · \(duration(snapshot.today.activeSeconds))")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                } else {
                    Text("No sessions yet today").font(.caption).foregroundStyle(.secondary)
                }
            }
            else { WidgetUnavailable() }
        }.widgetURL(URL(string: "betterworkspace://overview"))
    }
    /// `lineLimit(1)` plus a scale factor so a label that does not fit shrinks
    /// rather than breaking mid-word, which is what turned "Projects" into
    /// "Project s" on the desktop.
    private func metric(_ label: String, _ value: Int) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("\(value)").font(.title3.monospacedDigit()).lineLimit(1).minimumScaleFactor(0.6)
            Text(label).font(.caption2).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct TodayView: View {
    let snapshot: WorkspaceWidgetSnapshot?
    var body: some View {
        WidgetShell("Today's work", symbol: "calendar") {
            if let today = snapshot?.today { HStack { VStack(alignment: .leading) { Text("\(today.sessionCount)").font(.title2); Text("sessions").font(.caption2).foregroundStyle(.secondary) }; VStack(alignment: .leading) { Text(duration(today.activeSeconds)).font(.title2.monospacedDigit()); Text("active time").font(.caption2).foregroundStyle(.secondary) } }; Text(today.projects.isEmpty ? "No completed sessions yet" : today.projects.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
            else { WidgetUnavailable() }
        }.widgetURL(URL(string: "betterworkspace://today"))
    }
}

private struct HealthView: View {
    let snapshot: WorkspaceWidgetSnapshot?
    var body: some View {
        WidgetShell("Workspace health", symbol: "stethoscope") {
            if let health = snapshot?.health { if health.problems.isEmpty && health.watcherState == "running" { Label("Quietly healthy", systemImage: "checkmark.circle").foregroundStyle(.secondary); Text("No action needed.").font(.caption).foregroundStyle(.secondary) } else { ForEach(health.problems.prefix(3)) { problem in VStack(alignment: .leading, spacing: 2) { Text(problem.component.replacingOccurrences(of: "_", with: " ").capitalized).font(.headline); Text(problem.error ?? problem.state).font(.caption).foregroundStyle(.secondary).lineLimit(2) } } } }
            else { WidgetUnavailable() }
        }.widgetURL(URL(string: "betterworkspace://diagnostics"))
    }
}

private func projectURL(_ project: WidgetProject) -> URL? { projectURL(id: project.id) }
private func projectURL(id: String) -> URL? { URL(string: "betterworkspace://project/\(id)") }
private func intentURL(_ id: String) -> URL? { URL(string: "betterworkspace://intent/\(id)") }
private func itemURL(_ id: String) -> URL? { URL(string: "betterworkspace://item/\(id)") }
private func duration(_ seconds: Double) -> String { let minutes = Int(seconds / 60); return minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m" }

// MARK: - Interactive actions

struct CompleteGoalIntent: AppIntent {
    static var title: LocalizedStringResource = "Complete Workspace Goal"
    @Parameter(title: "Goal ID") var goalID: String
    init() {}
    init(goalID: String) { self.goalID = goalID }
    func perform() async throws -> some IntentResult { try await WidgetAPI.request(path: "goals/\(goalID)", method: "PATCH", body: ["completed": true]); return .result() }
}

private enum WidgetAPI {
    static func request(path: String, method: String, body: [String: Any]) async throws {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:8765/v1/\(path)")!)
        request.httpMethod = method; request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw URLError(.badServerResponse) }
    }
}
