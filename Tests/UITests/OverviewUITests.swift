import XCTest
import BetterWorkspaceCore

/// Overview decides; Projects browses. These check the handoff actually works, not
/// just that the sections render.
final class OverviewUITests: IsolatedUITestCase {

    private func launch() -> XCUIApplication {
        let app = isolatedApp()
        app.launch()
        requireForeground(app)
        requireWindow(app)
        return app
    }

    func testOverviewIsTheLandingScreenAndSaysWhatItIsFor() {
        let app = launch()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "identifier == %@ AND value == %@", "area.title", "Overview")).firstMatch
                        .waitForExistence(timeout: 20))
        XCTAssertTrue(app.staticTexts["WORTH YOUR ATTENTION"].firstMatch.waitForExistence(timeout: 20))
    }

    /// The fixture seeds an inbox item, so the inbox rule should fire and say why.
    func testAttentionExplainsItselfRatherThanShowingAScore() {
        let app = launch()
        let row = app.descendants(matching: .any)["overview.attention.Ingest inbox"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 20), "The seeded inbox item should be surfaced")

        // SwiftUI folds a button's children into the button's own accessibility
        // label, so the reason is on the row rather than a separate StaticText.
        let explained = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS[c] 'waiting to be filed'")).firstMatch
        XCTAssertTrue(explained.waitForExistence(timeout: 10),
                      "A surfaced item must say why, in words")
    }

    func testClickingASurfacedInboxItemGoesToIngest() {
        let app = launch()
        let row = app.descendants(matching: .any)["overview.attention.Ingest inbox"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 20))
        row.click()
        XCTAssertTrue(app.buttons["ingest.newCapture"].firstMatch.waitForExistence(timeout: 20),
                      "Clicking the inbox row should land in Ingest")
    }

    func testAttentionOpensTheSpecificProjectAndCanReturnToTheBrowser() {
        let app = launch()
        let row = app.buttons["overview.attention.Fixture project"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 20))
        row.click()
        XCTAssertTrue(app.buttons["All Projects"].firstMatch.waitForExistence(timeout: 20),
                      "An individual project link must open its project screen")
        XCTAssertTrue(app.staticTexts["Fixture project"].firstMatch.exists)
        XCTAssertFalse(app.descendants(matching: .any)["projects.presentation"].firstMatch.exists)
        app.buttons["All Projects"].firstMatch.click()
        XCTAssertTrue(app.descendants(matching: .any)["projects.presentation"].firstMatch.waitForExistence(timeout: 10))
    }

    func testBringForwardOpensTheSpecificProjectAtMinimumWidth() {
        let app = isolatedApp(arguments: ["-bwWindowWidth", "820", "-bwWindowHeight", "520"])
        app.launch(); requireWindow(app)
        let focus = app.descendants(matching: .any)["overview.focusPicker"].firstMatch
        XCTAssertTrue(focus.waitForExistence(timeout: 20))
        focus.click(); app.menuItems["Needs a revisit"].firstMatch.click()
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "overview.focusItem.")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 20)); row.click()
        XCTAssertTrue(app.buttons["All Projects"].firstMatch.waitForExistence(timeout: 20))
        XCTAssertTrue(app.staticTexts["Fixture project"].firstMatch.exists)
        attach(app, "Overview project handoff 820x520")
    }

    func testBringForwardOpensFeatureAndMilestoneDetailsAtMinimumWidth() throws {
        for kind in [WorkItemKind.feature, .milestone] {
            let item = WorkItem(id: "overview-\(kind.rawValue)", kind: kind, title: "Specific \(kind.displayName)",
                                url: Self.workspaceRoot.appendingPathComponent("placeholder.bw.md"))
            _ = try WorkItemService().create(item, in: Self.workspaceRoot.appendingPathComponent(kind == .feature ? "Features" : "Milestones"))
        }
        let app = isolatedApp(arguments: ["-bwWindowWidth", "820", "-bwWindowHeight", "520"])
        app.launch(); requireWindow(app)
        let focus = app.descendants(matching: .any)["overview.focusPicker"].firstMatch
        XCTAssertTrue(focus.waitForExistence(timeout: 20))
        focus.click(); app.menuItems["Needs a revisit"].firstMatch.click()
        for kind in [WorkItemKind.feature, .milestone] {
            let content = app.descendants(matching: .any)["overview.focusContent"].firstMatch
            content.click()
            // Keyboard selection stays in the open picker; the application's Go
            // menu has identically named entries that a global menu query can hit.
            app.typeKey(kind == .feature ? "f" : "m", modifierFlags: [])
            app.typeKey(.return, modifierFlags: [])
            let row = app.buttons["overview.focusItem.overview-\(kind.rawValue)"].firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 20)); row.click()
            XCTAssertTrue(app.buttons["work.detail.back"].firstMatch.waitForExistence(timeout: 20))
            XCTAssertTrue(app.staticTexts["Specific \(kind.displayName)"].firstMatch.exists)
            XCTAssertTrue(app.descendants(matching: .any)["inspector.editText"].firstMatch.exists)
            attach(app, "Overview \(kind.rawValue) handoff 820x520")
            app.buttons["work.detail.back"].firstMatch.click()
            XCTAssertFalse(app.buttons["work.detail.back"].firstMatch.exists)
            revealSidebarRow(app, "Overview").click()
        }
    }

    func testBringForwardRetainsTheSpecificIdeaSelection() throws {
        try "# Distinct idea\n\nDetails of the selected idea.".write(
            to: Self.workspaceRoot.appendingPathComponent("Ideas/Distinct idea.md"), atomically: true, encoding: .utf8)
        let app = launch()
        let focus = app.descendants(matching: .any)["overview.focusPicker"].firstMatch
        XCTAssertTrue(focus.waitForExistence(timeout: 20))
        focus.click(); app.menuItems["Needs a revisit"].firstMatch.click()
        app.descendants(matching: .any)["overview.focusContent"].firstMatch.click()
        app.typeKey("i", modifierFlags: [])
        app.typeKey(.return, modifierFlags: [])
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@",
                                                   "overview.focusItem.", "Distinct idea")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 20)); row.click()
        XCTAssertTrue(app.staticTexts["Details of the selected idea."].firstMatch.waitForExistence(timeout: 20),
                      "The idea workspace must keep the item selected during the area change")
    }

    /// Overview must not become a second Projects table.
    func testOverviewShowsNoTable() {
        let app = launch()
        XCTAssertTrue(app.staticTexts["WORTH YOUR ATTENTION"].firstMatch.waitForExistence(timeout: 20))
        XCTAssertEqual(tableColumns(app).count, 0, "Overview is for deciding, not for browsing rows")
    }

    /// Overview is derived state, not a launch-time snapshot. An item arriving in the
    /// inbox through Finder/iCloud must change the signal while the user stays here.
    func testIncomingCaptureUpdatesOverviewWithoutManualRefresh() throws {
        try FileManager.default.removeItem(at: Self.inboxRoot.appendingPathComponent("Drop Project"))
        let old = Date(timeIntervalSinceNow: -14 * 86_400)
        for path in ["Projects/Fixture project/README.md", "Projects/Fixture project"] {
            try FileManager.default.setAttributes(
                [.modificationDate: old],
                ofItemAtPath: Self.workspaceRoot.appendingPathComponent(path).path
            )
        }

        let app = launch()
        XCTAssertTrue(app.staticTexts["Nothing needs your attention"].firstMatch.waitForExistence(timeout: 20))

        let capture = Self.inboxRoot.appendingPathComponent("Overview arrival.md")
        try "A capture arrived while Overview was open.".write(to: capture, atomically: true, encoding: .utf8)

        let row = app.descendants(matching: .any)["overview.attention.Ingest inbox"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 20),
                      "Inbox polling or FSEvents should rebuild Overview without manual refresh")
    }

    func testProjectWorkItemBecomesAnExplainableOverviewHandoff() throws {
        let item = WorkItem(id: "fixture-overview-next-action", kind: .task,
                            title: "Write the concrete next action", stage: .now,
                            priority: .high, projectPath: "Projects/Fixture project",
                            url: Self.workspaceRoot.appendingPathComponent("placeholder.bw.md"))
        _ = try WorkItemService().create(item, in: Self.workspaceRoot.appendingPathComponent("To Do", isDirectory: true))

        let app = launch()
        let action = app.buttons["overview.nextAction.fixture-overview-next-action"].firstMatch
        XCTAssertTrue(action.waitForExistence(timeout: 20))

        // Assert on the button's own label rather than on a separate static text.
        // SwiftUI merges a button's children into one accessibility element, so the
        // title is not exposed separately — and the label is what a person actually
        // gets, by sight and through VoiceOver alike.
        XCTAssertTrue(action.label.contains("Write the concrete next action"),
                      "The recommendation must name the item; got “\(action.label)”")

        // It says where the work belongs and when it is planned for; the ranking rule
        // itself is a tooltip, not a sentence on every visit.
        XCTAssertTrue(action.label.contains("Fixture project") && action.label.contains("Now"),
                      "The recommendation must name its project and stage; got “\(action.label)”")

        // A work item is revealed in the queue that holds it, selected for its
        // in-place inspector editor rather than opened in a detached modal.
        action.click()
        let edit = app.descendants(matching: .any)["inspector.editText"].firstMatch
        XCTAssertTrue(edit.waitForExistence(timeout: 20), "The handoff should select the concrete work item")
    }

    /// On the 820×520 minimum window, Overview remains a short decision surface rather
    /// than turning into a dashboard that competes with the rest of the app for space.
    func testCompactOverviewCapsItsAttentionList() throws {
        for name in ["Idea one", "Idea two", "Idea three", "Empty folder"] {
            try FileManager.default.createDirectory(
                at: Self.workspaceRoot.appendingPathComponent(name == "Empty folder" ? name : "Ideas/\(name)"),
                withIntermediateDirectories: true
            )
        }

        let app = isolatedApp(arguments: ["-bwWindowWidth", "820", "-bwWindowHeight", "520"])
        app.launch()
        requireWindow(app)
        XCTAssertLessThan(app.windows.firstMatch.frame.width, 1000)
        XCTAssertTrue(app.staticTexts["WORTH YOUR ATTENTION"].firstMatch.waitForExistence(timeout: 20))

        let rows = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "overview.attention.")
        )
        XCTAssertEqual(rows.count, 3, "Compact Overview must cap attention at three rows")
    }

    /// A macOS StaticText carries its words in `value`; a button in `label`.
    private func text(_ element: XCUIElement) -> String {
        (element.value as? String).flatMap { $0.isEmpty ? nil : $0 } ?? element.label
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// One To-folder item, decided the way Inbox Review decides it: the folder names the
    /// primary action, the move is journaled, and Undo puts the file back.
    func testOneThingToReviewDecidesMovesAndUndoes() throws {
        let talk = Self.workspaceRoot.appendingPathComponent("To Watch/Talk.md")
        try "https://example.com/talk".write(to: talk, atomically: true, encoding: .utf8)
        let app = launch()

        let title = app.descendants(matching: .any)["overview.toReview.title"].firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 30), "Overview should offer one To-folder item")
        XCTAssertEqual(text(title), "Talk.md", "To Watch comes before To Organize in the rotation")
        let primary = app.buttons["overview.toReview.primary"].firstMatch
        XCTAssertEqual(primary.label, "Watched?")
        attach(app, "Overview review 1400x900")
        primary.click()

        let done = Self.workspaceRoot.appendingPathComponent("Reviewed/Done/To Watch/Talk.md")
        let moved = expectation(for: NSPredicate { _, _ in FileManager.default.fileExists(atPath: done.path) }, evaluatedWith: nil)
        wait(for: [moved], timeout: 20)
        XCTAssertFalse(FileManager.default.fileExists(atPath: talk.path))

        // The next due item is the fixture's To Organize note, whose decision is a move.
        let next = NSPredicate { _, _ in self.text(title) == "Old note.txt" }
        XCTAssertEqual(XCTWaiter().wait(for: [expectation(for: next, evaluatedWith: nil)], timeout: 20), .completed,
                       "The card should advance to the next due item; got “\(text(title))”")
        XCTAssertEqual(app.buttons["overview.toReview.primary"].firstMatch.label, "Move to…")
        XCTAssertTrue(app.buttons["Delete…"].firstMatch.exists, "To Organize offers recoverable Trash")

        app.buttons["overview.toReview.undo"].firstMatch.click()
        let restored = expectation(for: NSPredicate { _, _ in FileManager.default.fileExists(atPath: talk.path) }, evaluatedWith: nil)
        wait(for: [restored], timeout: 20)
        XCTAssertEqual(try String(contentsOf: talk, encoding: .utf8), "https://example.com/talk")
    }

    func testBringForwardOffersFocusesAndFitsTheMinimumWindow() throws {
        let app = isolatedApp(arguments: ["-bwWindowWidth", "820", "-bwWindowHeight", "520"])
        app.launch()
        requireWindow(app)
        let shelf = app.descendants(matching: .any)["overview.focusShelf"].firstMatch
        XCTAssertTrue(shelf.waitForExistence(timeout: 30))
        let focus = app.descendants(matching: .any)["overview.focusPicker"].firstMatch
        XCTAssertTrue(focus.exists)
        XCTAssertTrue(app.descendants(matching: .any)["overview.focusContent"].firstMatch.exists)
        let review = app.descendants(matching: .any)["overview.toReview"].firstMatch
        XCTAssertTrue(review.waitForExistence(timeout: 30))
        // The column must fit the minimum window: nothing may run past its right edge.
        // Waited for, because the window shrinks from the harness's 1400pt after launch.
        let fits = NSPredicate { _, _ in
            let window = app.windows.firstMatch.frame
            return window.width < 1000 && shelf.frame.maxX <= window.maxX && review.frame.maxX <= window.maxX
        }
        let fitted = XCTWaiter().wait(for: [expectation(for: fits, evaluatedWith: nil)], timeout: 15)
        if fitted != .completed { attach(app, "Overview overflow 820x520") }
        XCTAssertEqual(fitted, .completed,
                       "Overview overflows the 820pt window: window \(app.windows.firstMatch.frame), shelf \(shelf.frame), card \(review.frame)")
        XCTAssertGreaterThan(shelf.frame.width, 300, "The shelf must not be squeezed at 820x520")
        attach(app, "Overview focus 820x520")

        // Recent file changes make the fixture project a revisit candidate with a timeline mark.
        focus.click()
        app.menuItems["Needs a revisit"].firstMatch.click()
        XCTAssertTrue(app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "overview.focusItem.")).firstMatch
            .waitForExistence(timeout: 20), "Needs a revisit should bring the fixture project forward")
        app.descendants(matching: .any)["overview.focusView"].firstMatch.click()
        app.menuItems["Compare two focuses"].firstMatch.click()
        XCTAssertLessThanOrEqual(shelf.frame.maxX, app.windows.firstMatch.frame.maxX, "Compare mode overflows the window")
        attach(app, "Overview focus compare 820x520")
        XCTAssertEqual(tableColumns(app).count, 0, "Bring forward is a short list, not a table")
    }

    func testCompletedDependencyUnblocksTheProjectRecommendation() throws {
        let project = Self.workspaceRoot.appendingPathComponent("Projects/Fixture project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let service = WorkItemService(), queue = Self.workspaceRoot.appendingPathComponent("To Do")
        _ = try service.create(WorkItem(id: "completed-prerequisite", kind: .task, title: "Already done", status: .completed,
            projectPath: "Projects/Fixture project", url: queue), in: queue)
        _ = try service.create(WorkItem(id: "ready-dependent", kind: .task, title: "Ready after completion", stage: .now,
            projectPath: "Projects/Fixture project", dependencyIDs: ["completed-prerequisite"], url: queue), in: queue)
        let app = launch()
        XCTAssertTrue(app.buttons["overview.nextAction.ready-dependent"].waitForExistence(timeout: 20))
        XCTAssertFalse(app.buttons["overview.nextAction.completed-prerequisite"].exists)
    }

    func testReviewExpandsFullTextAndRemembersCollapseAtMinimumWidth() throws {
        let note = Self.workspaceRoot.appendingPathComponent("To Watch/Reading notes.md")
        let body = "# Review notes\n\n" + String(repeating: "Useful context. ", count: 350) + "\n\nEnd of full review notes"
        try body.write(to: note, atomically: true, encoding: .utf8)
        let app = isolatedApp(arguments: ["-bwWindowWidth", "820", "-bwWindowHeight", "520"])
        app.launch(); requireWindow(app)
        let disclosure = app.buttons["overview.toReview.disclosure"].firstMatch
        XCTAssertTrue(disclosure.waitForExistence(timeout: 30))
        XCTAssertEqual(disclosure.label, "Expand review")
        let preview = app.descendants(matching: .any)["overview.toReview.preview"].firstMatch
        XCTAssertFalse(preview.exists, "Collapsed review must not mount a heavyweight preview")
        disclosure.click()
        XCTAssertTrue(preview.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["End of full review notes"].firstMatch.exists,
                      "Expanded preview includes text beyond the phone digest's 4,000-character excerpt")
        XCTAssertLessThanOrEqual(preview.frame.maxX, app.windows.firstMatch.frame.maxX)
        app.scrollViews["overview.scroll"].firstMatch.scroll(byDeltaX: 0, deltaY: -310)
        attach(app, "Overview expanded review 820x520")
        app.terminate(); app.launch(); requireWindow(app)
        XCTAssertTrue(preview.waitForExistence(timeout: 30), "Expansion survives relaunch")
        disclosure.click()
        XCTAssertFalse(preview.exists)
        XCTAssertTrue(app.buttons["overview.toReview.primary"].exists, "Decisions remain available while collapsed")
        app.terminate(); app.launch(); requireWindow(app)
        XCTAssertTrue(disclosure.waitForExistence(timeout: 30))
        XCTAssertEqual(disclosure.label, "Expand review")
        XCTAssertFalse(preview.exists, "Collapse survives relaunch")
    }
}
