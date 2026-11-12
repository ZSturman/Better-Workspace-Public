import Foundation

/// Better Workspace's side of Workspace Project Exchange v1: how a request's field
/// edits meet `ProjectMetadata`. Kept in Core so the rules are testable without the app.
public enum ProjectExchangeMetadata {
    public struct Result: Equatable, Sendable {
        public var plan: ExchangeMerge.Plan
        public var metadata: ProjectMetadata
        public var warnings: [String]
        /// Notion property names to queue through the normal graph edit path.
        public var notionFields: Set<String>
    }

    public static let notionNames: [ExchangeField: String] = [
        .status: "Status", .phase: "Phase", .domain: "domain", .maintenanceCadence: "Maintenance Cadence",
        .completionModel: "Completion Model", .statusDetail: "status details"
    ]

    /// - Parameters:
    ///   - statusOptions: options the Projects source accepts, plus values already in use.
    ///   - statusPropertyKind: `status` properties reject options Notion does not list.
    public static func apply(_ changes: [ExchangeChange], to metadata: ProjectMetadata, statusOptions: [String],
                             notionStatusOptions: [String], statusPropertyKind: String?) -> Result {
        // A canonical lifecycle title adopts an equivalent existing option ("Paused" for
        // Backburner) so one vocabulary stays in use and Notion can accept the value.
        let changes = changes.map { change -> ExchangeChange in
            guard change.field == .status, let value = change.value, let lifecycle = ExchangeLifecycle.classify(value),
                  value.caseInsensitiveCompare(lifecycle.title) == .orderedSame else { return change }
            return .init(field: .status, base: change.base, value: lifecycle.preferredText(options: statusOptions))
        }
        let plan = ExchangeMerge.plan(changes) { value($0, in: metadata) }
        var updated = metadata, warnings: [String] = []
        for (field, value) in plan.updates { set(field, value, in: &updated) }
        if let status = plan.updates[.status] ?? nil, statusPropertyKind == "status",
           !notionStatusOptions.contains(where: { $0.caseInsensitiveCompare(status) == .orderedSame }) {
            warnings.append("Notion’s Status property has no “\(status)” option. Add it in Notion so this project can sync.")
        }
        return Result(plan: plan, metadata: updated, warnings: warnings, notionFields: Set(plan.updates.keys.compactMap { notionNames[$0] }))
    }

    public static func value(_ field: ExchangeField, in metadata: ProjectMetadata) -> String? {
        switch field {
        case .status: metadata.status
        case .phase: metadata.phase
        case .domain: metadata.domain
        case .maintenanceCadence: metadata.maintenanceCadence
        case .completionModel: metadata.completionModel
        case .statusDetail: metadata.statusDetail
        case .portfolioPriority: metadata.portfolioPriority.map(String.init)
        }
    }

    static func set(_ field: ExchangeField, _ value: String?, in metadata: inout ProjectMetadata) {
        let value = ExchangeText.clean(value)
        switch field {
        case .status: metadata.status = value
        case .phase: metadata.phase = value
        case .domain: metadata.domain = value
        case .maintenanceCadence: metadata.maintenanceCadence = value
        case .completionModel: metadata.completionModel = value
        case .statusDetail: metadata.statusDetail = value
        case .portfolioPriority: metadata.portfolioPriority = value.flatMap(Int.init).map { min(5, max(1, $0)) }
        }
    }
}

/// Finder Workspace Extensions owns project metadata and publishes it in its own
/// `finder-workspace` exchange folder. Better Workspace mirrors those values, so a Notion
/// pull never changes them, and sends its own edits there as base-checked requests.
public enum FinderOwnedMetadata {
    public static let sourceID = "finder-workspace"
    public static let requesterID = "better-workspace"
    /// Status details are long-form text. This app's snapshot cuts them to 500 characters
    /// and a request value is limited to 512 bytes, so they cannot round-trip: they stay
    /// owned here. Keep in step with Finder Workspace's `OwnedMetadata.fields`.
    public static let fields: [ExchangeField] = ExchangeField.allCases.filter { $0 != .statusDetail }

    /// The owner's values applied to this Mac's metadata, except fields with an edit of
    /// this Mac's own still waiting for a receipt. `changed` lists the fields replaced.
    public static func mirror(_ row: ExchangeProject, onto metadata: ProjectMetadata,
                              skipping waiting: Set<ExchangeField> = []) -> (metadata: ProjectMetadata, changed: Set<ExchangeField>) {
        var updated = metadata, changed = Set<ExchangeField>()
        for field in fields where !waiting.contains(field) {
            let owned = row.value(field)
            guard ExchangeText.clean(ProjectExchangeMetadata.value(field, in: metadata)) != owned else { continue }
            ProjectExchangeMetadata.set(field, owned, in: &updated)
            changed.insert(field)
        }
        return (updated, changed)
    }

    /// One request for the shared fields an edit here changed. Each base is the value the
    /// person saw here, so an edit made before a newer Finder choice arrived conflicts
    /// instead of overwriting it.
    public static func request(projectID: String, projectPath: String, from old: ProjectMetadata, to new: ProjectMetadata,
                               only fields: Set<ExchangeField>? = nil) -> ExchangeRequest? {
        let changes = Self.fields.compactMap { field -> ExchangeChange? in
            guard fields?.contains(field) ?? true else { return nil }
            let before = ExchangeText.clean(ProjectExchangeMetadata.value(field, in: old))
            let after = ExchangeText.clean(ProjectExchangeMetadata.value(field, in: new))
            return before == after ? nil : ExchangeChange(field: field, base: before, value: after)
        }
        guard !changes.isEmpty else { return nil }
        return ExchangeRequest(requesterID: requesterID, projectID: projectID, projectPath: projectPath, changes: changes)
    }
}
