import XCTest
import BetterWorkspaceCore

final class WorkItemIndexUITests: IsolatedUITestCase {
    func testKnownWorkAppearsBeforeDiscoveryAndUsesCurrentFileContents() throws {
        let service = WorkItemService()
        var item = try service.create(WorkItem(kind: .task, title: "Indexed task", url: Self.workspaceRoot),
                                      in: Self.workspaceRoot.appendingPathComponent("To Do"))
        let paths = try JSONSerialization.data(withJSONObject: ["version": 1, "root": Self.workspaceRoot.canonicalPath,
            "paths": ["To Do/" + item.url.lastPathComponent]])
        try paths.write(to: Self.fixtureRoot.appendingPathComponent("work-item-paths.json"))
        item.title = "Current text from Markdown"
        _ = try service.update(item)
        let app = isolatedApp(arguments: ["-bwStartArea", "Work", "-bwWorkItemDiscoveryDelay", "30"])
        app.launch(); requireWindow(app)
        // The discovery walk is deliberately still waiting. A cache of record bodies
        // would show the old title, and the pre-index implementation shows no task.
        XCTAssertTrue(app.staticTexts["Current text from Markdown"].firstMatch.waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["Indexed task"].exists)
        let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        attachment.name = "Work before background discovery"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
