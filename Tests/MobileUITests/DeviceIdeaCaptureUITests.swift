import XCTest
import UIKit

/// Opt-in capture to the signed-in account. Check the originals with
/// Tools/verify_device_idea.sh before counting the device test as delivery.
final class DeviceIdeaCaptureUITests: XCTestCase {
    func testIdeaWithImageAndFileSyncsAfterRelaunch() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Physical-device test: it writes a real CloudKit idea.")
        #else
        guard let stamp = ProcessInfo.processInfo.environment["BW_QA_STAMP"], !stamp.isEmpty else {
            throw XCTSkip("Set TEST_RUNNER_BW_QA_STAMP to opt in to a real idea.")
        }
        continueAfterFailure = false
        let app = XCUIApplication()
        // Disable CloudKit for the first process to exercise durable offline Save.
        // Relaunch without the override to exercise normal upload and Mac filing.
        app.launchArguments = ["-BWInitialURL", "betterworkspace-mobile://capture?kind=idea",
                               "-BWTestIdeaAttachments", "YES", "-mobileCloudDisabled", "YES"]
        app.launch()
        let note = app.textViews["capture-text"].firstMatch
        XCTAssertTrue(note.waitForExistence(timeout: 30))
        note.tap()
        note.typeText("BW QA idea \(stamp)\n\nCaptured on \(UIDevice.current.model) with a pasted image.")
        if app.buttons["Done"].exists { app.buttons["Done"].tap() }

        let paste = app.buttons["Paste media"].firstMatch
        for _ in 0..<6 { if paste.isHittable { break }; app.swipeUp() }
        paste.tap()
        // The system asks before an app reads the clipboard.
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let allow = springboard.buttons["Allow Paste"]
        if allow.waitForExistence(timeout: 5) { allow.tap() }
        let image = app.textFields.matching(identifier: "capture-attachment-title")
            .matching(NSPredicate(format: "value == %@", "Pasted Image")).firstMatch
        XCTAssertTrue(image.waitForExistence(timeout: 15), "The pasted image was not staged")

        if app.buttons["Done"].exists { app.buttons["Done"].tap() }
        let save = app.buttons["Save"].firstMatch
        for _ in 0..<6 { if save.isHittable { break }; app.swipeUp() }
        save.tap()
        let receipt = app.staticTexts["capture-receipt"]
        XCTAssertTrue(receipt.waitForExistence(timeout: 20))
        XCTAssertTrue(receipt.label.contains("Waiting for Mac sync"))
        app.terminate()
        app.launchArguments = ["-BWInitialURL", "betterworkspace-mobile://capture"]
        app.launch()
        let row = app.buttons.matching(identifier: "recent-capture")
            .matching(NSPredicate(format: "label CONTAINS %@", "BW QA idea " + stamp)).firstMatch
        for _ in 0..<5 where !row.exists { app.swipeUp() }
        XCTAssertTrue(row.waitForExistence(timeout: 30), "The saved idea did not survive relaunch")
        #endif
    }

    func testPeerCaptureAppearsOnceInTheSharedInbox() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Requires a physical device with iCloud Drive.")
        #else
        guard let stamp = ProcessInfo.processInfo.environment["BW_QA_PEER_STAMP"], !stamp.isEmpty else {
            throw XCTSkip("Set TEST_RUNNER_BW_QA_PEER_STAMP to a pending idea saved by another device.")
        }
        let app = XCUIApplication()
        app.launchArguments = ["-BWInitialURL", "betterworkspace-mobile://capture"]
        app.launch()
        XCTAssertTrue(app.staticTexts["iCloud · Better Workspace"].waitForExistence(timeout: 45))
        let rows = app.buttons.matching(identifier: "recent-capture")
            .matching(NSPredicate(format: "label CONTAINS %@", "BW QA idea " + stamp))
        for _ in 0..<6 where !rows.firstMatch.exists { app.swipeUp() }
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 45))
        XCTAssertEqual(rows.count, 1)
        #endif
    }
}
