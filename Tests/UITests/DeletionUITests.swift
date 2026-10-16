import XCTest
import BetterWorkspaceCore

final class DeletionUITests: IsolatedUITestCase {
    func testTodoQueueHasAnImmediateTrashButton() throws {
        let folder = Self.workspaceRoot.appendingPathComponent("To Do")
        let work = try WorkItemService().create(WorkItem(id: "delete-task", kind: .task, title: "Delete this task", url: folder.appendingPathComponent("placeholder")), in: folder)
        let app = isolatedApp(arguments: ["-bwStartArea", "To Do"])
        app.launch(); requireWindow(app)
        let delete = app.buttons["workItem.delete.delete-task"].firstMatch
        XCTAssertTrue(delete.waitForExistence(timeout: 15)); delete.click()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            !FileManager.default.fileExists(atPath: work.url.path)
        }, object: nil)], timeout: 10), .completed)
        XCTAssertFalse(app.sheets.firstMatch.exists)
    }

    func testFeatureQueueRightClickUsesManageMenuAndConfirmation() throws {
        let folder = Self.workspaceRoot.appendingPathComponent("Features")
        let work = try WorkItemService().create(WorkItem(id: "delete-feature", kind: .feature, title: "Delete this feature", url: folder.appendingPathComponent("placeholder")), in: folder)
        let app = isolatedApp(arguments: ["-bwStartArea", "Features"])
        app.launch(); requireWindow(app)
        let row = app.staticTexts["Delete this feature"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 15)); row.rightClick()
        app.menuItems["Manage feature"].firstMatch.hover()
        app.menuItems["Delete…"].firstMatch.click()
        XCTAssertTrue(app.sheets.firstMatch.buttons["Move to Trash"].waitForExistence(timeout: 5))
        XCTAssertTrue(FileManager.default.fileExists(atPath: work.url.path))
        app.sheets.firstMatch.buttons["Move to Trash"].click()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            !FileManager.default.fileExists(atPath: work.url.path)
        }, object: nil)], timeout: 10), .completed)
    }

    func testProjectDeletionAt820PointsCanBeCancelledAndTrashesWholeFolder() throws {
        let project = Self.workspaceRoot.appendingPathComponent("Projects/Fixture project")
        let database = try Database(url: Self.fixtureRoot.appendingPathComponent("test.sqlite"))
        _ = ProjectStore(database: database).register(url: project)
        // Display dates ignore metadata-only directory touches; deletion must use
        // the raw filesystem date instead of this older displayed content date.
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(3600)], ofItemAtPath: project.path)
        let app = isolatedApp(arguments: ["-bwStartArea", "Projects", "-bwWindowWidth", "820", "-bwWindowHeight", "520"])
        app.launch(); requireWindow(app)
        app.radioButtons["Cards"].firstMatch.click()
        let card = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Fixture project")).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 15)); card.click()
        let actions = app.menuButtons["Actions"].firstMatch
        XCTAssertTrue(actions.waitForExistence(timeout: 10)); actions.click()
        app.menuItems["Delete project…"].click()
        XCTAssertTrue(app.sheets.firstMatch.waitForExistence(timeout: 5))
        let screenshot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        screenshot.name = "delete-project-mac-820"; screenshot.lifetime = .keepAlways; add(screenshot)
        app.sheets.firstMatch.buttons["Cancel"].click()
        XCTAssertTrue(FileManager.default.fileExists(atPath: project.path))
        actions.click(); app.menuItems["Delete project…"].click()
        app.sheets.firstMatch.buttons["Move to Trash"].click()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            !FileManager.default.fileExists(atPath: project.path)
        }, object: nil)], timeout: 10), .completed)
        let trash = Self.fixtureRoot.appendingPathComponent("Trash")
        let folders = try FileManager.default.contentsOfDirectory(at: trash, includingPropertiesForKeys: nil)
        XCTAssertEqual(folders.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folders[0].appendingPathComponent("README.md").path))
        XCTAssertFalse(app.sheets.firstMatch.exists)
    }

    func testIdeaRightClickDeletionRemovesOnlySelectedIdea() throws {
        let app = isolatedApp(arguments: ["-bwStartArea", "Ideas"])
        app.launch(); requireWindow(app)
        let row = app.staticTexts["Fixture idea"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 15)); row.rightClick()
        try XCTUnwrap(app.menuItems.matching(identifier: "Delete").allElementsBoundByIndex.first { $0.isEnabled && $0.isHittable }).click()
        let note = Self.workspaceRoot.appendingPathComponent("Ideas/Fixture idea.md")
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            !FileManager.default.fileExists(atPath: note.path)
        }, object: nil)], timeout: 10), .completed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: Self.workspaceRoot.appendingPathComponent("Projects/Fixture project/README.md").path))
    }
}
