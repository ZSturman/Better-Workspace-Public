import Foundation

/// Uses the same property model as projects. Kept in the existing service-owned
/// planning envelope, so offline editing and mobile projection share one record.
public struct IdeaProjectDetails: Codable, Hashable, Sendable {
    public var metadata: ProjectMetadata
    public var oneLiner: String
    public var summary: String
    public var automaticNotionSync: Bool
    public init(metadata: ProjectMetadata = .init(), oneLiner: String = "", summary: String = "", automaticNotionSync: Bool = true) {
        self.metadata = metadata; self.oneLiner = oneLiner; self.summary = summary; self.automaticNotionSync = automaticNotionSync
    }
}

public enum IdeaProjectBridge {
    public static func directoryPath(_ value: String) -> String {
        if let url = URL(string: value), url.isFileURL { return url.path }
        return value
    }
    public static func recordID(_ serviceID: String) -> String { "idea-project:" + serviceID }
    public static func isPotentialRecord(_ record: ProjectGraphRecord) -> Bool {
        record.kind == .projects && record.localProjectID == nil && (record.id.hasPrefix("idea-project:") || record.serviceRecordID != nil)
    }
    public static func canAutomaticallySend(_ record: ProjectGraphRecord, source: ProjectGraphSource) -> Bool {
        isPotentialRecord(record) && !record.remoteArchived && record.locallyDeleted != true && promotedStatus(record, source: source) == nil
    }
    public static func promotedStatus(_ record: ProjectGraphRecord, source: ProjectGraphSource) -> String? {
        guard !record.remoteArchived, let field = source.property(named: "Status"),
              let value = record.remote[field.id], !value.display.isEmpty,
              ProjectViewQuery.normalize(value.display) != "idea", !ProjectMetadata(status: value.display).isTerminal else { return nil }
        return value.display
    }
    /// Identity first, then exact declared directory. Ambiguity is an error; name
    /// similarity is never enough to adopt a Notion page or create another one.
    public static func existing(serviceID: String, path: String, records: [ProjectGraphRecord], source: ProjectGraphSource) throws -> ProjectGraphRecord? {
        let bound = records.filter { $0.sourceID == source.id && ($0.id == recordID(serviceID) || $0.serviceRecordID == serviceID) }
        let matches = bound.isEmpty ? records.filter {
            $0.sourceID == source.id && $0.kind == .projects && !$0.remoteArchived && directoryPath($0.value("Local Directory", source: source).display) == path
        } : bound
        guard matches.count <= 1 else { throw NotionProjectSync.SyncError.unsupported("More than one Notion project matches this idea. Resolve the duplicate links in Sync Center before retrying.") }
        return matches.first
    }
    /// A Notion project with the same title and no Local Directory: probably this idea,
    /// recorded before it had a folder. Titles never establish identity, so the bridge
    /// does not adopt it, but it must not create a look-alike page either. Setting that
    /// page's Local Directory to the idea's folder links it by exact directory.
    public static func unlinkedTitleMatch(title: String, records: [ProjectGraphRecord], source: ProjectGraphSource) -> ProjectGraphRecord? {
        let wanted = ProjectViewQuery.normalize(title)
        guard !wanted.isEmpty, let titleID = source.schema.object.first(where: { $0.value["type"].string == "title" })?.value["id"].string else { return nil }
        let directoryID = source.property(named: "Local Directory")?.id
        return records.first { record in
            guard record.sourceID == source.id, record.kind == .projects, record.pageID != nil, !record.remoteArchived, record.serviceRecordID == nil else { return false }
            let titles = [record.local[titleID], record.remote[titleID]].compactMap { $0?.display }
            let directories = directoryID.map { [record.local[$0], record.remote[$0]].compactMap { $0?.display } } ?? []
            return titles.contains { ProjectViewQuery.normalize($0) == wanted } && directories.allSatisfy(\.isEmpty)
        }
    }
    public static func applying(serviceID: String, title: String, path: String, details: IdeaProjectDetails, tags: [String], ratings: [String: Int], to existing: ProjectGraphRecord?, source: ProjectGraphSource) throws -> ProjectGraphRecord {
        if let existing, existing.localProjectID != nil { return existing }
        guard source.kind == .projects, let titleField = source.schema.object.first(where: { $0.value["type"].string == "title" })?.key,
              let status = source.property(named: "Status"), ["select", "status"].contains(status.definition["type"].display),
              let directory = source.property(named: "Local Directory"), ["rich_text", "url"].contains(directory.definition["type"].display) else {
            throw NotionProjectSync.SyncError.unsupported("Projects needs a title, Status and writable Local Directory property. Refresh the Notion schema in Settings.")
        }
        var values: [String: ProjectJSON] = [
            titleField: ProjectServiceBridge.text(title),
            "Local Directory": directory.definition["type"].display == "url" ? .string(URL(fileURLWithPath: path).absoluteString) : ProjectServiceBridge.text(path),
        ]
        func shouldSupply(_ name: String, empty: Bool) -> Bool {
            !empty || existing == nil || source.property(named: name).map { existing?.serviceSnapshot?[$0.id] != nil } == true
        }
        for (name, text) in [("one liner", details.oneLiner), ("summary", details.summary)] where shouldSupply(name, empty: text.isEmpty) { values[name] = ProjectServiceBridge.text(text) }
        if existing == nil || existing?.pageID == nil || existing?.remote[status.id]?.display == "Idea" {
            values["Status"] = ProjectJSON(["name": "Idea"])
        }
        for (name, value) in [("domain", details.metadata.domain), ("Type", details.metadata.projectType), ("Phase", details.metadata.phase)] {
            guard shouldSupply(name, empty: value?.isEmpty != false), let field = source.property(named: name) else { continue }
            let names = (value ?? "").components(separatedBy: ", ").filter { !$0.isEmpty }
            values[name] = field.definition["type"].display == "multi_select" ? ProjectJSON(names.map { ["name": $0] }) : names.first.map { ProjectJSON(["name": $0]) } ?? .null
        }
        if shouldSupply("tags", empty: tags.isEmpty), let field = source.property(named: "tags"), field.definition["type"].display == "multi_select" { values["tags"] = ProjectJSON(tags.map { ["name": $0] }) }
        for metric in MetricDefinition.all { if let rating = ratings[metric.id] { values[metric.displayName] = .number(Double(rating)) } }
        let initial = existing ?? ProjectGraphRecord(id: recordID(serviceID), sourceID: source.id, kind: .projects)
        var result = ProjectServiceBridge.applying(values, serviceID: serviceID, to: initial, source: source)
        result.localPath = path
        return result
    }
}
