import Foundation

/// Private metadata snapshot; paths and project IDs are never part of the model input.
public struct ProjectSuggestionBaseline: Sendable {
    public let projectID: String
    public let path: String
    public let identityKey: String?
    public let description: ProjectDescription
    public let metadata: ProjectMetadata
    public let assignedTagIDs: Set<String>
    public init(projectID: String, path: String, description: ProjectDescription, metadata: ProjectMetadata, assignedTagIDs: Set<String>) {
        self.projectID = projectID; self.path = path; self.description = description
        self.identityKey = FileIdentityResolver.identity(of: URL(fileURLWithPath: path))?.key
        self.metadata = metadata; self.assignedTagIDs = assignedTagIDs
    }
}

public enum ProjectMetadataSuggestions {
    /// Adds tags (never removes assignments) and optionally replaces the one-liner.
    /// Store methods historically swallow database errors, so every write is verified before commit.
    @discardableResult
    public static func apply(database: Database, baseline: ProjectSuggestionBaseline, oneLiner: String?,
                             tags: [LMStudioTagSuggestion], approvedNewTagIDs: Set<String>) throws -> Set<String> {
        let projects = ProjectStore(database: database), store = TagStore(database: database)
        let url = URL(fileURLWithPath: baseline.path)
        return try database.transaction {
            guard let record = projects.record(id: baseline.projectID), record.lastPath == url.canonicalPath,
                  baseline.identityKey != nil, FileIdentityResolver.identity(of: url)?.key == baseline.identityKey,
                  (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                  projects.description(for: baseline.projectID) == baseline.description,
                  projects.metadata(for: baseline.projectID) == baseline.metadata,
                  Set(store.tags(for: url).map(\.id)) == baseline.assignedTagIDs else { throw LMStudioError.stale }
            var fields = Set<String>()
            if let oneLiner {
                let line = oneLiner.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !line.isEmpty, line.count <= 240, !line.contains(where: { $0.isNewline }) else { throw LMStudioError.invalidResponse("the edited one-liner must be a single line of 1–240 characters") }
                var description = baseline.description; description.oneLiner = line
                if description != baseline.description {
                    projects.setDescription(description, for: baseline.projectID)
                    guard projects.description(for: baseline.projectID) == description else { throw LMStudioError.saveFailed }
                    fields.insert("one liner")
                }
            }
            for suggestion in tags {
                let tag: Tag
                if let id = suggestion.existingID {
                    guard let existing = store.allTags().first(where: { $0.id == id && $0.name == suggestion.name }) else { throw LMStudioError.stale }
                    tag = existing
                } else {
                    guard approvedNewTagIDs.contains(suggestion.id), !suggestion.reason.isEmpty,
                          !TagMatching.normalized(suggestion.name).isEmpty, suggestion.name.count <= 80 else {
                        throw LMStudioError.invalidResponse("each new tag must be explicitly approved")
                    }
                    if let existing = store.existingTag(equivalentTo: suggestion.name) { tag = existing }
                    else {
                        guard let created = store.createTag(named: suggestion.name), store.allTags().contains(where: { $0.id == created.id }) else { throw LMStudioError.saveFailed }
                        tag = created
                    }
                }
                if !baseline.assignedTagIDs.contains(tag.id) {
                    store.assign(tagID: tag.id, to: url, area: "Projects")
                    guard store.tags(for: url).contains(where: { $0.id == tag.id }) else { throw LMStudioError.saveFailed }
                    fields.insert("tags")
                }
            }
            return fields
        }
    }
}
