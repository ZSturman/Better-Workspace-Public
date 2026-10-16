import XCTest

/// An empty list before the first read is "not known yet". These hold the first reads
/// back (`-bwSimulatedReadDelay`) and check the app says it is loading rather than
/// claiming there is nothing, then shows the real content once the read lands.
final class LoadingStateUITests: IsolatedUITestCase {

    private static let delaySeconds = 8

    private func launch(startingIn area: String, width: Int, height: Int) -> XCUIApplication {
        let app = isolatedApp(arguments: ["-bwSimulatedReadDelay", "\(Self.delaySeconds)",
                                          "-bwStartArea", area,
                                          "-bwWindowWidth", "\(width)", "-bwWindowHeight", "\(height)"])
        app.launch()
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

    private func waitForDisappearance(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let gone = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: element)
        return XCTWaiter().wait(for: [gone], timeout: timeout) == .completed
    }

    func testOverviewSaysItIsLoadingBeforeClaimingNoSignals() {
        let app = launch(startingIn: "Overview", width: 1400, height: 900)
        let loading = element(app, "loadingLabel")
        XCTAssertTrue(loading.waitForExistence(timeout: 15), "Overview should say it is still loading")
        XCTAssertFalse(app.staticTexts["Nothing needs your attention"].exists,
                       "Before the first refresh, an empty attention list is not known to be empty")
        attach(app, "Overview loading 1400x900")

        // The fixture seeds an inbox item, so the loaded Overview has a real signal.
        XCTAssertTrue(element(app, "overview.attention.Ingest inbox").waitForExistence(timeout: 40))
        XCTAssertTrue(waitForDisappearance(loading, timeout: 10), "Loading must give way to the content")
        attach(app, "Overview loaded 1400x900")
    }

    func testProjectsSaysItIsLoadingAtTheMinimumWindow() {
        let app = launch(startingIn: "Projects", width: 820, height: 520)
        let loading = element(app, "loadingState")
        XCTAssertTrue(loading.waitForExistence(timeout: 15), "Projects should say it is still loading")
        XCTAssertFalse(app.staticTexts["No matching projects"].exists)
        XCTAssertFalse(app.staticTexts["0 projects"].exists, "An uncounted list must not be counted as zero")
        attach(app, "Projects loading 820x520")

        XCTAssertTrue(app.staticTexts["Fixture project"].firstMatch.waitForExistence(timeout: 40),
                      "The fixture project should appear once Projects has been read")
        XCTAssertTrue(waitForDisappearance(loading, timeout: 10))
        attach(app, "Projects loaded 820x520")
    }

    func testIdeasSaysItIsLoadingAtTheMinimumWindow() {
        let app = launch(startingIn: "Ideas", width: 820, height: 520)
        let loading = element(app, "loadingState")
        XCTAssertTrue(loading.waitForExistence(timeout: 15), "Ideas should say it is still loading")
        XCTAssertFalse(app.staticTexts["No ideas yet"].exists)
        attach(app, "Ideas loading 820x520")

        XCTAssertTrue(waitForDisappearance(loading, timeout: 40))
        XCTAssertFalse(app.staticTexts["No ideas yet"].exists, "The fixture has an idea; it must be listed")
        attach(app, "Ideas loaded 820x520")
    }

    func testOverviewLoadingFitsTheMinimumWindow() {
        let app = launch(startingIn: "Overview", width: 820, height: 520)
        XCTAssertTrue(element(app, "loadingLabel").waitForExistence(timeout: 15))
        attach(app, "Overview loading 820x520")
        XCTAssertTrue(element(app, "overview.attention.Ingest inbox").waitForExistence(timeout: 40))
        attach(app, "Overview loaded 820x520")
    }

    /// The fixture's Study folder really is empty, so the loading state must give way to
    /// the honest empty state rather than spinning on.
    func testAnEmptyAreaShowsLoadingThenSaysItIsEmpty() {
        let app = launch(startingIn: "Study", width: 820, height: 520)
        let loading = element(app, "loadingState")
        XCTAssertTrue(loading.waitForExistence(timeout: 15))
        XCTAssertFalse(app.staticTexts["Nothing here yet"].exists)
        attach(app, "Empty area loading 820x520")

        XCTAssertTrue(app.staticTexts["Nothing here yet"].waitForExistence(timeout: 40))
        XCTAssertFalse(loading.exists)
        attach(app, "Empty area loaded 820x520")
    }

    func testIngestSaysItIsReadingTheInbox() {
        let app = launch(startingIn: "Ingest", width: 820, height: 520)
        let loading = element(app, "loadingState")
        XCTAssertTrue(loading.waitForExistence(timeout: 15), "Ingest should say it is reading the inbox")
        attach(app, "Ingest loading 820x520")
        XCTAssertTrue(waitForDisappearance(loading, timeout: 40))
        attach(app, "Ingest loaded 820x520")
    }

    /// Without the launch argument nothing is held back: the app opens straight onto content.
    func testNoLoadingStateLingersWithoutTheDelay() {
        let app = isolatedApp(arguments: ["-bwStartArea", "Projects"])
        app.launch()
        requireWindow(app)
        XCTAssertTrue(app.staticTexts["Fixture project"].firstMatch.waitForExistence(timeout: 20))
        XCTAssertFalse(element(app, "loadingState").exists)
    }
}
