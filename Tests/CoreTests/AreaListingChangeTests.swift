import XCTest
@testable import BetterWorkspaceCore

/// Which file events re-list an area. An agent building inside one project re-listed all
/// ~370 projects several times a second (October 26); only changes that can alter a
/// listed item's row may do that.
final class AreaListingChangeTests: XCTestCase {
    private let workspace = WorkspaceLocation(root: URL(fileURLWithPath: "/tmp/bw-area-listing"))
    private func alters(_ relative: String) -> Bool {
        workspace.changeAltersAreaListing(URL(fileURLWithPath: "/tmp/bw-area-listing/" + relative))
    }

    func testItemsChildrenAndGrandchildrenAlterTheListing() {
        XCTAssertTrue(alters("Projects"))
        XCTAssertTrue(alters("Projects/Casino Exit"), "The item itself")
        XCTAssertTrue(alters("Projects/Casino Exit/README.md"), "A direct child changes count and newest date")
        XCTAssertTrue(alters("Projects/Casino Exit/casino_exit/store.py"), "A grandchild changes its folder's date")
        XCTAssertTrue(alters("Projects/_Utilities/Storage Maintenance/notes.md"), "A container is not a level")
    }

    func testDeeperAndHiddenChangesDoNot() {
        XCTAssertFalse(alters("Projects/Casino Exit/casino_exit/autoapply/__pycache__/store.cpython-314.pyc"))
        XCTAssertFalse(alters("Projects/Casino Exit/casino_exit/autoapply/store.py"))
        XCTAssertFalse(alters("Projects/Casino Exit/.ruff_cache/0.16.10/x"), "Hidden children are not counted")
        XCTAssertFalse(alters("Projects/_Closed Abandoned/Better Data/Sources/App/Main.swift"))
    }

    func testOutsideTheWorkspaceIsConservative() {
        XCTAssertTrue(workspace.changeAltersAreaListing(URL(fileURLWithPath: "/elsewhere/file")))
    }
}
