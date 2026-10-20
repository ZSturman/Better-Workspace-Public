import Foundation

public struct MobileFilePreview: Identifiable, Hashable, Codable, Sendable {
    public var path: String
    public var name: String
    public var text: String?
    public var jpeg: Data?
    public var modifiedAt: Date?
    public var id: String { path }
    public init(path: String, name: String, text: String? = nil, jpeg: Data? = nil, modifiedAt: Date? = nil) {
        self.path = path; self.name = name; self.text = text; self.jpeg = jpeg; self.modifiedAt = modifiedAt
    }
}

/// Reuses the deployed optional overviewJSON field on project index records.
/// Older phones still read the separate plain-text fields. No CloudKit schema change.
public struct MobileProjectEnvelope: Codable {
    public var projectDetails: MobileProjectDetails
    public static func encode(_ details: MobileProjectDetails) -> String? {
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        return (try? encoder.encode(Self(projectDetails: details))).flatMap { String(data: $0, encoding: .utf8) }
    }
    public static func decode(_ text: String?) -> MobileProjectDetails? {
        text.flatMap { $0.data(using: .utf8) }.flatMap { try? JSONDecoder().decode(Self.self, from: $0).projectDetails }
    }
}

public struct MobileProjectProperties: Hashable, Codable, Sendable {
    public var domain: String
    public var status: String
    public var phase: String
    public var projectType: String
    public init(_ details: MobileProjectDetails) {
        domain = details.domain ?? ""; status = details.status ?? ""; phase = details.phase ?? ""; projectType = details.projectType ?? ""
    }
    public init(_ metadata: ProjectMetadata) {
        domain = metadata.domain ?? ""; status = metadata.status ?? ""; phase = metadata.phase ?? ""; projectType = metadata.projectType ?? ""
    }
    public func changedFields(from original: MobileProjectDetails) -> Set<String> {
        let before = Self(original)
        return Set([("domain", domain, before.domain), ("Status", status, before.status), ("Phase", phase, before.phase), ("Type", projectType, before.projectType)]
            .filter { $0.1 != $0.2 }.map { $0.0 })
    }
    public func isReflected(in details: MobileProjectDetails, from original: MobileProjectDetails) -> Bool {
        let changed = changedFields(from: original), current = Self(details)
        return (!changed.contains("domain") || current.domain == domain) && (!changed.contains("Status") || current.status == status)
            && (!changed.contains("Phase") || current.phase == phase) && (!changed.contains("Type") || current.projectType == projectType)
    }
}

public struct MobileProjectEdit: Hashable, Codable, Sendable {
    public var original: MobileProjectDetails
    public var ratings: [String: Int]
    public var oneLiner: String
    public var summary: String
    public var properties: MobileProjectProperties?
    public init(original: MobileProjectDetails, ratings: [String: Int], oneLiner: String, summary: String, properties: MobileProjectProperties? = nil) {
        self.properties = properties
        self.original = original; self.ratings = ratings; self.oneLiner = oneLiner; self.summary = summary
    }
    public func validate() throws {
        if let properties {
            guard [properties.domain, properties.status, properties.phase, properties.projectType].allSatisfy({ $0.utf8.count <= 200 && !$0.contains("\n") }) else {
                throw MobilePlanningFiles.Error.invalid("Keep each property under 200 bytes and on one line.")
            }
        }
        guard original.projectID != nil, original.ratings != nil,
              MobileWorkspacePath.normalizedRelative(original.path) == original.path,
              WorkspaceListing.isAreaChild(original.path, area: "Projects"),
              oneLiner.utf8.count <= 512, !oneLiner.contains("\n"), summary.utf8.count <= MobilePlanningFiles.maximumTextBytes,
              ratings.count <= MetricDefinition.all.count + MetricDefinition.legacyMetricIDs.count,
              ratings.allSatisfy({ (1...5).contains($0.value) && (MetricDefinition.find(id: $0.key) != nil || original.ratings?[$0.key] == $0.value) }) else {
            throw MobilePlanningFiles.Error.invalid("Refresh the project on your phone before scoring it. Keep the one-liner under 512 bytes and the summary under 32 KB.")
        }
    }
    public func matches(ratings current: [String: Int], description: ProjectDescription) -> Bool {
        (current == original.ratings && (description.oneLiner ?? "") == (original.oneLiner ?? "") && (description.summary ?? "") == (original.summary ?? ""))
        || (current == ratings && (description.oneLiner ?? "") == oneLiner && (description.summary ?? "") == summary)
    }
}

extension MobileProjectDetails {
    public var currentScore: ProjectScore {
        let preferences = scoringPreferences ?? ProjectScoringPreferences()
        return ProjectScore(ratings: ratings ?? [:], enabledMetricIDs: preferences.enabledMetricIDs,
            enabledGroups: MetricGroup.allGroups.filter { preferences.enabledGroupIDs.contains($0.id) }, groupWeights: preferences.groupWeights)
    }
    public var rankingScore: Double? { ratings == nil ? manualScore : currentScore.projectScore }
}

extension ProjectStore {
    public func needsSetup(_ projectID: String) -> Bool {
        ((try? db.query("SELECT project_id FROM project_setup WHERE project_id = ? AND completed = 0", [.text(projectID)], row: { $0.string(0) }))?.first) != nil
    }
    public func setupProjectIDs() -> Set<String> {
        Set((try? db.query("SELECT project_id FROM project_setup WHERE completed = 0", row: { $0.string(0) })) ?? [])
    }
    public func markDiscovered(_ projectID: String) {
        _ = try? db.run("INSERT OR IGNORE INTO project_setup (project_id, discovered_at) VALUES (?,?)", [.text(projectID), .double(Date().timeIntervalSince1970)])
    }
    public func finishSetup(_ projectID: String) throws {
        try db.run("UPDATE project_setup SET completed = 1 WHERE project_id = ?", [.text(projectID)])
    }
    public func saveMobileProject(_ change: MobileProjectEdit) throws {
        try change.validate()
        lock.lock(); defer { lock.unlock() }
        try db.transaction {
            guard let id = change.original.projectID, let record = record(id: id),
                  record.lastPath.hasSuffix("/" + change.original.path),
                  change.matches(ratings: ratings(for: id), description: description(for: id)) else { throw MobilePlanningFiles.Error.conflict }
            if let properties = change.properties {
                let current = MobileProjectProperties(metadata(for: id)), original = MobileProjectProperties(change.original)
                // SQL columns are a fixed allowlist. Unchanged properties are neither
                // conflict checks nor writes, preserving concurrent unrelated edits.
                for (column, desired, before, now) in [("domain", properties.domain, original.domain, current.domain),
                    ("status", properties.status, original.status, current.status), ("phase", properties.phase, original.phase, current.phase),
                    ("project_type", properties.projectType, original.projectType, current.projectType)] where desired != before {
                    guard now == before || now == desired else { throw MobilePlanningFiles.Error.conflict }
                    try db.run("INSERT INTO project_metadata(project_id,\(column),updated_at) VALUES (?,?,?) ON CONFLICT(project_id) DO UPDATE SET \(column)=excluded.\(column),updated_at=excluded.updated_at",
                        [.text(id), desired.isEmpty ? .null : .text(desired), .double(Date().timeIntervalSince1970)])
                }
            }
            // Throw on storage failures so a phone never gets a false success receipt.
            for metric in MetricDefinition.all {
                if let value = change.ratings[metric.id] {
                    try db.run("INSERT OR REPLACE INTO project_ratings (project_id,metric_id,value,updated_at) VALUES (?,?,?,?)", [.text(id), .text(metric.id), .int(Int64(value)), .double(Date().timeIntervalSince1970)])
                } else {
                    try db.run("DELETE FROM project_ratings WHERE project_id = ? AND metric_id = ?", [.text(id), .text(metric.id)])
                }
            }
            try db.run("INSERT INTO project_descriptions(project_id,one_liner,summary,updated_at) VALUES (?,?,?,?) ON CONFLICT(project_id) DO UPDATE SET one_liner=excluded.one_liner,summary=excluded.summary,updated_at=excluded.updated_at", [.text(id), change.oneLiner.isEmpty ? .null : .text(change.oneLiner), change.summary.isEmpty ? .null : .text(change.summary), .double(Date().timeIntervalSince1970)])
            try finishSetup(id)
        }
    }
}
