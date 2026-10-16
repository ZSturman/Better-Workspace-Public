import XCTest
import SwiftData
@testable import BetterWorkspaceCore

@MainActor
final class WorkspaceNotebookTests: XCTestCase {
    func testProjectAndTaskSaveThenReopenFromOwnedDiskStore() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bw-notebook-test-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("Notebook.store")
        let first = try WorkspaceNotebookPersistence.container(at: url)
        let project = try WorkspaceNotebookEditor.save(in: first.mainContext, kind: .project,
            title: "  Release fixture  ", body: "# A project", projectID: nil)
        let task = try WorkspaceNotebookEditor.save(in: first.mainContext, kind: .task,
            title: "Write a plan", body: "Offline note", projectID: project.recordID)
        let second = try WorkspaceNotebookPersistence.container(at: url)
        let restored = try second.mainContext.fetch(FetchDescriptor<WorkspaceNotebookRecord>())
        XCTAssertEqual(restored.count, 2)
        XCTAssertEqual(restored.first(where: { $0.recordID == project.recordID })?.title, "Release fixture")
        XCTAssertEqual(restored.first(where: { $0.recordID == task.recordID })?.projectID, project.recordID)
    }

    func testInvalidAndStaleEditsPreserveOriginal() throws {
        let container = try WorkspaceNotebookPersistence.container(inMemory: true)
        let context = container.mainContext
        let item = try WorkspaceNotebookEditor.save(in: context, kind: .idea, title: "Original", body: "Keep me", projectID: nil)
        let original = item.modifiedAt
        item.modifiedAt = original.addingTimeInterval(10)
        try context.save()
        XCTAssertThrowsError(try WorkspaceNotebookEditor.save(in: context, record: item, expectedModifiedAt: original,
            kind: .idea, title: "Overwrite", body: "", projectID: nil))
        XCTAssertThrowsError(try WorkspaceNotebookEditor.save(in: context, kind: .task, title: "   ", body: "", projectID: nil))
        XCTAssertThrowsError(try WorkspaceNotebookEditor.save(in: context, kind: .task,
            title: "Unbound", body: "", projectID: UUID()))
        XCTAssertEqual(item.title, "Original")
        XCTAssertEqual(item.body, "Keep me")
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<WorkspaceNotebookRecord>()), 1)
    }

    func testArchiveCanBeRestoredAndDoesNotDeleteLinkedTasks() throws {
        let container = try WorkspaceNotebookPersistence.container(inMemory: true)
        let context = container.mainContext
        let project = try WorkspaceNotebookEditor.save(in: context, kind: .project, title: "Project", body: "", projectID: nil)
        let task = try WorkspaceNotebookEditor.save(in: context, kind: .task, title: "Task", body: "", projectID: project.recordID)
        try WorkspaceNotebookEditor.setArchived(true, record: project, in: context)
        XCTAssertTrue(project.isArchived)
        XCTAssertFalse(task.isArchived)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<WorkspaceNotebookRecord>()), 2)
        XCTAssertThrowsError(try WorkspaceNotebookEditor.save(in: context, kind: .task, title: "New task", body: "", projectID: project.recordID))
        try WorkspaceNotebookEditor.setArchived(false, record: project, in: context)
        XCTAssertFalse(project.isArchived)
    }

    func testMemorySampleNeverCreatesPersistentConfigurationOrUsesCloud() throws {
        let container = try WorkspaceNotebookPersistence.container(inMemory: true, cloudEnabled: true)
        XCTAssertTrue(container.configurations.allSatisfy(\.isStoredInMemoryOnly))
        XCTAssertTrue(container.configurations.allSatisfy { $0.cloudKitContainerIdentifier == nil })
    }
}

final class OverviewLayoutTests: XCTestCase {
    func testHiddenSectionsKeepCustomOrderAcrossRelaunch() {
        let layout = OverviewLayout(order: [.review, .nextAction, .review, .attention], hidden: [.attention])
        let restored = OverviewLayout.load(layout.encoded)
        XCTAssertEqual(restored.visible(in: [.nextAction, .attention, .review]), [.review, .nextAction])
        XCTAssertEqual(Set(restored.order).count, restored.order.count)
    }

    func testInvalidPreferencesFallBackToPlatformOrderAndNewSectionsRemainAvailable() {
        let platform: [OverviewSectionID] = [.nextAction, .review, .focus]
        XCTAssertEqual(OverviewLayout.load("invalid", defaultOrder: platform).visible(in: platform), platform)
        let old = OverviewLayout(order: [.review])
        XCTAssertTrue(old.order.contains(.nextAction))
        XCTAssertTrue(OverviewLayout.simple.visible(in: [.nextAction, .review, .health]).contains(.nextAction))
        XCTAssertFalse(OverviewLayout.simple.visible(in: [.nextAction, .review, .health]).contains(.health))
    }
}
