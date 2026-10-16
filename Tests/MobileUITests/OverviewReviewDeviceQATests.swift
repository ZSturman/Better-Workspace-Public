import XCTest

/// Real iCloud round trips for Overview's "One thing to review", one step per test, on a
/// physical iPhone or iPad against the running Mac (see docs/OVERVIEW_FOCUS.md, "Device
/// QA"). The driving script creates `BW QA <id> …` files in a To folder, quits and starts
/// the Mac app between steps, and checks the Mac's files. Without `TEST_RUNNER_BWQA_ID`
/// every step skips, so no suite run ever decides anything.
///
/// - `TEST_RUNNER_BWQA_TITLE`: the review item's file name.
/// - `TEST_RUNNER_BWQA_DECISION`: `done` or `archive` (for the decide step).
/// - `TEST_RUNNER_BWQA_EXPECT`: text the Mac's refusal must contain.
final class OverviewReviewDeviceQATests: XCTestCase {
    private var title = ""
    private var environment: [String: String] { ProcessInfo.processInfo.environment }
    private let pendingPrefix = "Decision saved on this phone"

    override func setUpWithError() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Physical-device review QA step: the Simulator has no iCloud account.")
        #else
        guard let id = environment["BWQA_ID"], !id.isEmpty else {
            throw XCTSkip("Review QA step: set TEST_RUNNER_BWQA_ID to run it.")
        }
        guard let value = environment["BWQA_TITLE"], value.hasPrefix("BW QA \(id)") else {
            throw XCTSkip("Review QA step: TEST_RUNNER_BWQA_TITLE must name a BW QA \(id) item.")
        }
        title = value
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        #endif
    }

    // MARK: Helpers

    private func shoot(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name; shot.lifetime = .keepAlways; add(shot)
    }

    private func signal(_ word: String) { print("BWQA-SIGNAL \(word)") }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.workspaceDestination("Overview").waitForExistence(timeout: 30))
        app.workspaceDestination("Overview").tap()
        return app
    }

    private var refreshButton: (XCUIApplication) -> XCUIElement = { $0.buttons["Refresh workspace index"] }

    /// Refresh from Overview and wait for CloudKit to answer with a new sync time.
    private func syncNow(_ app: XCUIApplication) {
        app.workspaceDestination("Overview").tap()
        let refresh = refreshButton(app)
        XCTAssertTrue(refresh.waitForExistence(timeout: 15))
        let before = refresh.value as? String ?? ""
        refresh.tap()
        let synced = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value BEGINSWITH 'Synced' AND value != %@", before), object: refresh)
        XCTAssertEqual(XCTWaiter.wait(for: [synced], timeout: 90), .completed, "CloudKit did not answer: \(refresh.value ?? "")")
    }

    /// Ending a UI test kills the app; wait until the outbox has handed the decision to CloudKit.
    private func waitUntilSent(_ app: XCUIApplication) {
        let refresh = refreshButton(app)
        let sent = XCTNSPredicateExpectation(predicate: NSPredicate(format: "NOT (value CONTAINS 'waiting to send')"), object: refresh)
        XCTAssertEqual(XCTWaiter.wait(for: [sent], timeout: 90), .completed, "The decision never left the device: \(refresh.value ?? "")")
    }

    private func cardTitle(_ app: XCUIApplication) -> String? {
        let element = app.staticTexts["overview.toReview.title"]
        return element.exists ? element.label : nil
    }

    private func pending(_ app: XCUIApplication) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", pendingPrefix)).firstMatch
    }

    private func scrollToTop(_ app: XCUIApplication) {
        for _ in 0..<4 where app.staticTexts["overview.toReview"].isHittable == false { app.swipeDown() }
    }

    /// Syncs until `condition` holds. CloudKit queries lag behind writes.
    private func syncUntil(_ app: XCUIApplication, _ what: String, timeout: TimeInterval = 300,
                           _ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            syncNow(app)
            scrollToTop(app)
            if condition() { return }
            Thread.sleep(forTimeInterval: 10)
        } while Date() < deadline
        XCTFail("\(what) never happened; the card shows “\(cardTitle(app) ?? "no item")”")
    }

    // MARK: Steps

    /// The Mac's published review item reaches this device.
    func testOR1_ShowsTheItem() {
        let app = launch()
        syncUntil(app, "“\(title)” on the card") { cardTitle(app) == title }
        shoot("review-item-arrived")
    }

    /// Decide the item; the decision waits as a draft until the outbox sends it.
    func testOR2_DecideTheItem() throws {
        let app = launch()
        syncUntil(app, "“\(title)” on the card", timeout: 120) { cardTitle(app) == title }
        switch environment["BWQA_DECISION"] {
        case "archive":
            app.buttons["overview.toReview.more"].tap()
            app.buttons["Archive…"].tap()
            app.buttons["Move to Reviewed/Archive"].tap()
        case "done":
            app.buttons["overview.toReview.primary"].tap()
            app.buttons["Move to Reviewed/Done"].tap()
        default:
            throw XCTSkip("Set TEST_RUNNER_BWQA_DECISION to done or archive.")
        }
        XCTAssertTrue(pending(app).waitForExistence(timeout: 10), "The card should say the decision is waiting for the Mac")
        XCTAssertNil(cardTitle(app), "A decided item must not be offered again")
        shoot("review-decision-pending")
        waitUntilSent(app)
        signal("sent")
    }

    /// With the Mac away, a relaunch still holds the decision and does not offer the item.
    func testOR3_PendingSurvivesRelaunch() {
        let app = launch()
        syncNow(app)
        scrollToTop(app)
        XCTAssertTrue(pending(app).waitForExistence(timeout: 10), "The pending decision did not survive relaunch")
        XCTAssertNotEqual(cardTitle(app), title)
        shoot("review-pending-after-relaunch")
    }

    /// The Mac applied the decision: the draft settles and the card moves on.
    func testOR4_ConfirmedAndMovedOn() {
        let app = launch()
        syncUntil(app, "the Mac's confirmation") { cardTitle(app) != title && pending(app).exists == false }
        print("BWQA-NEXT \(cardTitle(app) ?? "none")")
        shoot("review-confirmed-next")
    }

    /// The Mac refused the decision: the device explains it and the draft can be discarded.
    func testOR5_RefusalExplainsAndDiscards() {
        let app = launch()
        let review = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Review “\(title)”")).firstMatch
        syncUntil(app, "the Mac's refusal") {
            for _ in 0..<6 where review.exists == false { app.swipeUp() }
            return review.exists
        }
        review.tap()
        let expected = environment["BWQA_EXPECT"] ?? ""
        let message = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", expected)).firstMatch
        XCTAssertTrue(message.waitForExistence(timeout: 10), "The refusal should say “\(expected)”")
        XCTAssertTrue(app.staticTexts["Nothing was moved. Discard this decision; the item comes back to Overview when it is due."].exists)
        shoot("review-refusal")
        app.buttons["Discard saved draft"].tap()
        app.workspaceDestination("Overview").tap()
        scrollToTop(app)
        XCTAssertFalse(pending(app).exists, "Discarding the refused decision should clear the pending state")
        shoot("review-refusal-discarded")
    }
}
