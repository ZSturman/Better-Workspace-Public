import Foundation
import SwiftData

/// App-owned records, separate from the read-only index of a person's Mac folders.
/// Defaults and optional links keep the schema compatible with CloudKit mirroring.
@Model
public final class WorkspaceNotebookRecord {
    public var recordID: UUID = UUID()
    public var kindValue: String = "idea"
    public var title: String = ""
    public var body: String = ""
    public var projectID: UUID?
    public var isComplete: Bool = false
    public var isArchived: Bool = false
    public var createdAt: Date = Date()
    public var modifiedAt: Date = Date()

    public init(kind: WorkspaceNotebookKind, title: String, body: String = "", projectID: UUID? = nil) {
        kindValue = kind.rawValue
        self.title = title
        self.body = body
        self.projectID = projectID
    }

    public var kind: WorkspaceNotebookKind { WorkspaceNotebookKind(rawValue: kindValue) ?? .document }
}

public enum WorkspaceNotebookKind: String, CaseIterable, Identifiable, Codable, Sendable {
    case project, task, idea, document
    public var id: String { rawValue }
    public var title: String {
        switch self { case .project: "Project"; case .task: "Task"; case .idea: "Idea"; case .document: "Document" }
    }
    public var symbol: String {
        switch self { case .project: "square.stack.3d.up"; case .task: "checklist"; case .idea: "lightbulb"; case .document: "doc.text" }
    }
}

public enum WorkspaceNotebookPersistence {
    /// Enabled only in products whose signed profiles support private CloudKit
    /// and push delivery. A missing setting keeps older/development hosts local.
    public static var isCloudSyncEnabled: Bool {
        !TestIsolation.isActive && (Bundle.main.object(forInfoDictionaryKey: "BWNotebookCloudSyncEnabled") as? Bool == true)
    }
    @MainActor private static var live: ModelContainer?
    /// All windows in one app share a coordinator and observe the same saves.
    @MainActor public static func sharedContainer() throws -> ModelContainer {
        if let live { return live }
        let container = try container(cloudEnabled: isCloudSyncEnabled)
        live = container
        return container
    }

    /// Cloud sync is explicit. Local mode never constructs a CloudKit container.
    /// Use a private app-owned URL, never an organized workspace or service database.
    public static func container(at url: URL? = nil, inMemory: Bool = false,
                                 cloudEnabled: Bool = false) throws -> ModelContainer {
        let schema = Schema([WorkspaceNotebookRecord.self])
        let configuration: ModelConfiguration
        if inMemory {
            configuration = ModelConfiguration("PersonalWorkspace", schema: schema,
                isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        } else {
            let storeURL: URL
            if let url { storeURL = url }
            else {
                let base = TestIsolation.sandbox ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                storeURL = base.appendingPathComponent("BetterWorkspace/PersonalWorkspace/Notebook.store")
            }
            try FileManager.default.createDirectory(at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            configuration = ModelConfiguration("PersonalWorkspace", schema: schema, url: storeURL,
                cloudKitDatabase: cloudEnabled && !TestIsolation.isActive ? .private(MobileCloudSchema.containerIdentifier) : .none)
        }
        return try ModelContainer(for: schema, configurations: [configuration])
    }
}

@MainActor
public enum WorkspaceNotebookEditor {
    public enum Failure: LocalizedError {
        case emptyTitle, tooLarge, changed, missingProject
        public var errorDescription: String? {
            switch self {
            case .emptyTitle: "Give this item a title."
            case .tooLarge: "Keep the title under 280 characters and the document under 1 MB."
            case .changed: "This item changed while you were editing. Close this draft and open the latest version."
            case .missingProject: "That project is no longer available. Choose another project or None."
            }
        }
    }

    @discardableResult
    public static func save(in context: ModelContext, record: WorkspaceNotebookRecord? = nil,
                            expectedModifiedAt: Date? = nil, kind: WorkspaceNotebookKind,
                            title: String, body: String, projectID: UUID?) throws -> WorkspaceNotebookRecord {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw Failure.emptyTitle }
        guard title.count <= 280, body.utf8.count <= 1_048_576 else { throw Failure.tooLarge }
        if let record, let expectedModifiedAt, record.modifiedAt != expectedModifiedAt { throw Failure.changed }
        if let projectID {
            let candidates = try context.fetch(FetchDescriptor<WorkspaceNotebookRecord>())
            guard kind != .project, candidates.contains(where: { $0.recordID == projectID && $0.kind == .project && !$0.isArchived }) else {
                throw Failure.missingProject
            }
        }
        let item = record ?? WorkspaceNotebookRecord(kind: kind, title: title)
        if record == nil { context.insert(item) }
        item.title = title; item.body = body; item.kindValue = kind.rawValue
        item.projectID = projectID; item.modifiedAt = Date()
        do { try context.save() } catch { context.rollback(); throw error }
        return item
    }

    /// Recoverable archive, rather than permanent deletion or any filesystem mutation.
    public static func setArchived(_ archived: Bool, record: WorkspaceNotebookRecord, in context: ModelContext) throws {
        record.isArchived = archived; record.modifiedAt = Date()
        do { try context.save() } catch { context.rollback(); throw error }
    }
}
