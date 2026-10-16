import XCTest
import UIKit

/// Runs against a real iPhone or iPad.
///
/// Unlike the Simulator tests, this one cannot inspect the app's files from the test
/// process — the runner has its own sandbox on the device. So it verifies through the
/// interface instead: the app's own "In the inbox" list is read back from whatever
/// destination the app resolved, which is the same evidence a person would trust.
///
/// Every step is screenshotted so the run can be reviewed by eye.
final class DeviceCaptureUITests: XCTestCase {

    private var step = 0

    private var deviceLabel: String {
        UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"
    }

    private func shoot(_ name: String) {
        step += 1
        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = String(format: "%02d-%@", step, name)
        attachment.lifetime = .keepAlways
        add(attachment)
        print("DEVICE SHOT -> \(attachment.name ?? name)")
    }

    /// Reads back what the device can currently see in the shared inbox, without
    /// capturing anything. Used to tell a device-to-Mac sync problem from a Mac-to-device
    /// one: the two directions fail for different reasons and look identical from the UI.
    func testListWhatThePhoneSeesInTheInbox() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Physical-device test.")
        #else
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.staticTexts["Capture"].waitForExistence(timeout: 30))
        // Let the inbox listing settle; it is an iCloud read.
        Thread.sleep(forTimeInterval: 6)
        let names = app.staticTexts.allElementsBoundByIndex
            .map(\.label)
            .filter { $0.hasSuffix(".md") || $0.hasSuffix(".jpeg") || $0.hasSuffix(".png") }
        print("DEVICE INBOX LIST -> \(names)")
        let count = app.staticTexts.matching(
            NSPredicate(format: "label MATCHES '^[0-9]+$'")).firstMatch
        print("DEVICE INBOX COUNT -> \(count.exists ? count.label : "?")")
        shoot("inbox-readback")
        #endif
    }

    /// The Mac publishes its discovered root Workspace folders through CloudKit. This
    /// checks the physical iPhone sees that projection in the one destination menu,
    /// rather than relying on the Simulator's isolated CloudKit account.
    func testDestinationMenuShowsPublishedWorkspaceFoldersOnTheRealDevice() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Physical-device test.")
        #else
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.staticTexts["Capture"].waitForExistence(timeout: 30))

        // The snapshot is intentionally asynchronous and comes from the Mac's private
        // CloudKit projection, not from the phone's filesystem.
        let destination = app.buttons["Destination"]
        XCTAssertTrue(destination.waitForExistence(timeout: 15))
        for _ in 0..<3 {
            destination.tap()
            if app.buttons["To Study"].waitForExistence(timeout: 8) { break }
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)).tap()
            Thread.sleep(forTimeInterval: 3)
        }
        XCTAssertTrue(app.buttons["To Study"].exists,
                      "The physical phone must receive To Study from the Mac projection.")
        shoot("destination-menu")
        #endif
    }

    /// Exercises the system camera on the attached iPhone. A new install may present
    /// the iOS camera-permission alert; the test deliberately stops there instead of
    /// attempting to approve a privacy decision on the user's behalf.
    func testCameraReturnsToTheDraftOnTheRealDevice() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Physical-device test.")
        #else
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.buttons["Camera"].waitForExistence(timeout: 30))
        app.buttons["Camera"].tap()

        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        if springboard.alerts.firstMatch.waitForExistence(timeout: 3) {
            shoot("camera-permission")
            throw XCTSkip("Camera permission requires the device owner to approve it.")
        }

        shoot("camera-opened")
        let shutter = app.buttons["PhotoCapture"].firstMatch
        XCTAssertTrue(shutter.waitForExistence(timeout: 12),
                      "The physical camera shutter was not exposed to UI automation.")
        shutter.tap()
        shoot("camera-photo-taken")

        let usePhoto = app.buttons["Use Photo"].firstMatch
        XCTAssertTrue(usePhoto.waitForExistence(timeout: 12),
                      "The camera did not offer the captured photo for use.")
        usePhoto.tap()
        XCTAssertTrue(app.staticTexts["Ready to save"].waitForExistence(timeout: 12),
                      "The captured photo did not return to the draft.")
        shoot("camera-returned-to-draft")
        #endif
    }

    /// Full physical hand-off: one photo/note/tag bundle is saved to To Study, then a
    /// second saved capture is re-routed from the recent list to a different folder.
    /// The deliberately short markers make the exact folder names inspectable on the
    /// Mac after this UI test finishes.
    func testPhysicalCaptureRoutesBundlesToPublishedFolders() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Physical-device test.")
        #else
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.staticTexts["Capture"].waitForExistence(timeout: 30))

        let suffix = Int(Date().timeIntervalSince1970) % 100_000
        let toStudy = "BW-E2E-Study-\(suffix)"
        let rerouted = "BW-E2E-Reroute-\(suffix)"

        app.buttons["Camera"].tap()
        XCTAssertTrue(app.buttons["PhotoCapture"].waitForExistence(timeout: 12))
        app.buttons["PhotoCapture"].tap()
        XCTAssertTrue(app.buttons["Use Photo"].waitForExistence(timeout: 12))
        app.buttons["Use Photo"].tap()
        XCTAssertTrue(app.staticTexts["Ready to save"].waitForExistence(timeout: 12))

        let note = app.textViews["capture-text"]
        XCTAssertTrue(note.waitForExistence(timeout: 12))
        note.tap()
        note.typeText(toStudy)
        let done = app.buttons["Done"].firstMatch
        if done.exists { done.tap() }

        // This is an actual CloudKit-published tag, not a test-only fixture. Keep the
        // routing test actionable when a deployed CloudKit schema has not published a
        // tag catalog yet; the dedicated catalog test reports that configuration issue.
        let aiTag = app.buttons["Tag AI"]
        if aiTag.waitForExistence(timeout: 3) {
            aiTag.tap()
        } else {
            print("DEVICE TAG CATALOG -> unavailable")
        }

        let destination = app.buttons["Destination"]
        destination.tap()
        XCTAssertTrue(app.buttons["To Study"].waitForExistence(timeout: 12))
        app.buttons["To Study"].tap()
        shoot("study-draft-ready")

        let save = app.buttons["Save"]
        XCTAssertTrue(save.isEnabled)
        save.tap()
        XCTAssertTrue(app.staticTexts["Saved \(toStudy)"].waitForExistence(timeout: 12))
        XCTAssertTrue(app.staticTexts[toStudy].waitForExistence(timeout: 15),
                      "The saved bundle did not appear in the recent list before Mac filing.")
        shoot("study-in-recent")

        // Save a second bundle without a destination, then change its destination from
        // the recent list. This proves routing is generic and that an existing capture
        // can be corrected before the Mac files it.
        note.tap()
        note.typeText(rerouted)
        if done.exists { done.tap() }
        XCTAssertTrue(save.isEnabled)
        save.tap()
        XCTAssertTrue(app.staticTexts["Saved \(rerouted)"].waitForExistence(timeout: 12))
        let recentCapture = app.staticTexts[rerouted]
        XCTAssertTrue(recentCapture.waitForExistence(timeout: 15))
        recentCapture.tap()
        XCTAssertTrue(app.buttons["To Look Up"].waitForExistence(timeout: 12))
        app.buttons["To Look Up"].tap()
        shoot("reroute-submitted")
        #endif
    }

    /// A new tag is created from the same draft, selected immediately, then delivered
    /// ahead of the capture's filing command. This covers the path that cannot be
    /// represented by a pre-existing catalog chip.
    func testPhysicalCaptureCreatesTagAndRoutesToIdeas() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Physical-device test.")
        #else
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.staticTexts["Capture"].waitForExistence(timeout: 30))

        let suffix = Int(Date().timeIntervalSince1970) % 100_000
        let tag = "BW New Tag \(suffix)"
        let capture = "BW-E2E-Ideas-\(suffix)"

        app.buttons["Camera"].tap()
        XCTAssertTrue(app.buttons["PhotoCapture"].waitForExistence(timeout: 12))
        app.buttons["PhotoCapture"].tap()
        XCTAssertTrue(app.buttons["Use Photo"].waitForExistence(timeout: 12))
        app.buttons["Use Photo"].tap()
        XCTAssertTrue(app.staticTexts["Ready to save"].waitForExistence(timeout: 12),
                      "The photo must return to the same new-tag draft.")

        let newTag = app.textFields["new-capture-tag"]
        XCTAssertTrue(newTag.waitForExistence(timeout: 15))
        newTag.tap()
        newTag.typeText(tag)
        let add = app.buttons["add-capture-tag"]
        XCTAssertTrue(add.isEnabled)
        add.tap()
        XCTAssertTrue(app.buttons["Tag \(tag)"].waitForExistence(timeout: 10),
                      "A new tag should be selected in the draft immediately.")

        let note = app.textViews["capture-text"]
        note.tap()
        note.typeText(capture)
        let done = app.buttons["Done"].firstMatch
        if done.exists { done.tap() }

        app.buttons["Destination"].tap()
        XCTAssertTrue(app.buttons["Ideas"].waitForExistence(timeout: 12))
        app.buttons["Ideas"].tap()
        shoot("new-tag-ideas-draft")

        let save = app.buttons["Save"]
        XCTAssertTrue(save.isEnabled)
        save.tap()
        XCTAssertTrue(app.staticTexts["Saved \(capture)"].waitForExistence(timeout: 12))
        XCTAssertTrue(app.staticTexts[capture].waitForExistence(timeout: 15))
        shoot("new-tag-ideas-recent")
        #endif
    }

    func testCaptureOnTheRealDevice() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Physical-device test: the Simulator has no iCloud container and the "
                      + "document picker there browses the Simulator's own storage. "
                      + "CaptureUITests covers the Simulator.")
        #else
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.staticTexts["Capture"].waitForExistence(timeout: 30),
                      "Capture screen did not appear on the device")
        let resolving = app.staticTexts["Connecting to iCloud…"].firstMatch
        if resolving.exists {
            let resolved = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: resolving)
            XCTAssertEqual(XCTWaiter.wait(for: [resolved], timeout: 30), .completed)
        }
        shoot("launched")
        // Which destination the app actually resolved. A capture that never reaches the
        // Mac is usually this: a bookmarked folder rather than the shared container.
        let destination = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS 'iCloud' OR label CONTAINS 'Inbox' OR label CONTAINS 'Not set'")
        ).allElementsBoundByIndex.map(\.label)
        print("DEVICE DESTINATION -> \(destination)")

        let needsFolder = app.staticTexts["Pick the shared inbox folder"].exists
        print("DEVICE NEEDS FOLDER -> \(needsFolder)")

        if needsFolder {
            // One-time setup: point the app at the shared iCloud Drive inbox.
            app.buttons["Choose Folder"].firstMatch.tap()
            Thread.sleep(forTimeInterval: 4)
            shoot("folder-picker")

            // The picker's layout varies; try to reach Better Workspace → Inbox.
            for label in ["iCloud Drive", "Browse", "Better Workspace", "Inbox"] {
                let cell = app.descendants(matching: .any)
                    .matching(NSPredicate(format: "label CONTAINS %@", label))
                    .firstMatch
                if cell.waitForExistence(timeout: 6), cell.isHittable {
                    cell.tap()
                    Thread.sleep(forTimeInterval: 2.5)
                    shoot("picker-\(label.replacingOccurrences(of: " ", with: "-"))")
                }
            }
            for confirm in ["Open", "Done", "Choose"] {
                let button = app.buttons[confirm].firstMatch
                if button.exists, button.isHittable {
                    button.tap()
                    Thread.sleep(forTimeInterval: 3)
                    break
                }
            }
            shoot("after-folder-pick")
        }

        // Capture something.
        let marker = "\(deviceLabel) capture \(Int(Date().timeIntervalSince1970) % 100000)"
        let field = app.textViews.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 15))
        field.tap()
        field.typeText(marker)
        shoot("typed")

        let capture = app.buttons["Save"].firstMatch
        print("DEVICE CAPTURE ENABLED -> \(capture.isEnabled)")
        guard capture.isEnabled else {
            shoot("capture-disabled")
            throw XCTSkip("No destination configured on the device yet — the shared folder "
                          + "still needs picking once by hand.")
        }
        capture.tap()
        Thread.sleep(forTimeInterval: 4)
        shoot("captured")

        // The app lists what is waiting for the Mac.
        XCTAssertTrue(app.staticTexts["In the inbox"].waitForExistence(timeout: 20),
                      "The capture should appear in the app's waiting list")
        XCTAssertTrue(app.staticTexts[marker].waitForExistence(timeout: 20),
                      "This capture, not an older item, must appear in the waiting list")
        shoot("inbox-list")
        print("DEVICE CAPTURED MARKER -> \(marker)")
        #endif
    }

    /// A real-device smoke path for successive saved bundles. Destination selection is
    /// intentionally one folder menu rather than special-purpose classification buttons.
    func testCaptureBundlesOnRealDevice() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Physical-device test.")
        #else
        continueAfterFailure = false
        // XCTest can otherwise rotate a real iPhone while the first text view is
        // acquiring focus, leaving the second synthetic type event without a keyboard.
        // Keep this capture flow in one stable orientation; landscape is covered by
        // the iPad-specific visual tests.
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.staticTexts["Capture"].waitForExistence(timeout: 30))
        let field = app.textViews.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 15))

        let suffix = Int(Date().timeIntervalSince1970) % 100000
        // The landscape iPad list deliberately truncates its narrow text label for
        // accessibility. Keep test-created names short enough that the assertion reads
        // back the exact row, rather than mistaking presentation truncation for loss.
        let captures = ["capture-\(suffix)", "followup-\(suffix)"]
        for title in captures {
            field.tap()
            field.typeText(title)
            XCTAssertTrue(app.buttons["Save"].isEnabled)
            app.buttons["Save"].tap()
            XCTAssertTrue(app.staticTexts[title].waitForExistence(timeout: 20))
            shoot(title.replacingOccurrences(of: " ", with: "-"))
        }
        #endif
    }
}
