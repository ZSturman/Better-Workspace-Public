import XCTest
import BetterWorkspaceCore

final class CaptureComposerUITests: IsolatedUITestCase {
    func testProcessInboxReopensClosedWorkspace() throws {
        let app = isolatedApp(arguments: ["-bwMenuBarPanelInWindow", "YES"])
        app.launch()
        requireWindow(app)
        let panel = app.windows["Menu Bar Panel (inspection)"].firstMatch
        XCTAssertTrue(panel.waitForExistence(timeout: 20))
        let workspace = app.windows.containing(.outline, identifier: "Sidebar").firstMatch

        // Exercise both the original window and the replacement created by openWindow.
        for _ in 0..<2 {
            XCTAssertTrue(workspace.waitForExistence(timeout: 10))
            workspace.buttons[XCUIIdentifierCloseWindow].click()
            XCTAssertNotEqual(app.state, .notRunning)
            XCTAssertFalse(workspace.exists, app.debugDescription)
            XCTAssertTrue(panel.exists)
            // A closed window leaves the accessibility tree before it leaves the screen.
            // Clicking while it still covers the button made XCUITest re-activate the app
            // (which, by design, reopens the workspace) and click through to the sidebar.
            let processInbox = panel.buttons["Process Inbox…"]
            let uncovered = expectation(for: NSPredicate(format: "isHittable == true"), evaluatedWith: processInbox)
            wait(for: [uncovered], timeout: 10)
            processInbox.click()
            XCTAssertTrue(workspace.waitForExistence(timeout: 10))
            XCTAssertTrue(workspace.buttons["ingest.newCapture"].waitForExistence(timeout: 10))
        }
    }

    func testMenuFilesURLWithSelectedDestination() throws {
        let app = isolatedApp(arguments: ["-bwMenuBarPanelInWindow", "YES", "-bwWindowWidth", "820", "-bwWindowHeight", "520"])
        app.launch()
        requireWindow(app)
        let panel = app.windows["Menu Bar Panel (inspection)"].firstMatch
        XCTAssertTrue(panel.waitForExistence(timeout: 20))
        XCTAssertFalse(panel.textFields["capture.title"].exists)
        XCTAssertFalse(panel.textFields["capture.url"].exists)
        XCTAssertFalse(panel.scrollViews["capture.destinations"].exists)
        // Optional visual artifact, like the one after saving: panel captures fail
        // intermittently ("Image creation failed") and say nothing about filing.
        if ProcessInfo.processInfo.environment["BW_CAPTURE_SCREENSHOTS"] == "1" {
            let emptyScreenshot = XCTAttachment(screenshot: panel.screenshot())
            emptyScreenshot.name = "Quick ingest default"
            emptyScreenshot.lifetime = .keepAlways
            add(emptyScreenshot)
        }
        panel.buttons["capture.details"].firstMatch.click()
        let title = panel.textFields["capture.title"].firstMatch
        title.click(); title.typeText("Watch this fixture")
        let url = panel.textFields["capture.url"].firstMatch
        url.click(); url.typeText("https://example.com/watch")
        panel.menuButtons["capture.destination"].firstMatch.click()
        XCTAssertTrue(app.menuItems["To Watch"].firstMatch.waitForExistence(timeout: 10))
        app.menuItems["To Watch"].firstMatch.click()
        // Selecting a destination does not save until Add is pressed.
        XCTAssertFalse(FileManager.default.fileExists(atPath: Self.workspaceRoot.appendingPathComponent("To Watch/Watch this fixture.md").path))
        panel.buttons["ingest.captureButton"].firstMatch.click()
        let destination = Self.workspaceRoot.appendingPathComponent("To Watch/Watch this fixture.md")
        let written = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            FileManager.default.fileExists(atPath: destination.path)
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [written], timeout: 15), .completed)
        XCTAssertEqual(try WorkspaceLink.parse(String(contentsOf: destination)).url, "https://example.com/watch")
        XCTAssertEqual(url.value as? String, "")
        // Optional visual artifact: image-server failures must not fail filing checks.
        if ProcessInfo.processInfo.environment["BW_CAPTURE_SCREENSHOTS"] == "1" {
            let screenshot = XCTAttachment(screenshot: panel.screenshot())
            screenshot.name = "Quick ingest after saving"
            screenshot.lifetime = .keepAlways
            add(screenshot)
        }
    }

    func testTitledMarkdownKeepsFirstLine() throws {
        let app = isolatedApp(arguments: ["-bwWindowWidth", "820", "-bwWindowHeight", "520"])
        app.launch(); requireWindow(app); openIngest(app)
        app.buttons["ingest.newCapture"].firstMatch.click()
        let title = app.textFields["capture.title"].firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 20))
        title.click(); title.typeText("Markdown fixture")
        let field = app.textViews["ingest.captureField"].firstMatch
        field.click(); field.typeText("- [ ] **Keep the first line**\n\n## Second heading")
        let draft = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        draft.name = "mac-markdown-capture-before-save"
        draft.lifetime = .keepAlways
        add(draft)
        app.buttons["ingest.captureButton"].firstMatch.click()
        let destination = Self.inboxRoot.appendingPathComponent("Markdown fixture.md")
        let written = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            FileManager.default.fileExists(atPath: destination.path)
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [written], timeout: 15), .completed)
        XCTAssertEqual(try String(contentsOf: destination), "- [ ] **Keep the first line**\n\n## Second heading")
        let saved = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        saved.name = "mac-markdown-capture-after-verified-file-write"
        saved.lifetime = .keepAlways
        add(saved)
    }
}
