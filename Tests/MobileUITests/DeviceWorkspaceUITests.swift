import XCTest

/// Runs Better Workspace Mobile against a real iPhone and the real CloudKit container.
///
/// The Simulator cannot stand in for this: it has no iCloud account, so every read is
/// the unavailable path and nothing the Mac publishes is ever seen. These tests need a
/// Mac to have published a projection first — they assert on whatever is actually
/// there rather than on fixture names, so they stay meaningful whatever the workspace
/// holds, and skip with a clear reason when the container is empty.
///
/// Every step is screenshotted so a run can be reviewed by eye.
final class DeviceWorkspaceUITests: XCTestCase {

    private var step = 0

    private func shoot(_ name: String) {
        step += 1
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = String(format: "%02d-%@", step, name)
        attachment.lifetime = .keepAlways
        add(attachment)
        print("DEVICE SHOT -> \(attachment.name ?? name)")
    }

    private func launchOnline(resetTips: Bool = false) throws -> XCUIApplication {
        #if targetEnvironment(simulator)
        throw XCTSkip("Physical-device test: the Simulator has no iCloud account, so the "
                      + "Mac-published index is never reachable there.")
        #else
        continueAfterFailure = false
        if UIDevice.current.userInterfaceIdiom == .phone { XCUIDevice.shared.orientation = .portrait }
        let app = XCUIApplication()
        if resetTips { app.launchArguments = ["-BWResetTipsForTesting", "YES"] }
        app.launch()
        return app
        #endif
    }

    private func waitForOverviewSurface(_ app: XCUIApplication) {
        if UIDevice.current.userInterfaceIdiom == .pad {
            XCTAssertTrue(app.staticTexts["workspace-sidebar-overview"]
                .waitForExistence(timeout: 30), "No iPad Overview sidebar destination")
        } else {
            XCTAssertTrue(app.buttons["Overview"].waitForExistence(timeout: 30), "No Overview tab")
        }
    }

    /// Browse is intentionally no longer a primary destination.  This preserves a
    /// direct physical-device check of the published index while exercising the new
    /// Overview menu that makes Overview the phone's home.
    private func openWorkspaceBrowser(_ app: XCUIApplication) {
        if UIDevice.current.userInterfaceIdiom == .pad {
            app.staticTexts["workspace-sidebar-overview"].tap()
        } else { app.buttons["Overview"].tap() }
        app.buttons["More workspace views"].tap()
        let browse = app.buttons["Browse folders"]
        XCTAssertTrue(browse.waitForExistence(timeout: 15), "Overview did not offer the workspace browser")
        browse.tap()
        XCTAssertTrue(app.navigationBars["Workspace"].waitForExistence(timeout: 15))
    }

    /// Waits for the index to stop loading, whichever way it resolves.
    private func waitForSync(_ app: XCUIApplication, timeout: TimeInterval = 60) {
        let loading = app.staticTexts["Loading…"].firstMatch
        if loading.exists {
            let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"),
                                                 object: loading)
            _ = XCTWaiter.wait(for: [gone], timeout: timeout)
        }
    }

    /// The Mac publishes an index; the phone shows it. This is the whole contract of
    /// the secondary workspace browser, so it is checked against the live container rather than a mock.
    func testTheMacPublishedIndexIsReadableOnTheDevice() throws {
        let app = try launchOnline(resetTips: true)
        waitForOverviewSurface(app)
        // A populated local cache has no loading state, so merely waiting for the
        // spinner proves only that the cached screen rendered. Force one live request
        // before calling this a CloudKit readback test.
        let refresh = app.buttons["Refresh workspace index"]
        XCTAssertTrue(refresh.waitForExistence(timeout: 15))
        refresh.tap()
        // Healthy sync is intentionally quiet. The refresh control exposes live
        // readback to accessibility without putting transport details in the page.
        let live = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value BEGINSWITH %@", "Synced"), object: refresh)
        XCTAssertEqual(XCTWaiter.wait(for: [live], timeout: 60), .completed)
        shoot("overview")

        openWorkspaceBrowser(app)

        // Area roots are published with no parent, so they are what the root lists.
        let ideas = app.buttons["workspace-entry-Ideas"]
        for _ in 0..<4 where !ideas.exists { app.swipeUp() }
        XCTAssertTrue(ideas.waitForExistence(timeout: 10), "A successful live index must include the published Ideas root")
        ideas.tap()
        XCTAssertTrue(app.navigationBars["Ideas"].waitForExistence(timeout: 20),
                      "Tapping an area root must drill into it")
        shoot("ideas-children")

        // An empty Ideas folder is a valid published state. The contract here is that
        // its root arrives and drills in; when children exist the next check prints
        // them for the paired Mac-side deletion check below.

        // Printed so a deletion on the Mac can be checked against what the phone still
        // shows: a record the Mac removed must not survive in the phone's cache.
        let listed = app.buttons.matching(NSPredicate(format: "label CONTAINS '.md'"))
            .allElementsBoundByIndex.map(\.label).sorted()
        print("DEVICE IDEAS CHILDREN -> \(listed)")
    }

    /// Applying a tag has to be visible immediately. The Mac is still the authority —
    /// the change is queued as an intent — but a phone that shows nothing at all makes
    /// the user tap again, which is how duplicate intents get created.
    func testApplyingATagShowsImmediatelyAndQueuesAnIntent() throws {
        let app = try launchOnline()
        waitForOverviewSurface(app)
        waitForSync(app)

        if app.staticTexts["Sync unavailable · capture still works"].exists {
            throw XCTSkip("CloudKit is unavailable on this device right now.")
        }
        openWorkspaceBrowser(app)
        let ideas = app.buttons["workspace-entry-Ideas"]
        guard ideas.waitForExistence(timeout: 30) else {
            throw XCTSkip("No projection has been published to this container yet.")
        }
        ideas.tap()

        // A file row, not one of the notice rows above the list. Matching on the row's
        // own label keeps this from tapping the sync banner, which is not a link and
        // leaves the test on the list wondering where the tag controls went.
        // The row is a Button inside an unlabelled Cell, so the cell carries no label to
        // match on — query the button.
        // CONTAINS rather than ENDSWITH: a row that carries tags appends their names to
        // its label, so ENDSWITH silently skipped every tagged entry.
        let fileRows = app.buttons.matching(NSPredicate(format: "label CONTAINS '.md'"))
        guard fileRows.count > 0, fileRows.element(boundBy: 0).waitForExistence(timeout: 20) else {
            throw XCTSkip("No file entries under Ideas to tag.")
        }
        fileRows.element(boundBy: 0).tap()
        XCTAssertTrue(app.staticTexts["Tags"].waitForExistence(timeout: 20),
                      "Tapping an entry did not open its detail view")
        shoot("entry-detail")

        app.buttons["Edit tags"].tap()
        let toggles = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Toggle tag '"))
        guard toggles.count > 0 else {
            throw XCTSkip("No tag catalog has been published, so there is nothing to apply.")
        }
        let toggle = toggles.element(boundBy: 0)
        let label = toggle.label
        let startedSelected = (toggle.value as? String) == "Selected"
        // Leave the real idea as it was found, even if an assertion below fails.
        addTeardownBlock {
            if toggle.exists, ((toggle.value as? String) == "Selected") != startedSelected { toggle.tap() }
        }
        toggle.tap()
        shoot("tag-applied")

        // The checkmark is the only feedback the screen gives. It comes from the model's
        // copy of the entry, so this fails if the detail view is reading a stale value
        // captured when the row was pushed.
        let checked = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "Selected"), object: toggle)
        XCTAssertEqual(XCTWaiter.wait(for: [checked], timeout: 10), .completed,
                      "Applying “\(label)” left the row unchecked, so nothing on screen "
                      + "confirms the tap landed")

        // Untoggle so the device is left as it was found (the teardown then has nothing to do).
        toggle.tap()
        shoot("tag-removed")
    }

    /// Applies a tag and deliberately leaves it on, so the Mac side of the flow has
    /// something to consume. Run by name as part of a paired Mac check; the resulting
    /// assignment lives only in whichever database the Mac under test is using.
    func testApplyATagAndLeaveItForTheMac() throws {
        // It leaves a real tag on a real idea for the Mac half of a paired check, so it
        // never runs as part of a whole suite.
        guard ProcessInfo.processInfo.environment["BW_PAIRED_TAG_CHECK"] == "1" else {
            throw XCTSkip("Paired Mac check: set TEST_RUNNER_BW_PAIRED_TAG_CHECK=1 to run it.")
        }
        let app = try launchOnline()
        waitForOverviewSurface(app)
        waitForSync(app)
        openWorkspaceBrowser(app)
        app.buttons["workspace-entry-Ideas"].tap()
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS '.md'")).element(boundBy: 0)
        XCTAssertTrue(row.waitForExistence(timeout: 20))
        row.tap()
        app.buttons["Edit tags"].tap()
        let toggle = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Toggle tag '")).element(boundBy: 0)
        XCTAssertTrue(toggle.waitForExistence(timeout: 20))
        toggle.tap()
        let selected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "Selected"), object: toggle)
        XCTAssertEqual(XCTWaiter.wait(for: [selected], timeout: 10), .completed)
        shoot("tag-left-on-for-mac")
        // Give the outbox a moment to reach CloudKit before the run ends.
        _ = app.staticTexts["queued"].waitForExistence(timeout: 5)
    }

    /// A relaunch must not lose what the phone already received. The cache is the only
    /// reason Overview and Ideas are usable before the first request comes back.
    func testTheIndexSurvivesARelaunchFromCache() throws {
        let app = try launchOnline()
        waitForOverviewSurface(app)
        waitForSync(app)
        openWorkspaceBrowser(app)
        guard app.buttons["workspace-entry-Ideas"].waitForExistence(timeout: 30) else {
            throw XCTSkip("No projection has been published to this container yet.")
        }

        app.terminate()
        _ = app.wait(for: .notRunning, timeout: 20)
        // Disable transport on this relaunch. Otherwise a fast online refresh could
        // repopulate the screen before the assertion and hide a broken disk cache.
        app.launchArguments = ["-mobileCloudDisabled", "YES"]
        app.launch()
        waitForOverviewSurface(app)
        shoot("overview-relaunched-with-cloud-disabled")

        // Straight after launch, before any request could have completed, the cached
        // index has to already be on screen.
        openWorkspaceBrowser(app)
        XCTAssertTrue(app.buttons["workspace-entry-Ideas"].waitForExistence(timeout: 10),
                      "The cached index was not shown after relaunch")
        XCTAssertFalse(app.staticTexts["No published items"].exists,
                       "A relaunch fell back to an empty workspace instead of the cache")
    }

    /// Read-only navigation and real device rotation against the published cache.
    func testIPhoneProjectWorkAndIdeasNavigationAcrossRotation() throws {
        guard UIDevice.current.userInterfaceIdiom == .phone else { throw XCTSkip("Requires an iPhone.") }
        let app = try launchOnline()
        let previous = XCUIDevice.shared.orientation
        defer { XCUIDevice.shared.orientation = previous == .unknown ? .portrait : previous }
        XCUIDevice.shared.orientation = .portrait
        waitForOverviewSurface(app)
        app.buttons["Projects"].tap()
        XCTAssertTrue(app.navigationBars["Projects"].waitForExistence(timeout: 15))
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "mobile-project-")).firstMatch
        guard row.waitForExistence(timeout: 30) else { throw XCTSkip("No project has been published to the device.") }
        row.tap()
        XCTAssertTrue(app.staticTexts["Up Next"].waitForExistence(timeout: 15))
        shoot("iphone-project-detail")
        app.buttons["Work"].tap()
        XCTAssertTrue(app.navigationBars["Work"].waitForExistence(timeout: 15))
        shoot("iphone-work-portrait")
        XCUIDevice.shared.orientation = .landscapeRight
        XCTAssertTrue(app.navigationBars["Work"].waitForExistence(timeout: 15))
        shoot("iphone-work-landscape")
        app.buttons["Ideas"].tap()
        XCTAssertTrue(app.navigationBars["Ideas"].waitForExistence(timeout: 15))
        XCUIDevice.shared.orientation = .portrait
        app.buttons["Overview"].tap()
        XCTAssertTrue(app.navigationBars["Overview"].waitForExistence(timeout: 15))
    }

    /// Capture writes to a unique app-private test inbox, never the real shared Inbox.
    func testIPhoneIsolatedTextCaptureKeyboardAndLandscape() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Physical iPhone capture test.")
        #else
        guard UIDevice.current.userInterfaceIdiom == .phone else { throw XCTSkip("Requires an iPhone.") }
        let previous = XCUIDevice.shared.orientation
        defer { XCUIDevice.shared.orientation = previous == .unknown ? .portrait : previous }
        continueAfterFailure = false
        let marker = "BW device capture QA " + UUID().uuidString.prefix(8)
        let app = XCUIApplication()
        app.launchArguments = ["-BWTestCaptureInboxID", "phone-qa-" + UUID().uuidString]
        app.launch()
        waitForOverviewSurface(app)
        app.buttons["Ingest"].tap()
        XCTAssertTrue(app.staticTexts["Test Inbox"].waitForExistence(timeout: 20), "Must use an isolated inbox before saving")
        let save = app.buttons["Save"].firstMatch
        XCTAssertFalse(save.isEnabled)
        let text = app.textViews["capture-text"]
        XCTAssertTrue(text.waitForExistence(timeout: 10)); text.tap(); text.typeText(marker)
        XCTAssertTrue(save.isEnabled)
        let done = app.buttons["Done"].firstMatch
        XCTAssertTrue(done.waitForExistence(timeout: 10)); done.tap()
        XCTAssertFalse(app.keyboards.firstMatch.exists)
        shoot("iphone-capture-portrait")
        XCUIDevice.shared.orientation = .landscapeRight
        XCTAssertTrue(text.waitForExistence(timeout: 10))
        XCTAssertTrue(save.isEnabled, "Rotating must preserve the unsaved note")
        XCTAssertTrue((text.value as? String)?.contains(marker) == true)
        shoot("iphone-capture-landscape")
        XCUIDevice.shared.orientation = .portrait
        if !save.isHittable { app.swipeUp() }
        XCTAssertTrue(save.isHittable); save.tap()
        XCTAssertTrue(app.staticTexts["Added to Inbox"].waitForExistence(timeout: 15))
        shoot("iphone-capture-saved-test-inbox")
        app.terminate()
        #endif
    }

    /// The regular-width iPad layout must retain one stable sidebar selection and swap
    /// the detail content in place. This is intentionally a device test: an iPhone's
    /// tab bar cannot expose split-view selection or a blank detail regression.
    func testIPadSidebarSelectionChangesDetail() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Physical iPad test.")
        #else
        guard UIDevice.current.userInterfaceIdiom == .pad else {
            throw XCTSkip("Requires an iPad.")
        }
        let app = try launchOnline()
        waitForOverviewSurface(app)
        XCTAssertTrue(app.navigationBars["Overview"].waitForExistence(timeout: 30))
        shoot("ipad-split-overview")

        let selections = [("workspace-sidebar-projects", "Projects"),
                          ("workspace-sidebar-work", "Work"),
                          ("workspace-sidebar-ideas", "Ideas"),
                          ("workspace-sidebar-overview", "Overview")]
        for (sidebarID, title) in selections {
            let row = app.staticTexts[sidebarID]
            XCTAssertTrue(row.waitForExistence(timeout: 15), "Missing sidebar row \(sidebarID)")
            row.tap()
            XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 15),
                          "Sidebar selection \(sidebarID) did not show \(title)")
            shoot("ipad-split-\(title.lowercased())")
        }
        #endif
    }

    /// Portrait keeps the iPad in the regular-width split layout; this guards the
    /// orientation transition separately from the landscape sidebar walkthrough.
    func testIPadPortraitOverviewSurface() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Physical iPad test.")
        #else
        guard UIDevice.current.userInterfaceIdiom == .pad else {
            throw XCTSkip("Requires an iPad.")
        }
        XCUIDevice.shared.orientation = .portrait
        defer { XCUIDevice.shared.orientation = .landscapeRight }
        let app = try launchOnline()
        waitForOverviewSurface(app)
        XCTAssertTrue(app.navigationBars["Overview"].waitForExistence(timeout: 30))
        shoot("ipad-portrait-overview")
        let refresh = app.buttons["Refresh workspace index"]
        XCTAssertTrue(refresh.waitForExistence(timeout: 15))
        XCTAssertTrue(refresh.isHittable, "Portrait Overview must retain its refresh action")
        #endif
    }
}
