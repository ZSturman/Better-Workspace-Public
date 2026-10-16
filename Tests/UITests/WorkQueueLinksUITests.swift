import XCTest

/// Filing into a work queue makes a work item, never a loose note the queue cannot
/// list; anything without a project waits under Needs Attention, where it is placed
/// with the same optional pickers used everywhere else.
final class WorkQueueLinksUITests: IsolatedUITestCase {

    private func waitFor(_ condition: @escaping () -> Bool, timeout: TimeInterval = 20) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    private func features() -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: Self.workspaceRoot.appendingPathComponent("Features").path)) ?? []
    }

    private func screenshot(_ element: XCUIElement, _ name: String) {
        guard ProcessInfo.processInfo.environment["BW_CAPTURE_SCREENSHOTS"] == "1" else { return }
        let shot = XCTAttachment(screenshot: element.screenshot()); shot.name = name; shot.lifetime = .keepAlways; add(shot)
    }

    func testMenuBarFeatureCaptureLandsInNeedsAttentionAndCanBePlaced() throws {
        // A note filed here before captures became work items: invisible until now.
        try "Loose thought".write(to: Self.workspaceRoot.appendingPathComponent("Features/Loose feature note.md"),
                                  atomically: true, encoding: .utf8)
        let app = isolatedApp(arguments: ["-bwMenuBarPanelInWindow", "YES"])
        app.launch()
        requireWindow(app)
        let panel = app.windows["Menu Bar Panel (inspection)"].firstMatch
        XCTAssertTrue(panel.waitForExistence(timeout: 20))

        let field = panel.textViews["ingest.captureField"].firstMatch
        field.click(); field.typeText("Menu bar feature")
        let destination = panel.popUpButtons["capture.destination"].exists
            ? panel.popUpButtons["capture.destination"] : panel.menuButtons["capture.destination"]
        destination.click()
        // The app's own menu bar has a Features item too: take the one on screen.
        func visible(_ title: String) -> XCUIElement? {
            app.menuItems.matching(NSPredicate(format: "title == %@", title)).allElementsBoundByIndex.first { $0.isHittable }
        }
        if visible("Features") == nil { visible("More")?.hover() }
        XCTAssertTrue(waitFor({ visible("Features") != nil }, timeout: 5))
        visible("Features")?.click()
        XCTAssertTrue(panel.descendants(matching: .any)["capture.links"].waitForExistence(timeout: 5),
                      "Choosing a queue offers where the work belongs")
        screenshot(panel, "menu-bar-feature-links")
        panel.buttons["ingest.captureButton"].firstMatch.click()

        XCTAssertTrue(waitFor { self.features().contains("Menu bar feature.bw.md") },
                      "The capture became a feature record: \(features())")
        XCTAssertFalse(features().contains("Menu bar feature.md"), "…not a loose note")
        let inbox = (try? FileManager.default.contentsOfDirectory(atPath: Self.inboxRoot.path)) ?? []
        XCTAssertFalse(inbox.contains("Menu bar feature.md"), "…and nothing is left in the Inbox: \(inbox)")

        // The panel floats above the workspace window; out of the way now.
        panel.buttons[XCUIIdentifierCloseWindow].click()
        let workspace = app.windows.containing(.outline, identifier: "Sidebar").firstMatch
        let row = revealSidebarRow(app, "sidebar.folder.Features")
        row.click()
        let attention = app.descendants(matching: .any)["workQueue.needsAttention"].firstMatch
        XCTAssertTrue(attention.waitForExistence(timeout: 15), "Unplaced work is called out at the top")
        XCTAssertTrue(app.staticTexts["Menu bar feature"].waitForExistence(timeout: 10))
        let convert = app.buttons["workQueue.convert.Loose feature note.md"].firstMatch
        XCTAssertTrue(convert.waitForExistence(timeout: 10), "A loose note is offered for conversion")
        screenshot(workspace, "features-needs-attention")

        convert.click()
        XCTAssertTrue(waitFor { self.features().contains("Loose feature note.bw.md") && self.features().contains("Loose feature note.md") == false },
                      "Convert writes the record and retires the note: \(features())")

        // Place the captured feature in a project from its row.
        let projectMenu = workspace.menuButtons["workLink.project"].firstMatch
        XCTAssertTrue(projectMenu.waitForExistence(timeout: 10))
        XCTAssertTrue(projectMenu.label.contains("No project") || projectMenu.title.contains("No project"),
                      "Read as its text, not its icon: \(projectMenu.label) / \(projectMenu.title)")
        projectMenu.click()
        XCTAssertTrue(waitFor({ visible("Fixture project") != nil }, timeout: 5))
        visible("Fixture project")?.click()
        let record = Self.workspaceRoot.appendingPathComponent("Features/Menu bar feature.bw.md")
        let convertedRecord = Self.workspaceRoot.appendingPathComponent("Features/Loose feature note.bw.md")
        XCTAssertTrue(waitFor {
            let a = (try? String(contentsOf: record, encoding: .utf8)) ?? ""
            let b = (try? String(contentsOf: convertedRecord, encoding: .utf8)) ?? ""
            return (a + b).contains("project: \"Projects/Fixture project\"")
        }, "Choosing a project writes the link")
        screenshot(workspace, "features-after-placing")
    }
}
