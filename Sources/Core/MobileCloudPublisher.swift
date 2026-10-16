import Foundation
import CloudKit
import CryptoKit
#if os(macOS)
import Security
#endif

/// A compact, filesystem-derived value ready for the mobile CloudKit projection.
/// Work and idea descriptions are bounded; media is represented by filenames only.
public struct MobileWorkspaceLocalSnapshot: Sendable {
    /// Immediate children of every discovered top-level folder, keyed by folder name.
    /// A key with no items still publishes its root, so an empty folder made in Finder
    /// shows up on the phone too.
    public var itemsByArea: [String: [WorkspaceItem]]
    public var workItems: [WorkItem]
    public var tags: [Tag]
    /// Tags by canonical absolute path. This is a read-through view of the local tag
    /// store, not a second tag database.
    public var tagsByPath: [String: [Tag]]
    /// Private project notes selected for mobile projection, keyed by project path.
    public var projectDetailsByPath: [String: MobileProjectDetails]
    public var ideaDetailsByPath: [String: MobileIdea]

    public init(itemsByArea: [String: [WorkspaceItem]], workItems: [WorkItem],
                tags: [Tag], tagsByPath: [String: [Tag]],
                projectDetailsByPath: [String: MobileProjectDetails] = [:],
                ideaDetailsByPath: [String: MobileIdea] = [:]) {
        self.itemsByArea = itemsByArea
        self.workItems = workItems
        self.tags = tags
        self.tagsByPath = tagsByPath
        self.projectDetailsByPath = projectDetailsByPath
        self.ideaDetailsByPath = ideaDetailsByPath
    }
}

/// A record candidate before the private revision store assigns its next revision.
/// The associated values are all already-safe projections of local authoritative data.
public enum MobileCloudPublicationCandidate: Sendable {
    case tag(Tag)
    case entry(MobileWorkspaceEntry)
    case workItem(MobileWorkItem)
    case idea(MobileIdea)

    public var scope: String {
        switch self {
        case .tag: return "tag"
        case .entry: return "entry"
        case .workItem: return "work-item"
        case .idea: return "idea"
        }
    }

    public var recordKey: String {
        switch self {
        case .tag(let tag): return tag.id
        case .entry(let entry): return entry.path
        case .workItem(let item): return item.id
        case .idea(let idea): return idea.path
        }
    }

    /// Record names are namespaced because CloudKit record names share a zone even
    /// when record types differ. A digest keeps arbitrary user file names out of a
    /// CloudKit identifier and below its length limit. IDs stay stable across a
    /// work-item file rename because their key is the item's embedded ID.
    public var recordName: String { Self.recordName(scope: scope, key: recordKey) }

    public static func recordName(scope: String, key: String) -> String {
        let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return "bw.\(scope).\(digest)"
    }

    public var recordType: String {
        switch self {
        case .tag: return MobileCloudSchema.tagRecordType
        case .entry: return MobileCloudSchema.indexRecordType
        case .workItem: return MobileCloudSchema.workItemRecordType
        case .idea: return MobileCloudSchema.ideaRecordType
        }
    }

    /// Deterministic content token. It is private bookkeeping rather than a security
    /// hash, so an inspectable field join is preferable to a dependency just for SHA.
    public var fingerprint: String {
        func date(_ value: Date?) -> String { value.map { String($0.timeIntervalSince1970.bitPattern) } ?? "-" }
        func tags(_ values: Set<String>) -> String { values.sorted().joined(separator: ",") }
        func details(_ value: MobileProjectDetails?) -> String {
            guard let value else { return "-" }
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            return String(decoding: (try? encoder.encode(value)) ?? Data(), as: UTF8.self)
        }
        switch self {
        case .tag(let tag):
            return [tag.id, tag.name, String(tag.colorIndex), date(tag.createdAt)].joined(separator: "\u{1F}")
        case .entry(let entry):
            return [entry.path, entry.parentPath ?? "", entry.name, String(entry.isDirectory), tags(entry.tagIDs), date(entry.modifiedAt), details(entry.projectDetails), entry.overview?.encoded ?? ""].joined(separator: "\u{1F}")
        case .workItem(let item):
            return [item.id, item.path, item.title, item.kind.rawValue, item.status.rawValue,
                    item.stage.rawValue, item.priority.rawValue, item.projectPath ?? "",
                    date(item.dueDate), tags(item.tagIDs), MobileActionProjection.encode(item) ?? ""].joined(separator: "\u{1F}")
        case .idea(let idea):
            return [idea.path, idea.title, tags(idea.tagIDs), date(idea.modifiedAt), idea.description ?? "", idea.serviceID ?? "",
                    MobileIdeaEnvelope.encode(idea) ?? ""].joined(separator: "\u{1F}")
        }
    }
}

/// Converts currently loaded filesystem state to the deliberately shallow phone index.
public enum MobileWorkspaceProjection {
    public static func candidates(from snapshot: MobileWorkspaceLocalSnapshot,
                                  workspace: WorkspaceLocation) -> [MobileCloudPublicationCandidate] {
        var candidates: [MobileCloudPublicationCandidate] = []
        var seen = Set<String>()
        func append(_ candidate: MobileCloudPublicationCandidate) {
            guard seen.insert("\(candidate.scope)\u{1F}\(candidate.recordKey)").inserted else { return }
            candidates.append(candidate)
        }

        for tag in snapshot.tags { append(.tag(tag)) }

        // Each entry looks up its project's plans; index them once rather than scanning
        // every work item per entry. Keeps the first plan per path, as a scan would.
        let goalsByProjectPath = Dictionary(grouping: snapshot.workItems.filter { $0.kind == .goal && $0.projectPath != nil },
                                            by: { $0.projectPath! })

        for area in snapshot.itemsByArea.keys.sorted() {
            // Area roots make `parentPath` navigable without pretending that an entire
            // directory tree is mirrored on the phone.
            append(.entry(MobileWorkspaceEntry(
                path: area, parentPath: nil, name: area,
                isDirectory: true, revision: 0
            )))
            for item in snapshot.itemsByArea[area] ?? [] {
                guard NoiseFilter.isForeignMetadata(name: item.name) == false,
                      let path = relativePath(of: item.url, workspace: workspace)
                else { continue }
                append(.entry(MobileWorkspaceEntry(
                    path: path, parentPath: area, name: mobileProjectName(item: item, goals: goalsByProjectPath[path] ?? []),
                    isDirectory: item.isDirectory, revision: 0,
                    tagIDs: Set(snapshot.tagsByPath[item.url.canonicalPath, default: []].map(\.id)),
                    modifiedAt: item.contentModifiedAt,
                    projectDetails: snapshot.projectDetailsByPath[path]
                )))
            }
        }

        for item in snapshot.workItems {
            guard let path = relativePath(of: item.url, workspace: workspace) else { continue }
            append(.workItem(MobileWorkItem(
                id: item.id, path: path, title: item.title, kind: item.kind,
                status: item.status, stage: item.stage, priority: item.priority,
                projectPath: item.projectPath.map { raw in
                    raw.hasPrefix(workspace.root.canonicalPath + "/") ? String(raw.dropFirst(workspace.root.canonicalPath.count + 1)) : raw
                }, dueDate: item.dueDate, revision: 0,
                tagIDs: Set(snapshot.tagsByPath[item.url.canonicalPath, default: []].map(\.id)),
                body: item.body.utf8.count <= MobilePlanningFiles.maximumTextBytes ? item.body : nil,
                actionMetadata: item.actionMetadata, dependencyIDs: item.dependencyIDs,
                featureIDs: item.featureIDs, milestoneIDs: item.milestoneIDs,
                createdAt: item.createdAt, modifiedAt: item.modifiedAt, completedAt: item.completedAt, importedNotionPageID: item.importedNotionPageID
            )))
        }

        for item in snapshot.itemsByArea[WorkspaceArea.ideas.directoryName] ?? [] {
            guard let path = relativePath(of: item.url, workspace: workspace) else { continue }
            guard NoiseFilter.isForeignMetadata(name: item.name) == false else { continue }
            let detail = snapshot.ideaDetailsByPath[path]
            append(.idea(MobileIdea(
                path: path, title: detail?.title ?? item.displayTitle, revision: 0,
                tagIDs: Set(snapshot.tagsByPath[item.url.canonicalPath, default: []].map(\.id)),
                modifiedAt: item.rawModifiedAt, description: detail?.description,
                attachments: detail?.attachments, serviceID: detail?.serviceID, planning: detail?.planning, scoringPreferences: detail?.scoringPreferences, previews: detail?.previews
            )))
        }
        return candidates.sorted {
            $0.scope == $1.scope ? $0.recordKey < $1.recordKey : $0.scope < $1.scope
        }
    }

    private static func mobileProjectName(item: WorkspaceItem, goals: [WorkItem]) -> String {
        if let plan = goals.first(where: { item.name.hasSuffix(" (\($0.id))") }) {
            return plan.title
        }
        return item.name
    }

    public static func relativePath(of url: URL, workspace: WorkspaceLocation) -> String? {
        let root = workspace.root.canonicalPath
        let path = url.canonicalPath
        guard path.hasPrefix(root + "/") else { return nil }
        return MobileWorkspacePath.normalizedRelative(String(path.dropFirst(root.count + 1)))
    }
}

/// The small amount of private state needed to make a retry-safe CloudKit cache.
/// Losing it only causes a full republish; it never loses or changes Workspace files.
public final class MobileCloudProjectionState: @unchecked Sendable {
    public struct Prepared: Sendable {
        public let candidate: MobileCloudPublicationCandidate
        public let revision: Int64
        public let changed: Bool
    }

    public struct Plan: Sendable {
        public let records: [Prepared]
        public let stale: [(scope: String, recordKey: String)]
    }

    private let db: Database
    private let lock = NSLock()

    public init(database: Database) { self.db = database }

    public func prepare(_ candidates: [MobileCloudPublicationCandidate]) throws -> Plan {
        lock.lock(); defer { lock.unlock() }
        let rows = try db.query(
            "SELECT scope, record_key, fingerprint, revision FROM mobile_cloud_projection",
            row: { ($0.string(0), $0.string(1), $0.string(2), $0.int(3)) }
        )
        let existing = Dictionary(uniqueKeysWithValues: rows.map { ("\($0.0)\u{1F}\($0.1)", ($0.2, $0.3)) })
        let wanted = Set(candidates.map { "\($0.scope)\u{1F}\($0.recordKey)" })
        let records = candidates.map { candidate -> Prepared in
            let key = "\(candidate.scope)\u{1F}\(candidate.recordKey)"
            guard let old = existing[key] else { return Prepared(candidate: candidate, revision: 1, changed: true) }
            return Prepared(candidate: candidate, revision: old.0 == candidate.fingerprint ? old.1 : old.1 + 1,
                            changed: old.0 != candidate.fingerprint)
        }
        let stale = rows.compactMap { row -> (scope: String, recordKey: String)? in
            wanted.contains("\(row.0)\u{1F}\(row.1)") ? nil : (row.0, row.1)
        }
        return Plan(records: records, stale: stale)
    }

    public func markPublished(_ prepared: Prepared) throws {
        lock.lock(); defer { lock.unlock() }
        try db.run("""
            INSERT INTO mobile_cloud_projection (scope, record_key, fingerprint, revision, updated_at)
            VALUES (?,?,?,?,?)
            ON CONFLICT(scope, record_key) DO UPDATE SET fingerprint = excluded.fingerprint,
                revision = excluded.revision, updated_at = excluded.updated_at
            """, [.text(prepared.candidate.scope), .text(prepared.candidate.recordKey),
                  .text(prepared.candidate.fingerprint), .int(prepared.revision),
                  .double(Date().timeIntervalSince1970)])
    }

    public func markDeleted(scope: String, recordKey: String) throws {
        lock.lock(); defer { lock.unlock() }
        try db.run("DELETE FROM mobile_cloud_projection WHERE scope = ? AND record_key = ?",
                   [.text(scope), .text(recordKey)])
    }

    public func needsInitialReconciliation() throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        return try db.query("SELECT 1 FROM mobile_cloud_sync_state WHERE state_key = ?", [.text("initial_projection_reconciled")], row: { _ in true }).isEmpty
    }

    public func markInitialReconciled() throws {
        lock.lock(); defer { lock.unlock() }
        try db.run("INSERT OR REPLACE INTO mobile_cloud_sync_state (state_key, updated_at) VALUES (?,?)",
                   [.text("initial_projection_reconciled"), .double(Date().timeIntervalSince1970)])
    }

    public func isHandled(_ id: UUID) throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        return try db.query("SELECT 1 FROM mobile_cloud_handled_intents WHERE mutation_id = ?", [.text(id.uuidString)], row: { _ in true }).isEmpty == false
    }

    public func markHandled(_ intent: MobileWorkspaceIntent) throws {
        lock.lock(); defer { lock.unlock() }
        try db.run("INSERT OR IGNORE INTO mobile_cloud_handled_intents (mutation_id, kind, handled_at) VALUES (?,?,?)",
                   [.text(intent.id.uuidString), .text(intent.kind.rawValue), .double(Date().timeIntervalSince1970)])
    }
}

/// A CloudKit intent record after validation. `intent == nil` is malformed input that
/// the Mac can safely acknowledge so it cannot poison every later sync pass.
public struct MobileCloudInboundIntent: Sendable {
    public let recordName: String
    public let intent: MobileWorkspaceIntent?
    public init(recordName: String, intent: MobileWorkspaceIntent?) {
        self.recordName = recordName
        self.intent = intent
    }
}

/// A readable picture of the container's current contents.
public struct MobileCloudDiagnostics: Sendable {
    public struct Row: Sendable {
        public let type: String
        public let recordName: String
        public let key: String
        public let detail: String
        public let revision: Int64?
        public let tagIDs: [String]
    }

    public var records: [Row] = []
    public var intents: [Row] = []

    public init() {}

    public var description: String {
        var lines = ["CLOUDKIT PROJECTION (\(records.count) records)"]
        for row in records {
            lines.append("  \(row.type) rev=\(row.revision.map(String.init) ?? "-") "
                + "key=\(row.key) detail=\(row.detail) tags=[\(row.tagIDs.joined(separator: ","))] "
                + "name=\(row.recordName)")
        }
        lines.append("CLOUDKIT INTENTS (\(intents.count) records)")
        for row in intents {
            lines.append("  \(row.type) base=\(row.revision.map(String.init) ?? "-") "
                + "key=\(row.key) \(row.detail) name=\(row.recordName)")
        }
        return lines.joined(separator: "\n")
    }
}

/// Optional Mac-side transport for the disposable projection and command channel.
/// It is lazy and opt-in: constructing it never creates a CKContainer, and a failed
/// sync leaves every local file and local database row exactly as they were.
public actor MobileCloudPublisher {
    public static let enabledDefaultsKey = "macCloudPublisherEnabled"
    private let containerIdentifier: String
    private let defaults: UserDefaults
    private let state: MobileCloudProjectionState
    private var resolved: CKDatabase?

    public init(database: Database, containerIdentifier: String = MobileCloudSchema.containerIdentifier,
                defaults: UserDefaults = TestIsolation.defaults) {
        self.state = MobileCloudProjectionState(database: database)
        self.containerIdentifier = containerIdentifier
        self.defaults = defaults
    }

    /// Never during an isolated test: fixture data must not reach the real container.
    public var isEnabled: Bool { TestIsolation.isActive == false && defaults.bool(forKey: Self.enabledDefaultsKey) }

    private func database(allowWhenDisabled: Bool = false) async throws -> CKDatabase {
        guard isEnabled || allowWhenDisabled else { throw MobileCloudError.turnedOff }
        #if os(macOS)
        // `CKContainer(identifier:)` terminates an unentitled Mac process. The app is
        // deliberately distributable without CloudKit, so reject an opt-in request
        // before constructing that object when the signed build lacks the capability.
        guard Self.hasCloudKitEntitlement else {
            throw MobileCloudError.rejected("This build is not signed with the CloudKit entitlement.")
        }
        #endif
        if let resolved { return resolved }
        let container = CKContainer(identifier: containerIdentifier)
        switch try? await container.accountStatus() {
        case .noAccount, .restricted: throw MobileCloudError.noAccount
        default: break
        }
        let database = container.privateCloudDatabase
        resolved = database
        return database
    }

    #if os(macOS)
    private static var hasCloudKitEntitlement: Bool {
        guard let task = SecTaskCreateFromSelf(nil),
              let identifiers = SecTaskCopyValueForEntitlement(
                task, "com.apple.developer.icloud-container-identifiers" as CFString, nil
              ) as? [String]
        else { return false }
        return identifiers.contains(MobileCloudSchema.containerIdentifier)
    }
    #endif

    /// What is actually in CloudKit right now, for diagnosing a sync.
    ///
    /// Deliberately reads the container rather than the local projection table. The two
    /// are supposed to agree, and the interesting failures are exactly the ones where
    /// they do not — a record the Mac believes it published that never landed, or a
    /// revision that stopped advancing. Answering that question from the local table
    /// would assume away the bug being looked for.
    public func diagnostics(allowWhenDisabled: Bool = false) async throws -> MobileCloudDiagnostics {
        let database = try await database(allowWhenDisabled: allowWhenDisabled)
        do {
            var report = MobileCloudDiagnostics()
            for type in [MobileCloudSchema.tagRecordType, MobileCloudSchema.indexRecordType,
                         MobileCloudSchema.workItemRecordType, MobileCloudSchema.ideaRecordType] {
                for record in try await Self.records(of: type, in: database) {
                    report.records.append(MobileCloudDiagnostics.Row(
                        type: type,
                        recordName: record.recordID.recordName,
                        key: (record["path"] as? String) ?? (record["id"] as? String) ?? "-",
                        detail: (record["title"] as? String) ?? (record["name"] as? String) ?? "-",
                        revision: (record["revision"] as? NSNumber)?.int64Value,
                        tagIDs: (record["tagIDs"] as? [String])?.sorted() ?? []
                    ))
                }
            }
            for type in [MobileCloudSchema.tagAssignmentChangeRecordType,
                         MobileCloudSchema.captureIntentRecordType] {
                for record in try await Self.records(of: type, in: database) {
                    report.intents.append(MobileCloudDiagnostics.Row(
                        type: type,
                        recordName: record.recordID.recordName,
                        key: (record["path"] as? String) ?? (record["captureName"] as? String) ?? "-",
                        detail: [("+", record["addTagIDs"] as? [String]), ("-", record["removeTagIDs"] as? [String]),
                                 ("=", record["tagIDs"] as? [String])]
                            .compactMap { sign, values in
                                (values?.isEmpty == false) ? sign + values!.sorted().joined(separator: ",") : nil
                            }
                            .joined(separator: " "),
                        revision: (record["baseRevision"] as? NSNumber)?.int64Value,
                        tagIDs: []
                    ))
                }
            }
            report.records.sort { $0.recordName < $1.recordName }
            report.intents.sort { $0.recordName < $1.recordName }
            return report
        } catch { throw Self.cloudError(error) }
    }

    public func pendingIntents() async throws -> [MobileCloudInboundIntent] {
        let database = try await database()
        do {
            async let tags = Self.records(of: MobileCloudSchema.tagAssignmentChangeRecordType, in: database)
            async let captures = Self.records(of: MobileCloudSchema.captureIntentRecordType, in: database)
            // Chronological, not by record name. The record name is the mutation UUID,
            // so sorting by it applies one path's changes in an essentially random
            // order: a tag removed and then re-added could be replayed the other way
            // round, leaving the Mac with the opposite of what the phone last showed.
            // The phone queues and flushes strictly in order for the same reason.
            // Record name breaks a tie so the sequence is still deterministic, and a
            // malformed record with no intent sorts last rather than jumping the queue.
            return try await (tags + captures).filter { $0["planningStatus"] == nil }.map(Self.intent).sorted { lhs, rhs in
                let left = lhs.intent?.createdAt ?? .distantFuture
                let right = rhs.intent?.createdAt ?? .distantFuture
                if left != right { return left < right }
                return lhs.recordName < rhs.recordName
            }
        } catch { throw Self.cloudError(error) }
    }

    public func acknowledge(recordName: String) async throws {
        let database = try await database()
        do { try await database.deleteRecord(withID: CKRecord.ID(recordName: recordName)) }
        catch let error as CKError where error.code == .unknownItem { return }
        catch { throw Self.cloudError(error) }
    }

    public func finishPlanning(_ intent: MobileWorkspaceIntent, error: String? = nil, workModifiedAt: Date? = nil) async throws {
        let database = try await database()
        let record = try await database.record(for: CKRecord.ID(recordName: intent.id.uuidString))
        record["planningStatus"] = error == nil ? "applied" : "rejected"
        record["planningError"] = error
        // A text token preserves subsecond precision across CloudKit date encoding.
        if let workModifiedAt { record["planningWorkRevision"] = String(workModifiedAt.timeIntervalSinceReferenceDate) }
        _ = try await database.save(record)
    }

    public func isHandled(_ id: UUID) throws -> Bool { try state.isHandled(id) }
    public func markHandled(_ intent: MobileWorkspaceIntent) throws { try state.markHandled(intent) }

    /// Publishes changed projections and removes projections that local state no longer
    /// contains. The local state row is advanced only after its matching CloudKit call
    /// succeeds, making a network interruption safe to retry.
    ///
    /// Writes go through `modifyRecords` with `.allKeys` rather than `CKDatabase.save`,
    /// for two reasons. `save` uses `.ifServerRecordUnchanged`, and these records are
    /// built fresh from local state so they carry no change tag: every *update* to an
    /// already-published record came back as `serverRecordChanged`, which meant the
    /// phone could only ever see each record's first version and the retry could never
    /// make progress. Overwriting is also the correct semantic — the Mac is the sole
    /// author of this projection and the records are a disposable cache of local truth,
    /// never something the phone edits. Batching is the second reason: one call per
    /// record is one round trip per record, and an index of a real workspace is
    /// thousands of them.
    public func publish(_ candidates: [MobileCloudPublicationCandidate]) async throws {
        let database = try await database()
        let plan = try state.prepare(candidates)
        do {
            // Projection state is only a local acknowledgement. A CloudKit schema reset,
            // an interrupted early publish, or a manual dashboard cleanup can leave it
            // claiming a tag exists when the phone has no record to fetch. Tags are a
            // deliberately tiny catalog, so verify just this type on each sync and
            // repair a missing record without re-reading the whole workspace index.
            let remoteTagRecordNames = Set(try await Self.records(of: MobileCloudSchema.tagRecordType, in: database)
                .map(\.recordID.recordName))
            let missingTagRecordNames = Set(plan.records.compactMap { prepared -> String? in
                guard case .tag = prepared.candidate,
                      remoteTagRecordNames.contains(prepared.candidate.recordName) == false
                else { return nil }
                return prepared.candidate.recordName
            })
            if try state.needsInitialReconciliation() {
                let desired = Set(plan.records.map { $0.candidate.recordName })
                var orphans: [CKRecord.ID] = []
                for type in MobileCloudSchema.projectionRecordTypes {
                    orphans += try await Self.records(of: type, in: database)
                        .map(\.recordID)
                        .filter { desired.contains($0.recordName) == false }
                }
                try await Self.delete(orphans, in: database)
                // This is a separate checkpoint from individual record saves. If a
                // later save fails, the next retry can continue publishing without
                // accidentally treating an incomplete run as a new reconciliation.
                try state.markInitialReconciled()
            }

            // One failure must not abandon the rest of the projection, so batches are
            // non-atomic and each record's local row advances on its own result. The
            // first real failure is raised at the end, after everything that could be
            // published has been.
            var failure: MobileCloudError?
            for batch in Self.batches(of: plan.records.filter {
                $0.changed || missingTagRecordNames.contains($0.candidate.recordName)
            }) {
                let byID = Dictionary(
                    batch.map { (CKRecord.ID(recordName: $0.candidate.recordName), $0) },
                    uniquingKeysWith: { first, _ in first }
                )
                let results = try await database.modifyRecords(
                    saving: batch.map(Self.record(for:)), deleting: [],
                    savePolicy: .allKeys, atomically: false
                )
                for (id, result) in results.saveResults {
                    guard let prepared = byID[id] else { continue }
                    switch result {
                    case .success:
                        try state.markPublished(prepared)
                    case .failure(let error):
                        failure = failure ?? Self.cloudError(error)
                    }
                }
            }

            for batch in Self.batches(of: plan.stale) {
                let byID = Dictionary(
                    batch.map { (CKRecord.ID(recordName: MobileCloudPublicationCandidate.recordName(
                        scope: $0.scope, key: $0.recordKey)), $0) },
                    uniquingKeysWith: { first, _ in first }
                )
                for (id, result) in try await Self.delete(Array(byID.keys), in: database) {
                    guard let stale = byID[id] else { continue }
                    switch result {
                    case .success:
                        try state.markDeleted(scope: stale.scope, recordKey: stale.recordKey)
                    case .failure(let error as CKError) where error.code == .unknownItem:
                        // The desired state is already absent remotely, so it is safe to
                        // forget the local publication row too.
                        try state.markDeleted(scope: stale.scope, recordKey: stale.recordKey)
                    case .failure(let error):
                        failure = failure ?? Self.cloudError(error)
                    }
                }
            }

            if let failure { throw failure }
        } catch { throw Self.cloudError(error) }
    }

    /// CloudKit's documented ceiling for one modify operation.
    private static let batchLimit = 400

    private static func batches<T>(of values: [T]) -> [[T]] {
        stride(from: 0, to: values.count, by: batchLimit).map {
            Array(values[$0..<min($0 + batchLimit, values.count)])
        }
    }

    @discardableResult
    private static func delete(
        _ recordIDs: [CKRecord.ID], in database: CKDatabase
    ) async throws -> [CKRecord.ID: Result<Void, Error>] {
        var all: [CKRecord.ID: Result<Void, Error>] = [:]
        for batch in batches(of: recordIDs) {
            let results = try await database.modifyRecords(saving: [], deleting: batch,
                                                           savePolicy: .allKeys, atomically: false)
            all.merge(results.deleteResults) { first, _ in first }
        }
        return all
    }

    private static func records(of type: String, in database: CKDatabase) async throws -> [CKRecord] {
        let query = CKQuery(recordType: type, predicate: NSPredicate(value: true))
        var page: (matchResults: [(CKRecord.ID, Result<CKRecord, Error>)], queryCursor: CKQueryOperation.Cursor?)
        do {
            page = try await database.records(matching: query, desiredKeys: nil)
        } catch where MobileCloudSchema.isMissingRecordType(error) {
            return []
        }
        var all = page.matchResults.compactMap { _, result in try? result.get() }
        // This is deliberately bounded: the mobile snapshot is an index, not a
        // replacement for the Workspace. A large workspace must stay usable even
        // when the CloudKit cache is behind. The same ceiling as the phone's reader, so
        // the two cannot disagree about how much of a projection exists.
        while let cursor = page.queryCursor, all.count < MobileCloudStore.recordFetchLimit {
            page = try await database.records(continuingMatchFrom: cursor, desiredKeys: nil)
            all += page.matchResults.compactMap { _, result in try? result.get() }
        }
        return all
    }

    private static func intent(_ record: CKRecord) -> MobileCloudInboundIntent {
        guard let id = UUID(uuidString: record.recordID.recordName),
              let mutationID = record["mutationID"] as? String, mutationID == id.uuidString,
              let createdAt = record["createdAt"] as? Date
        else { return MobileCloudInboundIntent(recordName: record.recordID.recordName, intent: nil) }
        if record.recordType == MobileCloudSchema.tagAssignmentChangeRecordType,
           let path = record["path"] as? String,
           let revision = record["baseRevision"] as? NSNumber {
            return MobileCloudInboundIntent(recordName: record.recordID.recordName, intent: MobileWorkspaceIntent(
                id: id, kind: .tagAssignment, targetPath: MobileWorkspacePath.normalizedRelative(path),
                baseRevision: revision.int64Value, tagIDs: [],
                addTagIDs: Set(record["addTagIDs"] as? [String] ?? []),
                removeTagIDs: Set(record["removeTagIDs"] as? [String] ?? []),
                captureName: nil, captureKind: nil, createdAt: createdAt
            ))
        }
        if record.recordType == MobileCloudSchema.captureIntentRecordType,
           let json = record["planningEdit"] as? String, let data = json.data(using: .utf8),
           let edit = try? JSONDecoder().decode(MobilePlanningEdit.self, from: data), edit.id == id {
            return MobileCloudInboundIntent(recordName: record.recordID.recordName,
                intent: MobileWorkspaceIntent(id: id, kind: .planningEdit, targetPath: nil, baseRevision: nil,
                    tagIDs: [], addTagIDs: [], removeTagIDs: [], captureName: nil, captureKind: nil,
                    createdAt: createdAt, planningEdit: edit))
        }
        if record.recordType == MobileCloudSchema.captureIntentRecordType,
           let tagID = record["tagID"] as? String,
           let name = record["tagName"] as? String {
            let tag = Tag(id: tagID, name: name,
                          colorIndex: (record["tagColorIndex"] as? NSNumber)?.intValue ?? Tag.colorIndex(for: name),
                          createdAt: (record["tagCreatedAt"] as? Date) ?? createdAt)
            return MobileCloudInboundIntent(recordName: record.recordID.recordName, intent: MobileWorkspaceIntent(
                id: id, kind: .tagCreation, targetPath: nil, baseRevision: nil,
                tagIDs: [], addTagIDs: [], removeTagIDs: [], captureName: nil, captureKind: nil,
                createdTag: tag, createdAt: createdAt
            ))
        }
        if record.recordType == MobileCloudSchema.captureIntentRecordType,
           let name = record["captureName"] as? String {
            return MobileCloudInboundIntent(recordName: record.recordID.recordName, intent: MobileWorkspaceIntent(
                id: id, kind: .captureClassification, targetPath: nil, baseRevision: nil,
                tagIDs: Set(record["tagIDs"] as? [String] ?? []), addTagIDs: [], removeTagIDs: [],
                captureName: name, captureKind: (record["captureKind"] as? String).flatMap(CaptureClassificationKind.init(rawValue:)),
                captureDestinationPath: record["captureDestinationPath"] as? String,
                captureExpectedChildren: Set(record["captureExpectedChildren"] as? [String] ?? []),
                createdAt: createdAt,
                captureLinks: WorkItemLinks.decode(record["captureLinks"] as? String)
            ))
        }
        return MobileCloudInboundIntent(recordName: record.recordID.recordName, intent: nil)
    }

    /// Writes a list field, or leaves it out entirely when there is nothing in it.
    ///
    /// CloudKit cannot infer a list field's element type from an empty array, and
    /// rejects the whole record with "cannot use an empty list to initialize a new
    /// field". Most work items carry no tags, so on a fresh container that single
    /// rejection stopped the entire work-item projection from ever starting — the
    /// phone's Work tab and Next Work widget simply stayed empty. Every reader on both
    /// sides already treats a missing list and an empty list identically.
    static func setList(_ values: [String], forKey key: String, on record: CKRecord) {
        record[key] = values.isEmpty ? nil : values
    }

    private static func record(for prepared: MobileCloudProjectionState.Prepared) -> CKRecord {
        let candidate = prepared.candidate
        let record = CKRecord(recordType: candidate.recordType, recordID: CKRecord.ID(recordName: candidate.recordName))
        switch candidate {
        case .tag(let tag):
            record["id"] = tag.id; record["name"] = tag.name
            record["colorIndex"] = NSNumber(value: tag.colorIndex); record["createdAt"] = tag.createdAt
        case .entry(let entry):
            if let overview = entry.overview?.encoded { record["overviewJSON"] = overview }
            record["path"] = entry.path
            if let parentPath = entry.parentPath { record["parentPath"] = parentPath }
            record["name"] = entry.name; record["isDirectory"] = NSNumber(value: entry.isDirectory)
            record["revision"] = NSNumber(value: prepared.revision)
            setList(Array(entry.tagIDs).sorted(), forKey: "tagIDs", on: record)
            if let modifiedAt = entry.modifiedAt { record["modifiedAt"] = modifiedAt }
            if let details = entry.projectDetails {
                record["overviewJSON"] = MobileProjectEnvelope.encode(details)
                if let oneLiner = details.oneLiner { record["projectOneLiner"] = oneLiner }
                if let summary = details.summary { record["projectSummary"] = summary }
                if let domain = details.domain { record["projectDomain"] = domain }
                if let status = details.status { record["projectStatus"] = status }
                if let phase = details.phase { record["projectPhase"] = phase }
                if let githubURL = details.githubURL { record["githubURL"] = githubURL }
                if let websiteURL = details.websiteURL { record["websiteURL"] = websiteURL }
                record["resourceCount"] = NSNumber(value: details.resourceCount)
                record["collectionCount"] = NSNumber(value: details.collectionCount)
                record["mediaCount"] = NSNumber(value: details.mediaCount)
                record["taskCount"] = NSNumber(value: details.taskCount)
                record["featureCount"] = NSNumber(value: details.featureCount)
                record["milestoneCount"] = NSNumber(value: details.milestoneCount)
                record["workLogCount"] = NSNumber(value: details.workLogCount)
            }
        case .workItem(let item):
            record["id"] = item.id; record["path"] = item.path; record["title"] = item.title
            record["body"] = MobileActionProjection.encode(item)
            record["kind"] = item.kind.rawValue; record["status"] = item.status.rawValue
            record["stage"] = item.stage.rawValue; record["priority"] = item.priority.rawValue
            if let projectPath = item.projectPath { record["projectPath"] = projectPath }
            if let dueDate = item.dueDate { record["dueDate"] = dueDate }
            record["revision"] = NSNumber(value: prepared.revision)
            setList(Array(item.tagIDs).sorted(), forKey: "tagIDs", on: record)
        case .idea(let idea):
            record["path"] = idea.path; record["title"] = idea.title
            record["description"] = idea.description
            record["serviceID"] = idea.serviceID
            record["attachmentsJSON"] = MobileIdeaEnvelope.encode(idea)
            record["revision"] = NSNumber(value: prepared.revision)
            setList(Array(idea.tagIDs).sorted(), forKey: "tagIDs", on: record)
            if let modifiedAt = idea.modifiedAt { record["modifiedAt"] = modifiedAt }
        }
        return record
    }

    private static func cloudError(_ error: Error) -> MobileCloudError {
        // Already classified — usually a per-record failure raised after the rest of the
        // batch was published. Re-wrapping it would lose `noAccount` and `rejected`, and
        // with them the outbox's ability to tell a retry from a refusal.
        if let error = error as? MobileCloudError { return error }
        guard let error = error as? CKError else { return .unavailable(error.localizedDescription) }
        switch error.code {
        case .notAuthenticated, .accountTemporarilyUnavailable: return .noAccount
        case .invalidArguments, .constraintViolation, .serverRejectedRequest, .badContainer,
             .badDatabase, .incompatibleVersion, .permissionFailure, .managedAccountRestricted,
             .referenceViolation: return .configuration(error.localizedDescription)
        default: return .unavailable(error.localizedDescription)
        }
    }
}
