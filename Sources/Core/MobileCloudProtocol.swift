import Foundation
import CloudKit

/// The disposable CloudKit representation of a Workspace.  These records are a cache
/// and command channel only: organized files remain the source of truth on the Mac.
///
/// Record types are deliberately namespaced because they are shared by two app
/// targets in one private CloudKit database.  See `docs/MOBILE_NOTES.md` for the
/// publisher/apply protocol that the Mac host must implement.
public enum MobileCloudSchema {
    public static let containerIdentifier = "iCloud.com.zacharysturman.BetterWorkspace"
    public static let tagRecordType = "BWTag"
    public static let indexRecordType = "BWWorkspaceEntry"
    public static let workItemRecordType = "BWWorkItem"
    public static let ideaRecordType = "BWIdea"
    public static let tagAssignmentChangeRecordType = "BWTagAssignmentChange"
    public static let captureIntentRecordType = "BWCaptureIntent"
    public static let downloadRecordType = "BWWorkspaceDownload"

    /// Every one of these record types is fetched with `TRUEPREDICATE`. CloudKit
    /// therefore needs a `QUERYABLE` index on its system `recordName` field for each
    /// type (in both the development and deployed production schemas). Keeping the
    /// list beside the protocol avoids adding a new channel without documenting the
    /// required schema change.
    public static let projectionRecordTypes = [
        tagRecordType,
        indexRecordType,
        workItemRecordType,
        ideaRecordType,
    ]

    public static let queryableRecordTypes = projectionRecordTypes + [
        tagAssignmentChangeRecordType,
        captureIntentRecordType,
    ]

    /// A fresh development container does not have any custom record types until its
    /// first write. A query for one is reported as `unknownItem`; for an optional
    /// cache/command channel that means "empty", not "sync is unavailable".
    ///
    /// Call this only around record-type queries. An `unknownItem` from a mutation is
    /// still meaningful and must retain its normal retry/error handling.
    public static func isMissingRecordType(_ error: Error) -> Bool {
        guard let cloudError = error as? CKError else { return false }
        return cloudError.code == .unknownItem
    }
}

/// A path in the mobile protocol is workspace-relative and normalized by the Mac from
/// a `URL.canonicalPath`.  It is never an iOS filesystem path: the phone cannot and
/// must not attempt to resolve `~/Workspace`.
public enum MobileWorkspacePath {
    public static func normalizedRelative(_ value: String) -> String? {
        let pieces = value.split(separator: "/", omittingEmptySubsequences: true)
        guard pieces.isEmpty == false,
              pieces.allSatisfy({ $0 != "." && $0 != ".." })
        else { return nil }
        return pieces.joined(separator: "/")
    }
}

/// Read-only audit summary; omits local IDs, file paths and executable commands.
public struct MobileProjectAssessment: Codable, Hashable, Sendable {
    public let assessedAt: String
    public let classification: String
    public let recommendation: String
    public let scores: [String: Int]
    public let workPriorityScore: Int
    public let validationCoverage: String
    public let confidence: String
    public init(_ audit: ProjectAuditAssessment) {
        assessedAt = audit.assessedAt; classification = String(audit.classification.prefix(200))
        recommendation = String(audit.recommendation.prefix(4000)); scores = audit.scores
        workPriorityScore = audit.workPriorityScore; validationCoverage = String(audit.validationCoverage.prefix(500))
        confidence = String(audit.confidence.prefix(200))
    }
}

/// The safe project context that accompanies one project-folder index entry. It is a
/// compact read-only projection of Better Workspace's private project notes; linked
/// databases, media, and repositories remain in their original systems.
public struct MobileProjectDetails: Identifiable, Hashable, Sendable, Codable {
    public let path: String
    public var oneLiner: String?
    public var summary: String?
    public var domain: String?
    public var status: String?
    public var phase: String?
    public let githubURL: String?
    public let websiteURL: String?
    public let resourceCount: Int
    public let collectionCount: Int
    public let mediaCount: Int
    public let taskCount: Int
    public let featureCount: Int
    public let milestoneCount: Int
    public let workLogCount: Int
    public let assessment: MobileProjectAssessment?
    public let projectID: String?
    public let serviceID: String?
    public let manualScore: Double?
    public let ratingCoverage: Double?
    public let lastWorked: Date?
    public var ratings: [String: Int]?
    public var scoringPreferences: ProjectScoringPreferences?
    public var needsSetup: Bool?
    public var previews: [MobileFilePreview]?
    public var projectType: String?
    public var createdAt: Date?

    private enum CodingKeys: String, CodingKey {
        case ratings, scoringPreferences, needsSetup, previews, projectType, createdAt
        case path, oneLiner, summary, domain, status, phase, githubURL, websiteURL, assessment, projectID, serviceID, manualScore, ratingCoverage, lastWorked
        case resourceCount, collectionCount, mediaCount, taskCount, featureCount, milestoneCount, workLogCount
    }

    public var id: String { path }

    public init(path: String, oneLiner: String? = nil, summary: String? = nil,
                domain: String? = nil, status: String? = nil, phase: String? = nil, githubURL: String? = nil,
                websiteURL: String? = nil, resourceCount: Int = 0, collectionCount: Int = 0,
                mediaCount: Int = 0, taskCount: Int = 0, featureCount: Int = 0,
                milestoneCount: Int = 0, workLogCount: Int = 0, assessment: MobileProjectAssessment? = nil, projectID: String? = nil, serviceID: String? = nil, manualScore: Double? = nil, ratingCoverage: Double? = nil, lastWorked: Date? = nil, ratings: [String: Int]? = nil, scoringPreferences: ProjectScoringPreferences? = nil, needsSetup: Bool? = nil, previews: [MobileFilePreview]? = nil, projectType: String? = nil, createdAt: Date? = nil) {
        self.projectType = projectType; self.createdAt = createdAt
        self.ratings = ratings; self.scoringPreferences = scoringPreferences; self.needsSetup = needsSetup; self.previews = previews
        self.path = MobileWorkspacePath.normalizedRelative(path) ?? path
        self.oneLiner = oneLiner
        self.summary = summary
        self.domain = domain
        self.status = status
        self.phase = phase
        self.githubURL = githubURL
        self.websiteURL = websiteURL
        self.resourceCount = max(0, resourceCount)
        self.collectionCount = max(0, collectionCount)
        self.mediaCount = max(0, mediaCount)
        self.taskCount = max(0, taskCount)
        self.featureCount = max(0, featureCount)
        self.milestoneCount = max(0, milestoneCount)
        self.workLogCount = max(0, workLogCount)
        self.assessment = assessment
        self.projectID = projectID; self.serviceID = serviceID; self.manualScore = manualScore; self.ratingCoverage = ratingCoverage; self.lastWorked = lastWorked
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            path: try values.decode(String.self, forKey: .path),
            oneLiner: try values.decodeIfPresent(String.self, forKey: .oneLiner),
            summary: try values.decodeIfPresent(String.self, forKey: .summary),
            domain: try values.decodeIfPresent(String.self, forKey: .domain),
            status: try values.decodeIfPresent(String.self, forKey: .status),
            phase: try values.decodeIfPresent(String.self, forKey: .phase),
            githubURL: try values.decodeIfPresent(String.self, forKey: .githubURL),
            websiteURL: try values.decodeIfPresent(String.self, forKey: .websiteURL),
            resourceCount: try values.decodeIfPresent(Int.self, forKey: .resourceCount) ?? 0,
            collectionCount: try values.decodeIfPresent(Int.self, forKey: .collectionCount) ?? 0,
            mediaCount: try values.decodeIfPresent(Int.self, forKey: .mediaCount) ?? 0,
            taskCount: try values.decodeIfPresent(Int.self, forKey: .taskCount) ?? 0,
            featureCount: try values.decodeIfPresent(Int.self, forKey: .featureCount) ?? 0,
            milestoneCount: try values.decodeIfPresent(Int.self, forKey: .milestoneCount) ?? 0,
            workLogCount: try values.decodeIfPresent(Int.self, forKey: .workLogCount) ?? 0,
            assessment: try values.decodeIfPresent(MobileProjectAssessment.self, forKey: .assessment),
            projectID: try values.decodeIfPresent(String.self, forKey: .projectID), serviceID: try values.decodeIfPresent(String.self, forKey: .serviceID),
            manualScore: try values.decodeIfPresent(Double.self, forKey: .manualScore), ratingCoverage: try values.decodeIfPresent(Double.self, forKey: .ratingCoverage),
            lastWorked: try values.decodeIfPresent(Date.self, forKey: .lastWorked),
            ratings: try values.decodeIfPresent([String: Int].self, forKey: .ratings),
            scoringPreferences: try values.decodeIfPresent(ProjectScoringPreferences.self, forKey: .scoringPreferences),
            needsSetup: try values.decodeIfPresent(Bool.self, forKey: .needsSetup),
            previews: try values.decodeIfPresent([MobileFilePreview].self, forKey: .previews),
            projectType: try values.decodeIfPresent(String.self, forKey: .projectType),
            createdAt: try values.decodeIfPresent(Date.self, forKey: .createdAt)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(path, forKey: .path)
        try values.encodeIfPresent(oneLiner, forKey: .oneLiner)
        try values.encodeIfPresent(summary, forKey: .summary)
        try values.encodeIfPresent(domain, forKey: .domain)
        try values.encodeIfPresent(status, forKey: .status)
        try values.encodeIfPresent(phase, forKey: .phase)
        try values.encodeIfPresent(githubURL, forKey: .githubURL)
        try values.encodeIfPresent(websiteURL, forKey: .websiteURL)
        try values.encode(resourceCount, forKey: .resourceCount)
        try values.encode(collectionCount, forKey: .collectionCount)
        try values.encode(mediaCount, forKey: .mediaCount)
        try values.encode(taskCount, forKey: .taskCount)
        try values.encode(featureCount, forKey: .featureCount)
        try values.encode(milestoneCount, forKey: .milestoneCount)
        try values.encode(workLogCount, forKey: .workLogCount)
        try values.encodeIfPresent(assessment, forKey: .assessment)
        try values.encodeIfPresent(projectID, forKey: .projectID); try values.encodeIfPresent(serviceID, forKey: .serviceID)
        try values.encodeIfPresent(manualScore, forKey: .manualScore); try values.encodeIfPresent(ratingCoverage, forKey: .ratingCoverage)
        try values.encodeIfPresent(lastWorked, forKey: .lastWorked)
        try values.encodeIfPresent(ratings, forKey: .ratings)
        try values.encodeIfPresent(scoringPreferences, forKey: .scoringPreferences)
        try values.encodeIfPresent(needsSetup, forKey: .needsSetup)
        try values.encodeIfPresent(previews, forKey: .previews)
        try values.encodeIfPresent(projectType, forKey: .projectType)
        try values.encodeIfPresent(createdAt, forKey: .createdAt)
    }
}

public struct MobileWorkspaceEntry: Identifiable, Hashable, Sendable, Codable {
    /// Canonical, workspace-relative path (for example `Ideas/Reading list`).
    public let path: String
    public let parentPath: String?
    public let name: String
    public let isDirectory: Bool
    public let revision: Int64
    public var tagIDs: Set<String>
    public let modifiedAt: Date?
    public let projectDetails: MobileProjectDetails?
    public var overview: OverviewDigest?

    public var id: String { path }

    public init(path: String, parentPath: String?, name: String, isDirectory: Bool,
                revision: Int64, tagIDs: Set<String> = [], modifiedAt: Date? = nil,
                projectDetails: MobileProjectDetails? = nil, overview: OverviewDigest? = nil) {
        self.path = MobileWorkspacePath.normalizedRelative(path) ?? path
        self.parentPath = parentPath.flatMap(MobileWorkspacePath.normalizedRelative)
        self.name = name
        self.isDirectory = isDirectory
        self.revision = revision
        self.tagIDs = tagIDs
        self.modifiedAt = modifiedAt
        self.projectDetails = projectDetails
        self.overview = overview
    }
}

public struct MobileWorkItem: Identifiable, Hashable, Sendable, Codable {
    public let id: String
    public let path: String
    public var title: String
    public var kind: WorkItemKind
    public var status: WorkItemStatus
    public var stage: WorkItemStage
    public var priority: WorkItemPriority
    public var projectPath: String?
    public var dueDate: Date?
    public var createdAt: Date?
    public var modifiedAt: Date?
    public var completedAt: Date?
    public var importedNotionPageID: String?
    public let revision: Int64
    public var tagIDs: Set<String>
    /// Nil for older publishers or a note too large for the phone editor.
    public var body: String?

    public var actionMetadata: WorkItemActionMetadata?
    public var dependencyIDs: [String]?
    /// The features and milestones this belongs to. `nil` from an older publisher or
    /// phone, which means "not said" — never "none".
    public var featureIDs: [String]?
    public var milestoneIDs: [String]?

    public init(id: String, path: String, title: String, kind: WorkItemKind,
                status: WorkItemStatus, stage: WorkItemStage, priority: WorkItemPriority,
                projectPath: String? = nil, dueDate: Date? = nil, revision: Int64,
                tagIDs: Set<String> = [], body: String? = nil,
                actionMetadata: WorkItemActionMetadata? = nil, dependencyIDs: [String]? = nil,
                featureIDs: [String]? = nil, milestoneIDs: [String]? = nil,
                createdAt: Date? = nil, modifiedAt: Date? = nil, completedAt: Date? = nil, importedNotionPageID: String? = nil) {
        self.importedNotionPageID = importedNotionPageID
        self.createdAt = createdAt; self.modifiedAt = modifiedAt; self.completedAt = completedAt
        self.featureIDs = featureIDs
        self.milestoneIDs = milestoneIDs
        self.actionMetadata = actionMetadata
        self.dependencyIDs = dependencyIDs
        self.body = body
        self.id = id
        self.path = MobileWorkspacePath.normalizedRelative(path) ?? path
        self.title = title
        self.kind = kind
        self.status = status
        self.stage = stage
        self.priority = priority
        self.projectPath = projectPath.flatMap(MobileWorkspacePath.normalizedRelative)
        self.dueDate = dueDate
        self.revision = revision
        self.tagIDs = tagIDs
    }
}

public struct MobileIdea: Identifiable, Hashable, Sendable, Codable {
    public let path: String
    public var title: String
    public let revision: Int64
    public var tagIDs: Set<String>
    public let modifiedAt: Date?
    public var description: String?
    public let attachments: [MobileIdeaAttachment]?
    public let serviceID: String?
    public var planning: IdeaPlanning?
    public var scoringPreferences: ProjectScoringPreferences?
    public var previews: [MobileFilePreview]?
    public var createdAt: Date?
    public var id: String { path }

    public init(path: String, title: String, revision: Int64, tagIDs: Set<String> = [], modifiedAt: Date? = nil,
                description: String? = nil, attachments: [MobileIdeaAttachment]? = nil, serviceID: String? = nil, planning: IdeaPlanning? = nil, scoringPreferences: ProjectScoringPreferences? = nil, previews: [MobileFilePreview]? = nil, createdAt: Date? = nil) {
        self.createdAt = createdAt
        self.planning = planning; self.scoringPreferences = scoringPreferences; self.previews = previews
        self.description = description
        self.attachments = attachments
        self.serviceID = serviceID
        self.path = MobileWorkspacePath.normalizedRelative(path) ?? path
        self.title = title
        self.revision = revision
        self.tagIDs = tagIDs
        self.modifiedAt = modifiedAt
    }
}

public struct MobileWorkspaceSnapshot: Sendable, Codable {
    public var tags: [Tag]
    public var entries: [MobileWorkspaceEntry]
    public var workItems: [MobileWorkItem]
    public var ideas: [MobileIdea]
    public var fetchedAt: Date
    /// The Mac's bounded Overview digest. It travels as one index record at
    /// `OverviewDigest.path` and is lifted out of `entries` here, so Browse never
    /// lists it as a file.
    public var overview: OverviewDigest?

    public init(tags: [Tag] = [], entries: [MobileWorkspaceEntry] = [],
                workItems: [MobileWorkItem] = [], ideas: [MobileIdea] = [], fetchedAt: Date = Date(),
                overview: OverviewDigest? = nil) {
        self.tags = tags
        self.entries = entries.filter { $0.path != OverviewDigest.path }
        self.workItems = workItems
        self.ideas = ideas
        self.fetchedAt = fetchedAt
        self.overview = overview ?? entries.first { $0.path == OverviewDigest.path }?.overview
    }

    /// Applies the phone's optimistic tag state to every projection that represents
    /// the same filesystem path. Browse, Work, and Ideas are separate compact views of
    /// the Mac-owned workspace, so changing only the entry list makes the other tabs
    /// contradict the tap until the next CloudKit refresh.
    public mutating func setTag(_ tagID: String, onPath path: String, isPresent: Bool) {
        guard let normalizedPath = MobileWorkspacePath.normalizedRelative(path) else { return }
        func updating(_ tagIDs: inout Set<String>) {
            if isPresent { tagIDs.insert(tagID) }
            else { tagIDs.remove(tagID) }
        }
        for index in entries.indices where entries[index].path == normalizedPath {
            updating(&entries[index].tagIDs)
        }
        for index in workItems.indices where workItems[index].path == normalizedPath {
            updating(&workItems[index].tagIDs)
        }
        for index in ideas.indices where ideas[index].path == normalizedPath {
            updating(&ideas[index].tagIDs)
        }
    }
}

/// A queued operation from the phone.  Each tag operation has an immutable mutation
/// ID and the revision the phone saw.  The Mac serializes per-path changes, rejects or
/// rebases stale revisions, then republishes the canonical entry revision.
public struct MobileWorkspaceIntent: Identifiable, Hashable, Sendable, Codable {
    public enum Kind: String, Codable, Sendable {
        case tagAssignment
        case captureClassification
        case tagCreation
        case planningEdit
    }

    public let id: UUID
    public let kind: Kind
    public let targetPath: String?
    public let baseRevision: Int64?
    public let tagIDs: Set<String>
    public let addTagIDs: Set<String>
    public let removeTagIDs: Set<String>
    public let captureName: String?
    public let captureKind: CaptureClassificationKind?
    /// A Mac-published, workspace-relative destination selected on the phone. The
    /// receiver accepts only a top-level Workspace folder; it is never an iOS path.
    public let captureDestinationPath: String?
    /// Exact child names in an iPhone-created capture folder. The Mac waits for each
    /// before it files the folder, preventing iCloud's incremental directory upload
    /// from splitting a photo or imported file away from its note.
    public let captureExpectedChildren: Set<String>
    /// Present only for a tag-creation command. Keeping the exact ID generated on
    /// the phone means the following capture-classification command can refer to it
    /// without a fragile name-to-ID translation.
    public let createdTag: Tag?
    public let createdAt: Date
    public let planningEdit: MobilePlanningEdit?
    /// Where a capture filed as work belongs: project, features, milestones. Optional
    /// throughout; absent from older phones.
    public let captureLinks: WorkItemLinks?

    public static func planning(_ edit: MobilePlanningEdit) -> Self {
        Self(id: edit.id, kind: .planningEdit, targetPath: nil, baseRevision: nil, tagIDs: [],
             addTagIDs: [], removeTagIDs: [], captureName: nil, captureKind: nil, planningEdit: edit)
    }

    public static func tagChange(path: String, baseRevision: Int64, adding: Set<String>, removing: Set<String>) -> Self {
        Self(kind: .tagAssignment, targetPath: MobileWorkspacePath.normalizedRelative(path),
             baseRevision: baseRevision, tagIDs: [], addTagIDs: adding, removeTagIDs: removing,
             captureName: nil, captureKind: nil)
    }

    public static func captureClassification(name: String, kind: CaptureClassificationKind?, tagIDs: Set<String>,
                                             destinationPath: String? = nil,
                                             expectedChildren: Set<String> = [],
                                             links: WorkItemLinks? = nil) -> Self {
        Self(kind: .captureClassification, targetPath: nil, baseRevision: nil, tagIDs: tagIDs,
             addTagIDs: [], removeTagIDs: [], captureName: name, captureKind: kind,
             captureDestinationPath: destinationPath, captureExpectedChildren: expectedChildren,
             captureLinks: links)
    }

    public static func tagCreation(_ tag: Tag) -> Self {
        Self(kind: .tagCreation, targetPath: nil, baseRevision: nil, tagIDs: [],
             addTagIDs: [], removeTagIDs: [], captureName: nil, captureKind: nil,
             createdTag: tag)
    }

    public init(id: UUID = UUID(), kind: Kind, targetPath: String?, baseRevision: Int64?,
                tagIDs: Set<String>, addTagIDs: Set<String>, removeTagIDs: Set<String>,
                captureName: String?, captureKind: CaptureClassificationKind?,
                captureDestinationPath: String? = nil, createdTag: Tag? = nil,
                captureExpectedChildren: Set<String> = [],
                createdAt: Date = Date(), planningEdit: MobilePlanningEdit? = nil,
                captureLinks: WorkItemLinks? = nil) {
        self.planningEdit = planningEdit
        self.captureLinks = captureLinks?.isEmpty == false ? captureLinks : nil
        self.id = id
        self.kind = kind
        self.targetPath = targetPath
        self.baseRevision = baseRevision
        self.tagIDs = tagIDs
        self.addTagIDs = addTagIDs
        self.removeTagIDs = removeTagIDs
        self.captureName = captureName
        self.captureKind = captureKind
        self.captureDestinationPath = captureDestinationPath.flatMap(MobileWorkspacePath.normalizedRelative)
        self.createdTag = createdTag
        self.captureExpectedChildren = Set(captureExpectedChildren.filter {
            $0.isEmpty == false && $0.contains("/") == false
        })
        self.createdAt = createdAt
    }
}

/// How long the Mac keeps retrying an inbound intent it cannot yet apply.
///
/// Some intents are legitimately not applicable the moment they arrive — iCloud can
/// deliver a classification before the capture it names. But some never become
/// applicable: the capture was deleted on the phone, or filed by hand on the Mac. An
/// intent with no expiry means the command channel accumulates records that every sync
/// pass re-reads and re-attempts forever, so unapplied intents are acknowledged once
/// they are this old, and the Mac says so rather than dropping them silently.
public enum MobileIntentLifetime {
    public static let retryWindow: TimeInterval = 14 * 24 * 60 * 60

    public static func hasExpired(_ intent: MobileWorkspaceIntent, now: Date = Date()) -> Bool {
        now.timeIntervalSince(intent.createdAt) > retryWindow
    }
}

public enum MobileCloudError: LocalizedError, Sendable, Equatable {
    /// Someone asked this launch not to use CloudKit.  Not a failure: no container is
    /// constructed and no request is made.
    case turnedOff
    /// No iCloud account, or one this app may not use.  An ordinary state — the phone
    /// still captures, and the Mac-published index simply is not there to read.
    case noAccount
    /// Something went wrong that trying again could fix.
    case unavailable(String)
    /// CloudKit accepted the app and account, but its container/schema/permissions need
    /// attention.  This is deliberately retryable: dropping a person's queued change
    /// because a Dashboard index or provisioning profile is temporarily wrong loses
    /// information exactly when the diagnostic is most useful.
    case configuration(String)
    /// CloudKit refused this record and will refuse it again.  Queued work that fails
    /// this way is dropped rather than left blocking a queue that can never drain.
    case rejected(String)
    case malformedRecord(String)

    public var errorDescription: String? {
        switch self {
        case .turnedOff: return "Syncing is switched off for this launch."
        case .noAccount: return "No iCloud account is available. Better Workspace works without one; the Mac-published index needs it."
        case .unavailable(let message): return message
        case .configuration(let message): return "CloudKit needs configuration: \(message)"
        case .rejected(let message): return "CloudKit refused the request: \(message)"
        case .malformedRecord(let type): return "The CloudKit \(type) record is malformed."
        }
    }

    /// Whether the same request is worth making again later.
    public var isRetryable: Bool {
        switch self {
        case .turnedOff, .noAccount, .unavailable, .configuration: return true
        case .rejected, .malformedRecord: return false
        }
    }
}

/// The phone-side CloudKit client.  It has no filesystem APIs and can therefore never
/// mistake a synced cache for workspace ownership.
public actor MobileCloudStore {

    /// Read when a request is made, not when the store is built, so that turning
    /// CloudKit off keeps a container from ever being constructed.
    public static let disabledDefaultsKey = "mobileCloudDisabled"

    private let containerIdentifier: String
    private let defaults: UserDefaults
    /// Built on first use and never during a model's initialisation.
    ///
    /// `CKContainer(identifier:)` is not a failable call: when the container is not in
    /// the app's entitlements it takes the process down. Constructing one eagerly meant
    /// every launch of an unentitled build trapped before the first frame — which is
    /// also why `-mobileCloudDisabled` has to be checked here rather than only in the
    /// callers, so "do not use CloudKit" really means "do not touch CloudKit".
    private var resolved: CKDatabase?

    public init(containerIdentifier: String = MobileCloudSchema.containerIdentifier,
                defaults: UserDefaults = .standard) {
        self.containerIdentifier = containerIdentifier
        self.defaults = defaults
    }

    /// True when a request would be attempted. Cheap, and makes no CloudKit call.
    public var isEnabled: Bool { defaults.bool(forKey: Self.disabledDefaultsKey) == false }

    /// Resolves the private database, once, refusing before anything CloudKit-shaped is
    /// constructed. Nothing is cached until the account has answered, so signing in
    /// later needs no relaunch.
    private func database() async throws -> CKDatabase {
        if let resolved { return resolved }
        guard isEnabled else { throw MobileCloudError.turnedOff }
        let container = CKContainer(identifier: containerIdentifier)
        switch try? await container.accountStatus() {
        case .noAccount, .restricted:
            // Asked and answered: there is no account to read. Reporting this as its own
            // state keeps the UI from describing a signed-out phone as a sync error.
            throw MobileCloudError.noAccount
        default:
            // `.available`, or the question could not be answered. Let the request itself
            // be the thing that fails, with CloudKit's own reason.
            break
        }
        resolved = container.privateCloudDatabase
        return container.privateCloudDatabase
    }

    public func fetchSnapshot() async throws -> MobileWorkspaceSnapshot {
        let database = try await database()
        async let tags = records(of: MobileCloudSchema.tagRecordType, in: database).map(Self.tag)
        async let entries = records(of: MobileCloudSchema.indexRecordType, in: database).map(Self.entry)
        async let workItems = records(of: MobileCloudSchema.workItemRecordType, in: database).map(Self.workItem)
        async let ideas = records(of: MobileCloudSchema.ideaRecordType, in: database).map(Self.idea)
        do {
            return try await MobileWorkspaceSnapshot(
                tags: tags.compactMap { $0 }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending },
                entries: entries.compactMap { $0 }.sorted { $0.path < $1.path },
                workItems: workItems.compactMap { $0 },
                ideas: ideas.compactMap { $0 }
            )
        } catch {
            throw Self.cloudError(error)
        }
    }

    /// Sends one queued intent.
    ///
    /// Idempotent on purpose: the record name *is* the mutation id, so a retry after a
    /// lost acknowledgement finds the record already there. CloudKit reports that as a
    /// conflict, which here means the intent landed and the outbox may drop it.
    public func submit(_ intent: MobileWorkspaceIntent) async throws {
        let database = try await database()
        let type: String
        switch intent.kind {
        case .tagAssignment: type = MobileCloudSchema.tagAssignmentChangeRecordType
        case .captureClassification: type = MobileCloudSchema.captureIntentRecordType
        case .tagCreation, .planningEdit: type = MobileCloudSchema.captureIntentRecordType
        }
        let record = CKRecord(recordType: type, recordID: CKRecord.ID(recordName: intent.id.uuidString))
        record["mutationID"] = intent.id.uuidString
        record["createdAt"] = intent.createdAt
        if let path = intent.targetPath { record["path"] = path }
        if let revision = intent.baseRevision { record["baseRevision"] = NSNumber(value: revision) }
        // Empty lists are left out rather than written: CloudKit cannot infer a list
        // field's element type from one, and rejects the record. A pure tag *removal*
        // has an empty `addTagIDs`, so writing it would have made removals impossible
        // to send on a container that had not yet seen an addition.
        if intent.kind == .tagAssignment {
            MobileCloudPublisher.setList(Array(intent.addTagIDs).sorted(), forKey: "addTagIDs", on: record)
            MobileCloudPublisher.setList(Array(intent.removeTagIDs).sorted(), forKey: "removeTagIDs", on: record)
        } else if intent.kind == .captureClassification {
            record["captureName"] = intent.captureName
            record["captureKind"] = intent.captureKind?.rawValue
            record["captureDestinationPath"] = intent.captureDestinationPath
            record["captureLinks"] = intent.captureLinks?.encoded
            MobileCloudPublisher.setList(Array(intent.tagIDs).sorted(), forKey: "tagIDs", on: record)
            MobileCloudPublisher.setList(Array(intent.captureExpectedChildren).sorted(), forKey: "captureExpectedChildren", on: record)
        } else if let edit = intent.planningEdit {
            record["planningEdit"] = String(data: try JSONEncoder().encode(edit), encoding: .utf8)
        } else if let tag = intent.createdTag {
            record["tagID"] = tag.id
            record["tagName"] = tag.name
            record["tagColorIndex"] = NSNumber(value: tag.colorIndex)
            record["tagCreatedAt"] = tag.createdAt
        }
        do {
            _ = try await database.save(record)
        } catch let error as CKError where error.code == .serverRecordChanged {
            return
        } catch {
            throw Self.cloudError(error)
        }
    }

    /// Direct record lookup: downloading originals never expands the index query.
    public func receiveDownload(id: UUID, path: String, cache: MobileDownloadCache) async throws -> MobileOfflineCopy? {
        if let installed = await cache.load(id), installed.path == path { return installed }
        let database = try await database()
        let record: CKRecord
        do { record = try await database.record(for: CKRecord.ID(recordName: "download-" + id.uuidString)) }
        catch let error as CKError where error.code == .unknownItem { return nil }
        guard record.recordType == MobileCloudSchema.downloadRecordType, record["path"] as? String == path,
              let asset = record["bundle"] as? CKAsset, let url = asset.fileURL else {
            throw MobilePlanningFiles.Error.invalid("The Mac download is incomplete. Request an update.")
        }
        defer { withExtendedLifetime(record) {} }
        return try await cache.install(asset: url, id: id, expectedPath: path)
    }

    public func removeDownload(_ id: UUID) async throws {
        let database = try await database()
        do { _ = try await database.deleteRecord(withID: CKRecord.ID(recordName: "download-" + id.uuidString)) }
        catch let error as CKError where error.code == .unknownItem { return }
    }

    public func planningReceipts(for ids: [UUID]) async throws -> [MobilePlanningReceipt] {
        guard !ids.isEmpty else { return [] }
        let database = try await database()
        let values = try await database.records(for: ids.prefix(100).map { CKRecord.ID(recordName: $0.uuidString) })
        return values.compactMap { recordID, result in
            guard let record = try? result.get(), let id = UUID(uuidString: recordID.recordName),
                  let status = record["planningStatus"] as? String else { return nil }
            let revision = (record["planningWorkRevision"] as? String).flatMap(Double.init).map(Date.init(timeIntervalSinceReferenceDate:))
            return MobilePlanningReceipt(id: id, applied: status == "applied", message: record["planningError"] as? String, workModifiedAt: revision, appliedAt: record.modificationDate)
        }
    }

    public func removePlanningReceipts(_ ids: Set<UUID>) async throws -> Set<UUID> {
        guard !ids.isEmpty else { return [] }
        let database = try await database()
        let results = try await database.modifyRecords(saving: [], deleting: ids.map { CKRecord.ID(recordName: $0.uuidString) }, atomically: false)
        return Set(results.deleteResults.compactMap { recordID, result in
            switch result {
            case .success: return UUID(uuidString: recordID.recordName)
            case .failure(let error as CKError) where error.code == .unknownItem: return UUID(uuidString: recordID.recordName)
            default: return nil
            }
        })
    }

    /// The maximum number of records the phone will pull for one record type.
    ///
    /// A CloudKit query answers one page at a time and hands back a cursor. Ignoring
    /// that cursor silently truncated every snapshot at the first page, which made the
    /// widget's "N open" counts wrong rather than merely incomplete. Following it is
    /// also not unbounded: the Mac must publish a curated index, not a mirror of a
    /// workspace that is over a million files here, so this is a backstop that keeps a
    /// mistake on the publishing side from hanging the phone.
    static let recordFetchLimit = 4_000

    private func records(of type: String, in database: CKDatabase) async throws -> [CKRecord] {
        let query = CKQuery(recordType: type, predicate: NSPredicate(value: true))
        var page: (matchResults: [(CKRecord.ID, Result<CKRecord, Error>)], queryCursor: CKQueryOperation.Cursor?)
        do {
            page = try await database.records(matching: query, desiredKeys: nil)
        } catch where MobileCloudSchema.isMissingRecordType(error) {
            return []
        }
        var all = page.matchResults.compactMap { _, value in try? value.get() }
        while let cursor = page.queryCursor, all.count < Self.recordFetchLimit {
            page = try await database.records(continuingMatchFrom: cursor, desiredKeys: nil)
            all += page.matchResults.compactMap { _, value in try? value.get() }
        }
        return all
    }

    private static func tag(_ record: CKRecord) -> Tag? {
        guard let id = record["id"] as? String,
              let name = record["name"] as? String
        else { return nil }
        return Tag(id: id, name: name, colorIndex: (record["colorIndex"] as? NSNumber)?.intValue ?? Tag.colorIndex(for: name),
                   createdAt: (record["createdAt"] as? Date) ?? Date.distantPast)
    }

    private static func entry(_ record: CKRecord) -> MobileWorkspaceEntry? {
        guard let path = record["path"] as? String,
              let name = record["name"] as? String,
              let isDirectory = record["isDirectory"] as? NSNumber,
              let revision = record["revision"] as? NSNumber
        else { return nil }
        return MobileWorkspaceEntry(path: path, parentPath: record["parentPath"] as? String, name: name,
                                    isDirectory: isDirectory.boolValue, revision: revision.int64Value,
                                    tagIDs: Set(record["tagIDs"] as? [String] ?? []), modifiedAt: record["modifiedAt"] as? Date,
                                    projectDetails: projectDetails(from: record, path: path), overview: path == OverviewDigest.path ? OverviewDigest.decode(record["overviewJSON"] as? String) : nil)
    }

    private static func projectDetails(from record: CKRecord, path: String) -> MobileProjectDetails? {
        if let details = MobileProjectEnvelope.decode(record["overviewJSON"] as? String), details.path == path { return details }
        let hasContent = ["projectOneLiner", "projectSummary", "projectDomain", "projectStatus", "projectPhase",
                          "githubURL", "websiteURL"].contains { record[$0] != nil }
            || record["resourceCount"] != nil || record["collectionCount"] != nil || record["mediaCount"] != nil
            || record["taskCount"] != nil || record["featureCount"] != nil || record["milestoneCount"] != nil || record["workLogCount"] != nil
        guard hasContent else { return nil }
        return MobileProjectDetails(
            path: path, oneLiner: record["projectOneLiner"] as? String,
            summary: record["projectSummary"] as? String, domain: record["projectDomain"] as? String,
            status: record["projectStatus"] as? String,
            phase: record["projectPhase"] as? String, githubURL: record["githubURL"] as? String,
            websiteURL: record["websiteURL"] as? String,
            resourceCount: (record["resourceCount"] as? NSNumber)?.intValue ?? 0,
            collectionCount: (record["collectionCount"] as? NSNumber)?.intValue ?? 0,
            mediaCount: (record["mediaCount"] as? NSNumber)?.intValue ?? 0,
            taskCount: (record["taskCount"] as? NSNumber)?.intValue ?? 0,
            featureCount: (record["featureCount"] as? NSNumber)?.intValue ?? 0,
            milestoneCount: (record["milestoneCount"] as? NSNumber)?.intValue ?? 0,
            workLogCount: (record["workLogCount"] as? NSNumber)?.intValue ?? 0
        )
    }

    private static func workItem(_ record: CKRecord) -> MobileWorkItem? {
        guard let id = record["id"] as? String, let path = record["path"] as? String,
              let title = record["title"] as? String,
              let kind = WorkItemKind(rawValue: record["kind"] as? String ?? ""),
              let status = WorkItemStatus(rawValue: record["status"] as? String ?? ""),
              let stage = WorkItemStage(rawValue: record["stage"] as? String ?? ""),
              let priority = WorkItemPriority(rawValue: record["priority"] as? String ?? ""),
              let revision = record["revision"] as? NSNumber
        else { return nil }
        let projection = MobileActionProjection.decode(record["body"] as? String)
        return MobileWorkItem(id: id, path: path, title: title, kind: kind, status: status, stage: stage,
                              priority: priority, projectPath: record["projectPath"] as? String,
                              dueDate: record["dueDate"] as? Date, revision: revision.int64Value,
                              tagIDs: Set(record["tagIDs"] as? [String] ?? []), body: projection.body,
                              actionMetadata: projection.metadata, dependencyIDs: projection.dependencies,
                              featureIDs: projection.features, milestoneIDs: projection.milestones,
                              createdAt: projection.createdAt, modifiedAt: projection.modifiedAt, completedAt: projection.completedAt, importedNotionPageID: projection.notionPageID)
    }

    private static func idea(_ record: CKRecord) -> MobileIdea? {
        guard let path = record["path"] as? String, let title = record["title"] as? String,
              let revision = record["revision"] as? NSNumber
        else { return nil }
        let envelope = MobileIdeaEnvelope.decode(record["attachmentsJSON"] as? String)
        return MobileIdea(path: path, title: title, revision: revision.int64Value,
                          tagIDs: Set(record["tagIDs"] as? [String] ?? []), modifiedAt: record["modifiedAt"] as? Date,
                          description: record["description"] as? String,
                          attachments: envelope?.attachments,
                          serviceID: record["serviceID"] as? String, planning: envelope?.planning, scoringPreferences: envelope?.scoringPreferences, previews: envelope?.previews, createdAt: envelope?.createdAt)
    }

    /// These responses can mean an invalid field *or* a missing dashboard index,
    /// undeployed development schema, entitlement, or private-database permission.
    /// A phone cannot distinguish those safely, so retain the immutable intent and
    /// make the condition visible rather than silently throwing away a classification.
    private static let configurationCodes: Set<CKError.Code> = [
        .invalidArguments, .constraintViolation, .serverRejectedRequest,
        .badContainer, .badDatabase, .incompatibleVersion, .permissionFailure,
        .managedAccountRestricted, .referenceViolation,
    ]

    private static func cloudError(_ error: Error) -> MobileCloudError {
        guard let cloudError = error as? CKError else {
            return .unavailable((error as NSError).localizedDescription)
        }
        switch cloudError.code {
        case .notAuthenticated, .accountTemporarilyUnavailable:
            return .noAccount
        case let code where configurationCodes.contains(code):
            return .configuration(cloudError.localizedDescription)
        default:
            return .unavailable(cloudError.localizedDescription)
        }
    }
}

/// A durable local outbox.  It only holds user intents until CloudKit is reachable;
/// it never stores a copy of the Workspace index or a SQLite/WAL database.
public final class MobileIntentOutbox: @unchecked Sendable {

    /// How many intents are kept at most.
    ///
    /// The queue drains in seconds when CloudKit is reachable, so reaching this means
    /// something is wrong rather than that someone has been busy. Bounded because the
    /// alternative is an ever-growing blob in preferences that is read and rewritten on
    /// every tag tap, and because a tag change queued against a revision the Mac moved
    /// past long ago cannot be applied anyway.
    public static let capacity = 500

    private let defaults: UserDefaults
    private let key: String
    private let ledger: WidgetCommandStore?
    private let stream: String
    private let lock = NSLock()

    public init(defaults: UserDefaults = .standard, key: String = "mobileWorkspaceIntentOutbox", ledger: WidgetCommandStore? = nil, stream: String = "workspace") {
        self.defaults = defaults
        self.key = key
        self.ledger = ledger; self.stream = stream
    }

    public func queued() -> [MobileWorkspaceIntent] {
        if let ledger { return ((try? ledger.records(stream: stream)) ?? []).filter { $0.state == .queued }.map(\.intent) }
        lock.lock(); defer { lock.unlock() }
        return loadLocked()
    }

    public var count: Int { queued().count }

    /// Queues an intent, dropping the oldest if the queue is already full.  Returns
    /// whether anything had to be dropped, so a caller can say so rather than losing a
    /// change silently.
    @discardableResult
    public func append(_ intent: MobileWorkspaceIntent) -> Bool {
        if let ledger { do { try ledger.append(intent, stream: stream); return false } catch { return true } }
        lock.lock(); defer { lock.unlock() }
        var values = loadLocked()
        guard values.contains(intent) == false else { return false }
        values.append(intent)
        let overflow = max(0, values.count - Self.capacity)
        if overflow > 0 { values.removeFirst(overflow) }
        saveLocked(values)
        return overflow > 0
    }

    public func remove(id: UUID) {
        if let ledger { try? ledger.delivered([id]); return }
        lock.lock(); defer { lock.unlock() }
        saveLocked(loadLocked().filter { $0.id != id })
    }

    /// Reads the queue and decides each intent's fate in one pass.
    ///
    /// The send itself cannot be done under the lock — it is a network call — so the
    /// caller does that and hands back what happened. Removing only the ids it names
    /// means an intent queued while the flush was in flight is never dropped unsent.
    public func remove(ids: Set<UUID>) {
        if let ledger { try? ledger.delivered(ids); return }
        guard ids.isEmpty == false else { return }
        lock.lock(); defer { lock.unlock() }
        saveLocked(loadLocked().filter { ids.contains($0.id) == false })
    }

    private func loadLocked() -> [MobileWorkspaceIntent] {
        guard let data = defaults.data(forKey: key),
              let values = try? JSONDecoder().decode([MobileWorkspaceIntent].self, from: data)
        else { return [] }
        return values
    }

    private func saveLocked(_ values: [MobileWorkspaceIntent]) {
        defaults.set(try? JSONEncoder().encode(values), forKey: key)
    }
}

/// Sends whatever is queued, and decides what to do with each result in one place so
/// the two iOS apps cannot disagree about it.
///
/// The rules that matter: a retryable failure stops the flush and leaves everything
/// still queued, because order is the only thing keeping two changes to one path
/// sensible; a refusal CloudKit will repeat drops that one intent, because the
/// alternative is a queue that can never drain past it.
public struct MobileOutboxFlush: Sendable {
    public var delivered = 0
    public var discarded = 0
    public var remaining = 0
    /// Set when the flush stopped early; the reason a caller can show.
    public var blockedBy: MobileCloudError?
    /// A truly invalid local intent may be discarded so it cannot permanently block
    /// later changes.  Preserve its reason for callers: an outbox must never lose a
    /// user action without giving the UI a chance to explain it.
    public var discardedBy: MobileCloudError?

    public var isComplete: Bool { blockedBy == nil }

    public init() {}
}

extension MobileIntentOutbox {
    public func flush(using send: (MobileWorkspaceIntent) async throws -> Void) async -> MobileOutboxFlush {
        var result = MobileOutboxFlush()
        if let ledger {
            do { guard try ledger.beginDelivery(stream: stream) else { result.remaining = count; return result } }
            catch { result.blockedBy = .unavailable(error.localizedDescription); return result }
        }
        defer { if let ledger { try? ledger.release("delivery:" + stream) } }
        var settled: Set<UUID> = []
        for intent in queued() {
            do {
                if let ledger, try !ledger.beginSending(intent.id) { continue }
                try await send(intent)
                settled.insert(intent.id)
                result.delivered += 1
            } catch let error as MobileCloudError where error.isRetryable == false {
                settled.insert(intent.id)
                result.discarded += 1
                result.discardedBy = error
                try? ledger?.receipt(id: intent.id, applied: false, message: error.localizedDescription)
            } catch {
                try? ledger?.retry(intent.id)
                result.blockedBy = (error as? MobileCloudError) ?? .unavailable(error.localizedDescription)
                break
            }
        }
        remove(ids: settled)
        result.remaining = count
        return result
    }
}
