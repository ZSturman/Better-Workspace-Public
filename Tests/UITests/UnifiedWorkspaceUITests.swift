import XCTest
import BetterWorkspaceCore

final class UnifiedWorkspaceUITests: IsolatedUITestCase {
    func testSharedWorkspaceAtNarrowWidthSavesAndReopens() throws {
        let fixture = UUID().uuidString
        let app = isolatedApp(arguments: ["-bwStartArea", "Workspace", "-bwWindowWidth", "820", "-BWUnifiedFixture", fixture])
        app.launch(); defer { app.terminate() }
        requireForeground(app)
        let local = app.buttons["unified.welcome.local"]
        XCTAssertTrue(local.waitForExistence(timeout: 20)); local.click()
        let newButton = app.buttons["unified.new"]
        XCTAssertTrue(newButton.waitForExistence(timeout: 10)); newButton.click()
        let title = app.textFields["unified.editor.title"]
        XCTAssertTrue(title.waitForExistence(timeout: 10)); title.click(); title.typeText("Mac offline task")
        let body = app.textViews["unified.editor.body"]
        body.click(); body.typeText("Shared workspace editor")
        app.buttons["unified.editor.save"].click()
        let item = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'unified.item.'")).firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 10))
        let capture = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        capture.name = "unified-mac-820"; capture.lifetime = .keepAlways; add(capture)
        app.terminate(); _ = app.wait(for: .notRunning, timeout: 10); app.launch(); requireForeground(app)
        XCTAssertTrue(item.waitForExistence(timeout: 20)); XCTAssertFalse(local.exists)
        item.click()
        XCTAssertTrue(title.waitForExistence(timeout: 10))
        XCTAssertTrue(body.waitForExistence(timeout: 10))
        XCTAssertEqual(title.value as? String, "Mac offline task")
        XCTAssertEqual(body.value as? String, "Shared workspace editor")
    }
}

extension UnifiedWorkspaceUITests {
    func testReviewedProjectCreationRetainsPropertiesUUIDAndExistingFolder() throws {
        let existing = Self.workspaceRoot.appendingPathComponent("Projects/Creative project")
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: false)
        let sentinel = existing.appendingPathComponent("Keep.txt"); try Data("Original folder".utf8).write(to: sentinel)
        let fixture = UUID().uuidString
        let app = isolatedApp(arguments: ["-bwStartArea", "Workspace", "-bwWindowWidth", "820", "-bwWindowHeight", "520", "-BWUnifiedFixture", fixture, "-BWUnifiedFileCreationFixture", "YES", "-BWProjectManagementFixture", "YES"])
        app.launch(); defer { app.terminate() }; requireForeground(app)
        XCTAssertTrue(app.buttons["unified.includeMac"].waitForExistence(timeout: 20)); app.buttons["unified.includeMac"].click()
        XCTAssertTrue(app.buttons["unified.merge.approve"].waitForExistence(timeout: 10)); app.buttons["unified.merge.approve"].click()
        let review = app.buttons["unified.reviewFiles"]
        XCTAssertTrue(review.waitForExistence(timeout: 10)); review.click()
        XCTAssertTrue(app.staticTexts["Projects/Creative project-Mac"].waitForExistence(timeout: 10))
        let capture = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        capture.name = "unified-reviewed-project-folder-820"; capture.lifetime = .keepAlways; add(capture)
        app.buttons["unified.createFiles"].click()
        XCTAssertTrue(review.waitForExistence(timeout: 15))
        let created = Self.workspaceRoot.appendingPathComponent("Projects/Creative project-Mac")
        let database = try Database(url: Self.fixtureRoot.appendingPathComponent("test.sqlite"))
        let projects = ProjectStore(database: database)
        let record = try XCTUnwrap(projects.record(for: created))
        let graph = try WorkspaceReplicaStore(directory: Self.fixtureRoot.appendingPathComponent("UnifiedAcceptance/" + fixture), initialWorkspaceID: UUID()).load()
        let state = try XCTUnwrap(graph.records.first { $0.id.uuidString == record.id })
        XCTAssertEqual(state.resolved?.content.title, "Creative project")
        XCTAssertEqual(projects.metadata(for: record.id).domain, "Art")
        XCTAssertEqual(projects.portfolioDetails(for: record.id).customLinks?.first?.label, "App Store")
        XCTAssertEqual(try String(contentsOf: sentinel), "Original folder")
        app.terminate(); XCTAssertTrue(app.wait(for: .notRunning, timeout: 10)); app.launch(); requireForeground(app)
        XCTAssertTrue(review.waitForExistence(timeout: 20)); review.click()
        XCTAssertTrue(app.staticTexts["No new Mac items are ready to create."].waitForExistence(timeout: 10))
        XCTAssertEqual(projects.record(for: created)?.id, record.id)
        XCTAssertEqual(try String(contentsOf: sentinel), "Original folder")
    }

    func testCreationCollisionAfterReviewCanBeCanceledWithoutFileChanges() throws {
        let app = isolatedApp(arguments: ["-bwStartArea", "Workspace", "-bwWindowWidth", "820", "-bwWindowHeight", "520", "-BWUnifiedFixture", UUID().uuidString, "-BWUnifiedFileCreationFixture", "YES"])
        app.launch(); defer { app.terminate() }; requireForeground(app)
        XCTAssertTrue(app.buttons["unified.welcome.local"].waitForExistence(timeout: 15)); app.buttons["unified.welcome.local"].click()
        app.buttons["unified.new"].click()
        let title = app.textFields["unified.editor.title"]
        XCTAssertTrue(title.waitForExistence(timeout: 10)); title.click(); title.typeText("Interruption")
        app.buttons["unified.editor.save"].click()
        app.buttons["unified.includeMac"].click()
        XCTAssertTrue(app.buttons["unified.merge.approve"].waitForExistence(timeout: 10)); app.buttons["unified.merge.approve"].click()
        let review = app.buttons["unified.reviewFiles"]
        XCTAssertTrue(review.waitForExistence(timeout: 10)); review.click()
        XCTAssertTrue(app.staticTexts["To Do/Interruption.bw.md"].waitForExistence(timeout: 10))
        let url = Self.workspaceRoot.appendingPathComponent("To Do/Interruption.bw.md")
        let external = Data("An unrelated file created after the preview".utf8)
        try external.write(to: url, options: .withoutOverwriting)
        app.buttons["unified.createFiles"].click()
        let problem = app.staticTexts["unified.creationError"]
        XCTAssertTrue(problem.waitForExistence(timeout: 15))
        app.buttons["Later"].click(); XCTAssertTrue(review.waitForExistence(timeout: 10)); review.click()
        let cancel = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'unified.cancelCreation.'")).firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 10)); cancel.click()
        // macOS exposes a duplicate action in its Touch Bar accessibility tree.
        app.windows.buttons["Cancel file creation"].click()
        XCTAssertTrue(review.waitForExistence(timeout: 10))
        XCTAssertEqual(try Data(contentsOf: url), external)
        review.click()
        XCTAssertTrue(app.staticTexts["To Do/Interruption-Mac.bw.md"].waitForExistence(timeout: 10))
        XCTAssertFalse(cancel.exists)
        XCTAssertEqual(try Data(contentsOf: url), external)
        let capture = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        capture.name = "unified-canceled-collision-new-preview-820"; capture.lifetime = .keepAlways; add(capture)
    }

    func testReviewedWorkCreationPreservesCollisionAndReplaysAt820Points() throws {
        let service = WorkItemService()
        let original = try service.create(.init(kind: .task, title: "Same name", body: "Existing Mac original", url: Self.workspaceRoot), in: Self.workspaceRoot.appendingPathComponent("To Do"))
        let originalBytes = try Data(contentsOf: original.url)
        let app = isolatedApp(arguments: ["-bwStartArea", "Workspace", "-bwWindowWidth", "820", "-bwWindowHeight", "520", "-BWUnifiedFixture", UUID().uuidString, "-BWUnifiedFileCreationFixture", "YES"])
        app.launch(); defer { app.terminate() }; requireForeground(app)
        XCTAssertTrue(app.buttons["unified.welcome.local"].waitForExistence(timeout: 15)); app.buttons["unified.welcome.local"].click()
        app.buttons["unified.new"].click()
        let title = app.textFields["unified.editor.title"]
        XCTAssertTrue(title.waitForExistence(timeout: 10)); title.click(); title.typeText("Same name")
        let body = app.textViews["unified.editor.body"]
        body.click(); body.typeText("Created through shared Workspace")
        app.buttons["unified.editor.save"].click()
        app.buttons["unified.includeMac"].click()
        XCTAssertTrue(app.buttons["unified.merge.approve"].waitForExistence(timeout: 10)); app.buttons["unified.merge.approve"].click()
        let review = app.buttons["unified.reviewFiles"]
        XCTAssertTrue(review.waitForExistence(timeout: 10)); review.click()
        XCTAssertTrue(app.staticTexts["To Do/Same name-Mac.bw.md"].waitForExistence(timeout: 10))
        let capture = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        capture.name = "unified-reviewed-file-creation-820"; capture.lifetime = .keepAlways; add(capture)
        app.buttons["unified.createFiles"].click()
        XCTAssertTrue(review.waitForExistence(timeout: 15))
        let createdURL = Self.workspaceRoot.appendingPathComponent("To Do/Same name-Mac.bw.md")
        let created = try XCTUnwrap(service.read(at: createdURL))
        XCTAssertEqual(created.body, "Created through shared Workspace")
        XCTAssertNotEqual(created.id, original.id)
        XCTAssertEqual(try Data(contentsOf: original.url), originalBytes)
        app.terminate(); XCTAssertTrue(app.wait(for: .notRunning, timeout: 10)); app.launch(); requireForeground(app)
        XCTAssertTrue(review.waitForExistence(timeout: 20)); review.click()
        XCTAssertTrue(app.staticTexts["No new Mac items are ready to create."].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["unified.createFiles"].isEnabled)
        XCTAssertEqual(service.items(under: Self.workspaceRoot.appendingPathComponent("To Do")).count, 2)
        XCTAssertEqual(try Data(contentsOf: original.url), originalBytes)
    }

    func testReviewedMergeAndConflictResolutionAtNarrowWidth() {
        let app = isolatedApp(arguments: ["-bwStartArea", "Workspace", "-bwWindowWidth", "820", "-BWUnifiedFixture", UUID().uuidString, "-BWUnifiedReviewFixture", "YES"])
        app.launch(); defer { app.terminate() }; requireForeground(app)
        let review = app.buttons["unified.reviewMerge"]
        XCTAssertTrue(review.waitForExistence(timeout: 15)); review.click()
        let peer = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Review Synthetic Mac'")).firstMatch
        XCTAssertTrue(peer.waitForExistence(timeout: 10)); peer.click()
        XCTAssertTrue(app.buttons["unified.merge.approve"].waitForExistence(timeout: 10)); app.buttons["unified.merge.approve"].click()
        XCTAssertTrue(app.buttons["Done"].waitForExistence(timeout: 10)); app.buttons["Done"].click()
        let note = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Concurrent note' AND identifier BEGINSWITH 'unified.item.'")).firstMatch
        XCTAssertTrue(note.waitForExistence(timeout: 10)); note.click()
        let remote = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Remote version'")).firstMatch
        XCTAssertTrue(remote.waitForExistence(timeout: 10)); remote.click()
        app.buttons["unified.editor.save"].click()
        XCTAssertTrue(note.waitForExistence(timeout: 10)); XCTAssertFalse(note.label.contains("Review both versions"))
        XCTAssertEqual(Set(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'unified.item.'")).allElementsBoundByIndex.map(\.identifier)).count, 3)
    }
}


extension UnifiedWorkspaceUITests {
    func testProjectMetadataAt820PointsSurvivesRestart() {
        let app = isolatedApp(arguments: ["-bwStartArea", "Workspace", "-bwWindowWidth", "820", "-BWUnifiedFixture", UUID().uuidString, "-BWProjectManagementFixture", "YES"])
        app.launch(); defer { app.terminate() }; requireForeground(app)
        let item = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'unified.item.'")).firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 20)); item.click()
        let featured = app.checkBoxes["project.featured"]
        XCTAssertTrue(featured.waitForExistence(timeout: 10)); featured.click()
        app.buttons["unified.editor.save"].click()
        XCTAssertTrue(item.waitForExistence(timeout: 10))
        app.terminate(); app.launch(); requireForeground(app)
        XCTAssertTrue(item.waitForExistence(timeout: 20)); item.click()
        XCTAssertTrue(featured.waitForExistence(timeout: 10)); XCTAssertEqual(featured.value as? Int, 1)
        let capture = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        capture.name = "project-properties-mac-820"; capture.lifetime = .keepAlways; add(capture)
    }
}


extension UnifiedWorkspaceUITests {
    func testReviewedNotesIdeasFoldersAndLaterOfflineEdit() throws {
        let original = Self.workspaceRoot.appendingPathComponent("For Reference/Shared note.md")
        try Data("Existing Mac original".utf8).write(to: original)
        let fixture = UUID().uuidString
        let app = isolatedApp(arguments: ["-bwStartArea", "Workspace", "-bwWindowWidth", "820", "-bwWindowHeight", "520", "-BWUnifiedFixture", fixture, "-BWUnifiedFileCreationFixture", "YES", "-BWUnifiedContentFixture", "YES"])
        app.launch(); defer { app.terminate() }; requireForeground(app)
        XCTAssertTrue(app.buttons["unified.includeMac"].waitForExistence(timeout: 20)); app.buttons["unified.includeMac"].click()
        XCTAssertTrue(app.buttons["unified.merge.approve"].waitForExistence(timeout: 10)); app.buttons["unified.merge.approve"].click()
        let review = app.buttons["unified.reviewFiles"]
        XCTAssertTrue(review.waitForExistence(timeout: 10)); review.click()
        XCTAssertTrue(app.staticTexts["For Reference/Shared note-Mac.md"].waitForExistence(timeout: 10))
        app.buttons["unified.createFiles"].click()
        XCTAssertTrue(review.waitForExistence(timeout: 15)); review.click()
        XCTAssertTrue(app.staticTexts["For Reference/Shared folder/Nested note.md"].waitForExistence(timeout: 10))
        app.buttons["unified.createFiles"].click()
        XCTAssertTrue(review.waitForExistence(timeout: 15))
        let note = Self.workspaceRoot.appendingPathComponent("For Reference/Shared note-Mac.md")
        XCTAssertEqual(try String(contentsOf: original), "Existing Mac original")
        XCTAssertEqual(try String(contentsOf: Self.workspaceRoot.appendingPathComponent("Ideas/Shared idea.md")), "# Shared idea\n\nPhone idea")
        XCTAssertEqual(try String(contentsOf: Self.workspaceRoot.appendingPathComponent("For Reference/Shared folder/Nested note.md")), "# Nested note\n\nNested text")
        let capture = XCTAttachment(screenshot: app.windows.firstMatch.screenshot()); capture.name = "unified-content-created-820"; capture.lifetime = .keepAlways; add(capture)
        app.terminate(); XCTAssertTrue(app.wait(for: .notRunning, timeout: 10))
        let store = try WorkspaceReplicaStore(directory: Self.fixtureRoot.appendingPathComponent("UnifiedAcceptance/" + fixture), initialWorkspaceID: UUID())
        let graph = try store.load()
        let id = try XCTUnwrap(WorkspaceContentIdentity.read(at: note)?.id)
        let head = try XCTUnwrap(graph.records.first(where: { $0.id == id })?.resolved)
        var updated = head.content; updated.body = "Later offline edit"
        _ = try store.save(recordID: id, content: updated, expectedHeads: [head.id], deviceID: UUID(), origin: .iOS)
        app.launch(); requireForeground(app)
        XCTAssertTrue(review.waitForExistence(timeout: 20)); review.click()
        XCTAssertTrue(app.staticTexts["No new Mac items are ready to create."].waitForExistence(timeout: 15))
        XCTAssertEqual(try String(contentsOf: note), "# Shared note\n\nLater offline edit")
        XCTAssertEqual(try String(contentsOf: original), "Existing Mac original")
        XCTAssertEqual(try WorkspaceContentIdentity.read(at: note)?.id, id)
    }
}
