import Foundation

/// Direction-aware composites over one project's ratings.
///
/// Pure functions over `[metricID: 1…5]` — nothing here touches the filesystem, the
/// database or the network, so the same numbers come out for a stored project, an
/// unsaved edit, or a test fixture.
///
/// The arithmetic is deliberately identical to Better Projects', so a project that
/// scored 54.6 there scores 54.6 here. The three levels answer different questions:
/// a *group score* is how good this project is on one dimension of value, the *rated
/// score* weights those groups against each other, and the *project score* discounts
/// the rated score toward the middle in proportion to how little has been answered —
/// so one lucky 5 out of twenty-one blanks cannot read as an excellent project.
public struct ProjectScore: Sendable {

    public let ratings: [String: Int]
    public let enabledMetricIDs: Set<String>
    public let enabledGroups: [MetricGroup]
    public let groupWeights: [String: Double]

    public init(
        ratings: [String: Int],
        enabledMetricIDs: Set<String> = Set(MetricDefinition.all.map(\.id)),
        enabledGroups: [MetricGroup] = MetricGroup.allGroups,
        groupWeights: [String: Double] = MetricGroup.defaultWeights
    ) {
        self.ratings = ratings
        self.enabledMetricIDs = enabledMetricIDs
        self.enabledGroups = enabledGroups
        self.groupWeights = groupWeights
    }

    /// The metrics that count: enabled, and belonging to an enabled group.
    public var activeMetrics: [MetricDefinition] {
        let groupIDs = Set(enabledGroups.map(\.id))
        return MetricDefinition.all.filter {
            enabledMetricIDs.contains($0.id) && groupIDs.contains($0.groupID)
        }
    }

    public func rating(for metric: MetricDefinition) -> Int? { ratings[metric.id] }

    public func desirability(for metric: MetricDefinition) -> Double? {
        ratings[metric.id].map { metric.desirability(for: $0) }
    }

    /// Mean desirability of the answered, enabled metrics in one group. `nil` when
    /// nothing in the group has been answered — which is different from zero.
    public func groupScore(for group: MetricGroup) -> Double? {
        let answered = group.metrics
            .filter { enabledMetricIDs.contains($0.id) }
            .compactMap { desirability(for: $0) }
        guard answered.isEmpty == false else { return nil }
        return answered.reduce(0, +) / Double(answered.count)
    }

    /// Weighted mean of the groups that have a score, normalized over those groups
    /// only. `nil` when nothing at all has been answered.
    public var ratedScore: Double? {
        var weightedSum = 0.0
        var totalWeight = 0.0
        for group in enabledGroups {
            guard let score = groupScore(for: group) else { continue }
            let weight = max(groupWeights[group.id] ?? MetricGroup.defaultWeights[group.id] ?? 0, 0)
            weightedSum += score * weight
            totalWeight += weight
        }
        guard totalWeight > 0 else {
            // Every scored group was given zero weight. Falling back to an unweighted
            // mean beats reporting nothing for a project that has actually been rated.
            let scored = enabledGroups.compactMap { groupScore(for: $0) }
            guard scored.isEmpty == false else { return nil }
            return scored.reduce(0, +) / Double(scored.count)
        }
        return weightedSum / totalWeight
    }

    /// Fraction of the active metrics that have been answered, 0–1.
    public var coverage: Double {
        let active = activeMetrics
        guard active.isEmpty == false else { return 0 }
        return Double(active.filter { ratings[$0.id] != nil }.count) / Double(active.count)
    }

    public var answeredCount: Int { activeMetrics.filter { ratings[$0.id] != nil }.count }

    /// `50 + (rated − 50) × coverage`. A thinly-rated project is pulled toward the
    /// middle rather than being trusted at face value.
    public var projectScore: Double? {
        guard let rated = ratedScore else { return nil }
        return 50 + ((rated - 50) * coverage)
    }

    /// Ratings recorded against metrics that no longer exist. Kept and shown, never
    /// counted — a judgement someone made is not invalidated by a taxonomy change.
    public var legacyRatings: [String: Int] {
        ratings.filter { MetricDefinition.legacyMetricIDs.contains($0.key) }
    }
}
