import SwiftUI
import WidgetKit
import BetterWorkspaceCore

@main
struct IngestWidgetBundle: WidgetBundle {
    var body: some Widget {
        IngestInboxWidget()
    }
}

struct IngestInboxWidget: Widget {
    let kind = WidgetKind.ingestInbox

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: IngestInboxProvider()) { entry in
            IngestInboxWidgetView(entry: entry)
        }
        .configurationDisplayName("Ingest Inbox")
        .description("See what is waiting for Better Workspace on your Mac.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

private struct IngestInboxEntry: TimelineEntry {
    let date: Date
    let snapshot: IngestWidgetSnapshot?
}

private struct IngestInboxProvider: TimelineProvider {
    private let store = WidgetSnapshotStore(appGroup: WidgetAppGroup.ingest)

    func placeholder(in context: Context) -> IngestInboxEntry {
        IngestInboxEntry(date: .now,
                         snapshot: IngestWidgetSnapshot(state: .ready, inboxCount: 2,
                                                        newestCapture: IngestWidgetCapture(name: "Project thought.md", modifiedAt: .now)))
    }

    func getSnapshot(in context: Context, completion: @escaping (IngestInboxEntry) -> Void) {
        completion(currentEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<IngestInboxEntry>) -> Void) {
        completion(Timeline(entries: [currentEntry()], policy: .never))
    }

    private func currentEntry() -> IngestInboxEntry {
        IngestInboxEntry(date: .now, snapshot: store?.ingestSnapshot())
    }
}

private struct IngestInboxWidgetView: View {
    let entry: IngestInboxEntry

    var body: some View {
        Group {
            if let snapshot = entry.snapshot {
                if snapshot.state == .needsInbox {
                    Label("Set up your shared Inbox", systemImage: "folder.badge.questionmark")
                        .font(.headline)
                } else if snapshot.inboxCount == 0 {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Inbox zero", systemImage: "checkmark.circle")
                            .font(.headline)
                        Text("Capture anything when it arrives.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("\(snapshot.inboxCount) waiting", systemImage: "tray.full")
                            .font(.headline)
                        if let newest = snapshot.newestCapture {
                            Text(newest.name)
                                .font(.caption.weight(.medium))
                                .lineLimit(2)
                                .privacySensitive()
                            Text(newest.modifiedAt, style: .relative)
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Open Ingest", systemImage: "tray")
                        .font(.headline)
                    Text("Set up capture to see your Inbox here.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .containerBackground(.fill.tertiary, for: .widget)
        .widgetURL(URL(string: "betterworkspace-ingest://capture"))
    }
}
