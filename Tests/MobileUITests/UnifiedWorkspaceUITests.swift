import XCTest
import CryptoKit

/// Runs the normal shared editor in an owned, durable local workspace. This does
/// not claim cloud/pairing or the person's actual upgrade has been verified.
final class UnifiedWorkspaceUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false; XCUIDevice.shared.orientation = .portrait }
    override func tearDownWithError() throws { XCUIDevice.shared.orientation = .portrait }
    func testStandaloneSaveReopenAndLandscapeEditor() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-BWUnifiedFixture", UUID().uuidString]
        app.launch()
        defer { app.terminate() }
        let local = app.buttons["unified.welcome.local"]
        XCTAssertTrue(local.waitForExistence(timeout: 20)); local.tap()
        XCTAssertTrue(app.buttons["unified.new"].waitForExistence(timeout: 10)); app.buttons["unified.new"].tap()
        let title = app.textFields["unified.editor.title"]
        XCTAssertTrue(title.waitForExistence(timeout: 10)); title.tap(); title.typeText("Offline physical device task")
        let body = app.textViews["unified.editor.body"]
        body.tap(); body.typeText("Saved locally without a Mac connection.")
        app.buttons["unified.editor.save"].tap()
        let item = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'unified.item.'")).firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 10))
        shoot("unified-standalone-saved")
        app.terminate(); app.launch()
        XCTAssertTrue(item.waitForExistence(timeout: 15)); XCTAssertFalse(local.exists, "Welcome must stay completed after relaunch")
        item.tap()
        XCTAssertTrue(title.waitForExistence(timeout: 10))
        XCTAssertTrue(body.waitForExistence(timeout: 10))
        XCTAssertEqual(title.value as? String, "Offline physical device task")
        XCTAssertEqual(body.value as? String, "Saved locally without a Mac connection.")
        XCUIDevice.shared.orientation = .landscapeLeft
        let landscape = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in XCUIScreen.main.screenshot().image.size.width > XCUIScreen.main.screenshot().image.size.height }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [landscape], timeout: 10), .completed)
        title.tap()
        shoot("unified-landscape-keyboard-editor")
        app.buttons["Cancel"].tap()
        XCUIDevice.shared.orientation = .portrait
        app.buttons["unified.connections"].tap()
        XCTAssertTrue(app.staticTexts["Connect devices"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["unified.enableCloud"].isEnabled, "Fixture must never contact cloud or touch an actual workspace")
        shoot("unified-device-connection-guidance")
    }
    private func shoot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}

extension UnifiedWorkspaceUITests {
    func testReviewedMergeRetainsUniqueItemsAndResolvesConcurrentVersions() {
        let app = XCUIApplication()
        app.launchArguments = ["-BWUnifiedFixture", UUID().uuidString, "-BWUnifiedReviewFixture", "YES"]
        app.launch(); defer { app.terminate() }
        let review = app.buttons["unified.reviewMerge"]
        XCTAssertTrue(review.waitForExistence(timeout: 15)); review.tap()
        let peer = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Review Synthetic Mac'")).firstMatch
        XCTAssertTrue(peer.waitForExistence(timeout: 10))
        XCTAssertTrue(peer.isHittable, "The merge action must be visible before scrolling past help text")
        peer.tap()
        XCTAssertTrue(app.staticTexts["1 item needing conflict review"].waitForExistence(timeout: 10))
        app.buttons["unified.merge.approve"].tap()
        XCTAssertTrue(app.buttons["Done"].waitForExistence(timeout: 10)); app.buttons["Done"].tap()
        let concurrent = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Concurrent note' AND identifier BEGINSWITH 'unified.item.'")).firstMatch
        XCTAssertTrue(concurrent.waitForExistence(timeout: 10)); concurrent.tap()
        let remote = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Remote version'")).firstMatch
        XCTAssertTrue(remote.waitForExistence(timeout: 10)); remote.tap()
        app.buttons["unified.editor.save"].tap()
        XCTAssertTrue(concurrent.waitForExistence(timeout: 10))
        XCTAssertFalse(concurrent.label.contains("Review both versions"))
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'unified.item.'")).count, 3)
        let capture = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        capture.name = "unified-reviewed-merge-and-resolution"; capture.lifetime = .keepAlways; add(capture)
    }
    func testContextualTipAndStandaloneAppIntent() {
        let app = XCUIApplication()
        app.launchArguments = ["-BWUnifiedFixture", UUID().uuidString, "-BWUnifiedShowTips", "YES"]
        app.launch(); defer { app.terminate() }
        XCTAssertTrue(app.buttons["unified.welcome.local"].waitForExistence(timeout: 15)); app.buttons["unified.welcome.local"].tap()
        XCTAssertTrue(app.staticTexts["Start with one item"].waitForExistence(timeout: 10))
        let tip = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); tip.name = "unified-contextual-tip"; tip.lifetime = .keepAlways; add(tip)
        app.terminate()
        app.launchArguments = ["-BWUnifiedFixture", UUID().uuidString, "-BWUnifiedIntent", "task"]
        app.launch()
        let task = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Intent-created standalone task' AND identifier BEGINSWITH 'unified.item.'")).firstMatch
        XCTAssertTrue(task.waitForExistence(timeout: 15)); task.tap()
        XCTAssertTrue(app.textViews["unified.editor.body"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.textViews["unified.editor.body"].value as? String, "Saved by the actual App Intent")
    }
}

extension UnifiedWorkspaceUITests {
    /// Read-only acceptance of the owner's approved Mac inclusion. Sample titles
    /// and body digests are supplied privately by the operator, never fixtures in
    /// source control. Every selection uses its canonical record UUID.
    func testNormalInstallationIncludedMacRecords() throws {
        struct Sample: Decodable { let recordID: UUID; let kind: String; let title: String; let bodyHash: String }
        struct Request: Decodable { let recordCount: Int; let samples: [Sample] }
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["BW_UNIFIED_NORMAL_INSTALL"] == "1", "Requires explicit normal-device acceptance")
        let data = try XCTUnwrap(env["BW_UNIFIED_MAC_SAMPLES"]?.data(using: .utf8))
        let request = try JSONDecoder().decode(Request.self, from: data)
        XCTAssertTrue((1...8).contains(request.samples.count))
        let app = XCUIApplication(); defer { app.terminate() }
        for sample in request.samples {
            app.launch()
            app.workspaceDestination("Workspace").tap()
            XCTAssertTrue(app.buttons["unified.connections"].waitForExistence(timeout: 30)); app.buttons["unified.connections"].tap()
            let refresh = app.buttons["Synchronize now"]
            let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in refresh.exists && refresh.isEnabled }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 90), .completed); refresh.tap()
            let synced = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in refresh.isEnabled && app.staticTexts.matching(NSPredicate(format: "label == %@", "Workspace synchronized · available offline")).firstMatch.exists }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [synced], timeout: 90), .completed)
            let count = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'This ' AND label ENDSWITH ' items'")).firstMatch.label
            XCTAssertGreaterThanOrEqual(Int(count.filter(\.isNumber)) ?? 0, request.recordCount)
            app.buttons["Done"].tap()
            let search = app.textFields["unified.search"]
            XCTAssertTrue(search.waitForExistence(timeout: 10)); search.tap(); search.typeText(sample.title)
            let item = app.buttons["unified.item." + sample.recordID.uuidString]
            XCTAssertTrue(item.waitForExistence(timeout: 15)); item.tap()
            XCTAssertTrue(app.textFields["unified.editor.title"].waitForExistence(timeout: 10))
            XCTAssertEqual(app.textFields["unified.editor.title"].value as? String, sample.title)
            let body = app.textViews["unified.editor.body"]
            for _ in 0..<8 where !body.exists { app.swipeUp() }
            XCTAssertTrue(body.waitForExistence(timeout: 5))
            // UIKit represents an empty TextEditor with a nil AX value. A
            // nonempty expected digest still fails if text is unexpectedly absent.
            let text = body.value as? String ?? ""
            shoot("normal-included-Mac-" + sample.kind)
            XCTAssertEqual(SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined(), sample.bodyHash)
            print("VERIFIED_MAC_KIND: " + sample.kind)
            app.buttons["Cancel"].tap()
            app.terminate(); XCTAssertTrue(app.wait(for: .notRunning, timeout: 10))
        }
    }

    /// Real linked devices, restricted to the UUID-named acceptance task seeded by
    /// the operator. Never selects another item or approves any additional merge.
    func testNormalInstallationOwnedRoundTripStage() throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["BW_UNIFIED_NORMAL_INSTALL"] == "1", "Requires explicit normal-device acceptance")
        let run = try XCTUnwrap(env["BW_UNIFIED_ROUNDTRIP_RUN"].flatMap(UUID.init(uuidString:)))
        let record = try XCTUnwrap(env["BW_UNIFIED_ROUNDTRIP_RECORD"].flatMap(UUID.init(uuidString:)))
        let stage = try XCTUnwrap(env["BW_UNIFIED_ROUNDTRIP_STAGE"])
        let title = "Connection check " + run.uuidString.lowercased()
        let bodies = [
            "mac": "Created on Mac for physical-device acceptance. Run: " + run.uuidString.lowercased(),
            "iphone": "Edited on iPhone for physical-device acceptance. Run: " + run.uuidString.lowercased(),
            "ipad": "Edited on iPad for physical-device acceptance. Run: " + run.uuidString.lowercased(),
            "offline": "Saved while iPhone synchronization was paused. Run: " + run.uuidString.lowercased(),
            "concurrent": "Concurrent iPad edit while iPhone was paused. Run: " + run.uuidString.lowercased(),
            "resolved": "Resolved physical-device conflict. Run: " + run.uuidString.lowercased()
        ]
        let actions: [String: (String, String?)] = ["readMac": ("mac", nil), "writeiPhone": ("mac", "iphone"), "readiPhone": ("iphone", nil), "writeiPad": ("iphone", "ipad"), "readiPad": ("ipad", nil), "writeOfflinePhone": ("ipad", "offline"), "readOfflinePhone": ("offline", nil), "writeConcurrentiPad": ("ipad", "concurrent"), "readConcurrentiPad": ("concurrent", nil), "resumeAndResolve": ("offline", "resolved"), "readResolved": ("resolved", nil)]
        let action = try XCTUnwrap(stage == "readDeleted" ? ("resolved", nil as String?) : actions[stage], "Unknown acceptance stage")
        let app = XCUIApplication(); app.launch(); defer { app.terminate() }
        app.workspaceDestination("Workspace").tap()
        func connection(_ mode: String) {
            XCTAssertTrue(app.buttons["unified.connections"].waitForExistence(timeout: 25)); app.buttons["unified.connections"].tap()
            let connect = app.buttons["unified.enableCloud"], refresh = app.buttons["Synchronize now"]
            if mode == "paused" { XCTAssertTrue(connect.waitForExistence(timeout: 10)) }
            else {
                if mode == "resume" { XCTAssertTrue(connect.waitForExistence(timeout: 10)); connect.tap() }
                let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in refresh.exists && refresh.isEnabled }, object: nil)
                XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 60), .completed)
                refresh.tap()
                let done = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in refresh.isEnabled && app.staticTexts.matching(NSPredicate(format: "label == %@", "Workspace synchronized · available offline")).firstMatch.exists }, object: nil)
                XCTAssertEqual(XCTWaiter.wait(for: [done], timeout: 60), .completed)
                if mode == "pause" { app.buttons["Pause synchronization"].tap(); XCTAssertTrue(connect.waitForExistence(timeout: 10)) }
            }
            shoot("normal-roundtrip-connection-" + stage)
            app.buttons["Done"].tap()
        }
        connection(stage == "writeOfflinePhone" ? "pause" : stage == "readOfflinePhone" ? "paused" : stage == "resumeAndResolve" ? "resume" : "refresh")
        let item = app.buttons["unified.item." + record.uuidString]
        if stage == "readDeleted" {
            XCTAssertFalse(item.exists, "The deleted task must leave the ordinary item list")
            app.buttons["All items"].tap()
            let recent = app.buttons["Recently deleted"]
            if recent.exists { recent.tap() } else { app.switches["Recently deleted"].tap() }
        }
        XCTAssertTrue(item.waitForExistence(timeout: 60), "The owned acceptance task must arrive through the normal cloud connection")
        item.tap()
        let field = app.textFields["unified.editor.title"], body = app.textViews["unified.editor.body"]
        XCTAssertTrue(field.waitForExistence(timeout: 10)); XCTAssertEqual(field.value as? String, title)
        if stage == "resumeAndResolve" {
            for key in ["offline", "concurrent"] {
                XCTAssertTrue(app.staticTexts[try XCTUnwrap(bodies[key])].exists, "Both actual physical-device versions must be retained")
            }
            app.buttons.matching(NSPredicate(format: "label CONTAINS %@", try XCTUnwrap(bodies["offline"]))).firstMatch.tap()
        }
        XCTAssertTrue(body.waitForExistence(timeout: 10)); XCTAssertEqual(body.value as? String, bodies[action.0])
        if stage == "readDeleted" { XCTAssertTrue(app.switches["In recently deleted"].exists, "The same UUID and resolved content must remain recoverable") }
        if let next = action.1 {
            body.tap(); body.press(forDuration: 1.1)
            // Keyboard selection uses the standard editor action, preserving the
            // actual app's optimistic Save and source identity checks.
            if app.buttons["Select All"].waitForExistence(timeout: 2) { app.buttons["Select All"].tap() }
            else if app.menuItems["Select All"].exists { app.menuItems["Select All"].tap() }
            else { body.tap(withNumberOfTaps: 3, numberOfTouches: 1) }
            body.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: (body.value as? String ?? "").count))
            body.typeText(try XCTUnwrap(bodies[next]))
            XCTAssertEqual(body.value as? String, bodies[next], "Refuse Save if the editor selection did not replace the complete owned text")
            app.buttons["unified.editor.save"].tap()
            XCTAssertTrue(item.waitForExistence(timeout: 15))
            item.tap(); XCTAssertEqual(body.value as? String, bodies[next])
        }
        shoot("normal-roundtrip-" + stage)
        app.buttons["Cancel"].tap()
        if action.1 != nil && stage != "writeOfflinePhone" { connection("refresh") }
    }

    /// Owner-authorized connection inspection on the preserved installation. This
    /// may enable the requested private iCloud connection, but never approves a
    /// merge or changes workspace content. Run in Release to match Production.
    func testNormalInstallationConnectionInspection() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["BW_UNIFIED_NORMAL_INSTALL"] == "1", "Requires explicit normal-install validation on the owner's device")
        let app = XCUIApplication(); app.launch()
        defer { app.terminate() }
        app.workspaceDestination("Workspace").tap()
        let welcome = app.buttons["unified.welcome.local"]
        if welcome.waitForExistence(timeout: 3) { welcome.tap() }
        let connections = app.buttons["unified.connections"]
        XCTAssertTrue(connections.waitForExistence(timeout: 25)); connections.tap()
        XCTAssertTrue(app.navigationBars["Devices & recovery"].waitForExistence(timeout: 10))
        let connect = app.buttons["unified.enableCloud"]
        if connect.exists && connect.isEnabled { connect.tap() }
        let refresh = app.buttons["Synchronize now"]
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in refresh.exists && refresh.isEnabled }, object: nil)
        let ready = XCTWaiter.wait(for: [enabled], timeout: 60)
        if ready == .completed {
            refresh.tap()
            let finished = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in refresh.exists && refresh.isEnabled }, object: nil)
            _ = XCTWaiter.wait(for: [finished], timeout: 60)
        }
        shoot("normal-device-connection-inspection")
        let peer = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Review ' AND label CONTAINS ' workspace ('")).firstMatch
        if peer.exists { XCTAssertTrue(peer.isHittable, "The first workspace must be visible without searching through setup instructions") }
        let state = XCTAttachment(string: app.debugDescription)
        state.name = "normal-connection-accessibility"; state.lifetime = .keepAlways; add(state)
        print("NORMAL_CONNECTION_LABELS: " + app.staticTexts.allElementsBoundByIndex.map(\.label).joined(separator: " | "))
        print("NORMAL_CONNECTION_PEERS: " + app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Review '")).allElementsBoundByIndex.map(\.label).joined(separator: " | "))
        XCTAssertEqual(ready, .completed, "The normal private iCloud connection must finish; inspect the attached screen for its actual error")
        XCTAssertTrue(app.buttons["Done"].exists)
    }

    /// Explicit owner-authorized installation smoke check. Reads the normal screen
    /// and changes top-level destinations; never creates, edits or deletes workspace content.
    func testNormalInstallationOpensWorkspaceAndPlanning() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["BW_UNIFIED_NORMAL_INSTALL"] == "1", "Requires explicit normal-install validation on the owner's device")
        let app = XCUIApplication(); app.launch(); defer { app.terminate() }
        let welcome = app.buttons["unified.welcome.local"]
        if welcome.waitForExistence(timeout: 5) { welcome.tap() }
        let workspace = app.workspaceDestination("Workspace")
        XCTAssertTrue(workspace.waitForExistence(timeout: 25)); workspace.tap()
        if welcome.waitForExistence(timeout: 3) { welcome.tap() }
        XCTAssertTrue(app.buttons["unified.new"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["unified.macTools"].exists)
        app.workspaceDestination("Planning").tap()
        XCTAssertTrue(app.segmentedControls["workspace.planningView"].waitForExistence(timeout: 10))
        app.workspaceDestination("Overview").tap()
        XCTAssertTrue(app.navigationBars["Overview"].waitForExistence(timeout: 10))
    }

    /// Separate opt-in for the owner's reviewed approval of empty-device linking.
    /// Nonempty or conflicted previews fail closed before the approval button.
    func testNormalInstallationApproveEmptyDeviceLinks() throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["BW_UNIFIED_NORMAL_INSTALL"] == "1" && env["BW_UNIFIED_APPROVE_EMPTY_LINKS"] == "1", "Requires explicit approval to link the owner's empty workspaces")
        let app = XCUIApplication(); app.launch(); defer { app.terminate() }
        app.workspaceDestination("Workspace").tap()
        XCTAssertTrue(app.buttons["unified.connections"].waitForExistence(timeout: 25)); app.buttons["unified.connections"].tap()
        let local = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'This ' AND label ENDSWITH ' · 0 items'")).firstMatch
        XCTAssertTrue(local.waitForExistence(timeout: 10), "Approval is limited to an empty local workspace")
        for _ in 0..<3 {
            let refresh = app.buttons["Synchronize now"]
            let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in refresh.exists && refresh.isEnabled }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 60), .completed)
            refresh.tap()
            let finished = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in refresh.exists && refresh.isEnabled }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [finished], timeout: 60), .completed)
            let peer = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Review ' AND label CONTAINS ' workspace ('")).firstMatch
            if !peer.exists { break }
            XCTAssertTrue(peer.label.hasSuffix("(0 items)"), "A nonempty peer needs a new review")
            peer.tap()
            XCTAssertTrue(app.staticTexts["0 incoming changes"].waitForExistence(timeout: 10))
            XCTAssertTrue(app.staticTexts["0 items needing conflict review"].exists)
            XCTAssertTrue(app.staticTexts["0 locations needing review"].exists)
            shoot("normal-approved-empty-device-preview")
            let approve = app.buttons["unified.merge.approve"]
            XCTAssertTrue(approve.isEnabled); approve.tap()
            let dismissed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in !approve.exists }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [dismissed], timeout: 30), .completed)
        }
        shoot("normal-linked-empty-devices")
        print("NORMAL_LINKED_LABELS: " + app.staticTexts.allElementsBoundByIndex.map(\.label).joined(separator: " | "))
        XCTAssertTrue(app.staticTexts["Connected workspaces"].exists)
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Review ' AND label CONTAINS ' workspace ('")).firstMatch.exists)
    }
}


extension UnifiedWorkspaceUITests {
    func testProjectPropertiesPersistAndSettingsAreAccessible() {
        let app = XCUIApplication()
        // A preceding connected-browser test may still be terminating. Wait for
        // that process before launching with a new isolated workspace identity.
        if app.state != .notRunning {
            app.terminate()
            XCTAssertTrue(app.wait(for: .notRunning, timeout: 10))
        }
        app.launchArguments = ["-BWUnifiedFixture", UUID().uuidString, "-BWProjectManagementFixture", "YES"]
        app.launch(); defer { app.terminate(); _ = app.wait(for: .notRunning, timeout: 10) }
        let item = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'unified.item.'")).firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 20))
        XCTAssertTrue(app.staticTexts["Art"].exists)
        app.buttons["workspace.settings"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 10))
        app.buttons["Done"].tap()
        item.tap()
        let featured = app.switches["project.featured"]
        XCTAssertTrue(featured.waitForExistence(timeout: 10))
        shoot("project-before-featured")
        if !featured.isHittable { app.swipeUp() }
        featured.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        XCTAssertEqual(featured.value as? String, "1")
        app.buttons["unified.editor.save"].tap()
        XCTAssertTrue(item.waitForExistence(timeout: 10))
        app.terminate(); app.launch()
        XCTAssertTrue(item.waitForExistence(timeout: 20)); item.tap()
        XCTAssertTrue(featured.waitForExistence(timeout: 10)); XCTAssertEqual(featured.value as? String, "1")
        XCTAssertTrue(app.staticTexts["Animation"].exists); XCTAssertTrue(app.staticTexts["Collection"].exists)
        XCUIDevice.shared.orientation = .landscapeLeft
        shoot("project-details-landscape")
        let github = app.descendants(matching: .any)["Open GitHub"].firstMatch
        let viewport = app.windows.firstMatch.frame
        for _ in 0..<6 {
            if github.exists && github.frame.maxY < viewport.maxY - 25 && github.frame.minY > viewport.minY { break }
            app.collectionViews.firstMatch.swipeUp()
        }
        shoot("project-links-after-scroll")
        XCTAssertTrue(github.waitForExistence(timeout: 5))
        XCTAssertLessThan(github.frame.maxY, viewport.maxY - 25)
        shoot("project-links-landscape")
        app.buttons["Cancel"].tap()
        XCUIDevice.shared.orientation = .portrait
        let star = app.buttons["Toggle featured Creative project"]
        XCTAssertTrue(star.waitForExistence(timeout: 10)); star.tap()
        let updated = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "Not featured"), object: star)
        XCTAssertEqual(XCTWaiter.wait(for: [updated], timeout: 10), .completed)
        item.tap()
        XCTAssertTrue(featured.waitForExistence(timeout: 10)); XCTAssertEqual(featured.value as? String, "0")
        shoot("project-details-portrait")
    }
}
