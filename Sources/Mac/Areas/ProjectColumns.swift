import SwiftUI
import BetterWorkspaceCore

/// Which columns the Projects table can show, and which it does.
///
/// The table gains a lot of available columns and shows none of them by default: the
/// four that were there before are still the four you get, and everything the
/// consolidation added is opt-in from one small menu. A project browser that opens
/// showing fourteen columns of mostly em dashes would be a worse tool than the one
/// this replaces.
enum ProjectColumn: String, CaseIterable, Identifiable {
    case kind, git, items, modified
    case score, coverage, notion
    case personalValue, financialValue, professionalValue, learningGrowth
    case strategicValue, timeExecution, riskConsequences
    case effort, active7d, lastWorked, consistency

    var id: String { rawValue }

    var title: String {
        switch self {
        case .kind: return "Kind"
        case .git: return "Git"
        case .items: return "Items"
        case .modified: return "Last activity"
        case .score: return "Score"
        case .coverage: return "Rated"
        case .notion: return "Notion"
        default:
            if let dimension { return dimension.title }
            return MetricGroup.find(id: rawValue)?.displayName ?? rawValue
        }
    }

    /// The background service dimension behind this column, when it is a measured one.
    ///
    /// Measured columns are not calculated here. The daemon publishes the number, its
    /// state and its caveat, and this app presents them — it never recomputes a
    /// formula, because a second implementation would only disagree with the first.
    var dimension: MeasurementDimension? {
        switch self {
        case .effort: return .investmentObserved
        case .active7d: return .activity7d
        case .lastWorked: return .activityAge
        case .consistency: return .consistency28d
        default: return nil
        }
    }

    var isMeasured: Bool { dimension != nil }

    /// What the table header says. "Risk & Long-Term Consequences" does not fit a
    /// numeric column, and a truncated header tells you nothing — the full name and
    /// its description stay in the menu and the tooltip.
    static let measuredColumns: [ProjectColumn] = [.effort, .active7d, .lastWorked, .consistency]

    var shortTitle: String {
        switch self {
        case .personalValue: return "Personal"
        case .financialValue: return "Financial"
        case .professionalValue: return "Career"
        case .learningGrowth: return "Learning"
        case .strategicValue: return "Strategic"
        case .timeExecution: return "Time"
        case .riskConsequences: return "Risk"
        default: return title
        }
    }

    /// Longer explanation for the menu, where "Score" alone does not say enough.
    var help: String? {
        switch self {
        case .score: return "Project score — the weighted rating, discounted by how much of it you have answered"
        case .coverage: return "How many of the 21 metrics have been answered"
        case .notion: return "Whether this project is associated with a Notion page"
        case .effort: return "Hours the background service has actually observed you working"
        case .active7d: return "How consistently active the last seven days were"
        case .lastWorked: return "Days since the last observed work session"
        case .consistency: return "Share of the last four weeks with a work session"
        default: return MetricGroup.find(id: rawValue)?.description
        }
    }

    var isScoring: Bool {
        switch self {
        case .kind, .git, .items, .modified, .notion: return false
        default: return isMeasured == false
        }
    }

    var idealWidth: CGFloat {
        if self == .coverage { return 62 }
        if isMeasured { return 76 }
        return isScoring ? 78 : 58
    }

    /// Nothing. The table opens exactly as it did before scoring existed; every column
    /// below is something you switched on.
    static let defaultVisible: Set<ProjectColumn> = []

    static let groupColumns: [ProjectColumn] = [
        .personalValue, .financialValue, .professionalValue, .learningGrowth,
        .strategicValue, .timeExecution, .riskConsequences,
    ]

    /// The columns the Columns menu governs. Name, Kind, Git, Items and Last activity
    /// are the table's fixed spine and are not in here.
    static let optional: [ProjectColumn] = [.score, .coverage, .notion] + measuredColumns + groupColumns
}

/// A 0–100 figure that may not be known.
///
/// Unknown is not zero. A project nobody has rated has no score, and showing 0 would
/// say something false about it — so unknown renders as an em dash, and sorts below
/// every real value rather than above them.
struct RankedValue: Comparable, Hashable {
    let value: Double?

    init(_ value: Double?) { self.value = value }

    static func < (lhs: RankedValue, rhs: RankedValue) -> Bool {
        switch (lhs.value, rhs.value) {
        case let (l?, r?): return l < r
        case (nil, _?): return true
        case (_?, nil): return false
        case (nil, nil): return false
        }
    }

    var label: String { value.map { "\(Int($0.rounded()))" } ?? "—" }
    var isKnown: Bool { value != nil }
}

/// Persisted table configuration.
struct ProjectColumnPreferences {
    static let defaultsKey = "projectsVisibleColumns"

    static func load(from defaults: UserDefaults = TestIsolation.defaults) -> Set<ProjectColumn> {
        guard let stored = defaults.string(forKey: defaultsKey) else { return ProjectColumn.defaultVisible }
        // An explicitly emptied selection is a real choice; only an absent key defaults.
        return Set(stored.split(separator: ",").compactMap { ProjectColumn(rawValue: String($0)) })
    }

    static func save(_ columns: Set<ProjectColumn>, to defaults: UserDefaults = TestIsolation.defaults) {
        defaults.set(columns.map(\.rawValue).sorted().joined(separator: ","), forKey: defaultsKey)
    }
}

/// The small set of portfolio distinctions that remains useful across a large local
/// folder collection.  Search is intentionally omitted: restoring a stale query at
/// launch is more surprising than helpful.
enum ProjectPortfolioGroup: String, CaseIterable, Codable, Identifiable {
    case none, domain, status, phase, priority
    var id: String { rawValue }
    var title: String {
        switch self {
        case .none: return "No grouping"
        case .domain: return "Domain"
        case .status: return "Status"
        case .phase: return "Phase"
        case .priority: return "Local priority"
        }
    }
}

enum ProjectPortfolioSort: String, CaseIterable, Codable, Identifiable {
    case name, kind, domain, status, priority, modified
    var id: String { rawValue }
    var title: String {
        switch self {
        case .name: return "Name"
        case .kind: return "Kind"
        case .domain: return "Domain"
        case .status: return "Status"
        case .priority: return "Local priority"
        case .modified: return "Last activity"
        }
    }
}

enum ProjectPriorityFilter: String, CaseIterable, Codable, Identifiable {
    case all, untriaged, someday, low, normal, high, critical
    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: return "All priorities"
        case .untriaged: return "Untriaged"
        case .someday: return "1 — Someday"
        case .low: return "2 — Low"
        case .normal: return "3 — Normal"
        case .high: return "4 — High"
        case .critical: return "5 — Critical"
        }
    }
    var value: Int? {
        switch self {
        case .someday: return 1
        case .low: return 2
        case .normal: return 3
        case .high: return 4
        case .critical: return 5
        case .all, .untriaged: return nil
        }
    }
}

struct ProjectPortfolioPreferences: Codable {
    static let defaultsKey = "projectPortfolioPreferences"

    var presentation: ProjectPresentation = .table
    var group: ProjectPortfolioGroup = .none
    var domain: String?
    var status: String?
    var phase: String?
    var priority: ProjectPriorityFilter = .all
    var onlyRated = false
    var sort: ProjectPortfolioSort = .modified
    var sortAscending = false

    static func load(from defaults: UserDefaults = TestIsolation.defaults) -> ProjectPortfolioPreferences {
        guard let data = defaults.data(forKey: defaultsKey),
              let preferences = try? JSONDecoder().decode(ProjectPortfolioPreferences.self, from: data)
        else { return ProjectPortfolioPreferences() }
        return preferences
    }

    func save(to defaults: UserDefaults = TestIsolation.defaults) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }
}

/// A score rendered the way the measurement actually is: a number when it is known, an
/// em dash when it is not, and dimmed when it rests on very little.
struct ScoreCell: View {
    let ranked: RankedValue
    var coverage: Double?

    private var isThin: Bool { (coverage ?? 1) < 0.25 }

    var body: some View {
        Text(ranked.label)
            .font(.system(size: 11).monospacedDigit())
            .foregroundStyle(ranked.isKnown ? (isThin ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.secondary))
                                            : AnyShapeStyle(.quaternary))
            .help(helpText)
    }

    private var helpText: String {
        guard ranked.isKnown else { return "Not rated yet" }
        guard let coverage, coverage < 1 else { return "" }
        return "Based on \(Int((coverage * 100).rounded()))% of the metrics"
    }
}

/// Whether a project is associated with a Notion page, and a way in when it is.
///
/// Absence is the normal case and must not look like a failure: Better Workspace is
/// complete without Notion, so an unassociated project simply shows an em dash.
/// Table cells take everything they show as values and read nothing from the
/// environment. When a row is removed — a project moved or deleted in Finder — AppKit
/// lays the outgoing row out once more after SwiftUI has detached its environment, and
/// an `@Environment(AppModel.self)` lookup there is a fatal error. That crashed the app
/// whenever a project folder left Projects while it was on screen.
struct NotionCell: View {
    let url: URL?

    var body: some View {
        if let url {
            Button { NSWorkspace.shared.open(url) } label: {
                Image(systemName: "arrow.up.forward.square").font(.system(size: 10))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Open this project's Notion page")
        } else {
            Text("—").foregroundStyle(.quaternary)
        }
    }
}

struct GitCell: View {
    let isRepository: Bool
    let branch: String

    var body: some View {
        if isRepository {
            HStack(spacing: 4) {
                Image(systemName: "arrow.triangle.branch").font(.system(size: 9))
                Text(branch.isEmpty ? "repo" : branch).lineLimit(1)
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
        } else {
            Text("—").foregroundStyle(.quaternary)
        }
    }
}

/// The project's name, its detected kind, and any tags it carries.
struct ProjectNameCell: View {
    let row: ProjectsView.ProjectRow
    /// Passed in, not looked up: see `NotionCell`.
    let tags: [Tag]

    var body: some View {
        HStack(spacing: Theme.Space.tight) {
            Image(systemName: row.kind.symbolName)
                .foregroundStyle(Theme.kindColor(.folder))
                .frame(width: 14)
            Text(row.name).lineLimit(1)
            if tags.isEmpty == false { TagChipRow(tags: tags, limit: 3) }
        }
    }
}

/// One generated optional column's cell. Which view it is depends on the column, but
/// the sort key is always `RankedValue`, so the table can order every one of them.
struct OptionalColumnCell: View {
    let column: ProjectColumn
    let row: ProjectsView.ProjectRow

    var body: some View {
        switch column {
        case .score:
            ScoreCell(ranked: row.projectScore, coverage: row.score?.coverage)
        case .coverage:
            Text(row.ratedLabel)
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.tertiary)
        case .notion:
            NotionCell(url: row.record?.notionURL)
        default:
            if let dimension = column.dimension {
                MeasurementCell(measurement: row.measurements?.measurement(dimension),
                                isDuration: dimension.isDuration)
            } else {
                ScoreCell(ranked: row.groupScore(column), coverage: nil)
            }
        }
    }
}

/// A measurement from the background service, shown the way the backend describes it.
///
/// Three states have to stay distinguishable and they all look different here: a known
/// value reads plainly, a provisional one is marked with a degree sign because it rests
/// on incomplete observation, and an unmeasured one is an em dash. Never a zero — the
/// whole point of the backend's contract is that "nobody has worked on this" and
/// "measured zero hours" are different claims.
struct MeasurementCell: View {
    let measurement: MeasuredValue?
    let isDuration: Bool

    var body: some View {
        Text(label)
            .font(.system(size: 11).monospacedDigit())
            .foregroundStyle(measurement?.value == nil ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.secondary))
            .help(helpText)
    }

    private var label: String {
        guard let value = measurement?.value else { return "—" }
        let text = isDuration ? Format.dayCount(value) : "\(Int(value.rounded()))"
        return measurement?.isProvisional == true ? text + "°" : text
    }

    private var helpText: String {
        guard let measurement else { return "The background service has no measurement for this project" }
        guard measurement.value != nil else {
            return measurement.explanation ?? "Not measured"
        }
        var parts: [String] = []
        if let raw = measurement.rawValue, let unit = measurement.unit {
            parts.append(String(format: "%.1f %@", raw, unit))
        }
        if measurement.isProvisional {
            parts.append("Provisional — sensing did not cover the whole window")
        }
        if let explanation = measurement.explanation { parts.append(explanation) }
        return parts.joined(separator: " · ")
    }
}
