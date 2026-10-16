import Foundation
import BetterWorkspaceCore

/// One-time migrations, run from a terminal against the app's own store and keychain.
///
/// The Settings window can do all of this, but a migration out of two other apps is
/// something a person wants to rehearse, read the numbers of, run, and then check —
/// and the checking part is not something a button gives you. This runs the same core
/// code the Settings window calls, then reads the result back from disk.
///
/// It lives in the app binary rather than in a separate tool because the Notion token
/// is a keychain item this app created: another binary asking for it would prompt.
///
///     "Better Workspace.app/Contents/MacOS/Better Workspace" --migrate notion-plan
///
/// `--service status|install|uninstall` manages the background service's launch agent.
///
/// Commands: `notion-discover`, `notion-schema`, `notion-plan`, `notion-apply`, `legacy-plan`,
/// `legacy-apply`, `link-notion <path> <page id>`, `status`. `--include-completed` brings finished tasks too;
/// `--planning-only` limits a Notion import to tasks, milestones and features;
/// `--notion-project <page id>` imports only one project's connected planning graph;
/// `--upgrade-legacy-imports` rewrites earlier, provenance-less imports nobody has edited;
/// `--include-unlinked` imports milestones and features whose Notion project has no local
/// folder, unattached, instead of leaving them in Notion. Nothing
/// writes unless the command name ends in `-apply` (or `-discover`, which saves only
/// database ids to preferences).
enum MigrationCommand {

    static func runIfRequested(arguments: [String] = CommandLine.arguments) {
        if let flag = arguments.firstIndex(of: "--service") {
            let command = arguments.indices.contains(flag + 1) ? arguments[flag + 1] : "status"
            if command == "verify-install" {
                let semaphore = DispatchSemaphore(value: 0)
                var code: Int32 = 0
                Task.detached { code = await BackgroundServiceInstallCheck.run(keep: arguments.contains("--keep")); semaphore.signal() }
                semaphore.wait()
                exit(code)
            }
            exit(service(command))
        }
        guard let flag = arguments.firstIndex(of: "--migrate") else { return }
        let command = arguments.indices.contains(flag + 1) ? arguments[flag + 1] : "status"
        let includeCompleted = arguments.contains("--include-completed")
        let planningOnly = arguments.contains("--planning-only")
        let upgradeLegacy = arguments.contains("--upgrade-legacy-imports")
        let includeUnlinked = arguments.contains("--include-unlinked")
        let notionProjectID = arguments.firstIndex(of: "--notion-project").flatMap { index in
            arguments.indices.contains(index + 1) ? arguments[index + 1] : nil
        }
        let operands = Array(arguments.dropFirst(flag + 2).filter { $0.hasPrefix("--") == false })

        let semaphore = DispatchSemaphore(value: 0)
        var code: Int32 = 0
        Task.detached {
            code = await run(command, includeCompleted: includeCompleted, planningOnly: planningOnly,
                             upgradeLegacy: upgradeLegacy, includeUnlinked: includeUnlinked,
                             notionProjectID: notionProjectID, operands: operands)
            semaphore.signal()
        }
        semaphore.wait()
        exit(code)
    }

    private static func say(_ line: String) {
        FileHandle.standardOutput.write(Data((line + "\n").utf8))
    }

    private static func run(_ command: String, includeCompleted: Bool, planningOnly: Bool = false,
                            upgradeLegacy: Bool = false, includeUnlinked: Bool = false,
                            notionProjectID: String? = nil,
                            operands: [String] = []) async -> Int32 {
        let workspace = WorkspaceLocation.resolved
        let opened = Database.opened(preferring: Database.preferredURL())
        let projectStore = ProjectStore(database: opened.database)
        let folders = WorkspaceFolderDiscovery().folders(
            in: workspace, store: AreaConfigurationStore(url: AreaConfigurationStore.defaultURL())
        ) ?? []
        let service = WorkItemService()
        say("Workspace: \(workspace.root.path)")

        switch command {
        case "status":
            report(service.items(under: workspace.root))
            say("Projects known: \(projectStore.allRecords().count), "
                + "with Notion link: \(projectStore.allRecords().filter(\.hasNotionLink).count)")
            say("Notion token stored: \(SecretStore.hasNotionToken ? "yes" : "no"); "
                + "databases configured: \(NotionSettings.load().isConfigured ? "yes" : "no")")
            return 0

        case "notion-discover":
            guard let token = SecretStore.read() else { return noToken() }
            do {
                let found = try await NotionClient(token: token).searchDatabases()
                let settings = NotionSettings.load().filled(from: found)
                settings.save()
                say("Shared databases: " + found.map { "\($0.title) (\(NotionImport.normalizedID($0.id)))" }
                    .joined(separator: ", "))
                describe(settings)
                return 0
            } catch {
                say("Failed: \(error.localizedDescription)")
                return 1
            }

        case "notion-schema":
            guard let token = SecretStore.read() ?? BackgroundServiceAgent().notionToken() else { return noToken() }
            guard let projectID = NotionSettings.load().databases.projects else {
                say("No Projects database configured.")
                return 1
            }
            do {
                let database = try await NotionClient(token: token).database(projectID)
                say("\(database.title): \(database.propertyNames.count) properties")
                for name in database.propertyNames {
                    say("  \(name) — \(database.propertyTypes[name] ?? "unknown")")
                }
                return 0
            } catch {
                say("Failed: \(error.localizedDescription)")
                return 1
            }

        case "notion-plan", "notion-apply":
            guard let token = SecretStore.read() ?? BackgroundServiceAgent().notionToken() else { return noToken() }
            let settings = NotionSettings.load()
            describe(settings)
            guard settings.isConfigured else {
                say("No databases configured. Run notion-discover first.")
                return 1
            }
            let client = NotionClient(token: token)
            var source = NotionImport.Source()
            var failed = false
            func fetch(_ id: String?, _ label: String) async -> [NotionPage] {
                guard let id else { return [] }
                do {
                    let (pages, complete) = try await client.allPages(inDatabase: id)
                    if complete == false { source.truncated.append(label) }
                    say("Read \(pages.count) rows from \(label)")
                    return pages
                } catch {
                    say("\(label): \(error.localizedDescription)")
                    failed = true
                    return []
                }
            }
            source.tasks = await fetch(settings.databases.tasks, "Tasks")
            source.milestones = await fetch(settings.databases.milestones, "Milestones")
            source.features = await fetch(settings.databases.features, "Features")
            source.projects = await fetch(settings.databases.projects, "Projects")
            if planningOnly == false && notionProjectID == nil {
                source.ideas = await fetch(settings.databases.ideas, "Ideas")
                source.socialPosts = await fetch(settings.databases.socialPosts, "Social Posts")
            }
            if let notionProjectID {
                source = NotionImport.scopedSource(source, toProjectID: notionProjectID)
                say("Scoped to Notion project \(NotionImport.normalizedID(notionProjectID))")
            }
            // A database that could not be read is not a database with no rows. Applying
            // a plan built from a partial read would look complete and not be.
            if failed && command == "notion-apply" {
                say("Not applying: at least one database could not be read.")
                return 1
            }

            var options = NotionImport.Options()
            options.includeCompletedTasks = includeCompleted
            options.upgradeLegacyImports = upgradeLegacy
            options.includeUnlinkedPlanning = includeUnlinked
            if planningOnly || notionProjectID != nil {
                options.includeIdeas = false
                options.includeIdeaProjects = false
                options.includeSocialPosts = false
            }
            // The same deterministic links the Settings import proposes: an exact Local
            // Directory, or a Notion title naming exactly one local project. Recorded
            // only on apply, and never replacing an existing link.
            let records = projectStore.allRecords()
            let resolution = NotionImport.resolveProjectLinks(
                notionProjects: source.projects, localProjects: records, workspaceRoot: workspace.root
            )
            var byNotionID = Dictionary(
                records.compactMap { record in record.notionPageID.map { (NotionImport.normalizedID($0), record) } },
                uniquingKeysWith: { first, _ in first }
            )
            let recordsByID = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
            for link in resolution.links { if let record = recordsByID[link.projectID] { byNotionID[link.notionPageID] = record } }
            let projectTitles = Dictionary(source.projects.map { (NotionImport.normalizedID($0.id), $0.title ?? "?") },
                                           uniquingKeysWith: { first, _ in first })

            let existing = service.items(under: workspace.root)
            let ideasFolder = workspace.url(for: .ideas)
            let ideaNames = Set((try? FileManager.default.contentsOfDirectory(atPath: ideasFolder.path)) ?? [])
            let plan = NotionImport.plan(
                from: source, options: options,
                destinations: .init(workspace: workspace, folders: folders),
                projectsByNotionID: byNotionID, existingWorkItems: existing, existingIdeaNames: ideaNames,
                projectLinks: resolution.links
            )
            say(plan.summary)
            say("  tasks: \(plan.tasks.count) (\(plan.openTaskCount) open, \(plan.completedTaskCount) completed), "
                + "milestones: \(plan.milestones.count), features: \(plan.features.count), ideas: \(plan.ideas.count)")
            say("  with a project: \(plan.workItems.filter { $0.item.projectPath != nil }.count) of \(plan.workItems.count)")
            say("  already present: \(plan.workItems.filter(\.alreadyPresent).count); to refresh (unedited, changed in Notion): "
                + "\(plan.refreshCount); kept because edited here: \(plan.keptLocalEditsCount)")
            say("  new project links: \(resolution.links.count); Notion projects with no unique local match: \(resolution.unmatchedCount)")
            for link in resolution.links {
                say("    link: \(projectTitles[link.notionPageID] ?? link.notionPageID) → \(recordsByID[link.projectID]?.name ?? "?")")
            }
            // Planning rows that cannot attach to a local project, by the Notion project
            // they name, so a person can see exactly what is left in Notion and why.
            func unattached(_ pages: [NotionPage], planned: [NotionImport.PlannedWorkItem]) -> [String: Int] {
                let plannedIDs = Set(planned.map(\.item.id))
                var counts: [String: Int] = [:]
                for page in pages where plannedIDs.contains(NotionImport.normalizedID(page.id)) == false {
                    let project = NotionImport.Fields(page).relations(NotionImport.Alias.project).first
                        .map { projectTitles[NotionImport.normalizedID($0)] ?? "(unknown project)" } ?? "(no project)"
                    counts[project, default: 0] += 1
                }
                return counts
            }
            for (label, pages, planned) in [("features", source.features, plan.features), ("milestones", source.milestones, plan.milestones)] {
                let left = unattached(pages, planned: planned)
                if left.isEmpty == false {
                    say("  \(label) not imported, by Notion project: " + left.sorted { $0.key < $1.key }.map { "\($0.key) (\($0.value))" }.joined(separator: "; "))
                }
            }
            plan.warnings.forEach { say("  warning: \($0)") }
            guard command == "notion-apply" else { return failed ? 1 : 0 }

            let links = resolution.links.filter { recordsByID[$0.projectID]?.notionPageID == nil }
            for link in links { projectStore.setNotionPageID(link.notionPageID, for: link.projectID) }
            let result = NotionImport.apply(plan, using: service)
            say("Linked \(links.count) projects. Created \(result.workItemsCreated) work items, refreshed \(result.workItemsRefreshed), \(result.ideasCreated) ideas, "
                + "\(result.socialPostsCreated) social posts; \(result.skippedExisting) already present")
            result.failures.forEach { say("  failed: \($0)") }

            // The check that matters: read back from disk, as the app will on launch.
            let onDisk = Dictionary(service.items(under: workspace.root).map { ($0.id, $0) },
                                    uniquingKeysWith: { first, _ in first })
            let missing = plan.workItems.filter { onDisk[$0.item.id] == nil }
            // Everything this run wrote must read back exactly as planned; untouched
            // items must still be unedited. The content hash covers every written field.
            let drifted = plan.workItems.filter { planned in
                guard let stored = onDisk[planned.item.id], planned.keptLocalEdits == false else { return false }
                guard planned.alreadyPresent == false || planned.replacing != nil else { return false }
                return NotionImport.contentHash(stored) != NotionImport.contentHash(planned.item)
            }
            report(Array(onDisk.values))
            say("Verified on disk: \(plan.workItems.count - missing.count) of \(plan.workItems.count) planned; "
                + "\(drifted.count) differ from the plan")
            missing.prefix(10).forEach { say("  missing: \($0.item.title)") }
            drifted.prefix(10).forEach { say("  differs: \($0.item.title)") }
            return missing.isEmpty && drifted.isEmpty && result.failures.isEmpty ? 0 : 1

        case "legacy-plan", "legacy-apply":
            let apply = command == "legacy-apply"
            let documents = LegacyImport.scanDocuments(in: workspace.url(for: .projects))
            let docs = LegacyImport.importDocuments(documents, into: projectStore, apply: apply)
            let ratings = LegacyImport.importRatings(into: projectStore, apply: apply)
            say("Documents: \(docs.discovered), registered: \(docs.imported), "
                + "Notion links recovered: \(docs.notionLinksRecovered), conflicts: \(docs.conflicts.count), "
                + "missing directories: \(docs.skippedMissingDirectory.count)")
            say("Ratings: \(ratings.projectsWithRatings) rated projects in the cache, "
                + "\(ratings.matchedToLocalProject) matched, \(ratings.ratingsWritten) ratings "
                + (apply ? "written" : "would be written"))
            ratings.unmatchedNotionIDs.forEach { say("  unmatched rated Notion project: \($0)") }
            if ratings.keptExisting > 0 { say("  \(ratings.keptExisting) ratings already set here were left alone") }
            let descriptions = LegacyImport.importDescriptions(into: projectStore, apply: apply)
            say("Descriptions: \(descriptions.described) projects " + (apply ? "described" : "would be described")
                + ", \(descriptions.pendingEditsApplied) unsent Better Projects edits " + (apply ? "applied, " : "would be applied, ")
                + "\(descriptions.keptExisting) fields already set kept")
            descriptions.pendingEditsUnmatched.forEach { say("  unsent edit with no matching project: \($0)") }
            return 0

        case "link-notion":
            // `link-notion <workspace-relative project path> <notion page id>`: records the
            // Notion page a project folder corresponds to, when no document recorded it.
            guard operands.count == 2 else {
                say("Usage: --migrate link-notion \"Projects/<folder>\" <notion page id>")
                return 2
            }
            let url = workspace.root.appendingPathComponent(operands[0])
            guard FileManager.default.fileExists(atPath: url.path) else { say("No folder at \(url.path)"); return 1 }
            let pageID = NotionImport.normalizedID(operands[1])
            if let other = projectStore.record(notionPageID: pageID) ?? projectStore.allRecords()
                .first(where: { $0.notionPageID.map(NotionImport.normalizedID) == pageID }),
               other.url.canonicalPath != url.canonicalPath {
                say("That Notion page is already linked to \(other.lastPath)")
                return 1
            }
            let record = projectStore.record(for: url) ?? projectStore.register(url: url)
            if let existing = record.notionPageID, NotionImport.normalizedID(existing) != pageID {
                say("\(operands[0]) is already linked to \(existing); not changed")
                return 1
            }
            projectStore.setNotionPageID(operands[1], for: record.id)
            say("Linked \(operands[0]) to Notion page \(operands[1]). Run legacy-apply to bring its ratings and description.")
            return 0

        default:
            say("Unknown migration command “\(command)”.")
            return 2
        }
    }

    /// `--service status` / `--service install`: the background service's launch agent,
    /// through the same `BackgroundServiceAgent` the Settings button uses.
    private static func service(_ command: String) -> Int32 {
        let agent = BackgroundServiceAgent()
        func show() {
            let status = agent.status()
            say("Installed program: \(status.runningProgram ?? "none")"
                + (status.runsFromLegacyCheckout ? " (still the Workspace Watcher checkout; install moves it)" : ""))
            say("Bundled service in this app: \(status.bundledServicePresent ? "yes" : "no"); "
                + "install location: \(agent.layout.home.path)")
            say("Installed code matches this app: " + (status.codeMatchesBundle.map { $0 ? "yes" : "no (run --service install to update)" } ?? "unknown"))
            say("Agent: \(agent.plistURL.path) — \(status.installed ? "installed" : "not installed"), "
                + "\(status.loaded ? "loaded" : "not loaded")\(status.pid.map { ", pid \($0)" } ?? "")")
            say("Launched by: \(status.owner)")
            say("Workspace Watcher daemon agent loaded: \(status.legacyDaemonLoaded), "
                + "menu bar agent loaded: \(status.legacyMenuBarLoaded)")
        }
        switch command {
        case "status":
            show()
            return 0
        case "install":
            do {
                try agent.install()
                say("Installed \(BackgroundServiceAgent.label).")
                show()
                return 0
            } catch {
                say("Failed: \(error.localizedDescription)")
                show()
                return 1
            }
        case "uninstall":
            // Stops the service and removes its login item. Its data, configuration and
            // installed program stay, so `install` brings it straight back.
            agent.uninstall()
            say("Removed \(BackgroundServiceAgent.label). Data in \(agent.logDirectory.path) and "
                + "configuration in \(agent.layout.home.path) are kept.")
            show()
            return 0
        default:
            say("Unknown service command “\(command)”. Use status, install, uninstall or verify-install [--keep].")
            return 2
        }
    }

    private static func noToken() -> Int32 {
        say("No Notion token in Better Workspace's keychain. Add it in Settings → Notion first.")
        return 1
    }

    private static func describe(_ settings: NotionSettings) {
        let d = settings.databases
        say("Databases — tasks: \(d.tasks ?? "–"), milestones: \(d.milestones ?? "–"), "
            + "features: \(d.features ?? "–"), ideas: \(d.ideas ?? "–"), projects: \(d.projects ?? "–")")
    }

    private static func report(_ items: [WorkItem]) {
        let counts = Dictionary(grouping: items, by: \.kind).mapValues(\.count)
        say("Work items on disk: \(items.count) — "
            + WorkItemKind.allCases.map { "\($0.rawValue): \(counts[$0] ?? 0)" }.joined(separator: ", "))
    }
}
