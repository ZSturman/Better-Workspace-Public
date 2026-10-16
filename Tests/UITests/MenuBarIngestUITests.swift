import XCTest

/// Ingest as a menu bar utility: a login launch has no window, capture works without
/// one, and the capture intents and links reach the real filing path.
final class MenuBarIngestUITests: IsolatedUITestCase {

    private var workspaceWindow: (XCUIApplication) -> XCUIElement = { app in
        app.windows.containing(.outline, identifier: "Sidebar").firstMatch
    }

    private func waitForFile(_ url: URL, timeout: TimeInterval = 20) -> Bool {
        let written = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            FileManager.default.fileExists(atPath: url.path)
        }, object: nil)
        return XCTWaiter.wait(for: [written], timeout: timeout) == .completed
    }

    private func contents(of folder: String) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: Self.workspaceRoot.appendingPathComponent(folder).path)) ?? []
    }

    /// `-bwLaunchedAtLogin YES` takes the same path as a real Login Item launch.
    func testLoginLaunchStaysInTheMenuBarUntilOpened() throws {
        let app = isolatedApp(arguments: ["-bwLaunchedAtLogin", "YES"])
        app.launch()
        XCTAssertNotEqual(app.state, .notRunning)
        // Long enough for SwiftUI's launch window to have appeared and been closed.
        Thread.sleep(forTimeInterval: 4)
        XCTAssertFalse(workspaceWindow(app).exists, "A login launch must not leave the main window open")
        XCTAssertNotEqual(app.state, .notRunning, "…and must keep running for the menu bar")

        // Opening the app again (Finder, Spotlight, the Dock) brings the workspace back.
        // That is a reopen, and `activate()` is not one -- it only activates, which by
        // design opens nothing. Launch Services routes a reopen by bundle identifier, so
        // with the installed copy running it reached that app, not this one; the runner
        // may not send this process an Apple Event either. The app's test hook hands the
        // reopen to SwiftUI's app delegate, the path a delivered reopen takes.
        XCTAssertNotEqual(app.state, .notRunning)
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name("com.zacharysturman.BetterWorkspace.test.reopen"),
            object: Self.fixtureRoot.path, userInfo: nil, deliverImmediately: true)
        XCTAssertTrue(workspaceWindow(app).waitForExistence(timeout: 15),
                      "Reopening a menu-bar-only app opens the workspace window")
    }

    /// Capture is a property of the running app, not of its window.
    func testMenuBarCaptureWorksWithTheWorkspaceClosed() throws {
        let app = isolatedApp(arguments: ["-bwMenuBarPanelInWindow", "YES"])
        app.launch()
        requireWindow(app)
        let panel = app.windows["Menu Bar Panel (inspection)"].firstMatch
        XCTAssertTrue(panel.waitForExistence(timeout: 20))
        let workspace = workspaceWindow(app)
        XCTAssertTrue(workspace.waitForExistence(timeout: 10))
        workspace.buttons[XCUIIdentifierCloseWindow].click()
        XCTAssertFalse(workspace.waitForExistence(timeout: 2))

        XCTAssertTrue(panel.textFields["tag.searchField"].exists, "Tags are one field away, not behind a menu")
        let field = panel.textViews["ingest.captureField"].firstMatch
        field.click(); field.typeText("Menu bar thought with no window")
        panel.buttons["ingest.captureButton"].firstMatch.click()
        XCTAssertTrue(waitForFile(Self.inboxRoot.appendingPathComponent("Menu bar thought with no window.md")))
        let row = panel.buttons.containing(NSPredicate(format: "label CONTAINS %@", "Menu bar thought with no window")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 15), "The panel lists the new capture")
        XCTAssertTrue(row.label.contains("needs filing"), "…as still waiting to be filed: \(row.label)")
        // Optional, as in CaptureComposerUITests: panel captures can fail on this machine.
        if ProcessInfo.processInfo.environment["BW_CAPTURE_SCREENSHOTS"] == "1" {
            let shot = XCTAttachment(screenshot: panel.screenshot()); shot.name = "menu-bar-panel-recent"; shot.lifetime = .keepAlways; add(shot)
        }

        panel.buttons["menubar.openWorkspace"].click()
        XCTAssertTrue(workspace.waitForExistence(timeout: 10))
    }

    /// Typing a tag in the menu bar shows existing tags as you type, and a spelling
    /// variant ("raspberrypi") offers the existing "Raspberry Pi" rather than a new tag.
    func testMenuBarTagFieldSuggestsExistingTagsWhileTyping() throws {
        let app = isolatedApp(arguments: ["-bwMenuBarPanelInWindow", "YES"])
        app.launch()
        requireWindow(app)
        let panel = app.windows["Menu Bar Panel (inspection)"].firstMatch
        XCTAssertTrue(panel.waitForExistence(timeout: 20))
        let tagField = panel.textFields["tag.searchField"].firstMatch
        tagField.click(); tagField.typeText("Raspberry Pi\r")
        let remove = panel.buttons["Remove Raspberry Pi"].firstMatch
        XCTAssertTrue(remove.waitForExistence(timeout: 5), "Return created and added the tag")
        remove.click()

        tagField.click(); tagField.typeText("rasp")
        let suggestion = panel.buttons["Tag Raspberry Pi"].firstMatch
        XCTAssertTrue(suggestion.waitForExistence(timeout: 5), "A partial name lists the existing tag")
        XCTAssertGreaterThan(suggestion.frame.height, 8, "…visibly, not laid out at zero height")
        if ProcessInfo.processInfo.environment["BW_CAPTURE_SCREENSHOTS"] == "1" {
            let shot = XCTAttachment(screenshot: panel.screenshot()); shot.name = "menu-bar-tag-suggestions"; shot.lifetime = .keepAlways; add(shot)
        }

        tagField.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 4) + "raspberrypi")
        XCTAssertTrue(suggestion.waitForExistence(timeout: 5))
        XCTAssertFalse(panel.buttons["tag.createButton"].exists, "A spelling variant never offers a second tag")
    }

    func testAddToFolderIntentFilesStraightIntoTheFolder() throws {
        let app = isolatedApp(arguments: ["-BWTestRunIntent", "folder|For Reference|Mac intent article"])
        app.launch()
        requireWindow(app)
        let filed = Self.workspaceRoot.appendingPathComponent("For Reference/Mac intent article.md")
        XCTAssertTrue(waitForFile(filed), "The Mac files immediately: \(contents(of: "For Reference"))")
        XCTAssertFalse(FileManager.default.fileExists(atPath: Self.inboxRoot.appendingPathComponent("Mac intent article.md").path),
                       "…and nothing is left behind in the Inbox")
    }

    func testCaptureIdeaIntentMakesAnIdeaFolder() throws {
        let app = isolatedApp(arguments: ["-BWTestRunIntent", "idea|Mac intent idea"])
        app.launch()
        requireWindow(app)
        let idea = Self.workspaceRoot.appendingPathComponent("Ideas/Mac intent idea/Mac intent idea.md")
        XCTAssertTrue(waitForFile(idea), "Ideas: \(contents(of: "Ideas"))")
    }

    func testQuickCaptureIntentGoesToTheInboxAndWaitsToBeFiled() throws {
        let app = isolatedApp(arguments: ["-BWTestRunIntent", "quick|Mac intent quick thought"])
        app.launch()
        requireWindow(app)
        XCTAssertTrue(waitForFile(Self.inboxRoot.appendingPathComponent("Mac intent quick thought.md")))
    }

    func testCaptureLinkOpensTheQuickCapturePanel() throws {
        // Delivered by the launched instance's own link handler: `app.open(_:)` starts a
        // second instance, and the panel then opened in whichever one XCUITest was not reading.
        let app = isolatedApp(arguments: ["-bwOpenURL", "betterworkspace://capture?kind=idea"])
        app.launch()
        requireWindow(app)
        XCTAssertTrue(app.staticTexts["New Idea"].waitForExistence(timeout: 10), "The idea link opens the panel in idea mode")
        XCTAssertTrue(app.buttons["capture.saveIdea"].exists)
        let field = app.textViews["ingest.captureField"].firstMatch
        field.click(); field.typeText("Linked Mac idea")
        app.buttons["capture.saveIdea"].click()
        XCTAssertTrue(waitForFile(Self.workspaceRoot.appendingPathComponent("Ideas/Linked Mac idea/Linked Mac idea.md")),
                      "Ideas: \(contents(of: "Ideas"))")
    }
}
