import XCTest

/// The capability-aware views, driven through the real app over a fixture whose
/// contents are chosen to switch each capability on or off: dates spread over years,
/// subfolders with things in them, and too few pictures for a gallery.
final class AreaViewsUITests: IsolatedUITestCase {

    private var fieldNotes: URL { Self.workspaceRoot.appendingPathComponent("Field Notes") }
    private var settingsFile: URL { Self.fixtureRoot.appendingPathComponent("Areas.json") }

    override func setUpWithError() throws {
        try super.setUpWithError()
        let fm = FileManager.default
        try fm.createDirectory(at: fieldNotes.appendingPathComponent("Sources/Deep"), withIntermediateDirectories: true)
        try "transcript".write(to: fieldNotes.appendingPathComponent("Sources/Interview transcript.md"),
                               atomically: true, encoding: .utf8)
        try "deep".write(to: fieldNotes.appendingPathComponent("Sources/Deep/Buried note.txt"),
                         atomically: true, encoding: .utf8)
        let calendar = Calendar(identifier: .gregorian)
        let dated: [(String, Int, Int)] = [
            ("Site survey.md", 2024, 3), ("Soil readings.csv", 2024, 11), ("Permit letter.pdf", 2025, 6),
            ("Budget.xlsx", 2025, 12), ("Walkthrough.md", 2026, 8),
        ]
        for (name, year, month) in dated {
            let url = fieldNotes.appendingPathComponent(name)
            try "fixture".write(to: url, atomically: true, encoding: .utf8)
            let date = calendar.date(from: DateComponents(year: year, month: month, day: 9, hour: 12))!
            try fm.setAttributes([.creationDate: date, .modificationDate: date], ofItemAtPath: url.path)
        }
        // Dated by its name, created today: the timeline should believe the name.
        let picture = try Data(contentsOf: Self.workspaceRoot.appendingPathComponent("For Inspiration/Wide inspiration.png"))
        try picture.write(to: fieldNotes.appendingPathComponent("Screenshot 2025-03-04 at 10.00.00.png"))
    }

    private func launch(startingIn area: String, width: Int = 1100, height: Int = 760) -> XCUIApplication {
        let app = isolatedApp(arguments: ["-bwStartArea", area,
                                          "-bwWindowWidth", "\(width)", "-bwWindowHeight", "\(height)"])
        app.launch()
        requireForeground(app)
        requireWindow(app)
        return app
    }

    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func write(settings: [String: String]) throws {
        let areas = settings.map { "\"\($0.key)\": {\"configuration\": {\"layout\": \"\($0.value)\"}}" }
        try "{\"version\": 1, \"areas\": {\(areas.joined(separator: ","))}}"
            .write(to: settingsFile, atomically: true, encoding: .utf8)
    }

    func testProjectToolsAppearOnTheApplicablePortfolioCard() {
        let app = launch(startingIn: "Projects")
        let cards = app.radioButtons["Cards"].firstMatch
        XCTAssertTrue(cards.waitForExistence(timeout: 15))
        cards.click()

        XCTAssertTrue(app.buttons["Explain"].firstMatch.waitForExistence(timeout: 15),
                      "The fixture project has a README, so its portfolio card should offer Explain.")
        XCTAssertFalse(element(app, "projects.explain").exists,
                       "Explain must not be presented as a selection-dependent action for the whole portfolio.")
        XCTAssertFalse(element(app, "projects.flowReview").exists,
                       "Flow Review must not be presented as a selection-dependent action for the whole portfolio.")
    }

    func testTheViewMenuOffersWhatTheContentsSupportAndSaysWhyNot() throws {
        let app = launch(startingIn: "Field Notes")
        XCTAssertTrue(app.staticTexts["Site survey"].waitForExistence(timeout: 15))

        element(app, "area.layout").click()
        XCTAssertTrue(app.menuItems["Timeline"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.menuItems["Timeline"].isEnabled, "Dates spread over three years")
        XCTAssertTrue(app.menuItems["Outline"].isEnabled, "Sources has something in it")
        XCTAssertFalse(app.menuItems["Gallery"].isEnabled, "One picture among eight items is not a gallery")
        attach(app, "view menu")

        app.menuItems["Timeline"].click()
        XCTAssertTrue(element(app, "area.timeline.rail").waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["date from name"].exists, "The screenshot is dated by its name")
        attach(app, "timeline, added")

        element(app, "area.layout").click()
        app.menuItems["Outline"].click()
        let outline = app.outlines["area.outline"]
        XCTAssertTrue(outline.waitForExistence(timeout: 10))
        // Sources is the only top-level folder with something in it, so the only triangle.
        let triangle = outline.disclosureTriangles.firstMatch
        XCTAssertTrue(triangle.waitForExistence(timeout: 5))
        triangle.click()
        XCTAssertTrue(app.staticTexts["Interview transcript"].waitForExistence(timeout: 10),
                      "Opening a folder in place reads its children")
        // Nested folders open the same way, and a nested file can be selected and inspected.
        let deepTriangle = outline.disclosureTriangles.matching(NSPredicate(format: "value == 0")).firstMatch
        XCTAssertTrue(deepTriangle.waitForExistence(timeout: 5))
        deepTriangle.click()
        let buried = app.staticTexts["Buried note"].firstMatch
        XCTAssertTrue(buried.waitForExistence(timeout: 10))
        buried.click()
        XCTAssertFalse(app.staticTexts["Nothing selected"].waitForExistence(timeout: 2),
                       "Selecting a nested file should put it in the inspector")
        attach(app, "outline, expanded and selected")

        // Searching reaches what has been opened, and shows the path to it.
        let search = app.textFields.matching(NSPredicate(format: "placeholderValue CONTAINS[c] 'search'")).firstMatch
        search.click()
        search.typeText("buried")
        XCTAssertTrue(app.staticTexts["Sources › Deep"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Site survey"].exists)
        attach(app, "outline, searching")
    }

    func testTheTimelineFitsTheSmallestWindow() throws {
        try write(settings: ["Field Notes": "timeline"])
        let app = launch(startingIn: "Field Notes", width: 820, height: 520)
        XCTAssertTrue(element(app, "area.timeline.rail").waitForExistence(timeout: 15))
        XCTAssertTrue(element(app, "area.dateBasis").exists)
        XCTAssertTrue(app.staticTexts["Field Notes"].exists, "The title must survive the trailing controls")
        attach(app, "timeline at 820x520")
    }

    func testAChosenViewTheContentsNoLongerSupportFallsBackAndSaysSo() throws {
        // The fixture's Ideas holds a single note: no history to lay out.
        try write(settings: ["Ideas": "timeline"])
        let app = launch(startingIn: "Ideas")
        XCTAssertTrue(element(app, "area.layoutFallback").waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["Fixture idea"].exists, "The list is shown instead")
        attach(app, "timeline unavailable")
    }
}
