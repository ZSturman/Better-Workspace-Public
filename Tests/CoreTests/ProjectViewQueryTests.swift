import XCTest
@testable import BetterWorkspaceCore

final class ProjectViewQueryTests: XCTestCase {
    private func row(_ id: String, _ values: [String: String] = [:], tags: [String] = []) -> ProjectQueryRecord {
        .init(id: id, name: id, values: values, selections: ["tags": tags])
    }
    func testMultipleStatusesAreAlternativesAndExclusionsKeepUnclassified() {
        let include = ProjectPropertyFilter(field: "status", values: ["Planning", "Development"])
        XCTAssertTrue(include.matches(["Planning"]))
        XCTAssertTrue(include.matches(["Development"]))
        XCTAssertFalse(include.matches(["Complete"]))
        let exclude = ProjectPropertyFilter(field: "status", operation: .excludes, values: ["Complete", "Abandoned", "Deprecated", "Archived"])
        for value in ["Active", "", "Planning"] { XCTAssertTrue(exclude.matches([value])) }
        for value in ["complete", "Archived", " Abandoned "] { XCTAssertFalse(exclude.matches([value])) }
    }
    func testSearchAlwaysNarrowsAndAllAnyPropertyLogicIsExplicit() {
        let filters = [ProjectPropertyFilter(field: "domain", values: ["Technology"]), .init(field: "phase", values: ["Planning", "Development"])]
        let tech = row("AI Studio", ["domain": "Technology", "phase": "Development"], tags: ["AI"])
        let art = row("Art Studio", ["domain": "Art", "phase": "Planning"])
        XCTAssertTrue(ProjectViewQuery.matches(tech, query: "studio ai", filters: filters))
        XCTAssertFalse(ProjectViewQuery.matches(art, query: "studio", filters: filters))
        XCTAssertTrue(ProjectViewQuery.matches(art, query: "studio", filters: filters, matchAny: true))
        XCTAssertFalse(ProjectViewQuery.matches(art, query: "missing", filters: filters, matchAny: true))
        XCTAssertTrue(ProjectViewQuery.matches(art, query: "", filters: [.init(field: "status", values: [])], matchAny: true))
    }
    func testTagsMatchWholeValuesWithCaseAndAccentsAndIncludeAll() {
        let record = row("Project", tags: ["AI", "Crème, design"])
        XCTAssertTrue(ProjectViewQuery.matches(record, query: "", filters: [.init(field: "tags", operation: .includesAll, values: ["ai", "creme, design"])]))
        XCTAssertFalse(ProjectViewQuery.matches(record, query: "", filters: [.init(field: "tags", values: ["design"])]))
        XCTAssertFalse(ProjectViewQuery.matches(record, query: "", filters: [.init(field: "tags", operation: .excludes, values: ["ai"])]))
    }
    func testSecondaryNumericSortAndMissingValuesLastInBothDirections() {
        let rows = [row("Z", ["domain": "Tech", "score": "10"]), row("A", ["domain": "Tech", "score": "90"]), row("B", ["domain": "Art", "score": "50"]), row("Missing", ["domain": "Tech"])]
        let sorts = [ProjectSortRule(field: "domain"), .init(field: "score", ascending: false)]
        XCTAssertEqual(rows.sorted { ProjectViewQuery.orderedBefore($0, $1, sorts: sorts) }.map(\.id), ["B", "A", "Z", "Missing"])
        for ascending in [true, false] {
            XCTAssertEqual(rows.sorted { ProjectViewQuery.orderedBefore($0, $1, sorts: [.init(field: "score", ascending: ascending)]) }.last?.id, "Missing")
        }
    }
    func testObservedActivityAndUnfinishedScopeKeepUnknownDistinctFromZero() {
        let stale = row("Old", ["sort:lastWorked": "90", "openWork": "8"])
        let zero = row("Today", ["sort:lastWorked": "0", "openWork": "0"])
        let unknown = row("Unknown")
        XCTAssertTrue(ProjectActivityFilter.stalled.matches(stale))
        XCTAssertTrue(ProjectActivityFilter.recent.matches(zero))
        XCTAssertFalse(ProjectActivityFilter.stale.matches(zero))
        for filter in ProjectActivityFilter.allCases where filter != .all { XCTAssertFalse(filter.matches(unknown)) }
    }
    func testRulesAndSortsRoundTrip() throws {
        let rules = [ProjectPropertyFilter(field: "status", operation: .excludes, values: ["Complete", "Archived"]), .init(field: "tags", operation: .includesAll, values: ["AI", "Native"])]
        XCTAssertEqual(try JSONDecoder().decode([ProjectPropertyFilter].self, from: JSONEncoder().encode(rules)), rules)
        let sorts = [ProjectSortRule(field: "domain"), .init(field: "lastWorked", ascending: false)]
        XCTAssertEqual(try JSONDecoder().decode([ProjectSortRule].self, from: JSONEncoder().encode(sorts)), sorts)
    }
    func testHundredsOfProjectsFilterAndSortWithinInteractiveBudget() {
        let rows = (0..<800).map { row("Project \($0)", ["domain": $0.isMultiple(of: 2) ? "Technology" : "Art", "status": $0.isMultiple(of: 5) ? "Complete" : "Active", "score": String($0 % 100)]) }
        let filters = [ProjectPropertyFilter(field: "domain", values: ["Technology"]), .init(field: "status", operation: .excludes, values: ["Complete"])]
        let start = Date()
        let result = rows.filter { ProjectViewQuery.matches($0, query: "project", filters: filters) }.sorted { ProjectViewQuery.orderedBefore($0, $1, sorts: [.init(field: "score", ascending: false)]) }
        XCTAssertEqual(result.count, 320)
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.0)
    }
}

final class ProjectAnalyticsTests: XCTestCase {
    func testChartsUseOnlySuppliedFilteredRowsAndRealRawEvidence() {
        let rows = [ProjectQueryRecord(id: "active", name: "Same name", values: ["status": "Active", "domain": "Tech", "openWork": "8", "sort:lastWorked": "45", "hours30": "4"]),
                    .init(id: "complete", name: "Same name", values: ["status": "Complete", "openWork": "20", "sort:lastWorked": "180", "hours30": "99"]),
                    .init(id: "unknown", name: "Unknown", values: ["active7d": "100", "score": "90"])]
        XCTAssertEqual(ProjectAnalytics.bars(rows, metric: .backlog).map(\.id), ["active"])
        XCTAssertEqual(ProjectAnalytics.bars(rows, metric: .stalled).map(\.id), ["active"])
        XCTAssertEqual(ProjectAnalytics.bars(rows, metric: .idle).map(\.value), [45])
        XCTAssertEqual(ProjectAnalytics.bars(rows, metric: .attention).map(\.value), [4])
        XCTAssertEqual(ProjectAnalytics.bars(rows, metric: .domains), [.init(id: "Tech", title: "Tech", value: 4)])
        XCTAssertEqual(ProjectAnalytics.bars(rows, metric: .backlog, activeOnly: false).map(\.id), ["complete", "active"])
        XCTAssertTrue(ProjectAnalytics.bars([rows[2]], metric: .attention).isEmpty)
        XCTAssertEqual(ProjectAnalytics.bars([rows[0]], metric: .backlog, limit: 0), [])
    }
    func testPeriodsAndSortingAndDuplicateTitlesKeepStableProjectIdentity() {
        let rows = [ProjectQueryRecord(id: "a", name: "Same", values: ["hours7": "2", "hours90": "20", "openWork": "2"]), .init(id: "b", name: "Same", values: ["hours7": "5", "hours90": "10", "openWork": "3"])]
        XCTAssertEqual(ProjectAnalytics.bars(rows, metric: .attention, days: 7).map(\.id), ["b", "a"])
        XCTAssertEqual(ProjectAnalytics.bars(rows, metric: .attention, days: 90).map(\.id), ["a", "b"])
        XCTAssertEqual(ProjectAnalytics.bars(rows, metric: .backlog, ascending: true).map(\.id), ["a", "b"])
    }
}

final class ProjectAnalyticsProgressTests: XCTestCase {
    func testClosestToDoneNeedsOpenAndCompletedRecordedWork() {
        let rows = [ProjectQueryRecord(id: "most", name: "Most", values: ["openWork": "1", "completedWork": "9"]),
                    .init(id: "half", name: "Half", values: ["openWork": "4", "completedWork": "4"]),
                    .init(id: "finished", name: "Finished", values: ["openWork": "0", "completedWork": "6"]),
                    .init(id: "fresh", name: "Fresh", values: ["openWork": "5", "completedWork": "0"]),
                    .init(id: "unknown", name: "Unknown", values: [:])]
        let bars = ProjectAnalytics.bars(rows, metric: .nearDone)
        XCTAssertEqual(bars.map(\.id), ["most", "half"])
        XCTAssertEqual(bars.map(\.value), [90, 50])
        XCTAssertEqual(bars.first?.note, "1 open")
    }
    func testHighValueIdleUsesScoreAndObservedAgeWithinThePeriod() {
        let rows = [ProjectQueryRecord(id: "idle", name: "Idle", values: ["score": "82", "sort:lastWorked": "45"]),
                    .init(id: "recent", name: "Recent", values: ["score": "90", "sort:lastWorked": "3"]),
                    .init(id: "low", name: "Low", values: ["score": "40", "sort:lastWorked": "120"]),
                    .init(id: "unobserved", name: "Unobserved", values: ["score": "95"]),
                    .init(id: "done", name: "Done", values: ["status": "Complete", "score": "99", "sort:lastWorked": "300"])]
        XCTAssertEqual(ProjectAnalytics.bars(rows, metric: .valueIdle, days: 30).map(\.id), ["idle"])
        XCTAssertEqual(ProjectAnalytics.bars(rows, metric: .valueIdle, days: 90).map(\.id), [])
        XCTAssertEqual(ProjectAnalytics.bars(rows, metric: .valueIdle, days: 7).map(\.value), [82])
        XCTAssertEqual(ProjectAnalytics.bars(rows, metric: .valueIdle, days: 30).first?.note, "last observed 45 days ago")
    }
    func testDefaultDashboardIsASubsetOfMetricsWithUnits() {
        XCTAssertTrue(Set(ProjectAnalytics.Metric.defaultOrder).isSubset(of: Set(ProjectAnalytics.Metric.allCases)))
        for metric in ProjectAnalytics.Metric.allCases { XCTAssertFalse(metric.unit.isEmpty); XCTAssertFalse(metric.explanation.isEmpty) }
    }
}

final class ProjectPortfolioExclusionTests: XCTestCase {
    private let preferences = ProjectScoringPreferences()
    private func candidate(_ id: String, status: String = "Active", ratings: [String: Int] = [:], action: Bool = false) -> ProjectPortfolio.Candidate {
        .init(id: id, name: id, metadata: ProjectMetadata(status: status), score: ProjectScore(ratings: ratings),
              nextAction: action ? WorkItem(id: id + "-work", kind: .task, title: "Work", stage: .now, url: URL(fileURLWithPath: "/tmp/x.bw.md")) : nil, activityAgeDays: nil)
    }
    func testExplainsOnlyCandidatesThatCannotAppearAnywhereInDecide() {
        let all = Dictionary(uniqueKeysWithValues: MetricDefinition.all.map { ($0.id, 3) })
        XCTAssertNil(ProjectPortfolio.exclusionReason(candidate("rated", ratings: all), preferences: preferences))
        XCTAssertNil(ProjectPortfolio.exclusionReason(candidate("actionable", action: true), preferences: preferences))
        XCTAssertEqual(ProjectPortfolio.exclusionReason(candidate("blank"), preferences: preferences), "Unrated, with no open Now or Next work")
        XCTAssertEqual(ProjectPortfolio.exclusionReason(candidate("thin", ratings: [MetricDefinition.urgency.id: 5]), preferences: preferences),
                       "Too few ratings for any lens, and no open Now or Next work")
        XCTAssertEqual(ProjectPortfolio.exclusionReason(candidate("paused", status: "Paused", ratings: all, action: true), preferences: preferences),
                       "Status Paused is excluded from recommendations")
    }
}

final class ProjectInactivityLowerBoundTests: XCTestCase {
    func testLowerBoundShowsInactivityButNeverRecency() {
        let unobserved = ProjectQueryRecord(id: "u", name: "Unobserved", values: ["sort:lastWorked": "3", "bound:lastWorked": "lower", "openWork": "9"])
        let observed = ProjectQueryRecord(id: "o", name: "Observed", values: ["sort:lastWorked": "3", "openWork": "9"])
        XCTAssertFalse(ProjectActivityFilter.recent.matches(unobserved), "No session since discovery three days ago is not recent work")
        XCTAssertTrue(ProjectActivityFilter.recent.matches(observed))
        let old = ProjectQueryRecord(id: "old", name: "Old", values: ["sort:lastWorked": "31", "bound:lastWorked": "lower", "openWork": "9"])
        XCTAssertTrue(ProjectActivityFilter.stale.matches(old), "At least 31 days is enough to show 30+ days of inactivity")
    }
    func testInactivityChartsFollowThePeriodAndNameLowerBounds() {
        let rows = [ProjectQueryRecord(id: "a", name: "A", values: ["sort:lastWorked": "26", "bound:lastWorked": "lower", "openWork": "25", "score": "70"]),
                    .init(id: "b", name: "B", values: ["sort:lastWorked": "10", "openWork": "6"])]
        XCTAssertEqual(ProjectAnalytics.bars(rows, metric: .stalled, days: 30).map(\.id), [])
        XCTAssertEqual(ProjectAnalytics.bars(rows, metric: .stalled, days: 7).map(\.id), ["a", "b"])
        XCTAssertEqual(ProjectAnalytics.bars(rows, metric: .stalled, days: 7).first?.note, "no observed work for at least 26 days")
        XCTAssertEqual(ProjectAnalytics.bars(rows, metric: .stalled, days: 7).last?.note, "last observed 10 days ago")
        XCTAssertEqual(ProjectAnalytics.bars(rows, metric: .valueIdle, days: 7).map(\.id), ["a"])
        let idle = ProjectAnalytics.bars(rows, metric: .idle)
        XCTAssertTrue(idle[0].isLowerBound)
        XCTAssertFalse(idle[1].isLowerBound)
        XCTAssertFalse(ProjectAnalytics.bars(rows, metric: .stalled, days: 7)[0].isLowerBound,
                       "The open-record count itself is exact even when the activity age is bounded")
    }
}
