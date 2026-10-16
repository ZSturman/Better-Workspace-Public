import Foundation

/// Adapts service API values without reading sidecars or recomputing observations.
public enum ProjectServiceBridge {
    public static func applying(_ values: [String: ProjectJSON], serviceID: String, to initial: ProjectGraphRecord, source: ProjectGraphSource) -> ProjectGraphRecord {
        var record = initial
        let firstImport = record.local.isEmpty && record.baseline.isEmpty && !record.remote.isEmpty
        if firstImport { record.seedInitialLocalState(values, source: source) }
        var snapshot = record.serviceSnapshot ?? [:]
        for (name, value) in values {
            guard let field = source.property(named: name), source.writable(field.id) else { continue }
            let existing = record.local[field.id] ?? .null
            let type = field.definition["type"].string ?? ""
            let proposed = ProjectJSON.object(["type": .string(type), type: value])
            let sameSelection = ["select", "status", "multi_select"].contains(type) && ProjectSyncTriage.equivalent(proposed, existing)
            // Service reads contain names, not Notion IDs/colors. Repair an old
            // metadata-only echo even when the service snapshot itself is unchanged.
            if sameSelection, let remote = record.remote[field.id],
               record.baseline[field.id]?.comparable == remote.comparable,
               ProjectSyncTriage.equivalent(proposed, remote) { record.local[field.id] = remote }
            if snapshot[field.id]?.comparable != value.comparable {
                let sameText = ["title", "rich_text"].contains(type) && value.display == existing.display
                let sameDate = type == "date" && value["start"].string.flatMap(ProjectDates.parse) != nil && value["start"].string.flatMap(ProjectDates.parse) == existing["date"]["start"].string.flatMap(ProjectDates.parse)
                if !firstImport && !sameText && !sameDate && !sameSelection { record.set(name, value: value, source: source, changedAt: nil) }
                snapshot[field.id] = value
            }
        }
        record.serviceRecordID = serviceID; record.serviceSnapshot = snapshot
        return record
    }
    public static func text(_ value: String?) -> ProjectJSON {
        let value = value ?? ""
        guard !value.isEmpty else { return ProjectJSON([]) }
        // Notion bounds each rich-text segment to 2,000 UTF-16 code units.
        // Preserve long summaries and scalar boundaries instead of truncating them.
        var chunks: [[String: Any]] = [], text = "", length = 0
        for scalar in value.unicodeScalars {
            let count = scalar.value > 0xFFFF ? 2 : 1
            if length + count > 2000 {
                chunks.append(["type": "text", "text": ["content": text]])
                text = ""; length = 0
            }
            text.unicodeScalars.append(scalar); length += count
        }
        if !text.isEmpty { chunks.append(["type": "text", "text": ["content": text]]) }
        return ProjectJSON(chunks)
    }
}
