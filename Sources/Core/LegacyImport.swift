import Foundation

/// One-time, read-only migration out of the systems Better Workspace absorbs.
///
/// `Project.betterproject` is otherwise off limits to this app — it is another tool's
/// file and stays filtered from display by `NoiseFilter`. It is read here, and only
/// here, because those 387 files hold the only record of which project folder
/// corresponds to which Notion page, and losing that would be losing user data.
///
/// Everything in this file is strictly read-only with respect to the Workspace. No
/// sidecar is written, moved or deleted, now or after a successful import. Retiring
/// them is a separate, explicit decision.
public enum LegacyImport {

    // MARK: - Better Projects documents

    /// One `Project.betterproject` as found on disk.
    public struct Document: Sendable, Hashable {
        public let fileURL: URL
        public let projectDirectory: URL
        public let title: String?
        public let documentID: String?
        public let watcherProjectID: String?
        public let notionProjectID: String?
        /// False when the directory the document names is no longer there.
        public let directoryExists: Bool
    }

    public struct DocumentReport: Sendable {
        public var documents: [Document] = []
        public var imported = 0
        public var notionLinksRecovered = 0
        public var skippedMissingDirectory: [Document] = []
        /// A document whose Notion id disagrees with one already recorded. Never
        /// overwritten silently — the existing value wins and the clash is reported.
        public var conflicts: [(document: Document, existingNotionID: String)] = []

        public var discovered: Int { documents.count }
    }

    /// Finds every `Project.betterproject` beneath a root. Immediate-child projects
    /// only — these documents sit at the top of a project folder, never buried.
    public static func scanDocuments(in projectsRoot: URL) -> [Document] {
        let fm = FileManager.default
        guard let children = try? fm.contentsOfDirectory(
            at: projectsRoot, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        ) else { return [] }

        return children.compactMap { child -> Document? in
            guard (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { return nil }
            let file = child.appendingPathComponent("Project.betterproject")
            guard let data = try? Data(contentsOf: file),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return nil }

            // The document also records the path it was written at, but that claim goes
            // stale the moment the folder is renamed. Where the file actually *is* is
            // the better answer, so `projectDirectoryPath` is deliberately not read.
            var isDir: ObjCBool = false
            let exists = fm.fileExists(atPath: child.path, isDirectory: &isDir) && isDir.boolValue

            return Document(
                fileURL: file,
                projectDirectory: child,
                title: json["title"] as? String,
                documentID: json["documentID"] as? String,
                watcherProjectID: json["workspaceProjectID"] as? String,
                notionProjectID: nonEmpty(json["notionProjectID"]),
                directoryExists: exists
            )
        }
    }

    /// Records identity and external links for every scanned document.
    ///
    /// - Parameter apply: when false nothing is written and the report is a preview.
    @discardableResult
    public static func importDocuments(
        _ documents: [Document], into store: ProjectStore, apply: Bool
    ) -> DocumentReport {
        var report = DocumentReport()
        report.documents = documents

        for document in documents {
            guard document.directoryExists else {
                report.skippedMissingDirectory.append(document)
                continue
            }

            let existing = store.record(for: document.projectDirectory)
            if let existing, let current = existing.notionPageID, current.isEmpty == false,
               let incoming = document.notionProjectID, current != incoming {
                report.conflicts.append((document, current))
                continue
            }

            report.imported += 1
            if document.notionProjectID != nil, existing?.hasNotionLink != true {
                report.notionLinksRecovered += 1
            }
            guard apply else { continue }

            let record = existing ?? store.register(url: document.projectDirectory, name: document.title)
            store.setExternalIDs(watcherID: document.watcherProjectID,
                                 documentID: document.documentID,
                                 for: record.id)
            if let notion = document.notionProjectID {
                store.setNotionPageID(notion, for: record.id)
            }
        }
        return report
    }

    // MARK: - Better Projects ratings cache

    public struct RatingsReport: Sendable {
        public var projectsInCache = 0
        public var projectsWithRatings = 0
        public var matchedToLocalProject = 0
        public var unmatchedNotionIDs: [String] = []
        public var ratingsWritten = 0
        /// Ratings whose metric id is no longer part of the taxonomy. Imported anyway
        /// and simply not counted — a judgement is not invalidated by a rename.
        public var legacyRatingsRetained = 0
        /// Ratings already set in Better Workspace, left as they are.
        public var keptExisting = 0
    }

    /// The default location of Better Projects' local cache. It is read, never written.
    public static var betterProjectsCacheURL: URL {
        WorkspaceLocation.homeDirectory
            .appendingPathComponent("Library/Application Support/Better Projects/cache.json")
    }

    /// Imports manual 1–5 ratings, joined to local projects by Notion page id — the
    /// only identifier the cache and the documents share.
    ///
    /// Fill-only: a metric already rated here is never overwritten, so running the
    /// import again after linking another project cannot undo a rating changed since.
    @discardableResult
    public static func importRatings(
        from cacheURL: URL = betterProjectsCacheURL, into store: ProjectStore, apply: Bool
    ) -> RatingsReport {
        var report = RatingsReport()
        guard let data = try? Data(contentsOf: cacheURL),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let projects = root["projects"] as? [[String: Any]]
        else { return report }

        report.projectsInCache = projects.count
        let known = Dictionary(
            store.allRecords().compactMap { record in
                record.notionPageID.map { (normalizedID($0), record) }
            },
            uniquingKeysWith: { first, _ in first }
        )

        // Collected first, then written together. Hundreds of individual writes were
        // hundreds of separate commits, and a migration that stops halfway through
        // leaves a project rated on three metrics out of eight — which reads as a
        // deliberate judgement rather than as an interrupted import.
        var pending: [(value: Int, metricID: String, projectID: String)] = []

        for project in projects {
            guard let ratings = project["ratings"] as? [String: Any], ratings.isEmpty == false else { continue }
            report.projectsWithRatings += 1

            guard let notionID = project["id"] as? String else { continue }
            guard let record = known[normalizedID(notionID)] else {
                report.unmatchedNotionIDs.append(notionID)
                continue
            }
            report.matchedToLocalProject += 1
            let existing = store.ratings(for: record.id)

            for (metricID, raw) in ratings {
                guard let value = raw as? Int, (1...5).contains(value) else { continue }
                if existing[metricID] != nil { report.keptExisting += 1; continue }
                if MetricDefinition.legacyMetricIDs.contains(metricID) { report.legacyRatingsRetained += 1 }
                report.ratingsWritten += 1
                pending.append((value, metricID, record.id))
            }
        }

        if apply, pending.isEmpty == false {
            try? store.batch {
                for rating in pending {
                    store.setRating(rating.value, metricID: rating.metricID, for: rating.projectID)
                }
            }
        }
        return report
    }

    // MARK: - Better Projects descriptions

    public struct DescriptionReport: Sendable {
        /// Projects whose one-liner or summary was written.
        public var described = 0
        /// Better Projects' unsent edits that found their project and were applied.
        public var pendingEditsApplied = 0
        /// Unsent edits whose project this app does not know. Kept in the archive.
        public var pendingEditsUnmatched: [String] = []
        /// Fields already set here, left as they are.
        public var keptExisting = 0
    }

    /// Imports project one-liners and summaries.
    ///
    /// Two sources, in order. First Better Projects' unsent edits (`pendingFieldWrites`):
    /// the newest thing a person wrote, which never reached Notion — for a local-only
    /// project it never could. Then the cached Notion values, for the rest. Fill-only
    /// across both: whatever is already set here wins.
    @discardableResult
    public static func importDescriptions(
        from cacheURL: URL = betterProjectsCacheURL, into store: ProjectStore, apply: Bool
    ) -> DescriptionReport {
        var report = DescriptionReport()
        guard let data = try? Data(contentsOf: cacheURL),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return report }

        let records = store.allRecords()
        let byNotionID = Dictionary(records.compactMap { record in record.notionPageID.map { (normalizedID($0), record) } },
                                    uniquingKeysWith: { first, _ in first })
        let byDocumentID = Dictionary(records.compactMap { record in record.documentID.map { ($0.lowercased(), record) } },
                                      uniquingKeysWith: { first, _ in first })
        /// Better Projects names a local-only project `local-document-<documentID>`.
        func record(forProjectID id: String) -> ProjectRecord? {
            let prefix = "local-document-"
            if id.hasPrefix(prefix) { return byDocumentID[String(id.dropFirst(prefix.count)).lowercased()] }
            return byNotionID[normalizedID(id)]
        }

        var planned: [String: ProjectDescription] = [:]
        func plan(_ field: WritableKeyPath<ProjectDescription, String?>, _ text: String?, for record: ProjectRecord) -> Bool {
            guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), text.isEmpty == false else { return false }
            var description = planned[record.id] ?? store.description(for: record.id)
            if description[keyPath: field] != nil { report.keptExisting += 1; return false }
            description[keyPath: field] = text
            planned[record.id] = description
            return true
        }

        for write in (root["pendingFieldWrites"] as? [[String: Any]]) ?? [] {
            guard let projectID = write["projectID"] as? String,
                  let property = (write["propertyName"] as? String)?.lowercased(),
                  let text = ((write["value"] as? [String: Any])?["richText"] as? [String: Any])?["_0"] as? String
            else { continue }
            let field: WritableKeyPath<ProjectDescription, String?>
            switch property {
            case "one liner", "one-liner", "oneliner": field = \.oneLiner
            case "summary": field = \.summary
            default: continue
            }
            guard let target = record(forProjectID: projectID) else {
                report.pendingEditsUnmatched.append("\(projectID) \(property)")
                continue
            }
            if plan(field, text, for: target) { report.pendingEditsApplied += 1 }
        }

        for project in (root["projects"] as? [[String: Any]]) ?? [] {
            guard let id = project["id"] as? String, let target = record(forProjectID: id),
                  let metadata = project["metadata"] as? [String: Any] else { continue }
            _ = plan(\.oneLiner, metadata["oneLiner"] as? String, for: target)
            _ = plan(\.summary, metadata["summary"] as? String, for: target)
        }

        report.described = planned.count
        if apply, planned.isEmpty == false {
            try? store.batch {
                for (projectID, description) in planned { store.setDescription(description, for: projectID) }
            }
        }
        return report
    }

    // MARK: - Private

    private static func nonEmpty(_ value: Any?) -> String? {
        guard let string = value as? String, string.isEmpty == false else { return nil }
        return string
    }

    /// Notion hands the same id back with and without dashes depending on the surface.
    private static func normalizedID(_ id: String) -> String {
        id.replacingOccurrences(of: "-", with: "").lowercased()
    }
}
