import XCTest
import BetterWorkspaceCore

final class ProjectGraphUITests: IsolatedUITestCase {
    private var remoteID = "remote"
    override func setUpWithError() throws {
        try super.setUpWithError()
        let database = try Database(url: Self.fixtureRoot.appendingPathComponent("test.sqlite"))
        let store = try ProjectGraphStore(database: database)
        let projects = ProjectGraphSource(id: "projects", title: "Projects", kind: .projects, schema: ProjectJSON([
            "title": ["id": "title", "type": "title"], "one liner": ["id": "line", "type": "rich_text"],
            "domain": ["id": "domain", "type": "select", "select": ["options": [["name": "Apps"], ["name": "Personal"]]]],
            "thumbnail": ["id": "thumbnail", "type": "relation", "relation": ["data_source_id": "assets"]]]))
        let assets = ProjectGraphSource(id: "assets", title: "Assets", kind: .assets, schema: ProjectJSON([
            "label": ["id": "label", "type": "title"], "relative path": ["id": "path", "type": "rich_text"], "storage": ["id": "storage", "type": "select"], "projects": ["id": "projects", "type": "relation", "relation": ["data_source_id": "projects"]]]))
        try store.write("sources", [projects, assets])
        func text(_ value: String, type: String = "rich_text") -> ProjectJSON { ProjectJSON(["type": type, type: [["type": "text", "text": ["content": value]]]]) }
        let fields: [String: ProjectJSON] = ["title": text("Remote project", type: "title"), "line": text("A project without a folder"), "domain": ProjectJSON(["type": "select", "select": ["name": "Apps"]]), "thumbnail": ProjectJSON(["type": "relation", "relation": [["id": "asset"]]])]
        try store.save(ProjectGraphRecord(id: remoteID, pageID: "remote-page", sourceID: "projects", kind: .projects, local: fields, baseline: fields, remote: fields))
        let media: [String: ProjectJSON] = ["label": text("Fixture image", type: "title"), "path": text("For Reference/Wide reference.png"), "storage": ProjectJSON(["type": "select", "select": ["name": "Workspace"]]), "projects": ProjectJSON(["type": "relation", "relation": [["id": "remote-page"]]])]
        try store.save(ProjectGraphRecord(pageID: "asset", sourceID: "assets", kind: .assets, local: media, baseline: media, remote: media))
    }
    private func launch(width: Int = 1100, height: Int = 760) -> XCUIApplication {
        let app = isolatedApp(arguments: ["-bwStartArea", "Projects", "-bwWindowWidth", "\(width)", "-bwWindowHeight", "\(height)"])
        app.launch(); requireWindow(app); if !remoteRow(app).waitForExistence(timeout: 5) { print(app.debugDescription) }; XCTAssertTrue(remoteRow(app).exists); return app
    }
    private func remoteRow(_ app: XCUIApplication) -> XCUIElement {
        app.staticTexts["projects.row.remote.name"].firstMatch
    }
    private func openRemote(_ app: XCUIApplication) {
        remoteRow(app).doubleClick()
        XCTAssertTrue(app.staticTexts["Notion-only"].firstMatch.waitForExistence(timeout: 10))
    }
    func testRemoteProjectHasPresentationsAndGalleryAtMinimumSize() {
        let app = launch(width: 820, height: 520); openRemote(app)
        for label in ["Tasks", "Details", "Media", "Portfolio"] { XCTAssertTrue(app.radioButtons[label].firstMatch.exists) }
        XCTAssertTrue(app.descendants(matching: .any)["projects.nextAction"].firstMatch.exists)
        XCTAssertFalse(app.radioButtons["Workspace"].firstMatch.exists)
        app.radioButtons["Details"].firstMatch.click()
        XCTAssertTrue(app.textFields["projects.property.line"].firstMatch.waitForExistence(timeout: 5))
        let detailsShot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot()); detailsShot.name = "project-details-820x520"; detailsShot.lifetime = .keepAlways; add(detailsShot)
        app.radioButtons["Media"].firstMatch.click()
        XCTAssertTrue(app.buttons["Add media file…"].firstMatch.waitForExistence(timeout: 5))
        let mediaShot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot()); mediaShot.name = "project-media-820x520"; mediaShot.lifetime = .keepAlways; add(mediaShot)
        app.radioButtons["Portfolio"].firstMatch.click()
        XCTAssertFalse(app.buttons["Add media file…"].firstMatch.exists)
        XCTAssertTrue(app.staticTexts["A project without a folder"].firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Media & Resources"].firstMatch.waitForExistence(timeout: 10))
        XCTAssertEqual(app.windows.firstMatch.frame.width, 820, accuracy: 1)
        XCTAssertEqual(app.windows.firstMatch.frame.height, 520, accuracy: 1)
        let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot()); attachment.name = "project-portfolio-820x520"; attachment.lifetime = .keepAlways; add(attachment)
    }
    func testPortfolioDisplaysIncomingMediaWithoutAcceptingIt() throws {
        let store = try ProjectGraphStore(database: Database(url: Self.fixtureRoot.appendingPathComponent("test.sqlite")))
        var asset = try XCTUnwrap(store.records().first { $0.pageID == "asset" })
        asset.local = [:]; asset.baseline = [:]
        try store.save(asset)
        let blocks = [ProjectJSON(["type": "synced_block", "_children": [["type": "unsupported"], ["type": "unsupported"],
            ["type": "paragraph", "paragraph": ["rich_text": [["text": ["content": "Readable story fixture"]]]]]]])]
        try store.write("pageContent.remote-page", NotionPageContent(pageID: "remote-page", editedAt: nil, blocks: blocks))
        let app = launch(width: 820, height: 520); openRemote(app)
        app.radioButtons["Portfolio"].firstMatch.click()
        XCTAssertTrue(app.images["projects.media.preview.\(asset.id)"].firstMatch.waitForExistence(timeout: 15))
        XCTAssertFalse(app.links["View unsupported in Notion"].firstMatch.exists)
        XCTAssertTrue(try XCTUnwrap(store.record(id: asset.id)).local.isEmpty)
        XCTAssertTrue(try XCTUnwrap(store.record(id: asset.id)).baseline.isEmpty)
    }
    private func seedLargeBacklog() throws -> ProjectGraphStore {
        let database = try Database(url: Self.fixtureRoot.appendingPathComponent("test.sqlite"))
        let store = try ProjectGraphStore(database: database)
        let source = try XCTUnwrap(store.read("sources", as: [ProjectGraphSource].self)?.first)
        try database.transaction {
            for index in 0..<3000 {
                var record = ProjectGraphRecord(id: "backlog-\(index)", pageID: "backlog-page-\(index)", sourceID: source.id, kind: .tasks)
                record.set("one liner", value: ProjectJSON([["text": ["content": String(repeating: "Local pending field ", count: 15)]]]), source: source)
                record.baseline = record.local
                record.remote = ["line": ProjectJSON(["type": "rich_text", "rich_text": [["text": ["content": String(repeating: "Remote pending field ", count: 15)]]]])]
                try store.save(record)
            }
        }
        return store
    }

    func testCreateAndResaveTaskWithLargeSyncBacklog() throws {
        let store = try seedLargeBacklog()
        let database = try Database(url: Self.fixtureRoot.appendingPathComponent("test.sqlite"))
        let url = Self.workspaceRoot.appendingPathComponent("Projects/Fixture project")
        let local = ProjectStore(database: database).register(url: url)
        var sources = try XCTUnwrap(store.read("sources", as: [ProjectGraphSource].self))
        let tasks = ProjectGraphSource(id: "tasks", title: "Tasks", kind: .tasks, schema: ProjectJSON([
            "Task": ["id": "title", "type": "title"],
            "projects": ["id": "projects", "type": "relation", "relation": ["data_source_id": "projects"]]]))
        sources.append(tasks); try store.write("sources", sources)
        var graph = ProjectGraphRecord(id: "local-project", pageID: "local-page", sourceID: "projects", kind: .projects)
        graph.localProjectID = local.id; graph.localPath = url.canonicalPath
        try store.save(graph)
        let app = launch()
        let row = app.staticTexts["Fixture project"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10)); row.doubleClick()
        let add = app.buttons["Add Task"].firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 5)); add.click()
        let title = app.textFields["workItem.title"].firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 5)); title.click(); title.typeText("Backlog test task")
        app.buttons["workItem.save"].firstMatch.click()
        XCTAssertTrue(app.buttons["projects.nextAction.edit"].firstMatch.waitForExistence(timeout: 10))
        let work = try XCTUnwrap(WorkItemService().items(under: Self.workspaceRoot.appendingPathComponent("To Do")).first { $0.title == "Backlog test task" })
        XCTAssertEqual(try store.record(id: work.id)?.title, "Backlog test task")
        app.buttons["projects.nextAction.edit"].firstMatch.click()
        XCTAssertTrue(title.waitForExistence(timeout: 5)); title.click(); title.typeKey("a", modifierFlags: .command); title.typeText("Saved again under backlog")
        app.buttons["workItem.save"].firstMatch.click()
        XCTAssertTrue(app.buttons["projects.nextAction.edit"].firstMatch.waitForExistence(timeout: 10))
        XCTAssertEqual(try store.record(id: work.id)?.title, "Saved again under backlog")
        XCTAssertEqual(WorkItemService().read(at: work.url)?.title, "Saved again under backlog")
        XCTAssertNil(try store.record(id: work.id)?.pageID, "The edit is local; no Notion Send occurs")
    }

    /// The backlog is deliberately unrelated to the selected project. Saving one
    /// field must remain usable while the whole graph is prepared in the background.
    func testZenWithLargeSyncBacklogPersistsLatestChoiceAndDoesNotSend() throws {
        let store = try seedLargeBacklog()
        let app = launch(width: 820, height: 520); openRemote(app)
        app.buttons["Zen mode"].firstMatch.click()
        let personal = app.buttons["projects.zen.choice.domain.Personal"].firstMatch
        XCTAssertTrue(personal.waitForExistence(timeout: 5))
        personal.click()
        app.buttons["projects.zen.choice.domain.Apps"].firstMatch.click()
        personal.click()
        app.buttons["Next"].firstMatch.click()
        app.buttons["Save & Exit"].firstMatch.click()
        app.buttons["Zen mode"].firstMatch.click()
        XCTAssertTrue(app.staticTexts["What kind of project is this?"].waitForExistence(timeout: 5))
        for _ in 0..<3 { app.buttons["Skip"].firstMatch.click() }
        app.buttons["Apply approved answers"].firstMatch.click()
        XCTAssertTrue(app.buttons["Zen mode"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(try store.record(id: remoteID)?.local["domain"]?.display, "Personal")
        XCTAssertEqual(try store.record(id: remoteID)?.remote["domain"]?.display, "Apps")
        XCTAssertEqual(try store.records().count, 3002)
        let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        attachment.name = "zen-large-backlog-820x520"; attachment.lifetime = .keepAlways; add(attachment)
    }

    func testZenSaveExitResumeAndFinalLocalApply() throws {
        let app = launch(); openRemote(app)
        app.buttons["Zen mode"].firstMatch.click()
        XCTAssertEqual(app.sheets.textViews.count, 0)
        XCTAssertEqual(app.sheets.textFields.count, 0)
        let choice = app.buttons["projects.zen.choice.domain.Personal"].firstMatch
        XCTAssertTrue(choice.waitForExistence(timeout: 5)); choice.click()
        app.buttons["Next"].firstMatch.click(); app.buttons["Save & Exit"].firstMatch.click()
        app.buttons["Zen mode"].firstMatch.click()
        XCTAssertTrue(app.staticTexts["What kind of project is this?"].waitForExistence(timeout: 5))
        for _ in 0..<3 { app.buttons["Skip"].firstMatch.click() }
        XCTAssertTrue(app.staticTexts["Review your changes"].waitForExistence(timeout: 5))
        app.buttons["Apply approved answers"].click()
        // Saved here, waiting in the toolbar's Notion menu; nothing is sent.
        let sync = app.descendants(matching: .any)["projects.sync"].firstMatch
        let pending = expectation(for: NSPredicate(format: "value == %@", "0 need you, 1 waiting"), evaluatedWith: sync)
        wait(for: [pending], timeout: 10)
        let store = try ProjectGraphStore(database: Database(url: Self.fixtureRoot.appendingPathComponent("test.sqlite")))
        XCTAssertEqual(try store.record(id: remoteID)?.local["domain"]?.display, "Personal")
    }

    func testZenEveryModeUsesChoicesAndRatings() {
        let app = launch(width: 820, height: 520); openRemote(app)
        app.buttons["Zen mode"].firstMatch.click()
        for mode in ["Details", "Planning", "Media", "Scoring"] {
            app.sheets.radioButtons[mode].firstMatch.click()
            XCTAssertEqual(app.sheets.textViews.count, 0, mode)
            XCTAssertEqual(app.sheets.textFields.count, 0, mode)
        }
        let rating = app.sheets.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND identifier ENDSWITH %@", "projects.zen.choice.", ".5")).firstMatch
        XCTAssertTrue(rating.waitForExistence(timeout: 5))
        XCTAssertTrue(rating.isHittable)
        XCTAssertLessThanOrEqual(app.sheets.buttons["Save & Exit"].firstMatch.frame.maxY, app.windows.firstMatch.frame.maxY)
        rating.click()
        XCTAssertTrue(app.sheets.buttons["Next"].firstMatch.isEnabled)
        app.sheets.buttons["Save & Exit"].firstMatch.click()
        app.buttons["Zen mode"].firstMatch.click()
        app.sheets.radioButtons["Scoring"].firstMatch.click()
        XCTAssertTrue(rating.exists)
        let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        attachment.name = "project-zen-mouse-only-820x520"; attachment.lifetime = .keepAlways; add(attachment)
    }

    func testLocalProjectOpensTasksAndKeepsAuditCollapsed() {
        let app = launch(width: 820, height: 520)
        let local = app.staticTexts.matching(NSPredicate(format: "value == %@", "Fixture project")).firstMatch
        XCTAssertTrue(local.waitForExistence(timeout: 5)); local.doubleClick()
        XCTAssertTrue(app.descendants(matching: .any)["projects.nextAction"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["No tasks yet"].firstMatch.exists)
        XCTAssertTrue(app.buttons["projects.plan.emptyAdd"].firstMatch.exists)
        for label in ["Tasks", "Details", "Media", "Portfolio"] { XCTAssertTrue(app.radioButtons[label].firstMatch.exists) }
        app.radioButtons["Details"].firstMatch.click()
        XCTAssertTrue(app.textFields["Type"].firstMatch.waitForExistence(timeout: 5))
        app.radioButtons["Tasks"].firstMatch.click()
        let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        attachment.name = "project-tasks-820x520"; attachment.lifetime = .keepAlways; add(attachment)
    }

    func testNextActionAndZenPlanningRespectExistingTasks() throws {
        let store = try ProjectGraphStore(database: Database(url: Self.fixtureRoot.appendingPathComponent("test.sqlite")))
        var sources = try XCTUnwrap(store.read("sources", as: [ProjectGraphSource].self))
        let tasks = ProjectGraphSource(id: "tasks", title: "Tasks", kind: .tasks, schema: ProjectJSON([
            "title": ["id": "title", "type": "title"],
            "Work Stage": ["id": "stage", "type": "select", "select": ["options": [["name": "Now"], ["name": "Next"], ["name": "Later"]]]],
            "Dependencies": ["id": "deps", "type": "relation", "relation": ["data_source_id": "tasks"]],
            "projects": ["id": "projects", "type": "relation", "relation": ["data_source_id": "projects"]]]))
        sources.append(tasks); try store.write("sources", sources)
        for (id, title, stage, dependency) in [("action", "Write fixture docs", "Next", ""), ("blocked", "Blocked fixture task", "Now", "unknown"), ("later", "Later fixture task", "Later", "")] {
            var record = ProjectGraphRecord(id: id, pageID: id + "-page", sourceID: tasks.id, kind: .tasks)
            record.set("title", value: ProjectJSON([["text": ["content": title]]]), source: tasks)
            record.set("Work Stage", value: ProjectJSON(["name": stage]), source: tasks)
            record.set("projects", value: ProjectJSON([["id": "remote-page"]]), source: tasks)
            if !dependency.isEmpty { record.set("Dependencies", value: ProjectJSON([["id": dependency]]), source: tasks) }
            record.baseline = record.local; record.remote = record.local
            try store.save(record)
        }
        let app = launch(width: 820, height: 520); openRemote(app)
        // Blocked work stays on the Active list but is never the next action.
        let next = app.descendants(matching: .any)["projects.nextAction"].firstMatch
        XCTAssertTrue(next.staticTexts["Write fixture docs"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(next.staticTexts["Blocked fixture task"].firstMatch.exists)
        XCTAssertTrue(app.descendants(matching: .any)["projects.plan.row.Blocked fixture task"].firstMatch.exists)
        app.buttons["Zen mode"].firstMatch.click(); app.sheets.radioButtons["Planning"].firstMatch.click()
        app.buttons["projects.zen.choice.task.action"].firstMatch.click()
        app.buttons["Next"].firstMatch.click()
        app.buttons["projects.zen.choice.stage.Now"].firstMatch.click()
        app.buttons["Review"].firstMatch.click(); app.buttons["Apply approved answers"].firstMatch.click()
        XCTAssertTrue(app.buttons["Zen mode"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(try store.record(id: "action")?.value("Work Stage", source: tasks).display, "Now")
        XCTAssertEqual(try store.records().filter { $0.kind == .tasks }.count, 3)
        let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        attachment.name = "project-next-task-820x520"; attachment.lifetime = .keepAlways; add(attachment)
    }

    func testGroupedNativeTableAndViewOptions() {
        let app = launch()
        app.descendants(matching: .any)["projects.viewOptions"].firstMatch.click()
        app.menuItems["Group"].firstMatch.hover(); app.menuItems["Group"].firstMatch.menuItems["Domain"].firstMatch.click()
        let group = app.staticTexts.matching(NSPredicate(format: "value == %@", "Apps · 1")).firstMatch
        if !group.waitForExistence(timeout: 5) { print(app.debugDescription) }
        XCTAssertTrue(group.exists)
        XCTAssertTrue(app.outlines["projects.table"].firstMatch.disclosureTriangles.firstMatch.exists)
        app.radioButtons["Cards"].firstMatch.click()
        XCTAssertTrue(app.buttons["projects.portfolio.remote"].firstMatch.waitForExistence(timeout: 10))
        app.radioButtons["Table"].firstMatch.click()
        XCTAssertTrue(group.waitForExistence(timeout: 10))
        let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot()); attachment.name = "project-grouped-table-desktop"; attachment.lifetime = .keepAlways; add(attachment)
    }
    func testInitialImportReviewPrioritizesConflictsAndBatchesHistory() throws {
        let store = try ProjectGraphStore(database: Database(url: Self.fixtureRoot.appendingPathComponent("test.sqlite")))
        var sources = try XCTUnwrap(store.read("sources", as: [ProjectGraphSource].self))
        let projectSource = try XCTUnwrap(sources.first { $0.kind == .projects })
        var schema = projectSource.schema.object; schema["Status"] = ProjectJSON(["id": "status", "type": "select"])
        sources.removeAll { $0.kind == .projects }
        sources.append(ProjectGraphSource(id: projectSource.id, title: projectSource.title, kind: .projects, schema: .object(schema)))
        try store.write("sources", sources)
        func title(_ value: String) -> ProjectJSON { ProjectJSON(["type": "title", "title": [["text": ["content": value]]]]) }
        let active = ProjectGraphRecord(id: "active", pageID: "active-page", sourceID: "projects", kind: .projects, remote: ["title": title("Active imported project"), "status": ProjectJSON(["type": "select", "select": ["name": "Active"]])])
        try store.save(active)
        for index in 0..<1000 {
            try store.save(ProjectGraphRecord(id: "log-\(index)", pageID: "log-page-\(index)", sourceID: "logs", kind: .workLogs, remote: ["title": title("Historical log \(index)"), "project": ProjectJSON(["type": "relation", "relation": [["id": "active-page"]]])]))
        }
        var conflict = try XCTUnwrap(store.record(id: remoteID))
        conflict.local["line"] = ProjectJSON(["type": "rich_text", "rich_text": [["text": ["content": "Local edit"]]]])
        conflict.remote["line"] = ProjectJSON(["type": "rich_text", "rich_text": [["text": ["content": "Notion edit"]]]])
        try store.save(conflict)
        let app = launch(width: 820, height: 520)
        app.typeKey(",", modifierFlags: .command)
        app.buttons["Integrations"].firstMatch.click()
        app.buttons["Import Reviewed Changes…"].firstMatch.click()
        let attention = app.buttons["projects.sync.group.attention"].firstMatch
        XCTAssertTrue(attention.waitForExistence(timeout: 5))
        XCTAssertFalse(app.checkBoxes["projects.sync.record.remote"].firstMatch.exists)
        let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot()); attachment.name = "project-sync-review-batched"; attachment.lifetime = .keepAlways; add(attachment)
        attention.click()
        XCTAssertTrue(app.checkBoxes["projects.sync.record.remote"].firstMatch.exists)
        XCTAssertTrue(app.checkBoxes["projects.sync.batch.relevant.projects"].firstMatch.exists)
        XCTAssertTrue(app.buttons["Apply 1 Records"].firstMatch.exists)
        attention.click()
        let history = app.buttons["projects.sync.group.history"].firstMatch
        XCTAssertTrue(history.exists)
        XCTAssertFalse(app.checkBoxes["projects.sync.record.log-0"].firstMatch.exists)
        let reviewScroll = app.scrollViews["projects.sync.records"].firstMatch
        for _ in 0..<5 where !history.isHittable || history.frame.maxY > reviewScroll.frame.maxY - 30 { reviewScroll.scroll(byDeltaX: 0, deltaY: -150) }
        history.click()
        let logs = app.checkBoxes["projects.sync.batch.history.workLogs"].firstMatch
        for _ in 0..<5 where !logs.exists || !logs.isHittable || logs.frame.maxY > reviewScroll.frame.maxY - 30 { reviewScroll.scroll(byDeltaX: 0, deltaY: -150) }
        if !logs.exists { print(app.debugDescription) }
        XCTAssertTrue(logs.waitForExistence(timeout: 5)); logs.click()
        XCTAssertTrue(app.buttons["Apply 1,001 Records"].firstMatch.exists)
        XCTAssertFalse(app.checkBoxes["projects.sync.record.log-0"].firstMatch.exists, "Bulk selection must not expand 1,000 log rows")
        let search = app.textFields["projects.sync.search"].firstMatch
        search.click(); search.typeText("Active imported project")
        app.buttons["projects.sync.recommended"].firstMatch.click()
        XCTAssertTrue(app.buttons["Apply 1 Records"].firstMatch.exists)
        search.click(); search.typeKey("a", modifierFlags: .command); search.typeText("Historical log 999")
        XCTAssertTrue(app.buttons["projects.sync.show.history.workLogs"].firstMatch.waitForExistence(timeout: 5))
        app.buttons["projects.sync.show.history.workLogs"].firstMatch.click()
        XCTAssertTrue(app.checkBoxes["projects.sync.record.log-999"].firstMatch.waitForExistence(timeout: 5))
        app.buttons["Cancel"].firstMatch.click()
        XCTAssertTrue(try XCTUnwrap(store.record(id: "active")).local.isEmpty)
        XCTAssertEqual(try store.record(id: remoteID)?.local["line"]?.display, "Local edit")
    }

    func testConflictChoicesShowSourcesAndNewestRequiresReview() throws {
        let store = try ProjectGraphStore(database: Database(url: Self.fixtureRoot.appendingPathComponent("test.sqlite")))
        var record = try XCTUnwrap(store.record(id: remoteID))
        let source = try XCTUnwrap(store.read("sources", as: [ProjectGraphSource].self)?.first { $0.kind == .projects })
        record.set("one liner", value: ProjectServiceBridge.text("New local one liner"), source: source, changedAt: Date(timeIntervalSince1970: 200))
        record.remote["line"] = ProjectJSON(["type": "rich_text", "rich_text": [["text": ["content": "Older Notion one liner"]]]])
        record.editedAt = Date(timeIntervalSince1970: 100)
        try store.save(record)
        let app = launch(width: 820, height: 520)
        app.typeKey(",", modifierFlags: .command)
        app.buttons["Integrations"].firstMatch.click()
        app.buttons["Import Reviewed Changes…"].firstMatch.click()
        app.buttons["projects.sync.group.attention"].firstMatch.click()
        let checkbox = app.checkBoxes["projects.sync.record.remote"].firstMatch
        XCTAssertTrue(checkbox.waitForExistence(timeout: 5)); checkbox.click()
        let apply = app.buttons["projects.sync.apply"].firstMatch
        XCTAssertFalse(apply.isEnabled, "An unresolved selected conflict blocks Apply")
        app.buttons["projects.sync.newest"].firstMatch.click()
        XCTAssertTrue(apply.isEnabled)
        XCTAssertTrue(app.staticTexts["Apply uses: Local 1 fields · Notion 0 fields · 0 unresolved"].firstMatch.exists)
        let notion = app.buttons["projects.sync.choice.remote.line.notion"].firstMatch
        let scroll = app.scrollViews["projects.sync.records"].firstMatch
        for _ in 0..<5 where !notion.isHittable { scroll.scroll(byDeltaX: 0, deltaY: -100) }
        let choicesShot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot()); choicesShot.name = "project-sync-newest-prepared"; choicesShot.lifetime = .keepAlways; add(choicesShot)
        if !notion.isHittable { print(app.debugDescription) }
        XCTAssertTrue(notion.isHittable); notion.click()
        XCTAssertTrue(app.staticTexts["Apply uses: Local 0 fields · Notion 1 fields · 0 unresolved"].firstMatch.exists)
        scroll.scroll(byDeltaX: 0, deltaY: -140)
        let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot()); attachment.name = "project-sync-color-choices-820"; attachment.lifetime = .keepAlways; add(attachment)
        app.buttons["Cancel"].firstMatch.click()
        XCTAssertEqual(try store.record(id: remoteID)?.local["line"]?.display, "New local one liner", "Preview never applies choices")
    }

    func testNewProjectDraftAndPendingStateSurviveRestart() {
        let app = launch()
        app.descendants(matching: .any)["projects.viewOptions"].firstMatch.click()
        app.menuItems["New project…"].firstMatch.click()
        let title = app.textFields["projects.property.title"]
        XCTAssertTrue(title.waitForExistence(timeout: 5)); title.click(); title.typeText("Offline project draft")
        app.buttons["projects.editor.save"].click()
        let row = app.staticTexts.matching(NSPredicate(format: "value == %@", "Offline project draft")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        let sync = app.descendants(matching: .any)["projects.sync"].firstMatch
        XCTAssertEqual(sync.value as? String, "0 need you, 1 waiting")
        app.terminate(); app.launch(); requireWindow(app)
        XCTAssertTrue(row.waitForExistence(timeout: 10)); row.doubleClick()
        XCTAssertTrue(app.staticTexts["Local draft"].firstMatch.waitForExistence(timeout: 10))
        XCTAssertEqual(app.descendants(matching: .any)["projects.sync"].firstMatch.value as? String, "0 need you, 1 waiting",
                       "Still waiting to be sent after a restart")
    }

}
