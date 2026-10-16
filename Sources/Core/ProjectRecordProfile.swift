import Foundation

/// What an editor leads with for one kind of planning record, and what it calls things.
///
/// A Notion database exposes every property it has: a Features record has fourteen, a
/// Task more than fifty. Creating one should ask for the few that make it what it is —
/// a name, what it is for, where it belongs — and keep the rest one click away under
/// More Options, unchanged. Nothing here hides a property for good, renames it in
/// Notion, or invents one: a name the schema does not have is skipped.
public struct ProjectRecordProfile: Sendable {
    public struct Field: Sendable, Hashable, Identifiable {
        /// The property's name in the Notion schema.
        public let name: String
        /// What the editor calls it.
        public let label: String
        /// Placeholder for an empty text field.
        public let prompt: String?
        public var id: String { name }
    }

    /// A relationship the editor offers as "Add Task", "Add Milestone": create a new
    /// record of that kind or link an existing one.
    public struct Relation: Sendable, Hashable, Identifiable {
        public let name: String
        public let target: ProjectEntityKind
        /// "Task", "Milestone".
        public let noun: String
        public var id: String { name }
    }

    /// The title property's name.
    public let title: String?
    /// The long-form "what is this" field, shown as a multi-line description.
    public let description: Field?
    /// Short fields shown up front (status, stage, dates, tags).
    public let essentials: [Field]
    /// Relationships offered as Add actions, in order.
    public let relations: [Relation]
    /// Every other writable property, for More Options: fields, then relationships, each by name.
    public let advanced: [String]
    /// Properties Notion computes; shown read-only under More Options.
    public let computed: [String]

    public func label(for name: String) -> String {
        if let field = ([description].compactMap { $0 } + essentials).first(where: { $0.name == name }) { return field.label }
        return Self.friendlyNames[name.lowercased()] ?? name.prefix(1).uppercased() + name.dropFirst()
    }

    /// Clearer names for properties that keep their schema names in More Options.
    static let friendlyNames: [String: String] = [
        "current focus": "Current focus", "next step": "Next step", "success criteria": "Done when",
        "outcome": "Outcome", "blocked by": "Waiting on", "blocking": "Blocks", "depends on": "Depends on",
        "dependencies": "Depends on", "child features": "Sub-features", "parent feature": "Part of feature",
        "parent task": "Part of task", "subtasks": "Subtasks", "work stage": "When",
        "do date (manual)": "Start", "due date (manual)": "Due", "do date": "Start", "due date": "Due",
        "date completed": "Completed on", "one liner": "One-line summary",
    ]

    private struct Plan {
        var description: [(String, String, String?)] = []
        var essentials: [(String, String, String?)] = []
        var relations: [(String, String)] = []
    }

    private static func plan(for kind: ProjectEntityKind) -> Plan {
        switch kind {
        case .features:
            return Plan(description: [("Description", "Description", nil), ("Outcome", "Outcome", "What will be true when this is done?")],
                        essentials: [("Status", "Status", nil)],
                        relations: [("Milestones", "Milestone"), ("Tasks", "Task")])
        case .milestones:
            return Plan(description: [("description", "Description", "What does reaching this milestone mean?")],
                        essentials: [("due date (manual)", "Due", nil)],
                        relations: [("tasks", "Task"), ("Features", "Feature")])
        case .tasks:
            return Plan(essentials: [("status", "Status", nil), ("Work Stage", "When", nil), ("priority", "Priority", nil), ("due date", "Due", nil)],
                        relations: [("Features", "Feature"), ("milestones", "Milestone")])
        case .projects:
            return Plan(description: [("summary", "Description", nil), ("description", "Description", nil)],
                        essentials: [("one liner", "One-line summary", "What is it, in a sentence?"), ("Status", "Status", nil), ("Phase", "Phase", nil),
                                     ("domain", "Domain", nil), ("Type", "Type", nil), ("tags", "Tags", nil)])
        case .ideas:
            return Plan(description: [("one liner", "Description", nil)],
                        essentials: [("status", "Status", nil), ("type", "Type", nil), ("tags", "Tags", nil)])
        case .notes:
            return Plan(essentials: [("type", "Type", nil), ("tags", "Tags", nil)])
        case .resources:
            return Plan(essentials: [("label", "Label", nil), ("url", "Link", "https://"), ("type", "Type", nil)])
        default:
            return Plan(description: [("one liner", "Description", nil), ("summary", "Description", nil), ("description", "Description", nil)],
                        essentials: [("status", "Status", nil), ("tags", "Tags", nil)])
        }
    }

    public static func make(kind: ProjectEntityKind, source: ProjectGraphSource, sources: [ProjectGraphSource]) -> ProjectRecordProfile {
        let schema = source.schema.object
        func type(_ name: String) -> String { schema[name]?["type"].string ?? "" }
        func writable(_ name: String) -> Bool { source.property(named: name).map { source.writable($0.id) } ?? false }
        /// The schema's own spelling of `name`, if it has a writable property by that name.
        func resolve(_ name: String) -> String? {
            guard let id = source.property(named: name)?.id, source.writable(id) else { return nil }
            return source.name(for: id)
        }
        /// A select with no options offers nothing to choose; it is not essential.
        func usable(_ name: String) -> Bool {
            let kind = type(name)
            guard ["select", "status", "multi_select"].contains(kind) else { return true }
            return !(schema[name]?[kind]["options"].array.isEmpty ?? true)
        }
        let plan = plan(for: kind)
        let title = schema.first { $0.value["type"].string == "title" }?.key
        let description = plan.description.lazy.compactMap { name, label, prompt in
            resolve(name).flatMap { ["rich_text"].contains(type($0)) ? Field(name: $0, label: label, prompt: prompt) : nil }
        }.first
        var used = Set([title, description?.name].compactMap { $0 })
        var essentials: [Field] = []
        for (name, label, prompt) in plan.essentials {
            guard let resolved = resolve(name), !used.contains(resolved), usable(resolved), type(resolved) != "relation" else { continue }
            essentials.append(Field(name: resolved, label: label, prompt: prompt)); used.insert(resolved)
        }
        let kindsBySource = Dictionary(sources.map { ($0.id, $0.kind) }, uniquingKeysWith: { first, _ in first })
        var relations: [Relation] = []
        for (name, noun) in plan.relations {
            guard let resolved = resolve(name), type(resolved) == "relation", !used.contains(resolved),
                  let target = schema[resolved]?["relation"]["data_source_id"].string.flatMap({ kindsBySource[$0] }) else { continue }
            relations.append(Relation(name: resolved, target: target, noun: noun)); used.insert(resolved)
        }
        let sorted = schema.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        return ProjectRecordProfile(
            title: title, description: description, essentials: essentials, relations: relations,
            // Fields first, then relationships, so links are not scattered among text.
            advanced: sorted.filter { !used.contains($0) && writable($0) && type($0) != "relation" }
                + sorted.filter { !used.contains($0) && writable($0) && type($0) == "relation" },
            computed: sorted.filter { !writable($0) })
    }
}
