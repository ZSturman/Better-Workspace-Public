import XCTest
import BetterWorkspaceCore

final class WorkspaceMobileChangesUITests: IsolatedUITestCase {
    func testTransparentProjectAndSelectablePropertiesAt820Points() throws {
        let directory = Self.workspaceRoot.appendingPathComponent("Projects/_Group/_Nested/Transparent project")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try "# Original file".write(to: directory.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        let app = isolatedApp(arguments: ["-bwWindowWidth", "820", "-bwWindowHeight", "520"])
        app.launch(); requireForeground(app); requireWindow(app)
        revealSidebarRow(app, "sidebar.folder.Projects").click()
        let project = app.buttons.containing(NSPredicate(format: "label CONTAINS %@", "Transparent project")).firstMatch
        XCTAssertTrue(project.waitForExistence(timeout: 20)); project.click()
        XCTAssertTrue(app.descendants(matching: .any)["projects.workspace"].firstMatch.waitForExistence(timeout: 15))
        app.radioButtons["Details"].firstMatch.click()
        let domain = app.descendants(matching: .any)["project.details.domain"].firstMatch
        XCTAssertTrue(domain.waitForExistence(timeout: 10))
        for _ in 0..<5 where !domain.isHittable { app.scrollViews.firstMatch.scroll(byDeltaX: 0, deltaY: -160) }
        XCTAssertTrue(domain.isHittable); domain.click()
        let add = app.menuItems["Add new domain…"].firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 5)); add.click()
        app.typeKey(.escape, modifierFlags: [])
        let screenshot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        screenshot.name = "mac-transparent-project-selectors-820"; screenshot.lifetime = .keepAlways; self.add(screenshot)
        XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent("README.md")), "# Original file")
    }
}
