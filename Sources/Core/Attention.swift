import Foundation

/// What deserves attention, and why.
///
/// Browsing happens in Projects. Deciding happens here, and a decision you cannot
/// explain is not much of a decision — so nothing in this file produces a ranking
/// number. Each rule contributes *reasons*, several rules can point at the same
/// project, and the reasons survive all the way to the screen. "Worked on yesterday ·
/// never rated" is worth more than "87/100".
///
/// The rules are a list, evaluated in order, and each one is small and independent.
/// Adding a signal later — remaining effort, a deadline, unfinished high-priority work,
/// completion velocity — means appending a rule and a reason, not rewriting a formula.
public enum Attention {

    // MARK: - Reasons

    /// Why one thing is being surfaced. A phrase, never a score.
    public enum Reason: Hashable, Sendable {
        case recentlyWorked(Date)
        case droppedAfterActivity(lastWorked: Date)
        case ratedHighlyButCold(score: Double, lastTouched: Date?)
        case newIdea
        case importantIdea(priority: Int, score: Double?)
        case newProject
        case activeButUnrated
        case recentlyChangedButUnrated
        case observedEffort(hours: Double)
        case waitingInInbox(count: Int)
        case ideasUndeveloped(count: Int)
        case emptyFolders(names: [String])

        public var phrase: String {
            switch self {
            case let .recentlyWorked(date):
                return "worked on \(Format.relativeDate(date).lowercased())"
            case let .droppedAfterActivity(date):
                return "picked up \(Format.relativeDate(date).lowercased()), then dropped"
            case let .ratedHighlyButCold(score, touched):
                let age = touched.map { " · untouched \(Format.relativeDate($0).lowercased())" } ?? ""
                return "you rated this \(Int(score.rounded()))\(age)"
            case .newIdea: return "idea needs priority, potential and scoring"
            case let .importantIdea(priority, score): return "your priority \(priority)/5" + (score.map { " · your score \(Int($0.rounded()))/100" } ?? "")
            case .newProject: return "new project created · add details and score"
            case .activeButUnrated:
                return "active but never rated"
            case .recentlyChangedButUnrated:
                // A filesystem timestamp can be caused by sync or another tool. It
                // is useful evidence, but it is not evidence that the person worked.
                return "recently changed but never rated"
            case let .observedEffort(hours):
                return hours < 1
                    ? "\(Int((hours * 60).rounded())) minutes of observed work"
                    : String(format: "%.1f hours of observed work", hours)
            case let .waitingInInbox(count):
                return count == 1 ? "1 capture waiting to be filed" : "\(count) captures waiting to be filed"
            case let .ideasUndeveloped(count):
                return "\(count) ideas are still just a title"
            case let .emptyFolders(names):
                return names.count == 1
                    ? "\(names[0]) is empty"
                    : "\(names.count) folders are empty — \(names.prefix(3).joined(separator: ", "))"
            }
        }
    }

    // MARK: - Items

    /// Where a surfaced thing lives, so clicking it lands as close as possible to the
    /// thing actually responsible for the recommendation.
    public enum Target: Hashable, Sendable {
        case project(path: String)
        case ingest
        case ideas
        case idea(path: String)
        case workspaceRoot
    }

    public struct Item: Identifiable, Hashable, Sendable {
        public let target: Target
        public let title: String
        public var reasons: [Reason]
        /// The index of the earliest rule that surfaced this. Lower sorts first.
        public var rank: Int

        public var id: Target { target }
        public var explanation: String { reasons.map(\.phrase).joined(separator: " · ") }
    }

    // MARK: - Input

    /// Everything Overview reasons over, gathered once.
    ///
    /// Deliberately plain values rather than live services: the rules stay pure, which
    /// is what makes them testable against contrived situations instead of only against
    /// whatever today's workspace happens to contain.
    public struct Input: Sendable {
        public struct Project: Sendable, Hashable {
            public let name: String
            public let path: String
            /// Workspace Watcher's stable project identity, when this project has
            /// been associated with one. Names are not unique and can change.
            public let watcherID: String?
            public let contentModifiedAt: Date?
            /// Manual project score, 0–100, when enough metrics have been answered.
            public let score: Double?
            public let ratedCount: Int
            public let lastSessionAt: Date?
            public let observedHours: Double?
            public var needsSetup: Bool

            public init(name: String, path: String, contentModifiedAt: Date?, score: Double?,
                        ratedCount: Int, lastSessionAt: Date?, observedHours: Double?,
                        watcherID: String? = nil, needsSetup: Bool = false) {
                self.needsSetup = needsSetup
                self.name = name
                self.path = path
                self.watcherID = watcherID
                self.contentModifiedAt = contentModifiedAt
                self.score = score
                self.ratedCount = ratedCount
                self.lastSessionAt = lastSessionAt
                self.observedHours = observedHours
            }
        }

        public struct Idea: Sendable, Hashable {
            public let name: String
            public let hasContent: Bool
            public var path: String?
            public var priority: Int
            public var score: Double?
            public var needsSetup: Bool
            public init(name: String, hasContent: Bool, path: String? = nil, priority: Int = 3, score: Double? = nil, needsSetup: Bool = false) {
                self.name = name
                self.hasContent = hasContent; self.path = path; self.priority = priority; self.score = score; self.needsSetup = needsSetup
            }
        }

        public var projects: [Project] = []
        public var ideas: [Idea] = []
        public var pendingIngestCount = 0
        public var emptyTopLevelFolders: [String] = []
        public var now = Date()

        public init() {}
    }

    // MARK: - Rules

    /// One independent signal. Named so it can be listed, explained, and eventually
    /// switched off without touching any of the others.
    public struct Rule: Sendable {
        public let id: String
        public let title: String
        public let evaluate: @Sendable (Input) -> [Item]

        public init(id: String, title: String, evaluate: @escaping @Sendable (Input) -> [Item]) {
            self.id = id
            self.title = title
            self.evaluate = evaluate
        }
    }

    private static let day: TimeInterval = 86_400

    /// Ordered by how much a person is likely to care. Rank comes from this order.
    public static let defaultRules: [Rule] = [
        Rule(id: "idea-planning", title: "Ideas to bring forward") { input in
            input.ideas.compactMap { idea in
                guard let path = idea.path, idea.needsSetup || idea.priority >= 4 || (idea.score ?? 0) >= 60 else { return nil }
                var reasons: [Reason] = []
                if idea.needsSetup { reasons.append(.newIdea) }
                if idea.priority >= 4 || idea.score != nil { reasons.append(.importantIdea(priority: idea.priority, score: idea.score)) }
                return Item(target: .idea(path: path), title: idea.name, reasons: reasons, rank: -5 - max(1, min(5, idea.priority)))
            }
        },
        Rule(id: "new-project", title: "New project created") { input in
            input.projects.filter(\.needsSetup).map {
                Item(target: .project(path: $0.path), title: $0.name, reasons: [.newProject], rank: -1)
            }
        },
        Rule(id: "dropped", title: "Picked up, then dropped") { input in
            input.projects.compactMap { project in
                guard let last = project.lastSessionAt else { return nil }
                let age = input.now.timeIntervalSince(last)
                guard age > 7 * day, age <= 30 * day else { return nil }
                var reasons: [Reason] = [.droppedAfterActivity(lastWorked: last)]
                if let hours = project.observedHours, hours > 0 { reasons.append(.observedEffort(hours: hours)) }
                return Item(target: .project(path: project.path), title: project.name,
                            reasons: reasons, rank: 0)
            }
        },

        Rule(id: "rated-cold", title: "Rated highly, gone cold") { input in
            input.projects.compactMap { project in
                guard let score = project.score, score >= 60 else { return nil }
                guard let touched = project.contentModifiedAt,
                      input.now.timeIntervalSince(touched) > 30 * day else { return nil }
                return Item(target: .project(path: project.path), title: project.name,
                            reasons: [.ratedHighlyButCold(score: score, lastTouched: touched)], rank: 1)
            }
        },

        Rule(id: "inbox", title: "Waiting in the inbox") { input in
            guard input.pendingIngestCount > 0 else { return [] }
            return [Item(target: .ingest, title: "Ingest inbox",
                         reasons: [.waitingInInbox(count: input.pendingIngestCount)], rank: 2)]
        },

        Rule(id: "active-unrated", title: "Active but never rated") { input in
            input.projects
                .filter { $0.ratedCount == 0 }
                .filter { project in
                    let sessionIsRecent = project.lastSessionAt.map {
                        input.now.timeIntervalSince($0) <= 7 * day
                    } ?? false
                    let contentChangedRecently = project.contentModifiedAt.map {
                        input.now.timeIntervalSince($0) <= 7 * day
                    } ?? false
                    return sessionIsRecent || contentChangedRecently
                }
                .sorted {
                    let left = $0.lastSessionAt ?? $0.contentModifiedAt ?? .distantPast
                    let right = $1.lastSessionAt ?? $1.contentModifiedAt ?? .distantPast
                    return left > right
                }
                .prefix(2)
                .map { project in
                    let hasRecentSession = project.lastSessionAt.map {
                        input.now.timeIntervalSince($0) <= 7 * day
                    } ?? false
                    var reasons: [Reason] = [hasRecentSession
                        ? .activeButUnrated
                        : .recentlyChangedButUnrated]
                    if let session = project.lastSessionAt, hasRecentSession {
                        reasons.append(.recentlyWorked(session))
                    }
                    return Item(target: .project(path: project.path), title: project.name,
                                reasons: reasons, rank: 3)
                }
        },

        Rule(id: "undeveloped-ideas", title: "Ideas never developed") { input in
            let bare = input.ideas.filter { $0.hasContent == false }
            guard bare.count >= 3 else { return [] }
            return [Item(target: .ideas, title: "Ideas",
                         reasons: [.ideasUndeveloped(count: bare.count)], rank: 4)]
        },

        Rule(id: "empty-folders", title: "Empty folders") { input in
            guard input.emptyTopLevelFolders.isEmpty == false else { return [] }
            return [Item(target: .workspaceRoot, title: "Workspace",
                         reasons: [.emptyFolders(names: input.emptyTopLevelFolders.sorted())], rank: 5)]
        },
    ]

    /// Evaluates the rules and merges what they found.
    ///
    /// Several rules can point at the same project. Rather than letting it appear
    /// twice, the reasons combine — which is the whole point: "picked up then dropped ·
    /// you rated this 72" says more than either line alone.
    ///
    /// - Parameter limit: Overview is meant to make a decision easier, so this stays
    ///   small. A longer list is a backlog, and there is already one of those.
    public static func evaluate(_ input: Input, rules: [Rule] = defaultRules, limit: Int = 4) -> [Item] {
        var merged: [Target: Item] = [:]
        for rule in rules {
            for item in rule.evaluate(input) {
                if var existing = merged[item.target] {
                    for reason in item.reasons where existing.reasons.contains(reason) == false {
                        existing.reasons.append(reason)
                    }
                    existing.rank = min(existing.rank, item.rank)
                    merged[item.target] = existing
                } else {
                    merged[item.target] = item
                }
            }
        }
        return merged.values
            .sorted { lhs, rhs in
                if lhs.rank != rhs.rank { return lhs.rank < rhs.rank }
                if lhs.reasons.count != rhs.reasons.count { return lhs.reasons.count > rhs.reasons.count }
                return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
            }
            .prefix(limit)
            .map { $0 }
    }

    // MARK: - Resume

    /// Where you actually left off.
    public struct ResumePoint: Sendable, Hashable {
        public enum Evidence: Sendable, Hashable {
            /// A real work session Workspace Watcher observed.
            case session
            /// No session data — the newest thing that changed on disk.
            case filesystem
        }

        public let projectName: String
        public let projectPath: String?
        public let at: Date
        public let activeHours: Double?
        public let files: [String]
        public let gitSubject: String?
        public let evidence: Evidence
    }

    /// A session has to represent real work to be worth resuming.
    ///
    /// Watcher records short bursts that are mostly a file provider or a dev server
    /// touching something; it marks those `discarded`, but even among completed ones a
    /// sixty-second blip is not where you left off. This matches Watcher's own floor.
    public static let meaningfulSessionSeconds: Double = 120

    /// The best available evidence of where meaningful work stopped.
    ///
    /// Prefers an observed session over a file timestamp, because "this folder changed"
    /// is not the same claim as "you were working here" — a backup, a sync or another
    /// tool writing metadata all move a timestamp.
    public static func resumePoint(
        sessions: [WorkSession], input: Input, now: Date = Date()
    ) -> ResumePoint? {
        let meaningful = sessions
            .filter { $0.activeSeconds >= meaningfulSessionSeconds }
            .sorted { $0.endedAt > $1.endedAt }

        if let session = meaningful.first {
            // A display name is neither unique nor permanent. Prefer the identity
            // Watcher recorded, then fall back to a name for older unassociated data.
            let path = input.projects.first { $0.watcherID == session.projectID }?.path
                ?? input.projects.first { $0.name == session.projectName }?.path
            return ResumePoint(
                projectName: session.projectName,
                projectPath: path,
                at: session.endedAt,
                activeHours: session.activeSeconds / 3600,
                files: session.interestingFiles,
                gitSubject: session.gitSubject,
                evidence: .session
            )
        }

        let newest = input.projects
            .filter { $0.contentModifiedAt != nil }
            .max { ($0.contentModifiedAt ?? .distantPast) < ($1.contentModifiedAt ?? .distantPast) }
        guard let newest, let at = newest.contentModifiedAt else { return nil }
        return ResumePoint(
            projectName: newest.name, projectPath: newest.path, at: at,
            activeHours: nil, files: [], gitSubject: nil, evidence: .filesystem
        )
    }
}
