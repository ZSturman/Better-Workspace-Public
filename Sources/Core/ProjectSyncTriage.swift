import Foundation

/// Sorts what differs between this Mac and Notion into what can happen on its own, what
/// the evidence settles, what needs a person, and what no longer matters.
///
/// Evidence comes from the record itself: an edit made in this app carries a field edit
/// time (`localFieldEditedAt`), Notion carries the page's edit time, and values seeded
/// from older metadata at first import carry neither. Nothing here writes; it only says
/// what each difference is and what would resolve it. See docs/NOTION_SYNC.md.
public enum ProjectSyncTriage {
    /// The person's explicit choices about what may move without them. Stored in the
    /// graph state (`ProjectSyncPolicy.key`) so automatic passes and the Sync Center agree.
    public struct Policy: Codable, Sendable, Equatable {
        public static let key = "syncPolicy"
        /// Take one-sided Notion changes on existing records (and new Notion records that
        /// never create a local file) in automatic passes. Off unless the person turns it on.
        public var receiveNotionChanges = false
        /// Owner policy: newest known edit wins; tied/unknown times prefer Workspace.
        public var preferWorkspaceChanges = false
        /// Offer ideas and daily work logs observed by the background service as Notion
        /// drafts. Off: they stay with the service, which keeps them; nothing is lost.
        public var offerServiceRecords = false
        /// Folders (canonical paths ending in "/") whose files never update Notion on their
        /// own: the Workspace's Backups area holds snapshots, and a copy there must not
        /// overwrite a live page (October 29: four backed-up tasks were about to).
        public var heldPaths: [String] = []
        public init(receiveNotionChanges: Bool = false, offerServiceRecords: Bool = false, heldPaths: [String] = [], preferWorkspaceChanges: Bool = false) {
            self.receiveNotionChanges = receiveNotionChanges; self.offerServiceRecords = offerServiceRecords; self.heldPaths = heldPaths
            self.preferWorkspaceChanges = preferWorkspaceChanges
        }
        public func holds(_ path: String) -> Bool { heldPaths.contains { path.hasPrefix($0) } }
        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            receiveNotionChanges = try container.decodeIfPresent(Bool.self, forKey: .receiveNotionChanges) ?? false
            preferWorkspaceChanges = try container.decodeIfPresent(Bool.self, forKey: .preferWorkspaceChanges) ?? false
            offerServiceRecords = try container.decodeIfPresent(Bool.self, forKey: .offerServiceRecords) ?? false
            heldPaths = try container.decodeIfPresent([String].self, forKey: .heldPaths) ?? []
        }
    }

    public enum Bucket: Int, Comparable, CaseIterable, Codable, Sendable {
        /// Can sync without asking: one side changed, or the change is clearly the person's own.
        case automatic
        /// Settled by evidence (an edit time, or Notion having nothing there).
        case reconcilable
        /// Needs a person: undated conflicts, overwrites of Notion values, deletions, uploads.
        case decision
        /// No longer meaningful: duplicates, drafts whose file is gone.
        case obsolete
        public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    public enum Side: String, Codable, Sendable { case local, notion, merge }

    public enum Category: String, CaseIterable, Codable, Sendable {
        case conflict, localEdit, notionEdit, newHere, newInNotion, upload, archive, serviceRecord, duplicate, missingFile, failed
        public var title: String {
            switch self {
            case .conflict: return "Conflicts"
            case .localEdit: return "Changed here"
            case .notionEdit: return "Changed in Notion"
            case .newHere: return "New here"
            case .newInNotion: return "New in Notion"
            case .upload: return "Files to upload"
            case .archive: return "Archived or deleted"
            case .serviceRecord: return "From the background service"
            case .duplicate: return "Duplicates"
            case .missingFile: return "File no longer exists"
            case .failed: return "Failed"
            }
        }
    }

    public struct FieldDiff: Identifiable, Sendable {
        public let id: String
        public let name: String
        public let state: ProjectFieldChange.State
        public let local: ProjectJSON
        public let notion: ProjectJSON
        /// Established from edit times when both are known.
        public let newer: Side?
        /// What would resolve it, when that is known.
        public let recommended: Side?
        public let bucket: Bucket
        public let note: String?
        public let mergeBlockedReason: String?
        public var merged: ProjectJSON? { mergeBlockedReason == nil ? ProjectSyncTriage.mergedValue(local: local, notion: notion) : nil }
    }

    public struct Item: Identifiable, Sendable {
        public var id: String { record.id }
        public let record: ProjectGraphRecord
        public let category: Category
        public let bucket: Bucket
        public let fields: [FieldDiff]
        /// Project page ids this record belongs to (its own for a project).
        public let projectIDs: [String]
        /// Short reason for the bucket, for a list row.
        public let reason: String
        public var sendsToNotion: Bool { record.pageID == nil || fields.contains { $0.recommended == .local || $0.recommended == .merge } || record.archiveRequested || !(record.pendingUploads ?? []).isEmpty }
        public var receivesFromNotion: Bool { fields.contains { $0.recommended == .notion || $0.recommended == .merge } || category == .newInNotion }
        /// Changes when anything about the difference changes; a deferral of an older
        /// fingerprint no longer applies.
        public var fingerprint: String {
            let parts = fields.map { "\($0.id)=\($0.local.comparable.display)|\($0.notion.comparable.display)" }.sorted()
            return ([category.rawValue, record.pageID ?? "draft", String(record.archiveRequested), String(record.remoteArchived)] + parts).joined(separator: ";")
        }
    }

    // MARK: Fields

    /// An additive union. Prefer canonical Notion options for duplicate names, keep
    /// stable order, and never concatenate scalar/text/file properties.
    public static func mergedValue(local: ProjectJSON, notion: ProjectJSON) -> ProjectJSON? {
        guard let type = local["type"].string ?? notion["type"].string,
              ["multi_select", "relation"].contains(type),
              local == .null || local["type"].string == type,
              notion == .null || notion["type"].string == type else { return nil }
        func entries(_ value: ProjectJSON) -> [ProjectJSON]? {
            if value == .null { return [] }
            guard case .array(let values) = value[type], !value["has_more"].bool else { return nil }
            return values
        }
        guard let left = entries(local), let right = entries(notion) else { return nil }
        func key(_ value: ProjectJSON) -> String? {
            if type == "relation" { return value["id"].string.map(ProjectGraph.normalizedID) }
            return value["name"].string.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        }
        var seen = Set<String>(), optionIDs = Set<String>(), values: [ProjectJSON] = []
        for value in right + left {
            guard let identity = key(value), !identity.isEmpty else { return nil }
            let optionID = type == "multi_select" ? value["id"].string : nil
            let duplicate = seen.contains(identity) || optionID.map { optionIDs.contains($0) } == true
            seen.insert(identity)
            if let optionID { optionIDs.insert(optionID) }
            if !duplicate { values.append(value) }
        }
        // Notion array writes are bounded. An oversized union needs a manual choice.
        guard values.count <= 100 else { return nil }
        var envelope = (notion == .null ? local : notion).object
        envelope[type] = .array(values)
        return .object(envelope)
    }

    public static func mergeChoices(_ item: Item) -> [String: Side] {
        guard item.record.pageID != nil, !item.record.remoteArchived, !item.record.archiveRequested,
              ![Category.archive, .failed, .duplicate, .missingFile, .newInNotion].contains(item.category) else { return [:] }
        return Dictionary(uniqueKeysWithValues: item.fields.compactMap { $0.merged == nil ? nil : ($0.id, .merge) })
    }

    /// Names Notion treats as one option when they differ only in case or spacing.
    static func equivalent(_ lhs: ProjectJSON, _ rhs: ProjectJSON) -> Bool {
        func names(_ value: ProjectJSON) -> [String]? {
            guard let type = value["type"].string else { return nil }
            switch type {
            case "select", "status": return [value[type]["name"].string ?? ""]
            case "multi_select": return value[type].array.compactMap { $0["name"].string }
            case "title", "rich_text": return [value.display]
            default: return nil
            }
        }
        guard let left = names(lhs), let right = names(rhs) else { return false }
        func normalize(_ values: [String]) -> [String] {
            values.map { $0.lowercased().trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "_", with: " ") }.sorted()
        }
        return normalize(left) == normalize(right)
    }

    public static func isEmpty(_ value: ProjectJSON) -> Bool { value.comparable == .null }

    static func field(_ change: ProjectFieldChange, record: ProjectGraphRecord, source: ProjectGraphSource, unavailableReferences: Set<String> = [], policy: Policy = .init()) -> FieldDiff {
        let name = source.name(for: change.id)
        let references = (change.local["relation"].array + change.remote["relation"].array).compactMap { $0["id"].string }.map(ProjectGraph.normalizedID)
        let blocked = references.contains(where: unavailableReferences.contains) ? "Includes archived or deleted links; review these in Notion." : nil
        let localAt = record.localFieldEditedAt?[change.id]
        let remoteAt = record.editedAt
        var newer: Side?
        if let localAt, let remoteAt, localAt != remoteAt { newer = localAt > remoteAt ? .local : .notion }
        func diff(_ bucket: Bucket, _ recommended: Side?, _ note: String? = nil) -> FieldDiff {
            FieldDiff(id: change.id, name: name, state: change.state, local: change.local, notion: change.remote,
                      newer: newer, recommended: recommended, bucket: bucket, note: note, mergeBlockedReason: blocked)
        }
        if let blocked, change.state != .equal && change.state != .incoming { return diff(.decision, nil, blocked) }
        if policy.preferWorkspaceChanges, record.serviceRecordID == nil,
           change.state == .conflict || change.state == .outgoing {
            // Finder category is structural evidence, independent of a page timestamp.
            if record.finderProjectAbsent == true, name == "Status" { return diff(.automatic, .local, "No longer in Projects; keep Idea status") }
            // An empty undated import was never a Workspace edit.
            if localAt == nil, isEmpty(change.local), change.state == .outgoing {
                return diff(.automatic, .notion, "Nothing here to send; Notion keeps its value")
            }
            let winner: Side = change.state == .conflict ? (newer ?? .local) : .local
            return diff(.automatic, winner, winner == .notion ? "Notion has the newer edit time" : "Workspace takes priority unless Notion changed this field more recently")
        }
        // A union only makes sense when this Mac's side differs from the last agreed
        // value. A one-sided Notion change (a new work-log link) is simply Notion's, and a
        // union there would bring back values Notion removed.
        if blocked == nil, change.state == .conflict || change.state == .outgoing, record.pageID != nil,
           (!record.baseline.isEmpty || !isEmpty(change.local)),
           mergedValue(local: change.local, notion: change.remote) != nil {
            return diff(.reconcilable, .merge, "Keep values from both sides")
        }
        switch change.state {
        case .equal:
            return diff(.automatic, .notion)
        case .incoming:
            // Recommend Notion for a reviewed Get; background passes never take it.
            return diff(.automatic, .notion)
        case .outgoing:
            if localAt != nil { return diff(.automatic, .local) }
            // No edit time: seeded from older metadata, not edited here.
            if isEmpty(change.remote) { return diff(.reconcilable, .local, "Notion has no value") }
            if equivalent(change.local, change.remote) { return diff(.automatic, .notion, "Same value, different spelling") }
            // Seeded with nothing (a field this Mac never had). Sending it would erase
            // Notion's value; keeping Notion's loses nothing. An intentional clear made
            // here carries an edit time and is handled above.
            if isEmpty(change.local) { return diff(.automatic, .notion, "Nothing here to send; Notion keeps its value") }
            if record.serviceRecordID != nil { return diff(.decision, nil, "Recalculated by the background service after it was sent") }
            return diff(.decision, nil, "Would replace a Notion value with older metadata")
        case .conflict:
            if equivalent(change.local, change.remote) { return diff(.automatic, .notion, "Same value, different spelling") }
            if let newer { return diff(.reconcilable, newer, newer == .local ? "Changed here more recently" : "Changed in Notion more recently") }
            return diff(.decision, nil, "Both changed; no edit times to compare")
        }
    }

    // MARK: Records

    public static func item(for record: ProjectGraphRecord, source: ProjectGraphSource, sources: [ProjectGraphSource],
                            syncedTitles: Set<String>, fileExists: (String) -> Bool, unavailableReferences: Set<String> = [],
                            policy: Policy = Policy()) -> Item? {
        let changes = record.changes.filter { $0.state != .equal && source.writable($0.id) }
        let unaccepted = record.baseline.isEmpty && !record.remote.isEmpty
        let archiveChange = record.remoteArchived != (record.acknowledgedArchived ?? false)
        let draft = record.pageID == nil
        let uploads = record.pendingUploads ?? []
        guard draft || unaccepted || archiveChange || record.archiveRequested || !uploads.isEmpty
                || record.serviceAcknowledgementPending == true || !changes.isEmpty else { return nil }
        let fields = changes.map { field($0, record: record, source: source, unavailableReferences: unavailableReferences, policy: policy) }
        let projects = projectIDs(record, source: source, sources: sources)
        let held = record.localPath.map(policy.holds) ?? false
        func make(_ category: Category, _ bucket: Bucket, _ reason: String) -> Item {
            // A snapshot copy never moves on its own; obsolete stays obsolete.
            guard held, bucket != .obsolete else {
                return Item(record: record, category: category, bucket: bucket, fields: fields, projectIDs: projects, reason: reason)
            }
            return Item(record: record, category: category, bucket: .decision, fields: fields, projectIDs: projects, reason: "In Backups, a snapshot copy. " + reason)
        }
        // A failed attempt keeps its own category; retrying and backing off is the
        // runner's job (`ProjectAutoSyncPlanner`). Only an ambiguous create needs a person.
        if record.ambiguousCreate { return make(.failed, .decision, "May already exist in Notion") }
        if record.pageID != nil, record.finderProjectAbsent != true, let path = record.localPath, !fileExists(path) {
            return make(.missingFile, .decision, "The local source is unavailable; its pending values are retained")
        }
        if record.archiveRequested { return make(.archive, .decision, "Archive in Notion") }
        if archiveChange { return make(.archive, .decision, record.remoteArchived ? "Archived in Notion" : "Restored in Notion") }
        if draft {
            if let path = record.localPath, !fileExists(path) { return make(.missingFile, .obsolete, "Its file was deleted") }
            if syncedTitles.contains(titleKey(record)) { return make(.duplicate, .obsolete, "Already in Notion under the same name") }
            if !uploads.isEmpty {
                let bytes = uploads.reduce(0) { $0 + $1.byteCount }
                return make(.upload, .decision, "Uploads \(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))")
            }
            if record.serviceRecordID != nil {
                // Not a difference anyone made: the service keeps these itself. They are
                // offered for Notion only when the person asked for that.
                return policy.offerServiceRecords ? make(.serviceRecord, .decision, "Observed by the background service")
                    : make(.serviceRecord, .obsolete, "Kept by the background service; not sent to Notion")
            }
            if record.localFieldEditedAt?.isEmpty == false { return make(.newHere, .automatic, "Made here") }
            return make(.newHere, .decision, "Imported, never sent")
        }
        if !uploads.isEmpty { return make(.upload, .decision, "Uploads a file") }
        let bucket = fields.map(\.bucket).max() ?? .automatic
        // A day the service recalculated after its log was sent. Notion still has what
        // was sent; whether the new numbers replace it is the person's call, and only
        // when they asked for service records in Notion at all.
        if record.serviceRecordID != nil, !fields.isEmpty, fields.allSatisfy({ $0.state == .outgoing && record.localFieldEditedAt?[$0.id] == nil }) {
            if !policy.offerServiceRecords { return make(.serviceRecord, .obsolete, "Recalculated by the background service; Notion keeps what was sent") }
            if fields.contains(where: { $0.bucket == .decision }) { return make(.serviceRecord, .decision, "Recalculated by the background service after it was sent") }
        }
        if unaccepted && !fields.contains(where: { $0.state == .conflict || $0.state == .outgoing }) {
            return make(.newInNotion, .automatic, "Not yet brought here")
        }
        if fields.contains(where: { $0.state == .conflict && $0.bucket != .automatic }) {
            return make(.conflict, bucket, bucket == .reconcilable ? (fields.contains { $0.recommended == .merge } ? "Merge keeps values from both sides" : "Newer side is known") : "Both sides changed")
        }
        if fields.contains(where: { $0.recommended == .local }) || fields.contains(where: { $0.state == .outgoing }) {
            return make(.localEdit, bucket, bucket == .automatic ? "Changed here" : bucket == .reconcilable ? "Fills empty Notion fields" : "Would replace Notion values")
        }
        if record.serviceAcknowledgementPending == true && fields.isEmpty { return make(.serviceRecord, .automatic, "Confirming with the background service") }
        return make(.notionEdit, bucket, "Changed in Notion")
    }

    public static func items(records: [ProjectGraphRecord], sources: [ProjectGraphSource], policy: Policy = Policy(),
                             fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> [Item] {
        let byID = Dictionary(sources.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let unavailable = Set(records.filter { $0.locallyDeleted == true || $0.remoteArchived }.flatMap { [$0.id, $0.pageID].compactMap { $0 }.map(ProjectGraph.normalizedID) })
        let live = records.filter { $0.locallyDeleted != true }
        let synced = Set(live.filter { $0.pageID != nil }.map(titleKey))
        return live.compactMap { record in
            byID[record.sourceID].flatMap { item(for: record, source: $0, sources: sources, syncedTitles: synced, fileExists: fileExists, unavailableReferences: unavailable, policy: policy) }
        }
    }

    static func titleKey(_ record: ProjectGraphRecord) -> String {
        "\(record.kind.rawValue)|\(record.title.lowercased().trimmingCharacters(in: .whitespacesAndNewlines))"
    }

    static func projectIDs(_ record: ProjectGraphRecord, source: ProjectGraphSource, sources: [ProjectGraphSource]) -> [String] {
        if record.kind == .projects { return [ProjectGraph.normalizedID(record.pageID ?? record.id)] }
        guard let projects = sources.first(where: { $0.kind == .projects }) else { return [] }
        return source.schema.object.keys.sorted().filter { source.property(named: $0)?.definition["relation"]["data_source_id"].string == projects.id }
            .flatMap { record.value($0, source: source)["relation"].array.compactMap { $0["id"].string } }
            .map(ProjectGraph.normalizedID)
    }

    // MARK: Resolution

    /// Scalar per-field choices (`true` = keep this Mac's value) for the recommended resolution,
    /// in the shape `NotionProjectSync.pull/push` take. Fields without a recommendation
    /// and additive merges are left out; the Boolean legacy review cannot represent a union.
    public static func recommendedResolutions(_ item: Item) -> [String: Bool] {
        Dictionary(uniqueKeysWithValues: item.fields.compactMap { field in
            field.state == .conflict && field.recommended != .merge ? field.recommended.map { (field.id, $0 == .local) } : nil
        })
    }
}

/// What automatic sync does on one pass, and what it leaves for a person.
///
/// Ordinary outgoing `.automatic` edits on existing pages move on their own. Differences
/// where Notion's value is kept anyway (equal spellings, nothing here) settle on this Mac
/// without a request. Routine one-sided Notion changes are received automatically only
/// when the person's policy says so; otherwise they wait as one action, not as decisions.
/// New pages, conflicts, archives, uploads, missing files and service handoffs require
/// review. Per-record deferral and retry backoff are retained.
public enum ProjectAutoSyncPlanner {
    public struct Failure: Codable, Sendable, Equatable {
        public var attempts: Int
        public var nextAttempt: Date
        public var message: String
        public init(attempts: Int, nextAttempt: Date, message: String) {
            self.attempts = attempts; self.nextAttempt = nextAttempt; self.message = message
        }
    }

    public struct Plan: Sendable {
        /// Receive Notion's side: routine changes, when the policy allows it.
        public var pull: [ProjectSyncTriage.Item] = []
        /// Send this Mac's side (made or edited here).
        public var push: [ProjectSyncTriage.Item] = []
        /// Settled here alone: Notion's value is kept where this Mac's only differs in
        /// spelling or is empty. No request and no file write.
        public var settle: [ProjectSyncTriage.Item] = []
        /// Routine Notion changes the policy leaves for the person to receive together.
        public var receivable: [ProjectSyncTriage.Item] = []
        /// Automatic, but backing off after a failure.
        public var waiting: [ProjectSyncTriage.Item] = []
        /// Needs a person: decisions, reconcilable conflicts, repeated failures.
        public var attention: [ProjectSyncTriage.Item] = []
        public var deferred: [ProjectSyncTriage.Item] = []
        public var obsolete: [ProjectSyncTriage.Item] = []
    }

    /// After this many failed attempts an automatic change asks for attention.
    public static let attemptsBeforeAttention = 4

    /// 1 minute, 5 minutes, 30 minutes, then 2 hours.
    public static func backoff(attempts: Int) -> TimeInterval {
        [60, 300, 1800, 7200][min(max(attempts - 1, 0), 3)]
    }

    /// Ideas and work logs use the service's separately authorized handoff; ordinary
    /// automatic passes must not write them.
    static let receiveOnly: Set<ProjectEntityKind> = [.ideas, .workLogs]

    /// Kinds whose received values change only this app's own records. Tasks, features
    /// and milestones rewrite `.bw.md` files in the Workspace, and ideas hand values to
    /// the background service; those keep a reviewed Get.
    public static let receivableKinds: Set<ProjectEntityKind> = Set(ProjectEntityKind.allCases).subtracting([.tasks, .features, .milestones, .ideas])

    /// Categories whose state is more than field values; never settled or received routinely.
    static let structural: Set<ProjectSyncTriage.Category> = [.missingFile, .failed, .archive, .upload, .duplicate, .serviceRecord, .newHere]

    static func plain(_ item: ProjectSyncTriage.Item) -> Bool {
        let record = item.record
        return record.pageID != nil && item.bucket == .automatic && !structural.contains(item.category)
            && !record.archiveRequested && record.remoteArchived == (record.acknowledgedArchived ?? false)
            && (record.pendingUploads ?? []).isEmpty && !record.ambiguousCreate && record.serviceAcknowledgementPending != true
            && !item.fields.isEmpty
    }

    /// Every difference keeps Notion's value and none is incoming: nothing needs to move.
    public static func settlesLocally(_ item: ProjectSyncTriage.Item) -> Bool {
        plain(item) && item.fields.allSatisfy { $0.recommended == .notion && $0.state != .incoming && $0.state != .equal }
    }

    /// Only Notion moved (or a field settles to Notion's value), on a kind whose received
    /// values touch no Workspace file. A new Notion project is excluded: linking it seeds
    /// local metadata, which is what built the October 11 backlog.
    public static func receivesRoutinely(_ item: ProjectSyncTriage.Item) -> Bool {
        // Service-owned records (its ideas and daily logs) hand received values back to the
        // service; that stays reviewed. Work logs from other writers have no service id.
        guard plain(item), receivableKinds.contains(item.record.kind), item.record.serviceRecordID == nil,
              item.fields.allSatisfy({ $0.recommended == .notion && $0.bucket == .automatic }),
              item.fields.contains(where: { $0.state == .incoming }) else { return false }
        return !(item.category == .newInNotion && item.record.kind == .projects)
    }

    public static func plan(_ items: [ProjectSyncTriage.Item], deferred: [String: String],
                            failures: [String: Failure], policy: ProjectSyncTriage.Policy = .init(), now: Date = Date()) -> Plan {
        var plan = Plan()
        for item in items {
            let priorityReceive = policy.preferWorkspaceChanges && item.fields.contains { $0.state == .conflict }
            if let fingerprint = deferred[item.id], fingerprint == item.fingerprint { plan.deferred.append(item); continue }
            if item.bucket == .obsolete { plan.obsolete.append(item); continue }
            if let failure = failures[item.id] {
                if failure.attempts >= attemptsBeforeAttention { plan.attention.append(item); continue }
                if failure.nextAttempt > now { plan.waiting.append(item); continue }
            }
            if settlesLocally(item) && !priorityReceive { plan.settle.append(item); continue }
            if policy.preferWorkspaceChanges, plain(item), receivableKinds.contains(item.record.kind), item.record.serviceRecordID == nil,
               item.fields.allSatisfy({ $0.recommended == .notion }), priorityReceive {
                if policy.receiveNotionChanges { plan.pull.append(item) } else { plan.receivable.append(item) }
                continue
            }
            if receivesRoutinely(item) {
                if policy.receiveNotionChanges { plan.pull.append(item) } else { plan.receivable.append(item) }
                continue
            }
            // With receiving allowed, a record whose incoming values are routine and whose
            // other differences are this Mac's own dated edits (a Finder move into Ideas,
            // beside a new work-log link) syncs both ways; nothing in it needs a decision.
            if policy.receiveNotionChanges, plain(item), receivableKinds.contains(item.record.kind), !receiveOnly.contains(item.record.kind),
               item.record.serviceRecordID == nil,
               item.fields.allSatisfy({ $0.bucket == .automatic && ($0.state == .incoming ? $0.recommended == .notion : ($0.recommended == .local || $0.recommended == .notion)) }),
               item.fields.contains(where: { $0.state == .incoming }), item.fields.contains(where: { $0.recommended == .local }) {
                plan.push.append(item); continue
            }
            // Other incoming values require a reviewed Get. Never accept them as a side
            // effect of sending an unrelated local field on the same record.
            guard item.record.pageID != nil,
                  !item.fields.contains(where: { $0.state == .incoming }),
                  item.bucket == .automatic else { plan.attention.append(item); continue }
            let sends = item.record.pageID == nil || item.fields.contains { $0.recommended == .local }
            if sends {
                if receiveOnly.contains(item.record.kind) { plan.attention.append(item) } else { plan.push.append(item) }
            } else {
                plan.attention.append(item)
            }
        }
        return plan
    }

    /// Fields where Notion's value is taken although this Mac's differs (equal
    /// spellings): settled locally before a pull or push, so neither side is rewritten.
    public static func localChoices(_ item: ProjectSyncTriage.Item) -> [String: ProjectSyncTriage.Side] {
        Dictionary(uniqueKeysWithValues: item.fields.compactMap { field in
            field.state == .conflict && field.recommended == .local ? (field.id, .local)
                : field.recommended == .notion && field.state != .incoming && field.state != .equal ? (field.id, .notion) : nil
        })
    }
}
