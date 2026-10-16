import XCTest
import UIKit

final class MobileCaptureComposerUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        if XCUIDevice.shared.orientation != .portrait { XCUIDevice.shared.orientation = .portrait }
    }
    override func tearDownWithError() throws { XCUIDevice.shared.orientation = .portrait }

    private func shoot(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name; shot.lifetime = .keepAlways; add(shot)
    }

    private func launch(images: Bool = false, catalog: Bool = false,
                        url: String = "betterworkspace-mobile://capture", intent: String? = nil) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-mobileCloudDisabled", "YES", "-BWTestCaptureInboxID", "capture-batch-" + UUID().uuidString,
                               "-BWInitialURL", url]
        // Runs a capture intent through the same capture() its perform() calls.
        if let intent { app.launchArguments += ["-BWTestRunIntent", intent] }
        if images { app.launchArguments += ["-BWTestCaptureImageDraft", "YES"] }
        // Fixture tags (Cooking, Photography, Programming, Projects, Reference) and
        // folders (For Reference, Ideas), in place of the Mac's CloudKit catalog.
        if catalog { app.launchArguments += ["-BWTestCaptureCatalog", "YES"] }
        app.launch()
        XCTAssertTrue(app.staticTexts["Test Inbox"].waitForExistence(timeout: 20))
        return app
    }

    func testMarkdownTitleAndLandscapePreserveDraftOffline() {
        let app = launch()
        let title = app.textFields["capture-title"]
        title.tap(); title.typeText("Offline Markdown")
        let text = app.textViews["capture-text"]
        text.tap(); text.typeText("- [ ] **First line**\n\n## More")
        XCTAssertTrue(app.buttons["Done"].waitForExistence(timeout: 10))
        let keyboard = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        keyboard.name = "Capture Markdown with keyboard"; keyboard.lifetime = .keepAlways; add(keyboard)
        app.buttons["Done"].tap()
        XCTAssertFalse(app.keyboards.firstMatch.exists)
        XCUIDevice.shared.orientation = .landscapeRight
        let landscapeReady = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            app.windows.firstMatch.frame.width > app.windows.firstMatch.frame.height
        }, object: nil)
        let rotated = XCTWaiter.wait(for: [landscapeReady], timeout: 8) == .completed
        if rotated {
            // Input synthesis waits for the app to idle; an existence query can
            // return in the middle of the physical rotation animation.
            text.tap(); app.buttons["Done"].tap()
        }
        XCTAssertEqual(title.value as? String, "Offline Markdown")
        XCTAssertTrue((text.value as? String)?.contains("**First line**") == true)
        let landscape = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        landscape.name = "Capture Markdown in landscape"; landscape.lifetime = .keepAlways; add(landscape)
        XCUIDevice.shared.orientation = .portrait
        let save = app.buttons["Save"].firstMatch
        for _ in 0..<5 { if save.isHittable { break }; app.swipeUp() }
        save.tap()
        XCTAssertTrue(app.staticTexts["Added to Inbox"].waitForExistence(timeout: 10))
        shoot("Offline Markdown saved receipt")
        XCTAssertTrue(rotated, "Disable device Rotation Lock and repeat the landscape check; the Markdown save was verified")
    }

    func testTwoImagesHaveIndependentTitles() {
        let app = launch(images: true)
        if app.buttons["Done"].exists { app.buttons["Done"].tap() }
        let titles = app.textFields.matching(identifier: "capture-attachment-title")
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in titles.count == 2 }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 10), .completed)
        for (index, name) in ["Blue PNG", "Blue JPEG"].enumerated() {
            let field = titles.element(boundBy: index)
            for _ in 0..<4 { if field.isHittable { break }; app.swipeDown() }
            field.tap()
            let old = field.value as? String ?? ""
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: old.count) + name)
            XCTAssertEqual(field.value as? String, name, "The entire image title must be replaced before saving")
            if app.buttons["Done"].exists { app.buttons["Done"].tap() }
            XCTAssertFalse(app.keyboards.firstMatch.exists, "Done must dismiss the image-title keyboard")
        }
        shoot("Two independently titled image previews")
        let save = app.buttons["Save"].firstMatch
        for _ in 0..<5 { if save.isHittable { break }; app.swipeUp() }
        save.tap()
        XCTAssertTrue(app.staticTexts["Added 2 files to Inbox"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Blue PNG.png"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Blue JPEG.jpeg"].waitForExistence(timeout: 10))
        shoot("Two separate saved image files")
    }

    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<6 { if element.exists && element.isHittable { return }; app.swipeUp() }
    }

    private func save(_ app: XCUIApplication) {
        if app.buttons["Done"].exists { app.buttons["Done"].tap() }
        let save = app.buttons["Save"].firstMatch
        reveal(save, in: app)
        save.tap()
    }

    /// The save receipt that stays on the capture card (the toast fades in 3 s, which a
    /// slower physical device can miss entirely between launch and the first query).
    private func receipt(_ app: XCUIApplication, _ text: String) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label == %@", text)).firstMatch
    }

    private func recentRow(_ app: XCUIApplication, containing text: String) -> XCUIElement {
        app.buttons.matching(identifier: "recent-capture")
            .matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    func testTypingATagNarrowsToExistingTagsAndReturnPicksOne() {
        let app = launch(catalog: true)
        if app.buttons["Done"].exists { app.buttons["Done"].tap() }
        let organize = app.buttons.containing(NSPredicate(format: "label BEGINSWITH %@", "Organize ·")).firstMatch
        reveal(organize, in: app)
        organize.tap()
        let search = app.textFields["capture-tag-search"]
        reveal(search, in: app)
        search.tap()
        search.typeText("pro")

        let suggestions = app.buttons.matching(identifier: "tag-suggestion")
        XCTAssertTrue(app.buttons["Tag Programming"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Tag Projects"].exists)
        XCTAssertEqual(suggestions.count, 2, "Only tags matching “pro” remain")
        XCTAssertFalse(app.buttons["Tag Cooking"].exists)
        XCTAssertTrue(app.buttons["create-capture-tag"].exists, "A genuinely new tag can still be created")
        shoot("Tag search narrowed to pro")

        search.typeText("ject")
        XCTAssertEqual(suggestions.count, 1)
        XCTAssertFalse(app.buttons["create-capture-tag"].exists, "“project” is the existing Projects, not a new tag")
        search.typeText("\n")
        XCTAssertTrue(app.buttons["Tag Projects, selected"].waitForExistence(timeout: 5),
                      "Return picks the existing tag")
        // Empty again: the simulator reports the placeholder as the value, a device nil.
        let cleared = (search.value as? String).map { $0.isEmpty || $0 == "Find or add a tag" } ?? true
        XCTAssertTrue(cleared, "The search clears after picking: \(String(describing: search.value))")
        shoot("Existing tag picked with Return")
    }

    /// Filing into a work queue offers where the work belongs, every link optional.
    func testFilingIntoFeaturesOffersOptionalLinks() {
        let app = launch(catalog: true)
        let text = app.textViews["capture-text"]
        text.tap(); text.typeText("Phone feature")
        app.buttons["Done"].tap()
        let organize = app.buttons.containing(NSPredicate(format: "label BEGINSWITH %@", "Organize ·")).firstMatch
        reveal(organize, in: app)
        organize.tap()
        let destination = app.buttons["Destination"]
        reveal(destination, in: app)
        XCTAssertFalse(app.buttons["work-link-project"].exists, "Not for an ordinary folder")
        destination.tap()
        XCTAssertTrue(app.buttons["Features"].waitForExistence(timeout: 5))
        app.buttons["Features"].tap()
        let project = app.buttons["work-link-project"]
        XCTAssertTrue(project.waitForExistence(timeout: 5), "A queue offers a project")
        XCTAssertTrue(app.buttons["work-link-milestone"].exists, "…and a milestone, for a feature")
        reveal(project, in: app)
        shoot("mobile-capture-feature-links")
        save(app)
        XCTAssertTrue(app.staticTexts["Added to Features"].waitForExistence(timeout: 10))
    }

    func testSavingStraightToAFolderSaysWhereItWent() {
        let app = launch(catalog: true)
        let title = app.textFields["capture-title"]
        title.tap(); title.typeText("Article Name")
        let text = app.textViews["capture-text"]
        text.tap(); text.typeText("Worth keeping")
        app.buttons["Done"].tap()
        let organize = app.buttons.containing(NSPredicate(format: "label BEGINSWITH %@", "Organize ·")).firstMatch
        reveal(organize, in: app)
        organize.tap()
        let destination = app.buttons["Destination"]
        reveal(destination, in: app)
        destination.tap()
        XCTAssertTrue(app.buttons["For Reference"].waitForExistence(timeout: 5))
        app.buttons["For Reference"].tap()
        save(app)

        XCTAssertTrue(app.staticTexts["Added to For Reference"].waitForExistence(timeout: 10),
                      "The receipt names the folder, not the Inbox")
        XCTAssertFalse(app.staticTexts["Added to Inbox"].exists)
        XCTAssertTrue(app.staticTexts["Recently Added"].waitForExistence(timeout: 10))
        let row = recentRow(app, containing: "Article Name")
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        XCTAssertTrue(row.label.contains("For Reference"), "The row shows its destination: \(row.label)")
        XCTAssertFalse(row.label.contains("Needs filing"))
        XCTAssertFalse(app.descendants(matching: .any)["recent-needs-filing-count"].exists,
                       "A capture with a destination is not counted as waiting")
        shoot("Recently Added shows For Reference")
    }

    func testAnInboxCaptureCanBeTaggedAndFiledFromRecentlyAdded() {
        let app = launch(catalog: true)
        let title = app.textFields["capture-title"]
        title.tap(); title.typeText("Loose thought")
        let text = app.textViews["capture-text"]
        text.tap(); text.typeText("File me later")
        save(app)
        XCTAssertTrue(app.staticTexts["Added to Inbox"].waitForExistence(timeout: 10))
        let row = recentRow(app, containing: "Loose thought")
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        XCTAssertTrue(row.label.contains("Needs filing"), "Unplaced captures say so: \(row.label)")
        XCTAssertTrue(app.descendants(matching: .any)["recent-needs-filing-count"].exists)

        reveal(row, in: app)
        row.tap()
        XCTAssertTrue(app.navigationBars["In the Inbox"].waitForExistence(timeout: 5))
        let search = app.textFields["capture-tag-search"]
        search.tap(); search.typeText("photo\n")
        XCTAssertTrue(app.buttons["Tag Photography, selected"].waitForExistence(timeout: 5))
        app.buttons["file-into-Ideas"].tap()
        shoot("Inbox capture tagged and filed")
        app.buttons["recent-capture-confirm"].tap()

        XCTAssertTrue(app.staticTexts["Filing to Ideas"].waitForExistence(timeout: 10))
        let filing = recentRow(app, containing: "Loose thought")
        let moved = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", "Ideas"), object: filing)
        XCTAssertEqual(XCTWaiter.wait(for: [moved], timeout: 10), .completed, "Row now shows its destination")
        XCTAssertFalse(filing.label.contains("Needs filing"))
    }

    // MARK: App Intents (via IntentTestHarness) and deep links

    func testQuickCaptureIntentLandsInTheInbox() {
        let app = launch(catalog: true, intent: "quick|Intent quick thought")
        XCTAssertTrue(receipt(app, "Added to Inbox").waitForExistence(timeout: 20))
        let row = recentRow(app, containing: "Intent quick thought")
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        XCTAssertTrue(row.label.contains("Needs filing"), row.label)
        shoot("Quick Capture intent in Recently Added")
    }

    func testCaptureIdeaIntentIsFiledAsAnIdea() {
        let app = launch(catalog: true, intent: "idea|Intent idea")
        XCTAssertTrue(receipt(app, "Added to Ideas").waitForExistence(timeout: 20))
        let row = recentRow(app, containing: "Intent idea")
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        XCTAssertTrue(row.label.contains("Ideas"), row.label)
        XCTAssertFalse(row.label.contains("Needs filing"))
    }

    func testAddToFolderIntentResolvesATypedFolder() {
        let app = launch(catalog: true, intent: "folder|reference|Intent article")
        XCTAssertTrue(receipt(app, "Added to For Reference").waitForExistence(timeout: 20),
                      "“reference” resolves to the published For Reference folder")
        let row = recentRow(app, containing: "Intent article")
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        XCTAssertTrue(row.label.contains("For Reference"), row.label)
    }

    func testTaggedQuickCaptureUsesExistingAndNewTags() {
        let app = launch(catalog: true, intent: "tags|pro,Gardening|Intent tagged thought")
        XCTAssertTrue(receipt(app, "Added to Inbox").waitForExistence(timeout: 20))
        // “Gardening” was new: it is in the catalog now, ready to pick next time.
        let organize = app.buttons.containing(NSPredicate(format: "label BEGINSWITH %@", "Organize ·")).firstMatch
        reveal(organize, in: app)
        organize.tap()
        let search = app.textFields["capture-tag-search"]
        // The save receipt can shift layout under the first tap; open it once more if so.
        if search.waitForExistence(timeout: 3) == false { organize.tap() }
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        reveal(search, in: app)
        search.tap(); search.typeText("gardening")
        XCTAssertTrue(app.buttons["Tag Gardening"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["create-capture-tag"].exists, "Gardening exists now; it must not be offered as new")
    }

    func testNewIdeaLinkOpensCaptureInIdeaMode() {
        let app = launch(catalog: true, url: "betterworkspace-mobile://capture?kind=idea")
        let organize = app.buttons.containing(NSPredicate(format: "label BEGINSWITH %@", "Organize · New idea")).firstMatch
        XCTAssertTrue(organize.waitForExistence(timeout: 10), "The New Idea widget/link opens in idea mode")
        let text = app.textViews["capture-text"]
        text.tap(); text.typeText("Linked idea")
        save(app)
        XCTAssertTrue(app.staticTexts["Added to Ideas"].waitForExistence(timeout: 10))
        let row = recentRow(app, containing: "Linked idea")
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        XCTAssertTrue(row.label.contains("Ideas"), row.label)
        XCTAssertTrue(app.buttons.containing(NSPredicate(format: "label BEGINSWITH %@", "Organize · Inbox")).firstMatch.exists,
                      "Idea mode applies to that one save")
    }

    func testURLWithoutTitleUsesHostFilenameOffline() {
        let app = launch()
        app.buttons["Add link"].tap()
        let url = app.textFields["capture-url"]
        url.tap(); url.typeText("https://example.com/bw-capture-qa")
        app.buttons["Done"].tap()
        XCTAssertFalse(app.keyboards.firstMatch.exists, "Done must dismiss the URL keyboard")
        let save = app.buttons["Save"].firstMatch
        for _ in 0..<5 { if save.isHittable { break }; app.swipeUp() }
        save.tap()
        XCTAssertTrue(app.staticTexts["Added to Inbox"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["example.com.md"].waitForExistence(timeout: 10))
        shoot("Untitled URL saved using host filename")
    }
}

/// Real transport checks deliberately create only UUID-named QA captures. The Mac
/// validation must inspect their exact names, never sweep or delete Inbox content.
final class PhysicalCaptureTransportUITests: XCTestCase {
    private func receipt(_ app: XCUIApplication, _ text: String) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label == %@", text)).firstMatch
    }

    private func launchCapture() throws -> XCUIApplication {
        #if targetEnvironment(simulator)
        throw XCTSkip("Requires a physical device with iCloud Drive.")
        #else
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["-BWInitialURL", "betterworkspace-mobile://capture"]
        app.launch()
        XCTAssertTrue(app.staticTexts["iCloud · Better Workspace"].waitForExistence(timeout: 45),
                      "The real shared Inbox must resolve before a transport test saves")
        return app
        #endif
    }

    func testURLAndMarkdownRouteThroughRealInboxToRead() throws {
        let app = try launchCapture()
        let device = UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"
        let marker = "BW-QA-device-link-" + device + "-" + UUID().uuidString
        print("DEVICE TRANSPORT FILE -> " + marker + ".md")
        let title = app.textFields["capture-title"]
        title.tap(); title.typeText(marker)
        XCTAssertEqual(title.value as? String, marker, "Verify the complete title arrived before saving")
        app.buttons["Add link"].tap()
        let link = app.textFields["capture-url"]
        link.tap(); link.typeText("https://example.com/bw-device-capture-qa")
        XCTAssertEqual(link.value as? String, "https://example.com/bw-device-capture-qa")
        let note = app.textViews["capture-text"]
        note.tap(); note.typeText("- [ ] **Device transport QA**\n\n## Notes")
        XCTAssertEqual(note.value as? String, "- [ ] **Device transport QA**\n\n## Notes",
                       "Verify device input arrived before testing transport")
        app.buttons["Done"].tap()
        app.buttons.containing(NSPredicate(format: "label BEGINSWITH %@", "Organize ·")).firstMatch.tap()
        let destination = app.buttons["Destination"]
        for _ in 0..<5 { if destination.isHittable { break }; app.swipeUp() }
        destination.tap()
        // Recently used folders are listed first; the rest are under More.
        if app.buttons["To Read"].waitForExistence(timeout: 20) == false, app.buttons["More"].exists {
            app.buttons["More"].tap()
        }
        XCTAssertTrue(app.buttons["To Read"].waitForExistence(timeout: 10),
                      "The Mac must publish the actual To Read destination")
        app.buttons["To Read"].tap()
        let save = app.buttons["Save"].firstMatch
        for _ in 0..<5 { if save.isHittable { break }; app.swipeUp() }
        save.tap()
        XCTAssertTrue(receipt(app, "Added to To Read").waitForExistence(timeout: 15))
        let routed = app.buttons.matching(identifier: "recent-capture")
            .matching(NSPredicate(format: "label CONTAINS %@", marker)).firstMatch
        XCTAssertTrue(routed.waitForExistence(timeout: 10))
        XCTAssertTrue(routed.label.contains("To Read"), "Recently Added shows the requested folder: \(routed.label)")
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "Real Inbox capture with To Read routing"; shot.lifetime = .keepAlways; add(shot)
        // A visible saved receipt proves the local save. Mac-side file and content
        // readback separately proves iCloud delivery and the classification intent.
    }
}

/// The return leg of the real round trip: after the Mac files a capture, the phone's
/// Recently Added shows it as filed rather than waiting. Opt-in: pass the capture's
/// name as `TEST_RUNNER_BW_QA_FILED_CAPTURE` (xcodebuild forwards `TEST_RUNNER_` vars).
final class PhysicalFiledStateUITests: XCTestCase {
    func testFiledCaptureShowsItsFolderOnThePhone() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Requires a physical device with iCloud.")
        #else
        guard let name = ProcessInfo.processInfo.environment["BW_QA_FILED_CAPTURE"], name.isEmpty == false else {
            throw XCTSkip("Set TEST_RUNNER_BW_QA_FILED_CAPTURE to a capture the Mac has filed.")
        }
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-BWInitialURL", "betterworkspace-mobile://capture"]
        app.launch()
        let row = app.buttons.matching(identifier: "recent-capture")
            .matching(NSPredicate(format: "label CONTAINS %@", name)).firstMatch
        for _ in 0..<6 where row.exists == false { app.swipeUp() }
        XCTAssertTrue(row.waitForExistence(timeout: 30), "The capture is in Recently Added")
        // The Inbox poll (15 s) and the Mac's index decide this; allow a few rounds.
        let filed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            row.label.contains("To Read") && row.label.contains("Filing when") == false
                && row.label.contains("Needs filing") == false
        }, object: nil)
        let result = XCTWaiter.wait(for: [filed], timeout: 90)
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "Recently Added after the Mac filed it"; shot.lifetime = .keepAlways; add(shot)
        XCTAssertEqual(result, .completed, "Still: \(row.label)")
        #endif
    }
}

/// Opt-in hardware check. Run after the ordinary composer and transport checks:
/// an unresolved iOS permission alert can block subsequent automation sessions.
final class PhysicalCameraCaptureUITests: XCTestCase {
    func testPhysicalCameraImageCanBeTitledAndSaved() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Requires a physical camera.")
        #else
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-mobileCloudDisabled", "YES", "-BWTestCaptureInboxID", "camera-" + UUID().uuidString,
                               "-BWInitialURL", "betterworkspace-mobile://capture"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Test Inbox"].waitForExistence(timeout: 20))
        if app.buttons["Done"].exists { app.buttons["Done"].tap() }
        let camera = app.buttons["Camera"].firstMatch
        for _ in 0..<5 { if camera.isHittable { break }; app.swipeUp() }
        camera.tap()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        if springboard.alerts.firstMatch.waitForExistence(timeout: 3) {
            throw XCTSkip("Camera permission needs approval by the device owner; no permission was changed")
        }
        let shutter = app.buttons["PhotoCapture"].firstMatch
        XCTAssertTrue(shutter.waitForExistence(timeout: 12)); shutter.tap()
        let use = app.buttons["Use Photo"].firstMatch
        XCTAssertTrue(use.waitForExistence(timeout: 12)); use.tap()
        let title = app.textFields["capture-attachment-title"].firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 12))
        for _ in 0..<5 { if title.isHittable { break }; app.swipeDown() }
        // Put the cursor at the end: a plain tap can land mid-title, and the deletes
        // then left part of the old name ("Camera QAat 11 29 59 AM").
        title.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.5)).tap()
        let old = title.value as? String ?? ""
        title.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: old.count) + "Camera QA")
        XCTAssertEqual(title.value as? String, "Camera QA")
        app.buttons["Done"].tap()
        XCTAssertFalse(app.keyboards.firstMatch.exists)
        let save = app.buttons["Save"].firstMatch
        for _ in 0..<5 { if save.isHittable { break }; app.swipeUp() }
        save.tap()
        XCTAssertTrue(app.staticTexts["Added to Inbox"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["Camera QA.jpg"].waitForExistence(timeout: 15))
        #endif
    }
}

/// Share → Better Workspace from Safari, on a physical device with iCloud. Saves a
/// uniquely named link to To Read; the Mac files it. Opt-in by running on hardware.
final class PhysicalShareExtensionUITests: XCTestCase {
    func testSharingAPageFromSafariSavesItToTheChosenFolder() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Requires a physical device with iCloud.")
        #else
        continueAfterFailure = false
        let marker = "bw-share-qa-" + UUID().uuidString.prefix(8).lowercased()
        print("SHARE QA MARKER -> " + marker)
        let safari = XCUIApplication(bundleIdentifier: "com.apple.mobilesafari")
        safari.launch()
        safari.open(URL(string: "https://example.com/?" + marker)!)
        XCTAssertTrue(safari.wait(for: .runningForeground, timeout: 20))
        Thread.sleep(forTimeInterval: 4)

        // Safari's share control: a toolbar button on older iOS; inside the Page Menu
        // (MoreMenuButton) on iOS 26 and later.
        let share = safari.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == 'ShareButton' OR label == 'Share'")).firstMatch
        if share.waitForExistence(timeout: 5) == false {
            let pageMenu = safari.buttons.matching(NSPredicate(format: "identifier == 'MoreMenuButton' OR label == 'Page Menu'")).firstMatch
            if pageMenu.exists { pageMenu.tap() }
        }
        XCTAssertTrue(share.waitForExistence(timeout: 8), "Safari's Share control: \(safari.debugDescription.prefix(3000))")
        share.tap()

        // The share sheet lists apps in a row (after AirDrop, Messages, Mail…); scroll it
        // left, and fall back to its trailing “More”. The contacts row above is never touched.
        let target = safari.descendants(matching: .any).matching(NSPredicate(format: "label == 'Better Workspace'")).firstMatch
        let appRowAnchor = safari.cells["Messages"].firstMatch
        if target.waitForExistence(timeout: 5) == false, appRowAnchor.waitForExistence(timeout: 5) {
            // Drag along the row's fixed screen position; cells scroll away under us.
            let rowY = appRowAnchor.frame.midY
            let width = safari.frame.width
            let origin = safari.coordinate(withNormalizedOffset: .zero)
            for _ in 0..<5 where target.exists == false || target.isHittable == false {
                origin.withOffset(CGVector(dx: width * 0.85, dy: rowY))
                    .press(forDuration: 0.05, thenDragTo: origin.withOffset(CGVector(dx: width * 0.15, dy: rowY)))
                Thread.sleep(forTimeInterval: 0.6)
            }
        }
        if target.exists == false {
            let more = safari.cells.matching(NSPredicate(format: "label == 'More'")).firstMatch
            if more.waitForExistence(timeout: 3) { more.tap() }
        }
        XCTAssertTrue(target.waitForExistence(timeout: 10), "Better Workspace is offered in the share sheet")
        let sheet = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); sheet.name = "share-sheet-offers-better-workspace"; sheet.lifetime = .keepAlways; add(sheet)
        target.tap()

        // The extension's own form, hosted by Safari.
        let save = safari.buttons["share-save"]
        XCTAssertTrue(save.waitForExistence(timeout: 15), "The Better Workspace share form opens")
        let title = safari.textFields["share-title"]
        if title.exists { title.tap(); title.typeText(marker) }
        let destination = safari.descendants(matching: .any)["share-destination"].firstMatch
        if destination.exists {
            destination.tap()
            let toRead = safari.buttons["To Read"].firstMatch
            if toRead.waitForExistence(timeout: 5) { toRead.tap() }
        }
        let form = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); form.name = "share-extension-form"; form.lifetime = .keepAlways; add(form)
        save.tap()
        let saved = safari.descendants(matching: .any)["share-saved"].firstMatch
        let closed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in saved.exists || save.exists == false }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [closed], timeout: 20), .completed, "Saved and closed")
        if saved.exists { print("SHARE RECEIPT -> " + saved.label) }
        #endif
    }
}
