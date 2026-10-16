import XCTest
import Foundation
import SwiftData
import CoreData
import BetterWorkspaceCore

/// Explicitly opted-in, signed app-hosted Development CloudKit acceptance.
/// Never opens a live app store or uses the filesystem-index/command channels.
@MainActor
final class NotebookCloudAcceptanceTests: XCTestCase {
    private var exports: [(String, Date)] = []
    private var imports: [(String, Date)] = []
    private var errors: [String] = []

    func testPrivateCreateEditAndCleanupWithFreshStoreReadback() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["BW_RUN_NOTEBOOK_CLOUD_ACCEPTANCE"] == "1",
                          "Requires explicit disposable Development CloudKit acceptance")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bw-app-cloud-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let observer = NotificationCenter.default.addObserver(forName: NSPersistentCloudKitContainer.eventChangedNotification,
            object: nil, queue: .main) { [weak self] note in
            guard let event = note.userInfo?[NSPersistentCloudKitContainer.eventNotificationUserInfoKey] as? NSPersistentCloudKitContainer.Event else { return }
            Task { @MainActor in
                if event.type == .export, event.succeeded, let end = event.endDate { self?.exports.append((event.storeIdentifier, end)) }
                if event.type == .import, event.succeeded, let end = event.endDate { self?.imports.append((event.storeIdentifier, end)) }
                if event.endDate != nil && !event.succeeded { self?.errors.append(event.error?.localizedDescription ?? "Unknown sync error") }
            }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        let writer = try WorkspaceNotebookPersistence.container(at: root.appendingPathComponent("Writer/Notebook.store"), cloudEnabled: true)
        let project = WorkspaceNotebookRecord(kind: .project, title: "Disposable verification project " + UUID().uuidString)
        let item = WorkspaceNotebookRecord(kind: .idea, title: "Disposable app-hosted verification " + UUID().uuidString, projectID: project.recordID)
        let id = item.recordID
        try Data(id.uuidString.utf8).write(to: root.appendingPathComponent("owned-record-id.txt"))
        try JSONEncoder().encode([project.recordID, id]).write(to: root.appendingPathComponent("owned-record-ids.json"))
        var cleaned = false
        do {
            let created = Date()
            writer.mainContext.insert(project); writer.mainContext.insert(item); try writer.mainContext.save()
            try await wait("first export") { self.exports.contains { $0.1 >= created } }
            let writerID = try XCTUnwrap(exports.first { $0.1 >= created }?.0)
            let reader = try WorkspaceNotebookPersistence.container(at: root.appendingPathComponent("Reader/Notebook.store"), cloudEnabled: true)
            let query = FetchDescriptor<WorkspaceNotebookRecord>(predicate: #Predicate { $0.recordID == id })
            try await wait("separate-store import") {
                let restored = try ModelContext(reader).fetch(query).first
                return restored?.title == item.title && restored?.projectID == project.recordID
            }
            let edited = Date()
            item.body = "A second save after initial synchronization"; item.modifiedAt = edited
            try writer.mainContext.save()
            try await wait("live edit export") { self.exports.contains { $0.0 == writerID && $0.1 >= edited } }
            // CloudKit can exclude the originating device from push delivery. A
            // second store on this Mac is not a separate device: use a fresh
            // initial import to verify persisted edits, and test push separately
            // on physical devices rather than inventing a same-device deadline.
            let editedReader = try WorkspaceNotebookPersistence.container(at: root.appendingPathComponent("EditedReader/Notebook.store"), cloudEnabled: true)
            try await wait("edited record readback") { try ModelContext(editedReader).fetch(query).first?.body == item.body }
            let deleted = Date()
            writer.mainContext.delete(item); writer.mainContext.delete(project); try writer.mainContext.save()
            try await wait("owned-record cleanup export") { self.exports.contains { $0.0 == writerID && $0.1 >= deleted } }
            let cleanURL = root.appendingPathComponent("CleanReader/Notebook.store")
            let cleanReader = try WorkspaceNotebookPersistence.container(at: cleanURL, cloudEnabled: true)
            let metadata = try NSPersistentStoreCoordinator.metadataForPersistentStore(ofType: NSSQLiteStoreType, at: cleanURL)
            let cleanID = try XCTUnwrap(metadata[NSStoreUUIDKey] as? String)
            try await wait("cleanup reader initial import") { self.imports.contains { $0.0 == cleanID } }
            XCTAssertTrue(try ModelContext(cleanReader).fetch(query).isEmpty)
            cleaned = true
            let report: [String: Any] = ["create_export_import": "passed", "linked_project_id_import": "passed", "edit_export_fresh_import": "passed",
                "owned_record_cleanup": "passed", "scope": "Signed Mac app, two isolated stores; not physical cross-device acceptance",
                "fixture": root.path, "environment": ProcessInfo.processInfo.environment["BW_NOTEBOOK_CLOUD_ENVIRONMENT"] ?? "Development"]
            let attachment = XCTAttachment(data: try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]), uniformTypeIdentifier: "public.json")
            attachment.name = "app-hosted-notebook-cloud-acceptance"; attachment.lifetime = .keepAlways; add(attachment)
            withExtendedLifetime((writer, reader, editedReader, cleanReader)) {}
        } catch {
            if !cleaned {
                // Only this exact UUID belongs to the test. Save a tombstone even on
                // failure and retain its checkpoint/store if export needs a retry.
                let query = FetchDescriptor<WorkspaceNotebookRecord>(predicate: #Predicate { $0.recordID == id })
                for record in try writer.mainContext.fetch(query) { writer.mainContext.delete(record) }
                let projectID = project.recordID
                let projectQuery = FetchDescriptor<WorkspaceNotebookRecord>(predicate: #Predicate { $0.recordID == projectID })
                for record in try writer.mainContext.fetch(projectQuery) { writer.mainContext.delete(record) }
                let cleanup = Date()
                try writer.mainContext.save()
                try? await wait("cleanup after failed verification") { self.exports.contains { $0.1 >= cleanup } }
            }
            XCTFail("\(error.localizedDescription). Owned fixture retained at \(root.path)")
            throw error
        }
    }

    private func wait(_ operation: String, until condition: () throws -> Bool) async throws {
        let deadline = Date().addingTimeInterval(90)
        while Date() < deadline {
            if try condition() { return }
            if let error = errors.first { throw NSError(domain: "NotebookCloudAcceptance", code: 1, userInfo: [NSLocalizedDescriptionKey: operation + ": " + error]) }
            try await Task.sleep(for: .seconds(1))
        }
        throw NSError(domain: "NotebookCloudAcceptance", code: 2, userInfo: [NSLocalizedDescriptionKey: "Timed out: " + operation])
    }
}
