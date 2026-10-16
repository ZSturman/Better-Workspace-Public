import XCTest
import BetterWorkspaceCore

final class LMStudioUITests: IsolatedUITestCase {
    private func shoot(_ app: XCUIApplication, _ name: String) {
        let sheet = app.sheets.firstMatch
        let screenshot = sheet.exists ? sheet.screenshot() : app.descendants(matching: .any)["lmStudio.sheet"].firstMatch.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
    private var projectURL: URL { Self.workspaceRoot.appendingPathComponent("Projects/Fixture project") }
    private func launch(response: String? = nil, width: Int = 820, delayMS: Int = 0) throws -> XCUIApplication {
        let db = try Database(url: Self.fixtureRoot.appendingPathComponent("test.sqlite"))
        let projects = ProjectStore(database: db)
        let record = projects.register(url: projectURL)
        projects.setDescription(ProjectDescription(oneLiner: "Original line", summary: "A garden journal."), for: record.id)
        let tags = TagStore(database: db)
        _ = tags.createTag(Tag(id: "tag-garden", name: "Gardening"))
        let content = response ?? #"{"one_liner":"Track plants and garden observations.","existing_tag_ids":["tag-garden"],"new_tags":[{"name":"Plant diary","reason":"No existing tag describes a plant diary specifically."}]}"#
        let data = try JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": content], "finish_reason": "stop"]]])
        let fixture = Self.fixtureRoot.appendingPathComponent("lm-response.json"); try data.write(to: fixture)
        let app = isolatedApp(arguments: ["-bwStartArea", "Projects", "-bwWindowWidth", String(width), "-bwWindowHeight", width == 820 ? "520" : "900", "-bwLMStudioFixture", fixture.path, "-bwLMStudioFixtureDelayMS", String(delayMS)])
        app.launch(); requireWindow(app)
        let project = app.staticTexts.matching(NSPredicate(format: "value == %@", "Fixture project")).firstMatch
        XCTAssertTrue(project.waitForExistence(timeout: 15)); project.doubleClick()
        let details = app.radioButtons["Details"].firstMatch
        XCTAssertTrue(details.waitForExistence(timeout: 10)); details.click()
        let open = app.buttons["project.lmStudio.open"].firstMatch
        XCTAssertTrue(open.waitForExistence(timeout: 10)); open.click()
        return app
    }
    private func prepare(_ app: XCUIApplication) {
        let endpoint = app.textFields["lmStudio.endpoint"].firstMatch
        XCTAssertTrue(endpoint.waitForExistence(timeout: 5))
        let model = app.popUpButtons["lmStudio.model"].firstMatch
        XCTAssertTrue(model.waitForExistence(timeout: 5), "The available fixture model is chosen automatically")
        app.buttons["lmStudio.prepare"].firstMatch.click()
        XCTAssertTrue(app.staticTexts["lmStudio.payload"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["lmStudio.generate"].firstMatch.isEnabled)
    }
    func testPreviewCancelThenSelectEditApplyAndRelaunch() throws {
        let app = try launch(); prepare(app)
        shoot(app, "lm-studio-request-820")
        let db = try Database(url: Self.fixtureRoot.appendingPathComponent("test.sqlite"))
        let projects = ProjectStore(database: db), tags = TagStore(database: db)
        let record = try XCTUnwrap(projects.record(for: projectURL))
        app.buttons["lmStudio.generate"].firstMatch.click()
        let line = app.textFields["lmStudio.line"].firstMatch
        XCTAssertTrue(line.waitForExistence(timeout: 5))
        XCTAssertEqual(projects.description(for: record.id).oneLiner, "Original line")
        XCTAssertEqual(tags.allTags().count, 1)
        XCTAssertTrue(tags.tags(for: projectURL).isEmpty)
        XCTAssertTrue(app.buttons["lmStudio.apply"].firstMatch.label.contains("(2)"))
        shoot(app, "lm-studio-choices-820")
        app.buttons["lmStudio.cancel"].firstMatch.click()
        XCTAssertEqual(projects.description(for: record.id).oneLiner, "Original line")
        app.buttons["project.lmStudio.open"].firstMatch.click()
        // Same connection persists; prepare again without changing it.
        app.buttons["lmStudio.prepare"].firstMatch.click()
        XCTAssertTrue(app.staticTexts["lmStudio.payload"].firstMatch.waitForExistence(timeout: 5))
        app.buttons["lmStudio.generate"].firstMatch.click()
        XCTAssertTrue(line.waitForExistence(timeout: 5))
        line.click(); line.typeKey("a", modifierFlags: .command); line.typeText("A reviewed garden journal.")
        let newTag = app.checkBoxes["lmStudio.tag.Plant diary"].firstMatch
        XCTAssertTrue(newTag.exists); newTag.click()
        XCTAssertTrue(app.buttons["lmStudio.apply"].firstMatch.label.contains("(3)"))
        app.buttons["lmStudio.apply"].firstMatch.click()
        XCTAssertTrue(app.buttons["project.lmStudio.open"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(projects.description(for: record.id).oneLiner, "A reviewed garden journal.")
        XCTAssertEqual(Set(tags.tags(for: projectURL).map(\.name)), ["Gardening", "Plant diary"])
        app.terminate(); _ = app.wait(for: .notRunning, timeout: 10); app.launch(); requireWindow(app)
        let reopened = try Database(url: Self.fixtureRoot.appendingPathComponent("test.sqlite"))
        XCTAssertEqual(ProjectStore(database: reopened).description(for: record.id).oneLiner, "A reviewed garden journal.")
        XCTAssertEqual(TagStore(database: reopened).tags(for: projectURL).count, 2)
    }
    func testCancelGenerationSavesNothing() throws {
        let app = try launch(delayMS: 10_000); prepare(app)
        app.buttons["lmStudio.generate"].firstMatch.click()
        let cancel = app.buttons["lmStudio.cancel"].firstMatch
        XCTAssertEqual(cancel.label, "Cancel generation"); cancel.click()
        let generate = app.buttons["lmStudio.generate"].firstMatch
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in generate.isEnabled && generate.label == "Generate" }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 5), .completed)
        XCTAssertFalse(app.buttons["lmStudio.apply"].firstMatch.exists)
        let db = try Database(url: Self.fixtureRoot.appendingPathComponent("test.sqlite"))
        let projects = ProjectStore(database: db)
        XCTAssertEqual(projects.description(for: projects.record(for: projectURL)!.id).oneLiner, "Original line")
        XCTAssertTrue(TagStore(database: db).tags(for: projectURL).isEmpty)
        app.buttons["lmStudio.cancel"].firstMatch.click()
    }
    func testInvalidResponseShowsErrorAndSavesNothing() throws {
        let app = try launch(response: "not JSON", width: 1200); prepare(app)
        app.buttons["lmStudio.generate"].firstMatch.click()
        let error = app.staticTexts["lmStudio.error"].firstMatch
        XCTAssertTrue(error.waitForExistence(timeout: 5))
        let sheet = app.sheets.firstMatch
        XCTAssertGreaterThanOrEqual(error.frame.minY, sheet.frame.minY)
        XCTAssertLessThanOrEqual(error.frame.maxY, sheet.frame.maxY - 35, "Error stays visible above the action buttons")
        let db = try Database(url: Self.fixtureRoot.appendingPathComponent("test.sqlite"))
        let projects = ProjectStore(database: db)
        XCTAssertEqual(projects.description(for: projects.record(for: projectURL)!.id).oneLiner, "Original line")
        XCTAssertEqual(TagStore(database: db).allTags().count, 1)
        XCTAssertFalse(app.buttons["lmStudio.apply"].firstMatch.exists)
        shoot(app, "lm-studio-error-normal")
        app.buttons["lmStudio.cancel"].firstMatch.click()
    }
}
