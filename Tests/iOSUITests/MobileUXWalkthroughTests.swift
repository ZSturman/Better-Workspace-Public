import XCTest

/// A visual walk through the phone app, including the states a capture-first app lives
/// or dies by: the keyboard up, a queue with items in it, and landscape.
///
/// Screenshots go into the result bundle as attachments so they can be reviewed by eye.
final class MobileUXWalkthroughTests: XCTestCase {

    private var inbox: URL!
    private var step = 0

    private let testInboxID = "mobile-ux-\(UUID().uuidString)"

    override func setUpWithError() throws {
        continueAfterFailure = true
        inbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("mobile-ux-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: inbox)
        XCUIDevice.shared.orientation = .portrait
    }

    private func shoot(_ name: String, settle: TimeInterval = 1.2) {
        Thread.sleep(forTimeInterval: settle)
        step += 1
        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = String(format: "%02d-%@", step, name)
        attachment.lifetime = .keepAlways
        add(attachment)
        print("IOS SHOT -> \(attachment.name ?? name)")
    }

    private func launchReady() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-BWTestCaptureInboxID", testInboxID]
        app.launch()
        XCTAssertTrue(app.staticTexts["Capture"].waitForExistence(timeout: 30))
        XCTAssertTrue(app.staticTexts["Test Inbox"].waitForExistence(timeout: 20),
                      "The app must resolve its test destination before the walkthrough captures.")
        return app
    }

    // MARK: - The walk

    func testMobileWalkthrough() throws {
        let app = launchReady()
        shoot("ready-empty", settle: 2.5)

        XCTAssertFalse(app.staticTexts["Pick the shared inbox folder"].exists,
                       "With a destination configured the setup card must be gone")

        // ---- Keyboard up: can you still reach Capture? ----
        let field = app.textViews.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 15))
        field.tap()
        Thread.sleep(forTimeInterval: 1.5)
        shoot("keyboard-up-empty", settle: 0.8)

        field.typeText("Look into a desk-mounted focus timer with an ESP32")
        shoot("keyboard-up-typed", settle: 0.8)

        let capture = app.buttons["Save"].firstMatch
        XCTAssertTrue(capture.exists, "Capture button must exist while typing")
        XCTAssertTrue(capture.isHittable,
                      "Capture must stay reachable with the keyboard up — it is the whole point")
        XCTAssertTrue(capture.isEnabled)

        // iOS 26 Simulator gives the first tap to the text editor while it owns the
        // keyboard. The explicit Done control is the supported way to end editing;
        // keep the assertions above so this still catches a hidden Capture control.
        let done = app.buttons["Done"].firstMatch
        XCTAssertTrue(done.waitForExistence(timeout: 10))
        done.tap()
        capture.tap()
        let firstName = "Look into a desk-mounted focus timer with an ESP32"
        XCTAssertTrue(app.staticTexts["Saved \(firstName)"].waitForExistence(timeout: 10))
        Thread.sleep(forTimeInterval: 3)
        shoot("after-capture", settle: 1.0)

        // The field is cleared. Exact Markdown file assertions live in
        // MobileCaptureServiceTests because the app's fixture is in its own iOS sandbox.
        XCTAssertEqual(field.value as? String, "")

        // ---- A second capture, so the waiting list has depth ----
        field.tap()
        field.typeText("Research alternatives to Tailscale Funnel")
        XCTAssertTrue(done.waitForExistence(timeout: 10))
        done.tap()
        XCTAssertFalse(app.keyboards.firstMatch.exists, "Done dismisses the keyboard")
        capture.tap()
        XCTAssertTrue(app.staticTexts["Saved Research alternatives to Tailscale Funnel"].waitForExistence(timeout: 10))
        Thread.sleep(forTimeInterval: 3)
        shoot("two-waiting", settle: 1.0)

        // ---- Landscape ----
        XCUIDevice.shared.orientation = .landscapeLeft
        shoot("landscape", settle: 2.5)
        XCTAssertTrue(app.buttons["Save"].firstMatch.waitForExistence(timeout: 10),
                      "Save must survive rotation")
        XCUIDevice.shared.orientation = .portrait
        Thread.sleep(forTimeInterval: 2)

        // ---- Attachment affordances ----
        for tile in ["Photos", "Files", "Paste media"] {
            let button = app.buttons[tile].firstMatch
            XCTAssertTrue(button.exists, "\(tile) tile missing")
            XCTAssertTrue(button.isEnabled, "\(tile) should be usable once a destination exists")
        }
        shoot("attach-row", settle: 0.6)

        // ---- The file importer actually opens ----
        app.buttons["Files"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Cancel"].firstMatch.waitForExistence(timeout: 15),
                      "Files must present a document picker, not silently stay on Capture")
        shoot("file-importer", settle: 1.0)
        for dismiss in ["Cancel", "Done"] {
            let button = app.buttons[dismiss].firstMatch
            if button.exists, button.isHittable { button.tap(); break }
        }
        Thread.sleep(forTimeInterval: 2)
        shoot("back-from-importer", settle: 1.0)
        XCTAssertTrue(app.staticTexts["Capture"].waitForExistence(timeout: 15),
                      "Dismissing the importer must return to the capture screen")
        app.buttons["Choose inbox folder"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Cancel"].firstMatch.waitForExistence(timeout: 15))
        shoot("folder-picker")
        app.buttons["Cancel"].firstMatch.tap()
    }

    /// Without a destination the app must explain itself rather than silently fail.
    func testUnconfiguredStateIsHonest() {
        let app = XCUIApplication()
        app.launchArguments = ["-ingestInboxPath", ""]
        app.launch()
        XCTAssertTrue(app.staticTexts["Capture"].waitForExistence(timeout: 30))
        Thread.sleep(forTimeInterval: 4)
        shoot("unconfigured", settle: 0.5)

        // Either iCloud resolved, or the setup card is showing. Never a dead Capture
        // button with no explanation.
        let hasSetupCard = app.staticTexts["Pick the shared inbox folder"].exists
        let captureEnabled = app.buttons["Capture"].firstMatch.isEnabled
        XCTAssertTrue(hasSetupCard || captureEnabled,
                      "With no destination the app must show the setup card")
    }
}
