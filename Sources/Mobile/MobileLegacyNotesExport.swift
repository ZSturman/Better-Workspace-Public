import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import BetterWorkspaceCore

/// Recovery access without presenting the former notebook as another workspace.
struct MobileLegacyNotesExportButton: View {
    @State private var document: LegacyNotesDocument?
    @State private var exporting = false
    @State private var error: String?
    var body: some View {
        Button("Export earlier personal notes", systemImage: "square.and.arrow.up") {
            do {
                let container = try WorkspaceNotebookPersistence.sharedContainer()
                let records = try container.mainContext.fetch(FetchDescriptor<WorkspaceNotebookRecord>())
                let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
                document = LegacyNotesDocument(data: try encoder.encode(records.map(LegacyNote.init)))
                exporting = true
            } catch { self.error = error.localizedDescription }
        }
        .disabled(TestIsolation.isActive || UserDefaults.standard.bool(forKey: "BWTestMobilePlanning"))
        .fileExporter(isPresented: $exporting, document: document, contentType: .json, defaultFilename: "Better-Workspace-earlier-notes") { result in
            if case .failure(let failure) = result { error = failure.localizedDescription }
        }
        if let error { Text(error).font(.caption).foregroundStyle(.orange) }
    }
}

private struct LegacyNote: Encodable {
    let id: UUID
    let kind: String
    let title: String
    let body: String
    let projectID: UUID?
    let isComplete: Bool
    let isArchived: Bool
    let createdAt: Date
    let modifiedAt: Date
    init(_ record: WorkspaceNotebookRecord) {
        id = record.recordID; kind = record.kindValue; title = record.title; body = record.body; projectID = record.projectID
        isComplete = record.isComplete; isArchived = record.isArchived; createdAt = record.createdAt; modifiedAt = record.modifiedAt
    }
}

private struct LegacyNotesDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}
