import SwiftUI
import BetterWorkspaceCore

/// The same service records on Mac, iPhone and iPad. This view cannot edit drafts
/// or send them to Notion; those actions retain their existing service/review path.
struct ProjectWorkHistoryView: View {
    let history: ProjectWorkHistory?

    var body: some View {
        List {
            if let history {
                Section {
                    Text("\(count(history.totalLogs, "work log")) · \(count(history.totalSessions, "recorded session"))")
                    Text("Recent work history from your Mac. Expand a daily log to see its recorded sessions.")
                        .font(.caption).foregroundStyle(.secondary)
                    if history.totalLogs > history.logs.count || history.totalSessions > history.sessions.count {
                        Text("Showing \(count(history.logs.count, "recent work log")) and \(count(history.sessions.count, "recent session")).")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section("Work logs") {
                    if history.logs.isEmpty { Text("No work logs are available for this project.").foregroundStyle(.secondary) }
                    ForEach(history.logs) { log in
                        DisclosureGroup {
                            if let summary = log.summary { Text(summary).textSelection(.enabled) }
                            if let start = log.startedAt { timestamp("Started", start) }
                            if let end = log.endedAt { timestamp("Ended", end) }
                            Text("Active: \(duration(log.activeMinutes * 60)) · Elapsed: \(duration(log.elapsedMinutes * 60))")
                                .font(.caption)
                            if log.isReconstructed { Label("Includes reconstructed session evidence", systemImage: "clock.arrow.circlepath").font(.caption) }
                            if let page = log.notionPageID, let url = URL(string: "https://www.notion.so/" + page.replacingOccurrences(of: "-", with: "")) {
                                Link("Open work log in Notion", destination: url)
                            }
                            let linked = history.sessions(for: log)
                            ForEach(linked) { session in sessionRow(session) }
                            if linked.count < log.sessionCount {
                                Text("\(count(log.sessionCount - linked.count, "session")) outside the available history or without surviving details.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(String(log.dateKey.prefix(10))).font(.headline)
                                Text("\(duration(log.activeMinutes * 60)) active · \(count(log.sessionCount, "session")) · \(logStatus(log.status))")
                                    .font(.caption).foregroundStyle(.secondary)
                                if let summary = log.summary { Text(summary).font(.callout).lineLimit(2) }
                            }
                        }.accessibilityIdentifier("project.history.log." + log.id)
                    }
                }
                Section("Sessions") {
                    if history.sessions.isEmpty { Text("No recorded sessions are available.").foregroundStyle(.secondary) }
                    ForEach(history.sessions) { session in sessionRow(session) }
                }
            } else {
                Section {
                    Text("Work history is not included in this snapshot yet.")
                    Text("Refresh from an updated Mac with the background service enabled. Independent projects can be used without Mac history.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Work logs & sessions")
        .accessibilityIdentifier("project.history")
    }

    private func sessionRow(_ session: WorkSession) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(session.startedAt.formatted(date: .abbreviated, time: .standard)).font(.headline)
            timestamp("Ended", session.endedAt)
            Text("\(duration(session.activeSeconds)) active · \(duration(session.endedAt.timeIntervalSince(session.startedAt))) elapsed")
                .font(.caption).foregroundStyle(.secondary)
            if let subject = session.gitSubject { Text(subject).textSelection(.enabled) }
            if !session.interestingFiles.isEmpty {
                Text(session.interestingFiles.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary)
            }
        }.padding(.vertical, 4)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("project.history.session." + session.id)
    }

    private func count(_ value: Int, _ noun: String) -> String {
        "\(value) \(noun)\(value == 1 ? "" : "s")"
    }

    private func logStatus(_ status: String) -> String {
        switch status {
        case "prepared": "Draft"
        case "synced": "In Notion"
        case "failed", "sync_failed": "Needs attention"
        default: status.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    private func timestamp(_ title: String, _ date: Date) -> some View {
        Text("\(title): \(date.formatted(date: .abbreviated, time: .standard))").font(.caption)
    }

    private func duration(_ seconds: Double) -> String {
        let minutes = Int(max(0, seconds.isFinite ? seconds : 0) / 60)
        return minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m"
    }
}
