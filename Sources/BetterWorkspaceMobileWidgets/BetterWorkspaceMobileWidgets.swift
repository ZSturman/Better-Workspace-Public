import SwiftUI
import WidgetKit
import AppIntents
import BetterWorkspaceCore

@main
struct BetterWorkspaceMobileWidgetBundle: WidgetBundle {
    var body: some Widget {
        QuickCaptureWidget()
        NextWorkWidget()
        RecentIdeasWidget()
        DashboardProjectWidget()
        BringForwardWidget()
        ProjectChartsWidget()
        DashboardTasksWidget()
        InboxReviewWidget()
        CaptureInboxWidget()
        NeedsAttentionWidget()
        if #available(iOS 18.0, *) {
            NewCaptureControl()
            NewIdeaControl()
        }
    }
}

// MARK: - Quick Capture

/// One tap from the Home Screen or Lock Screen to a focused capture field, plus the
/// one thing worth knowing at a glance: whether anything is still waiting to be filed.
struct QuickCaptureWidget: Widget {
    let kind = WidgetKind.quickCapture

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: CaptureWidgetProvider()) { entry in
            QuickCaptureWidgetView(entry: entry)
        }
        .configurationDisplayName("Quick Capture")
        .description("Capture a thought or an idea in one tap, and see what still needs filing.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular, .accessoryRectangular])
    }
}

private enum CaptureLink {
    static let capture = URL(string: "betterworkspace-mobile://capture")!
    static let idea = URL(string: "betterworkspace-mobile://capture?kind=idea")!
}

private struct CaptureWidgetEntry: TimelineEntry {
    let date: Date
    let snapshot: IngestWidgetSnapshot?
}

private struct CaptureWidgetProvider: TimelineProvider {
    private let store = WidgetSnapshotStore(appGroup: WidgetAppGroup.mobile)

    func placeholder(in context: Context) -> CaptureWidgetEntry {
        CaptureWidgetEntry(date: .now, snapshot: IngestWidgetSnapshot(
            state: .ready, inboxCount: 2,
            newestCapture: IngestWidgetCapture(name: "Article Name.md", modifiedAt: .now, status: "In For Reference"),
            needsFilingCount: 1))
    }

    func getSnapshot(in context: Context, completion: @escaping (CaptureWidgetEntry) -> Void) {
        completion(context.isPreview ? placeholder(in: context) : CaptureWidgetEntry(date: .now, snapshot: store?.ingestSnapshot()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<CaptureWidgetEntry>) -> Void) {
        // The app reloads this kind whenever a capture is saved or the Inbox changes.
        completion(Timeline(entries: [CaptureWidgetEntry(date: .now, snapshot: store?.ingestSnapshot())], policy: .never))
    }
}

private struct QuickCaptureWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: CaptureWidgetEntry

    private var toFile: Int? { entry.snapshot.map { $0.needsFilingCount ?? $0.inboxCount } }

    private var statusLine: String {
        guard let snapshot = entry.snapshot, snapshot.state == .ready else { return "Open to set up" }
        guard let toFile else { return "Ready" }
        return toFile == 0 ? "Inbox clear" : "\(toFile) to file"
    }

    var body: some View {
        switch family {
        case .accessoryCircular:
            ZStack {
                AccessoryWidgetBackground()
                Image(systemName: "square.and.pencil").font(.title2.weight(.semibold))
            }
            .accessibilityLabel("New capture")
            .widgetURL(CaptureLink.capture)
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 2) {
                Label("Capture", systemImage: "square.and.pencil").font(.headline)
                Text(statusLine).font(.caption)
            }
            .widgetURL(CaptureLink.capture)
        case .systemMedium:
            medium
        default:
            small
        }
    }

    private var small: some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: "square.and.pencil")
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(.white)
            Spacer(minLength: 0)
            Text("Capture").font(.title3.weight(.bold)).foregroundStyle(.white)
            Text(statusLine).font(.caption.weight(.medium)).foregroundStyle(.white.opacity(0.85))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .containerBackground(for: .widget) { CaptureWidgetBackground() }
        .widgetURL(CaptureLink.capture)
    }

    private var medium: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Link(destination: CaptureLink.capture) {
                    CaptureWidgetButton(title: "Capture", symbol: "square.and.pencil")
                }
                Link(destination: CaptureLink.idea) {
                    CaptureWidgetButton(title: "New Idea", symbol: "lightbulb")
                }
            }
            HStack(spacing: 6) {
                Image(systemName: (toFile ?? 0) > 0 ? "tray" : "checkmark.circle")
                Text(statusLine).fontWeight(.semibold)
                if let latest = entry.snapshot?.newestCapture {
                    Text("·")
                    Text((latest.name as NSString).deletingPathExtension).lineLimit(1).privacySensitive()
                    if let status = latest.status { Text("— \(status)").lineLimit(1).layoutPriority(-1) }
                }
            }
            .font(.caption)
            .foregroundStyle(.white.opacity(0.9))
        }
        .containerBackground(for: .widget) { CaptureWidgetBackground() }
    }
}

private struct CaptureWidgetButton: View {
    let title: String
    let symbol: String

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: symbol).font(.title2.weight(.semibold))
            Text(title).font(.subheadline.weight(.semibold))
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.white.opacity(0.18), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

private struct CaptureWidgetBackground: View {
    var body: some View {
        LinearGradient(colors: [Color(red: 0.16, green: 0.42, blue: 0.95), Color(red: 0.36, green: 0.27, blue: 0.86)],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

// MARK: - Control Center and the Action Button

@available(iOS 18.0, *)
struct NewCaptureControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.zacharysturman.BetterWorkspace.NewCapture") {
            ControlWidgetButton(action: OpenCaptureIntent(asIdea: false)) {
                Label("New Capture", systemImage: "square.and.pencil")
            }
        }
        .displayName("New Capture")
        .description("Opens Better Workspace ready to capture.")
    }
}

@available(iOS 18.0, *)
struct NewIdeaControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.zacharysturman.BetterWorkspace.NewIdea") {
            ControlWidgetButton(action: OpenCaptureIntent(asIdea: true)) {
                Label("New Idea", systemImage: "lightbulb")
            }
        }
        .displayName("New Idea")
        .description("Opens Better Workspace ready to record an idea.")
    }
}

struct NextWorkWidget: Widget {
    let kind = WidgetKind.nextWork

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: WorkspaceWidgetProvider()) { entry in
            if WidgetDashboardRuntime.load() != nil { DashboardWidgetView(entry: DashboardEntry.load(options: .init(mode: .nextWork))) }
            else { NextWorkWidgetView(entry: entry) }
        }
        .configurationDisplayName("Next Work")
        .description("Your next ready work item, with task completion and checked Undo.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .systemExtraLarge, .accessoryRectangular])
    }
}

struct RecentIdeasWidget: Widget {
    let kind = WidgetKind.recentIdeas

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: WorkspaceWidgetProvider()) { entry in
            RecentIdeasWidgetView(entry: entry)
        }
        .configurationDisplayName("Recent Ideas")
        .description("See the newest ideas published from Better Workspace on your Mac.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

private struct WorkspaceWidgetEntry: TimelineEntry {
    let date: Date
    let snapshot: WorkspaceWidgetSnapshot?
}

private struct WorkspaceWidgetProvider: TimelineProvider {
    private let store = WidgetSnapshotStore(appGroup: WidgetAppGroup.mobile)

    func placeholder(in context: Context) -> WorkspaceWidgetEntry {
        WorkspaceWidgetEntry(
            date: .now,
            snapshot: WorkspaceWidgetSnapshot(
                nextWorkItem: WorkspaceWidgetWorkItem(title: "Review the capture flow", projectName: "Better Workspace", kind: "task",
                                                       stage: "now", priority: "high", dueDate: nil),
                openWorkCount: 4,
                inProgressWorkCount: 1,
                recentIdeas: [WorkspaceWidgetIdea(title: "A simpler daily review", modifiedAt: .now)],
                fetchedAt: .now
            )
        )
    }

    func getSnapshot(in context: Context, completion: @escaping (WorkspaceWidgetEntry) -> Void) {
        completion(currentEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<WorkspaceWidgetEntry>) -> Void) {
        Task {
            await WidgetDashboardRuntime.refresh()
            completion(Timeline(entries: [currentEntry()], policy: .after(.now.addingTimeInterval(900))))
        }
    }

    private func currentEntry() -> WorkspaceWidgetEntry {
        WorkspaceWidgetEntry(date: .now, snapshot: store?.workspaceSnapshot())
    }
}

private struct NextWorkWidgetView: View {
    let entry: WorkspaceWidgetEntry

    var body: some View {
        Group {
            if let snapshot = entry.snapshot, let next = snapshot.nextWorkItem {
                VStack(alignment: .leading, spacing: 7) {
                    Label("Next work", systemImage: "checklist")
                        .font(.caption.weight(.semibold))
                    Text(next.title)
                        .font(.headline)
                        .lineLimit(3)
                        .privacySensitive()
                    if let project = next.projectName, project.isEmpty == false {
                        Text(project)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .privacySensitive()
                    }
                    HStack(spacing: 6) {
                        Text(next.stage.capitalized)
                        Text("·")
                        Text("\(snapshot.openWorkCount) open")
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Label("No open work", systemImage: "checkmark.circle")
                        .font(.headline)
                    Text("Open Better Workspace to refresh your published index.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .containerBackground(.fill.tertiary, for: .widget)
        .widgetURL(URL(string: "betterworkspace-mobile://work"))
    }
}

private struct RecentIdeasWidgetView: View {
    let entry: WorkspaceWidgetEntry

    var body: some View {
        Group {
            if let snapshot = entry.snapshot, snapshot.recentIdeas.isEmpty == false {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Recent ideas", systemImage: "lightbulb")
                        .font(.caption.weight(.semibold))
                    ForEach(Array(snapshot.recentIdeas.enumerated()), id: \.offset) { _, idea in
                        Text(idea.title)
                            .font(.caption.weight(.medium))
                            .lineLimit(1)
                            .privacySensitive()
                    }
                    Spacer(minLength: 0)
                    Text("Updated \(snapshot.fetchedAt, style: .relative)")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Label("No ideas published", systemImage: "lightbulb")
                        .font(.headline)
                    Text("Ideas stay as files on your Mac until its index syncs.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .containerBackground(.fill.tertiary, for: .widget)
        .widgetURL(URL(string: "betterworkspace-mobile://ideas"))
    }
}
