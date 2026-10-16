import XCTest

/// Captures the system's actual widget choices, never writes an app-group fixture
/// over a person's widget cache. Gallery diagnostics alone are not acceptance.
final class InstalledWidgetDiagnostics: XCTestCase {
    func testInspectAddedQuickCapture() throws {
        #if os(iOS) && !targetEnvironment(simulator)
        try XCTSkipUnless(ProcessInfo.processInfo.environment["BW_INSPECT_ADDED_WIDGET"] == "1", "Explicit installed widget inspection")
        continueAfterFailure = false
        let tapWidget = ProcessInfo.processInfo.environment["BW_TAP_ADDED_WIDGET"] == "1"
        let app = XCUIApplication(bundleIdentifier: "com.zacharysturman.BetterWorkspace.Mobile")
        if tapWidget {
            app.launchArguments = []
            app.launch()
            let picker = app.segmentedControls["workspace.experience"]
            XCTAssertTrue(picker.waitForExistence(timeout: 20))
            picker.buttons["My Workspace"].tap()
            XCTAssertTrue(app.textFields["personal.search"].waitForExistence(timeout: 20))
            app.terminate()
        }
        XCUIDevice.shared.press(.home)
        XCUIDevice.shared.press(.home)
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        var matches: [XCUIElement] = []
        for _ in 0..<8 {
            matches = springboard.descendants(matching: .any)
                .matching(NSPredicate(format: "label BEGINSWITH %@", "Capture"))
                .allElementsBoundByIndex.filter { $0.isHittable && $0.frame.width >= 100 && $0.frame.height >= 100 }
            if matches.isEmpty {
                matches = springboard.otherElements.containing(.staticText, identifier: "Capture").allElementsBoundByIndex
                    .filter { $0.isHittable && $0.frame.width >= 100 && $0.frame.width <= 450 && $0.frame.height >= 100 && $0.frame.height <= 500 }
            }
            if !matches.isEmpty { break }
            springboard.swipeLeft()
        }
        guard let widget = matches.min(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }) else {
            let labels = springboard.descendants(matching: .any)
                .matching(NSPredicate(format: "label CONTAINS %@ OR identifier CONTAINS %@", "Capture", "BetterWorkspace"))
                .allElementsBoundByIndex.map { "\($0.elementType): \($0.identifier): \($0.label)" }
            let attachment = XCTAttachment(string: labels.joined(separator: "\n"))
            attachment.name = "widget-only-accessibility-labels"; attachment.lifetime = .keepAlways; add(attachment)
            throw XCTSkip("System did not expose the installed Capture widget as a bounded element; user-supplied screenshots remain rendering evidence")
        }
        let screenshot = XCTAttachment(screenshot: widget.screenshot())
        screenshot.name = "installed-quick-capture-widget-only"; screenshot.lifetime = .keepAlways; add(screenshot)
        if tapWidget {
            defer { app.terminate() }
            widget.tap()
            XCTAssertTrue(app.navigationBars["Ingest"].waitForExistence(timeout: 20))
            XCTAssertTrue(app.segmentedControls["workspace.experience"].buttons["Mac Workspace"].isSelected)
        }
        #else
        throw XCTSkip("Physical Home Screen widget inspection")
        #endif
    }

    func testColdCaptureLinkFromPersonalWorkspace() throws {
        try verifyColdRoute("capture", title: "Ingest")
    }

    func testColdWorkLinkFromPersonalWorkspace() throws {
        try verifyColdRoute("work", title: "Work")
    }

    private func verifyColdRoute(_ route: String, title: String) throws {
        #if os(iOS)
        try XCTSkipUnless(ProcessInfo.processInfo.environment["BW_RUN_WIDGET_ROUTE_ACCEPTANCE"] == "1",
                          "Explicit navigation-only widget acceptance; never saves records")
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "com.zacharysturman.BetterWorkspace.Mobile")
        app.launchArguments = []
        #if targetEnvironment(simulator)
        app.launchArguments = ["-workspaceWelcomeCompleted", "YES"]
        let sandbox = FileManager.default.temporaryDirectory.appendingPathComponent("bw-widget-route-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        app.launchEnvironment["BW_TEST_DATABASE_PATH"] = sandbox.appendingPathComponent("metadata.sqlite").path
        defer { try? FileManager.default.removeItem(at: sandbox) }
        #endif
        app.launch()
        defer { app.terminate() }
        let picker = app.segmentedControls["workspace.experience"]
        XCTAssertTrue(picker.waitForExistence(timeout: 20))
        picker.buttons["My Workspace"].tap()
        XCTAssertTrue(app.textFields["personal.search"].waitForExistence(timeout: 20))
        app.terminate()
        // Deliver the actual widget URL during cold launch, not a post-launch
        // argument callback that can hide lifecycle ordering defects.
        app.open(URL(string: "betterworkspace-mobile://" + route)!)
        XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 20), "Cold widget route must reveal its connected destination")
        XCTAssertTrue(app.segmentedControls["workspace.experience"].buttons["Mac Workspace"].isSelected)
        #else
        throw XCTSkip("Mobile widget destination regression")
        #endif
    }

    func testInspectOfflineControls() throws {
        #if os(iOS) && !targetEnvironment(simulator)
        try XCTSkipUnless(ProcessInfo.processInfo.environment["BW_INSPECT_OFFLINE_CONTROLS"] == "1", "Explicit settings inspection")
        let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        settings.launch()
        let controls = settings.switches.allElementsBoundByIndex.map { ["label": $0.label, "value": String(describing: $0.value ?? "")] }
        let evidence = XCTAttachment(string: String(describing: controls))
        evidence.name = "offline-switches-no-account-data"; evidence.lifetime = .keepAlways; add(evidence)
        let wifi = settings.buttons["Wi-Fi"].firstMatch
        if wifi.exists { wifi.tap() }
        else if settings.staticTexts["Wi-Fi"].firstMatch.exists { settings.staticTexts["Wi-Fi"].firstMatch.tap() }
        let detail = settings.switches.allElementsBoundByIndex.map { ["label": $0.label, "value": String(describing: $0.value ?? "")] }
        let wifiEvidence = XCTAttachment(string: String(describing: detail))
        wifiEvidence.name = "wifi-switches-no-network-names"; wifiEvidence.lifetime = .keepAlways; add(wifiEvidence)
        XCUIDevice.shared.press(.home)
        #else
        throw XCTSkip("Physical device settings inspection")
        #endif
    }

    func testInspectInstalledApplicationWidgetChoices() throws {
        #if os(iOS) && !targetEnvironment(simulator)
        try XCTSkipUnless(ProcessInfo.processInfo.environment["BW_INSPECT_INSTALLED_WIDGETS"] == "1",
                          "Explicit physical-device widget inspection only")
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        XCUIDevice.shared.press(.home)
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        defer { XCUIDevice.shared.press(.home) }
        let icon = springboard.icons["Better Workspace"].firstMatch
        // Find the app on an ordinary Home Screen, without Spotlight queries that
        // could surface personal mail or documents.
        for _ in 0..<8 {
            if icon.exists && icon.isHittable { break }
            springboard.swipeLeft()
        }
        guard icon.exists && icon.isHittable else {
            throw XCTSkip("App icon is not on an accessible Home Screen; inspect its widget gallery manually")
        }
        icon.press(forDuration: 1.2)
        if springboard.buttons["Options"].firstMatch.exists {
            springboard.buttons["Options"].firstMatch.tap()
        }
        if springboard.buttons["Edit Home Screen"].firstMatch.exists {
            springboard.buttons["Edit Home Screen"].firstMatch.tap()
            if springboard.buttons["Edit"].firstMatch.exists { springboard.buttons["Edit"].firstMatch.tap() }
            if springboard.buttons["Add Widget"].firstMatch.exists { springboard.buttons["Add Widget"].firstMatch.tap() }
        }
        if springboard.searchFields.firstMatch.exists {
            let search = springboard.searchFields.firstMatch
            search.tap(); search.typeText("Better Workspace")
            let result = springboard.buttons["Better Workspace"].firstMatch
            if result.waitForExistence(timeout: 8) { result.tap() }
            else if springboard.staticTexts["Better Workspace"].firstMatch.exists { springboard.staticTexts["Better Workspace"].firstMatch.tap() }
        }
        // Keep the context/menu subtree only; the full Home Screen can contain
        // unrelated personal widgets. Never export that hierarchy into repository docs.
        let panel = springboard.collectionViews["add-sheet-collection-view"].firstMatch
        guard panel.waitForExistence(timeout: 10) else {
            throw XCTSkip("System widget gallery was not exposed; do not capture the person's Home Screen")
        }
        let state = XCTAttachment(string: panel.debugDescription)
        state.name = "installed-widget-choices-local-only"; state.lifetime = .keepAlways; add(state)
        let screenshot = XCTAttachment(screenshot: panel.screenshot())
        screenshot.name = "installed-widget-choices-review-before-sharing"; screenshot.lifetime = .keepAlways; add(screenshot)
        #else
        throw XCTSkip("Physical iOS widget diagnostic")
        #endif
    }
}
