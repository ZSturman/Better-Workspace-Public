import XCTest
import BetterWorkspaceCore

final class ProjectsExperienceUITests: IsolatedUITestCase {
    private static let defaultColumnCount = 7
    private func seedProjects() throws {
        let database = try Database(url: Self.fixtureRoot.appendingPathComponent("test.sqlite"))
        let store = ProjectStore(database: database)
        for (name, domain, status, phase) in [("AI Studio", "Technology", "Active", "Development"), ("AI Research", "Technology", "Queued", "Planning"), ("Retired Tool", "Technology", "Complete", "Development"), ("Painting", "Art", "Active", "Planning")] {
            let url = Self.workspaceRoot.appendingPathComponent("Projects/" + name)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            let record = store.register(url: url)
            store.setMetadata(.init(domain: domain, status: status, phase: phase), for: record.id)
        }
        let service = WorkItemService()
        for index in 0..<3 {
            _ = try service.create(WorkItem(id: "chart-work-\(index)", kind: .task, title: "Recorded task \(index)", projectPath: index < 2 ? "Projects/AI Studio" : "Projects/AI Research", url: Self.fixtureRoot), in: Self.workspaceRoot.appendingPathComponent("To Do"))
        }
    }
    private func launch(_ area: String = "Projects", extra: [String] = []) -> XCUIApplication {
        let app = isolatedApp(arguments: ["-bwStartArea", area, "-bwWindowWidth", "820", "-bwWindowHeight", "520"] + extra)
        app.launch(); requireForeground(app); requireWindow(app)
        return app
    }
    private func view(_ app: XCUIApplication, _ label: String) {
        let picker = app.descendants(matching: .any)["projects.presentation"].firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 20))
        picker.radioButtons[label].click()
    }
    private func options(_ app: XCUIApplication) { app.descendants(matching: .any)["projects.viewOptions"].firstMatch.click() }
    private func shot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot()); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
    func testExclusionSharedViewsSavedConfigurationAndHeaderMenu() throws {
        try seedProjects()
        let app = launch()
        XCTAssertTrue(app.staticTexts["Retired Tool"].firstMatch.waitForExistence(timeout: 25))
        options(app); app.menuItems["Presets"].firstMatch.hover(); app.menuItems["Active Projects"].firstMatch.click()
        let removed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in !app.staticTexts["Retired Tool"].firstMatch.exists }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [removed], timeout: 10), .completed)
        XCTAssertTrue(app.staticTexts["AI Studio"].firstMatch.exists)
        let filterButton = app.descendants(matching: .any)["projects.filterButton"].firstMatch
        XCTAssertTrue(filterButton.waitForExistence(timeout: 5)); filterButton.click()
        let domain = app.popUpButtons["projects.filter.property"].firstMatch
        XCTAssertTrue(domain.waitForExistence(timeout: 5)); domain.click(); app.menuItems["Domain"].firstMatch.click()
        let tech = app.checkBoxes["projects.filter.domain.Technology"].firstMatch
        XCTAssertTrue(tech.waitForExistence(timeout: 5)); tech.click()
        app.buttons["Done"].firstMatch.click()
        for presentation in ["Cards", "Decide", "Charts", "Table"] {
            view(app, presentation)
            XCTAssertFalse(app.staticTexts["Retired Tool"].firstMatch.exists)
            XCTAssertFalse(app.staticTexts["Painting"].firstMatch.exists)
            if presentation == "Decide" {
                // Both remaining projects have open Next work, so none is excluded from Decide.
                let unranked = app.descendants(matching: .any)["projects.decide.unranked"].firstMatch
                XCTAssertTrue(unranked.waitForExistence(timeout: 10)); unranked.click()
                XCTAssertTrue(app.staticTexts["Every matching project can appear above."].firstMatch.waitForExistence(timeout: 5))
            }
        }
        // Native header menu uses the same array as View Options > Columns.
        let header = app.buttons["Name"].firstMatch
        XCTAssertTrue(header.waitForExistence(timeout: 5)); header.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).rightClick()
        XCTAssertTrue(app.menuItems["Restore default columns"].firstMatch.waitForExistence(timeout: 5))
        app.menuItems["Score"].firstMatch.click()
        // Regression: changing columns once rebuilt them around a retained outline column, duplicating Name.
        XCTAssertTrue(app.buttons["Score"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(tableColumns(app).count, ProjectsExperienceUITests.defaultColumnCount + 1)
        options(app); app.menuItems["Saved views"].firstMatch.hover(); app.menuItems["Save current view…"].firstMatch.click()
        let name = app.textFields.matching(NSPredicate(format: "placeholderValue == %@", "View name")).firstMatch
        XCTAssertTrue(name.waitForExistence(timeout: 5)); name.typeText("Technology focus")
        let save = try XCTUnwrap(panelButton(app, "Save")); save.click()
        shot(app, "projects-filtered-table-820")
        app.terminate(); app.launch(); requireWindow(app)
        XCTAssertTrue(app.staticTexts["AI Studio"].firstMatch.waitForExistence(timeout: 25))
        XCTAssertFalse(app.staticTexts["Retired Tool"].firstMatch.exists)
        options(app); app.menuItems["Saved views"].firstMatch.hover()
        XCTAssertTrue(app.menuItems["Technology focus"].firstMatch.waitForExistence(timeout: 5))
        app.typeKey(.escape, modifierFlags: [])
        app.typeKey(.escape, modifierFlags: [])
        view(app, "Charts")
        XCTAssertTrue(app.descendants(matching: .any)["projects.charts.customize"].firstMatch.waitForExistence(timeout: 10))
        shot(app, "projects-analytics-820")
        let openChart = app.descendants(matching: .any)["projects.charts.open.backlog"].firstMatch
        XCTAssertTrue(openChart.waitForExistence(timeout: 10)); openChart.click()
        let project = app.menuItems["AI Studio"].firstMatch
        XCTAssertTrue(project.waitForExistence(timeout: 5)); project.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        XCTAssertTrue(app.descendants(matching: .any)["projects.workspace"].firstMatch.waitForExistence(timeout: 15))
    }
    private func countLabel(_ app: XCUIApplication, _ pattern: String) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "value MATCHES %@ OR label MATCHES %@", pattern, pattern)).firstMatch
    }
    func testNativeNameSortPersistsAcrossRestart() throws {
        try seedProjects()
        let app = launch()
        let header = app.buttons["Name"].firstMatch
        XCTAssertTrue(header.waitForExistence(timeout: 20))
        func expectNames(_ expected: [String]) {
            let sorted = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                let names = app.outlines["projects.table"].staticTexts.matching(NSPredicate(
                    format: "identifier BEGINSWITH %@ AND identifier ENDSWITH %@", "projects.row.", ".name"))
                    .allElementsBoundByIndex.map { $0.value as? String ?? $0.label }
                return names == expected
            }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [sorted], timeout: 10), .completed)
        }
        let ascending = ["AI Research", "AI Studio", "Fixture project", "Painting", "Retired Tool"]
        // Native outline headers expose a sort button but XCTest's automatic
        // scroll-to-visible can reject it. Click its visible header frame.
        header.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click(); expectNames(ascending)
        header.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click(); expectNames(Array(ascending.reversed()))
        app.terminate(); app.launch(); requireWindow(app)
        expectNames(Array(ascending.reversed()))
        shot(app, "projects-native-name-sort-820")
    }
    /// Hundreds of projects with work records: loading, filtering, every presentation and
    /// the analytics dashboard must stay interactive. Budgets include XCUITest overhead.
    func testFourHundredProjectsStayResponsiveAcrossViews() throws {
        let database = try Database(url: Self.fixtureRoot.appendingPathComponent("test.sqlite"))
        let store = ProjectStore(database: database)
        let statuses = ["Active", "Queued", "Paused", "Complete", "Archived"], domains = ["Technology", "Art", "Writing", "Research"]
        let service = WorkItemService()
        for index in 0..<400 {
            let name = String(format: "Load %03d", index)
            let url = Self.workspaceRoot.appendingPathComponent("Projects/" + name)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            let record = store.register(url: url)
            store.setMetadata(.init(domain: domains[index % 4], status: statuses[index % 5], phase: index.isMultiple(of: 3) ? "Planning" : "Development"), for: record.id)
            if index.isMultiple(of: 4) {
                _ = try service.create(WorkItem(id: "load-work-\(index)", kind: .task, title: "Load task \(index)", projectPath: "Projects/" + name, url: Self.fixtureRoot), in: Self.workspaceRoot.appendingPathComponent("To Do"))
            }
        }
        var timings: [String] = []
        // Measured from the end of the synthesized interaction (XCUITest menu hovers alone
        // take seconds) until the result is on screen; polling adds up to about a second.
        func timed(_ name: String, budget: TimeInterval, _ element: XCUIElement, after action: () -> Void) {
            let interaction = Date(); action()
            let start = Date()
            XCTAssertTrue(element.waitForExistence(timeout: budget * 4), name)
            let elapsed = Date().timeIntervalSince(start)
            timings.append("\(name): \(String(format: "%.2f", elapsed))s (interaction \(String(format: "%.1f", start.timeIntervalSince(interaction)))s)")
            XCTAssertLessThan(elapsed, budget, name)
        }
        let app = launch()
        timed("initial load", budget: 30, countLabel(app, "40[0-9] of 40[0-9] projects")) {}
        timed("Active Projects preset", budget: 2.5, countLabel(app, "2[0-9][0-9] of 40[0-9] projects")) {
            options(app); app.menuItems["Presets"].firstMatch.hover(); app.menuItems["Active Projects"].firstMatch.click()
        }
        // Load 017 is Paused, so the Active Projects preset keeps it; search narrows to it alone.
        timed("search within filters", budget: 2.5, countLabel(app, "1 of 40[0-9] projects")) {
            let search = app.searchFields.firstMatch.exists ? app.searchFields.firstMatch : app.textFields.firstMatch
            search.click(); search.typeText("Load 017")
        }
        for (presentation, identifier) in [("Cards", "projects.portfolio"), ("Decide", "projects.decide"), ("Charts", "projects.charts.backlog"), ("Table", "projects.table")] {
            timed(presentation, budget: 2.5, app.descendants(matching: .any)[identifier].firstMatch) { view(app, presentation) }
        }
        let report = XCTAttachment(string: timings.joined(separator: "\n")); report.name = "projects-400-timings"; report.lifetime = .keepAlways; add(report)
        print("Projects 400 timings:", timings)
        shot(app, "projects-400-table-820")
    }
    func testPotentialProjectDetailsAndExternalStatusPromotionKeepOneGraphRecord() throws {
        let sourceURL = Self.workspaceRoot.appendingPathComponent("Ideas/Studio")
        try FileManager.default.createDirectory(at: sourceURL.appendingPathComponent("Media"), withIntermediateDirectories: true)
        try "Original attachment".write(to: sourceURL.appendingPathComponent("Media/Original.txt"), atomically: true, encoding: .utf8)
        let service = Self.fixtureRoot.appendingPathComponent("Service")
        try FileManager.default.createDirectory(at: service, withIntermediateDirectories: true)
        let details = IdeaProjectDetails(metadata: .init(domain: "Technology", phase: "Planning", projectType: "Application"), oneLiner: "Make something useful", summary: "All existing files stay together")
        let planning = IdeaPlanning(potential: .project, needsSetup: false, project: details)
        let planningJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(planning))
        let json: [String: Any] = ["data": [["id": "studio-id", "title": "Studio", "path": sourceURL.path, "planning": planningJSON]]]
        try JSONSerialization.data(withJSONObject: json).write(to: service.appendingPathComponent("v1_ideas.json"))
        let database = try Database(url: Self.fixtureRoot.appendingPathComponent("test.sqlite"))
        let store = try ProjectGraphStore(database: database)
        let source = ProjectGraphSource(id: "projects", title: "Projects", kind: .projects, schema: ProjectJSON([
            "Name": ["id": "title", "type": "title"], "Status": ["id": "status", "type": "status"], "Local Directory": ["id": "directory", "type": "rich_text"],
            "domain": ["id": "domain", "type": "select", "select": ["options": [["name": "Technology"]]]], "Type": ["id": "type", "type": "multi_select"], "Phase": ["id": "phase", "type": "select"], "one liner": ["id": "line", "type": "rich_text"], "summary": ["id": "summary", "type": "rich_text"]]))
        try store.write("sources", [source])
        var record = try IdeaProjectBridge.applying(serviceID: "studio-id", title: "Studio", path: sourceURL.canonicalPath, details: details, tags: [], ratings: [:], to: nil, source: source)
        record.pageID = "stable-page"; record.baseline = record.local; record.remote = record.local
        record.remote["status"] = ProjectJSON(["type": "status", "status": ["name": "Active"]]); record.editedAt = Date()
        try store.save(record)
        let app = launch("Ideas", extra: ["-bwServiceFixture", service.path])
        let row = app.staticTexts["Studio"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 20))
        XCTAssertTrue(app.descendants(matching: .any)["idea.row.notionPromotion"].firstMatch.waitForExistence(timeout: 10),
                      "The list says which idea's Notion status changed without selecting it first")
        row.click()
        let actions = app.descendants(matching: .any)["idea.promote"].firstMatch
        XCTAssertTrue(actions.waitForExistence(timeout: 15))
        app.buttons["idea.planning.edit"].firstMatch.click()
        let line = app.textFields["idea.project.oneLiner"].firstMatch
        XCTAssertTrue(line.waitForExistence(timeout: 10)); XCTAssertEqual(line.value as? String, details.oneLiner)
        shot(app, "idea-project-details-820")
        app.buttons["Cancel"].firstMatch.click()
        actions.click()
        let review = app.menuItems["idea.notion.reviewPromotion"].firstMatch
        XCTAssertTrue(review.waitForExistence(timeout: 10)); review.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        let confirm = try XCTUnwrap(panelButton(app, "Move entire folder to Projects")); confirm.click()
        let destination = Self.workspaceRoot.appendingPathComponent("Projects/Studio")
        let moved = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            (try? store.record(id: record.id)?.localPath) == destination.canonicalPath && FileManager.default.fileExists(atPath: destination.appendingPathComponent("Media/Original.txt").path)
        }, object: nil)
        let result = XCTWaiter.wait(for: [moved], timeout: 25)
        if result != .completed {
            let commands = try WidgetCommandStore(directory: Self.fixtureRoot.appendingPathComponent("Widgets"))
            print("Promotion receipts:", try commands.records().map { "\($0.state.rawValue): \($0.message ?? "")" })
            print("Promotion source exists:", FileManager.default.fileExists(atPath: sourceURL.path), "destination exists:", FileManager.default.fileExists(atPath: destination.path))
            print("Promotion binding:", try store.record(id: record.id)?.localPath as Any)
            shot(app, "promotion-recovery-state")
        }
        XCTAssertEqual(result, .completed)
        let promoted = try XCTUnwrap(store.record(id: record.id))
        XCTAssertEqual(promoted.pageID, "stable-page"); XCTAssertNotNil(promoted.localProjectID)
        XCTAssertEqual(promoted.value("Local Directory", source: source).display, destination.canonicalPath)
        XCTAssertEqual(promoted.value("Status", source: source).display, "Active")
        XCTAssertEqual(try store.records().filter { $0.serviceRecordID == "studio-id" }.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: sourceURL.path))
    }

    /// The app stops after the folder moved and the project was bound, but before the idea
    /// service acknowledged the move. A restart resumes the same command: one project, one
    /// Notion record, the same page and every file intact.
    func testInterruptedPromotionResumesAfterRestartWithoutDuplicates() throws {
        let sourceURL = Self.workspaceRoot.appendingPathComponent("Ideas/Resume")
        try FileManager.default.createDirectory(at: sourceURL.appendingPathComponent("Media"), withIntermediateDirectories: true)
        try "Original attachment".write(to: sourceURL.appendingPathComponent("Media/Original.txt"), atomically: true, encoding: .utf8)
        let service = Self.fixtureRoot.appendingPathComponent("Service")
        try FileManager.default.createDirectory(at: service, withIntermediateDirectories: true)
        let details = IdeaProjectDetails(metadata: .init(domain: "Technology", phase: "Planning"), oneLiner: "Resume safely", summary: "")
        let planning = IdeaPlanning(potential: .project, needsSetup: false, project: details)
        let json: [String: Any] = ["data": [["id": "resume-id", "title": "Resume", "path": sourceURL.path, "planning": try JSONSerialization.jsonObject(with: JSONEncoder().encode(planning))]]]
        try JSONSerialization.data(withJSONObject: json).write(to: service.appendingPathComponent("v1_ideas.json"))
        let unavailable = service.appendingPathComponent("relocate-unavailable")
        try Data().write(to: unavailable)
        let database = try Database(url: Self.fixtureRoot.appendingPathComponent("test.sqlite"))
        let store = try ProjectGraphStore(database: database)
        let source = ProjectGraphSource(id: "projects", title: "Projects", kind: .projects, schema: ProjectJSON([
            "Name": ["id": "title", "type": "title"], "Status": ["id": "status", "type": "status"], "Local Directory": ["id": "directory", "type": "rich_text"]]))
        try store.write("sources", [source])
        var record = try IdeaProjectBridge.applying(serviceID: "resume-id", title: "Resume", path: sourceURL.canonicalPath, details: details, tags: [], ratings: [:], to: nil, source: source)
        record.pageID = "resume-page"; record.baseline = record.local; record.remote = record.local
        record.remote["status"] = ProjectJSON(["type": "status", "status": ["name": "Active"]]); record.editedAt = Date()
        try store.save(record)
        let destination = Self.workspaceRoot.appendingPathComponent("Projects/Resume")
        let commands = try WidgetCommandStore(directory: Self.fixtureRoot.appendingPathComponent("Widgets"))
        func checkpoint() -> IdeaPromotionCheckpoint? {
            guard let edit = try? commands.records().compactMap(\.edit).first(where: { $0.operation == .promoteIdea }) else { return nil }
            return try? commands.value("idea-promotion:" + edit.id.uuidString, as: IdeaPromotionCheckpoint.self)
        }
        func projectsAtDestination() -> Int { ProjectStore(database: database).allRecords().filter { URL(fileURLWithPath: $0.lastPath).canonicalPath == destination.canonicalPath }.count }

        let app = launch("Ideas", extra: ["-bwServiceFixture", service.path])
        let row = app.staticTexts["Resume"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 20)); row.click()
        let actions = app.descendants(matching: .any)["idea.promote"].firstMatch
        XCTAssertTrue(actions.waitForExistence(timeout: 15)); actions.click()
        let review = app.menuItems["idea.notion.reviewPromotion"].firstMatch
        XCTAssertTrue(review.waitForExistence(timeout: 10)); review.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        try XCTUnwrap(panelButton(app, "Move entire folder to Projects")).click()

        let interrupted = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in checkpoint()?.projectBound == true }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [interrupted], timeout: 25), .completed, "The move and project binding complete before the service acknowledgement")
        XCTAssertNotEqual(checkpoint()?.applied, true, "Without the idea service the promotion stays open")
        XCTAssertFalse(FileManager.default.fileExists(atPath: sourceURL.path))
        XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("Media/Original.txt"), encoding: .utf8), "Original attachment")
        XCTAssertEqual(projectsAtDestination(), 1)
        XCTAssertEqual(try store.record(id: record.id)?.localPath, destination.canonicalPath)

        // Interruption: quit, bring the service back, relaunch.
        app.terminate()
        try FileManager.default.removeItem(at: unavailable)
        app.launch(); requireWindow(app)
        let resumed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in checkpoint()?.applied == true }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [resumed], timeout: 30), .completed, "The same command resumes after restart")
        XCTAssertEqual(projectsAtDestination(), 1, "Resuming does not register the project twice")
        let graph = try store.records().filter { $0.serviceRecordID == "resume-id" }
        XCTAssertEqual(graph.count, 1)
        XCTAssertEqual(graph.first?.pageID, "resume-page")
        XCTAssertEqual(graph.first?.value("Status", source: source).display, "Active")
        XCTAssertEqual(graph.first?.value("Local Directory", source: source).display, destination.canonicalPath)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: destination.appendingPathComponent("Media").path), ["Original.txt"])
    }
}
