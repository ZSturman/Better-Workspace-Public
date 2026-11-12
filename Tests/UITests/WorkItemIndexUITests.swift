import XCTest
import BetterWorkspaceCore

final class WorkItemIndexUITests: IsolatedUITestCase {
    func testKnownWorkAppearsBeforeDiscoveryAndUsesCurrentFileContents() throws {
        let service = WorkItemService()
        var item = try service.create(WorkItem(kind: .task, title: "Indexed task", url: Self.workspaceRoot),
                                      in: Self.workspaceRoot.appendingPathComponent("To Do"))
        let paths = try JSONSerialization.data(withJSONObject: ["version": 1, "root": Self.workspaceRoot.canonicalPath,
            "paths": ["To Do/" + item.url.lastPathComponent]])
        try paths.write(to: Self.fixtureRoot.appendingPathComponent("work-item-paths.json"))
        item.title = "Current text from Markdown"
        _ = try service.update(item)
        let app = isolatedApp(arguments: ["-bwStartArea", "Work", "-bwWorkItemDiscoveryDelay", "30"])
        app.launch(); requireWindow(app)
        // The discovery walk is deliberately still waiting. A cache of record bodies
        // would show the old title, and the pre-index implementation shows no task.
        XCTAssertTrue(app.staticTexts["Current text from Markdown"].firstMatch.waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["Indexed task"].exists)
        let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        attachment.name = "Work before background discovery"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}


extension WorkItemIndexUITests {
    func testFinderDeletionRemovesTaskWithoutPromptOrRestoration() throws {
        let service = WorkItemService(), folder = Self.workspaceRoot.appendingPathComponent("To Do")
        let first = try service.create(.init(kind: .task, title: "Finder removes this task", url: folder), in: folder)
        let second = try service.create(.init(kind: .task, title: "This task stays", url: folder), in: folder)
        let app = isolatedApp(arguments: ["-bwStartArea", "Work", "-bwWindowWidth", "820"])
        app.launch(); defer { app.terminate() }; requireForeground(app)
        XCTAssertTrue(app.staticTexts[first.title].firstMatch.waitForExistence(timeout: 20))
        try FileManager.default.removeItem(at: first.url)
        app.buttons["Refresh"].firstMatch.click()
        let removed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            !app.staticTexts[first.title].firstMatch.exists
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [removed], timeout: 15), .completed)
        XCTAssertTrue(app.staticTexts[second.title].firstMatch.exists)
        XCTAssertFalse(app.windows.buttons["Add files back"].exists)
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.url.path))
        app.terminate(); XCTAssertTrue(app.wait(for: .notRunning, timeout: 10)); app.launch(); requireForeground(app)
        XCTAssertTrue(app.staticTexts[second.title].firstMatch.waitForExistence(timeout: 20))
        XCTAssertFalse(app.staticTexts[first.title].firstMatch.exists)
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.url.path))
    }
}

extension WorkItemIndexUITests {
    func testProjectsResizeAndFullscreenKeepNavigationResponsive() throws {
        let app = isolatedApp(arguments: ["-bwStartArea", "Projects", "-BWReliabilityResizeFixture", "YES"])
        app.launch(); defer { app.terminate() }; requireForeground(app)
        let projects = app.descendants(matching: .any)["sidebar.folder.Projects"].firstMatch
        XCTAssertTrue(projects.waitForExistence(timeout: 20))
        for _ in 0..<2 {
            app.buttons["reliability.resizeNarrow"].click()
            let narrow = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in app.windows.firstMatch.frame.width < 1000 }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [narrow], timeout: 10), .completed, "Window frame: \(app.windows.firstMatch.frame)")
            XCTAssertTrue(revealSidebarRow(app, "sidebar.folder.Projects").isHittable)
            XCTAssertTrue(app.buttons["Refresh"].firstMatch.isHittable)
            app.buttons["reliability.resizeWide"].click()
            let wide = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in app.windows.firstMatch.frame.width > 1100 }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [wide], timeout: 10), .completed)
        }
        // The same AppKit fullscreen transition used by the green window button.
        let fullscreenButton = app.windows.firstMatch.buttons[XCUIIdentifierFullScreenWindow]
        XCTAssertTrue(fullscreenButton.exists); fullscreenButton.click()
        let fullscreen = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            app.windows.firstMatch.frame.width > 1350
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [fullscreen], timeout: 15), .completed)
        app.typeKey(.escape, modifierFlags: [])
        let restored = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in app.windows.firstMatch.frame.width < 1350 }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [restored], timeout: 15), .completed)
        XCTAssertTrue(projects.waitForExistence(timeout: 15)); revealSidebarRow(app, "sidebar.folder.Projects").click()
        let ideas = revealSidebarRow(app, "sidebar.folder.Ideas")
        XCTAssertTrue(ideas.isHittable); ideas.click(); revealSidebarRow(app, "sidebar.folder.Projects").click()
        XCTAssertTrue(app.buttons["Refresh"].firstMatch.isHittable)
    }
}
