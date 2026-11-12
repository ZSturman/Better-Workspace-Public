import XCTest
import AppKit
import BetterWorkspaceCore

final class ProjectControlUITests: IsolatedUITestCase {
    private func wait(_ title: String, _ condition: @escaping () -> Bool) {
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 25), .completed, title)
    }
    private func screenshot(_ name: String, _ app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }

    func testNewFinderProjectAppearsInOverviewAndProjectsAtMinimumWidth() throws {
        let app = isolatedApp(arguments: ["-bwWindowWidth", "820", "-bwWindowHeight", "520"])
        app.launch(); requireForeground(app); requireWindow(app)
        let project = Self.workspaceRoot.appendingPathComponent("Projects/AI Assisted Visual Game Creation Studio")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: false)
        let attention = app.buttons.containing(NSPredicate(format: "label CONTAINS %@", "AI Assisted Visual Game Creation Studio")).firstMatch
        XCTAssertTrue(attention.waitForExistence(timeout: 25), "A new Finder folder must surface without a manual refresh")
        screenshot("new-project-overview-820", app)
        revealSidebarRow(app, "sidebar.folder.Projects").click()
        let shortcut = app.buttons.containing(NSPredicate(format: "label CONTAINS %@", "AI Assisted Visual Game Creation Studio")).firstMatch
        XCTAssertTrue(shortcut.waitForExistence(timeout: 15))
        XCTAssertTrue(shortcut.label.contains("New project created"))
        screenshot("new-project-projects-820", app)
        let addNotion = app.buttons["Add to Notion…"].firstMatch
        XCTAssertTrue(addNotion.waitForExistence(timeout: 10))
        addNotion.click()
        XCTAssertTrue(app.staticTexts["Notion settings"].firstMatch.waitForExistence(timeout: 10))
        app.buttons["Done"].firstMatch.click()
        shortcut.click()
        XCTAssertTrue(app.descendants(matching: .any)["projects.workspace"].firstMatch.waitForExistence(timeout: 15))
    }

    func testMobileScoreCommandChangesMacNextActionAndRejectsStaleDraft() throws {
        let projectRoot = Self.workspaceRoot.appendingPathComponent("Projects")
        for name in ["Low", "High"] { try FileManager.default.createDirectory(at: projectRoot.appendingPathComponent(name), withIntermediateDirectories: true) }
        let db = try Database(url: Self.fixtureRoot.appendingPathComponent("test.sqlite"))
        let projects = ProjectStore(database: db)
        let low = projects.register(url: projectRoot.appendingPathComponent("Low")), high = projects.register(url: projectRoot.appendingPathComponent("High"))
        projects.setRating(4, metricID: "qualityOfLife", for: low.id)
        let service = WorkItemService()
        _ = try service.create(WorkItem(id: "low-task", kind: .task, title: "Low urgent task", stage: .now, priority: .high, projectPath: "Projects/Low", url: Self.fixtureRoot), in: Self.workspaceRoot.appendingPathComponent("To Do"))
        _ = try service.create(WorkItem(id: "high-task", kind: .task, title: "Highest scored project task", stage: .next, priority: .low, projectPath: "Projects/High", url: Self.fixtureRoot), in: Self.workspaceRoot.appendingPathComponent("To Do"))
        let store = try WidgetCommandStore(directory: Self.fixtureRoot.appendingPathComponent("Widgets"))
        let original = MobileProjectDetails(path: "Projects/High", projectID: high.id, ratings: [:])
        let change = MobileProjectEdit(original: original, ratings: ["qualityOfLife": 5], oneLiner: "Phone details", summary: "")
        let edit = MobilePlanningEdit(operation: .saveProject, title: "High", projectEdit: change)
        try store.append(.planning(edit), stream: "workspace")
        let app = isolatedApp(arguments: ["-bwWindowWidth", "820", "-bwWindowHeight", "520"])
        app.launch(); requireForeground(app); requireWindow(app)
        wait("Score command receives a result") { (try? store.records().first { $0.id == edit.id }?.state) == .applied }
        XCTAssertEqual(projects.ratings(for: high.id), change.ratings)
        XCTAssertTrue(app.buttons["overview.nextAction.high-task"].waitForExistence(timeout: 20))
        screenshot("score-ranked-next-action-820", app)
        var stale = change; stale.oneLiner = "Stale phone details"
        let refused = MobilePlanningEdit(operation: .saveProject, title: "High", projectEdit: stale)
        try store.append(.planning(refused), stream: "workspace")
        wait("Stale phone draft is refused") { (try? store.records().first { $0.id == refused.id }?.state) == .rejected }
        XCTAssertEqual(projects.description(for: high.id).oneLiner, "Phone details")
    }

    func testScheduledIngestAndBoundedProjectPreviewsUsePrivateMetadataOnly() throws {
        let projectURL = Self.workspaceRoot.appendingPathComponent("Projects/Fixture project")
        let imageURL = projectURL.appendingPathComponent("Media/Example.png")
        try FileManager.default.createDirectory(at: imageURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let image = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 48, pixelsHigh: 32, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        for x in 0..<48 { for y in 0..<32 { image.setColor(.systemTeal, atX: x, y: y) } }
        let png = try XCTUnwrap(image.representation(using: .png, properties: [:])); try png.write(to: imageURL)
        let original = try Data(contentsOf: imageURL)
        try "# Fixture capture\nKeep this original.".write(to: Self.inboxRoot.appendingPathComponent("Fixture capture.md"), atomically: true, encoding: .utf8)
        let app = isolatedApp(arguments: ["-bwStartArea", "Ingest", "-bwWindowWidth", "820", "-bwWindowHeight", "520"])
        app.launch(); requireForeground(app); requireWindow(app)
        app.buttons["sidebar.ingest"].firstMatch.tap()
        XCTAssertTrue(app.descendants(matching: .any)["ingest.priority"].firstMatch.waitForExistence(timeout: 20))
        XCTAssertTrue(app.descendants(matching: .any)["ingest.reviewLater"].firstMatch.exists)
        screenshot("ingest-priority-and-return-820", app)
        let db = try Database(url: Self.fixtureRoot.appendingPathComponent("test.sqlite")), projects = ProjectStore(database: db)
        let record = projects.register(url: projectURL)
        let request = MobileWorkspaceEntry(path: "Projects/Fixture project", parentPath: "Projects", name: "Fixture project", isDirectory: true, revision: 1,
            projectDetails: MobileProjectDetails(path: "Projects/Fixture project", projectID: record.id))
        let store = try WidgetCommandStore(directory: Self.fixtureRoot.appendingPathComponent("Widgets"))
        let edit = MobilePlanningEdit(operation: .previewProject, title: request.name, originalEntry: request)
        try store.append(.planning(edit), stream: "workspace")
        wait("Bounded previews receive a result") { (try? store.records().first { $0.id == edit.id }?.state) == .applied }
        let payload = try XCTUnwrap(db.query("SELECT payload FROM mobile_project_previews WHERE project_id=?", [.text(record.id)], row: { $0.string(0) }).first)
        let previews = try JSONDecoder().decode([MobileFilePreview].self, from: Data(payload.utf8))
        XCTAssertTrue(previews.contains { $0.name == "Example.png" && $0.jpeg?.isEmpty == false })
        XCTAssertTrue(previews.contains { $0.name == "README.md" && $0.text?.isEmpty == false })
        XCTAssertLessThanOrEqual(previews.count, 6)
        XCTAssertTrue(previews.allSatisfy { ($0.jpeg?.count ?? 0) <= 32_768 })
        XCTAssertEqual(try Data(contentsOf: imageURL), original)
        let capture = Self.inboxRoot.appendingPathComponent("Fixture capture.md")
        let date = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: capture.path)[.modificationDate] as? Date)
        let schedule = MobilePlanningEdit(operation: .scheduleCapture, title: capture.lastPathComponent,
            captureReview: MobileCaptureReview(capture: DashboardCapture(name: capture.lastPathComponent, modified: date), priority: 5, until: Date().addingTimeInterval(86_400)))
        try store.append(.planning(schedule), stream: "workspace")
        wait("Capture schedule receives a result") { (try? store.records().first { $0.id == schedule.id }?.state) == .applied }
        let bundle = Self.inboxRoot.appendingPathComponent("Drop Project")
        let bundleDate = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: bundle.path)[.modificationDate] as? Date)
        let deferBundle = MobilePlanningEdit(operation: .scheduleCapture, title: "Drop Project", captureReview: MobileCaptureReview(capture: DashboardCapture(name: "Drop Project", modified: bundleDate), priority: 3, until: Date().addingTimeInterval(86_400)))
        try store.append(.planning(deferBundle), stream: "workspace")
        wait("Folder scheduling receives a result") { (try? store.records().first { $0.id == deferBundle.id }?.state) == .applied }
        wait("Deferred-only inbox clears automatic focus") { app.staticTexts["Nothing due now"].exists }
        screenshot("ingest-nothing-due-820", app)
    }
}


extension ProjectControlUITests {
    func testNativeProjectDetailsAndFeaturedStarPersist() throws {
        let url = Self.workspaceRoot.appendingPathComponent("Projects/Creative fixture")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let database = try Database(url: Self.fixtureRoot.appendingPathComponent("test.sqlite"))
        let store = ProjectStore(database: database), record = store.register(url: url)
        store.setMetadata(.init(domain: "Art", status: "Active", projectType: "Animation, Collection"), for: record.id)
        store.setPortfolioDetails(.init(githubURL: "https://github.com/example/project"), for: record.id)
        let source = ProjectGraphSource(id: "fixture-projects", title: "Projects", kind: .projects, schema: ProjectJSON([
            "Name": ["id": "title", "type": "title"], "domain": ["id": "d", "type": "select"],
            "Status": ["id": "s", "type": "status"], "Featured": ["id": "f", "type": "checkbox"]]))
        var graph = ProjectGraphRecord(sourceID: source.id, kind: .projects)
        graph.localProjectID = record.id; graph.localPath = url.canonicalPath
        graph.set("Name", value: ProjectJSON([["type": "text", "text": ["content": "Creative fixture"]]]), source: source)
        graph.set("domain", value: ProjectJSON(["name": "Older graph domain"]), source: source)
        graph.set("Featured", value: .bool(false), source: source)
        let graphStore = try ProjectGraphStore(database: database)
        try graphStore.write("sources", [source]); try graphStore.save(graph)
        let app = isolatedApp(arguments: ["-bwStartArea", "Projects", "-bwWindowWidth", "820", "-bwWindowHeight", "520"])
        app.launch(); defer { app.terminate() }; requireForeground(app)
        let title = app.staticTexts["Creative fixture"].firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 20))
        // Simulate an unrelated newer private edit after the graph was loaded.
        store.setMetadata(.init(domain: "Art", status: "Active", projectType: "Animation, Collection"), for: record.id)
        let star = app.buttons["Toggle featured Creative fixture"].firstMatch
        XCTAssertTrue(star.waitForExistence(timeout: 10)); star.click()
        wait("Table star persisted") { store.portfolioDetails(for: record.id).featured == true }
        XCTAssertEqual(store.metadata(for: record.id).domain, "Art", "A flag draft must not replay older unrelated graph values")
        screenshot("project-table-native-820", app)
        title.doubleClick()
        let featured = app.checkBoxes["project.featured"]
        XCTAssertTrue(featured.waitForExistence(timeout: 10)); XCTAssertEqual(featured.value as? Int, 1)
        let scroll = app.scrollViews.firstMatch
        for _ in 0..<5 where featured.frame.maxY > scroll.frame.maxY - 30 { scroll.scroll(byDeltaX: 0, deltaY: -150) }
        featured.click()
        XCTAssertEqual(featured.value as? Int, 0)
        app.buttons["project.details.save"].click()
        screenshot("project-details-after-save", app)
        wait("Details save persisted") { store.portfolioDetails(for: record.id).featured == false }
        XCTAssertEqual(store.metadata(for: record.id).projectType, "Animation, Collection")
        screenshot("project-details-native-820", app)
    }
}
