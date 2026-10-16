import Foundation

/// Pure portfolio calculations.  Views supply filesystem, work-item and measurement
/// evidence; this type never reads a database or invents a score for missing data.
public enum ProjectPortfolio {
    public struct Candidate: Identifiable, Sendable {
        public let id: String
        public let name: String
        public let metadata: ProjectMetadata
        public let score: ProjectScore?
        public let nextAction: WorkItem?
        public let activityAgeDays: Double?

        public init(id: String, name: String, metadata: ProjectMetadata, score: ProjectScore?,
                    nextAction: WorkItem?, activityAgeDays: Double?) {
            self.id = id; self.name = name; self.metadata = metadata; self.score = score
            self.nextAction = nextAction; self.activityAgeDays = activityAgeDays
        }
    }

    public struct Recommendation: Sendable, Identifiable {
        public let candidate: Candidate
        public let explanation: String
        /// The concrete values available for the selected project. They describe the
        /// deterministic sort, rather than pretending unavailable ratings are zero.
        public let factors: [String]
        public var id: String { candidate.id }
    }

    public struct Ranking: Identifiable, Sendable {
        public let id: String
        public let title: String
        public let formula: String
        public let items: [(candidate: Candidate, score: Double, supporting: String?)]
    }

    public static func recommend(_ candidates: [Candidate], preferences: ProjectScoringPreferences) -> Recommendation? {
        let eligible = candidates.filter { $0.metadata.isUnavailableForNextWork == false && $0.nextAction != nil }
        guard let winner = eligible.sorted(by: actionOrder(preferences: preferences)).first, let action = winner.nextAction else { return nil }
        var factors = ["Open \(action.stage.displayName) work"]
        if winner.metadata.portfolioPriority == nil {
            factors.append("Portfolio priority untriaged (neutral)")
        } else {
            factors.append("Portfolio priority \(winner.metadata.portfolioPriorityLabel)")
        }
        factors.append("\(action.priority.rawValue.capitalized) work-item priority")
        if let dueDate = action.dueDate {
            factors.append("Due \(dueDate.formatted(date: .abbreviated, time: .omitted))")
        }
        if let score = doNextScore(winner.score, preferences: preferences) {
            factors.append("Do Next score \(Int(score.rounded()))")
        } else {
            factors.append("Do Next score unavailable (insufficient ratings)")
        }
        if let score = readyNowScore(winner.score, preferences: preferences) {
            factors.append("Ready Now score \(Int(score.rounded()))")
        } else {
            factors.append("Ready Now score unavailable (no readiness rating)")
        }
        return Recommendation(candidate: winner,
                              explanation: "Ordered by stage → local portfolio priority → work-item priority → due date → Do Next → Ready Now → name.",
                              factors: factors)
    }

    /// Why a candidate cannot appear in Recommended Next or any ranking lens, or nil
    /// when it is eligible for at least one (even if outranked). Uses the same rules.
    public static func exclusionReason(_ candidate: Candidate, preferences: ProjectScoringPreferences) -> String? {
        if candidate.metadata.isUnavailableForNextWork { return "Status \(candidate.metadata.status ?? "")".trimmingCharacters(in: .whitespaces) + " is excluded from recommendations" }
        if candidate.nextAction != nil { return nil }
        if rankings([candidate], preferences: preferences).contains(where: { !$0.items.isEmpty }) { return nil }
        if (candidate.score?.answeredCount ?? 0) == 0 { return "Unrated, with no open Now or Next work" }
        return "Too few ratings for any lens, and no open Now or Next work"
    }

    public static func rankings(_ candidates: [Candidate], preferences: ProjectScoringPreferences) -> [Ranking] {
        let active = candidates.filter { $0.metadata.isUnavailableForNextWork == false }
        func ranked(_ id: String, _ title: String, _ formula: String,
                    _ value: (Candidate) -> Double?, supporting: (Candidate) -> String? = { _ in nil }) -> Ranking {
            let items = active.compactMap { candidate -> (candidate: Candidate, score: Double, supporting: String?)? in
                value(candidate).map { (candidate, $0, supporting(candidate)) }
            }.sorted { $0.score == $1.score ? $0.candidate.name < $1.candidate.name : $0.score > $1.score }
            return Ranking(id: id, title: title, formula: formula, items: Array(items.prefix(5)))
        }
        return [
            ranked("overall", "Best Overall", "Project Score; requires 50% rating coverage", { candidate in
                guard let score = candidate.score, score.coverage >= 0.5 else { return nil }; return score.projectScore
            }, supporting: { candidate in candidate.score.map { "\(Int($0.coverage * 100))% rated" } }),
            ranked("next", "Do Next", "Urgency 40% · dependencies 25% · readiness 20% · effort 15%", { doNextScore($0.score, preferences: preferences) }),
            ranked("exciting", "Most Exciting", "Enjoyment 70% · personal importance 30%", { excitingScore($0.score, preferences: preferences) }),
            ranked("financial", "Financial Upside", "Income potential 65% · cost savings 35%", { financialScore($0.score, preferences: preferences) }),
            ranked("professional", "Professional Value", "Career relevance · demonstration · opportunity; requires 2 ratings", { groupScore($0.score, group: .professionalValue, preferences: preferences) }, supporting: { groupCoverage($0.score, group: .professionalValue, preferences: preferences) }),
            ranked("learning", "Learning & Growth", "Skill development · knowledge · exploration; requires 2 ratings", { groupScore($0.score, group: .learningGrowth, preferences: preferences) }, supporting: { groupCoverage($0.score, group: .learningGrowth, preferences: preferences) }),
            ranked("strategic", "Strategic Value", "Goal alignment · leverage · dependencies; requires 2 ratings", { groupScore($0.score, group: .strategicValue, preferences: preferences) }, supporting: { groupCoverage($0.score, group: .strategicValue, preferences: preferences) }),
            ranked("ready", "Ready Now", "Readiness 65% · effort desirability 35%", { readyNowScore($0.score, preferences: preferences) }),
            ranked("risk", "Highest Cost / Risk", "Financial cost · effort · uncertainty · burden · abandonment", { riskScore($0.score, preferences: preferences) }),
        ]
    }

    private static func actionOrder(preferences: ProjectScoringPreferences) -> (Candidate, Candidate) -> Bool {
        { lhs, rhs in
            guard let a = lhs.nextAction, let b = rhs.nextAction else { return lhs.nextAction != nil }
            if a.stage.rank != b.stage.rank { return a.stage.rank < b.stage.rank }
            if lhs.metadata.portfolioPriorityForRecommendation != rhs.metadata.portfolioPriorityForRecommendation {
                return lhs.metadata.portfolioPriorityForRecommendation > rhs.metadata.portfolioPriorityForRecommendation
            }
            if a.priority.rank != b.priority.rank { return a.priority.rank < b.priority.rank }
            switch (a.dueDate, b.dueDate) {
            case let (a?, b?) where a != b: return a < b
            case (_?, nil): return true
            case (nil, _?): return false
            default: break
            }
            let aScore = doNextScore(lhs.score, preferences: preferences) ?? -.infinity
            let bScore = doNextScore(rhs.score, preferences: preferences) ?? -.infinity
            if aScore != bScore { return aScore > bScore }
            let aReady = readyNowScore(lhs.score, preferences: preferences) ?? -.infinity
            let bReady = readyNowScore(rhs.score, preferences: preferences) ?? -.infinity
            if aReady != bReady { return aReady > bReady }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    private static func desirability(_ score: ProjectScore?, _ metric: MetricDefinition,
                                     preferences: ProjectScoringPreferences) -> Double? {
        guard preferences.enabledGroupIDs.contains(metric.groupID), preferences.enabledMetricIDs.contains(metric.id) else { return nil }
        return score?.desirability(for: metric)
    }

    private static func weighted(_ score: ProjectScore?, _ metrics: [(MetricDefinition, Double)], minimum: Int,
                                 preferences: ProjectScoringPreferences) -> Double? {
        let values = metrics.compactMap { metric, weight -> (Double, Double)? in desirability(score, metric, preferences: preferences).map { ($0, weight) } }
        guard values.count >= minimum else { return nil }
        let total = values.reduce(0) { $0 + $1.1 }
        return values.reduce(0) { $0 + $1.0 * $1.1 } / total
    }

    public static func doNextScore(_ score: ProjectScore?, preferences: ProjectScoringPreferences) -> Double? {
        weighted(score, [(.urgency, 0.40), (.dependencyImportance, 0.25), (.readiness, 0.20), (.effort, 0.15)], minimum: 2, preferences: preferences)
    }
    public static func readyNowScore(_ score: ProjectScore?, preferences: ProjectScoringPreferences) -> Double? {
        guard desirability(score, .readiness, preferences: preferences) != nil else { return nil }
        return weighted(score, [(.readiness, 0.65), (.effort, 0.35)], minimum: 1, preferences: preferences)
    }
    public static func excitingScore(_ score: ProjectScore?, preferences: ProjectScoringPreferences) -> Double? {
        guard desirability(score, .enjoyment, preferences: preferences) != nil else { return nil }
        return weighted(score, [(.enjoyment, 0.70), (.personalImportance, 0.30)], minimum: 1, preferences: preferences)
    }
    public static func financialScore(_ score: ProjectScore?, preferences: ProjectScoringPreferences) -> Double? {
        weighted(score, [(.incomePotential, 0.65), (.costSavings, 0.35)], minimum: 1, preferences: preferences)
    }

    /// Better Projects' group lenses require at least two answered enabled metrics.
    /// A one-answer group reads as an unknown rather than an authoritative rank.
    public static func groupScore(_ score: ProjectScore?, group: MetricGroup,
                                  preferences: ProjectScoringPreferences) -> Double? {
        guard let score, preferences.enabledGroupIDs.contains(group.id) else { return nil }
        let active = group.metrics.filter { preferences.enabledMetricIDs.contains($0.id) }
        guard active.count >= 2, active.filter({ score.ratings[$0.id] != nil }).count >= 2 else { return nil }
        return score.groupScore(for: group)
    }

    private static func groupCoverage(_ score: ProjectScore?, group: MetricGroup,
                                      preferences: ProjectScoringPreferences) -> String? {
        guard let score else { return nil }
        let active = group.metrics.filter { preferences.enabledMetricIDs.contains($0.id) }
        let answered = active.filter { score.ratings[$0.id] != nil }.count
        return "\(answered)/\(active.count) rated"
    }

    public static func riskScore(_ score: ProjectScore?, preferences: ProjectScoringPreferences) -> Double? {
        guard let score else { return nil }
        let metrics: [MetricDefinition] = [.financialCost, .effort, .outcomeUncertainty, .ongoingBurden, .abandonmentCost]
        let values = metrics.filter { preferences.enabledMetricIDs.contains($0.id) && preferences.enabledGroupIDs.contains($0.groupID) }
            .compactMap { score.ratings[$0.id].map { Double($0 - 1) / 4 * 100 } }
        guard values.count >= 2 else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }
}
