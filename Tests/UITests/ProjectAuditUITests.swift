import XCTest
import BetterWorkspaceCore

final class ProjectAuditUITests: IsolatedUITestCase {
    func testProjectSelectionShowsAssessmentRecommendationsAndOwnerFilters() throws {
        let project = Self.workspaceRoot.appendingPathComponent("Projects/Fixture project")
        let database = try Database(url: Self.fixtureRoot.appendingPathComponent("test.sqlite"))
        let record = ProjectStore(database: database).register(url: project)
        func decode<T: Decodable>(_ value: Any, as type: T.Type) throws -> T {
            try JSONDecoder().decode(type, from: JSONSerialization.data(withJSONObject: value))
        }
        let scores = Dictionary(uniqueKeysWithValues: ["FunctionalHealth", "Maintainability", "TestConfidence", "Documentation", "Completion", "CurrentUtility", "Uniqueness", "FuturePotential", "EaseOfProgress", "TechnicalRisk"].map { ($0, 6) })
        let audit = try decode(["version":1, "projectID":record.id, "assessedAt":"2026-10-04", "classification":"REPAIR", "recommendation":"Validate the disposable fixture", "scores":scores, "workPriorityScore":70, "validationCoverage":"Fixture checks", "confidence":"High", "nextWorkID":"agent", "nextAgentActionID":"agent", "nextUserActionID":"user", "notes":[], "commands":[]] as [String: Any], as: ProjectAuditAssessment.self)
        try ProjectAuditStore(database: database).save(audit)
        for (id, title, owner) in [("agent", "Repair parser fixture", "AGENT"), ("user", "Review fixture interaction", "USER"), ("blocked", "Blocked credential fixture", "AGENT")] {
            let meta = try decode(["version":1, "fingerprint":"audit:"+id, "priority":"P1", "actionScore":id == "agent" ? 90 : 80, "delegation":owner, "tags":["TESTING"], "requirements":[owner == "AGENT" ? "Coding Agent" : "Human Judgment"], "agentExecutability":owner == "AGENT" ? 100 : 0, "humanInvolvement":owner == "USER" ? 100 : 5, "estimatedEffort":"30–60 minutes", "category":"Validation", "reason":"Fixture evidence", "evidence":["README.md"], "agentSubtasks":owner == "AGENT" ? [title] : [], "userSubtasks":owner == "USER" ? [title] : [], "blockedBy":id == "blocked" ? ["Credentials Required"] : [], "isNextWork":id == "agent", "isNextAgentAction":id == "agent", "isNextUserAction":id == "user"] as [String: Any], as: WorkItemActionMetadata.self)
            var item = WorkItem(id: id, kind: .task, title: title, stage: .now, projectPath: "Projects/Fixture project", url: project)
            item.actionMetadata = meta
            _ = try WorkItemService().create(item, in: Self.workspaceRoot.appendingPathComponent("To Do"))
        }
        let app = isolatedApp(arguments: ["-bwStartArea", "Projects", "-bwWindowWidth", "820", "-bwWindowHeight", "520"])
        app.launch(); requireWindow(app)
        let row = app.staticTexts.matching(NSPredicate(format: "value == %@", "Fixture project")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10)); row.doubleClick()
        XCTAssertTrue(app.descendants(matching: .any)["projects.nextAction"].firstMatch.waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["WORKSPACE AUDIT"].firstMatch.exists)
        let scroll = app.scrollViews.matching(NSPredicate(format: "identifier == %@", "projects.plan")).firstMatch
        let assessment = app.buttons["Assessment & ranked backlog"].firstMatch
        for _ in 0..<6 where !assessment.isHittable || assessment.frame.maxY > scroll.frame.maxY - 30 { scroll.scroll(byDeltaX: 0, deltaY: -180) }
        assessment.click()
        for _ in 0..<3 where !app.staticTexts["WORKSPACE AUDIT"].firstMatch.exists { scroll.scroll(byDeltaX: 0, deltaY: -150) }
        let expanded = XCTAttachment(screenshot: app.windows.firstMatch.screenshot()); expanded.name = "project-audit-expanded"; expanded.lifetime = .keepAlways; add(expanded)
        XCTAssertTrue(app.staticTexts["WORKSPACE AUDIT"].firstMatch.waitForExistence(timeout: 5))
        for title in ["NEXT WORK", "NEXT AGENT ACTION", "NEXT USER ACTION"] {
            XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", title)).firstMatch.exists)
        }
        let risk = app.buttons["project.audit.score.TechnicalRisk"].firstMatch
        // "Hittable" is also true for a tile below the window; scroll until it is inside it.
        let windowBottom = app.windows.firstMatch.frame.maxY
        for _ in 0..<8 where !risk.isHittable || risk.frame.maxY > windowBottom - 20 { scroll.scroll(byDeltaX: 0, deltaY: -180) }
        if !risk.isHittable { print(app.debugDescription) }
        let scoreShot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot()); scoreShot.name = "project-audit-scores-820"; scoreShot.lifetime = .keepAlways; add(scoreShot)
        XCTAssertTrue(risk.isHittable); risk.click()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "value CONTAINS %@", "Higher means MORE risk")).firstMatch.waitForExistence(timeout: 5))
        let owner = app.popUpButtons["Owner"].firstMatch
        for _ in 0..<4 where !owner.isHittable || owner.frame.maxY > windowBottom - 20 { app.scrollViews.matching(NSPredicate(format: "identifier == %@", "projects.plan")).firstMatch.scroll(byDeltaX: 0, deltaY: -350) }
        if !owner.exists { print(app.debugDescription) }
        XCTAssertTrue(owner.exists); owner.click(); app.menuItems["Agent"].firstMatch.click()
        XCTAssertFalse(app.descendants(matching: .any)["project.audit.action.blocked"].firstMatch.exists)
        let action = app.buttons["project.audit.expand.agent"].firstMatch
        for _ in 0..<8 where !action.isHittable || action.frame.maxY > windowBottom - 20 { scroll.scroll(byDeltaX: 0, deltaY: -180) }
        XCTAssertTrue(action.isHittable); action.click()
        XCTAssertTrue(app.staticTexts["Fixture evidence"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Evidence: README.md"].firstMatch.exists)
        let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        attachment.name = "project-audit-ranked-backlog"; attachment.lifetime = .keepAlways; add(attachment)
    }
}
