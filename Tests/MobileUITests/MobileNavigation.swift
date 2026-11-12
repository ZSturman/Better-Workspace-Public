import XCTest

extension XCUIApplication {
    /// A top-level destination however this device shows it: the tab bar on iPhone, the
    /// split-view sidebar (`workspace-sidebar-<name>`) on iPad in regular width.
    func workspaceDestination(_ name: String, timeout: TimeInterval = 20) -> XCUIElement {
        // The identifier lands on the row's icon, which is not hittable on its own; the
        // cell that contains it is what a person taps.
        let key = name == "Planning" ? "work" : name.lowercased()
        let label = staticTexts["workspace-sidebar-\(key)"].firstMatch
        let sidebar = cells.containing(NSPredicate(format: "identifier == %@", "workspace-sidebar-\(key)")).firstMatch
        let tab = buttons[name].firstMatch
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if label.exists && label.isHittable { return label }
            if sidebar.exists { return sidebar }
            if tab.exists { return tab }
            Thread.sleep(forTimeInterval: 0.25)
        } while Date() < deadline
        return tab
    }

    /// Projects or Work. The fixture shell has a tab for each; the production shell
    /// (since October 23) puts both under Planning's segmented picker.
    func openPlanning(_ view: String, timeout: TimeInterval = 20) {
        let picker = segmentedControls["workspace.planningView"]
        if !picker.exists, buttons[view].firstMatch.exists, !buttons["Planning"].exists {
            buttons[view].firstMatch.tap(); return
        }
        if !picker.exists { workspaceDestination("Planning", timeout: timeout).tap() }
        if picker.waitForExistence(timeout: timeout) { picker.buttons[view].tap() }
    }

    /// Lists build rows only as they scroll in; swipe until `element` is on screen.
    @discardableResult
    func scrollTo(_ element: XCUIElement, maxSwipes: Int = 8) -> Bool {
        for _ in 0..<maxSwipes where !(element.exists && element.isHittable) { swipeUp() }
        return element.exists && element.isHittable
    }
}
