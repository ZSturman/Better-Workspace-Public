import XCTest

extension XCUIApplication {
    /// A top-level destination however this device shows it: the tab bar on iPhone, the
    /// split-view sidebar (`workspace-sidebar-<name>`) on iPad in regular width.
    func workspaceDestination(_ name: String, timeout: TimeInterval = 20) -> XCUIElement {
        // The identifier lands on the row's icon, which is not hittable on its own; the
        // cell that contains it is what a person taps.
        let sidebar = cells.containing(NSPredicate(format: "identifier == %@", "workspace-sidebar-\(name.lowercased())")).firstMatch
        let tab = buttons[name].firstMatch
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if sidebar.exists { return sidebar }
            if tab.exists { return tab }
            Thread.sleep(forTimeInterval: 0.25)
        } while Date() < deadline
        return tab
    }
}
