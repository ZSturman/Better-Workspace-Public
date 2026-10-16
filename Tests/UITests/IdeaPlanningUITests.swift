import XCTest
import BetterWorkspaceCore

final class IdeaPlanningUITests: IsolatedUITestCase {
    func testIdeaPotentialScoringAndConfirmedFolderPromotionAtMinimumWidth() throws {
        let source = Self.workspaceRoot.appendingPathComponent("Ideas/Promotion candidate")
        try FileManager.default.createDirectory(at: source.appendingPathComponent("Media"), withIntermediateDirectories: true)
        try "Keep the original attachment".write(to: source.appendingPathComponent("Media/Original.txt"), atomically: true, encoding: .utf8)
        let fixture = Self.fixtureRoot.appendingPathComponent("Service")
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
        let json: [String: Any] = ["data": [["id": "promotion-idea", "title": "Promotion candidate", "path": source.path, "one_liner": "A complete idea", "planning": ["priority": 5, "ratings": ["qualityOfLife": 5], "potential": "milestone", "needsSetup": true]]]]
        try JSONSerialization.data(withJSONObject: json).write(to: fixture.appendingPathComponent("v1_ideas.json"))
        let app = isolatedApp(arguments: ["-bwStartArea", "Ideas", "-bwWindowWidth", "820", "-bwWindowHeight", "520", "-bwServiceFixture", fixture.path])
        app.launch(); requireForeground(app); requireWindow(app)
        let row = app.staticTexts["Promotion candidate"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 20)); row.click()
        let score = app.buttons["idea.planning.edit"].firstMatch
        XCTAssertTrue(score.waitForExistence(timeout: 10)); score.click()
        let potential = app.descendants(matching: .any)["idea.planning.potential"].firstMatch
        XCTAssertTrue(potential.waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["idea.planning.save"].isEnabled)
        let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot()); attachment.name = "idea-priority-scoring-mac-820"; attachment.lifetime = .keepAlways; add(attachment)
        app.buttons["Cancel"].firstMatch.click()
        app.descendants(matching: .any)["idea.promote"].firstMatch.click()
        app.menuItems["Move to Milestones…"].firstMatch.click()
        let confirm = try XCTUnwrap(panelButton(app, "Move entire folder to Milestones"))
        confirm.click()
        let destination = Self.workspaceRoot.appendingPathComponent("Milestones/Promotion candidate")
        let moved = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in FileManager.default.fileExists(atPath: destination.appendingPathComponent("Media/Original.txt").path) }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [moved], timeout: 25), .completed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("Media/Original.txt"), encoding: .utf8), "Keep the original attachment")
        let plan = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in WorkItemService().items(under: destination).contains { $0.kind == .milestone } }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [plan], timeout: 15), .completed)
    }
}
