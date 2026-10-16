import XCTest

/// Editing a work item in the inspector while something else edits the same Markdown file.
final class WorkItemEditingUITests: IsolatedUITestCase {

    private var record: URL { Self.workspaceRoot.appendingPathComponent("To Do/Water the plants.bw.md") }

    override func setUpWithError() throws {
        try super.setUpWithError()
        try """
        ---
        better-workspace: 1
        id: plants-1
        kind: task
        title: "Water the plants"
        status: open
        stage: next
        priority: medium
        estimate: 10m
        ---

        # Water the plants
        """.write(to: record, atomically: true, encoding: .utf8)
    }

    private func openEditor() -> (app: XCUIApplication, editor: XCUIElement) {
        let app = isolatedApp(arguments: ["-bwStartArea", "Work"])
        app.launch()
        requireWindow(app)
        let row = app.staticTexts["Water the plants"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 20))
        row.click()
        let edit = app.descendants(matching: .any)["inspector.editText"].firstMatch
        XCTAssertTrue(edit.waitForExistence(timeout: 10))
        edit.click()
        let editor = app.textViews.firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        return (app, editor)
    }

    private func captureFlow(_ app: XCUIApplication, named name: String) {
        let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testSavedDescriptionSurvivesRelaunch() throws {
        let opened = openEditor()
        opened.editor.click()
        opened.editor.typeKey(.downArrow, modifierFlags: .command)
        opened.editor.typeText("\nFunctional audit persisted note")
        captureFlow(opened.app, named: "mac-work-description-before-save")
        opened.app.descendants(matching: .any)["inspector.saveText"].firstMatch.click()
        let persisted = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            (try? String(contentsOf: self.record, encoding: .utf8))?.contains("Functional audit persisted note") == true
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [persisted], timeout: 15), .completed)
        XCTAssertTrue(try String(contentsOf: record, encoding: .utf8).hasSuffix("# Water the plants\nFunctional audit persisted note"),
                      "The note belongs in the description, after the original body and outside frontmatter")
        opened.app.terminate()
        XCTAssertTrue(opened.app.wait(for: .notRunning, timeout: 10))

        let relaunched = openEditor()
        XCTAssertTrue((relaunched.editor.value as? String)?.contains("Functional audit persisted note") == true)
        captureFlow(relaunched.app, named: "mac-work-description-after-relaunch")
    }

    /// A concurrent edit is surfaced and the inspector never overwrites it.
    func testAConflictKeepsTheInspectorOpenAndPreservesTheVersionOnDisk() throws {
        let opened = openEditor()
        let app = opened.app
        let editor = opened.editor
        editor.click()
        editor.typeKey(.downArrow, modifierFlags: .command)
        editor.typeText("\nMy unsaved note")

        Thread.sleep(forTimeInterval: 1.1)
        let theirs = try String(contentsOf: record, encoding: .utf8).replacingOccurrences(of: "priority: medium", with: "priority: high")
        try theirs.write(to: record, atomically: false, encoding: .utf8)

        app.descendants(matching: .any)["inspector.saveText"].firstMatch.click()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "value CONTAINS %@", "changed in another app"))
            .firstMatch.waitForExistence(timeout: 10), "A conflict is reported in the inspector")
        XCTAssertTrue((editor.value as? String)?.contains("My unsaved note") == true, "What was typed is still there")
        XCTAssertTrue(try String(contentsOf: record, encoding: .utf8).contains("priority: high"),
                      "The other change was not overwritten")
        captureFlow(app, named: "mac-work-conflict-preserves-unsaved-description")
    }

    /// Reload deliberately accepts the disk version; a later save uses that new snapshot.
    func testReloadThenSaveUsesTheFreshOnDiskVersion() throws {
        let opened = openEditor()
        let app = opened.app
        opened.editor.click()
        opened.editor.typeKey(.downArrow, modifierFlags: .command)
        opened.editor.typeText("\nMine wins")

        Thread.sleep(forTimeInterval: 1.1)
        let theirs = try String(contentsOf: record, encoding: .utf8).replacingOccurrences(of: "stage: next", with: "stage: later")
        try theirs.write(to: record, atomically: false, encoding: .utf8)

        app.descendants(matching: .any)["inspector.saveText"].firstMatch.click()
        XCTAssertTrue(app.buttons["Reload"].firstMatch.waitForExistence(timeout: 10))
        app.buttons["Reload"].firstMatch.click()
        let edit = app.descendants(matching: .any)["inspector.editText"].firstMatch
        XCTAssertTrue(edit.waitForExistence(timeout: 10))
        edit.click()
        let editor = app.textViews.firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        editor.click()
        editor.typeKey(.downArrow, modifierFlags: .command)
        editor.typeText("\nMine wins")
        app.descendants(matching: .any)["inspector.saveText"].firstMatch.click()
        let expectation = expectation(description: "saved")
        DispatchQueue.global().async {
            for _ in 0..<50 {
                if (try? String(contentsOf: self.record, encoding: .utf8))?.contains("Mine wins") == true { break }
                Thread.sleep(forTimeInterval: 0.2)
            }
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 15)
        let saved = try String(contentsOf: record, encoding: .utf8)
        XCTAssertTrue(saved.contains("Mine wins"), saved)
        XCTAssertTrue(saved.contains("stage: later"), saved)
        XCTAssertTrue(saved.contains("estimate: 10m"), saved)
        XCTAssertTrue(saved.hasSuffix("# Water the plants\nMine wins"), saved)
        captureFlow(app, named: "mac-work-reloaded-conflict-saved")
    }

    func testCompletionHasAnUndoGracePeriodBeforeWriting() throws {
        let app = isolatedApp(arguments: ["-bwStartArea", "Work"])
        app.launch()
        requireWindow(app)
        let completion = app.descendants(matching: .any)["workItem.complete.plants-1"].firstMatch
        XCTAssertTrue(completion.waitForExistence(timeout: 20))

        completion.click()
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertTrue(try String(contentsOf: record, encoding: .utf8).contains("status: open"),
                      "The grace period must not persist an accidental completion")
        completion.click()
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertTrue(try String(contentsOf: record, encoding: .utf8).contains("status: open"))
        captureFlow(app, named: "mac-work-completion-undone-before-persisting")

        completion.click()
        let saved = expectation(description: "completion persisted")
        DispatchQueue.global().async {
            for _ in 0..<20 {
                if (try? String(contentsOf: self.record, encoding: .utf8))?.contains("status: completed") == true { break }
                Thread.sleep(forTimeInterval: 0.2)
            }
            saved.fulfill()
        }
        wait(for: [saved], timeout: 8)
        XCTAssertTrue(try String(contentsOf: record, encoding: .utf8).contains("status: completed"))
    }
}
