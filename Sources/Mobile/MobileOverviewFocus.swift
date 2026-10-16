import SwiftUI
import BetterWorkspaceCore

extension MobileWorkspaceModel {
    var overviewDigest: OverviewDigest? { snapshot.overview }
    var overviewInboxItem: OverviewInboxItem? {
        let candidates = overviewDigest?.reviewItems ?? overviewDigest?.inboxItem.map { [$0] } ?? []
        let pending = Set(planningDrafts.filter { $0.operation == .reviewInbox && planningErrors[$0.id.uuidString] == nil }.compactMap { $0.inboxReview?.item.id })
        if let id = widgetReviewItemID { return candidates.first { $0.id == id && !pending.contains($0.id) } }
        return candidates.first { !pending.contains($0.id) }
    }
    var hasPendingInboxReview: Bool { planningDrafts.contains { $0.operation == .reviewInbox && planningErrors[$0.id.uuidString] == nil } }
    /// The Mac's digest is the candidate set: it already excludes completed work and
    /// carries scores and recorded sessions the phone never receives. Project progress
    /// is recounted here so a task completed offline moves its bar at once. Without a
    /// digest (a Mac that has not published one yet) the phone ranks what it has.
    var overviewFocusItems: [OverviewFocusItem] {
        let tasks = snapshot.workItems.filter { $0.kind == .task }
        let grouped = Dictionary(grouping: tasks, by: { $0.projectPath ?? "" })
        func recounted(_ item: OverviewFocusItem) -> OverviewFocusItem {
            guard item.kind == .projects, let linked = grouped[item.path] else { return item }
            var item = item
            item.completed = linked.filter { $0.status == .completed }.count; item.total = linked.count
            return item
        }
        if let digest = overviewDigest {
            let present = Set(snapshot.entries.map(\.path) + snapshot.ideas.map(\.path) + snapshot.workItems.map(\.path))
            let completed = Set(snapshot.workItems.filter { $0.status == .completed }.map(\.id))
            return digest.focusItems.filter { present.contains($0.path) }.map { item in
                var item = recounted(item)
                if item.kind == .projects, let details = snapshot.entries.first(where: { $0.path == item.path })?.projectDetails, details.ratings != nil {
                    item.score = details.currentScore.coverage >= 0.5 ? details.rankingScore : nil
                }
                if item.kind == .ideas, let idea = snapshot.ideas.first(where: { $0.path == item.path }), let planning = idea.planning {
                    item.score = planning.score(preferences: idea.scoringPreferences ?? .init()).projectScore
                }
                if completed.contains(item.id) { item.terminal = true }
                return item
            }
        }
        var result = entries(in: "Projects").filter(\.isDirectory).map { project in
            recounted(OverviewFocusItem(id: project.id, path: project.path, title: project.name, kind: .projects, lastChanged: project.modifiedAt))
        }
        result += snapshot.ideas.map { OverviewFocusItem(id: $0.id, path: $0.path, title: $0.title, kind: .ideas, lastChanged: $0.modifiedAt) }
        var links: [String: [MobileWorkItem]] = [:]
        for task in tasks { for id in Set((task.featureIDs ?? []) + (task.milestoneIDs ?? [])) { links[id, default: []].append(task) } }
        result += snapshot.workItems.filter { $0.kind == .feature || $0.kind == .milestone }.map { work in
            let children = links[work.id] ?? []
            return OverviewFocusItem(id: work.id, path: work.path, title: work.title, kind: work.kind == .feature ? .features : .milestones,
                completed: children.filter { $0.status == .completed }.count, total: children.count,
                terminal: work.status == .completed)
        }
        return result
    }
    func prioritizeInbox(_ item: OverviewInboxItem, priority: Int) {
        _ = savePlanning(MobilePlanningEdit(operation: .reviewInbox, title: item.title,
            inboxReview: OverviewInboxCommand(item: item, action: .prioritize, priority: priority)))
    }
    func reviewInbox(_ item: OverviewInboxItem, action: OverviewInboxCommand.Action, days: Int = 1) {
        let until = action == .snooze ? Calendar.current.date(byAdding: .day, value: days, to: Calendar.current.startOfDay(for: Date())) : nil
        _ = savePlanning(MobilePlanningEdit(operation: .reviewInbox, title: item.title,
            inboxReview: OverviewInboxCommand(item: item, action: action, until: until)))
    }
}

/// Selection pushes onto the Overview stack's own path. A navigationDestination on a
/// Section turned its header into a row inside the card.
struct MobileOverviewFocusSection: View {
    @Environment(MobileWorkspaceModel.self) private var model
    @Binding var path: NavigationPath
    var body: some View {
        Section("Bring forward") {
            OverviewFocusShelf(items: model.overviewFocusItems, defaults: model.overviewDefaults) { item in
                if let work = model.snapshot.workItems.first(where: { $0.id == item.id }) { path.append(work) }
                else if let idea = model.snapshot.ideas.first(where: { $0.path == item.path }) { path.append(idea) }
                else if let project = model.snapshot.entries.first(where: { $0.path == item.path }) { path.append(project) }
            }
        }
    }
}

/// The one To-folder item the Mac picked for the phone: text and links small enough
/// to preview here. A decision is a planning draft like any other edit, so it waits
/// out a relaunch or a dead network and the Mac checks the file is unchanged before
/// moving it. To Organize, Trash, Move and Undo stay on the Mac.
struct MobileOverviewInboxSection: View {
    @Environment(MobileWorkspaceModel.self) private var model
    @Environment(\.openURL) private var openURL
    @State private var preview = false
    @State private var reviewExpanded = false
    @State private var confirm: OverviewInboxCommand.Action?
    var body: some View {
        Section {
            if let item = model.overviewInboxItem {
                VStack(alignment: .leading, spacing: 10) {
                    Text("\(item.category) · \(item.actions.purpose)").font(.caption).foregroundStyle(.secondary)
                    Text(item.title).font(.headline).lineLimit(2)
                        .accessibilityIdentifier("overview.toReview.title")
                    Button { reviewExpanded.toggle() } label: {
                        Label("Inbox Review", systemImage: reviewExpanded ? "chevron.down" : "chevron.right")
                    }.buttonStyle(.borderless).accessibilityIdentifier("overview.toReview.expand")
                    if reviewExpanded {
                        VStack(alignment: .leading, spacing: 8) {
                            if item.preview.isEmpty { Text("No cached text preview. Open this item on the Mac.").foregroundStyle(.secondary) }
                            else { MarkdownView(text: item.preview).textSelection(.enabled) }
                            Text("Cached from the Mac. File and embedded web previews are available there; decisions here wait for the Mac's file check.")
                                .font(.caption).foregroundStyle(.secondary)
                        }.accessibilityElement(children: .contain).accessibilityIdentifier("overview.toReview.preview")
                    }
                    ViewThatFits(in: .horizontal) {
                        HStack { primaryActions(item) }
                        VStack(alignment: .leading, spacing: 10) { primaryActions(item) }
                    }
                    HStack(spacing: 16) {
                        Button("Preview") { preview = true }
                        if let link = item.link, ["http", "https"].contains(link.scheme?.lowercased() ?? "") {
                            Button("Open link") { openURL(link) }
                        }
                        Spacer(minLength: 0)
                        Menu("More") {
                            Menu("Priority \(item.priority ?? 3)") {
                                ForEach(1...5, id: \.self) { value in Button("\(value) · \(value == 5 ? "Highest" : value == 1 ? "Lowest" : "Priority")") { model.prioritizeInbox(item, priority: value) } }
                            }
                            Button("Snooze three days") { model.reviewInbox(item, action: .snooze, days: 3) }
                            Button("Snooze one month") { model.reviewInbox(item, action: .snooze, days: 30) }
                            Button("Snooze one week") { model.reviewInbox(item, action: .snooze, days: 7) }
                            Button("Archive…") { confirm = .archive }
                            Button("\(item.actions.retireTitle)…") { confirm = .retire }
                        }
                        .accessibilityIdentifier("overview.toReview.more")
                    }
                    .buttonStyle(.borderless)
                }
                .padding(.vertical, 4)
                .confirmationDialog(confirmTitle(item), isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } }),
                                    titleVisibility: .visible) {
                    if let action = confirm {
                        Button(destination(action)) { model.reviewInbox(item, action: action) }
                    }
                } message: { Text("The Mac checks that the file has not changed before moving it, and can undo the move.") }
                .sheet(isPresented: $preview) {
                    NavigationStack {
                        ScrollView {
                            Text(item.preview.isEmpty ? "No text preview. Open this item on the Mac." : item.preview)
                                .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding()
                        }
                        .navigationTitle(item.title).navigationBarTitleDisplayMode(.inline)
                        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { preview = false } } }
                    }
                }
            } else {
                Text(emptyMessage).font(.subheadline).foregroundStyle(.secondary)
                    .accessibilityIdentifier("overview.toReview.empty")
            }
        } header: {
            // Identified here, not on the Section: a Section's identifier is stamped on
            // every row inside it and hides the card's own controls.
            Text("One thing to review").accessibilityIdentifier("overview.toReview")
        } footer: {
            if model.overviewInboxItem != nil {
                Text("Decisions apply when the Mac next syncs. Move, Trash and Undo are on the Mac.")
            }
        }.onAppear { reviewExpanded = model.overviewDefaults.bool(forKey: "mobileInboxReviewExpanded") }
            .onChange(of: reviewExpanded) { _, value in model.overviewDefaults.set(value, forKey: "mobileInboxReviewExpanded") }
    }

    private var emptyMessage: String {
        if model.hasPendingInboxReview { return "Decision saved on this phone. The Mac sends the next item after applying it." }
        if model.overviewDigest?.inboxCheckedAt == nil { return "Items from your To folders appear here once the Mac has checked them." }
        return "Nothing is due that can be reviewed here. Files and To Organize items wait on the Mac."
    }

    private func confirmTitle(_ item: OverviewInboxItem) -> String {
        switch confirm {
        case .done: return "\(item.decision.replacingOccurrences(of: "?", with: "")) — move “\(item.title)” to Reviewed?"
        case .retire: return "\(item.actions.retireTitle) — move “\(item.title)” to Reviewed?"
        default: return "Archive “\(item.title)”?"
        }
    }

    private func destination(_ action: OverviewInboxCommand.Action) -> String {
        switch action {
        case .done: return "Move to Reviewed/Done"
        case .retire: return "Move to Reviewed/Retired"
        default: return "Move to Reviewed/Archive"
        }
    }

    @ViewBuilder private func primaryActions(_ item: OverviewInboxItem) -> some View {
        Button(item.decision) { confirm = .done }.buttonStyle(.borderedProminent)
            .accessibilityIdentifier("overview.toReview.primary")
        Button("Deal with later") { model.reviewInbox(item, action: .snooze) }.buttonStyle(.bordered)
            .accessibilityIdentifier("overview.toReview.later")
    }
}
