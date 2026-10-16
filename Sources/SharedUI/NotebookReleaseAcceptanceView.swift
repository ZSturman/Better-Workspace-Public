import SwiftUI
import SwiftData
import CoreData
import CloudKit
import BetterWorkspaceCore

/// Test-only launch surface available in signed Release builds. It displays and
/// edits only the two UUID records owned by the requested disposable session.
struct NotebookReleaseAcceptanceView: View {
    let sessionID: UUID
    @State private var container: ModelContainer?
    @State private var failure: String?

    var body: some View {
        Group {
            if let container { NotebookAcceptanceRecords(sessionID: sessionID).modelContainer(container) }
            else if let failure { ContentUnavailableView("Verification store could not open", systemImage: "exclamationmark.triangle", description: Text(failure)) }
            else { ProgressView("Opening isolated verification…") }
        }
        .task { @MainActor in
            guard container == nil else { return }
            do { container = try WorkspaceNotebookPersistence.container(at: NotebookReleaseAcceptance.storeURL(for: sessionID), cloudEnabled: true) }
            catch { failure = error.localizedDescription }
        }
        #if os(macOS)
        .frame(minWidth: 620, minHeight: 520)
        #endif
    }
}

private struct NotebookAcceptanceRecords: View {
    let sessionID: UUID
    let taskID: UUID
    @Environment(\.modelContext) private var context
    @Query private var records: [WorkspaceNotebookRecord]
    @State private var error: String?
    @State private var mutationDate: Date?
    @State private var exportConfirmed = false
    @State private var accountStatus = "Checking iCloud account"
    @State private var importStatus = "Waiting for import"

    init(sessionID: UUID) {
        self.sessionID = sessionID
        let taskID = NotebookReleaseAcceptance.taskID(for: sessionID)
        self.taskID = taskID
        _records = Query(filter: #Predicate<WorkspaceNotebookRecord> { $0.recordID == sessionID || $0.recordID == taskID })
    }

    private var projectTitle: String { "Release verification project " + sessionID.uuidString }
    private var taskTitle: String { "Release verification task " + sessionID.uuidString }
    private var task: WorkspaceNotebookRecord? { records.first { $0.recordID == taskID } }
    private var phase: String { task?.body ?? "waiting-for-owned-fixtures" }

    var body: some View {
        NavigationStack {
            Form {
                Section("Isolated release verification") {
                    Text("Only this session’s two disposable records are shown. Your personal workspace, Mac folder index, capture queues and widgets are not opened by this mode.")
                    Text(sessionID.uuidString).font(.caption.monospaced()).textSelection(.enabled)
                    Text(phase).accessibilityIdentifier("release.cloud.phase")
                    Text("Owned records: \(records.count)").accessibilityIdentifier("release.cloud.count")
                    Text(exportConfirmed ? "Export confirmed" : "Waiting for export").accessibilityIdentifier("release.cloud.export")
                    Text(accountStatus).accessibilityIdentifier("release.cloud.account")
                    Text(importStatus).accessibilityIdentifier("release.cloud.import")
                }
                Section {
                    Button("Create owned fixtures") { change { try create() } }.accessibilityIdentifier("release.cloud.create")
                        .disabled(!records.isEmpty)
                    Button("Update owned task") { change { try update() } }.accessibilityIdentifier("release.cloud.update")
                        .disabled(task == nil)
                    Button("Remove owned fixtures") { change { try cleanup() } }.accessibilityIdentifier("release.cloud.cleanup")
                        .disabled(records.isEmpty)
                }
                if let error { Text(error).foregroundStyle(.red).accessibilityIdentifier("release.cloud.error") }
            }
            .navigationTitle("Release sync verification")
            .task { @MainActor in
                do {
                    let status = try await CKContainer(identifier: "iCloud.com.zacharysturman.BetterWorkspace").accountStatus()
                    accountStatus = status == .available ? "iCloud account available" : "iCloud account unavailable (\(status.rawValue))"
                    if status != .available { error = accountStatus }
                } catch {
                    self.error = "iCloud account check failed (\((error as NSError).domain):\((error as NSError).code))"
                }
            }
            .task { @MainActor in
                for await notification in NotificationCenter.default.notifications(named: NSPersistentCloudKitContainer.eventChangedNotification) {
                    guard let event = notification.userInfo?[NSPersistentCloudKitContainer.eventNotificationUserInfoKey] as? NSPersistentCloudKitContainer.Event else { continue }
                    if event.type == .export, event.succeeded, event.endDate != nil,
                       let mutationDate, event.startDate >= mutationDate { exportConfirmed = true }
                    if event.type == .import, event.endDate != nil {
                        importStatus = event.succeeded ? "Import confirmed" : "Import failed"
                    }
                    if let eventError = event.error as NSError? {
                        error = "Cloud sync failed (\(eventError.domain):\(eventError.code))"
                    }
                }
            }
        }
    }

    private func change(_ operation: () throws -> Void) {
        do { mutationDate = Date(); exportConfirmed = false; try operation(); error = nil }
        catch { context.rollback(); self.error = error.localizedDescription }
    }

    private func verifyOwnership() throws {
        guard records.allSatisfy({ ($0.recordID == sessionID && $0.title == projectTitle && $0.kind == .project) ||
            ($0.recordID == taskID && $0.title == taskTitle && $0.kind == .task && $0.projectID == sessionID) }) else {
            throw NSError(domain: "NotebookAcceptance", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unexpected record identity; refusing to edit or delete it."])
        }
    }

    private func create() throws {
        guard records.isEmpty else { return }
        let project = WorkspaceNotebookRecord(kind: .project, title: projectTitle)
        project.recordID = sessionID
        let task = WorkspaceNotebookRecord(kind: .task, title: taskTitle, body: "phase-1", projectID: sessionID)
        task.recordID = taskID
        context.insert(project); context.insert(task); try context.save()
    }

    private func update() throws {
        try verifyOwnership()
        guard let task else { return }
        task.body = "phase-2"; task.isComplete = true; task.modifiedAt = Date()
        try context.save()
    }

    private func cleanup() throws {
        try verifyOwnership()
        for record in records { context.delete(record) }
        try context.save()
    }
}
