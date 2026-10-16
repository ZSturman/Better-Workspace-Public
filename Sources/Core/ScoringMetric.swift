import Foundation

/// Project scoring, ported from Better Projects.
///
/// Twenty-one metrics in seven weighted groups. Each is answered 1–5; what a given
/// number *means* is spelled out per metric by its anchors, which is what makes rating
/// a project quick rather than a guess.
///
/// Unlike the system this came from, none of it depends on Notion. A rating is local
/// data owned by this app (`ProjectStore`), and a Notion page id is an optional
/// attribute of a project rather than its identity. `notionPropertyName` is retained
/// only so an optional export can find the matching column in someone's existing
/// Notion database.

public enum MetricDirection: String, Codable, Sendable {
    case benefit
    case costOrRisk

    public var isCostOrRisk: Bool { self == .costOrRisk }

    public var shortLabel: String {
        switch self {
        case .benefit: return "Benefit"
        case .costOrRisk: return "Cost / Risk"
        }
    }

    public var explanation: String {
        switch self {
        case .benefit: return "Higher is generally better — value, readiness, or alignment."
        case .costOrRisk: return "Higher means more cost, risk or burden — not more desirable."
        }
    }
}

/// A human-readable anchor describing what one rating value means for one metric.
public struct RatingAnchor: Codable, Sendable, Hashable {
    public let rating: Int
    public let label: String
    public let description: String
    public init(rating: Int, label: String, description: String) {
        self.rating = rating
        self.label = label
        self.description = description
    }
}

public struct MetricDefinition: Identifiable, Hashable, Codable, Sendable {
    public let id: String
    public let displayName: String
    /// The column an optional Notion export would write to. Never required.
    public let notionPropertyName: String
    public let question: String
    public let direction: MetricDirection
    public let groupID: String
    public let anchors: [RatingAnchor]

    public init(id: String, displayName: String, notionPropertyName: String,
                question: String, direction: MetricDirection, groupID: String,
                anchors: [RatingAnchor]) {
        self.id = id
        self.displayName = displayName
        self.notionPropertyName = notionPropertyName
        self.question = question
        self.direction = direction
        self.groupID = groupID
        self.anchors = anchors
    }

    public func anchor(for rating: Int) -> RatingAnchor? { anchors.first { $0.rating == rating } }

    /// Direction-aware desirability, 0–100. A benefit metric rises with the rating; a
    /// cost metric falls, so that 100 always means "good for this project".
    public func desirability(for raw: Int) -> Double {
        switch direction {
        case .benefit: return Double(raw - 1) / 4.0 * 100.0
        case .costOrRisk: return Double(5 - raw) / 4.0 * 100.0
        }
    }

    public static func find(id: String) -> MetricDefinition? { all.first { $0.id == id } }

    // MARK: - The twenty-one metrics
    // 1. PERSONAL VALUE
    public static let qualityOfLife = MetricDefinition(
        id: "qualityOfLife", displayName: "Quality of Life", notionPropertyName: "Quality of Life",
        question: "How much would having the finished result improve your day-to-day life?",
        direction: .benefit, groupID: "personalValue",
        anchors: [
            RatingAnchor(rating: 1, label: "None", description: "No meaningful day-to-day improvement."),
            RatingAnchor(rating: 2, label: "Minor", description: "Occasionally useful or pleasant."),
            RatingAnchor(rating: 3, label: "Meaningful", description: "Noticeably improves some part of regular life."),
            RatingAnchor(rating: 4, label: "Major", description: "Significantly improves an important part of daily life."),
            RatingAnchor(rating: 5, label: "Transformative", description: "Fundamentally improves how you live or function."),
        ])

    public static let personalImportance = MetricDefinition(
        id: "personalImportance", displayName: "Personal Importance", notionPropertyName: "Personal Importance",
        question: "How personally meaningful is completing this, independent of practical benefits?",
        direction: .benefit, groupID: "personalValue",
        anchors: [
            RatingAnchor(rating: 1, label: "Indifferent", description: "Little personal attachment."),
            RatingAnchor(rating: 2, label: "Nice to do", description: "Some personal interest."),
            RatingAnchor(rating: 3, label: "Meaningful", description: "You would genuinely care about having done it."),
            RatingAnchor(rating: 4, label: "Important", description: "Strong personal significance."),
            RatingAnchor(rating: 5, label: "Deeply important", description: "Completing it matters to you regardless of external rewards."),
        ])

    public static let enjoyment = MetricDefinition(
        id: "enjoyment", displayName: "Enjoyment", notionPropertyName: "Enjoyment",
        question: "How much do you expect to enjoy actually working on it?",
        direction: .benefit, groupID: "personalValue",
        anchors: [
            RatingAnchor(rating: 1, label: "Dread", description: "Mostly unpleasant work."),
            RatingAnchor(rating: 2, label: "Chore", description: "More tedious than enjoyable."),
            RatingAnchor(rating: 3, label: "Neutral", description: "Mix of enjoyable and tedious work."),
            RatingAnchor(rating: 4, label: "Enjoyable", description: "You expect to like working on it."),
            RatingAnchor(rating: 5, label: "Compelling", description: "You would actively choose to work on it for its own sake."),
        ])

    // 2. FINANCIAL VALUE
    public static let incomePotential = MetricDefinition(
        id: "incomePotential", displayName: "Income Potential", notionPropertyName: "Income Potential",
        question: "How much realistic potential does this project have to directly generate income?",
        direction: .benefit, groupID: "financialValue",
        anchors: [
            RatingAnchor(rating: 1, label: "None", description: "No realistic income path."),
            RatingAnchor(rating: 2, label: "Small", description: "Could generate incidental income."),
            RatingAnchor(rating: 3, label: "Meaningful", description: "Plausible source of useful income."),
            RatingAnchor(rating: 4, label: "Significant", description: "Strong potential to become an important income source."),
            RatingAnchor(rating: 5, label: "Exceptional", description: "Could materially change your financial situation."),
        ])

    public static let costSavings = MetricDefinition(
        id: "costSavings", displayName: "Cost Savings", notionPropertyName: "Cost Savings",
        question: "How much money could the finished project realistically save?",
        direction: .benefit, groupID: "financialValue",
        anchors: [
            RatingAnchor(rating: 1, label: "None", description: "Essentially no financial savings."),
            RatingAnchor(rating: 2, label: "Minor", description: "Small savings."),
            RatingAnchor(rating: 3, label: "Meaningful", description: "Meaningful recurring or one-time savings."),
            RatingAnchor(rating: 4, label: "Substantial", description: "Substantial savings."),
            RatingAnchor(rating: 5, label: "Major", description: "Major long-term financial impact."),
        ])

    public static let financialCost = MetricDefinition(
        id: "financialCost", displayName: "Financial Cost", notionPropertyName: "Financial Cost",
        question: "How expensive is the project beyond your own time?",
        direction: .costOrRisk, groupID: "financialValue",
        anchors: [
            RatingAnchor(rating: 1, label: "Essentially free", description: "Requires little or no additional spending."),
            RatingAnchor(rating: 2, label: "Inexpensive", description: "Requires only minor spending."),
            RatingAnchor(rating: 3, label: "Moderate", description: "A noticeable but reasonable expense."),
            RatingAnchor(rating: 4, label: "Expensive", description: "Requires substantial spending or resources."),
            RatingAnchor(rating: 5, label: "Major commitment", description: "Cost itself is a significant consideration in whether to pursue the project."),
        ])

    // 3. PROFESSIONAL VALUE
    public static let careerRelevance = MetricDefinition(
        id: "careerRelevance", displayName: "Career Relevance", notionPropertyName: "Career Relevance",
        question: "How directly does this support the kind of professional work you want to be doing?",
        direction: .benefit, groupID: "professionalValue",
        anchors: [
            RatingAnchor(rating: 1, label: "Unrelated", description: "Little connection to your desired professional direction."),
            RatingAnchor(rating: 2, label: "Loosely related", description: "Some connection but limited relevance."),
            RatingAnchor(rating: 3, label: "Relevant", description: "Clearly supports your professional direction."),
            RatingAnchor(rating: 4, label: "Directly aligned", description: "Strongly supports the kind of work you want to pursue."),
            RatingAnchor(rating: 5, label: "Central", description: "Directly represents or enables your desired professional direction."),
        ])

    public static let demonstrationValue = MetricDefinition(
        id: "demonstrationValue", displayName: "Demonstration Value", notionPropertyName: "Demonstration Value",
        question: "How strongly could the finished project demonstrate your capabilities to other people?",
        direction: .benefit, groupID: "professionalValue",
        anchors: [
            RatingAnchor(rating: 1, label: "Shows very little", description: "Difficult to use as meaningful evidence of capability."),
            RatingAnchor(rating: 2, label: "Modest example", description: "Demonstrates something useful but relatively ordinary or narrow."),
            RatingAnchor(rating: 3, label: "Solid evidence", description: "Credible evidence of meaningful capability."),
            RatingAnchor(rating: 4, label: "Strong portfolio evidence", description: "Clearly demonstrates sophisticated or valuable abilities."),
            RatingAnchor(rating: 5, label: "Standout demonstration", description: "Exceptional evidence capable of materially changing someone's perception of your capabilities."),
        ])

    public static let opportunityPotential = MetricDefinition(
        id: "opportunityPotential", displayName: "Opportunity Potential", notionPropertyName: "Opportunity Potential",
        question: "How likely is this to create professional opportunities that otherwise wouldn't exist?",
        direction: .benefit, groupID: "professionalValue",
        anchors: [
            RatingAnchor(rating: 1, label: "None expected", description: "Unlikely to affect future opportunities."),
            RatingAnchor(rating: 2, label: "Possible", description: "Could occasionally lead somewhere useful."),
            RatingAnchor(rating: 3, label: "Plausible", description: "Has a reasonable chance of generating useful connections, work, access, or opportunities."),
            RatingAnchor(rating: 4, label: "Likely", description: "Strong potential to create meaningful new opportunities."),
            RatingAnchor(rating: 5, label: "Gateway", description: "Could open major opportunities that would otherwise be difficult or unavailable."),
        ])

    // 4. LEARNING & GROWTH
    public static let skillDevelopment = MetricDefinition(
        id: "skillDevelopment", displayName: "Skill Development", notionPropertyName: "Skill Development",
        question: "How much will completing this improve your ability to do something useful?",
        direction: .benefit, groupID: "learningGrowth",
        anchors: [
            RatingAnchor(rating: 1, label: "Existing skills", description: "Mostly uses abilities you already have comfortably."),
            RatingAnchor(rating: 2, label: "Some practice", description: "Provides practice or minor skill development."),
            RatingAnchor(rating: 3, label: "Meaningful development", description: "Requires practicing and improving useful skills."),
            RatingAnchor(rating: 4, label: "Major improvement", description: "Develops substantial competence in an important skill."),
            RatingAnchor(rating: 5, label: "New capability", description: "Represents a major step toward proficiency or mastery in a highly useful skill."),
        ])

    public static let knowledgeGain = MetricDefinition(
        id: "knowledgeGain", displayName: "Knowledge Gain", notionPropertyName: "Knowledge Gain",
        question: "How much useful understanding will you acquire?",
        direction: .benefit, groupID: "learningGrowth",
        anchors: [
            RatingAnchor(rating: 1, label: "Almost nothing new", description: "Little new understanding expected."),
            RatingAnchor(rating: 2, label: "Some new information", description: "Learn a few useful facts or concepts."),
            RatingAnchor(rating: 3, label: "Meaningful understanding", description: "Gain useful understanding applicable elsewhere."),
            RatingAnchor(rating: 4, label: "Deep learning", description: "Develop substantial understanding of an important subject."),
            RatingAnchor(rating: 5, label: "Foundational expertise", description: "Gain a body of knowledge likely to influence or enable substantial future work."),
        ])

    public static let explorationValue = MetricDefinition(
        id: "explorationValue", displayName: "Exploration Value", notionPropertyName: "Exploration Value",
        question: "How valuable would answering the unknowns uncovered by this project be, even if the project itself fails?",
        direction: .benefit, groupID: "learningGrowth",
        anchors: [
            RatingAnchor(rating: 1, label: "Little learned from failure", description: "The investigation itself provides little useful information."),
            RatingAnchor(rating: 2, label: "Some useful answers", description: "Failure or experimentation would still answer some worthwhile questions."),
            RatingAnchor(rating: 3, label: "Worthwhile exploration", description: "The investigation itself provides meaningful value."),
            RatingAnchor(rating: 4, label: "Important questions answered", description: "The project would resolve important unknowns even without achieving its intended result."),
            RatingAnchor(rating: 5, label: "Highly valuable exploration", description: "The investigation itself is highly valuable regardless of whether the intended outcome succeeds."),
        ])

    // 5. STRATEGIC VALUE
    public static let goalAlignment = MetricDefinition(
        id: "goalAlignment", displayName: "Goal Alignment", notionPropertyName: "Goal Alignment",
        question: "How directly does this advance a current important goal?",
        direction: .benefit, groupID: "strategicValue",
        anchors: [
            RatingAnchor(rating: 1, label: "Unrelated", description: "Does not meaningfully support a current goal."),
            RatingAnchor(rating: 2, label: "Loosely supportive", description: "Some connection, but completing it would not substantially advance the goal."),
            RatingAnchor(rating: 3, label: "Clearly supportive", description: "Clearly contributes to at least one current goal."),
            RatingAnchor(rating: 4, label: "Directly advances", description: "Would materially advance an important current goal."),
            RatingAnchor(rating: 5, label: "Essential", description: "Central or essential to accomplishing a top-level goal."),
        ])

    public static let leverage = MetricDefinition(
        id: "leverage", displayName: "Leverage", notionPropertyName: "Leverage",
        question: "How much will completing this make future valuable work easier, faster, or more capable?",
        direction: .benefit, groupID: "strategicValue",
        anchors: [
            RatingAnchor(rating: 1, label: "Mostly isolated", description: "Benefits itself with little downstream effect."),
            RatingAnchor(rating: 2, label: "Small multiplier", description: "Saves some effort or helps a small amount of future work."),
            RatingAnchor(rating: 3, label: "Useful multiplier", description: "Makes several future tasks easier, faster, or more effective."),
            RatingAnchor(rating: 4, label: "Strong multiplier", description: "Significantly improves or enables substantial amounts of other work."),
            RatingAnchor(rating: 5, label: "Foundational", description: "Unlocks, automates, or dramatically accelerates many valuable things afterward."),
        ])

    public static let dependencyImportance = MetricDefinition(
        id: "dependencyImportance", displayName: "Dependency Importance", notionPropertyName: "Dependency Importance",
        question: "How much other work is currently waiting on this?",
        direction: .benefit, groupID: "strategicValue",
        anchors: [
            RatingAnchor(rating: 1, label: "Nothing", description: "No meaningful work depends on it."),
            RatingAnchor(rating: 2, label: "Minor dependencies", description: "A small amount of low-priority work benefits from it."),
            RatingAnchor(rating: 3, label: "Meaningful dependencies", description: "Several useful tasks or projects are constrained by it."),
            RatingAnchor(rating: 4, label: "Major blocker", description: "Important work cannot proceed efficiently until this is completed."),
            RatingAnchor(rating: 5, label: "Critical path", description: "A substantial body of high-value work is effectively blocked by this project."),
        ])

    // 6. TIME & EXECUTION
    public static let urgency = MetricDefinition(
        id: "urgency", displayName: "Urgency", notionPropertyName: "Urgency",
        question: "What happens if you delay it?",
        direction: .benefit, groupID: "timeExecution",
        anchors: [
            RatingAnchor(rating: 1, label: "Whenever", description: "Doing it months from now is essentially fine."),
            RatingAnchor(rating: 2, label: "Prefer sooner", description: "Some advantage to doing it sooner, but no meaningful consequence to waiting."),
            RatingAnchor(rating: 3, label: "Time-sensitive", description: "Delay has a noticeable cost or there is a useful timeframe."),
            RatingAnchor(rating: 4, label: "Pressing", description: "Significant value is being lost or a deadline/opportunity is approaching."),
            RatingAnchor(rating: 5, label: "Immediate", description: "Waiting risks serious consequences or losing an imminent opportunity."),
        ])

    /// Effort is a cost metric: higher effort means less desirable, all else equal.
    public static let effort = MetricDefinition(
        id: "effort", displayName: "Effort", notionPropertyName: "Effort",
        question: "How much of your focused work is required to reach a genuinely useful completed state?",
        direction: .costOrRisk, groupID: "timeExecution",
        anchors: [
            RatingAnchor(rating: 1, label: "Hours", description: "A few hours or less."),
            RatingAnchor(rating: 2, label: "Small", description: "Roughly one or two focused days."),
            RatingAnchor(rating: 3, label: "Moderate", description: "Several days to roughly a week of real work."),
            RatingAnchor(rating: 4, label: "Large", description: "Multiple weeks of substantial work."),
            RatingAnchor(rating: 5, label: "Major undertaking", description: "A sustained project likely requiring many weeks or months."),
        ])

    public static let readiness = MetricDefinition(
        id: "readiness", displayName: "Readiness", notionPropertyName: "Readiness",
        question: "How prepared is the project for productive work right now?",
        direction: .benefit, groupID: "timeExecution",
        anchors: [
            RatingAnchor(rating: 1, label: "Blocked", description: "You cannot meaningfully begin because major prerequisites or blockers remain."),
            RatingAnchor(rating: 2, label: "Significant preparation needed", description: "Important research, decisions, setup, access, or preparation remain."),
            RatingAnchor(rating: 3, label: "Workable", description: "You can begin, but important questions or prerequisites remain."),
            RatingAnchor(rating: 4, label: "Mostly ready", description: "Requirements and next steps are mostly clear with little preventing productive work."),
            RatingAnchor(rating: 5, label: "Immediately executable", description: "Everything important is available and understood, and productive work can begin immediately."),
        ])

    // 7. RISK & LONG-TERM CONSEQUENCES
    public static let outcomeUncertainty = MetricDefinition(
        id: "outcomeUncertainty", displayName: "Outcome Uncertainty", notionPropertyName: "Outcome Uncertainty",
        question: "How uncertain are you that the project can actually produce its intended result?",
        direction: .costOrRisk, groupID: "riskConsequences",
        anchors: [
            RatingAnchor(rating: 1, label: "Proven", description: "The path is straightforward and known to work."),
            RatingAnchor(rating: 2, label: "Mostly understood", description: "A few unknowns exist, but the approach is well understood."),
            RatingAnchor(rating: 3, label: "Meaningful unknowns", description: "Important questions remain and experimentation is expected."),
            RatingAnchor(rating: 4, label: "Major uncertainty", description: "Significant technical, conceptual, or execution questions remain unresolved."),
            RatingAnchor(rating: 5, label: "Highly experimental", description: "Feasibility itself or the path to the intended outcome is uncertain."),
        ])

    public static let ongoingBurden = MetricDefinition(
        id: "ongoingBurden", displayName: "Ongoing Burden", notionPropertyName: "Ongoing Burden",
        question: "Once finished, how much continuing attention will it demand?",
        direction: .costOrRisk, groupID: "riskConsequences",
        anchors: [
            RatingAnchor(rating: 1, label: "Essentially none", description: "Finish it and it largely takes care of itself."),
            RatingAnchor(rating: 2, label: "Light", description: "Occasional minor maintenance."),
            RatingAnchor(rating: 3, label: "Moderate", description: "Regular maintenance, updates, monitoring, support, or expense."),
            RatingAnchor(rating: 4, label: "Heavy", description: "Requires significant recurring attention or resources."),
            RatingAnchor(rating: 5, label: "Continuous", description: "Creates a substantial ongoing responsibility comparable to maintaining a product or service."),
        ])

    public static let abandonmentCost = MetricDefinition(
        id: "abandonmentCost", displayName: "Abandonment Cost", notionPropertyName: "Abandonment Cost",
        question: "If you start this and later abandon it, how costly is that likely to be?",
        direction: .costOrRisk, groupID: "riskConsequences",
        anchors: [
            RatingAnchor(rating: 1, label: "Almost nothing lost", description: "Easy to stop with little consequence."),
            RatingAnchor(rating: 2, label: "Small sunk cost", description: "Some lost work or resources, but little lasting consequence."),
            RatingAnchor(rating: 3, label: "Meaningful loss", description: "Abandoning it would waste a meaningful amount of time or resources."),
            RatingAnchor(rating: 4, label: "Substantial cost", description: "Abandoning it would create substantial sunk cost, disruption, or lost commitments."),
            RatingAnchor(rating: 5, label: "Serious consequences", description: "Once started, abandoning the project would have major financial, operational, interpersonal, or other consequences."),
        ])

    // MARK: - Collections

    public static let all: [MetricDefinition] = MetricGroup.allGroups.flatMap(\.metrics)

    /// Retired metric ids from earlier versions. Ratings recorded against these are
    /// kept — a judgement someone made is not invalidated by a taxonomy change — but
    /// they take no part in any calculation.
    public static let legacyMetricIDs: Set<String> = [
        "outcomeValue", "strategicRelevance", "resourceCost", "uncertainty",
        "skillGain", "reusableAssetValue", "opportunityValue", "processVisibilityValue",
    ]
}

public struct MetricGroup: Identifiable, Hashable, Sendable {
    public let id: String
    public let displayName: String
    public let description: String
    public let metrics: [MetricDefinition]
    public static let personalValue = MetricGroup(
        id: "personalValue", displayName: "Personal Value",
        description: "What completing the project does for your life directly, separate from career, money, or learning.",
        metrics: [.qualityOfLife, .personalImportance, .enjoyment])

    public static let financialValue = MetricGroup(
        id: "financialValue", displayName: "Financial Value",
        description: "Financial effects specifically, so that \"value\" does not ambiguously mean money.",
        metrics: [.incomePotential, .costSavings, .financialCost])

    public static let professionalValue = MetricGroup(
        id: "professionalValue", displayName: "Professional Value",
        description: "Career and professional effects without conflating them with direct financial value.",
        metrics: [.careerRelevance, .demonstrationValue, .opportunityPotential])

    public static let learningGrowth = MetricGroup(
        id: "learningGrowth", displayName: "Learning & Growth",
        description: "What you gain internally by doing the work.",
        metrics: [.skillDevelopment, .knowledgeGain, .explorationValue])

    public static let strategicValue = MetricGroup(
        id: "strategicValue", displayName: "Strategic Value",
        description: "How the project interacts with everything else you are trying to accomplish.",
        metrics: [.goalAlignment, .leverage, .dependencyImportance])

    public static let timeExecution = MetricGroup(
        id: "timeExecution", displayName: "Time & Execution",
        description: "The practical reality of getting the project done.",
        metrics: [.urgency, .effort, .readiness])

    public static let riskConsequences = MetricGroup(
        id: "riskConsequences", displayName: "Risk & Long-Term Consequences",
        description: "Uncertainty and costs that may persist beyond initial implementation.",
        metrics: [.outcomeUncertainty, .ongoingBurden, .abandonmentCost])

    public static let allGroups: [MetricGroup] = [
        .personalValue, .financialValue, .professionalValue,
        .learningGrowth, .strategicValue, .timeExecution, .riskConsequences,
    ]

    public static let defaultWeights: [String: Double] = [
        "personalValue": 20.0,
        "financialValue": 10.0,
        "professionalValue": 15.0,
        "learningGrowth": 10.0,
        "strategicValue": 20.0,
        "timeExecution": 15.0,
        "riskConsequences": 10.0,
    ]

    public static func find(id: String) -> MetricGroup? { allGroups.first { $0.id == id } }
}
