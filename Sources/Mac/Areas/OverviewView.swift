import SwiftUI
import BetterWorkspaceCore

/// What deserves attention, and what to do next.
///
/// Projects is where you browse — group, sort, filter, inspect. Overview is where you
/// decide, and the two must not become the same screen. So: no table, no columns,
/// every list capped, and each row is a *reason* rather than a row of metadata.
/// Clicking anything hands off to the place that owns it.
///
/// Single column at every width. The sections are already narrow, and two cards side
/// by side is the first step toward a dashboard.
struct OverviewView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @AppStorage("overview.layout.mac", store: TestIsolation.defaults) private var layoutValue = ""
    @State private var showsCustomization = false
    @State private var showsWelcome = false
    private let supportedSections: [OverviewSectionID] = [.resume, .nextAction, .attention, .focus, .review, .activity, .health]
    private var visibleSections: [OverviewSectionID] {
        var sections = OverviewLayout.load(layoutValue, defaultOrder: supportedSections).visible(in: supportedSections)
        if model.widgetOverviewSection == "widget-attention", !sections.contains(.attention) { sections.append(.attention) }
        if model.widgetOverviewSection == "widget-review", !sections.contains(.review) { sections.append(.review) }
        return sections
    }

    /// Below this height the lists shorten rather than the layout changing.
    private static let compactHeight: CGFloat = 700

    var body: some View {
        GeometryReader { geometry in
            let compact = geometry.size.height < Self.compactHeight
            ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.loose) {
                    ForEach(visibleSections) { section in
                        switch section {
                        case .resume: resume
                        case .nextAction: nextAction
                        case .attention: attention(limit: compact ? 3 : 4).id("widget-attention")
                        case .focus:
                            OverviewSection(title: "Bring forward") {
                                OverviewFocusShelf(items: model.overviewFocusItems, defaults: TestIsolation.defaults, onSelect: model.revealOverviewFocus)
                            }
                        case .review:
                            if let controller = model.overviewInbox {
                                OverviewSection(title: "One thing to review") { OverviewInboxView(controller: controller) }.id("widget-review")
                            }
                        case .activity: recentActivity(limit: compact ? 3 : 5)
                        case .health: health
                        default: EmptyView()
                        }
                    }
                    if visibleSections.isEmpty {
                        ContentUnavailableView("Make Overview your own", systemImage: "slider.horizontal.3", description: Text("Choose a few sections with Customize Overview."))
                    }
                }
                .padding(.horizontal, Theme.Space.base)
                .padding(.bottom, Theme.Space.section)
            }
            .accessibilityIdentifier("overview.scroll")
            .onChange(of: model.widgetOverviewSection) { _, id in if let id { proxy.scrollTo(id, anchor: .top) } }
            .task { if let id = model.widgetOverviewSection { proxy.scrollTo(id, anchor: .top) } }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                VStack(spacing: 0) {
                    HStack {
                        AreaHeader(title: "Overview", subtitle: nil, symbol: "rectangle.3.group")
                        Menu {
                            Button("Customize Overview", systemImage: "slider.horizontal.3") { showsCustomization = true }
                            Button("Welcome & capabilities", systemImage: "questionmark.circle") { showsWelcome = true }
                        } label: { Image(systemName: "slider.horizontal.3") }
                        .accessibilityLabel("Overview options")
                        .accessibilityIdentifier("overview.options")
                        .padding(.trailing, Theme.Space.base)
                    }
                    Divider()
                }
                .background(.regularMaterial)
            }
        }
        .sheet(isPresented: $showsCustomization) { OverviewCustomizationView(encoded: $layoutValue, supported: supportedSections) }
        .sheet(isPresented: $showsWelcome) {
            WorkspaceWelcomeView(platform: .advancedMac, startPersonal: {
                showsWelcome = false
            }, connect: { showsWelcome = false }, exploreSample: nil)
        }
        .task { @MainActor in model.prepareOverviewInbox() }
    }

    // MARK: - Resume

    @ViewBuilder
    private var resume: some View {
        if let point = model.resumePoint {
            VStack(alignment: .leading, spacing: Theme.Space.tight) {
                Label("Pick up where you left off", systemImage: "arrow.uturn.left.circle.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.tint)

                Text(point.projectName)
                    .font(.system(size: 19, weight: .semibold))
                    .lineLimit(1)

                Text(resumeDetail(point))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                if let subject = point.gitSubject, subject.isEmpty == false {
                    Label(subject, systemImage: "arrow.triangle.branch")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }

                HStack(spacing: Theme.Space.tight) {
                    if let path = point.projectPath {
                        Button("Open") { model.open(URL(fileURLWithPath: path)) }
                            .buttonStyle(.borderedProminent)
                        Button("Reveal") { model.revealInFinder(URL(fileURLWithPath: path)) }
                        Button("Go to project") { model.reveal(projectPath: path) }
                    }
                    Spacer()
                }
                .padding(.top, 2)
            }
            .padding(Theme.Space.base)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: Theme.Radius.panel))
            .accessibilityIdentifier("overview.resume")
        } else if model.isAwaitingInitialRefresh {
            OverviewSection(title: "Pick up where you left off") {
                LoadingLabel(text: "Loading projects, work and recent activity…")
            }
        }
    }

    private func resumeDetail(_ point: Attention.ResumePoint) -> String {
        var parts = [Format.relativeDate(point.at)]
        if let hours = point.activeHours {
            parts.append(hours < 1
                         ? "\(Int((hours * 60).rounded())) active minutes"
                         : String(format: "%.1f active hours", hours))
        }
        if point.files.isEmpty == false {
            parts.append("last touched " + point.files.prefix(3).joined(separator: ", "))
        }
        if point.evidence == .filesystem {
            // Say which claim is being made. A changed file is not the same as
            // observed work — a sync or another tool moves a timestamp too.
            parts.append("from file changes")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - Next action

    @ViewBuilder
    private var nextAction: some View {
        if let action = model.overviewNextAction {
            OverviewSection(title: "Next action") {
                Button { model.reveal(workItem: action.item) } label: {
                    HStack(alignment: .center, spacing: Theme.Space.base) {
                        Image(systemName: action.item.kind.symbolName)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.tint)
                            .frame(width: 22)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(action.item.title)
                                .font(.system(size: 14, weight: .semibold))
                                .lineLimit(1)
                            Text(nextActionDetail(action))
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: Theme.Space.tight)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(Theme.Space.base)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: Theme.Radius.panel))
                .help("Higher-scored projects come first. Within a project, designated next work, stage and priority decide. Blocked, completed and Later work are excluded.")
                .accessibilityIdentifier("overview.nextAction.\(action.item.id)")
            }
        }
    }

    /// Where it is from and when it is planned for; why this one only when it is not
    /// simply the top of the list.
    private func nextActionDetail(_ action: AppModel.OverviewNextAction) -> String {
        let item = action.item
        return [action.project.displayTitle, item.stage.displayName,
                item.priority == .medium ? nil : "\(item.priority.rawValue.capitalized) priority",
                model.score(for: action.project, preferences: model.scoringPreferences())?.projectScore.map { "Project score \(Int($0.rounded()))/100" },
                action.resumesRecentProject ? "continues your recent project" : nil]
            .compactMap { $0 }.joined(separator: " · ")
    }

    // MARK: - Attention

    @ViewBuilder
    private func attention(limit: Int) -> some View {
        OverviewSection(title: "Worth your attention") {
            if model.attention.isEmpty, model.isAwaitingInitialRefresh {
                LoadingLabel(text: "Checking for attention signals…")
            } else if model.attention.isEmpty {
                // This only describes the current rules; it makes no claim that there
                // is no useful work (a Next action may be shown immediately above).
                Label("Nothing needs your attention", systemImage: "checkmark.circle")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, Theme.Space.tight)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(model.attention.prefix(limit))) { item in
                        AttentionRow(item: item) { go(to: item.target) }
                    }
                }
            }
        }
    }

    private func go(to target: Attention.Target) {
        switch target {
        case let .project(path): model.reveal(projectPath: path)
        case .ingest: model.selection = .ingest
        case .ideas: model.selection = .area(.ideas)
        case .idea(let path):
            if let idea = model.items(for: .ideas).first(where: { $0.url.canonicalPath == path }) { model.navigate(to: .area(.ideas), selecting: idea) }
        case .workspaceRoot: model.revealInFinder(model.workspace.root)
        }
    }

    // MARK: - Recent activity

    @ViewBuilder
    private func recentActivity(limit: Int) -> some View {
        let sessions = model.recentSessions
            .filter { $0.activeSeconds >= Attention.meaningfulSessionSeconds }
            .prefix(limit)

        if sessions.isEmpty == false {
            OverviewSection(title: "Recently") {
                VStack(spacing: 0) {
                    ForEach(Array(sessions)) { session in
                        let path = path(for: session)
                        Button { if let path { model.reveal(projectPath: path) } } label: {
                            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.tight) {
                                Text(session.projectName)
                                    .font(.system(size: 12, weight: .medium))
                                    .lineLimit(1)
                                Text(Format.relativeDate(session.endedAt))
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                                Spacer(minLength: Theme.Space.tight)
                                Text(session.activeHours < 1
                                     ? "\(Int((session.activeHours * 60).rounded()))m"
                                     : String(format: "%.1fh", session.activeHours))
                                    .font(.system(size: 11).monospacedDigit())
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(.vertical, 5)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        // Watcher can report a session for a project that has since
                        // been renamed or removed; the row still belongs in the
                        // history, it just has nowhere to go.
                        .disabled(path == nil)
                        Divider().opacity(0.4)
                    }
                }
            }
        }
    }

    private func path(for session: WorkSession) -> String? {
        // The Watcher id survives a rename and disambiguates same-named folders.
        // Names remain a fallback for sessions that predate an association.
        let projects = model.projects()
        return projects.first { model.projectRecord(for: $0)?.watcherID == session.projectID }?.url.canonicalPath
            ?? projects.first { $0.displayTitle == session.projectName }?.url.canonicalPath
    }

    // MARK: - Health

    @ViewBuilder
    private var health: some View {
        if model.watcherReachable == false {
            // Not an error. The daemon being off is ordinary, and everything here
            // except observed effort still works without it.
            Label("The background service isn't running — observed effort and sessions are unavailable. Start it in Settings.",
                  systemImage: "info.circle")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Pieces

private struct OverviewSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.tight) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One surfaced thing and, in plain words, why.
private struct AttentionRow: View {
    let item: Attention.Item
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.snug) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.title)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                    Text(item.explanation)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: Theme.Space.tight)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, Theme.Space.tight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("overview.attention.\(item.title)")
    }
}
