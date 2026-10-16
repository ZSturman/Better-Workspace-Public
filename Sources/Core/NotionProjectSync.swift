import Foundation

public struct ProjectSyncReport: Codable, Sendable {
    public var checkedAt: Date?
    public var workspaceName = "Notion"
    public var counts: [String: Int] = [:]
    public var failures: [String: String] = [:]
    public var unresolvedReferences = 0
    public var referenceDetails: [String: Int]? = nil
    public init() {}
}

/// One coordinator for explicit writes and headless reads. Only check() runs in the background.
public actor NotionProjectSync {
    public enum SyncError: LocalizedError {
        case busy, incomplete(String), conflict(String), ambiguous(String), stale, unsupported(String)
        public var errorDescription: String? {
            switch self {
            case .busy: return "Another Notion operation is running."
            case .incomplete(let source): return "Notion returned an incomplete source: \(source). The previous snapshot was retained."
            case .conflict(let title): return "Review conflicting fields in \(title) before syncing."
            case .ambiguous(let title): return "Notion may have created \(title). Reconcile this record before retrying."
            case .stale: return "This record changed after review. Review its latest changes before syncing."
            case .unsupported(let message): return message
            }
        }
    }
    private let store: ProjectGraphStore
    private let client: NotionClient
    public init(store: ProjectGraphStore, client: NotionClient) { self.store = store; self.client = client }

    public func check(seeds: [ProjectEntityKind: String], disabled: Set<ProjectEntityKind> = [], forceFull: Bool = false) async throws -> ProjectSyncReport {
        let owner = "pid:\(ProcessInfo.processInfo.processIdentifier):\(UUID().uuidString)"
        guard try store.acquire(owner: owner) else { throw SyncError.busy }
        defer { try? store.release(owner: owner) }
        var report = ProjectSyncReport()
        report.workspaceName = (try? await client.graphRequest("users/me"))?["bot"]["workspace_name"].string ?? "Notion"
        var sources = try store.read("sources", as: [ProjectGraphSource].self) ?? []
        // Existing explicit source choices win over relation discovery.
        for (kind, id) in seeds where !disabled.contains(kind) {
            do {
                let source = try await client.graphSource(id, kind: kind)
                sources.removeAll { $0.kind == kind }; sources.append(source)
            } catch { report.failures[kind.title] = error.localizedDescription }
        }
        sources.removeAll { disabled.contains($0.kind) }
        var checked = Set<String>(), position = 0
        while position < sources.count {
            let source = sources[position]; position += 1
            guard checked.insert(source.id).inserted else { continue }
            for property in source.schema.object.values where property["type"].string == "relation" {
                guard let id = property["relation"]["data_source_id"].string,
                      !sources.contains(where: { $0.id == id }) else { continue }
                do {
                    let next = try await client.graphSource(id)
                    guard let kind = ProjectEntityKind.matching(next.title), !disabled.contains(kind),
                          !sources.contains(where: { $0.kind == kind }) else { continue }
                    sources.append(ProjectGraphSource(id: next.id, title: next.title, kind: kind, schema: next.schema))
                } catch { report.failures[id] = error.localizedDescription }
            }
        }
        try store.write("sources", sources)
        let fullAt = try store.read("lastFullCheck", as: Date.self)
        let full = forceFull || fullAt == nil || Date().timeIntervalSince(fullAt!) > 86400
        let retainedCounts = Dictionary(grouping: try store.records().filter { $0.pageID != nil }, by: \.sourceID).mapValues(\.count)
        var changedTaskIDs = Set<String>(), changedTaskRelations = Set<String>(), ingested = Set<String>()
        for source in sources {
            report.counts[source.title] = retainedCounts[source.id] ?? 0
            let started = Date()
            do {
                let since = full ? nil : try store.read("cursor:\(source.id)", as: Date.self)?.addingTimeInterval(-120)
                let result = try await client.graphPages(sourceID: source.id, since: since)
                guard result.complete else { throw SyncError.incomplete(source.title) }
                var verified = result.pages
                if full {
                    let known = Set(result.pages.compactMap { $0["id"].string })
                    // Absence may mean lost access. Verify each previously known missing page.
                    for record in try store.records() where record.sourceID == source.id && record.pageID != nil && !known.contains(record.pageID!) {
                        let page = try await client.completeProperties(try await client.graphRequest("pages/\(record.pageID!)"))
                        verified.append(page)
                    }
                }
                if !full && source.kind == .tasks {
                    for page in verified {
                        if let id = page["id"].string { changedTaskIDs.insert(ProjectGraph.normalizedID(id)) }
                        for value in page["properties"].object.values where value["type"].string == "relation" {
                            changedTaskRelations.formUnion(value["relation"].array.compactMap { $0["id"].string }.map(ProjectGraph.normalizedID))
                        }
                    }
                }
                try store.ingest(pages: verified, source: source)
                try store.write("cursor:\(source.id)", started)
                ingested.insert(source.id)
            } catch { report.failures[source.title] = error.localizedDescription }
        }
        // Formula and rollup changes do not reliably advance a parent's edit time.
        // Re-read affected milestone parents when an incremental task read changes.
        if !changedTaskIDs.isEmpty, let source = sources.first(where: { $0.kind == .milestones }), report.failures[source.title] == nil {
            do {
                let parents = try store.records().filter { record in
                    guard record.kind == .milestones, let id = record.pageID else { return false }
                    let relations = Set((Array(record.local.values) + Array(record.remote.values)).filter { $0["type"].string == "relation" }.flatMap { $0["relation"].array.compactMap { $0["id"].string }.map(ProjectGraph.normalizedID) })
                    return changedTaskRelations.contains(ProjectGraph.normalizedID(id)) || !relations.isDisjoint(with: changedTaskIDs)
                }
                var refreshed: [ProjectJSON] = []
                for parent in parents {
                    if let id = parent.pageID { refreshed.append(try await client.completeProperties(try await client.graphRequest("pages/\(id)"))) }
                }
                try store.ingest(pages: refreshed, source: source)
            } catch { report.failures[source.title] = "Computed parent refresh: \(error.localizedDescription)" }
        }
        // Counted once for every source read, not by decoding the whole graph per source.
        if !ingested.isEmpty, let records = try? store.records() {
            let counts = Dictionary(grouping: records.filter { $0.pageID != nil && ingested.contains($0.sourceID) }, by: \.sourceID).mapValues(\.count)
            for source in sources where ingested.contains(source.id) { report.counts[source.title] = counts[source.id] ?? 0 }
        }
        if full && report.failures.isEmpty { try store.write("lastFullCheck", Date()) }
        report.checkedAt = Date()
        report.unresolvedReferences = try store.unresolvedReferences().count
        report.referenceDetails = try store.referenceDetails(sources: sources)
        try store.write("report", report)
        return report
    }

    /// Re-fetch before applying any reviewed field. Never substitute a stale snapshot.
    public func pull(ids: Set<String>, reviewed: [ProjectGraphRecord], resolutions: [String: [String: Bool]] = [:]) async throws {
        let owner = "pid:\(ProcessInfo.processInfo.processIdentifier):\(UUID().uuidString)"
        guard try store.acquire(owner: owner) else { throw SyncError.busy }
        defer { try? store.release(owner: owner) }
        let sources = try store.read("sources", as: [ProjectGraphSource].self) ?? []
        let selected = reviewed.filter { ids.contains($0.id) }
        // Initial imports commonly contain thousands of pages. Complete source
        // queries provide the same fresh properties without thousands of page GETs.
        let batch = selected.count > 100
        var fetched = Set<String>()
        if batch {
            for source in sources where selected.contains(where: { $0.sourceID == source.id }) {
                let result = try await client.graphPages(sourceID: source.id)
                guard result.complete else { throw SyncError.incomplete(source.title) }
                try store.ingest(pages: result.pages, source: source)
                fetched.formUnion(result.pages.compactMap { $0["id"].string }.map(ProjectGraph.normalizedID))
            }
        }
        // Revalidate the whole selected plan before applying any local fields.
        for prior in selected {
            try Task.checkCancellation()
            guard let current = try store.record(id: prior.id), current.locallyDeleted != true, current.local == prior.local else { throw SyncError.stale }
            if let pageID = prior.pageID, let source = sources.first(where: { $0.id == prior.sourceID }) {
                if !batch || !fetched.contains(ProjectGraph.normalizedID(pageID)) {
                    let page = try await client.completeProperties(try await client.graphRequest("pages/\(pageID)"))
                    try store.ingest(pages: [page], source: source)
                }
                let latest = try store.record(id: prior.id)
                guard latest?.remote.mapValues(\.comparable) == prior.remote.mapValues(\.comparable), latest?.remoteArchived == prior.remoteArchived, latest?.editedAt == prior.editedAt else { throw SyncError.stale }
            }
            if current.changes.contains(where: { $0.state == .conflict && resolutions[prior.id]?[$0.id] == nil }) { throw SyncError.conflict(current.title) }
        }
        try Task.checkCancellation()
        for prior in selected { try store.acceptIncoming(prior.id, resolutions: resolutions[prior.id] ?? [:]) }
    }

    /// `fields` restricts a reviewed merge to those existing-page properties. Other
    /// conflicts, incoming values, archives and uploads remain pending.
    public func push(ids: Set<String>, reviewed: [ProjectGraphRecord], resolutions: [String: [String: Bool]] = [:],
                     fields: [String: Set<String>]? = nil) async throws {
        let owner = "pid:\(ProcessInfo.processInfo.processIdentifier):\(UUID().uuidString)"
        guard try store.acquire(owner: owner) else { throw SyncError.busy }
        defer { try? store.release(owner: owner) }
        let sources = try store.read("sources", as: [ProjectGraphSource].self) ?? []
        // Validate the whole review before starting any write. A stale existing
        // record must not cause unrelated new pages to be created first.
        for prior in reviewed where ids.contains(prior.id) {
            try Task.checkCancellation()
            guard let record = try store.record(id: prior.id), record.locallyDeleted != true, record.local == prior.local,
                  record.pendingUploads == prior.pendingUploads, record.archiveRequested == prior.archiveRequested else { throw SyncError.stale }
            guard let source = sources.first(where: { $0.id == record.sourceID }) else { throw SyncError.unsupported("Configure the source for \(record.kind.title).") }
            if let fields {
                guard record.pageID != nil, !record.remoteArchived,
                      let selectedFields = fields[record.id], !selectedFields.isEmpty,
                      selectedFields.allSatisfy({ source.writable($0) }) else { throw SyncError.stale }
            }
            if record.ambiguousCreate { throw SyncError.ambiguous(record.title) }
            if record.changes.contains(where: { $0.state == .conflict && (fields == nil || fields?[record.id]?.contains($0.id) == true) && resolutions[record.id]?[$0.id] == nil }) { throw SyncError.conflict(record.title) }
            if let pageID = prior.pageID {
                let fresh = try await client.completeProperties(try await client.graphRequest("pages/\(pageID)"))
                try store.ingest(pages: [fresh], source: source)
                guard let current = try store.record(id: prior.id), current.remote.mapValues(\.comparable) == prior.remote.mapValues(\.comparable), current.remoteArchived == prior.remoteArchived, current.editedAt == prior.editedAt else { throw SyncError.stale }
            }
        }
        // Materialize new pages first; relations get wired only after all page IDs exist.
        for draft in reviewed where ids.contains(draft.id) && draft.pageID == nil {
            try Task.checkCancellation()
            guard var record = try store.record(id: draft.id), record.local == draft.local, record.pendingUploads == draft.pendingUploads else { throw SyncError.stale }
            guard !record.ambiguousCreate else { throw SyncError.ambiguous(record.title) }
            guard let source = sources.first(where: { $0.id == record.sourceID }) else { throw SyncError.unsupported("Configure the source for \(record.kind.title).") }
            let properties = record.local.filter { source.writable($0.key) && $0.value["type"].string != "relation" }.mapValues(Self.writeValue)
            // Durable attempt marker is written BEFORE the non-idempotent request.
            record.ambiguousCreate = true; try store.save(record)
            try store.write("operation:\(record.id):create", ProjectJSON(["state": "attempting", "source": record.sourceID, "properties": ProjectJSON.object(properties).foundationObject]))
            do {
                let page = try await client.graphRequest("pages", method: "POST", body: .object([
                    "parent": ProjectJSON(["type": "data_source_id", "data_source_id": source.id]), "properties": .object(properties)]))
                guard let pageID = page["id"].string else { throw SyncError.ambiguous(record.title) }
                let sent = record.local
                record = try store.record(id: record.id) ?? record
                record.pageID = pageID; record.ambiguousCreate = false; record.error = nil
                // Acknowledge only fields actually sent. Relationships are still outgoing.
                for (key, value) in sent where value["type"].string != "relation" && source.writable(key) { record.baseline[key] = value; record.remote[key] = value }
                try store.save(record)
                try store.write("operation:\(record.id):create", ProjectJSON(["state": "acknowledged", "pageID": pageID]))
            } catch {
                var latest = try store.record(id: record.id) ?? record
                if case NotionClient.Failure.http(let status, _) = error, [400, 401, 403, 404, 409, 429].contains(status) { latest.ambiguousCreate = false }
                latest.error = error.localizedDescription; try store.save(latest); throw error
            }
        }
        for prior in reviewed where ids.contains(prior.id) {
            try Task.checkCancellation()
            guard var record = try store.record(id: prior.id), let pageID = record.pageID,
                  let source = sources.first(where: { $0.id == record.sourceID }) else { continue }
            guard record.local == prior.local, record.pendingUploads == prior.pendingUploads else { throw SyncError.stale }
            let fresh = try await client.completeProperties(try await client.graphRequest("pages/\(pageID)"))
            try store.ingest(pages: [fresh], source: source)
            record = try store.record(id: prior.id)!
            if prior.pageID != nil && (record.remote.mapValues(\.comparable) != prior.remote.mapValues(\.comparable) || record.remoteArchived != prior.remoteArchived || record.editedAt != prior.editedAt) { throw SyncError.stale }
            if prior.pageID == nil {
                // New pages have server-provided defaults (including empty relations).
                // Those defaults are the initial baseline, not competing remote edits.
                for (key, value) in record.local where value["type"].string == "relation" {
                    record.baseline[key] = record.remote[key] ?? .null
                }
                try store.save(record)
            }
            if fields == nil { try store.acceptIncoming(record.id, resolutions: resolutions[record.id] ?? [:]) }
            record = try store.record(id: prior.id)!
            guard !record.changes.contains(where: { $0.state == .conflict && (fields == nil || fields?[record.id]?.contains($0.id) == true) }) else { throw SyncError.conflict(record.title) }
            var properties: [String: ProjectJSON] = [:]
            for change in record.changes where change.state == .outgoing {
                guard source.writable(change.id), fields == nil || fields?[record.id]?.contains(change.id) == true else { continue }
                var value = Self.writeValue(change.local)
                if change.local["type"].string == "relation" {
                    let mapped = try change.local["relation"].array.map { reference -> ProjectJSON in
                        let id = reference["id"].string ?? ""
                        // References need one current identity, not a decode of the
                        // entire graph for every relation in a reviewed batch.
                        if let linked = try store.record(id: id) {
                            guard let pageID = linked.pageID else { throw SyncError.unsupported("Select \(linked.title) for Send to Notion before attaching this relationship.") }
                            return ProjectJSON(["id": pageID])
                        }
                        return ProjectJSON(["id": id])
                    }
                    var seen = Set<String>()
                    let unique = mapped.filter { seen.insert(ProjectGraph.normalizedID($0["id"].display)).inserted }
                    guard unique.count <= 100 else { throw SyncError.unsupported("\(source.name(for: change.id)) exceeds Notion's 100-relation write limit. Keep this change pending.") }
                    value = .object(["relation": .array(unique)])
                }
                properties[change.id] = value
            }
            do { for upload in (fields == nil ? record.pendingUploads : nil) ?? [] {
                guard source.writable(upload.propertyID), source.schema.object.values.contains(where: { $0["id"].string == upload.propertyID && $0["type"].string == "files" }) else { throw SyncError.unsupported("The upload property is no longer a writable file property.") }
                let file = try await uploadFile(upload)
                properties[upload.propertyID] = ProjectJSON(["files": [["name": upload.filename, "type": "file_upload", "file_upload": ["id": file]]]])
            } } catch { var latest = try store.record(id: record.id) ?? record; latest.error = error.localizedDescription; try store.save(latest); throw error }
            if properties.isEmpty && (fields != nil || !record.archiveRequested) { continue }
            var body: [String: ProjectJSON] = ["properties": .object(properties)]
            if fields == nil && record.archiveRequested { body["in_trash"] = .bool(true) }
            do {
                try store.write("operation:\(record.id):update", ProjectJSON(["state": "attempting", "pageID": pageID, "body": ProjectJSON.object(body).foundationObject]))
                _ = try await client.graphRequest("pages/\(pageID)", method: "PATCH", body: .object(body))
                // Fetch canonical server values rather than assuming Notion accepted our shape.
                let confirmed = try await client.completeProperties(try await client.graphRequest("pages/\(pageID)"))
                try store.ingest(pages: [confirmed], source: source)
                var latest = try store.record(id: record.id)!
                for (key, requested) in properties {
                    let type = record.local[key]?["type"].string ?? ""
                    if ["relation", "multi_select"].contains(type), !Self.retainsSelections(requested, actual: latest.remote[key] ?? .null, type: type) {
                        throw SyncError.unsupported("Notion did not return every value for \(source.name(for: key)). Local choices remain pending; check linked page availability and integration access.")
                    }
                }
                for key in properties.keys {
                    // Concurrent local edits remain pending.
                    if latest.local[key] == record.local[key] { latest.local[key] = latest.remote[key]; latest.baseline[key] = latest.remote[key] }
                }
                if fields == nil {
                    let completedUploads = Set((record.pendingUploads ?? []).map(\.id))
                    latest.pendingUploads = latest.pendingUploads?.filter { !completedUploads.contains($0.id) }
                    latest.archiveRequested = false; latest.acknowledgedArchived = latest.remoteArchived
                }
                latest.error = nil; try store.save(latest)
                try store.write("operation:\(record.id):update", ProjectJSON(["state": "acknowledged", "pageID": pageID]))
            } catch {
                var latest = try store.record(id: record.id) ?? record
                latest.error = error.localizedDescription; try store.save(latest); throw error
            }
        }
    }
    /// A person chooses a candidate; matching fields must still be verified before binding it.
    public func reconcileCreation(recordID: String, pageID: String) async throws {
        let owner = "pid:\(ProcessInfo.processInfo.processIdentifier):\(UUID().uuidString)"
        guard try store.acquire(owner: owner) else { throw SyncError.busy }
        defer { try? store.release(owner: owner) }
        guard var record = try store.record(id: recordID), record.ambiguousCreate, record.pageID == nil,
              let source = try store.read("sources", as: [ProjectGraphSource].self)?.first(where: { $0.id == record.sourceID }) else { throw SyncError.stale }
        let page = try await client.completeProperties(try await client.graphRequest("pages/\(pageID)"))
        guard page["parent"]["data_source_id"].string == source.id else { throw SyncError.unsupported("Choose a page in this record's configured data source.") }
        let incoming = Dictionary(uniqueKeysWithValues: page["properties"].object.map { name, value in (value["id"].string ?? source.property(named: name)?.id ?? name, value) })
        for (key, value) in record.local where source.writable(key) && value["type"].string != "relation" {
            guard incoming[key]?.comparable == value.comparable else { throw SyncError.unsupported("The selected page does not match the attempted creation. Review it before linking.") }
        }
        // A check may already have staged this remote page under another private ID.
        if let staged = try store.records().first(where: { $0.pageID == pageID && $0.id != recordID }) {
            guard staged.local.isEmpty else { throw SyncError.unsupported("This page is already bound to an imported record.") }
            try store.removeUnaccepted(staged.id)
        }
        record.pageID = pageID; record.remote = incoming; record.ambiguousCreate = false; record.error = nil
        for (key, value) in record.local where value["type"].string != "relation" && source.writable(key) { record.baseline[key] = incoming[key] }
        try store.save(record)
        try store.write("operation:\(record.id):create", ProjectJSON(["state": "reconciled", "pageID": pageID]))
    }
    private func uploadFile(_ upload: ProjectPendingUpload) async throws -> String {
        guard upload.byteCount <= 20 * 1024 * 1024 else { throw SyncError.unsupported("\(upload.filename) exceeds the 20 MB single-upload limit. Select a smaller preview; the original remains local.") }
        let url = URL(fileURLWithPath: upload.path)
        let data = try await Task.detached { () -> Data in
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard (attributes[.size] as? NSNumber)?.intValue == upload.byteCount, attributes[.modificationDate] as? Date == upload.modifiedAt else { throw SyncError.stale }
            return try Data(contentsOf: url)
        }.value
        let key = "fileUpload:\(upload.id)"
        if let id = try store.read(key, as: String.self) {
            let existing: ProjectJSON
            do { existing = try await client.graphRequest("file_uploads/\(id)") }
            catch NotionClient.Failure.http(let status, _) where status == 404 { existing = .null }
            if existing["status"].string == "uploaded" { return id }
            if existing["status"].string == "pending" {
                let sent = try await client.sendFileUpload(id: id, data: data, filename: upload.filename, contentType: upload.contentType)
                guard sent["status"].string == "uploaded" else { throw SyncError.unsupported("Notion did not complete the file upload. The pending file was retained.") }
                return id
            }
        }
        let created = try await client.graphRequest("file_uploads", method: "POST", body: ProjectJSON(["mode": "single_part", "filename": upload.filename, "content_type": upload.contentType]))
        guard let id = created["id"].string else { throw SyncError.unsupported("Notion did not return a file upload ID.") }
        try store.write(key, id)
        let sent = try await client.sendFileUpload(id: id, data: data, filename: upload.filename, contentType: upload.contentType)
        guard sent["status"].string == "uploaded" else { throw SyncError.unsupported("Notion did not complete the file upload. The pending file was retained.") }
        return id
    }
    /// A 200 response alone is not acknowledgement: Notion can omit unavailable
    /// relationships. Keep the staged local union until every requested value returns.
    static func retainsSelections(_ requested: ProjectJSON, actual: ProjectJSON, type: String) -> Bool {
        let expected = requested[type].array, returned = actual[type].array
        if type == "relation" {
            return Set(expected.compactMap { $0["id"].string }.map(ProjectGraph.normalizedID)) == Set(returned.compactMap { $0["id"].string }.map(ProjectGraph.normalizedID))
        }
        guard expected.count == returned.count else { return false }
        return expected.allSatisfy { option in
            returned.contains { other in
                if let name = option["name"].string {
                    return name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == other["name"].string?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                }
                return option["id"].string != nil && option["id"].string == other["id"].string
            }
        }
    }

    public static func writeValue(_ envelope: ProjectJSON) -> ProjectJSON {
        guard let type = envelope["type"].string else { return envelope }
        if type == "title" || type == "rich_text" {
            return .object([type: .array(envelope[type].array.map { .object($0.object.filter { ["type", "text", "mention", "equation", "annotations"].contains($0.key) }) })])
        }
        if ["select", "status"].contains(type) { return .object([type: envelope[type] == .null ? .null : .object(["name": envelope[type]["name"]])]) }
        return .object([type: envelope[type]])
    }
}

public enum NotionGraphConfiguration {
    public static let sourceOverridesKey = "projectGraphSourceIDs"
    public static func seeds(defaults: UserDefaults = TestIsolation.defaults) -> [ProjectEntityKind: String] {
        let config = NotionSettings.load(from: defaults).databases
        var result: [ProjectEntityKind: String] = [:]
        for (kind, id) in [(ProjectEntityKind.projects, config.projects), (.tasks, config.tasks), (.features, config.features), (.milestones, config.milestones), (.ideas, config.ideas)] {
            if let id { result[kind] = id }
        }
        for (key, id) in defaults.dictionary(forKey: sourceOverridesKey) as? [String: String] ?? [:] {
            if let kind = ProjectEntityKind(rawValue: key), !id.isEmpty { result[kind] = id }
        }
        return result
    }
    public static func disabled(defaults: UserDefaults = TestIsolation.defaults) -> Set<ProjectEntityKind> {
        let stored = defaults.dictionary(forKey: NotionSettings.defaultsKey) as? [String: String] ?? [:]
        let overrides = defaults.dictionary(forKey: sourceOverridesKey) as? [String: String] ?? [:]
        return Set(ProjectEntityKind.allCases.filter { stored[$0.rawValue]?.trimmingCharacters(in: .whitespacesAndNewlines) == "" || overrides[$0.rawValue] == "" })
    }
}
