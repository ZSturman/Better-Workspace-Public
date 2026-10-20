import XCTest

/// Native experience checks. Live-device checks require explicit opt-in and discard
/// project editor drafts; sample checks use memory-only content.
final class PersonalExperienceUITests: XCTestCase {
    /// Opens the live project's controls without saving an edit or requesting files.
    func testInstalledWorkspaceZenAndSelectableProperties() throws {
        #if os(iOS) && !targetEnvironment(simulator)
        try XCTSkipUnless(ProcessInfo.processInfo.environment["BW_RUN_CONNECTED_ACCEPTANCE"] == "1", "Explicit installed-phone connected acceptance only")
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication(bundleIdentifier: "com.zacharysturman.BetterWorkspace.Mobile")
        app.launchArguments = []
        app.launch(); app.activate()
        defer {
            XCUIDevice.shared.orientation = .portrait
            app.terminate(); app.launchArguments = []; app.launch()
        }
        XCTAssertTrue(app.tabBars.buttons["Projects"].waitForExistence(timeout: 20))
        app.tabBars.buttons["Projects"].tap()
        XCTAssertTrue(app.buttons["projects.filterSort"].waitForExistence(timeout: 10))
        let search = app.searchFields.firstMatch
        for _ in 0..<3 {
            if search.waitForExistence(timeout: 1) { break }
            app.collectionViews.firstMatch.swipeDown()
        }
        XCTAssertTrue(search.waitForExistence(timeout: 10)); search.tap(); search.typeText("Better Workspace")
        let project = app.buttons["mobile-project-Projects/Better Workspace"]
        XCTAssertTrue(project.waitForExistence(timeout: 20)); project.tap()
        app.buttons["project.zen.open"].tap()
        XCTAssertTrue(app.staticTexts["zen.question"].waitForExistence(timeout: 10))
        app.buttons["zen.rating.5"].tap() // Unsaved draft only; Cancel below.
        XCUIDevice.shared.orientation = .landscapeLeft
        let next = app.buttons["zen.next"]
        XCTAssertTrue(next.waitForExistence(timeout: 10)); XCTAssertTrue(next.isHittable)
        XCTAssertLessThanOrEqual(next.frame.maxY, app.frame.maxY)
        let landscape = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        landscape.name = "installed-phone-zen-landscape"; landscape.lifetime = .keepAlways; add(landscape)
        XCUIDevice.shared.orientation = .portrait
        app.buttons["scoring.zen.toggle"].tap()
        let domain = app.buttons["project.property.domain"]
        XCTAssertTrue(domain.waitForExistence(timeout: 10)); domain.tap()
        app.buttons["Add new domain…"].tap()
        XCTAssertTrue(app.alerts.textFields.firstMatch.waitForExistence(timeout: 5))
        app.alerts.buttons["Cancel"].tap()
        let oneLiner = app.textFields["project.score.oneLiner"].exists
            ? app.textFields["project.score.oneLiner"] : app.textViews["project.score.oneLiner"]
        oneLiner.tap()
        let done = app.buttons["project.score.keyboardDone"]
        XCTAssertTrue(done.waitForExistence(timeout: 5)); XCTAssertTrue(done.isHittable); done.tap()
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.buttons["project.zen.open"].waitForExistence(timeout: 10))
        #else
        throw XCTSkip("Installed physical iPhone acceptance only")
        #endif
    }

    /// Read-only acceptance against the installed phone app. The runner is installed
    /// separately; never replace TestFlight just to verify the connected index.
    func testInstalledConnectedWorkspaceRefreshAndOfflineCache() throws {
        #if os(iOS) && !targetEnvironment(simulator)
        try XCTSkipUnless(ProcessInfo.processInfo.environment["BW_RUN_CONNECTED_ACCEPTANCE"] == "1", "Explicit installed-phone connected acceptance only")
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication(bundleIdentifier: "com.zacharysturman.BetterWorkspace.Mobile")
        app.launchArguments = []
        app.launch(); app.activate()
        let connected = app.buttons["Mac Workspace"].firstMatch
        // Older installed builds have a workspace switch; current builds open it directly.
        if connected.waitForExistence(timeout: 3) { connected.tap() }
        XCTAssertTrue(app.tabBars.buttons["Overview"].waitForExistence(timeout: 20))
        app.tabBars.buttons["Overview"].tap()
        let refresh = app.buttons["Refresh workspace index"].firstMatch
        XCTAssertTrue(refresh.waitForExistence(timeout: 20)); refresh.tap()
        let synced = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value BEGINSWITH %@", "Synced"), object: refresh)
        XCTAssertEqual(XCTWaiter.wait(for: [synced], timeout: 90), .completed)
        app.tabBars.buttons["Projects"].tap()
        let search = app.searchFields.firstMatch
        for _ in 0..<3 {
            if search.waitForExistence(timeout: 1) { break }
            app.collectionViews.firstMatch.swipeDown()
        }
        XCTAssertTrue(search.waitForExistence(timeout: 10))
        search.tap(); search.typeText("Better Workspace")
        let project = app.buttons["mobile-project-Projects/Better Workspace"].firstMatch
        XCTAssertTrue(project.waitForExistence(timeout: 25), "The advanced Mac's actual project must be in the received index")
        let online = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        online.name = "installed-phone-connected-projects"; online.lifetime = .keepAlways; add(online)
        app.terminate()
        app.launchArguments = ["-mobileCloudDisabled", "YES"]
        app.launch()
        app.tabBars.buttons["Projects"].tap()
        for _ in 0..<3 {
            if search.waitForExistence(timeout: 1) { break }
            app.collectionViews.firstMatch.swipeDown()
        }
        XCTAssertTrue(search.waitForExistence(timeout: 10))
        search.tap(); search.typeText("Better Workspace")
        XCTAssertTrue(project.waitForExistence(timeout: 20), "The disk cache must survive a relaunch with transport disabled")
        let cached = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        cached.name = "installed-phone-cached-projects"; cached.lifetime = .keepAlways; add(cached)
        app.terminate()
        app.launchArguments = []
        app.launch()
        #else
        throw XCTSkip("Installed physical iPhone acceptance only")
        #endif
    }

    func testPersonalStoreScreenshots() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["BW_CAPTURE_PERSONAL_SCREENSHOTS"] == "1", "Explicit private-sample screenshot capture only")
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.zacharysturman.BetterWorkspace.Mobile")
        app.launchArguments = ["-BWPersonalPreviewIsolation", UUID().uuidString, "-BWPersonalPreviewContent", "sample", "-bwWindowWidth", "1280", "-bwWindowHeight", "800"]
        #if os(iOS)
        XCUIDevice.shared.orientation = .portrait
        #endif
        app.launch(); app.activate()
        defer { app.terminate() }
        XCTAssertTrue(app.textFields["personal.search"].waitForExistence(timeout: 20))
        #if os(macOS)
        XCTAssertEqual(app.windows.firstMatch.frame.width, 1280, accuracy: 1)
        XCTAssertEqual(app.windows.firstMatch.frame.height, 800, accuracy: 1)
        #endif
        let overview = XCTAttachment(screenshot: sampleScreenshot(app))
        overview.name = "store-personal-overview"; overview.lifetime = .keepAlways; add(overview)
        let project = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Garden journal")).firstMatch
        XCTAssertTrue(project.waitForExistence(timeout: 5)); press(project)
        XCTAssertTrue(app.textFields["personal.editor.title"].waitForExistence(timeout: 5))
        let editor = XCTAttachment(screenshot: sampleScreenshot(app))
        editor.name = "store-personal-project-editor"; editor.lifetime = .keepAlways; add(editor)
        press(app.buttons["personal.editor.cancel"])
    }

    func testIsolatedProductionCloudHandshake() throws {
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipUnless(environment["BW_RUN_NOTEBOOK_CROSS_DEVICE"] == "1", "Explicit disposable cross-device verification only")
        let session = try XCTUnwrap(environment["BW_NOTEBOOK_SESSION_ID"].flatMap(UUID.init(uuidString:)))
        let role = try XCTUnwrap(environment["BW_NOTEBOOK_ROLE"])
        #if os(iOS)
        XCUIDevice.shared.orientation = .portrait
        #endif
        let offlineWriter = environment["BW_NOTEBOOK_OFFLINE_WRITER"] == "1"
        continueAfterFailure = false
        #if os(iOS) && !targetEnvironment(simulator)
        // Only the iPad acceptance controller uses this after recording Wi-Fi on,
        // Airplane Mode off. VPN settings are never changed.
        defer { if offlineWriter { try? setAcceptanceNetworking(offline: false) } }
        if offlineWriter { try setAcceptanceNetworking(offline: true) }
        #else
        try XCTSkipIf(offlineWriter, "Physical iPad offline acceptance only")
        #endif
        let app = XCUIApplication(bundleIdentifier: "com.zacharysturman.BetterWorkspace.Mobile")
        app.launchArguments = ["-BWNotebookAcceptance", session.uuidString]
        app.launch(); app.activate()
        defer {
            let state = XCTAttachment(string: app.debugDescription)
            state.name = "isolated-cloud-final-state-" + role
            state.lifetime = .keepAlways; add(state)
            app.terminate()
        }
        #if os(macOS)
        // A previously closed development window can restore an empty window set.
        if !app.windows.firstMatch.waitForExistence(timeout: 3) {
            app.typeKey("n", modifierFlags: .command)
        }
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 20))
        // Installed builds may restore several windows from New Window acceptance.
        // One test session needs one isolated store coordinator and one control set.
        for _ in 0..<8 {
            if app.windows.count <= 1 { break }
            app.typeKey("w", modifierFlags: .command)
        }
        #endif
        func phase(_ value: String) {
            let predicate = NSPredicate(format: "identifier == %@ AND (label == %@ OR value == %@)", "release.cloud.phase", value, value)
            let expected = app.staticTexts.matching(predicate).firstMatch
            let syncError = app.staticTexts["release.cloud.error"]
            let completed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in expected.exists || (!offlineWriter && syncError.exists) }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [completed], timeout: 300), .completed, "Expected \(value); role \(role)")
            // The bounded verification screen can retain an expected offline
            // diagnostic. Require the actual data phases/export after reconnection.
            if !offlineWriter { XCTAssertFalse(syncError.exists, syncError.exists ? syncError.label : "") }
            XCTAssertTrue(expected.exists)
            print("BW_NOTEBOOK_PHASE:\(role):\(value)")
        }
        if role == "cleanup" {
            let cleanup = app.buttons["release.cloud.cleanup"].firstMatch
            XCTAssertTrue(cleanup.waitForExistence(timeout: 30)); XCTAssertTrue(cleanup.isEnabled)
            press(cleanup)
            phase("waiting-for-owned-fixtures")
            let exported = NSPredicate(format: "identifier == %@ AND (label == %@ OR value == %@)", "release.cloud.export", "Export confirmed", "Export confirmed")
            XCTAssertTrue(app.staticTexts.matching(exported).firstMatch.waitForExistence(timeout: 180))
        } else if role == "writer" {
            let create = app.buttons["release.cloud.create"].firstMatch
            XCTAssertTrue(create.waitForExistence(timeout: 30)); press(create)
            phase("phase-1")
            #if os(iOS) && !targetEnvironment(simulator)
            if offlineWriter {
                app.terminate(); app.launch(); app.activate()
                phase("phase-1")
                XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "identifier == %@ AND label == %@", "release.cloud.export", "Export confirmed")).firstMatch.exists)
                print("BW_NOTEBOOK_OFFLINE_LOCAL_PERSISTENCE_CONFIRMED")
                try setAcceptanceNetworking(offline: false)
                app.activate()
                print("BW_NOTEBOOK_NETWORK_RESTORED")
            }
            #endif
            // Keep the writer running while the separate physical device edits.
            phase("phase-2")
            #if os(macOS)
            // The controller opens this owned gate only after the third device
            // reports phase-2. Keep tombstones until every observer has seen edits.
            if let gate = environment["BW_NOTEBOOK_CLEANUP_GATE"] {
                let deadline = Date().addingTimeInterval(300)
                while !FileManager.default.fileExists(atPath: gate) && Date() < deadline {
                    Thread.sleep(forTimeInterval: 0.25)
                }
                XCTAssertTrue(FileManager.default.fileExists(atPath: gate), "Third-device acknowledgement did not arrive")
            }
            #endif
            if let delay = environment["BW_NOTEBOOK_OBSERVER_HOLD_SECONDS"].flatMap(Double.init) {
                Thread.sleep(forTimeInterval: max(0, min(delay, 180)))
            }
            press(app.buttons["release.cloud.cleanup"].firstMatch)
            phase("waiting-for-owned-fixtures")
            let exported = NSPredicate(format: "identifier == %@ AND (label == %@ OR value == %@)", "release.cloud.export", "Export confirmed", "Export confirmed")
            XCTAssertTrue(app.staticTexts.matching(exported).firstMatch.waitForExistence(timeout: 180), "Keep the writer alive until its tombstones are exported")
        } else if role == "observer" {
            phase("phase-1")
            phase("phase-2")
            phase("waiting-for-owned-fixtures")
        } else {
            XCTAssertEqual(role, "reader")
            phase("phase-1")
            press(app.buttons["release.cloud.update"].firstMatch)
            phase("phase-2")
            phase("waiting-for-owned-fixtures")
        }
        let count = NSPredicate(format: "identifier == %@ AND (label == %@ OR value == %@)", "release.cloud.count", "Owned records: 0", "Owned records: 0")
        XCTAssertTrue(app.staticTexts.matching(count).firstMatch.exists)
        let proof = XCTAttachment(screenshot: sampleScreenshot(app))
        proof.name = "production-cross-device-owned-fixtures-cleaned-" + role
        proof.lifetime = .keepAlways; add(proof)
    }

    func testRestoreAcceptanceNetworking() throws {
        #if os(iOS) && !targetEnvironment(simulator)
        try XCTSkipUnless(ProcessInfo.processInfo.environment["BW_RESTORE_ACCEPTANCE_NETWORK"] == "1", "Explicit recovery only")
        try setAcceptanceNetworking(offline: false)
        #else
        throw XCTSkip("Physical-device recovery only")
        #endif
    }

    #if os(iOS) && !targetEnvironment(simulator)
    private func setAcceptanceNetworking(offline: Bool) throws {
        let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        settings.launch()
        if settings.buttons["Wi-Fi"].firstMatch.exists { settings.buttons["Wi-Fi"].firstMatch.tap() }
        else if settings.staticTexts["Wi-Fi"].firstMatch.exists { settings.staticTexts["Wi-Fi"].firstMatch.tap() }
        func set(_ label: String, on: Bool) throws {
            let control = settings.switches[label].firstMatch
            guard control.waitForExistence(timeout: 10) else { throw NSError(domain: "AcceptanceNetworking", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing " + label + "; no other setting will be used"]) }
            let expected = on ? "1" : "0"
            if String(describing: control.value ?? "") != expected { control.tap() }
            func matched() -> Bool {
                let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in String(describing: control.value ?? "") == expected }, object: nil)
                return XCTWaiter.wait(for: [expectation], timeout: 3) == .completed
            }
            if !matched() {
                // iPad Settings can expose a full-row switch whose center is its
                // label. Tap only the trailing control of that same known switch.
                guard control.isHittable && control.isEnabled else { throw NSError(domain: "AcceptanceNetworking", code: 3, userInfo: [NSLocalizedDescriptionKey: label + " is unavailable"]) }
                control.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
            }
            guard matched() else { throw NSError(domain: "AcceptanceNetworking", code: 2, userInfo: [NSLocalizedDescriptionKey: "Could not verify " + label]) }
        }
        try set("Airplane Mode", on: offline)
        try set("Wi-Fi", on: !offline)
        print(offline ? "BW_ACCEPTANCE_NETWORK:airplane=1,wifi=0" : "BW_ACCEPTANCE_NETWORK:airplane=0,wifi=1")
    }
    #endif

    private func launchPersonal() -> XCUIApplication {
        continueAfterFailure = false
        #if os(iOS)
        XCUIDevice.shared.orientation = .portrait
        #endif
        let app = XCUIApplication(bundleIdentifier: "com.zacharysturman.BetterWorkspace.Mobile")
        app.launchArguments = ["-BWPersonalPreviewIsolation", UUID().uuidString, "-workspaceWelcomeCompleted", "YES", "-workspaceExperience", "personal", "-mobileCloudDisabled", "YES", "-bwWindowWidth", "820", "-bwWindowHeight", "520"]
        app.launch()
        app.activate()
        #if os(macOS)
        print("PERSONAL_ROOT_WINDOW_COUNT=\(app.windows.count)")
        #endif
        let initialState = XCTAttachment(string: app.debugDescription)
        initialState.name = "isolated-personal-root-initial-state"; initialState.lifetime = .keepAlways; add(initialState)
        XCTAssertTrue(app.textFields["personal.search"].waitForExistence(timeout: 20))
        return app
    }

    private func press(_ element: XCUIElement) {
        #if os(macOS)
        element.click()
        #else
        element.tap()
        #endif
    }

    private func visible(_ id: String, in app: XCUIApplication) -> XCUIElement {
        #if os(macOS)
        // Parent window controls can report hittable while its sheet is active.
        let sheetMatch = app.sheets.descendants(matching: .any).matching(identifier: id).firstMatch
        if sheetMatch.exists { return sheetMatch }
        #endif
        let matches = app.descendants(matching: .any).matching(identifier: id)
        if let element = matches.allElementsBoundByIndex.first(where: { $0.isHittable }) { return element }
        return matches.firstMatch
    }

    private func sampleScreenshot(_ app: XCUIApplication) -> XCUIScreenshot {
        #if os(macOS)
        // app.screenshot() includes the person's desktop on macOS.
        app.windows.firstMatch.screenshot()
        #else
        app.screenshot()
        #endif
    }

    private func openSample(_ app: XCUIApplication) {
        let directSample = app.buttons["personal.sample.open"].firstMatch
        if directSample.exists && directSample.isHittable {
            press(directSample)
            XCTAssertTrue(app.buttons["personal.sample.close"].waitForExistence(timeout: 10))
            return
        }
        let options = visible("personal.options", in: app)
        XCTAssertTrue(options.waitForExistence(timeout: 10)); press(options)
        #if os(macOS)
        let sample = app.menuItems["Try a private sample"].firstMatch
        #else
        let sample = visible("personal.sample.open", in: app)
        #endif
        XCTAssertTrue(sample.waitForExistence(timeout: 5)); press(sample)
        XCTAssertTrue(app.buttons["personal.sample.close"].waitForExistence(timeout: 10))
    }

    func testCreateEditAndDiscardSampleProject() {
        let app = launchPersonal()
        defer { app.terminate() }
        openSample(app)
        press(visible("personal.sample.new", in: app))
        #if os(macOS)
        XCTAssertTrue(app.menuItems["New Project"].waitForExistence(timeout: 5))
        press(app.menuItems["New Project"])
        #else
        press(visible("personal.new.project", in: app))
        #endif
        let title = app.textFields["personal.editor.title"]
        XCTAssertTrue(title.waitForExistence(timeout: 5)); press(title)
        let marker = "Release sample " + UUID().uuidString.prefix(8)
        title.typeText(marker)
        press(app.buttons["personal.editor.save"])
        let created = app.buttons.matching(NSPredicate(format: "label == %@", marker)).firstMatch
        reveal(created, in: app)
        XCTAssertTrue(created.waitForExistence(timeout: 5))
        let shot = XCTAttachment(screenshot: sampleScreenshot(app)); shot.name = "personal-project-created-in-private-sample"; shot.lifetime = .keepAlways; add(shot)
        press(app.buttons["personal.sample.close"])
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label == %@", marker)).firstMatch.exists,
                       "Sample records must never be copied to the person's database")
        openSample(app)
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label == %@", marker)).firstMatch.exists,
                       "Each sample starts from a new memory-only store")
    }

    func testPrivateSampleLayoutTaskCompletionAndEditorCancellation() {
        let app = launchPersonal()
        defer { app.terminate() }
        verifyTaskAndCancellation(app)
    }

    #if os(macOS)
    func testNewWindowAndRelaunchInIsolatedPersonalWorkspace() {
        let app = launchPersonal()
        defer { app.terminate() }
        let initialCount = app.windows.count
        app.typeKey("n", modifierFlags: .command)
        let added = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            app.windows.count == initialCount + 1
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [added], timeout: 15), .completed)
        XCTAssertTrue(app.textFields["personal.search"].firstMatch.exists)
        app.typeKey("w", modifierFlags: .command)
        let closed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            app.windows.count == initialCount
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [closed], timeout: 15), .completed)
        app.terminate()
        app.launch()
        app.activate()
        XCTAssertTrue(app.textFields["personal.search"].firstMatch.waitForExistence(timeout: 20))
        XCTAssertGreaterThan(app.windows.count, 0)
    }
    #endif

    #if os(iOS)
    func testLandscapeSampleTaskCompletionAndEditorCancellation() {
        let app = launchPersonal()
        defer { app.terminate(); XCUIDevice.shared.orientation = .portrait }
        XCUIDevice.shared.orientation = .landscapeLeft
        verifyTaskAndCancellation(app)
    }
    #endif

    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        #if os(iOS)
        // SwiftUI List creates only visible rows; landscape may need scrolling.
        for _ in 0..<5 {
            if element.exists && element.isHittable { return }
            (app.collectionViews.allElementsBoundByIndex.last ?? app).swipeUp()
        }
        #endif
    }

    private func verifyTaskAndCancellation(_ app: XCUIApplication) {
        openSample(app)
        XCTAssertTrue(visible("personal.sample.new", in: app).isHittable)
        let screenshot = XCTAttachment(screenshot: sampleScreenshot(app))
        screenshot.name = "personal-workspace-private-sample"; screenshot.lifetime = .keepAlways; add(screenshot)
        let complete = app.buttons["Complete task"].firstMatch
        XCTAssertTrue(complete.waitForExistence(timeout: 5)); press(complete)
        XCTAssertTrue(app.buttons["Reopen task"].firstMatch.waitForExistence(timeout: 5))
        press(visible("personal.sample.new", in: app))
        #if os(macOS)
        let new = app.menuItems["New Document"]
        #else
        let new = visible("personal.new.document", in: app)
        #endif
        XCTAssertTrue(new.waitForExistence(timeout: 5)); press(new)
        XCTAssertTrue(app.textFields["personal.editor.title"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["personal.editor.save"].isEnabled)
        press(app.buttons["personal.editor.cancel"])
        XCTAssertTrue(app.buttons["personal.sample.close"].waitForExistence(timeout: 5))
        press(app.buttons["personal.sample.close"])
        reveal(app.buttons["personal.firstProject"], in: app)
        XCTAssertTrue(app.buttons["personal.firstProject"].waitForExistence(timeout: 5))
    }
}
