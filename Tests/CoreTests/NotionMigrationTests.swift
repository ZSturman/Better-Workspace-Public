import XCTest
@testable import BetterWorkspaceCore

/// The Notion migration as it meets the real databases: names that differ by case and
/// by database, ids pasted as URLs, and the whole fetch → plan → write → read-back path.
final class NotionMigrationTests: XCTestCase {

    private func page(_ id: String, title: String, _ extra: [String: NotionValue] = [:]) -> NotionPage {
        var properties: [String: NotionValue] = ["Name": .title(title)]
        properties.merge(extra) { _, new in new }
        return NotionPage(id: id, url: URL(string: "https://notion.so/\(id)"), properties: properties)
    }

    private func tempRoot() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("bw-notion-migration-\(UUID().uuidString)")
    }

    private func destinations(_ root: URL) -> NotionImport.Destinations {
        .init(tasks: root.appendingPathComponent("To Do"), milestones: root.appendingPathComponent("Milestones"),
              features: root.appendingPathComponent("Features"), ideas: root.appendingPathComponent("Ideas"))
    }

    /// Each database spells its fields its own way. A name the import misses is a field
    /// silently dropped from every row, so every one of these must land.
    func testFieldsAreFoundWhateverEachDatabaseCallsThem() {
        var source = NotionImport.Source()
        source.tasks = [page("t1", title: "Task", [
            "Projects": .relations(["p-1"]),
            "Milestones": .relations(["m-1"]),
            "Features": .relations(["f-1"]),
            "Status": .choice("In Progress"),
            "Priority": .choice("High"),
            "Description": .text("What to do"),
            "Due Date": .date("2026-10-30"),
        ])]
        source.milestones = [page("m1", title: "Milestone", [
            "Project": .relations(["p-1"]),
            "Feature": .relations(["f-1"]),
            "Tasks": .relations(["t-1"]),
            "Due Date (Manual)": .date("2026-11-01"),
            "Summary": .text("Why it matters"),
        ])]
        source.features = [page("f1", title: "Feature", [
            "project": .relations(["p-1"]),
            "status": .choice("Active"),
            "Priority": .number(5),
            "Milestones": .relations(["m-1"]),
            "Description": .text("The shape of it"),
        ])]
        let record = ProjectRecord(id: "local", identityKey: nil, lastPath: "/W/Projects/Thing", name: "Thing",
                                   notionPageID: "p-1", watcherID: nil, documentID: nil,
                                   createdAt: Date(), updatedAt: Date())
        let plan = NotionImport.plan(from: source, options: .init(), destinations: destinations(tempRoot()),
                                     projectsByNotionID: ["p1": record], existingWorkItems: [], existingIdeaNames: [])

        let task = plan.tasks.first?.item
        XCTAssertEqual(task?.projectPath, "/W/Projects/Thing")
        XCTAssertEqual(task?.parentID, "m1")
        XCTAssertEqual(task?.relatedIDs, ["f1"], "A task's feature is kept as a relation")
        XCTAssertEqual(task?.status, .inProgress)
        XCTAssertEqual(task?.priority, .high)
        XCTAssertNotNil(task?.dueDate)
        XCTAssertTrue(task?.body.contains("What to do") == true)

        let milestone = plan.milestones.first?.item
        XCTAssertEqual(milestone?.projectPath, "/W/Projects/Thing")
        XCTAssertEqual(milestone?.parentID, "f1")
        XCTAssertEqual(milestone?.relatedIDs, ["t1"])
        XCTAssertNotNil(milestone?.dueDate)
        XCTAssertTrue(milestone?.body.contains("Why it matters") == true)

        let feature = plan.features.first?.item
        XCTAssertEqual(feature?.projectPath, "/W/Projects/Thing")
        XCTAssertEqual(feature?.status, .inProgress)
        XCTAssertEqual(feature?.priority, .high)
        XCTAssertEqual(feature?.relatedIDs, ["m1"])
        XCTAssertTrue(feature?.body.contains("The shape of it") == true)
        XCTAssertTrue(plan.warnings.isEmpty, "\(plan.warnings)")
    }

    func testAnEmptyFieldDoesNotHideAFilledAlias() {
        var source = NotionImport.Source()
        source.tasks = [page("t1", title: "Task", ["Details": .text(""), "Notes": .text("The real note"),
                                                   "Milestone": .relations([]), "Milestones": .relations(["m-9"])])]
        let plan = NotionImport.plan(from: source, options: .init(), destinations: destinations(tempRoot()),
                                     projectsByNotionID: [:], existingWorkItems: [], existingIdeaNames: [])
        XCTAssertTrue(plan.tasks.first?.item.body.contains("The real note") == true)
        XCTAssertEqual(plan.tasks.first?.item.parentID, "m9")
    }

    func testOneSidedNotionRelationsStillProduceAConnectedPlanningGraph() {
        var source = NotionImport.Source()
        source.tasks = [page("task-1", title: "Task", ["Project": .relations(["project-1"])])]
        source.milestones = [page("mile-1", title: "Milestone", [
            "Project": .relations(["project-1"]), "Tasks": .relations(["task-1"]),
        ])]
        source.features = [page("feature-1", title: "Feature", [
            "Project": .relations(["project-1"]), "Milestones": .relations(["mile-1"]),
            "Tasks": .relations(["task-1"]),
        ])]
        let project = ProjectRecord(id: "local-project", identityKey: nil, lastPath: "/W/Projects/Connected",
                                    name: "Connected", notionPageID: "project-1", watcherID: nil,
                                    documentID: nil, createdAt: Date(), updatedAt: Date())

        let plan = NotionImport.plan(from: source, options: .init(), destinations: destinations(tempRoot()),
                                     projectsByNotionID: ["project1": project], existingWorkItems: [], existingIdeaNames: [])

        XCTAssertEqual(plan.tasks.first?.item.parentID, "mile1")
        XCTAssertEqual(plan.tasks.first?.item.relatedIDs, ["feature1"])
        XCTAssertEqual(plan.milestones.first?.item.parentID, "feature1")
        XCTAssertEqual(plan.milestones.first?.item.relatedIDs, ["task1"])
        XCTAssertEqual(plan.features.first?.item.relatedIDs, ["mile1"])
    }

    func testProjectScopedSourceIncludesOnlyItsConnectedPlanningGraph() {
        var source = NotionImport.Source()
        source.projects = [page("project-1", title: "One"), page("project-2", title: "Two")]
        source.milestones = [
            page("mile-1", title: "One milestone", ["Project": .relations(["project-1"]), "Tasks": .relations(["task-1"])]),
            page("mile-2", title: "Two milestone", ["Project": .relations(["project-2"])]),
        ]
        source.features = [page("feature-1", title: "One feature", ["Project": .relations(["project-1"])])]
        source.tasks = [
            page("task-1", title: "Related only from milestone"),
            page("task-2", title: "Other", ["Project": .relations(["project-2"])])
        ]

        let scoped = NotionImport.scopedSource(source, toProjectID: "project-1")

        XCTAssertEqual(scoped.projects.map(\.id), ["project-1"])
        XCTAssertEqual(scoped.milestones.map(\.id), ["mile-1"])
        XCTAssertEqual(scoped.features.map(\.id), ["feature-1"])
        XCTAssertEqual(scoped.tasks.map(\.id), ["task-1"])
    }

    func testUnresolvedPlanningReviewGroupsFeaturesAndMilestonesByNotionProject() throws {
        var source = NotionImport.Source()
        source.projects = [page("project-1", title: "Desktop Widgets")]
        source.milestones = [page("mile-1", title: "Ship widget", [
            "Project": .relations(["project-1"]), "Status": .choice("In Progress"),
            "Description": .text("Deliver the first version.")
        ])]
        source.features = [page("feature-1", title: "Widgets", [
            "Project": .relations(["project-1"]), "Status": .choice("Planned")
        ])]

        let groups = NotionImport.unresolvedPlanningGroups(
            from: source, linkedNotionProjectIDs: [], options: .init()
        )

        let group = try XCTUnwrap(groups.first)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(group.notionProjectName, "Desktop Widgets")
        XCTAssertEqual(Set(group.items.map(\.kind)), [.feature, .milestone])
        XCTAssertEqual(group.items.first(where: { $0.id == "mile1" })?.detail,
                       "Deliver the first version.")
        XCTAssertTrue(NotionImport.unresolvedPlanningGroups(
            from: source, linkedNotionProjectIDs: ["project1"], options: .init()
        ).isEmpty)
    }

    func testADatabaseIdComesOutOfWhateverIsPasted() {
        let id = "304aec944d3c80d69ec5ff5ced6930fa"
        XCTAssertEqual(NotionSettings.databaseID(from: id), id)
        XCTAssertEqual(NotionSettings.databaseID(from: "304aec94-4d3c-80d6-9ec5-ff5ced6930fa"), id)
        XCTAssertEqual(NotionSettings.databaseID(from: "https://www.notion.so/\(id)?v=abc"), id)
        XCTAssertEqual(NotionSettings.databaseID(from: "https://www.notion.so/team/Tasks-\(id)?v=abc"), id)
        XCTAssertNil(NotionSettings.databaseID(from: "Tasks"))
        XCTAssertNil(NotionSettings.databaseID(from: "  "))
    }

    func testSocialPostsUseTheSuppliedDatabaseUnlessExplicitlyCleared() {
        let suite = "bw-social-post-settings-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertEqual(NotionSettings.load(from: defaults).databases.socialPosts,
                       NotionSettings.suppliedSocialPostsDatabaseID)
        var settings = NotionSettings.load(from: defaults)
        settings.databases.socialPosts = nil
        settings.save(to: defaults)
        XCTAssertNil(NotionSettings.load(from: defaults).databases.socialPosts)
    }

    func testSocialPostsBecomeOnePortableFileAndLegacyDatesDoNotScheduleThem() {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        var source = NotionImport.Source()
        source.socialPosts = [
            page("legacy-post", title: "Legacy post", [
                "platform": .choices(["LinkedIn", "BlueSky"]),
                "content": .text("A full LinkedIn draft"),
                "content short": .text("A shorter Bluesky draft"),
                "post date": .date("2027-01-01T10:00:00Z"),
            ]),
            page("scheduled-post", title: "Scheduled post", [
                "scheduled": .flag(true),
                "post date": .date("2026-10-02T15:00:00Z"),
                "posted": .flag(false),
                "LinkedIn URL": .text("https://linkedin.example/post"),
            ]),
            page("published-post", title: "Published post", [
                "posted": .flag(true),
                "Bluesky URL": .text("https://bsky.app/profile/example/post/1"),
            ]),
        ]
        let destinations = NotionImport.Destinations(
            tasks: root.appendingPathComponent("To Do"), milestones: root.appendingPathComponent("Milestones"),
            features: root.appendingPathComponent("Features"), ideas: root.appendingPathComponent("Ideas"),
            socialPosts: root.appendingPathComponent("Social Posts")
        )
        let plan = NotionImport.plan(from: source, options: .init(), destinations: destinations,
                                     projectsByNotionID: [:], existingWorkItems: [], existingIdeaNames: [])
        XCTAssertEqual(plan.newSocialPostCount, 3)
        XCTAssertEqual(plan.socialPosts.first { $0.post.id == "legacypost" }?.post.status, .draft)
        XCTAssertNil(plan.socialPosts.first { $0.post.id == "legacypost" }?.post.scheduledAt)
        XCTAssertEqual(plan.socialPosts.first { $0.post.id == "scheduledpost" }?.post.status, .scheduled)
        XCTAssertNotNil(plan.socialPosts.first { $0.post.id == "scheduledpost" }?.post.scheduledAt)
        XCTAssertEqual(plan.socialPosts.first { $0.post.id == "publishedpost" }?.post.status, .posted)

        let result = NotionImport.apply(plan)
        XCTAssertEqual(result.socialPostsCreated, 3)
        let posts = SocialPostService().items(in: destinations.socialPosts)
        XCTAssertEqual(posts.count, 3)
        XCTAssertEqual(posts.first { $0.id == "legacypost" }?.linkedInContent, "A full LinkedIn draft")
        XCTAssertEqual(posts.first { $0.id == "legacypost" }?.blueskyContent, "A shorter Bluesky draft")
    }

    /// Filling by title must never guess between two databases of the same name, and
    /// never replace an id someone chose.
    func testSharedDatabasesFillOnlyEmptyUnambiguousSlots() {
        var settings = NotionSettings()
        settings.databases.projects = "chosen"
        let found = [
            NotionDatabase(id: "aaaa-1", title: "Tasks"),
            NotionDatabase(id: "bbbb-2", title: "Milestones "),
            NotionDatabase(id: "cccc-3", title: "Ideas"),
            NotionDatabase(id: "cccc-4", title: "ideas"),
            NotionDatabase(id: "dddd-5", title: "Projects"),
            NotionDatabase(id: "eeee-6", title: "Work Log"),
        ]
        let filled = settings.filled(from: found)
        XCTAssertEqual(filled.databases.tasks, "aaaa1")
        XCTAssertEqual(filled.databases.milestones, "bbbb2")
        XCTAssertNil(filled.databases.features)
        XCTAssertNil(filled.databases.ideas, "Two databases called Ideas is ambiguous")
        XCTAssertEqual(filled.databases.projects, "chosen")
    }

    func testSuppliedFeatureAndMilestoneDatabasesAreInitialDefaultsOnly() {
        let suite = "bw-notion-settings-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let initial = NotionSettings.load(from: defaults)
        XCTAssertEqual(initial.databases.features, NotionSettings.suppliedFeaturesDatabaseID)
        XCTAssertEqual(initial.databases.milestones, NotionSettings.suppliedMilestonesDatabaseID)

        defaults.set(["tasks": "other-tasks-db"], forKey: NotionSettings.defaultsKey)
        let partial = NotionSettings.load(from: defaults)
        XCTAssertEqual(partial.databases.tasks, "other-tasks-db")
        XCTAssertEqual(partial.databases.features, NotionSettings.suppliedFeaturesDatabaseID)
        XCTAssertEqual(partial.databases.milestones, NotionSettings.suppliedMilestonesDatabaseID)

        NotionSettings(databases: .init()).save(to: defaults)
        let cleared = NotionSettings.load(from: defaults)
        XCTAssertNil(cleared.databases.features)
        XCTAssertNil(cleared.databases.milestones)
    }

    /// A cleared field is a decision. Discovery that runs by itself after a token is
    /// saved must not undo it, while an explicit "find databases" may fill it.
    func testAutomaticDiscoveryLeavesAClearedFieldCleared() {
        let suite = "bw-notion-discovery-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let found = [NotionDatabase(id: "t-1", title: "Tasks"), NotionDatabase(id: "i-1", title: "Ideas"),
                     NotionDatabase(id: "p-1", title: "Projects")]

        let fresh = NotionSettings.load(from: defaults)
        XCTAssertEqual(fresh.undecided, ["tasks", "ideas", "projects"], "Supplied defaults are not undecided")
        let auto = fresh.filled(from: found, onlyUndecided: true)
        XCTAssertEqual(auto.databases.tasks, "t1")
        XCTAssertEqual(auto.databases.ideas, "i1")
        XCTAssertTrue(auto.undecided.isEmpty)

        var cleared = NotionSettings.load(from: defaults)
        cleared.databases.tasks = "chosen"
        cleared.save(to: defaults)               // ideas and projects saved blank: opted out
        let reloaded = NotionSettings.load(from: defaults)
        XCTAssertTrue(reloaded.undecided.isEmpty)
        XCTAssertNil(reloaded.filled(from: found, onlyUndecided: true).databases.ideas)
        XCTAssertEqual(reloaded.filled(from: found).databases.ideas, "i1", "Asking explicitly fills it")
        XCTAssertEqual(reloaded.filled(from: found).databases.tasks, "chosen")
    }

    /// Real idea folders keep the title as written, colon included; a new folder would
    /// drop it. Either spelling means the idea is already here and must not be duplicated.
    func testAnIdeaFolderNamedWithItsExactTitleIsAlreadyPresent() {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        var source = NotionImport.Source()
        source.ideas = [page("i1", title: "Zine: Notes on Attention"), page("i2", title: "Brand new")]
        let plan = NotionImport.plan(from: source, options: .init(), destinations: destinations(root),
                                     projectsByNotionID: [:], existingWorkItems: [],
                                     existingIdeaNames: ["Zine: Notes on Attention"])
        XCTAssertEqual(plan.ideas.filter { $0.alreadyPresent == false }.map(\.title), ["Brand new"])
    }

    func testFeatureAndMilestoneWithoutALocalProjectLinkAreSkipped() {
        var source = NotionImport.Source()
        source.features = [page("f1", title: "Feature", ["Project": .relations(["missing-project"])])]
        source.milestones = [page("m1", title: "Milestone", ["project": .relations(["missing-project"])])]

        let plan = NotionImport.plan(from: source, options: .init(), destinations: destinations(tempRoot()),
                                     projectsByNotionID: [:], existingWorkItems: [], existingIdeaNames: [])

        XCTAssertTrue(plan.features.isEmpty)
        XCTAssertTrue(plan.milestones.isEmpty)
        XCTAssertTrue(plan.warnings.contains { $0.contains("features were skipped") })
        XCTAssertTrue(plan.warnings.contains { $0.contains("milestones were skipped") })
    }

    func testMilestoneOnlyTaskImportBringsJustItsCompanionTasks() {
        var source = NotionImport.Source()
        source.milestones = [page("m1", title: "Milestone", ["Project": .relations(["p1"])])]
        source.tasks = [
            page("attached", title: "Attached task", ["Milestone": .relations(["m1"])]),
            page("other", title: "Unrelated task", ["Milestone": .relations(["other-milestone"])]),
        ]
        let project = ProjectRecord(id: "project", identityKey: nil, lastPath: "/W/Projects/One", name: "One",
                                    notionPageID: "p1", watcherID: nil, documentID: nil,
                                    createdAt: Date(), updatedAt: Date())
        var options = NotionImport.Options()
        options.includeTasks = false
        options.includeTasksLinkedToIncludedMilestones = true
        options.includeFeatures = false
        options.includeIdeas = false
        options.includeSocialPosts = false

        let plan = NotionImport.plan(from: source, options: options, destinations: destinations(tempRoot()),
                                     projectsByNotionID: ["p1": project], existingWorkItems: [], existingIdeaNames: [])
        XCTAssertEqual(plan.milestones.map(\.item.id), ["m1"])
        XCTAssertEqual(plan.tasks.map(\.item.id), ["attached"])
        XCTAssertEqual(plan.tasks.first?.item.parentID, "m1")
        XCTAssertEqual(plan.tasks.first?.item.projectPath, "/W/Projects/One")
    }

    func testExactProjectDirectoryAndUniqueNameProducePreviewLinks() {
        let root = URL(fileURLWithPath: "/Workspace")
        let directoryMatch = ProjectRecord(id: "directory", identityKey: nil,
                                           lastPath: "/Workspace/Projects/From Directory", name: "Renamed locally",
                                           notionPageID: nil, watcherID: nil, documentID: nil,
                                           createdAt: Date(), updatedAt: Date())
        let titleMatch = ProjectRecord(id: "title", identityKey: nil,
                                       lastPath: "/Workspace/Projects/From Title", name: "Unique title",
                                       notionPageID: nil, watcherID: nil, documentID: nil,
                                       createdAt: Date(), updatedAt: Date())
        let duplicateA = ProjectRecord(id: "duplicate-a", identityKey: nil,
                                       lastPath: "/Workspace/Projects/A", name: "Duplicate",
                                       notionPageID: nil, watcherID: nil, documentID: nil,
                                       createdAt: Date(), updatedAt: Date())
        let duplicateB = ProjectRecord(id: "duplicate-b", identityKey: nil,
                                       lastPath: "/Workspace/Projects/B", name: "Duplicate",
                                       notionPageID: nil, watcherID: nil, documentID: nil,
                                       createdAt: Date(), updatedAt: Date())
        let alreadyLinked = ProjectRecord(id: "existing", identityKey: nil,
                                          lastPath: "/Workspace/Projects/Existing", name: "Existing",
                                          notionPageID: "already", watcherID: nil, documentID: nil,
                                          createdAt: Date(), updatedAt: Date())
        let pages = [
            page("by-directory", title: "Not local name", ["Local Directory": .text("Projects/From Directory")]),
            page("old-root", title: "Still not local", ["Local Directory": .text("/Old Mac/Work/Projects/Unique title")]),
            page("by-title", title: "Unique title"),
            page("ambiguous", title: "Duplicate"),
            page("already", title: "Existing"),
        ]

        let result = NotionImport.resolveProjectLinks(
            notionProjects: pages,
            localProjects: [directoryMatch, titleMatch, duplicateA, duplicateB, alreadyLinked], workspaceRoot: root
        )

        XCTAssertEqual(Set(result.links), [
            .init(notionPageID: "bydirectory", projectID: "directory"),
            .init(notionPageID: "oldroot", projectID: "title"),
        ])
        XCTAssertEqual(result.unmatchedCount, 2, "Existing links are preserved; ambiguous and duplicate pages stay unmatched")
    }

    /// Re-running is the normal way to finish an import: link a project, run again. The
    /// second run must bring only what was skipped, and must still recognise an imported
    /// item that someone has since moved to another folder.
    func testRerunningAfterLinkingAProjectAddsOnlyWhatWasSkipped() throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        var source = NotionImport.Source()
        source.tasks = [page("t1", title: "A task", ["Projects": .relations(["p-1"])])]
        source.features = [page("f1", title: "A feature", ["Project": .relations(["p-2"])])]
        let linked = ProjectRecord(id: "one", identityKey: nil, lastPath: "/W/Projects/One", name: "One",
                                   notionPageID: "p-1", watcherID: nil, documentID: nil,
                                   createdAt: Date(), updatedAt: Date())
        let service = WorkItemService()

        let first = NotionImport.plan(from: source, options: .init(), destinations: destinations(root),
                                      projectsByNotionID: ["p1": linked], existingWorkItems: [], existingIdeaNames: [])
        XCTAssertEqual(first.newWorkItemCount, 1, "The feature's project is not linked yet")
        XCTAssertEqual(NotionImport.apply(first).workItemsCreated, 1)

        // Someone files the imported task elsewhere before importing again.
        let task = try XCTUnwrap(service.items(under: root).first)
        _ = try service.move(task, to: root.appendingPathComponent("Elsewhere"))

        let laterLinked = ProjectRecord(id: "two", identityKey: nil, lastPath: "/W/Projects/Two", name: "Two",
                                        notionPageID: "p-2", watcherID: nil, documentID: nil,
                                        createdAt: Date(), updatedAt: Date())
        let second = NotionImport.plan(from: source, options: .init(), destinations: destinations(root),
                                       projectsByNotionID: ["p1": linked, "p2": laterLinked],
                                       existingWorkItems: service.items(under: root), existingIdeaNames: [])
        XCTAssertEqual(second.newWorkItemCount, 1)
        XCTAssertEqual(NotionImport.apply(second).workItemsCreated, 1)
        XCTAssertEqual(Set(service.items(under: root).map(\.id)), ["t1", "f1"], "One of each, never two")

        let third = NotionImport.plan(from: source, options: .init(), destinations: destinations(root),
                                      projectsByNotionID: ["p1": linked, "p2": laterLinked],
                                      existingWorkItems: service.items(under: root), existingIdeaNames: [])
        XCTAssertEqual(third.newWorkItemCount, 0)
    }

    /// The whole path the Settings window and `--migrate notion-apply` take: real HTTP
    /// shapes in, files out, and the files read back as the app reads them on launch.
    func testAnImportFromNotionPersistsAsWorkItemsTheAppCanReadBack() async throws {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        StubNotion.responses = [
            "tasks-db": [
                Self.row("task-1", title: "Write the migration", extra: [
                    "Milestone": ["type": "relation", "relation": [["id": "mile-1"]]],
                    "Status": ["type": "status", "status": ["name": "In Progress"]],
                ]),
                Self.row("task-2", title: "Already finished", extra: [
                    "Complete": ["type": "checkbox", "checkbox": true],
                ]),
            ],
            "milestones-db": [Self.row("mile-1", title: "Migration done", extra: [
                "Project": ["type": "relation", "relation": [["id": "project-1"]]],
                "Features": ["type": "relation", "relation": [["id": "feat-1"]]],
            ])],
            "features-db": [Self.row("feat-1", title: "Leave Notion", extra: [
                "Project": ["type": "relation", "relation": [["id": "project-1"]]],
            ])],
        ]
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubNotion.self]
        let client = NotionClient(token: "test", session: URLSession(configuration: configuration))

        var source = NotionImport.Source()
        source.tasks = try await client.allPages(inDatabase: "tasks-db").pages
        source.milestones = try await client.allPages(inDatabase: "milestones-db").pages
        source.features = try await client.allPages(inDatabase: "features-db").pages

        let project = ProjectRecord(id: "local-project", identityKey: nil, lastPath: "/W/Projects/Better Workspace",
                                    name: "Better Workspace", notionPageID: "project-1", watcherID: nil,
                                    documentID: nil, createdAt: Date(), updatedAt: Date())
        let plan = NotionImport.plan(from: source, options: .init(), destinations: destinations(root),
                                     projectsByNotionID: ["project1": project], existingWorkItems: [], existingIdeaNames: [])
        XCTAssertEqual(plan.newWorkItemCount, 3, "The finished task stays behind by default")
        let result = NotionImport.apply(plan)
        XCTAssertEqual(result.workItemsCreated, 3)
        XCTAssertTrue(result.failures.isEmpty)

        let names = try FileManager.default.subpathsOfDirectory(atPath: root.path)
            .filter { $0.hasSuffix(WorkItemService.fileSuffix) }
        XCTAssertEqual(names.count, 3, "\(names)")

        // A fresh service, as on the next launch.
        let reread = Dictionary(uniqueKeysWithValues: WorkItemService().items(under: root).map { ($0.id, $0) })
        XCTAssertEqual(reread["task1"]?.title, "Write the migration")
        XCTAssertEqual(reread["task1"]?.status, .inProgress)
        XCTAssertEqual(reread["task1"]?.parentID, "mile1")
        XCTAssertEqual(reread["mile1"]?.kind, .milestone)
        XCTAssertEqual(reread["mile1"]?.parentID, "feat1")
        XCTAssertEqual(reread["feat1"]?.kind, .feature)
        XCTAssertNil(reread["task2"])

        // And a second import, planned against what is now on disk, writes nothing.
        let again = NotionImport.plan(from: source, options: .init(), destinations: destinations(root),
                                      projectsByNotionID: ["project1": project], existingWorkItems: Array(reread.values),
                                      existingIdeaNames: [])
        XCTAssertEqual(again.newWorkItemCount, 0)
    }

    private static func row(_ id: String, title: String, extra: [String: Any]) -> [String: Any] {
        var properties: [String: Any] = ["Name": ["type": "title", "title": [["plain_text": title]]]]
        properties.merge(extra) { _, new in new }
        return ["id": id, "url": "https://www.notion.so/\(id)", "properties": properties]
    }
}

/// Answers data-source definitions and queries from a fixed table, without network.
final class StubNotion: URLProtocol {
    nonisolated(unsafe) static var responses: [String: [[String: Any]]] = [:]

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "api.notion.com" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let parts = request.url?.pathComponents ?? []
        let id = parts.firstIndex(of: "data_sources").flatMap { parts.indices.contains($0 + 1) ? parts[$0 + 1] : nil }
        let rows = id.flatMap { Self.responses[$0] }
        let status = rows == nil ? 404 : 200
        let body: [String: Any]
        if request.httpMethod == "GET", let id, let rows {
            body = ["id": id, "title": [["plain_text": id]], "properties": rows.first?["properties"] ?? [:]]
        } else { body = rows.map { ["results": $0, "has_more": false] } ?? ["message": "not found"] }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: body))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// Re-running the import against the real schema shapes: what it may rewrite, what it
/// must leave alone, and that a second identical run writes nothing.
final class NotionImportRefreshTests: XCTestCase {

    private var root: URL!
    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("bw-refresh-\(UUID().uuidString)")
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func destinations() -> NotionImport.Destinations {
        .init(tasks: root.appendingPathComponent("To Do"), milestones: root.appendingPathComponent("Milestones"),
              features: root.appendingPathComponent("Features"), ideas: root.appendingPathComponent("Ideas"))
    }

    private func page(_ id: String, _ title: String, edited: Date = Date(timeIntervalSince1970: 1_790_000_000),
                      _ extra: [String: NotionValue]) -> NotionPage {
        var properties: [String: NotionValue] = ["task": .title(title)]
        properties.merge(extra) { _, new in new }
        return NotionPage(id: id, url: URL(string: "https://www.notion.so/\(id)"),
                          createdTime: Date(timeIntervalSince1970: 1_780_000_000), lastEditedTime: edited,
                          properties: properties)
    }

    private let project = ProjectRecord(id: "p", identityKey: nil, lastPath: "/W/Projects/Thing", name: "Thing",
                                        notionPageID: "proj-1", watcherID: nil, documentID: nil,
                                        createdAt: Date(), updatedAt: Date())

    private func plan(_ source: NotionImport.Source, legacy: Bool = false, completed: Bool = true) -> NotionImport.Plan {
        var options = NotionImport.Options()
        options.includeCompletedTasks = completed
        options.upgradeLegacyImports = legacy
        return NotionImport.plan(from: source, options: options, destinations: destinations(),
                                 projectsByNotionID: ["proj1": project],
                                 existingWorkItems: WorkItemService().items(under: root), existingIdeaNames: [])
    }

    func testTheRealSchemaShapesImportFaithfully() {
        var source = NotionImport.Source()
        source.milestones = [
            page("m-done", "Shipped", ["status": .text("Complete"), "project": .relations(["proj-1"])]),
            page("m-late", "Late", ["status": .text("Behind Schedule"), "project": .relations(["proj-1"]),
                                    "depends on": .relations(["m-done"])]),
        ]
        source.tasks = [
            page("t-dup", "Twice", ["status": .choice("Duplicate"), "project": .relations(["proj-1"])]),
            page("t-review", "Look", ["status": .choice("In Review"), "Work Stage": .choice("Current"),
                                      "Blocked by": .relations(["t-dup"]), "effort": .choice("3"),
                                      "due date": .date("2026-10-01T09:00:00.000-07:00")]),
        ]
        let result = plan(source)
        let done = result.milestones.first { $0.item.title == "Shipped" }!.item
        let late = result.milestones.first { $0.item.title == "Late" }!.item
        XCTAssertEqual(done.status, .completed, "A formula status of Complete is a completed milestone")
        XCTAssertEqual(late.status, .open)
        XCTAssertTrue(late.extraFrontMatter.contains("depends-on: [mdone]"))
        XCTAssertTrue(late.extraFrontMatter.contains("source: notion"))
        XCTAssertTrue(late.extraFrontMatter.contains { $0.hasPrefix("notion-edited: ") })

        let duplicate = result.tasks.first { $0.item.title == "Twice" }!.item
        XCTAssertEqual(duplicate.status, .completed, "A duplicate is closed, not open work")
        let review = result.tasks.first { $0.item.title == "Look" }!.item
        XCTAssertEqual(review.status, .inProgress)
        XCTAssertEqual(review.stage, .now, "Work Stage beats a date")
        XCTAssertNotNil(review.dueDate, "A due date with milliseconds is kept")
        XCTAssertTrue(review.extraFrontMatter.contains("blocked-by: [tdup]"))
        XCTAssertTrue(review.body.contains("**Effort:** 3"))
    }

    func testAnUneditedImportIsRefreshedAndAnEditedOneIsLeftAlone() throws {
        var source = NotionImport.Source()
        source.tasks = [page("t-1", "First", ["project": .relations(["proj-1"])]),
                        page("t-2", "Second", ["project": .relations(["proj-1"])])]
        XCTAssertEqual(NotionImport.apply(plan(source)).workItemsCreated, 2)

        // Identical second run: nothing to do.
        let same = plan(source)
        XCTAssertEqual(same.newWorkItemCount + same.refreshCount, 0)

        // Someone edits Second in Better Workspace.
        let service = WorkItemService()
        var second = try XCTUnwrap(service.items(under: root).first { $0.title == "Second" })
        second.body += "\n\nMy own note."
        _ = try service.update(second)

        // Both change in Notion.
        source.tasks = [page("t-1", "First, renamed", edited: Date(timeIntervalSince1970: 1_790_100_000),
                             ["project": .relations(["proj-1"])]),
                        page("t-2", "Second, renamed", edited: Date(timeIntervalSince1970: 1_790_100_000),
                             ["project": .relations(["proj-1"])])]
        let changed = plan(source)
        XCTAssertEqual(changed.refreshCount, 1)
        XCTAssertEqual(changed.keptLocalEditsCount, 1)
        let result = NotionImport.apply(changed)
        XCTAssertEqual(result.workItemsRefreshed, 1)
        XCTAssertEqual(result.workItemsCreated, 0)

        let items = service.items(under: root)
        XCTAssertEqual(items.count, 2, "Refreshing never duplicates")
        XCTAssertTrue(items.contains { $0.title == "First, renamed" })
        XCTAssertTrue(items.contains { $0.title == "Second" && $0.body.contains("My own note.") })

        let again = plan(source)
        XCTAssertEqual(again.refreshCount, 0, "A refreshed file is unedited, and already current")
    }

    func testAContentHashSurvivesWritingAndReadingTheFile() throws {
        var source = NotionImport.Source()
        source.tasks = [page("t-1", "With \"quotes\" and: colons", ["project": .relations(["proj-1"]),
                                                                   "due date": .date("2026-10-01"),
                                                                   "Blocking": .relations(["x-1", "x-2"])])]
        let planned = plan(source).tasks[0].item
        NotionImport.apply(plan(source))
        let stored = try XCTUnwrap(WorkItemService().items(under: root).first)
        XCTAssertEqual(NotionImport.contentHash(stored), NotionImport.contentHash(planned))
    }

    func testALegacyImportIsUpgradedOnlyWhenAskedAndUntouched() throws {
        // What the import wrote before it recorded provenance.
        let service = WorkItemService()
        let legacy = WorkItem(id: "t1", kind: .task, title: "Old", projectPath: "/W/Projects/Thing",
                              body: "**Status:** Todo\n\n\n[Originally in Notion](https://www.notion.so/t-1)",
                              url: root.appendingPathComponent("To Do/x"))
        _ = try service.create(legacy, in: root.appendingPathComponent("To Do"))
        var source = NotionImport.Source()
        source.tasks = [page("t-1", "Old", ["project": .relations(["proj-1"])])]

        XCTAssertEqual(plan(source).refreshCount, 0, "Not without being asked")
        let upgrade = plan(source, legacy: true)
        XCTAssertEqual(upgrade.refreshCount, 1)
        XCTAssertEqual(NotionImport.apply(upgrade).workItemsRefreshed, 1)
        let stored = try XCTUnwrap(service.items(under: root).first)
        XCTAssertTrue(stored.extraFrontMatter.contains("source: notion"))
        XCTAssertEqual(plan(source, legacy: true).refreshCount, 0)
    }

    /// The real case: "Project Foundation" milestones and features for Notion projects
    /// that have no folder here. Opted in, they import unattached and keep the project
    /// by id and by name; linking the project later attaches them, once, in place.
    func testUnlinkedPlanningImportsUnattachedAndAttachesOnceLinked() throws {
        var source = NotionImport.Source()
        source.projects = [page("orphan-1", "Psyche Agent", [:])]
        source.milestones = [page("m-1", "Project Foundation", ["status": .text("Behind Schedule"),
                                                                "project": .relations(["orphan-1"])])]
        source.features = [page("f-1", "Local Model Connection", ["Status": .choice("Active"),
                                                                  "Project": .relations(["orphan-1"]),
                                                                  "Phase": .choice("Build")])]
        func planned(unlinked: Bool, projects: [String: ProjectRecord] = [:]) -> NotionImport.Plan {
            var options = NotionImport.Options()
            options.includeTasks = false
            options.includeUnlinkedPlanning = unlinked
            return NotionImport.plan(from: source, options: options, destinations: destinations(),
                                     projectsByNotionID: projects,
                                     existingWorkItems: WorkItemService().items(under: root), existingIdeaNames: [])
        }

        let byDefault = planned(unlinked: false)
        XCTAssertEqual(byDefault.newWorkItemCount, 0, "Linking first stays the default")
        XCTAssertEqual(byDefault.warnings.filter { $0.contains("skipped") }.count, 2)

        let unattached = planned(unlinked: true)
        XCTAssertEqual(unattached.newWorkItemCount, 2)
        let milestone = try XCTUnwrap(unattached.milestones.first?.item)
        XCTAssertNil(milestone.projectPath)
        XCTAssertTrue(milestone.extraFrontMatter.contains("notion-project: [orphan1]"))
        XCTAssertTrue(milestone.body.contains("**Notion project:** Psyche Agent"))
        let feature = try XCTUnwrap(unattached.features.first?.item)
        XCTAssertTrue(feature.extraFrontMatter.contains("notion-project: [orphan1]"))
        XCTAssertTrue(feature.body.contains("**Phase:** Build"))
        XCTAssertEqual(NotionImport.apply(unattached).workItemsCreated, 2)
        XCTAssertEqual(planned(unlinked: true).newWorkItemCount + planned(unlinked: true).refreshCount, 0,
                       "A second run writes nothing")

        // The project gets a folder and a link: the next run attaches both in place.
        let linked = ProjectRecord(id: "psyche", identityKey: nil, lastPath: "/W/Projects/Psyche Agent",
                                   name: "Psyche Agent", notionPageID: "orphan-1", watcherID: nil,
                                   documentID: nil, createdAt: Date(), updatedAt: Date())
        let attach = planned(unlinked: true, projects: ["orphan1": linked])
        XCTAssertEqual(attach.newWorkItemCount, 0)
        XCTAssertEqual(attach.refreshCount, 2)
        XCTAssertEqual(NotionImport.apply(attach).workItemsRefreshed, 2)
        let items = WorkItemService().items(under: root)
        XCTAssertEqual(items.count, 2, "Attached, never duplicated")
        XCTAssertTrue(items.allSatisfy { $0.projectPath == "/W/Projects/Psyche Agent" })
        XCTAssertTrue(items.allSatisfy { $0.body.contains("Notion project") == false })
    }
}
