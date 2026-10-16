import XCTest

/// Explicit release-only setup. Never enters Apple credentials or accepts legal terms.
final class ReleaseStoreInstallUITests: XCTestCase {
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
