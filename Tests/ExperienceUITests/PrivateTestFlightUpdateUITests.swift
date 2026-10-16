import XCTest

/// Opt-in management of this project's already-installed official TestFlight app.
/// Never installs the sibling development host or updates another beta application.
final class PrivateTestFlightUpdateUITests: XCTestCase {
    func testInspectBetterWorkspaceTestFlightDetail() throws {
        #if os(iOS) && !targetEnvironment(simulator)
        try XCTSkipUnless(ProcessInfo.processInfo.environment["BW_INSPECT_PRIVATE_TESTFLIGHT"] == "1", "Explicit private release update only")
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let testFlight = XCUIApplication(bundleIdentifier: "com.apple.TestFlight")
        testFlight.launch()
        let title = testFlight.staticTexts["Better Workspace"].firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 30), "Unlock device and open the existing Better Workspace invitation in TestFlight")
        title.tap()
        XCTAssertTrue(testFlight.staticTexts["TestFlight.appDetails.shortVersion"].waitForExistence(timeout: 30))
        let state = XCTAttachment(string: testFlight.debugDescription)
        state.name = "better-workspace-testflight-detail-local-only"
        state.lifetime = .keepAlways
        add(state)
        #else
        throw XCTSkip("Physical TestFlight update only")
        #endif
    }

    func testInstallApprovedBuild8() throws {
        #if os(iOS) && !targetEnvironment(simulator)
        try XCTSkipUnless(ProcessInfo.processInfo.environment["BW_INSTALL_PRIVATE_TESTFLIGHT"] == "8", "Explicit owner-approved build-8 update only")
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let testFlight = XCUIApplication(bundleIdentifier: "com.apple.TestFlight")
        testFlight.launch()
        let detailTitle = testFlight.staticTexts["TestFlight.appDetails.title"]
        if !detailTitle.exists || detailTitle.label != "Better Workspace" {
            let titles = testFlight.staticTexts.matching(identifier: "Better Workspace")
            XCTAssertTrue(titles.firstMatch.waitForExistence(timeout: 30))
            let title = try XCTUnwrap(titles.allElementsBoundByIndex.first(where: { $0.isHittable }))
            title.tap()
        }
        XCTAssertTrue(detailTitle.waitForExistence(timeout: 30))
        XCTAssertEqual(detailTitle.label, "Better Workspace")
        let version = testFlight.staticTexts["TestFlight.appDetails.shortVersion"]
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            version.exists && version.label.filter { !$0.isWhitespace }.hasSuffix("Build8")
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 45), .completed,
                       "Refuse to install another build or modify another app")
        let updates = testFlight.buttons.matching(NSPredicate(format: "label ==[c] %@ OR label ==[c] %@", "Update", "Install"))
        var update = updates.allElementsBoundByIndex.first(where: { $0.isHittable && $0.isEnabled })
        for _ in 0..<3 {
            if update != nil || testFlight.buttons["TestFlight.offerButton.open"].exists { break }
            testFlight.swipeDown()
            update = updates.allElementsBoundByIndex.first(where: { $0.isHittable && $0.isEnabled })
        }
        if let update { update.tap() }
        else { XCTAssertTrue(testFlight.buttons["TestFlight.offerButton.open"].exists, "No visible update action; do not synthesize a tap at an invalid point") }
        // Do not accept terms, permission changes, data-loss warnings or other
        // dialogs. Any such interruption requires the owner's intervention.
        XCTAssertTrue(testFlight.buttons["TestFlight.offerButton.open"].waitForExistence(timeout: 180),
                      "Inspect any system prompt before continuing; never uninstall the app")
        let proof = XCTAttachment(string: "Better Workspace TestFlight: " + version.label + "; Open available. Confirm installed bundleVersion independently with CoreDevice.")
        proof.name = "testflight-build8-update-state"; proof.lifetime = .keepAlways; add(proof)
        #else
        throw XCTSkip("Physical TestFlight update only")
        #endif
    }
}
