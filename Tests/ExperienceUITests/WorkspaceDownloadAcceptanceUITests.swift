import XCTest

/// Explicit, UUID-scoped acceptance against the installed phone and running Mac.
/// Creates/edits only its own project through the app; cleanup uses recoverable Trash.
final class WorkspaceDownloadAcceptanceUITests: XCTestCase {
    func testInstalledWorkspaceDownload() throws {
        #if os(iOS) && !targetEnvironment(simulator)
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["BW_RUN_DOWNLOAD_ACCEPTANCE"] == "1", "Explicit disposable live-download acceptance only")
        let session = try XCTUnwrap(env["BW_DOWNLOAD_SESSION_ID"].flatMap(UUID.init(uuidString:)))
        let phase = try XCTUnwrap(env["BW_DOWNLOAD_ACCEPTANCE_PHASE"])
        let title = "Offline QA " + session.uuidString
        let app = XCUIApplication(bundleIdentifier: "com.zacharysturman.BetterWorkspace.Mobile")
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        app.launchArguments = phase == "offline" ? ["-mobileCloudDisabled", "YES"] : []
        app.launch(); app.activate()
        defer {
            let context = XCTAttachment(string: app.debugDescription)
            context.name = "download-" + phase + "-final-state"; context.lifetime = .keepAlways; add(context)
            app.terminate(); app.launchArguments = []; app.launch()
        }

        func refresh() {
            app.tabBars.buttons["Overview"].tap()
            let button = app.buttons["Refresh workspace index"].firstMatch
            XCTAssertTrue(button.waitForExistence(timeout: 10)); button.tap()
            let finished = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value BEGINSWITH %@", "Synced"), object: button)
            XCTAssertEqual(XCTWaiter.wait(for: [finished], timeout: 60), .completed)
            app.tabBars.buttons["Projects"].tap()
        }
        func reveal(_ element: XCUIElement) {
            for _ in 0..<6 where !element.exists || !element.isHittable { app.swipeUp() }
            XCTAssertTrue(element.isHittable)
        }
        func capture(_ name: String) {
            let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            attachment.name = "download-" + phase + "-" + name
            attachment.lifetime = .keepAlways; add(attachment)
        }
        func openProject() {
            app.tabBars.buttons["Projects"].tap()
            let search = app.searchFields.firstMatch
            for _ in 0..<3 {
                if search.waitForExistence(timeout: 1) { break }
                app.collectionViews.firstMatch.swipeDown()
            }
            XCTAssertTrue(search.waitForExistence(timeout: 10)); search.tap(); search.typeText(title)
            let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "mobile-project-Projects/" + title)).firstMatch
            for _ in 0..<4 {
                if row.waitForExistence(timeout: 5) { break }
                refresh()
            }
            XCTAssertTrue(row.waitForExistence(timeout: 10)); row.tap()
        }
        func waitForCopy() {
            let open = app.buttons["download.open"]
            let update = app.buttons["Update download"]
            let deadline = Date().addingTimeInterval(180)
            while Date() < deadline {
                if open.waitForExistence(timeout: 5), update.exists, update.isEnabled { return }
                refresh()
            }
            XCTAssertTrue(open.exists, "Mac must prepare the requested asset and the phone must install it")
            XCTAssertTrue(update.isEnabled, "Receipt/transfer cleanup must finish")
        }

        if phase == "create" {
            app.tabBars.buttons["Projects"].tap()
            app.buttons["New project"].tap()
            let field = app.textFields["planning-title"]
            XCTAssertTrue(field.waitForExistence(timeout: 10)); field.tap(); field.typeText(title)
            let description = app.textViews["planning-description"]
            description.tap(); description.typeText("Initial offline fixture " + session.uuidString)
            app.buttons["Save"].tap()
            openProject()
            let toggle = app.switches["download.enabled"]; reveal(toggle)
            XCTAssertEqual(toggle.value as? String, "0")
            toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
            waitForCopy(); capture("ready")
        } else {
            openProject()
            switch phase {
            case "download":
                let toggle = app.switches["download.enabled"]; reveal(toggle)
                if toggle.value as? String == "0" {
                    toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
                }
                waitForCopy(); capture("ready")
            case "offline":
                let open = app.buttons["download.open"]
                XCTAssertTrue(open.waitForExistence(timeout: 10)); open.tap()
                app.collectionViews.buttons["Work"].firstMatch.tap()
                let file = app.collectionViews.buttons.matching(NSPredicate(format: "label CONTAINS %@ AND NOT label BEGINSWITH %@", title, "Share ")).firstMatch
                XCTAssertTrue(file.waitForExistence(timeout: 10)); file.tap()
                capture("quick-look")
                let close = app.buttons.matching(NSPredicate(format: "identifier == %@ OR label ==[c] %@ OR label ==[c] %@", "QLOverlayDoneButtonAccessibilityIdentifier", "Done", "Close")).firstMatch
                XCTAssertTrue(close.waitForExistence(timeout: 10), "Local Quick Look must open with transport disabled")
                close.tap()
                let dismissed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.otherElements["QLPreviewControllerView"])
                XCTAssertEqual(XCTWaiter.wait(for: [dismissed], timeout: 10), .completed)
                let share = app.collectionViews.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Share ")).firstMatch
                XCTAssertTrue(share.waitForExistence(timeout: 10)); share.tap()
                XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Copy")).firstMatch.waitForExistence(timeout: 10), "The local file must open a share sheet; no recipient is chosen")
                capture("share-sheet")
            case "update":
                let goal = app.collectionViews.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", title)).firstMatch
                reveal(goal); goal.tap(); app.buttons["Edit"].tap()
                let body = app.textViews["planning-description"]
                XCTAssertTrue(body.waitForExistence(timeout: 10)); body.tap()
                body.typeText("\nUpdated offline fixture " + session.uuidString)
                app.buttons["Save"].tap()
                app.navigationBars["Goal"].buttons.element(boundBy: 0).tap()
                XCTAssertTrue(app.buttons["project.zen.open"].waitForExistence(timeout: 10))
                let update = app.buttons["Update download"]; reveal(update); update.tap()
                waitForCopy(); capture("updated")
            case "refresh":
                let update = app.buttons["Update download"]; reveal(update); update.tap()
                waitForCopy(); capture("updated")
            case "remove":
                let toggle = app.switches["download.enabled"]; reveal(toggle)
                XCTAssertEqual(toggle.value as? String, "1")
                toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
                XCTAssertEqual(toggle.value as? String, "0")
                XCTAssertFalse(app.buttons["download.open"].exists); capture("removed")
            case "cancel":
                let toggle = app.switches["download.enabled"]; reveal(toggle)
                XCTAssertEqual(toggle.value as? String, "0")
                toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
                XCTAssertEqual(toggle.value as? String, "1")
                toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
                XCTAssertEqual(toggle.value as? String, "0")
                XCTAssertFalse(app.buttons["download.open"].exists); capture("cancelled")
                refresh()
            case "cleanup":
                app.buttons["Manage project"].tap(); app.buttons["Delete project…"].tap()
                XCTAssertTrue(app.alerts.buttons["Move entire project to Trash"].waitForExistence(timeout: 5))
                app.alerts.buttons["Move entire project to Trash"].tap()
                refresh()
            default: XCTFail("Unknown acceptance phase")
            }
        }
        #else
        throw XCTSkip("Installed physical iPhone acceptance only")
        #endif
    }
}
