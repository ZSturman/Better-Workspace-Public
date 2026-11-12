import Foundation
import CryptoKit

/// The portable, app-owned part of a workspace. Filesystem content is referenced by
/// its adapter, never copied into this model by browsing a Mac folder.
public struct WorkspaceRecordContent: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable {
        case project, task, feature, milestone, goal, idea, folder, note
    }
    public var kind: Kind
    public var title: String
    public var body: String
    public var parentID: UUID?
    public var isComplete: Bool
    public var projectMetadata: ProjectMetadata?
    public var projectLinks: ProjectPortfolioDetails?
    public var isDeleted: Bool
    /// Who does a task — "Me", "Agent" or "Either" — from its `action-metadata`
    /// delegation. Presentation only: Mac-observed, never written back from a device, and
    /// encoded only when present so existing revisions keep their identity.
    public var responsibility: String?

    public init(kind: Kind, title: String, body: String = "", parentID: UUID? = nil,
                isComplete: Bool = false, isDeleted: Bool = false, projectMetadata: ProjectMetadata? = nil, projectLinks: ProjectPortfolioDetails? = nil) {
        self.kind = kind; self.title = title; self.body = body; self.parentID = parentID
        self.isComplete = isComplete; self.isDeleted = isDeleted
        self.projectMetadata = projectMetadata; self.projectLinks = projectLinks
    }
}

enum WorkspaceStableIdentity {
    static func uuid(namespace: String, data: Data) -> UUID {
        var digest = Array(SHA256.hash(data: Data((namespace + "\0").utf8) + data).prefix(16))
        digest[6] = (digest[6] & 0x0f) | 0x80; digest[8] = (digest[8] & 0x3f) | 0x80
        return UUID(uuid: (digest[0], digest[1], digest[2], digest[3], digest[4], digest[5], digest[6], digest[7],
                           digest[8], digest[9], digest[10], digest[11], digest[12], digest[13], digest[14], digest[15]))
    }
}

/// Immutable revisions let disconnected devices retain both versions of an edit.
/// Timestamps are for display only; ancestry determines which changes supersede others.
public struct WorkspaceRecordRevision: Codable, Hashable, Identifiable, Sendable {
    public enum Origin: String, Codable, Sendable { case mac = "Mac", iOS = "iOS", legacy = "Earlier" }
    public let id: UUID
    public let recordID: UUID
    public let parents: Set<UUID>
    public let deviceID: UUID
    public let origin: Origin
    public let createdAt: Date
    public let recordCreatedAt: Date
    public let content: WorkspaceRecordContent

    public init(id: UUID = UUID(), recordID: UUID, parents: Set<UUID> = [], deviceID: UUID,
                origin: Origin, createdAt: Date = Date(), recordCreatedAt: Date? = nil, content: WorkspaceRecordContent) {
        self.id = id; self.recordID = recordID; self.parents = parents; self.deviceID = deviceID
        self.origin = origin; self.createdAt = createdAt; self.content = content
        self.recordCreatedAt = recordCreatedAt ?? createdAt
    }
}

public enum WorkspaceReplicaError: LocalizedError, Equatable {
    case invalid(String), revisionCollision, changed, conflicting, missing, unsupportedVersion
    public var errorDescription: String? {
        switch self {
        case .invalid(let reason): return reason
        case .revisionCollision: return "Two different changes have the same revision identity. Both sources have been retained; the merge was not applied."
        case .changed: return "The workspace changed after this preview. Review a new preview before continuing."
        case .conflicting: return "Review both versions of this item before making another change."
        case .missing: return "That item is not available yet. Its other changes may still be arriving."
        case .unsupportedVersion: return "This workspace was saved by a newer version of Better Workspace. Update the app to open it."
        }
    }
}

public struct WorkspaceRecordState: Identifiable, Sendable {
    public let id: UUID
    /// Multiple heads are a visible conflict, including a deletion concurrent with an edit.
    public let heads: [WorkspaceRecordRevision]
    public var isConflict: Bool { heads.count > 1 }
    public var resolved: WorkspaceRecordRevision? { heads.count == 1 ? heads[0] : nil }
}

/// A small revision graph, not a second filesystem index. It has no network or
/// filesystem side effects. Import, merge and edits validate a candidate before commit.
public struct WorkspaceReplica: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    public private(set) var formatVersion = currentVersion
    public let workspaceID: UUID
    /// Only an approved initial join may add another independently created root.
    /// All peers choose the same canonical ID from this set, regardless of initiator.
    public private(set) var joinedWorkspaceIDs: Set<UUID>
    public private(set) var revisions: [WorkspaceRecordRevision]

    public init(workspaceID: UUID = UUID(), revisions: [WorkspaceRecordRevision] = [], joinedWorkspaceIDs: Set<UUID>? = nil) throws {
        self.workspaceID = workspaceID; self.revisions = revisions
        self.joinedWorkspaceIDs = joinedWorkspaceIDs ?? [workspaceID]
        try validate()
    }

    private enum CodingKeys: String, CodingKey { case formatVersion, workspaceID, joinedWorkspaceIDs, revisions }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        formatVersion = try values.decode(Int.self, forKey: .formatVersion)
        guard formatVersion == Self.currentVersion else { throw WorkspaceReplicaError.unsupportedVersion }
        workspaceID = try values.decode(UUID.self, forKey: .workspaceID)
        joinedWorkspaceIDs = try values.decodeIfPresent(Set<UUID>.self, forKey: .joinedWorkspaceIDs) ?? [workspaceID]
        revisions = try values.decode([WorkspaceRecordRevision].self, forKey: .revisions)
        try validate()
    }

    public func validate() throws {
        guard formatVersion == Self.currentVersion else { throw WorkspaceReplicaError.unsupportedVersion }
        guard joinedWorkspaceIDs.count <= 256, joinedWorkspaceIDs.contains(workspaceID),
              joinedWorkspaceIDs.map(\.uuidString).min() == workspaceID.uuidString else {
            throw WorkspaceReplicaError.invalid("The workspace identity has not been adopted consistently.")
        }
        guard revisions.count <= 100_000 else { throw WorkspaceReplicaError.invalid("This workspace exceeds the revision limit.") }
        var known: [UUID: WorkspaceRecordRevision] = [:]
        for revision in revisions {
            if let previous = known[revision.id] {
                guard previous == revision else { throw WorkspaceReplicaError.revisionCollision }
                throw WorkspaceReplicaError.invalid("A revision is stored more than once.")
            }
            let value = revision.content
            guard !value.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  value.title.utf8.count <= 1_024, value.body.utf8.count <= 1_048_576,
                  value.parentID != revision.recordID, !revision.parents.contains(revision.id),
                  revision.parents.count <= 256, revision.createdAt.timeIntervalSince1970.isFinite,
                  revision.recordCreatedAt.timeIntervalSince1970.isFinite else {
                throw WorkspaceReplicaError.invalid("An item has invalid content or revision ancestry.")
            }
            known[revision.id] = revision
        }
        // Iterative topological validation avoids a recursive stack overflow for a
        // long history. Missing ancestors are allowed during paginated transfers.
        var pending: [UUID: Int] = [:], descendants: [UUID: [UUID]] = [:]
        for revision in revisions {
            for parentID in revision.parents {
                guard let parent = known[parentID] else { continue }
                guard parent.recordID == revision.recordID else {
                    throw WorkspaceReplicaError.invalid("A change refers to another item's history.")
                }
                pending[revision.id, default: 0] += 1
                descendants[parentID, default: []].append(revision.id)
            }
        }
        var ready = revisions.filter { pending[$0.id, default: 0] == 0 }.map(\.id)
        var index = 0
        while index < ready.count {
            for child in descendants[ready[index], default: []] {
                pending[child, default: 0] -= 1
                if pending[child] == 0 { ready.append(child) }
            }
            index += 1
        }
        guard ready.count == revisions.count else { throw WorkspaceReplicaError.invalid("The change history contains a cycle.") }
    }

    /// Only complete histories affect the view. A page containing a child before its
    /// parent must not hide the last usable version or resurrect a deleted item.
    public var records: [WorkspaceRecordState] {
        var waiting: [UUID: Int] = [:], children: [UUID: [UUID]] = [:]
        let known = Dictionary(uniqueKeysWithValues: revisions.map { ($0.id, $0) })
        for revision in revisions {
            waiting[revision.id] = revision.parents.count
            for parent in revision.parents { children[parent, default: []].append(revision.id) }
        }
        var complete = revisions.filter { $0.parents.isEmpty }.map(\.id)
        var index = 0, superseded: Set<UUID> = []
        while index < complete.count {
            let id = complete[index]
            for child in children[id, default: []] {
                waiting[child, default: 0] -= 1
                if waiting[child] == 0 { complete.append(child) }
            }
            if let revision = known[id] { superseded.formUnion(revision.parents) }
            index += 1
        }
        let heads = complete.filter { !superseded.contains($0) }.compactMap { known[$0] }
        return Dictionary(grouping: heads, by: \.recordID).map { id, versions in
            WorkspaceRecordState(id: id, heads: versions.sorted { $0.id.uuidString < $1.id.uuidString })
        }.sorted { $0.id.uuidString < $1.id.uuidString }
    }

    public var pendingRevisionCount: Int {
        // A complete revision is either a head or an ancestor of one.
        let known = Dictionary(uniqueKeysWithValues: revisions.map { ($0.id, $0) })
        var complete: Set<UUID> = [], queue = records.flatMap(\.heads).map(\.id), index = 0
        while index < queue.count {
            let id = queue[index]
            if complete.insert(id).inserted { queue.append(contentsOf: known[id]?.parents ?? []) }
            index += 1
        }
        return revisions.count - complete.count
    }

    /// UUID identity, never a title or path, joins content from different devices.
    public func merging(_ incoming: WorkspaceReplica) throws -> WorkspaceReplica {
        try validate(); try incoming.validate()
        var byID = Dictionary(uniqueKeysWithValues: revisions.map { ($0.id, $0) })
        for revision in incoming.revisions {
            if let existing = byID[revision.id], existing != revision { throw WorkspaceReplicaError.revisionCollision }
            byID[revision.id] = revision
        }
        return try Self(workspaceID: workspaceID, revisions: byID.values.sorted { $0.id.uuidString < $1.id.uuidString }, joinedWorkspaceIDs: joinedWorkspaceIDs)
    }

    /// Initial identity adoption is separate from routine revision delivery. The
    /// store exposes it only through its reviewed/checkpointed merge operation.
    public func joining(_ incoming: WorkspaceReplica) throws -> WorkspaceReplica {
        let combined = try merging(incoming)
        let roots = joinedWorkspaceIDs.union(incoming.joinedWorkspaceIDs)
        let canonical = roots.min { $0.uuidString < $1.uuidString }!
        return try Self(workspaceID: canonical, revisions: combined.revisions, joinedWorkspaceIDs: roots)
    }

    /// Normal edits require the exact version the editor opened. Only the reviewed
    /// resolution path may supersede several conflicting versions.
    @discardableResult
    public mutating func save(recordID: UUID = UUID(), content: WorkspaceRecordContent,
                              expectedHeads: Set<UUID>, deviceID: UUID,
                              origin: WorkspaceRecordRevision.Origin, resolvingConflict: Bool = false) throws -> WorkspaceRecordRevision {
        let state = records.first { $0.id == recordID }
        let current = Set(state?.heads.map(\.id) ?? [])
        guard current == expectedHeads else { throw WorkspaceReplicaError.changed }
        guard resolvingConflict || current.count <= 1 else { throw WorkspaceReplicaError.conflicting }
        // Never create a new root over a partially received history.
        guard !current.isEmpty || !revisions.contains(where: { $0.recordID == recordID }) else { throw WorkspaceReplicaError.missing }
        // A received move can leave a location unavailable (or cyclic). Preserve
        // that visible issue while allowing text/status edits and recovery. Only
        // a new or changed relationship must pass destination validation here.
        let preservesParent = state.map { !$0.heads.isEmpty && $0.heads.allSatisfy { $0.content.parentID == content.parentID } } ?? false
        if let parentID = content.parentID, !preservesParent {
            let resolved = Dictionary(uniqueKeysWithValues: records.compactMap { record in record.resolved.map { (record.id, $0.content) } })
            guard let parent = resolved[parentID], !parent.isDeleted,
                  [.project, .feature, .milestone, .folder, .idea].contains(parent.kind) else { throw WorkspaceReplicaError.missing }
            var ancestor: UUID? = parentID, visited: Set<UUID> = [recordID]
            while let id = ancestor {
                guard visited.insert(id).inserted else { throw WorkspaceReplicaError.invalid("That move would create a folder cycle.") }
                ancestor = resolved[id]?.parentID
            }
        }
        let revision = WorkspaceRecordRevision(recordID: recordID, parents: current, deviceID: deviceID, origin: origin,
            recordCreatedAt: state?.heads.map(\.recordCreatedAt).min(), content: content)
        let candidate = try Self(workspaceID: workspaceID, revisions: revisions + [revision], joinedWorkspaceIDs: joinedWorkspaceIDs)
        self = candidate
        return revision
    }

    /// Used for merge approval. Stable encoding does not depend on array/set order.
    public var fingerprint: String {
        get throws {
            try validate()
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            // Set's Codable order is unspecified. Canonicalize parents independently.
            struct Canonical: Encodable {
                let id: UUID; let recordID: UUID; let parents: [String]; let deviceID: UUID
                let origin: WorkspaceRecordRevision.Origin; let createdAt: Date; let recordCreatedAt: Date; let content: WorkspaceRecordContent
                init(_ value: WorkspaceRecordRevision) {
                    id = value.id; recordID = value.recordID; parents = value.parents.map(\.uuidString).sorted()
                    deviceID = value.deviceID; origin = value.origin; createdAt = value.createdAt
                    recordCreatedAt = value.recordCreatedAt; content = value.content
                }
            }
            let bytes = try encoder.encode(revisions.sorted { $0.id.uuidString < $1.id.uuidString }.map(Canonical.init))
            let identity = joinedWorkspaceIDs.map(\.uuidString).sorted().joined(separator: ",")
            return identity + ":" + SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        }
    }
}

extension WorkspaceReplica {
    /// Presentation only. This never renames a Mac file. Independently created items
    /// retain separate UUIDs even when their names, kinds and bodies are identical.
    public var displayTitles: [UUID: String] {
        func key(_ value: String) -> String {
            value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        }
        var result: [UUID: String] = [:]
        let visible = records.compactMap(\.resolved).filter { !$0.content.isDeleted }
        for siblings in Dictionary(grouping: visible, by: { $0.content.parentID }).values {
            let groups = Dictionary(grouping: siblings, by: { key($0.content.title) })
            var used = Set(siblings.map { key($0.content.title) })
            for groupKey in groups.keys.sorted() {
                let group = groups[groupKey]!
                for item in group.sorted(by: { $0.recordID.uuidString < $1.recordID.uuidString }) {
                    if group.count == 1 { result[item.recordID] = item.content.title; continue }
                    let base = item.content.title + "-" + item.origin.rawValue
                    var title = base, suffix = 2
                    while used.contains(key(title)) { title = base + "-\(suffix)"; suffix += 1 }
                    used.insert(key(title)); result[item.recordID] = title
                }
            }
        }
        return result
    }

    public enum LocationIssue: String, Sendable {
        case missingParent, conflictedParent, deletedParent, nonContainerParent, cycle, ancestorUnavailable
    }

    /// Concurrent moves can form a cycle without either device making an invalid
    /// local move. Keep every record and expose the problem for a reviewed move;
    /// never silently drop an orphaned subtree from the workspace.
    public var locationIssues: [UUID: LocationIssue] {
        let states = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
        var issues: [UUID: LocationIssue] = [:], good: Set<UUID> = []
        for record in states.values where record.resolved?.content.isDeleted == false {
            var path: [UUID] = [], positions: [UUID: Int] = [:], current = record.id
            while true {
                if let cycleStart = positions[current] {
                    for id in path[cycleStart...] { issues[id] = .cycle }
                    for id in path[..<cycleStart] { issues[id] = .ancestorUnavailable }
                    break
                }
                if issues[current] != nil {
                    for id in path { issues[id] = .ancestorUnavailable }
                    break
                }
                if good.contains(current) { good.formUnion(path); break }
                positions[current] = path.count; path.append(current)
                guard let parentID = states[current]?.resolved?.content.parentID else { good.formUnion(path); break }
                let parent = states[parentID]
                let problem: LocationIssue?
                if parent == nil { problem = .missingParent }
                else if parent!.isConflict { problem = .conflictedParent }
                else if parent!.resolved?.content.isDeleted == true { problem = .deletedParent }
                else if ![.project, .feature, .milestone, .folder, .idea].contains(parent!.resolved!.content.kind) { problem = .nonContainerParent }
                else { problem = nil }
                if let problem {
                    issues[current] = problem
                    for id in path.dropLast() { issues[id] = .ancestorUnavailable }
                    break
                }
                current = parentID
            }
        }
        return issues
    }
}
