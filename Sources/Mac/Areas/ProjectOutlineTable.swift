import SwiftUI
import AppKit

/// Values and closures only: departing AppKit cells never look up a SwiftUI environment.
struct ProjectOutlineTable: NSViewRepresentable {
    let groups: [(String, [ProjectBrowserRow])]
    let grouped: Bool
    @Binding var columns: [String]
    let availableColumns: [(String, String)]
    var defaultColumns = ProjectBrowserPreferences.defaultColumns
    @Binding var widths: [String: Double]
    @Binding var collapsed: Set<String>
    @Binding var selection: String?
    @Binding var sort: String
    @Binding var ascending: Bool
    let open: (ProjectBrowserRow) -> Void
    let action: (ProjectBrowserRow, String) -> Void

    final class Node: NSObject {
        let name: String
        let row: ProjectBrowserRow?
        let children: [Node]
        init(name: String, row: ProjectBrowserRow? = nil, children: [Node] = []) { self.name = name; self.row = row; self.children = children }
    }
    final class KeyboardOutline: NSOutlineView {
        override func menu(for event: NSEvent) -> NSMenu? {
            let index = row(at: convert(event.locationInWindow, from: nil))
            guard index >= 0, (item(atRow: index) as? Node)?.row != nil else { return nil }
            selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
            return super.menu(for: event)
        }
        override func mouseDown(with event: NSEvent) {
            super.mouseDown(with: event)
            window?.makeFirstResponder(self)
        }
        override func keyDown(with event: NSEvent) {
            if [36, 76].contains(event.keyCode) || ["\r", "\n", "\u{3}"].contains(event.charactersIgnoringModifiers ?? "") {
                if let target, let action = doubleAction { NSApp.sendAction(action, to: target, from: self) }
            } else { super.keyDown(with: event) }
        }

    }
    final class Header: NSTableHeaderView {
        weak var coordinator: Coordinator?
        override func menu(for event: NSEvent) -> NSMenu? {
            guard let coordinator, let tableView else { return nil }
            let index = column(at: convert(event.locationInWindow, from: nil))
            let key = index >= 0 ? tableView.tableColumns[index].identifier.rawValue : nil
            return coordinator.headerMenu(key: key)
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let outline = KeyboardOutline()
        outline.delegate = context.coordinator; outline.dataSource = context.coordinator
        let header = Header(frame: NSRect(x: 0, y: 0, width: 600, height: 28)); header.coordinator = context.coordinator; outline.headerView = header
        outline.allowsColumnReordering = true; outline.allowsColumnResizing = true
        outline.rowHeight = 30; outline.usesAlternatingRowBackgroundColors = true
        outline.allowsMultipleSelection = false; outline.columnAutoresizingStyle = .noColumnAutoresizing
        outline.target = context.coordinator; outline.doubleAction = #selector(Coordinator.openSelection)
        outline.setAccessibilityIdentifier("projects.table")
        let menu = NSMenu()
        for (title, key) in [("Open Project", "open"), ("Explain", "explain"), ("User Flow", "flow"), ("Reveal in Finder", "finder"), ("Open in Notion", "notion")] {
            let item = NSMenuItem(title: title, action: #selector(Coordinator.performMenu(_:)), keyEquivalent: "")
            item.representedObject = key; item.target = context.coordinator; menu.addItem(item)
        }
        menu.addItem(.separator())
        let manage = NSMenuItem(title: "Manage project", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        let delete = NSMenuItem(title: "Delete project…", action: #selector(Coordinator.performMenu(_:)), keyEquivalent: "")
        delete.representedObject = "delete"; delete.target = context.coordinator
        submenu.addItem(delete); manage.submenu = submenu; menu.addItem(manage)
        outline.menu = menu
        let scroll = NSScrollView(); scroll.documentView = outline
        scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true; scroll.borderType = .noBorder
        context.coordinator.outline = outline
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self; coordinator.updating = true
        defer { coordinator.updating = false }
        guard let outline = coordinator.outline else { return }
        let wanted = columns.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        if outline.tableColumns.map({ $0.identifier.rawValue }) != wanted {
            // Reconcile in place. NSOutlineView keeps its outline column when asked to
            // remove it, so a remove-all-then-add rebuild duplicated Name.
            for column in outline.tableColumns where !wanted.contains(column.identifier.rawValue) { outline.removeTableColumn(column) }
            for key in wanted where outline.tableColumn(withIdentifier: .init(key)) == nil {
                let column = NSTableColumn(identifier: .init(key))
                column.title = ProjectBrowserView.title(key)
                column.width = widths[key] ?? (key == "name" ? 270 : 130); column.minWidth = key == "name" ? 160 : 70
                column.sortDescriptorPrototype = NSSortDescriptor(key: key, ascending: true)
                outline.addTableColumn(column)
            }
            for (target, key) in wanted.enumerated() {
                let current = outline.column(withIdentifier: .init(key))
                if current >= 0, current != target { outline.moveColumn(current, toColumn: target) }
            }
            outline.outlineTableColumn = outline.tableColumns.first { $0.identifier.rawValue == "name" } ?? outline.tableColumns.first
        }
        for column in outline.tableColumns {
            let key = column.identifier.rawValue
            let desired = widths[key] ?? (key == "name" ? 270 : 130)
            if abs(column.width - desired) > 0.5 { column.width = desired }
        }
        coordinator.nodes = grouped ? groups.map { name, rows in Node(name: "\(name) · \(rows.count)", children: rows.map { Node(name: $0.name, row: $0) }) }
            : groups.flatMap { $0.1.map { Node(name: $0.name, row: $0) } }
        coordinator.groupNames = Dictionary(uniqueKeysWithValues: zip(coordinator.nodes, groups.map(\.0)).map { (ObjectIdentifier($0.0), $0.1) })
        outline.reloadData()
        if grouped { for node in coordinator.nodes { if !collapsed.contains(coordinator.groupNames[ObjectIdentifier(node)] ?? "") { outline.expandItem(node) } } }
        if let selection {
            for index in 0..<outline.numberOfRows where (outline.item(atRow: index) as? Node)?.row?.id == selection { outline.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false); break }
        }
        if outline.sortDescriptors.first?.key != sort || outline.sortDescriptors.first?.ascending != ascending {
            outline.sortDescriptors = [NSSortDescriptor(key: sort, ascending: ascending)]
        }
    }
    final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuItemValidation {
        var parent: ProjectOutlineTable
        var nodes: [Node] = []
        var groupNames: [ObjectIdentifier: String] = [:]
        weak var outline: NSOutlineView?
        var updating = false
        init(_ parent: ProjectOutlineTable) { self.parent = parent }
        func headerMenu(key: String?) -> NSMenu {
            let menu = NSMenu()
            func item(_ title: String, _ action: String, _ value: String) -> NSMenuItem {
                let item = NSMenuItem(title: title, action: #selector(headerAction(_:)), keyEquivalent: "")
                item.target = self; item.representedObject = [action, value]; return item
            }
            if let key {
                menu.addItem(item("Sort ascending", "ascending", key))
                menu.addItem(item("Sort descending", "descending", key))
                menu.addItem(.separator())
            }
            for (key, title) in parent.availableColumns {
                let entry = item(title, "toggle", key)
                entry.state = parent.columns.contains(key) ? .on : .off
                entry.isEnabled = key != "name"; menu.addItem(entry)
            }
            menu.addItem(.separator()); menu.addItem(item("Restore default columns", "reset", ""))
            return menu
        }
        @objc func headerAction(_ sender: NSMenuItem) {
            guard let values = sender.representedObject as? [String], values.count == 2 else { return }
            let key = values[1]
            switch values[0] {
            case "ascending", "descending": parent.sort = key; parent.ascending = values[0] == "ascending"
            case "toggle":
                if parent.columns.contains(key) { parent.columns.removeAll { $0 == key } } else { parent.columns.append(key) }
            case "reset": parent.columns = parent.defaultColumns; parent.widths = [:]
            default: break
            }
        }
        func outlineViewColumnDidMove(_ notification: Notification) {
            guard !updating, let outline else { return }
            parent.columns = outline.tableColumns.map { $0.identifier.rawValue }
        }
        func outlineViewColumnDidResize(_ notification: Notification) {
            guard !updating, let outline else { return }
            parent.widths = Dictionary(uniqueKeysWithValues: outline.tableColumns.map { ($0.identifier.rawValue, Double($0.width)) })
        }
        func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int { (item as? Node)?.children.count ?? nodes.count }
        func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any { (item as? Node)?.children[index] ?? nodes[index] }
        func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool { !(item as! Node).children.isEmpty }
        func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool { (item as! Node).row != nil }
        func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
            guard let node = item as? Node, let column = tableColumn else { return nil }
            let field = NSTextField(labelWithString: node.row.map { $0.value(column.identifier.rawValue).isEmpty ? "—" : $0.value(column.identifier.rawValue) } ?? (column == outlineView.outlineTableColumn ? node.name : ""))
            field.lineBreakMode = .byTruncatingTail; field.font = .systemFont(ofSize: 12, weight: node.row == nil ? .semibold : .regular)
            field.textColor = column.identifier.rawValue == "name" ? .labelColor : .secondaryLabelColor
            field.setAccessibilityIdentifier(node.row.map { "projects.row.\($0.id).\(column.identifier.rawValue)" } ?? "projects.group")
            field.toolTip = node.row?.values["help:" + column.identifier.rawValue] ?? field.stringValue
            return field
        }
        func outlineViewSelectionDidChange(_ notification: Notification) {
            guard !updating, let outline, outline.selectedRow >= 0 else { return }
            parent.selection = (outline.item(atRow: outline.selectedRow) as? Node)?.row?.id
        }
        func outlineView(_ outlineView: NSOutlineView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            guard !updating, let descriptor = outlineView.sortDescriptors.first, let key = descriptor.key else { return }
            parent.sort = key; parent.ascending = descriptor.ascending
        }
        func outlineViewItemDidCollapse(_ notification: Notification) { changeGroup(notification, collapsed: true) }
        func outlineViewItemDidExpand(_ notification: Notification) { changeGroup(notification, collapsed: false) }
        func changeGroup(_ notification: Notification, collapsed: Bool) {
            guard !updating, let node = notification.userInfo?["NSObject"] as? Node, let name = groupNames[ObjectIdentifier(node)] else { return }
            if collapsed { parent.collapsed.insert(name) } else { parent.collapsed.remove(name) }
        }
        var selectedRow: ProjectBrowserRow? {
            guard let outline else { return nil }
            let index = outline.selectedRow
            return index >= 0 ? (outline.item(atRow: index) as? Node)?.row : nil
        }
        @objc func openSelection() {
            guard let outline else { return }
            let index = outline.selectedRow
            if index >= 0, let row = (outline.item(atRow: index) as? Node)?.row { parent.open(row) }
        }
        @objc func performMenu(_ sender: NSMenuItem) { if let row = selectedRow, let key = sender.representedObject as? String { parent.action(row, key) } }
        func validateMenuItem(_ item: NSMenuItem) -> Bool {
            if item.action == #selector(headerAction(_:)) { return (item.representedObject as? [String]) != ["toggle", "name"] }
            guard let row = selectedRow else { return false }
            switch item.representedObject as? String {
            case "explain": return row.values["canExplain"] == "true"
            case "flow": return row.values["canFlow"] == "true"
            case "finder", "delete": return row.item != nil
            case "notion": return row.graph?.pageID != nil
            default: return true
            }
        }
    }
}
