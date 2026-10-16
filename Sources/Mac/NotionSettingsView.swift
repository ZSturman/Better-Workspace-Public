import SwiftUI
import BetterWorkspaceCore

/// Notion, entirely optional, in one place.
///
/// Project data uses reviewed bidirectional sync. Legacy portable-record and
/// social-post migrations remain separate, previewed operations.
struct NotionSettingsSection: View {
    @Environment(AppModel.self) private var model

    @State private var token = ""
    @State private var settings = NotionSettings.load()
    @State private var fingerprint = SecretStore.fingerprint()
    @State private var includeTasks = true
    @State private var includeMilestoneTasks = true
    @State private var includeCompletedTasks = false
    @State private var includeMilestones = true
    @State private var includeFeatures = true
    @State private var includeIdeas = true
    @State private var includeSocialPosts = true
    @State private var showingDatabases = false
    @State private var showingMappingReview = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.snug) {
            Text("Optional. Nothing is sent to or taken from Notion without your review.")
                .font(.caption).foregroundStyle(.secondary)

            tokenRow
            DisclosureGroup("Databases", isExpanded: $showingDatabases) { databaseFields }
                .font(.caption)
            NotionProjectIntegrationView()
            DisclosureGroup("Legacy portable-file migration") { importRow }
        }
        .sheet(isPresented: $showingMappingReview) {
            NotionProjectMappingReview()
        }
    }

    // MARK: - Token

    @ViewBuilder
    private var tokenRow: some View {
        if let fingerprint {
            HStack(spacing: Theme.Space.tight) {
                Image(systemName: "key.fill").foregroundStyle(.green).font(.system(size: 10))
                Text("Integration token stored (\(fingerprint))").font(.caption)
                Spacer()
                Button("Remove") {
                    SecretStore.remove()
                    self.fingerprint = nil
                }
            }
        } else {
            HStack(spacing: Theme.Space.tight) {
                SecureField("Notion integration secret", text: $token)
                    .textFieldStyle(.roundedBorder)
                Button("Save") {
                    guard SecretStore.save(token) else { return }
                    token = ""
                    fingerprint = SecretStore.fingerprint()
                    // With databases still undecided, the obvious next step is finding
                    // them. A field someone deliberately cleared stays cleared.
                    guard settings.undecided.isEmpty == false else { return }
                    Task { @MainActor in
                        await model.discoverNotionDatabases(onlyUndecided: true)
                        settings = NotionSettings.load()
                    }
                }
                .disabled(token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    // MARK: - Databases

    private var databaseFields: some View {
        VStack(alignment: .leading, spacing: 4) {
            field("Tasks", get: { settings.databases.tasks }, set: { settings.databases.tasks = $0 })
            field("Milestones", get: { settings.databases.milestones }, set: { settings.databases.milestones = $0 })
            field("Features", get: { settings.databases.features }, set: { settings.databases.features = $0 })
            field("Ideas", get: { settings.databases.ideas }, set: { settings.databases.ideas = $0 })
            field("Projects", get: { settings.databases.projects }, set: { settings.databases.projects = $0 })
            field("Social Posts", get: { settings.databases.socialPosts }, set: { settings.databases.socialPosts = $0 })
            Button("Find Shared Databases") {
                Task { @MainActor in
                    await model.discoverNotionDatabases()
                    settings = NotionSettings.load()
                }
            }
            .disabled(model.hasNotionToken == false || model.notionBusy)
            .help("Fills empty fields with the shared databases named Tasks, Milestones, Features, Ideas, Projects and Social Posts.")
            Text("The supplied Features, Milestones and Social Posts databases are prefilled. Each is optional — leave one blank to skip it. "
                 + "Importing a feature or milestone requires its Notion project to already be linked to a local project.")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 4)
    }

    private func field(_ label: String, get: @escaping () -> String?, set: @escaping (String?) -> Void) -> some View {
        LabeledContent(label) {
            TextField("Database ID", text: Binding(
                get: { get() ?? "" },
                set: { value in
                    // A pasted database URL is reduced to its id; anything that is not
                    // recognisably an id is kept as typed so the field never fights back.
                    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                    set(trimmed.isEmpty ? nil : (NotionSettings.databaseID(from: trimmed) ?? trimmed))
                    settings.save()
                }
            ))
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 11, design: .monospaced))
        }
    }

    // MARK: - Import

    @ViewBuilder
    private var importRow: some View {
        if let plan = model.notionPlan {
            VStack(alignment: .leading, spacing: 3) {
                Text(plan.summary).font(.caption.weight(.medium))
                Text("\(plan.openTaskCount) open tasks, \(plan.milestones.count) milestones, "
                     + "\(plan.features.count) features, \(plan.ideas.count) ideas and "
                     + "\(plan.socialPosts.count) social posts found.")
                    .font(.caption).foregroundStyle(.secondary)
                if plan.completedTaskCount > 0 {
                    Text("\(plan.completedTaskCount) completed tasks included.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(plan.warnings, id: \.self) { warning in
                    Text(warning).font(.caption).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let review = model.notionMappingReview {
                    Button("Review \(review.groups.count) unresolved Notion projects") {
                        showingMappingReview = true
                    }
                    .font(.caption)
                    .accessibilityIdentifier("notion.reviewMappings")
                }
            }
        }

        VStack(alignment: .leading, spacing: 3) {
            Toggle("Import tasks", isOn: $includeTasks).font(.caption)
            if includeTasks {
                Toggle("Include completed tasks", isOn: $includeCompletedTasks)
                    .font(.caption)
                    .help("There are far more finished tasks than open ones. Off by default.")
            }
            Toggle("Import milestones", isOn: $includeMilestones).font(.caption)
            if includeMilestones {
                Toggle("Also import their tasks", isOn: $includeMilestoneTasks)
                    .font(.caption)
                    .help("Imports only tasks directly attached to milestones selected by this same preview when the full task import is off.")
            }
            Toggle("Import features", isOn: $includeFeatures).font(.caption)
            Toggle("Import ideas", isOn: $includeIdeas).font(.caption)
            Toggle("Import social posts", isOn: $includeSocialPosts).font(.caption)
        }

        HStack(spacing: Theme.Space.tight) {
            Button("Check What Would Import") {
                Task { @MainActor in
                    var options = NotionImport.Options()
                    options.includeTasks = includeTasks
                    options.includeTasksLinkedToIncludedMilestones = includeMilestoneTasks
                    options.includeCompletedTasks = includeCompletedTasks
                    options.includeMilestones = includeMilestones
                    options.includeFeatures = includeFeatures
                    options.includeIdeas = includeIdeas
                    options.includeIdeaProjects = includeIdeas
                    options.includeSocialPosts = includeSocialPosts
                    await model.planNotionImport(options: options)
                }
            }
            .disabled(model.hasNotionToken == false || settings.isConfigured == false || model.notionBusy)

            Button("Import") {
                Task { @MainActor in await model.applyNotionImport() }
            }
            .disabled(model.notionPlan == nil || model.notionBusy)

            if model.notionBusy { ProgressView().controlSize(.small) }
        }

        if model.hasNotionToken == false {
            Text("Add an integration token to enable the import.")
                .font(.caption).foregroundStyle(.tertiary)
        }
    }
}

/// Makes the conservative part of the migration visible.  The automatic matcher
/// intentionally stays exact-only; this sheet is where a person can make the one
/// decision it cannot safely infer.  A choice is saved in local app metadata and the
/// already-fetched preview is re-planned without contacting Notion again.
private struct NotionProjectMappingReview: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var localProjectFilter = ""
    @State private var choices: [String: String] = [:]
    @State private var skipped = Set<String>()

    private var review: AppModel.NotionMappingReview? { model.notionMappingReview }

    private var candidateProjects: [ProjectRecord] {
        guard let review else { return [] }
        let query = localProjectFilter.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.isEmpty == false else { return review.localProjectCandidates }
        return review.localProjectCandidates.filter {
            $0.name.localizedCaseInsensitiveContains(query)
                || $0.lastPath.localizedCaseInsensitiveContains(query)
        }
    }

    private var visibleGroups: [NotionImport.UnresolvedProjectGroup] {
        review?.groups.filter { skipped.contains($0.id) == false } ?? []
    }

    /// A native Picker eagerly materializes every project for every unresolved group.
    /// Large workspaces therefore create thousands of AppKit menu rows before the
    /// person has asked to choose one. The menu below is opened only for the row being
    /// mapped, and the shared filter keeps its bounded list useful.
    private var displayedCandidates: [ProjectRecord] { Array(candidateProjects.prefix(50)) }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.loose) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Link unresolved Notion projects").font(.title3.weight(.semibold))
                    Text("Map a Notion project once to restore every listed Feature and Milestone. "
                         + "The app never guesses here; Skip leaves the rows untouched.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button("Done") { dismiss() }
            }

            TextField("Filter local projects", text: $localProjectFilter)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("notion.mappingProjectFilter")

            if visibleGroups.isEmpty {
                ContentUnavailableView("Everything in this preview is mapped",
                                        systemImage: "checkmark.circle",
                                        description: Text("Run the import when you are ready."))
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: Theme.Space.snug) {
                        ForEach(visibleGroups) { group in
                            mappingCard(group)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .padding(Theme.Space.loose)
        .frame(minWidth: 640, idealWidth: 760, minHeight: 460, idealHeight: 620)
    }

    @ViewBuilder
    private func mappingCard(_ group: NotionImport.UnresolvedProjectGroup) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: Theme.Space.tight) {
                HStack(alignment: .firstTextBaseline) {
                    Text(group.notionProjectName ?? "Unnamed Notion project")
                        .font(.headline)
                    Spacer()
                    Text(group.notionProjectID)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
                ForEach(group.items) { item in
                    HStack(alignment: .top, spacing: Theme.Space.tight) {
                        Image(systemName: item.kind.symbolName)
                            .foregroundStyle(.secondary)
                            .frame(width: 14)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("\(item.kind.displayName): \(item.title)").font(.caption.weight(.medium))
                            if let status = item.status, status.isEmpty == false {
                                Text(status).font(.caption2).foregroundStyle(.secondary)
                            }
                            if let detail = item.detail, detail.isEmpty == false {
                                Text(detail).font(.caption2).foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                        }
                    }
                }
                Divider()
                HStack {
                    Menu {
                        if candidateProjects.count > displayedCandidates.count {
                            Text("Showing the first \(displayedCandidates.count). Refine the filter to find another project.")
                        }
                        ForEach(displayedCandidates) { project in
                            Button(project.name) { choices[group.id] = project.id }
                        }
                    } label: {
                        let selected = choices[group.id].flatMap { id in
                            review?.localProjectCandidates.first(where: { $0.id == id })?.name
                        }
                        Label(selected ?? "Choose a local project", systemImage: "folder")
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("notion.chooseProject")
                    Button("Map") {
                        guard let choice = choices[group.id], choice.isEmpty == false else { return }
                        Task { @MainActor in await model.mapNotionProject(group.notionProjectID, to: choice) }
                    }
                    .disabled((choices[group.id] ?? "").isEmpty || model.notionBusy)
                    .accessibilityIdentifier("notion.mapProject")
                    Button("Skip") { skipped.insert(group.id) }
                        .accessibilityIdentifier("notion.skipProject")
                }
                if candidateProjects.isEmpty {
                    Text("No unlinked local projects match this filter. Clear it or create/link a project first.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 2)
        } label: {
            Text("Notion Project")
        }
    }

}
