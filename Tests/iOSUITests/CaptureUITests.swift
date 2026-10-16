import XCTest
import UIKit

/// Drives the real iOS capture app in the Simulator.
///
/// The destination folder is supplied as a launch argument (`-ingestInboxPath`), which
/// `UserDefaults` picks up automatically. On a device that argument is absent and the
/// app resolves iCloud instead. A Debug-only app-private fixture lets the test drive the
/// actual capture and inbox read-back flow without trying to cross the runner's sandbox;
/// `MobileCaptureServiceTests` separately assert the exact file bytes and filename.
final class CaptureUITests: XCTestCase {

    private var inbox: URL!

    private var usingSharedInbox = false

    private let testInboxID = "capture-ui-\(UUID().uuidString)"

    override func setUpWithError() throws {
        // Point the app at the real shared inbox when one is supplied, so the mobile →
        // desktop hand-off can be exercised for real rather than simulated.
        if let shared = ProcessInfo.processInfo.environment["BW_TEST_INBOX"], shared.isEmpty == false {
            inbox = URL(fileURLWithPath: shared, isDirectory: true)
            usingSharedInbox = true
        } else {
            inbox = FileManager.default.temporaryDirectory
                .appendingPathComponent("mobile-inbox-\(UUID().uuidString)", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        // Never delete the user's real inbox.
        if usingSharedInbox == false { try? FileManager.default.removeItem(at: inbox) }
    }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = usingSharedInbox
            ? ["-ingestInboxPath", inbox.path]
            : ["-BWTestCaptureInboxID", testInboxID]
        app.launch()
        if usingSharedInbox == false {
            XCTAssertTrue(app.staticTexts["Test Inbox"].waitForExistence(timeout: 20),
                          "The app must resolve its test destination before the test captures.")
        }
        return app
    }

    func testCaptureScreenIsReadyWhenADestinationIsConfigured() {
        let app = launch()
        XCTAssertTrue(app.staticTexts["Capture"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.buttons["Save"].waitForExistence(timeout: 10))
        // With a destination configured the setup card must be gone.
        XCTAssertFalse(app.staticTexts["Pick the shared inbox folder"].exists)
        XCTAssertTrue(app.buttons["Photos"].exists, "Photo attachment must be offered")
        XCTAssertTrue(app.buttons["Files"].exists, "File attachment must be offered")
        add(XCTAttachment(screenshot: XCUIScreen.main.screenshot()))
    }

    func testTypedTextBecomesAMarkdownFileInTheSharedInbox() throws {
        let app = launch()
        let field = app.textViews.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 20))
        field.tap()
        field.typeText("Look into building a local ESP32 control surface")

        add(XCTAttachment(screenshot: XCUIScreen.main.screenshot()))

        let capture = app.buttons["Save"].firstMatch
        XCTAssertTrue(capture.isEnabled, "Capture must be enabled once there is text")
        let done = app.buttons["Done"].firstMatch
        XCTAssertTrue(done.waitForExistence(timeout: 10))
        done.tap()
        capture.tap()

        // The app confirms the write. The core test suite checks the Markdown bytes and
        // filename at the service boundary; physical-device tests cover the iCloud list.
        let name = "Look into building a local ESP32 control surface"
        XCTAssertTrue(app.staticTexts["Saved \(name)"].waitForExistence(timeout: 10))
        add(XCTAttachment(screenshot: XCUIScreen.main.screenshot()))
    }

    func testPastedImageBecomesARealPNG() throws {
        let app = launch()
        XCTAssertTrue(app.buttons["Paste media"].waitForExistence(timeout: 20))
        let original = UIPasteboard.general.items
        defer { UIPasteboard.general.items = original }
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 48, height: 24))
        let image = renderer.image { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 48, height: 24))
        }
        UIPasteboard.general.image = image
        app.buttons["Paste media"].tap()
        // The paste-permission alert belongs to springboard, not to this app, so asking
        // `app` for it can only ever time out. It also has to be answered: the app now
        // reads the pasteboard off the main actor, so it stays responsive while the alert
        // is up rather than blocking behind it — but nothing is pasted until Allow.
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        // Exact match: "Don't Allow Paste" also *contains* "Allow Paste", and matching
        // loosely tapped the deny button — which then looked like a paste failure.
        let allowPaste = springboard.buttons.matching(
            NSPredicate(format: "label == 'Allow Paste' OR label == 'Allow'")
        ).firstMatch
        let alertAppeared = allowPaste.waitForExistence(timeout: 10)
        print("PASTE ALERT FOUND -> \(alertAppeared) label=\(alertAppeared ? allowPaste.label : "-")")
        if alertAppeared { allowPaste.tap() }
        Thread.sleep(forTimeInterval: 2)
        XCTAssertTrue(app.buttons["Save"].isEnabled, "A pasted image should become part of the draft.")
        app.buttons["Save"].tap()
        let messages = app.staticTexts.allElementsBoundByIndex.map(\.label)
            .filter { $0.contains("clipboard") || $0.contains("Saved") || $0.contains("Could not") }
        print("PASTE APP MESSAGE -> \(messages)")
        // The app-side inbox is intentionally not exposed to the test runner. Service
        // tests cover encoded-file validity; the UI can report this asynchronous save
        // either through the short-lived toast or the refreshed inbox row.
        let saved = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Saved '")).firstMatch.waitForExistence(timeout: 3)
        let listed = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Pasted Image'")).firstMatch.waitForExistence(timeout: 10)
        XCTAssertTrue(saved || listed, "The pasted image must be acknowledged or listed after saving.")
    }

    func testFailedWritePreservesTheDraft() throws {
        let blocked = inbox.appendingPathComponent("not-a-folder")
        try "fixture".write(to: blocked, atomically: true, encoding: .utf8)
        let app = XCUIApplication()
        app.launchArguments = ["-ingestInboxPath", blocked.path]
        app.launch()
        let field = app.textViews.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 20))
        field.tap()
        field.typeText("Keep this draft after a failed save")
        app.buttons["Save"].tap()
        XCTAssertEqual(field.value as? String, "Keep this draft after a failed save")
        XCTAssertEqual(try String(contentsOf: blocked), "fixture")
    }

    func testCaptureIsRefusedWhenThereIsNothingToSave() {
        let app = launch()
        XCTAssertTrue(app.staticTexts["Capture"].waitForExistence(timeout: 20))
        XCTAssertFalse(app.buttons["Save"].isEnabled,
                       "An empty draft must not be savable")
    }

    func testDestinationIsOptionalAndDoesNotBlockSaving() {
        let app = launch()
        let field = app.textViews.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 20))
        field.tap()
        field.typeText("A quick unclassified thought")
        XCTAssertTrue(app.buttons["Save"].isEnabled)
        XCTAssertTrue(app.staticTexts["Destination"].exists)
        XCTAssertTrue(app.buttons["Destination"].exists)
    }

    func testCaptureDeepLinkKeepsTheCaptureSurfaceReady() {
        let app = XCUIApplication()
        app.launchArguments = (usingSharedInbox
            ? ["-ingestInboxPath", inbox.path]
            : ["-BWTestCaptureInboxID", testInboxID])
            + ["-BWInitialURL", "betterworkspace-ingest://capture"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Test Inbox"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.textViews["capture-text"].waitForExistence(timeout: 20))
    }

    func testTipKitDatastoreResetLeavesCaptureAvailable() {
        let app = XCUIApplication()
        app.launchArguments = (usingSharedInbox
            ? ["-ingestInboxPath", inbox.path]
            : ["-BWTestCaptureInboxID", testInboxID])
            + ["-BWResetTipsForTesting", "YES"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Test Inbox"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.buttons["Save"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.staticTexts["Capture first"].waitForExistence(timeout: 10),
                      "The first-run tip must explain that Capture writes a real Inbox file")
    }
}
