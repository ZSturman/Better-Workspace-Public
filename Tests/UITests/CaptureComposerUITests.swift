import XCTest
import AppKit
import BetterWorkspaceCore

final class CaptureComposerUITests: IsolatedUITestCase {
    func testVideoFailureCanBeReadAndRemovedWithoutLosingIdeaText() throws {
        let app = isolatedApp(arguments: ["-bwMenuBarPanelInWindow", "YES"])
        app.launch(); requireWindow(app)
        let panel = app.windows["Menu Bar Panel (inspection)"]
        XCTAssertTrue(panel.waitForExistence(timeout: 20))
        let field = panel.textViews["ingest.captureField"].firstMatch
        field.click()
        let clipboard = NSPasteboard.general
        let previous = clipboard.pasteboardItems?.map { item -> NSPasteboardItem in
            let copy = NSPasteboardItem()
            for type in item.types { if let data = item.data(forType: type) { copy.setData(data, forType: type) } }
            return copy
        } ?? []
        let noteText = "Keep this video idea\n\nThese notes must survive a failed attachment."
        clipboard.clearContents()
        XCTAssertTrue(clipboard.setString(noteText, forType: .string))
        field.typeKey("a", modifierFlags: .command)
        field.typeKey("v", modifierFlags: .command)
        XCTAssertEqual(field.value as? String, noteText)
        clipboard.clearContents()
        let missing = Self.fixtureRoot.appendingPathComponent(String(repeating: "Unavailable video reference ", count: 5) + ".mov")
        try Data("video fixture".utf8).write(to: missing)
        XCTAssertTrue(clipboard.writeObjects([missing as NSURL]))
        let change = clipboard.changeCount
        defer {
            if clipboard.changeCount == change {
                clipboard.clearContents()
                if !previous.isEmpty { clipboard.writeObjects(previous) }
            }
        }
        field.typeKey("v", modifierFlags: .command)
        XCTAssertTrue(panel.textFields["Image or file title"].firstMatch.waitForExistence(timeout: 5))
        try FileManager.default.removeItem(at: missing)
        panel.menuButtons["capture.destination"].click()
        app.menuItems["New Idea"].click()
        panel.buttons["ingest.captureButton"].click()
        let result = panel.staticTexts["capture.result"]
        XCTAssertTrue(result.waitForExistence(timeout: 15))
        let message = (result.value as? String) ?? result.label
        XCTAssertTrue(message.contains(missing.lastPathComponent), message)
        XCTAssertTrue(message.contains("Your draft is still here"), message)
        XCTAssertGreaterThan(result.frame.height, 30, "The full error wraps across lines")
        let remove = panel.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'capture.removeAttachment.'")).firstMatch
        remove.click()
        XCTAssertTrue(panel.exists)
        XCTAssertFalse(panel.textFields["Image or file title"].exists)
        XCTAssertTrue((field.value as? String)?.contains("These notes must survive") == true)
        panel.buttons["ingest.captureButton"].click()
        let note = Self.workspaceRoot.appendingPathComponent("Ideas/Keep this video idea/Keep this video idea.md")
        let saved = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in FileManager.default.fileExists(atPath: note.path) }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [saved], timeout: 20), .completed)
        XCTAssertTrue(try String(contentsOf: note, encoding: .utf8).contains("These notes must survive"))
    }

    func testFilesPickerNavigatesAndCancellationKeepsDraft() throws {
        let app = isolatedApp(arguments: ["-bwMenuBarPanelInWindow", "YES"])
        app.launch(); requireWindow(app)
        let panel = app.windows["Menu Bar Panel (inspection)"]
        XCTAssertTrue(panel.waitForExistence(timeout: 20))
        let field = panel.textViews["ingest.captureField"].firstMatch
        field.click(); field.typeText("Picker draft survives cancellation")
        let draftBeforePicker = try XCTUnwrap(field.value as? String)
        XCTAssertTrue(draftBeforePicker.contains("Picker draft survives cancellation"))
        panel.buttons["capture.files"].click()
        let cancel = app.buttons["Cancel"].firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 10)); XCTAssertTrue(cancel.isEnabled)
        app.typeKey("g", modifierFlags: [.command, .shift])
        // The Go to Folder control is a text field on current macOS, and a
        // combo box on earlier versions. Type into its already focused editor.
        app.typeText(Self.workspaceRoot.appendingPathComponent("For Reference").path)
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(app.buttons["Add to draft"].firstMatch.waitForExistence(timeout: 5))
        cancel.click()
        XCTAssertEqual(field.value as? String, draftBeforePicker)
    }

    func testMenuBarIdeaKeepsPastedImagesWithItsMarkdown() throws {
        let app = isolatedApp(arguments: ["-bwMenuBarPanelInWindow", "YES", "-bwWindowWidth", "820", "-bwWindowHeight", "520"])
        app.launch()
        requireWindow(app)
        let panel = app.windows["Menu Bar Panel (inspection)"].firstMatch
        XCTAssertTrue(panel.waitForExistence(timeout: 20))
        let field = panel.textViews["ingest.captureField"].firstMatch
        field.click()
        field.typeText("Visual idea\n\nThe pasted references belong here.")

        let png = try Data(contentsOf: Self.workspaceRoot.appendingPathComponent("For Reference/Wide reference.png"))
        let tiff = try XCTUnwrap(NSImage(data: png)?.tiffRepresentation)
        let clipboard = NSPasteboard.general
        let previous = clipboard.pasteboardItems?.map { item -> NSPasteboardItem in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) { copy.setData(data, forType: type) }
            }
            return copy
        } ?? []
        var fixtureChange = clipboard.changeCount
        defer {
            if clipboard.changeCount == fixtureChange {
                clipboard.clearContents()
                if !previous.isEmpty { clipboard.writeObjects(previous) }
            }
        }
        clipboard.clearContents()
        XCTAssertTrue(clipboard.setData(png, forType: .png))
        fixtureChange = clipboard.changeCount
        field.typeKey("v", modifierFlags: .command)
        XCTAssertTrue(panel.textFields["Image or file title"].firstMatch.waitForExistence(timeout: 5))

        clipboard.clearContents()
        XCTAssertTrue(clipboard.setData(tiff, forType: .tiff))
        fixtureChange = clipboard.changeCount
        panel.buttons["capture.paste"].click()
        XCTAssertEqual(panel.textFields.matching(identifier: "Image or file title").count, 2)

        panel.menuButtons["capture.destination"].firstMatch.click()
        let ideas = app.menuItems["New Idea"].firstMatch
        XCTAssertTrue(ideas.waitForExistence(timeout: 10))
        ideas.click()
        panel.buttons["ingest.captureButton"].firstMatch.click()
        let folder = Self.workspaceRoot.appendingPathComponent("Ideas/Visual idea")
        let note = folder.appendingPathComponent("Visual idea.md")
        let written = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            FileManager.default.fileExists(atPath: note.path)
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [written], timeout: 15), .completed)
        // Idea/Idea.md with the images under Attachments, each linked from the note.
        let text = try String(contentsOf: note, encoding: .utf8)
        XCTAssertTrue(text.hasPrefix("Visual idea\n\nThe pasted references belong here.\n"), text)
        let images = try FileManager.default.contentsOfDirectory(at: folder.appendingPathComponent("Attachments"), includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "png" }
        XCTAssertEqual(images.count, 2)
        XCTAssertTrue(images.allSatisfy { NSImage(contentsOf: $0)?.isValid == true })
        XCTAssertTrue(images.allSatisfy { text.contains("](<Attachments/\($0.lastPathComponent)>)") }, text)
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: folder.path)), ["Visual idea.md", "Attachments"])
    }

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
