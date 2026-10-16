import XCTest

/// A guided walk through the whole Mac app that screenshots every state a person
/// actually looks at, plus the workflows that touch the real filesystem.
///
/// The assertions matter, but the screenshots are the point — they get reviewed by eye.
/// Where a step changes the filesystem, the test reads `the isolated Workspace` back to confirm the
/// interface and the disk agree.
///
/// Each test owns a fresh workspace, inbox, and database.
final class UXWalkthroughTests: IsolatedUITestCase {

    private static let shots = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent("bw-ux", isDirectory: true)

    private var step = 0

    override class func setUp() {
        try? FileManager.default.removeItem(at: shots)
        try? FileManager.default.createDirectory(at: shots, withIntermediateDirectories: true)
        print("UX SHOTS -> \(shots.path)")
    }


    private static func area(_ name: String) -> URL {
        workspaceRoot.appendingPathComponent(name, isDirectory: true)
    }

    private static func names(in area: String) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: Self.area(area).path)) ?? []
    }

    // MARK: - Harness

    private func shoot(_ app: XCUIApplication, _ name: String, settle: TimeInterval = 1.0) {
        Thread.sleep(forTimeInterval: settle)
        guard app.windows.firstMatch.exists else { print("UX SHOT SKIPPED -> \(name)"); return }
        step += 1
        let shot = app.windows.firstMatch.screenshot()
        let file = String(format: "%02d-%@.png", step, name)
        try? shot.pngRepresentation.write(to: Self.shots.appendingPathComponent(file))
        add(XCTAttachment(screenshot: shot))
        print("UX SHOT -> \(file)")
    }

    private func go(_ app: XCUIApplication, area name: String) {
        let row = app.descendants(matching: .any)["sidebar.folder.\(name)"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 20), "\(name) unreachable")
        row.click()
    }

    private func goIngest(_ app: XCUIApplication) {
        let row = app.descendants(matching: .any)["sidebar.ingest"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 20), "Ingest unreachable")
        row.click()
    }

    /// Captures text through the real capture field and returns the title the app used.
    @discardableResult
    private func capture(_ app: XCUIApplication, _ text: String) -> String {
        openIngest(app)
        app.buttons["ingest.newCapture"].firstMatch.click()
        let field = app.textViews["ingest.captureField"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 20))
        field.click()
        field.typeText(text)
        app.buttons["ingest.captureButton"].firstMatch.click()
        Thread.sleep(forTimeInterval: 3)
        let title = app.textFields["ingest.titleField"].firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 20), "Captured item did not open for processing")
        return (title.value as? String) ?? text
    }

    private func classify(_ app: XCUIApplication, into area: String) {
        let destination = app.descendants(matching: .any)["ingest.destination.\(area)"].firstMatch
        XCTAssertTrue(destination.waitForExistence(timeout: 10), "\(area) destination missing")
        destination.click()
        Thread.sleep(forTimeInterval: 0.6)
        let fileIt = app.buttons["ingest.fileItButton"].firstMatch
        XCTAssertTrue(fileIt.isEnabled, "File it should be enabled once a destination is chosen")
        fileIt.click()
        Thread.sleep(forTimeInterval: 3)
    }

    // MARK: - The walk

    func testWalkTheWholeApp() throws {
        let app = isolatedApp(arguments: ["-bwWindowWidth", "1400", "-bwWindowHeight", "900"])
        app.launch()
        requireWindow(app)
        shoot(app, "ingest-empty", settle: 3.0)

        // ---- Capture → tag → classify into Ideas, verified on disk ----
        let ideaText = "UXWalk Idea \(Int(Date().timeIntervalSince1970) % 100000)"
        let ideaTitle = capture(app, ideaText)
        shoot(app, "ingest-item-focused", settle: 1.0)

        // The capture popover stays open for the next capture; close it to file this one.
        app.typeKey(.escape, modifierFlags: [])
        let tagField = app.textFields["tag.searchField"].firstMatch
        XCTAssertTrue(tagField.waitForExistence(timeout: 10))
        tagField.click()
        tagField.typeText("Hardware\n")
        shoot(app, "ingest-tagged", settle: 1.5)

        let ideasBefore = Self.names(in: "Ideas").count
        classify(app, into: "Ideas")
        shoot(app, "ingest-after-filing", settle: 1.5)

        let ideasAfter = Self.names(in: "Ideas")
        XCTAssertEqual(ideasAfter.count, ideasBefore + 1, "Filing should add exactly one Idea")
        let landedIdea = ideasAfter.first { $0.hasPrefix("UXWalk Idea") }
        XCTAssertNotNil(landedIdea, "The filed note must exist in the isolated Workspace/Ideas")
        XCTAssertEqual(landedIdea, "\(ideaTitle).md", "Filename on disk must match what the UI showed")
        print("UX FILED IDEA -> \(landedIdea ?? "nil")")

        // ---- A second item into a different destination ----
        let refText = "UXWalk Reference \(Int(Date().timeIntervalSince1970) % 100000)"
        let refTitle = capture(app, refText)
        app.typeKey(.escape, modifierFlags: [])
        let referenceTag = app.textFields["tag.searchField"].firstMatch
        referenceTag.click()
        referenceTag.typeText("Hardware\n")
        classify(app, into: "For Reference")
        let landedRef = Self.names(in: "For Reference").first { $0.hasPrefix("UXWalk Reference") }
        XCTAssertEqual(landedRef, "\(refTitle).md", "Second destination must also receive the real file")
        print("UX FILED REFERENCE -> \(landedRef ?? "nil")")

        // ---- A third item, skipped rather than filed ----
        let skipText = "UXWalk Skipped \(Int(Date().timeIntervalSince1970) % 100000)"
        let skipTitle = capture(app, skipText)
        shoot(app, "ingest-before-skip", settle: 0.8)
        app.buttons["Skip"].firstMatch.click()
        shoot(app, "ingest-after-skip", settle: 2.0)

        // Skipping moves on to whatever is next, so the skipped item is no longer the
        // one in focus. It must still be in the queue, and the header must own up to it.
        // (An earlier version asserted "Un-skip" is on screen, which only held when the
        // queue had exactly one item. The fixture deliberately includes another item.)
        XCTAssertTrue(app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS[c] 'skipped' OR value CONTAINS[c] 'skipped'")).firstMatch.waitForExistence(timeout: 10),
            "The header should report how many items are skipped")

        let skippedChip = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@", skipTitle)).firstMatch
        XCTAssertTrue(skippedChip.waitForExistence(timeout: 10),
                      "A skipped item stays in the queue rather than disappearing")
        skippedChip.click()
        Thread.sleep(forTimeInterval: 1.5)
        XCTAssertTrue(app.buttons["Un-skip"].firstMatch.waitForExistence(timeout: 10),
                      "Selecting a skipped item offers Un-skip")

        app.buttons["Un-skip"].firstMatch.click()
        XCTAssertTrue(app.buttons["Skip"].firstMatch.waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] 'skipped' OR value CONTAINS[c] 'skipped'")).firstMatch.exists)
        app.buttons["Skip"].firstMatch.click()

        // ---- Every discovered area ----
        for name in discoveredFolderNames() {
            go(app, area: name)
            XCTAssertTrue(areaHeader(app, name).waitForExistence(timeout: 20), "\(name) header missing")
            shoot(app, name.lowercased(), settle: name == "Projects" || name == "Assets" ? 3.0 : 2.0)
        }

        // ---- Inspector: selection, tagging, and that it follows the area ----
        go(app, area: "Ideas")
        Thread.sleep(forTimeInterval: 1.5)
        if let filed = landedIdea {
            let title = (filed as NSString).deletingPathExtension
            let row = app.staticTexts[title].firstMatch
            if row.waitForExistence(timeout: 10) {
                row.click()
                shoot(app, "ideas-inspector-selected", settle: 1.5)
                let inspectorTag = app.textFields["tag.searchField"].firstMatch
                if inspectorTag.exists {
                    inspectorTag.click()
                    inspectorTag.typeText("AI\n")
                    shoot(app, "ideas-inspector-tagged", settle: 1.5)
                }
            }
        }

        // Projects hides an empty inspector (it has its own project workspace) and
        // reading areas such as For Reference select their first document, so check
        // clearing where an area opens with nothing selected and shows the inspector.
        go(app, area: "Analytics")
        shoot(app, "analytics-inspector-cleared", settle: 2.5)
        XCTAssertTrue(app.staticTexts["Nothing selected"].firstMatch.waitForExistence(timeout: 10),
                      "Changing area must clear the inspector rather than describe the old item")

        // ---- Organize filters ----
        go(app, area: "To Organize")
        Thread.sleep(forTimeInterval: 2)
        let oldest = app.descendants(matching: .any)["organize.ageBand.Over 2 years"].firstMatch
        if oldest.waitForExistence(timeout: 10) {
            oldest.click()
            shoot(app, "organize-filtered", settle: 1.5)
            oldest.click()
        }

        // ---- Inspiration flatten ----
        go(app, area: "For Inspiration")
        Thread.sleep(forTimeInterval: 2)
        let flatten = app.descendants(matching: .any)["inspiration.flatten"].firstMatch
        if flatten.waitForExistence(timeout: 10) {
            flatten.click()
            shoot(app, "inspiration-flattened", settle: 4.0)
            flatten.click()
        }

        // ---- Tags across areas ----
        let tagRow = app.descendants(matching: .any)["sidebar.tag.Hardware"].firstMatch
        if tagRow.waitForExistence(timeout: 10) {
            tagRow.click()
            shoot(app, "tag-browser", settle: 2.0)
        }

        // ---- Window size ----
        let startFrame = app.windows.firstMatch.frame
        print("UX WINDOW default -> \(Int(startFrame.width))x\(Int(startFrame.height))")

        // ---- Inspector hidden ----
        go(app, area: "Projects")
        Thread.sleep(forTimeInterval: 1.5)
        app.typeKey("i", modifierFlags: [.command, .option])
        shoot(app, "projects-no-inspector", settle: 1.5)
        app.typeKey("i", modifierFlags: [.command, .option])

        // ---- Back to the inbox, where the skipped item should still be ----
        goIngest(app)
        shoot(app, "ingest-skipped-still-there", settle: 2.5)

        XCTAssertGreaterThan(step, 16, "The walk should have produced a screenshot per screen")
        print("UX SHOTS COMPLETE -> \(Self.shots.path)")
    }

}

/// The same screens at the smallest size the window allows.
///
/// Dragging the resize corner through the accessibility API does not resize a SwiftUI
/// window, so the size is set with a launch argument instead and the app is relaunched.
final class SmallWindowUXTests: IsolatedUITestCase {

    private static let shots = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent("bw-ux-small", isDirectory: true)
    private var step = 0

    override class func setUp() {
        try? FileManager.default.removeItem(at: shots)
        try? FileManager.default.createDirectory(at: shots, withIntermediateDirectories: true)
        print("UX SMALL SHOTS -> \(shots.path)")
    }

    private func shoot(_ app: XCUIApplication, _ name: String, settle: TimeInterval = 1.5) {
        Thread.sleep(forTimeInterval: settle)
        guard app.windows.firstMatch.exists else { return }
        step += 1
        let shot = app.windows.firstMatch.screenshot()
        try? shot.pngRepresentation.write(
            to: Self.shots.appendingPathComponent(String(format: "%02d-%@.png", step, name)))
        add(XCTAttachment(screenshot: shot))
        print("UX SMALL SHOT -> \(name)")
    }

    func testLayoutAtTheSmallestSupportedSize() {
        let app = isolatedApp(arguments: ["-bwWindowWidth", "820", "-bwWindowHeight", "520"])
        app.launch()
        requireWindow(app)

        let frame = app.windows.firstMatch.frame
        print("UX SMALL WINDOW -> \(Int(frame.width))x\(Int(frame.height))")
        XCTAssertLessThan(frame.width, 1000, "The launch argument should have shrunk the window")

        openIngest(app)
        shoot(app, "ingest", settle: 3.0)
        let classifier = app.scrollViews.containing(.textField, identifier: "ingest.titleField").firstMatch
        classifier.scroll(byDeltaX: 0, deltaY: 500)
        XCTAssertTrue(app.buttons["ingest.fileItButton"].firstMatch.isHittable,
                      "The filing controls must be reachable in the smallest window")
        shoot(app, "ingest-scrolled-controls")
        for name in ["Ideas", "Projects", "To Organize", "Logs", "Assets"] {
            let row = revealSidebarRow(app, "sidebar.folder.\(name)")
            XCTAssertTrue(row.isHittable, "\(name) should be reachable by scrolling the sidebar")
            row.click()
            shoot(app, name.lowercased(), settle: 2.5)
        }
    }
}
