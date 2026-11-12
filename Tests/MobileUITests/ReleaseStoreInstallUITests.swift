import XCTest

/// Explicit release-only setup. Never enters Apple credentials or accepts legal terms.
final class ReleaseStoreInstallUITests: XCTestCase {
    func testInspectNormalLaunchOverlay() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["BW_RELEASE_STORE_INSTALL"] == "1")
        let app = XCUIApplication(); app.launch(); defer { app.terminate() }
        let screen = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screen.name = "normal-launch-overlay-local-only"; screen.lifetime = .keepAlways; add(screen)
        let service = XCUIApplication(bundleIdentifier: "com.apple.ios.StoreKitUIService")
        if service.state != .notRunning {
            let state = XCTAttachment(string: service.debugDescription)
            state.name = "storekit-overlay-local-only"; state.lifetime = .keepAlways; add(state)
        }
    }
    func testCaptureIsolatedWorkspaceForStore() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["BW_RELEASE_STORE_INSTALL"] == "1")
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["-BWUnifiedFixture", UUID().uuidString]
        app.launch(); defer { app.terminate() }
        let start = app.buttons["unified.welcome.local"]
        XCTAssertTrue(start.waitForExistence(timeout: 20)); start.tap()
        app.buttons["unified.new"].tap()
        let title = app.textFields["unified.editor.title"]
        XCTAssertTrue(title.waitForExistence(timeout: 10)); title.tap(); title.typeText("Plan the garden journal")
        let body = app.textViews["unified.editor.body"]
        body.tap(); body.typeText("Choose a few ideas for the coming week.")
        app.buttons["unified.editor.save"].tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'unified.item.'")).firstMatch.waitForExistence(timeout: 10))
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "store-unified-workspace"; shot.lifetime = .keepAlways; add(shot)
    }

    /// Explicit release acceptance: update only this app through Apple's TestFlight.
    /// CoreDevice must independently verify the installed version after this test.
    func testUpdateBetterWorkspaceThroughTestFlight() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Requires the owner's physical TestFlight installation.")
        #else
        try XCTSkipUnless(ProcessInfo.processInfo.environment["BW_RELEASE_STORE_INSTALL"] == "1")
        continueAfterFailure = false
        let flight = XCUIApplication(bundleIdentifier: "com.apple.TestFlight")
        flight.launch()
        defer { flight.terminate() }
        XCTAssertTrue(flight.wait(for: .runningForeground, timeout: 20))
        let app = flight.staticTexts["Better Workspace"].firstMatch
        XCTAssertTrue(app.waitForExistence(timeout: 30), "The existing owner-only beta must be visible.")
        app.tap()
        let update = flight.buttons.matching(NSPredicate(format: "label == 'Update' OR label == 'UPDATE' OR label == 'Install' OR label == 'INSTALL'")).firstMatch
        let open = flight.buttons.matching(NSPredicate(format: "label == 'Open' OR label == 'OPEN'")).firstMatch
        if update.waitForExistence(timeout: 8) { update.tap() }
        let replacement = flight.alerts["You already have this app installed."]
        if replacement.waitForExistence(timeout: 5) {
            guard ProcessInfo.processInfo.environment["BW_RELEASE_REPLACE_APPROVED"] == "1" else {
                throw XCTSkip("TestFlight warns that replacing the installed app may lose data. Explicit owner approval is required.")
            }
            // This opt-in is separate from installing a beta: Apple explicitly warns
            // about existing data when replacing a development installation.
            replacement.buttons["Install"].tap()
        }
        let hierarchy = XCTAttachment(string: flight.debugDescription)
        hierarchy.name = "testflight-update-state-local-only"; hierarchy.lifetime = .keepAlways; add(hierarchy)
        XCTAssertTrue(open.waitForExistence(timeout: 120), "Complete any authentication or agreement on the device; this test never accepts it.")
        print("BW-RELEASE TestFlight shows Open; independently verify installed version/build with CoreDevice.")
        #endif
    }

    func testInspectOwnerTestFlightBuild() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Requires physical TestFlight installation.")
        #else
        guard ProcessInfo.processInfo.environment["BW_RELEASE_STORE_INSTALL"] == "1" else {
            throw XCTSkip("Opt in with TEST_RUNNER_BW_RELEASE_STORE_INSTALL=1.")
        }
        let flight = XCUIApplication(bundleIdentifier: "com.apple.TestFlight")
        flight.launch()
        XCTAssertTrue(flight.wait(for: .runningForeground, timeout: 20))
        // This observed Welcome screen contains a non-binding data-use notice.
        // Any later agreement or authentication page is inspected, never accepted.
        if flight.staticTexts["Welcome to TestFlight"].exists, flight.buttons["Continue"].exists {
            flight.buttons["Continue"].tap()
        }
        let hierarchy = XCTAttachment(string: flight.debugDescription)
        hierarchy.name = "owner-testflight-setup-local-only"
        hierarchy.lifetime = .keepAlways
        add(hierarchy)
        print("BW-RELEASE TestFlight installed and launched; inspection only, no agreement acceptance or beta installation.")
        #endif
    }

    func testInstallOfficialTestFlight() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("TestFlight installation requires a physical device.")
        #else
        guard ProcessInfo.processInfo.environment["BW_RELEASE_STORE_INSTALL"] == "1" else {
            throw XCTSkip("Opt in with TEST_RUNNER_BW_RELEASE_STORE_INSTALL=1.")
        }
        continueAfterFailure = false
        let store = XCUIApplication(bundleIdentifier: "com.apple.AppStore")
        store.launch()
        store.open(URL(string: "https://apps.apple.com/us/app/testflight/id899247664")!)
        XCTAssertTrue(store.staticTexts["TestFlight"].firstMatch.waitForExistence(timeout: 25),
                      "The official Apple TestFlight product page must be visible.")
        let open = store.buttons.matching(NSPredicate(format: "label == 'Open' OR label == 'OPEN'")).firstMatch
        if open.exists { return }
        let get = store.buttons.matching(NSPredicate(format: "label == 'Get' OR label == 'GET' OR label == 'Redownload'")).firstMatch
        XCTAssertTrue(get.waitForExistence(timeout: 10), "No free Get/Redownload control on the official product page.")
        get.tap()
        XCTAssertTrue(open.waitForExistence(timeout: 45),
                      "TestFlight has not installed. Complete any on-device App Store authentication yourself; this test never handles credentials, biometrics or legal agreements.")
        #endif
    }
}
