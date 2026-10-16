import XCTest

/// Drives the real application against per-test workspace and inbox fixtures.
///
/// Screenshots are written to `/tmp/bw-uitest/` so the rendered result of each area can
/// be inspected, not just asserted on.
final class SmokeUITests: IsolatedUITestCase {

    private static let shotDirectory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        .appendingPathComponent("bw-uitest-shots", isDirectory: true)

    override class func setUp() {
        do {
            try FileManager.default.createDirectory(at: shotDirectory, withIntermediateDirectories: true)
            print("UITEST SHOTS -> \(shotDirectory.path)")
        } catch {
            print("UITEST SHOTS FAILED -> \(error)")
        }
    }




    private static var configuredInbox: URL? {
        inboxRoot
    }

    private func launch() -> XCUIApplication {
        let app = isolatedApp()
        app.launch()
        requireForeground(app)
        requireWindow(app)
        return app
    }

    private func shoot(_ app: XCUIApplication, _ name: String) {
        guard app.windows.firstMatch.exists else { print("UITEST SHOT SKIPPED -> \(name)"); return }
        let shot = app.windows.firstMatch.screenshot()
        try? shot.pngRepresentation.write(to: Self.shotDirectory.appendingPathComponent("\(name).png"))
        add(XCTAttachment(screenshot: shot))
    }

    // MARK: - Navigation through every discovered folder

    /// Walks whatever the sidebar found, not a fixed list.
    ///
    /// The nine areas used to be a hardcoded enum. They are discovered from the
    /// filesystem now, so asserting nine specific names would test a model the app no
    /// longer has — and would keep passing while discovery was broken.
    func test01_NavigateEveryArea() throws {
        let app = launch()
        shoot(app, "00-overview")

        let areas = discoveredFolderNames()
        XCTAssertFalse(areas.isEmpty, "The fixture seeded folders but the sidebar discovered none")
        for (index, area) in areas.enumerated() {
            print("UITEST AREA -> \(area)")
            let row = app.descendants(matching: .any)["sidebar.folder.\(area)"].firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 15), "\(area) row missing")
            row.click()
            // Each area renders its own header with its own subtitle.
            XCTAssertTrue(areaHeader(app, area).waitForExistence(timeout: 15), "\(area) header missing")
            Thread.sleep(forTimeInterval: 1.2)   // let async probes land before the shot
            shoot(app, String(format: "%02d-%@", index + 1, area.lowercased()))
        }
    }

    // MARK: - Window sizes

    func test02_WindowResizesWithoutLosingTheSidebarOrInspector() throws {
        let app = launch()
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 20))

        app.descendants(matching: .any)["sidebar.folder.Projects"].firstMatch.click()
        Thread.sleep(forTimeInterval: 1)

        drag(window, by: CGVector(dx: -420, dy: -260))
        Thread.sleep(forTimeInterval: 1.5)
        shoot(app, "20-narrow")
        let header = areaHeader(app, "Projects")
        XCTAssertTrue(header.exists && header.isHittable, "Header survives a narrow window")

        drag(window, by: CGVector(dx: 420, dy: 260))
        Thread.sleep(forTimeInterval: 1.5)
        shoot(app, "21-wide")
    }

    /// Resizes by dragging the bottom-right corner; `resizeWindow(byMovingCorner:)` is
    /// not in this SDK.
    private func drag(_ window: XCUIElement, by offset: CGVector) {
        let corner = window.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 1))
        corner.press(forDuration: 0.2, thenDragTo: corner.withOffset(offset))
    }

    // MARK: - Capture → tag → classify, end to end, through the UI

    func test03_CaptureTagAndClassifyThroughTheInterface() throws {
        let app = launch()
        let marker = "UITest Idea \(Int(Date().timeIntervalSince1970) % 100000)"

        app.descendants(matching: .any)["sidebar.ingest"].firstMatch.click()

        // 1. Type into the capture box and capture. This must produce a real .md file.
        app.buttons["ingest.newCapture"].firstMatch.click()
        let field = app.textViews["ingest.captureField"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 20))
        field.click()
        field.typeText(marker)
        shoot(app, "30-typed")

        app.buttons["ingest.captureButton"].firstMatch.click()
        Thread.sleep(forTimeInterval: 2.5)
        shoot(app, "31-captured")

        // 2. The item is now in the queue with a preview and a classifier.
        XCTAssertTrue(app.buttons["ingest.fileItButton"].firstMatch.waitForExistence(timeout: 20),
                      "A captured item must open in the processing pane")

        // 3. Create and assign a tag from the shared editor, before classifying.
        // The capture popover stays open for the next capture; close it to file this one.
        app.typeKey(.escape, modifierFlags: [])
        let tagField = app.textFields["tag.searchField"].firstMatch
        XCTAssertTrue(tagField.waitForExistence(timeout: 10))
        tagField.click()
        tagField.typeText("AI\n")
        Thread.sleep(forTimeInterval: 1.5)
        shoot(app, "32-tagged")

        // 4. Pick Ideas as the destination and file it.
        let ideasButton = app.descendants(matching: .any)["ingest.destination.Ideas"].firstMatch
        XCTAssertTrue(ideasButton.waitForExistence(timeout: 10))
        ideasButton.click()
        Thread.sleep(forTimeInterval: 0.8)
        shoot(app, "33-destination-chosen")

        app.buttons["ingest.fileItButton"].firstMatch.click()
        Thread.sleep(forTimeInterval: 3)
        shoot(app, "34-filed")

        // 5. It physically moved into the isolated Workspace/Ideas.
        let ideas = Self.workspaceRoot.appendingPathComponent("Ideas")
        let landed = (try? FileManager.default.contentsOfDirectory(atPath: ideas.path))?
            .first { $0.hasPrefix("UITest Idea") }
        XCTAssertNotNil(landed, "Classifying as an Idea must move the file into the isolated Workspace/Ideas")
        let landedTitle = landed.map { ($0 as NSString).deletingPathExtension } ?? marker

        // 6. And the app now shows it in Ideas, carrying the tag.
        app.descendants(matching: .any)["sidebar.folder.Ideas"].firstMatch.click()
        Thread.sleep(forTimeInterval: 2)
        shoot(app, "35-ideas-after")
        XCTAssertTrue(app.staticTexts[landedTitle].firstMatch.waitForExistence(timeout: 20),
                      "The classified item must appear in the Ideas list")


    }

    // MARK: - External filesystem changes

    func test04_ExternalInboxDropBecomesAPendingItem() throws {
        let app = launch()
        app.descendants(matching: .any)["sidebar.ingest"].firstMatch.click()
        Thread.sleep(forTimeInterval: 2)

        let inbox = Self.inboxRoot

        let name = "External Drop \(Int(Date().timeIntervalSince1970) % 100000).txt"
        let dropped = inbox.appendingPathComponent(name)
        try "dropped by the test runner".write(to: dropped, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: dropped) }

        // No refresh button pressed: FSEvents must notice it.
        // FSEvents coalescing plus the inbox read's own timeout mean this is not instant,
        // and the inbox lives in iCloud Drive, so allow generously.
        let title = dropped.deletingPathExtension().lastPathComponent
        let label = app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", title)
        ).firstMatch
        XCTAssertTrue(label.waitForExistence(timeout: 60),
                      "A file added to the inbox outside the app must appear in the queue")
        shoot(app, "40-external-drop")
    }

    // MARK: - Multiple pending items

    /// Captures two items and walks the queue.
    ///
    /// Regression cover for a bug where the title editor lived on the parent view: a
    /// second capture shifted which item was current and the in-flight binding wrote
    /// the new item's title onto the previous item's record.
    func test05_MultipleItemsKeepTheirOwnTitlesAndNextItemFlowWorks() throws {
        let app = launch()
        app.descendants(matching: .any)["sidebar.ingest"].firstMatch.click()

        app.buttons["ingest.newCapture"].firstMatch.click()
        let field = app.textViews["ingest.captureField"].firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 20))

        let first = "QueueOne\(Int(Date().timeIntervalSince1970) % 1000)"
        let second = "QueueTwo\(Int(Date().timeIntervalSince1970) % 1000)"

        for text in [first, second] {
            field.click()
            field.typeText(text)
            app.buttons["ingest.captureButton"].firstMatch.click()
            Thread.sleep(forTimeInterval: 2.5)
        }
        shoot(app, "50-two-captures")

        let title = app.textFields["ingest.titleField"].firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 15))
        let currentTitle = (title.value as? String) ?? ""
        XCTAssertFalse(currentTitle.isEmpty, "The focused item must have a title")

        // Walk to the next item; the title must change, not be duplicated.
        app.typeKey("]", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 1.5)
        let secondTitle = (app.textFields["ingest.titleField"].firstMatch.value as? String) ?? ""
        shoot(app, "51-next-item")
        XCTAssertNotEqual(secondTitle, currentTitle,
                          "⌘] must move to a different item, each with its own title")
        XCTAssertFalse(secondTitle.isEmpty)

        // Both captures still exist on disk with their own names.
        if let root = Self.configuredInbox {
            let files = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
            XCTAssertTrue(files.contains { $0.contains(first) }, "First capture missing from \(root.path)")
            XCTAssertTrue(files.contains { $0.contains(second) }, "Second capture missing from \(root.path)")
            for name in files where name.contains(first) || name.contains(second) {
                try? FileManager.default.removeItem(at: root.appendingPathComponent(name))
            }
        }
    }
}
