import XCTest
import BetterWorkspaceCore
import Foundation

final class WidgetNavigationUITests: IsolatedUITestCase {
    func testMissingPinnedProjectAtMinimumWidthExplains() {
        let app = isolatedApp(arguments: ["-bwWindowWidth", "820", "-bwOpenURL", "betterworkspace://widget-project?id=missing"])
        app.launch(); requireWindow(app)
        XCTAssertTrue(app.staticTexts["This pinned project is no longer available."].firstMatch.waitForExistence(timeout: 20))
        XCTAssertFalse(app.buttons["All Projects"].firstMatch.exists)
    }
    func testChartsLinkOpensProjectCharts() {
        let app = isolatedApp(arguments: ["-bwOpenURL", "betterworkspace://charts?id=progress"])
        app.launch(); requireWindow(app)
        XCTAssertTrue(app.descendants(matching: .any)["projects.charts"].firstMatch.waitForExistence(timeout: 20))
    }
    func testMissingReviewExplainsWithoutStoppingWidgetQueue() throws {
        try "A separate review candidate".write(to: Self.workspaceRoot.appendingPathComponent("To Read/Widget review.md"), atomically: true, encoding: .utf8)
        let app = isolatedApp(arguments: ["-bwOpenURL", "betterworkspace://review?id=missing"])
        app.launch(); requireWindow(app)
        XCTAssertTrue(app.staticTexts["This review item is no longer available. Choose Next to continue reviewing."].firstMatch.waitForExistence(timeout: 20))
        let directory = Self.fixtureRoot.appendingPathComponent("Widgets")
        wait("Independent review queue published") {
            DashboardWidgetStore.load(directory: directory)?.reviewItems.contains { $0.path == "To Read/Widget review.md" } == true
        }
    }
    func testConfirmedCapturePromotesOnceAndTaskCompletionPreservesNotes() throws {
        let capture = Self.inboxRoot.appendingPathComponent("Widget capture.md")
        try "# Widget capture\nPreserve these notes.".write(to: capture, atomically: true, encoding: .utf8)
        let date = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: capture.path)[.modificationDate] as? Date)
        let store = try WidgetCommandStore(directory: Self.fixtureRoot.appendingPathComponent("Widgets"))
        let edit = MobilePlanningEdit(operation: .fileCapture, title: capture.lastPathComponent,
            captureFiling: .init(capture: .init(name: capture.lastPathComponent, modified: date), destination: "To Do"))
        let preview = try store.stage(scope: "fixture", edit: edit)
        try store.confirm(scope: "fixture", token: preview.id)
        let app = isolatedApp(); app.launch(); requireWindow(app)
        wait("Capture receipt") {
            let state = try? store.records().first { $0.id == edit.id }?.state
            return state == .applied || state == .rejected
        }
        let filingReceipt = try XCTUnwrap(store.records().first { $0.id == edit.id })
        XCTAssertEqual(filingReceipt.state, .applied, filingReceipt.message ?? "Filing did not complete")
        let service = WorkItemService()
        let queue = Self.workspaceRoot.appendingPathComponent("To Do")
        let created = try XCTUnwrap(service.items(under: queue).first { $0.id == edit.id.uuidString })
        XCTAssertTrue(created.body.contains("Preserve these notes."))
        XCTAssertFalse(FileManager.default.fileExists(atPath: capture.path))
        wait("Task published") { DashboardWidgetStore.load(directory: store.directory)?.work.contains { $0.id == created.id } == true }
        try WidgetDashboardRuntime.complete(taskID: created.id, store: store)
        let completion = try XCTUnwrap(store.records().last { $0.edit?.operation == .saveWork }?.id)
        wait("Completion applied") { (try? store.records().first { $0.id == completion }?.state) == .applied }
        wait("Applied revision published") {
            let result = try? store.records().first { $0.id == completion }?.workModifiedAt
            return DashboardWidgetStore.load(directory: store.directory)?.work.first { $0.id == created.id }?.modifiedAt == result
        }
        try WidgetDashboardRuntime.undo(id: completion, store: store)
        let reversal = try XCTUnwrap(store.records().last { $0.edit?.work?.status == .open }?.id)
        wait("Reversal applied") { (try? store.records().first { $0.id == reversal }?.state) == .applied }
        XCTAssertEqual(service.items(under: queue).first { $0.id == created.id }?.status, .open)
        XCTAssertTrue(service.items(under: queue).first { $0.id == created.id }?.body.contains("Preserve these notes.") == true)
        app.terminate(); app.launch(); requireWindow(app)
        XCTAssertEqual(service.items(under: queue).filter { $0.id == created.id }.count, 1)
    }
    func testChangedCaptureProducesRejectedReceiptWithoutFiling() throws {
        let capture = Self.inboxRoot.appendingPathComponent("Changed widget capture.md")
        try "Original".write(to: capture, atomically: true, encoding: .utf8)
        let date = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: capture.path)[.modificationDate] as? Date)
        let store = try WidgetCommandStore(directory: Self.fixtureRoot.appendingPathComponent("Widgets"))
        let edit = MobilePlanningEdit(operation: .fileCapture, title: capture.lastPathComponent,
            captureFiling: .init(capture: .init(name: capture.lastPathComponent, modified: date), destination: "To Read"))
        try store.append(.planning(edit))
        try "Changed".write(to: capture, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: date.addingTimeInterval(0.25)], ofItemAtPath: capture.path)
        let app = isolatedApp(); app.launch(); requireWindow(app)
        wait("Refusal receipt") { (try? store.records().first?.state) == .rejected }
        XCTAssertTrue(try store.records().first?.message?.contains("changed") == true)
        XCTAssertEqual(try String(contentsOf: capture, encoding: .utf8), "Changed")
        XCTAssertFalse(FileManager.default.fileExists(atPath: Self.workspaceRoot.appendingPathComponent("To Read/Changed widget capture.md").path))
    }
    private func wait(_ title: String, until condition: @escaping () -> Bool) {
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 25), .completed, title)
    }
}
