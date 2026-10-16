import XCTest

/// Real iCloud round trips between a physical iPhone/iPad and a running Mac, one step
/// per test. A script runs the steps in order and checks the Mac's files between them
/// (see docs/DEVICE_SYNC_QA.md). Every item is named `BW QA <id>`; without
/// `TEST_RUNNER_BWQA_ID` each step skips, so no suite run ever creates one.
final class DeviceSyncUITests: XCTestCase {
    private var id = ""
    private var base: String { "BW QA \(id)" }

    override func setUpWithError() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Physical-device sync step: the Simulator has no iCloud account.")
        #else
        guard let value = ProcessInfo.processInfo.environment["BWQA_ID"], !value.isEmpty else {
            throw XCTSkip("Sync QA step: set TEST_RUNNER_BWQA_ID to run it.")
        }
        id = value
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        #endif
    }

    // MARK: Helpers

    private func shoot(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name; shot.lifetime = .keepAlways; add(shot)
    }

    /// Printed lines reach the driving script while the test is still running.
    private func signal(_ word: String) { print("BWQA-SIGNAL \(word)") }

    private func launch(_ arguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = arguments
        app.launch()
        XCTAssertTrue(app.workspaceDestination("Overview").waitForExistence(timeout: 30))
        return app
    }

    private func label(_ app: XCUIApplication, _ prefix: String) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", prefix)).firstMatch
    }

    private func row(_ app: XCUIApplication, _ title: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", title)).firstMatch
    }

    /// Refresh from Overview and wait for CloudKit to answer.
    private func syncNow(_ app: XCUIApplication) {
        if app.keyboards.count > 0, app.buttons["Close"].exists { app.buttons["Close"].tap() }
        let overview = app.workspaceDestination("Overview")
        overview.tap()
        let refresh = app.buttons["Refresh workspace index"]
        if !refresh.waitForExistence(timeout: 5) { overview.tap() }
        XCTAssertTrue(refresh.waitForExistence(timeout: 15))
        let before = refresh.value as? String ?? ""
        refresh.tap()
        // A new sync time, not merely "Synced": a refresh that silently does nothing
        // leaves the old time in place.
        let synced = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value BEGINSWITH 'Synced' AND value != %@", before), object: refresh)
        XCTAssertEqual(XCTWaiter.wait(for: [synced], timeout: 90), .completed, "CloudKit did not answer: \(refresh.value ?? "")")
    }

    private func search(_ app: XCUIApplication, _ text: String) {
        workRoot(app)
        let field = app.searchFields["Find work"]
        if !field.waitForExistence(timeout: 5) { workRoot(app) }
        if !field.waitForExistence(timeout: 5) { app.swipeDown() }
        XCTAssertTrue(field.waitForExistence(timeout: 10), "Work has no search field")
        field.tap()
        if let current = field.value as? String, !current.isEmpty, current != "Find work" {
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count))
        }
        field.typeText(text + "\n") // submit, so the keyboard no longer covers the tab bar
    }

    /// Syncs until a row titled `title` shows up in Work and, opened, shows every one of
    /// `expecting` (LabeledContent prefixes such as "Status, Completed"). CloudKit queries
    /// lag behind writes, so a first download can be older than the Mac's files.
    @discardableResult
    private func openWhenSynced(_ app: XCUIApplication, _ title: String, expecting: [String] = [],
                                timeout: TimeInterval = 300) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            syncNow(app)
            search(app, title)
            let match = row(app, title)
            if match.waitForExistence(timeout: 5) {
                match.tap()
                if expecting.allSatisfy({ label(app, $0).waitForExistence(timeout: 5) }) { return true }
                workRoot(app)
            }
            Thread.sleep(forTimeInterval: 10)
        } while Date() < deadline
        XCTFail("“\(title)” with \(expecting) never reached this device")
        return false
    }

    private func createWork(_ app: XCUIApplication, title: String, dueDate: Bool) {
        app.workspaceDestination("Work").tap()
        let add = app.buttons["New work"]
        XCTAssertTrue(add.waitForExistence(timeout: 10)); add.tap()
        let field = app.textFields["planning-title"]
        XCTAssertTrue(field.waitForExistence(timeout: 10)); field.tap(); field.typeText(title)
        if dueDate {
            if app.buttons["Done"].exists { app.buttons["Done"].tap() }
            // The due date is an advanced option.
            let more = app.buttons["More Options"].firstMatch
            for _ in 0..<4 where !more.exists || !more.isHittable { app.swipeUp() }
            more.tap()
            let due = app.switches["Due date"].firstMatch
            for _ in 0..<4 where !due.exists || !due.isHittable { app.swipeUp() }
            due.tap()
            if due.value as? String == "0" { due.switches.firstMatch.tap() }
            XCTAssertEqual(due.value as? String, "1")
        }
        app.buttons["Save"].tap()
        XCTAssertTrue(app.navigationBars["Work"].waitForExistence(timeout: 10))
    }

    private func editTitle(_ app: XCUIApplication, appending suffix: String) {
        app.buttons["Edit"].tap()
        let field = app.textFields["planning-title"]
        XCTAssertTrue(field.waitForExistence(timeout: 10)); field.tap()
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        field.typeText(suffix)
        app.buttons["Save"].tap()
    }

    private func confirmDelete(_ app: XCUIApplication) {
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            let buttons = app.buttons.matching(NSPredicate(format: "label == 'Delete' AND identifier != 'work-delete'"))
                .allElementsBoundByIndex.filter(\.isHittable)
            if let last = buttons.last { last.tap(); return }
            Thread.sleep(forTimeInterval: 0.25)
        }
        XCTFail("No delete confirmation appeared")
    }

    /// The Work list itself, not a page pushed on it (an iPad section keeps its place).
    private func workRoot(_ app: XCUIApplication) {
        let work = app.workspaceDestination("Work")
        work.tap()
        for _ in 0..<4 {
            let back = app.navigationBars.buttons["BackButton"].firstMatch
            guard back.exists, back.label == "Work" || back.label == "Back" else { break }
            back.tap()
        }
    }

    /// Pulls the page down from a plain row. The title allows text selection, so a press
    /// that starts on it selects text instead of pulling the list.
    private func pullToRefresh(_ app: XCUIApplication) {
        // Upper part of the page (the detail column on iPad): rows further down may not
        // be loaded on a task with a long description.
        let list = app.collectionViews.containing(.button, identifier: "work-toggle-completion").firstMatch
        if list.exists {
            list.swipeDown(velocity: .slow)
        } else {
            let start = app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.3))
            start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: 500)))
        }
    }

    private func lastSync(_ app: XCUIApplication) -> String {
        app.workspaceDestination("Overview").tap()
        let refresh = app.buttons["Refresh workspace index"]
        if !refresh.waitForExistence(timeout: 5) { app.workspaceDestination("Overview").tap() }
        return refresh.waitForExistence(timeout: 10) ? refresh.value as? String ?? "" : ""
    }

    /// Waits until the phone's outbox is empty, so ending the test (which kills the app)
    /// cannot strand a change.
    private func waitUntilSent(_ app: XCUIApplication) {
        app.workspaceDestination("Overview").tap()
        let refresh = app.buttons["Refresh workspace index"]
        if !refresh.waitForExistence(timeout: 5) { app.workspaceDestination("Overview").tap() }
        let sent = XCTNSPredicateExpectation(predicate: NSPredicate(format: "NOT (value CONTAINS 'waiting to send')"), object: refresh)
        XCTAssertEqual(XCTWaiter.wait(for: [sent], timeout: 90), .completed, "Changes never left the phone: \(refresh.value ?? "")")
    }

    /// Waits without letting the device auto-lock: a locked phone fails the next tap.
    /// Touches only the navigation bar, which does nothing on these screens.
    private func stayAwake(_ app: XCUIApplication, for seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            Thread.sleep(forTimeInterval: min(10, max(0, deadline.timeIntervalSinceNow)))
            app.navigationBars.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)).tap()
        }
    }

    // MARK: Steps

    /// Either device. Pulling a task's page down refreshes it (needs any synced task).
    func testQA0_PullingATaskPageRefreshes() {
        let app = launch(["-BWShowRefreshCount", "YES"])
        syncNow(app)
        let before = lastSync(app)
        print("BWQA-DIAG before \(before)")
        workRoot(app)
        let first = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Now · ' OR label CONTAINS 'Next · '")).firstMatch
        XCTAssertTrue(first.waitForExistence(timeout: 20)); first.tap()
        XCTAssertTrue(app.buttons["work-toggle-completion"].waitForExistence(timeout: 10) || app.buttons["Edit"].waitForExistence(timeout: 5))
        Thread.sleep(forTimeInterval: 2)
        pullToRefresh(app)
        let started = Date()
        var after = ""
        repeat {
            Thread.sleep(forTimeInterval: 10)
            after = lastSync(app)
            print("BWQA-DIAG +\(Int(Date().timeIntervalSince(started)))s \(after)")
            app.navigationBars.buttons["BackButton"].firstMatch.exists ? () : ()
        } while after.contains("refreshing") && Date().timeIntervalSince(started) < 180
        func count(_ value: String) -> Int { Int(value.components(separatedBy: "refreshes ").last?.components(separatedBy: " ").first ?? "") ?? -1 }
        XCTAssertGreaterThan(count(after), count(before), "Pulling the page did not ask for a refresh: \(before) → \(after)")
    }

    /// iPhone. Creates a dated task and a second one, then edits and completes the first
    /// at once — before the Mac has applied the creation, so the follow-up edits name the
    /// phone's placeholder path and must be resolved by ID.
    func testQA1_CreateEditAndCompleteBeforeTheMacSeesIt() {
        let app = launch()
        createWork(app, title: base, dueDate: true)
        createWork(app, title: base + " C", dueDate: false)
        search(app, base)
        let created = row(app, base)
        XCTAssertTrue(created.waitForExistence(timeout: 10)); created.tap()
        XCTAssertTrue(label(app, "Due, ").waitForExistence(timeout: 10))
        editTitle(app, appending: " edited")
        XCTAssertTrue(app.staticTexts[base + " edited"].waitForExistence(timeout: 10))
        app.buttons["work-toggle-completion"].tap()
        XCTAssertTrue(label(app, "Status, Completed").waitForExistence(timeout: 10))
        XCTAssertTrue(label(app, "Due, ").exists, "Completing dropped the due date")
        shoot("qa1-completed-on-phone")
        waitUntilSent(app)
        signal("QA1-DONE")
    }

    /// iPad. The phone's changes arrive through the Mac; reopening here goes back.
    func testQA2_IPadSeesThePhoneChangesAndReopens() {
        let app = launch()
        XCTAssertTrue(openWhenSynced(app, base + " edited", expecting: ["Status, Completed", "Due, "]))
        shoot("qa2-ipad-sees-completed")
        app.buttons["work-toggle-completion"].tap()
        XCTAssertTrue(label(app, "Status, Open").waitForExistence(timeout: 10))
        waitUntilSent(app)
        signal("QA2-DONE")
    }

    /// iPhone. An edit made on the Mac (title and stage) arrives, and every view that
    /// shows the item agrees.
    func testQA3_PhoneSeesTheMacEdit() {
        let app = launch()
        XCTAssertTrue(openWhenSynced(app, base + " mac", expecting: ["Stage, Now", "Status, Open", "Due, "]))
        shoot("qa3-phone-sees-mac-edit")
        search(app, base + " edited")
        XCTAssertFalse(row(app, base + " edited").waitForExistence(timeout: 3), "The old title is still listed")
        app.workspaceDestination("Overview").tap()
        XCTAssertTrue(app.descendants(matching: .any)["overview-progress"].waitForExistence(timeout: 10))
        signal("QA3-DONE")
    }

    /// iPad. Holds an edit screen open while the Mac changes the same record, then saves
    /// on the stale copy: the Mac must refuse it and the iPad must offer it for review.
    func testQA4_ConflictingEditsBecomeAReviewDraft() {
        let app = launch()
        XCTAssertTrue(openWhenSynced(app, base + " C"))
        signal("QA4-READY")
        stayAwake(app, for: 75) // the script edits the Mac file now
        editTitle(app, appending: " phone")
        XCTAssertTrue(app.staticTexts[base + " C phone"].waitForExistence(timeout: 10))
        let review = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Review “" + base + " C phone")).firstMatch
        let deadline = Date().addingTimeInterval(240)
        repeat {
            syncNow(app)
            workRoot(app)
            if review.waitForExistence(timeout: 5) { break }
            Thread.sleep(forTimeInterval: 10)
        } while Date() < deadline
        XCTAssertTrue(review.exists, "The refused edit never came back for review")
        shoot("qa4-review-offered")
        review.tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "changed on the Mac")).firstMatch.waitForExistence(timeout: 10))
        app.buttons["Discard saved draft"].tap()
        search(app, base + " C mac")
        XCTAssertTrue(row(app, base + " C mac").waitForExistence(timeout: 10), "The Mac's version is not what the iPad shows")
        signal("QA4-DONE")
    }

    /// iPad. Watches the item's page while another device deletes it.
    func testQA5_ADetailPageSaysWhenItsItemIsDeletedElsewhere() {
        let app = launch()
        XCTAssertTrue(openWhenSynced(app, base + " mac"))
        signal("QA5-WATCHING")
        let missing = app.descendants(matching: .any)["work-missing"]
        let deadline = Date().addingTimeInterval(480)
        while !missing.exists, Date() < deadline {
            // Pull to refresh, staying on this page: a slow, long drag, which a quick
            // swipe on iPad does not always register as.
            pullToRefresh(app)
            _ = missing.waitForExistence(timeout: 15)
        }
        if !missing.exists {
            // Tell a refresh that never ran from an index that still lists the item.
            shoot("qa5-page-still-shows-item")
            app.workspaceDestination("Overview").tap()
            let refresh = app.buttons["Refresh workspace index"]
            let synced = refresh.waitForExistence(timeout: 10) ? "\(refresh.value ?? "")" : "no refresh control"
            search(app, base + " mac")
            let listed = row(app, base + " mac").waitForExistence(timeout: 5)
            XCTFail("The page never noticed its item was deleted. Last sync: \(synced); still listed in Work: \(listed)")
            return
        }
        XCTAssertFalse(app.buttons["Edit"].isEnabled, "A deleted item can still be edited")
        XCTAssertFalse(app.buttons["work-delete"].exists)
        XCTAssertFalse(app.buttons["work-toggle-completion"].exists)
        shoot("qa5-detail-after-remote-delete")
        signal("QA5-DONE")
    }

    /// iPhone. Opens the item, waits while the script renames its file on the Mac, then
    /// deletes it from the stale path: the Mac must find it by ID and move it to the Trash.
    func testQA6_DeleteAfterTheMacMovedTheFile() {
        let app = launch()
        XCTAssertTrue(openWhenSynced(app, base + " mac"))
        signal("QA6-READY")
        stayAwake(app, for: 60) // the script renames the file now
        app.buttons["work-delete"].tap()
        confirmDelete(app)
        XCTAssertTrue(app.navigationBars["Work"].waitForExistence(timeout: 10))
        search(app, base + " mac")
        XCTAssertFalse(row(app, base + " mac").waitForExistence(timeout: 3))
        waitUntilSent(app)
        signal("QA6-DONE")
    }

    /// iPhone. The planning fixture, launched WITHOUT `-mobileCloudDisabled` on a signed-in
    /// device, must still never send anything. The script then checks the Mac.
    func testQA7_TheFixtureNeverReachesTheMac() {
        let app = launch(["-BWTestMobilePlanning", "YES", "-BWResetPlanningFixture", "YES"])
        createWork(app, title: base + " fixture", dueDate: false)
        XCTAssertTrue(row(app, base + " fixture").waitForExistence(timeout: 10))
        Thread.sleep(forTimeInterval: 20)
        app.terminate()
        signal("QA7-DONE")
    }

    /// iPhone. Deletes the item titled `TEST_RUNNER_BWQA_TITLE` (a leftover from an
    /// interrupted run), through the app so it reaches the Mac's Trash.
    func testQA9_DeleteALeftoverItem() throws {
        guard let title = ProcessInfo.processInfo.environment["BWQA_TITLE"], title.hasPrefix("BW QA ") else {
            throw XCTSkip("Set TEST_RUNNER_BWQA_TITLE to a BW QA item's title.")
        }
        let app = launch()
        XCTAssertTrue(openWhenSynced(app, title))
        app.buttons["work-delete"].tap()
        confirmDelete(app)
        XCTAssertTrue(app.navigationBars["Work"].waitForExistence(timeout: 10))
        waitUntilSent(app)
    }

    /// iPhone. Deleting a Notion-linked task (`TEST_RUNNER_BWQA_TITLE`, chosen by the
    /// person) is refused by the Mac: the task comes back with a draft to review, which
    /// is then discarded. The file never leaves the Workspace.
    func testQA13_DeletingANotionLinkedTaskIsRefused() throws {
        guard let title = ProcessInfo.processInfo.environment["BWQA_TITLE"], !title.isEmpty else {
            throw XCTSkip("Set TEST_RUNNER_BWQA_TITLE to a Notion-linked task the person chose.")
        }
        let app = launch()
        XCTAssertTrue(openWhenSynced(app, title))
        app.buttons["work-delete"].tap()
        confirmDelete(app)
        XCTAssertTrue(app.navigationBars["Work"].waitForExistence(timeout: 10))
        waitUntilSent(app)
        let review = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Review “" + title)).firstMatch
        let deadline = Date().addingTimeInterval(300)
        repeat {
            syncNow(app)
            workRoot(app)
            if review.waitForExistence(timeout: 5) { break }
            Thread.sleep(forTimeInterval: 10)
        } while Date() < deadline
        XCTAssertTrue(review.exists, "The refused delete never came back for review")
        shoot("qa13-notion-delete-refused")
        review.tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'Notion'")).firstMatch.waitForExistence(timeout: 10),
                      "The review does not say why")
        shoot("qa13-review-explains-notion")
        app.buttons["Discard saved draft"].tap()
        search(app, title)
        XCTAssertTrue(row(app, title).waitForExistence(timeout: 10), "The refused task is not back in Work")
        signal("QA13-DONE")
    }

    // MARK: Offline (a person switches Airplane Mode between steps)

    /// iPhone, online. Makes sure the Mac-created offline item is in the phone's cache.
    func testQA10_CacheTheOfflineItem() {
        let app = launch()
        XCTAssertTrue(openWhenSynced(app, base + " offline", expecting: ["Status, Open"]))
        signal("QA10-DONE")
    }

    /// iPhone in Airplane Mode. The cached index opens, an edit is saved, and both
    /// survive a relaunch while still offline.
    func testQA11_EditWhileOfflineAndRelaunch() {
        let app = launch()
        let refresh = app.buttons["Refresh workspace index"]
        XCTAssertTrue(refresh.waitForExistence(timeout: 15))
        refresh.tap()
        let offline = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value BEGINSWITH 'Offline'"), object: refresh)
        XCTAssertEqual(XCTWaiter.wait(for: [offline], timeout: 200), .completed, "Not reported offline: \(refresh.value ?? "")")
        search(app, base + " offline")
        let item = row(app, base + " offline")
        XCTAssertTrue(item.waitForExistence(timeout: 10), "The cached index does not have the item offline")
        item.tap()
        app.buttons["work-toggle-completion"].tap()
        XCTAssertTrue(label(app, "Status, Completed").waitForExistence(timeout: 10))
        shoot("qa11-completed-offline")
        app.terminate()
        let again = launch()
        search(again, base + " offline")
        let cached = row(again, base + " offline")
        XCTAssertTrue(cached.waitForExistence(timeout: 15), "Relaunch offline lost the item")
        cached.tap()
        XCTAssertTrue(label(again, "Status, Completed").waitForExistence(timeout: 10), "Relaunch offline lost the edit")
        workRoot(again)
        XCTAssertTrue(again.staticTexts.containing(NSPredicate(format: "label CONTAINS 'waiting for the Mac'")).firstMatch.waitForExistence(timeout: 10))
        shoot("qa11-relaunched-offline")
        signal("QA11-DONE")
    }

    /// iPhone, back online. The offline edit leaves the phone.
    func testQA12_SendTheOfflineEditAfterReconnecting() {
        let app = launch()
        waitUntilSent(app)
        signal("QA12-DONE")
    }

    /// iPhone. Removes the conflict item once the test is over.
    func testQA8_CleanUpTheConflictItem() {
        let app = launch()
        XCTAssertTrue(openWhenSynced(app, base + " C mac"))
        app.buttons["work-delete"].tap()
        confirmDelete(app)
        XCTAssertTrue(app.navigationBars["Work"].waitForExistence(timeout: 10))
        waitUntilSent(app)
        signal("QA8-DONE")
    }
}
