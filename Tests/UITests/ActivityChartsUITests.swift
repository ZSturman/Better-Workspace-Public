import XCTest
import BetterWorkspaceCore

/// Uses private fixtures, including measured, lower-bound, absent and historical evidence.
final class ActivityChartsUITests: IsolatedUITestCase {
    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id].firstMatch
    }
    private func bar(_ chart: XCUIElement, _ name: String) -> XCUIElement {
        chart.otherElements.matching(NSPredicate(format: "label BEGINSWITH %@", name + ", ")).firstMatch
    }
    func testActivityBoundsPeriodsHistoryAndEmptyCharts() throws {
        let database = try Database(url: Self.fixtureRoot.appendingPathComponent("test.sqlite"))
        let store = ProjectStore(database: database)
        let service = Self.fixtureRoot.appendingPathComponent("Service")
        try FileManager.default.createDirectory(at: service, withIntermediateDirectories: true)
        var projects: [[String: Any]] = []
        let work = WorkItemService()
        for (name, age, lower) in [("Measured work", 10.0, false), ("Never measured", 26.0, true), ("Missing evidence", -1.0, false)] {
            let url = Self.workspaceRoot.appendingPathComponent("Projects/" + name)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            let record = store.register(url: url)
            store.setExternalIDs(watcherID: name, documentID: nil, for: record.id)
            store.setMetadata(.init(domain: "Technology", status: "Active"), for: record.id)
            for index in 0..<6 {
                _ = try work.create(WorkItem(id: name + "-\(index)", kind: .task, title: "Task \(index)", projectPath: "Projects/" + name, url: Self.fixtureRoot), in: Self.workspaceRoot.appendingPathComponent("To Do"))
            }
            if name == "Measured work" {
                _ = try work.create(WorkItem(id: "done", kind: .task, title: "Completed task", status: .completed,
                                            projectPath: "Projects/" + name, url: Self.fixtureRoot), in: Self.workspaceRoot.appendingPathComponent("To Do"))
            }
            let dimension: [String: Any] = ["value": age, "raw_value": age, "state": "provisional", "unit": "days",
                                           "window": lower ? ["bound": "lower"] : [:],
                                           "explanation": lower ? "At least 26 days without observed work" : "Last observed 10 days ago"]
            projects.append(["id": name, "name": name, "dimensions": age < 0 ? [:] : ["activity_age": dimension]])
        }
        func write(_ filename: String, _ data: Any) throws {
            try JSONSerialization.data(withJSONObject: ["data": data]).write(to: service.appendingPathComponent(filename))
        }
        try write("v1_scoring_projects.json", ["projects": projects])
        let date = DateFormatter(); date.dateFormat = "yyyy-MM-dd"; date.locale = Locale(identifier: "en_US_POSIX")
        let historical = date.string(from: Calendar.current.date(byAdding: .day, value: -45, to: Date())!)
        try write("v1_work-logs.json", [["id": "historical", "project_id": "Measured work", "project_name": "Measured work",
                                       "date_key": historical, "status": "prepared", "payload_json": "{\"active_minutes\":120,\"session_count\":1}"]])
        let app = isolatedApp(arguments: ["-bwStartArea", "Projects", "-bwServiceFixture", service.path,
                                          "-bwWindowWidth", "820", "-bwWindowHeight", "520"])
        app.launch(); requireForeground(app); requireWindow(app)
        XCTAssertTrue(app.staticTexts["Never measured"].firstMatch.waitForExistence(timeout: 25))
        element(app, "projects.presentation").radioButtons["Charts"].click()
        let customize = element(app, "projects.charts.customize")
        XCTAssertTrue(customize.waitForExistence(timeout: 10))
        // Keep only the relevant charts so their actual bars fit at minimum width.
        customize.click(); app.menuItems["Restore dashboard"].firstMatch.click()
        for title in ["Outstanding work", "Closest to done", "High value, not recently worked on", "Recent attention", "Time by domain"] {
            customize.click(); app.menuItems[title].firstMatch.click()
        }
        XCTAssertTrue(app.staticTexts["No project with five or more open records has gone 30 days without observed work. Try a shorter period."].waitForExistence(timeout: 10))
        let period = element(app, "projects.charts.period")
        period.click(); app.menuItems["7 days"].firstMatch.click()
        let chart = element(app, "projects.charts.stalled")
        XCTAssertTrue(bar(chart, "Never measured").waitForExistence(timeout: 10))
        XCTAssertTrue(bar(chart, "Measured work").exists)
        XCTAssertFalse(bar(chart, "Missing evidence").exists)
        XCTAssertTrue(bar(chart, "Never measured").label.contains("at least 26 days"),
                      chart.debugDescription)
        customize.click(); app.menuItems["Unfinished and inactive"].firstMatch.click()
        customize.click(); app.menuItems["Longest since observed work"].firstMatch.click()
        let idle = element(app, "projects.charts.idle")
        XCTAssertTrue(bar(idle, "Never measured").waitForExistence(timeout: 10))
        XCTAssertTrue(bar(idle, "Never measured").label.contains("at least 26 days"),
                      idle.debugDescription)
        XCTAssertFalse(bar(idle, "Measured work").label.contains("at least"))
        let shot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        shot.name = "activity-lower-bound-820"; shot.lifetime = .keepAlways; add(shot)
        customize.click(); app.menuItems["Longest since observed work"].firstMatch.click()
        customize.click(); app.menuItems["Recent attention"].firstMatch.click()
        XCTAssertTrue(app.staticTexts["No observed work in the last 7 days for these projects. Missing measurements are never counted as zero."].waitForExistence(timeout: 10))
        period.click(); app.menuItems["90 days"].firstMatch.click()
        let attention = element(app, "projects.charts.attention")
        XCTAssertTrue(bar(attention, "Measured work").waitForExistence(timeout: 10))
        XCTAssertEqual(bar(attention, "Measured work").label, "Measured work, 2 hours")
        XCTAssertFalse(bar(attention, "Never measured").exists)
        XCTAssertFalse(bar(attention, "Missing evidence").exists)
        customize.click(); app.menuItems["Recent attention"].firstMatch.click()
        customize.click(); app.menuItems["Closest to done"].firstMatch.click()
        let completion = bar(element(app, "projects.charts.nearDone"), "Measured work")
        XCTAssertTrue(completion.waitForExistence(timeout: 10))
        XCTAssertEqual(completion.label, "Measured work, 14 % complete · 6 open", "Percent must be announced only once")
    }
}
