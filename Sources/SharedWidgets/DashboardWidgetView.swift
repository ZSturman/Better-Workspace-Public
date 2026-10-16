import SwiftUI
import Charts
import WidgetKit
import BetterWorkspaceCore

struct DashboardWidgetView: View {
    @Environment(\.widgetFamily) private var systemFamily
    let entry: DashboardEntry
    var familyOverride: WidgetFamily? = nil
    private var family: WidgetFamily { familyOverride ?? systemFamily }
    private var options: DashboardOptions { entry.options }
    private var snapshot: WorkspaceDashboardSnapshot? { entry.snapshot }
    private var compact: Bool { family == .systemSmall || accessory }
    private var accessory: Bool {
        #if os(iOS)
        family == .accessoryRectangular
        #else
        false
        #endif
    }
    private var limit: Int { compact ? 1 : family == .systemMedium ? (options.mode == .tasks || options.mode == .focus ? 2 : 3) : family == .systemExtraLarge ? 8 : 5 }
    private var mobile: Bool {
        #if os(iOS)
        true
        #else
        false
        #endif
    }
    private var title: String {
        switch options.mode {
        case .project: return "Project Focus"
        case .focus: return options.focus.title
        case .charts: return options.chart == .progress ? "Project Progress" : "Portfolio Status"
        case .nextWork: return "Next Work"
        case .tasks: return options.queue == .next ? "Next Tasks" : options.queue == .overdue ? "Overdue Tasks" : "In Progress"
        case .review: return "Inbox Review"
        case .captures: return "Capture Inbox"
        case .attention: return "Needs Attention"
        }
    }
    private var symbol: String {
        switch options.mode {
        case .project: "scope"
        case .focus: "arrow.up.forward.circle"
        case .charts: "chart.bar"
        case .tasks, .nextWork: "checklist"
        case .review: "tray.full"
        case .captures: "tray.and.arrow.down"
        case .attention: "exclamationmark.circle"
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: accessory ? 2 : family == .systemMedium ? 4 : 7) {
            Label(title, systemImage: symbol).font(.caption.weight(.semibold)).foregroundStyle(.secondary).widgetAccentable()
            if let snapshot {
                if let confirmation = entry.confirmation, !compact { confirm(confirmation) }
                else {
                    switch options.mode {
                    case .project: project(snapshot)
                    case .focus: focus(snapshot)
                    case .charts: charts(snapshot)
                    case .nextWork:
                        if let item = WorkItemRecommendation.nextMobileAction(in: snapshot.work, allItems: snapshot.work) { taskRow(item) }
                        else { empty("No ready work. Open Needs Attention to address blockers.") }
                    case .tasks: tasks(snapshot)
                    case .review: review(snapshot)
                    case .captures: captures(snapshot)
                    case .attention: attention(snapshot)
                    }
                }
                if !accessory, entry.confirmation == nil {
                    if let error = entry.error { Text(error).font(.caption2).foregroundStyle(.orange).lineLimit(compact ? 2 : 1) }
                    if let record = relevantRecords.last {
                        receipt(record)
                    }
                    Spacer(minLength: 0)
                    if !compact && (family != .systemMedium || options.mode != .review) {
                        let date = options.mode == .captures ? snapshot.captureUpdatedAt ?? snapshot.updatedAt
                            : options.mode == .review ? snapshot.reviewCheckedAt ?? snapshot.updatedAt : snapshot.updatedAt
                        HStack {
                            Text("Updated \(date, style: .relative)").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            Spacer()
                            Button(intent: action("refresh")) { Image(systemName: "arrow.clockwise") }
                                .buttonStyle(.plain).accessibilityLabel("Refresh widget")
                        }
                    }
                }
            } else {
                Text("Open Better Workspace").font(.headline)
                Text("Your workspace will appear after its first successful refresh.").font(.caption).foregroundStyle(.secondary).lineLimit(3)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .containerBackground(.fill.tertiary, for: .widget)
        .widgetURL(defaultRoute.url(mobile: mobile))
        .privacySensitive()
    }
    private var defaultRoute: WidgetRoute {
        switch options.mode {
        case .project: return options.projectID.map(WidgetRoute.project) ?? snapshot?.project(id: nil)?.route ?? .overview
        case .focus: return .overview
        case .charts: return .charts(options.chart.rawValue)
        case .nextWork: return WorkItemRecommendation.nextMobileAction(in: snapshot?.work ?? [], allItems: snapshot?.work ?? []).map { .task($0.id) } ?? .attention("work")
        case .tasks: return snapshot?.tasks(queue: options.queue, projectID: options.projectID).first.map { .task($0.id) } ?? .attention("work")
        case .review: return .review(selectedReview?.id ?? "")
        case .captures: return .capture(selectedCapture?.name ?? "")
        case .attention: return .attention(options.attention.rawValue)
        }
    }
    private var relevantRecords: [WidgetCommandRecord] {
        entry.records.filter { record in
            let recentlyApplied = record.state == .applied && entry.date.timeIntervalSince(record.appliedAt ?? .distantPast) < 600
            guard !record.settled || recentlyApplied else { return false }
            switch options.mode {
            case .review: return record.edit?.operation == .reviewInbox
            case .captures: return record.edit?.operation == .fileCapture
            case .tasks, .nextWork, .project: return record.edit?.operation == .saveWork && record.edit?.work?.kind == .task
            case .attention: return record.state == .rejected
            default: return false
            }
        }
    }
    private func canUndo(_ record: WidgetCommandRecord) -> Bool {
        guard let changed = record.edit?.work, changed.kind == .task, changed.status == .completed else { return false }
        if record.state == .queued { return true }
        guard record.state == .applied, entry.date.timeIntervalSince(record.appliedAt ?? .distantPast) < 600,
              let revision = record.workModifiedAt, let current = snapshot?.work.first(where: { $0.id == changed.id }) else { return false }
        return current.modifiedAt == revision && MobilePlanningFiles.sameWidgetFields(current, changed)
    }
    private func action(_ name: String, target: String = "", token: String = "", destination: String = "") -> DashboardActionIntent {
        DashboardActionIntent(name, target: target, scope: options.scope, token: token, destination: destination)
    }
    private func empty(_ message: String) -> some View { Text(message).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
    private func receipt(_ record: WidgetCommandRecord) -> some View {
        HStack(spacing: 6) {
            Text(record.label).font(.caption2).foregroundStyle(record.state == .rejected ? Color.orange : Color.secondary).lineLimit(2)
            Spacer(minLength: 0)
            if canUndo(record) {
                Button("Undo", intent: action("undo", target: record.id.uuidString)).font(.caption2).buttonStyle(.plain)
            }
            if record.state == .rejected {
                Button("Dismiss", intent: action("dismiss", target: record.id.uuidString)).font(.caption2).buttonStyle(.plain)
            }
        }
    }
    @ViewBuilder private func project(_ snapshot: WorkspaceDashboardSnapshot) -> some View {
        if let project = snapshot.project(id: options.projectID) {
            Link(destination: project.route.url(mobile: mobile)) {
                Text(project.name).font(.headline).lineLimit(family == .systemMedium ? 1 : 2)
            }
            if project.focus.total > 0 {
                ProgressView(value: project.focus.fraction).tint(.green)
                    .accessibilityLabel("Linked tasks").accessibilityValue("\(project.focus.completed) of \(project.focus.total) complete")
                Text("\(project.focus.completed)/\(project.focus.total) linked tasks done").font(.caption)
            } else { empty("No linked tasks yet") }
            if !compact, let next = project.nextTask { taskRow(next, showProject: false) }
            if !compact {
                Text([project.status, project.focus.score.map { "Rated \(Int($0.rounded()))/100" }].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                if let date = project.focus.lastWorked { Text("Worked \(date, style: .relative)").font(.caption2).foregroundStyle(.secondary) }
                else if let date = project.focus.lastChanged { Text("Files changed \(date, style: .relative)").font(.caption2).foregroundStyle(.secondary) }
                else { empty("Activity unknown") }
            }
        } else { empty(options.projectID == nil ? "Choose a project in Edit Widget." : "This pinned project is unavailable. Edit the widget to choose another.") }
    }
    @ViewBuilder private func focus(_ snapshot: WorkspaceDashboardSnapshot) -> some View {
        let items = Array(OverviewRanking.items(snapshot.focusItems, kind: options.content, focus: options.focus).prefix(limit))
        if items.isEmpty { empty("No \(options.content.title.lowercased()) qualify for this focus yet.") }
        else {
            ForEach(items) { item in
                VStack(alignment: .leading, spacing: 3) {
                    Link(destination: route(item).url(mobile: mobile)) { Text(item.title).font(.subheadline.weight(.semibold)).lineLimit(compact ? 2 : 1) }
                    Text(item.reason(options.focus, now: entry.date)).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    if options.display == .chart && !accessory {
                        if options.focus == .almostDone { ProgressView(value: item.fraction).tint(.green) }
                        else if options.focus == .highestRated { ProgressView(value: (item.score ?? 0) / 100).tint(.blue) }
                        else {
                            let days = max(0, entry.date.timeIntervalSince(item.lastWorked ?? item.lastChanged ?? entry.date) / 86400)
                            ProgressView(value: min(days / OverviewFocusItem.revisitHorizonDays, 1)).tint(.orange)
                                .accessibilityLabel("Age on a 90-day track")
                        }
                    }
                }
            }
        }
    }
    private func route(_ item: OverviewFocusItem) -> WidgetRoute {
        switch item.kind {
        case .projects: return .project(snapshot?.projects.first { $0.path == item.path }?.id ?? item.path)
        case .ideas: return .idea(item.path)
        case .features, .milestones: return .task(item.id)
        }
    }
    private struct Bar: Identifiable {
        let id: String; let title: String; let series: String; let count: Int
    }
    @ViewBuilder private func charts(_ snapshot: WorkspaceDashboardSnapshot) -> some View {
        let bars = chartBars(snapshot)
        let firstProject = bars.first.flatMap { bar in snapshot.projects.first { $0.id + ":done" == bar.id } }
        if bars.isEmpty { empty("No recorded data for this chart yet.") }
        else {
            Chart(bars) { bar in
                BarMark(x: .value("Count", bar.count), y: .value("Project", bar.title))
                    .foregroundStyle(by: .value("Status", bar.series)).cornerRadius(2)
            }
            .chartForegroundStyleScale(domain: options.chart == .status ? ["Projects"] : ["Done", "Open"], range: options.chart == .status ? [Color.accentColor] : [Color.green, Color.accentColor])
            .chartLegend(compact || options.chart == .status ? .hidden : .visible)
            .chartXAxis(.hidden)
            .frame(maxHeight: .infinity)
            .accessibilityLabel(options.chart == .status ? "Projects by status" : "Linked-task progress by project")
            if compact, let project = firstProject, options.chart == .progress { Text("\(project.focus.completed)/\(project.focus.total) done").font(.caption) }
        }
    }
    private func chartBars(_ snapshot: WorkspaceDashboardSnapshot) -> [Bar] {
        if options.chart == .status {
            let groups: [String: [DashboardProject]] = Dictionary(grouping: snapshot.projects) { $0.status?.isEmpty == false ? $0.status! : "No status" }
            var bars: [Bar] = []
            for (status, projects) in groups { bars.append(Bar(id: status, title: status, series: "Projects", count: projects.count)) }
            bars.sort { $0.count == $1.count ? $0.title < $1.title : $0.count > $1.count }
            return Array(bars.prefix(limit))
        }
        var projects = snapshot.projects.filter { !$0.focus.terminal && $0.focus.total > 0 }
        projects.sort { $0.focus.remaining == $1.focus.remaining ? $0.id < $1.id : $0.focus.remaining > $1.focus.remaining }
        var bars: [Bar] = []
        for project in projects.prefix(limit) {
            bars.append(Bar(id: project.id + ":done", title: project.name, series: "Done", count: project.focus.completed))
            bars.append(Bar(id: project.id + ":open", title: project.name, series: "Open", count: project.focus.remaining))
        }
        return bars
    }
    @ViewBuilder private func tasks(_ snapshot: WorkspaceDashboardSnapshot) -> some View {
        let items = Array(snapshot.tasks(queue: options.queue, projectID: options.projectID, now: entry.date).prefix(limit))
        if options.projectID != nil && snapshot.project(id: options.projectID) == nil { empty("The selected project is unavailable.") }
        else if items.isEmpty { empty("No tasks in this queue. Blocked work and Later tasks appear in their owning app flows.") }
        else { ForEach(items) { taskRow($0) } }
    }
    private func taskRow(_ item: MobileWorkItem, showProject: Bool = true) -> some View {
        HStack(alignment: .top, spacing: 7) {
            if !accessory && item.kind == .task {
                Button(intent: action("complete", target: item.id, token: String(item.modifiedAt?.timeIntervalSince1970 ?? 0))) {
                    Image(systemName: "circle").font(.title3)
                }.buttonStyle(.plain).accessibilityLabel("Complete \(item.title)")
            }
            VStack(alignment: .leading, spacing: 2) {
                Link(destination: WidgetRoute.task(item.id).url(mobile: mobile)) { Text(item.title).font(.subheadline.weight(.semibold)).lineLimit(accessory ? 2 : compact ? 3 : 1) }
                if showProject, let path = item.projectPath {
                    Text(snapshot?.projects.first { $0.path == path }?.name ?? path.split(separator: "/").last.map(String.init) ?? path).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                if !compact { Text([item.stage.displayName, item.priority.rawValue.capitalized, item.dueDate.map { "Due " + $0.formatted(date: .abbreviated, time: .omitted) }].compactMap { $0 }.joined(separator: " · ")).font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
            }
        }.invalidatableContent()
    }
    private var selectedReview: OverviewInboxItem? {
        let items = snapshot?.reviewItems.filter { options.folder == .all || $0.category == options.folder.rawValue } ?? []
        return items.isEmpty ? nil : items[entry.cursor % items.count]
    }
    @ViewBuilder private func review(_ snapshot: WorkspaceDashboardSnapshot) -> some View {
        if let item = selectedReview {
            Text(item.category).font(.caption2).foregroundStyle(.secondary)
            Text(item.title).font(.headline).lineLimit(compact ? 2 : 1)
            if !accessory { Text(item.preview.isEmpty ? "Open in the app for the full preview." : item.preview).font(.caption).foregroundStyle(.secondary).lineLimit(compact ? 2 : family == .systemMedium ? 1 : 3) }
            if !compact {
                HStack(spacing: 8) {
                    Button(item.decision, intent: action("done", target: item.id, token: item.fingerprint ?? "")).buttonStyle(.borderedProminent)
                    Button("Later", intent: action("snooze", target: item.id, token: item.fingerprint ?? "")).buttonStyle(.bordered)
                    Button("Next", intent: action("next")).buttonStyle(.bordered)
                }.font(.caption)
                if family != .systemMedium {
                    HStack {
                        Button("Archive", intent: action("archive", target: item.id, token: item.fingerprint ?? ""))
                        Button(item.actions.retireTitle, intent: action("retire", target: item.id, token: item.fingerprint ?? ""))
                        Button("Snooze 1 week", intent: action("week", target: item.id, token: item.fingerprint ?? ""))
                    }.font(.caption).buttonStyle(.plain)
                } else {
                    HStack {
                        Button("Archive", intent: action("archive", target: item.id, token: item.fingerprint ?? ""))
                        Button("Retire", intent: action("retire", target: item.id, token: item.fingerprint ?? ""))
                    }.font(.caption2).buttonStyle(.plain)
                }
            }
        } else {
            if snapshot.reviewCheckedAt == nil { empty("Waiting for Mac to check the To folders.") }
            else if relevantRecords.contains(where: { $0.pending }) { empty("Decisions saved. More items arrive after Mac applies them.") }
            else { empty("No eligible items due. To Organize and larger files can be reviewed on Mac.") }
        }
    }
    private var selectedCapture: DashboardCapture? {
        let items = snapshot?.captures ?? []
        return items.isEmpty ? nil : items[entry.cursor % items.count]
    }
    @ViewBuilder private func captures(_ snapshot: WorkspaceDashboardSnapshot) -> some View {
        if let count = snapshot.captureCount { Text("\(count) need filing").font(compact ? .title3 : .caption).foregroundStyle(.secondary) }
        else { empty("Inbox count unavailable") }
        if let capture = selectedCapture {
            Text(capture.name).font(.headline).lineLimit(2)
            if !compact {
                let destinations = options.destinations.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }.filter { selected in snapshot.destinations.contains { $0.path == selected } }
                if destinations.isEmpty { empty("Edit this widget to choose up to three filing destinations.") }
                else {
                    HStack {
                        ForEach(destinations, id: \.self) { destination in
                            Button(destination, intent: action("file", target: capture.name, token: String(capture.modified.timeIntervalSince1970), destination: destination)).lineLimit(1).minimumScaleFactor(0.7)
                        }
                    }.font(.caption).buttonStyle(.bordered)
                }
                HStack {
                    Button("Next capture", intent: action("next")).font(.caption2).buttonStyle(.plain)
                    Spacer()
                    Link("Other destination…", destination: WidgetRoute.capture(capture.name).url(mobile: mobile)).font(.caption2)
                }
            }
        } else { empty(snapshot.captureUpdatedAt == nil ? "Open Ingest to publish its first successful listing." : "No captures waiting here.") }
    }
    @ViewBuilder private func attention(_ snapshot: WorkspaceDashboardSnapshot) -> some View {
        let items = snapshot.attentionItems(now: entry.date)
        let failures = entry.records.filter { $0.state == .rejected && !$0.settled }.map {
            WidgetAttentionItem(id: "receipt:\($0.id)", title: $0.edit?.title ?? "Saved change", reason: $0.message ?? "Mac refused this change", category: .failure,
                route: $0.edit?.work.map { .task($0.id) } ?? $0.edit?.inboxReview.map { .review($0.item.id) }
                    ?? $0.edit?.originalIdea.map { .idea($0.path) }
                    ?? .capture($0.edit?.captureFiling?.capture.name ?? $0.intent.captureName ?? ""))
        }
        let filtered = (failures + items).filter { item in
            switch options.attention {
            case .all: true
            case .work: item.category == .overdue || item.category == .blocked
            case .inbox: item.category == .inbox
            case .projects: item.category == .project
            case .failures: item.category == .failure
            }
        }
        if filtered.isEmpty { empty("No actionable items in this category.") }
        else { ForEach(filtered.prefix(limit)) { item in
            Link(destination: item.route.url(mobile: mobile)) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title).font(.subheadline.weight(.semibold)).lineLimit(compact ? 2 : 1)
                    Text(item.reason).font(.caption2).foregroundStyle(.secondary).lineLimit(compact ? 2 : 1)
                }
            }
        } }
    }
    private func confirm(_ confirmation: WidgetConfirmation) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(confirmation.edit.title).font(.headline).lineLimit(2)
            if let review = confirmation.edit.inboxReview {
                Text(review.item.preview).font(.caption).foregroundStyle(.secondary).lineLimit(family == .systemMedium ? 2 : 6)
                Text(review.action == .done && review.item.path.lowercased().hasSuffix(".bw.md")
                    ? "Complete task in place · " + review.item.path
                    : "Move to Reviewed/\(review.action == .done ? "Done" : review.action == .archive ? "Archive" : "Retired")/\(review.item.category)")
                    .font(.caption.weight(.medium)).lineLimit(2)
            } else if let filing = confirmation.edit.captureFiling {
                Text("File into \(filing.destination)").font(.subheadline)
                Text("Work queues create a work item. Mac checks the capture before filing it.").font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            HStack {
                Button("Confirm", intent: action("confirm", token: confirmation.id.uuidString)).buttonStyle(.borderedProminent)
                Button("Cancel", intent: action("cancel")).buttonStyle(.bordered)
            }.font(.caption)
            if let error = entry.error { Text(error).font(.caption2).foregroundStyle(.orange).lineLimit(2) }
        }
    }
}
