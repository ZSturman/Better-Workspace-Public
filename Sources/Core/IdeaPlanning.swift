import Foundation

public enum IdeaPromotionKind: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
    case project, feature, milestone
    public var id: String { rawValue }
    public var title: String { rawValue.capitalized }
    public var area: String { self == .project ? "Projects" : self == .feature ? "Features" : "Milestones" }
    public var workKind: WorkItemKind? { self == .project ? nil : self == .feature ? .feature : .milestone }
}

/// Service-owned decisions. A potential project remains an idea until promotion.
public struct IdeaPlanning: Codable, Hashable, Sendable {
    public var priority: Int
    public var ratings: [String: Int]
    public var potential: IdeaPromotionKind?
    public var needsSetup: Bool
    public var project: IdeaProjectDetails?
    public var sourceProjectID: String?
    public init(priority: Int = 3, ratings: [String: Int] = [:], potential: IdeaPromotionKind? = nil, needsSetup: Bool = true, sourceProjectID: String? = nil, project: IdeaProjectDetails? = nil) {
        self.priority = priority; self.ratings = ratings; self.potential = potential; self.needsSetup = needsSetup; self.sourceProjectID = sourceProjectID; self.project = project
    }
    public func score(preferences: ProjectScoringPreferences = .init()) -> ProjectScore {
        ProjectScore(ratings: ratings, enabledMetricIDs: preferences.enabledMetricIDs,
            enabledGroups: MetricGroup.allGroups.filter { preferences.enabledGroupIDs.contains($0.id) }, groupWeights: preferences.groupWeights)
    }
    public func validate(original: IdeaPlanning? = nil) throws {
        if let project {
            guard project.oneLiner.count <= 2000, project.summary.count <= 12000,
                  [project.metadata.domain, project.metadata.projectType, project.metadata.phase].compactMap({ $0 }).allSatisfy({ $0.count <= 200 }),
                  (try? JSONEncoder().encode(project).count).map({ $0 <= 32000 }) == true else { throw MobilePlanningFiles.Error.invalid("Keep the one-liner under 2,000 characters and summary under 12,000 characters.") }
        }
        guard (1...5).contains(priority), ratings.count <= 64,
              ratings.allSatisfy({ (1...5).contains($0.value) && (MetricDefinition.find(id: $0.key) != nil || original?.ratings[$0.key] == $0.value) }),
              sourceProjectID == original?.sourceProjectID else { throw MobilePlanningFiles.Error.invalid("Choose a priority and ratings from 1 to 5. Refresh if the idea changed.") }
    }
}

public enum IdeaRanking {
    public static func comesFirst(_ lhs: MobileIdea, _ rhs: MobileIdea) -> Bool {
        let a = lhs.planning, b = rhs.planning
        if (a?.priority ?? 3) != (b?.priority ?? 3) { return (a?.priority ?? 3) > (b?.priority ?? 3) }
        let left = a?.score(preferences: lhs.scoringPreferences ?? .init()).projectScore
        let right = b?.score(preferences: rhs.scoringPreferences ?? .init()).projectScore
        if left != right { return (left ?? -.infinity) > (right ?? -.infinity) }
        if lhs.modifiedAt != rhs.modifiedAt { return (lhs.modifiedAt ?? .distantPast) > (rhs.modifiedAt ?? .distantPast) }
        return lhs.title == rhs.title ? lhs.id < rhs.id : lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
    }
}

/// The deployed attachmentsJSON field can carry a versioned idea envelope.
/// New phones also accept the old array. Plain description fields stay readable.
public struct MobileIdeaEnvelope: Codable {
    public var attachments: [MobileIdeaAttachment]
    public var planning: IdeaPlanning?
    public var scoringPreferences: ProjectScoringPreferences?
    public var previews: [MobileFilePreview]?
    public static func encode(_ idea: MobileIdea) -> String? {
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        return (try? encoder.encode(Self(attachments: idea.attachments ?? [], planning: idea.planning, scoringPreferences: idea.scoringPreferences, previews: idea.previews))).flatMap { String(data: $0, encoding: .utf8) }
    }
    public static func decode(_ text: String?) -> Self? {
        guard let data = text?.data(using: .utf8) else { return nil }
        if let value = try? JSONDecoder().decode(Self.self, from: data) { return value }
        return (try? JSONDecoder().decode([MobileIdeaAttachment].self, from: data)).map { Self(attachments: $0) }
    }
}

/// A receipt checkpoint is persisted before the opaque same-volume rename. Retrying
/// addresses the same folder; a pre-existing or replaced destination is never claimed.
public struct IdeaPromotionCheckpoint: Codable, Hashable, Sendable {
    public var source: String
    public var destination: String
    public var identity: String
    public var sourceModifiedAt: Date?
    public var projectBound: Bool?
    public var applied: Bool = false
}

public enum IdeaPromotionFiles {
    public static func move(_ original: MobileIdea, kind: IdeaPromotionKind, workspace: WorkspaceLocation, checkpoint: IdeaPromotionCheckpoint?) throws -> IdeaPromotionCheckpoint {
        let source = try MobilePlanningFiles.resolve(original.path, workspace: workspace)
        guard original.path.split(separator: "/").count == 2, original.path.hasPrefix("Ideas/") else { throw MobilePlanningFiles.Error.invalid("Choose a top-level idea folder.") }
        let destination = try MobilePlanningFiles.resolve(kind.area + "/" + source.lastPathComponent, workspace: workspace)
        let fm = FileManager.default
        if let checkpoint {
            guard checkpoint.source == source.canonicalPath, checkpoint.destination == destination.canonicalPath else { throw MobilePlanningFiles.Error.conflict }
            if !fm.fileExists(atPath: source.path), FileIdentityResolver.identity(of: destination)?.key == checkpoint.identity { return checkpoint }
        }
        guard (try? source.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true,
              !fm.fileExists(atPath: destination.path), let identity = FileIdentityResolver.identity(of: source)?.key,
              checkpoint?.identity == nil || checkpoint?.identity == identity,
              (try? source.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate == original.modifiedAt else { throw MobilePlanningFiles.Error.conflict }
        var sourceInfo = stat(), targetInfo = stat()
        guard lstat(source.path, &sourceInfo) == 0, lstat(destination.deletingLastPathComponent().path, &targetInfo) == 0,
              sourceInfo.st_dev == targetInfo.st_dev else { throw MobilePlanningFiles.Error.invalid("Promotion needs ordinary Ideas and destination folders on the same volume. Use Finder for a cross-volume move.") }
        return IdeaPromotionCheckpoint(source: source.canonicalPath, destination: destination.canonicalPath, identity: identity, sourceModifiedAt: original.modifiedAt)
    }

    /// No folder traversal, inspection of foreign metadata, overwrite or file copying.
    public static func apply(_ checkpoint: IdeaPromotionCheckpoint) throws {
        let source = URL(fileURLWithPath: checkpoint.source), destination = URL(fileURLWithPath: checkpoint.destination)
        let workspace = WorkspaceLocation(root: source.deletingLastPathComponent().deletingLastPathComponent())
        let resolvedSource = try MobilePlanningFiles.resolve("Ideas/" + source.lastPathComponent, workspace: workspace)
        let relativeTarget = destination.deletingLastPathComponent().lastPathComponent + "/" + destination.lastPathComponent
        let resolvedTarget = try MobilePlanningFiles.resolve(relativeTarget, workspace: workspace)
        guard resolvedSource.canonicalPath == checkpoint.source, resolvedTarget.canonicalPath == checkpoint.destination,
              ["Projects", "Features", "Milestones"].contains(destination.deletingLastPathComponent().lastPathComponent) else { throw MobilePlanningFiles.Error.conflict }
        if !FileManager.default.fileExists(atPath: source.path), FileIdentityResolver.identity(of: destination)?.key == checkpoint.identity { return }
        guard FileIdentityResolver.identity(of: source)?.key == checkpoint.identity else { throw MobilePlanningFiles.Error.conflict }
        if let expected = checkpoint.sourceModifiedAt {
            guard let actual = try source.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                  abs(actual.timeIntervalSince(expected)) < 0.001 else { throw MobilePlanningFiles.Error.conflict }
        }
        // RENAME_EXCL makes non-overwrite atomic even if a destination appears
        // between preview and rename. No traversal or cross-volume copy fallback.
        guard renameatx_np(AT_FDCWD, source.path, AT_FDCWD, destination.path, UInt32(RENAME_EXCL)) == 0 else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: source.path,
                NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(errno))])
        }
    }
}
