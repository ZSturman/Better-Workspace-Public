import Foundation
import BetterWorkspaceCore

/// Project-workspace coordination belongs at the app-model boundary: it joins the
/// private project store to filesystem-owned work records and watcher observations.
extension AppModel {
    func openProjectWorkspace(for item: WorkspaceItem) {
        // Overview can surface a directory before the initial background registration
        // finishes. Register this one private identity so that first click still opens.
        let record = projectRecord(for: item) ?? projectStore.register(url: item.url)
        // A local project must replace a previously opened Notion-only project.
        openGraphProjectID = nil
        openProjectWorkspaceID = record.id
        navigate(to: .area(.projects), selecting: item)
        showInspector = false
    }

    func closeProjectWorkspace() { openProjectWorkspaceID = nil }

    func workspaceProject() -> WorkspaceItem? {
        guard let id = openProjectWorkspaceID, let record = projectStore.record(id: id) else { return nil }
        return projects().first { $0.url.canonicalPath == record.lastPath }
    }

    func projectMetadata(for item: WorkspaceItem) -> ProjectMetadata {
        guard let record = projectRecord(for: item) else { return ProjectMetadata() }
        return projectStore.metadata(for: record.id)
    }

    func projectPortfolioDetails(for item: WorkspaceItem) -> ProjectPortfolioDetails {
        guard let record = projectRecord(for: item) else { return .init() }
        return projectStore.portfolioDetails(for: record.id)
    }

    func saveProjectMetadata(_ metadata: ProjectMetadata, relatedProjectIDs: Set<String>, for item: WorkspaceItem) {
        guard let record = projectRecord(for: item) else { return }
        projectStore.setMetadata(metadata, for: record.id)
        projectStore.setRelatedProjectIDs(relatedProjectIDs, for: record.id)
        statusMessage = "Saved details for “\(item.displayTitle)”"
        queueProjectGraphEdits(for: item, fields: ["domain", "Status", "Phase", "Type", "Completion Model", "Maintenance Cadence", "Current Work", "Next Work", "Recent Work", "Work Mode", "Blocked By", "status details", "Local Directory", "started at", "last update at", "related projects"])
        refreshOverview()
    }

    func relatedProjects(for item: WorkspaceItem) -> [WorkspaceItem] {
        guard let record = projectRecord(for: item) else { return [] }
        let ids = projectStore.relatedProjectIDs(for: record.id)
        return projects().filter { projectRecord(for: $0).map { ids.contains($0.id) } ?? false }
    }

    func scoringPreferences() -> ProjectScoringPreferences { projectStore.scoringPreferences() }

    func setScoringPreferences(_ preferences: ProjectScoringPreferences) {
        projectStore.setScoringPreferences(preferences)
        refreshOverview()
        requestMobileCloudSync()
    }

    func score(for item: WorkspaceItem, preferences: ProjectScoringPreferences? = nil) -> ProjectScore? {
        guard let record = projectRecord(for: item) else { return nil }
        let preferences = preferences ?? scoringPreferences()
        return ProjectScore(ratings: ratingsByProject[record.id] ?? [:], enabledMetricIDs: preferences.enabledMetricIDs,
                            enabledGroups: MetricGroup.allGroups.filter { preferences.enabledGroupIDs.contains($0.id) },
                            groupWeights: preferences.groupWeights)
    }

    func projectWorkItems(for item: WorkspaceItem) -> [WorkItem] {
        guard let path = workspaceRelativePath(for: item.url) else { return [] }
        // Keep the legacy absolute-path compatibility without asking Foundation to
        // resolve every project directory for every work item while the portfolio
        // table is rendering.  Discovery URLs are lexical paths under this workspace.
        let legacyPath = item.url.path
        return workItems.filter { $0.projectPath == path || $0.projectPath == legacyPath }
    }

    func projectNextAction(for item: WorkspaceItem) -> WorkItem? {
        WorkItemRecommendation.nextAction(in: projectWorkItems(for: item), allItems: workItems)
    }

    func projectAudit(for item: WorkspaceItem) -> ProjectAuditAssessment? {
        guard let record = projectRecord(for: item) else { return nil }
        return try? ProjectAuditStore(database: database).assessment(for: record.id)
    }

    func projectNextAction(for item: WorkspaceItem, audience: WorkActionAudience) -> WorkItem? {
        WorkItemRecommendation.nextAction(in: projectWorkItems(for: item), allItems: workItems, audience: audience)
    }

    func portfolioCandidates() -> [ProjectPortfolio.Candidate] {
        let preferences = scoringPreferences()
        return projects().compactMap { portfolioCandidate(for: $0, preferences: preferences) }
    }

    /// One project's candidate. Every call reads the database and scans work items, so
    /// callers building many rows use this per row rather than `portfolioCandidates()`
    /// per row — that was quadratic, and froze Projects → Decide for minutes.
    func portfolioCandidate(for item: WorkspaceItem, preferences: ProjectScoringPreferences) -> ProjectPortfolio.Candidate? {
        guard let record = projectRecord(for: item) else { return nil }
        let age = measurements(for: item)?.measurement(.activityAge)?.rawValue
            ?? measurements(for: item)?.measurement(.activityAge)?.value
        return ProjectPortfolio.Candidate(id: record.id, name: item.displayTitle, metadata: projectMetadata(for: item),
                                          score: score(for: item, preferences: preferences), nextAction: projectNextAction(for: item),
                                          activityAgeDays: age)
    }

    func portfolioProject(for candidate: ProjectPortfolio.Candidate) -> WorkspaceItem? {
        guard let record = projectStore.record(id: candidate.id) else { return nil }
        return projects().first { $0.url.canonicalPath == record.lastPath }
    }
}
