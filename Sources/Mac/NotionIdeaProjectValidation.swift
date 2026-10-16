#if DEBUG
import Foundation
import BetterWorkspaceCore

/// Developer acceptance for potential-project ideas against the configured Notion
/// Projects source.
///
/// `audit-idea-projects` is read-only: it reads the live schema and pages and the local
/// records, and reports how ideas would map and match. It writes nothing to Notion or
/// to this app's database.
///
/// `validate-idea-project --create-validation-records` creates one explicitly named page
/// through the production bridge and coordinator in a private scratch database, edits
/// only that page, and archives only that page's returned ID.
enum NotionIdeaProjectValidation {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
    private static func say(_ line: String) { FileHandle.standardOutput.write(Data((line + "\n").utf8)) }
    private static func require(_ condition: Bool, _ message: @autoclosure () -> String) throws {
        if !condition { throw Failure(message: message()) }
    }

    static func configuredProjects(_ store: ProjectGraphStore) throws -> ProjectGraphSource {
        guard let source = try store.read("sources", as: [ProjectGraphSource].self)?.first(where: { $0.kind == .projects }) else {
            throw Failure(message: "No Projects source is configured in Settings → Integrations → Notion.")
        }
        return source
    }
    private static func options(_ field: (id: String, definition: ProjectJSON)) -> [String] {
        let type = field.definition["type"].display
        return field.definition[type]["options"].array.compactMap { $0["name"].string }
    }
    /// Snapshots compared as Notion has them (an unaccepted import has no local values yet).
    private static func asRemote(_ records: [ProjectGraphRecord]) -> [ProjectGraphRecord] {
        records.map { record in var copy = record; if copy.local.isEmpty { copy.local = copy.remote }; return copy }
    }

    // MARK: - Read-only audit

    static func audit(client: NotionClient, store: ProjectGraphStore) async throws -> Int32 {
        let configured = try configuredProjects(store)
        let live = try await client.graphSource(configured.id, kind: .projects)
        var problems: [String] = []
        say("Projects source: \(live.title) (\(live.id))")

        // Mapping the bridge writes.
        let title = live.schema.object.first { $0.value["type"].string == "title" }?.key
        say("Title property: \(title ?? "missing")"); if title == nil { problems.append("No title property") }
        if let status = live.property(named: "Status") {
            let type = status.definition["type"].display, names = options(status)
            say("Status: \(type) with options \(names.joined(separator: ", "))")
            if !["status", "select"].contains(type) { problems.append("Status is \(type), not status/select") }
            if !names.contains("Idea") { problems.append("Status has no Idea option") }
            let promotable = names.filter { ProjectViewQuery.normalize($0) != "idea" && !ProjectMetadata(status: $0).isTerminal }
            say("Statuses that offer promotion: \(promotable.joined(separator: ", "))")
        } else { problems.append("No Status property") }
        if let directory = live.property(named: "Local Directory") {
            let type = directory.definition["type"].display
            say("Local Directory: \(type)")
            if !["rich_text", "url"].contains(type) { problems.append("Local Directory is \(type), not rich_text/url") }
        } else { problems.append("No Local Directory property") }
        for name in ["domain", "Type", "Phase", "one liner", "summary", "tags"] {
            let field = live.property(named: name)
            say("\(name): " + (field.map { "\($0.definition["type"].display)" + (options($0).isEmpty ? "" : " (\(options($0).count) options)") } ?? "not in schema; left unmapped"))
        }
        let ratings = MetricDefinition.all.filter { live.property(named: $0.displayName) != nil }
        say("Rating properties mapped: \(ratings.count) of \(MetricDefinition.all.count)")
        let stored = Set(configured.schema.object.keys), current = Set(live.schema.object.keys)
        if stored != current {
            say("Stored schema differs from Notion: added \(current.subtracting(stored).sorted()), removed \(stored.subtracting(current).sorted()). Refresh the schema in Settings.")
        } else { say("Stored schema matches Notion") }

        // Existing pages, matched by exact directory as the bridge does.
        let (pages, complete) = try await client.graphPages(sourceID: live.id)
        let scratch = try ProjectGraphStore(database: Database(inMemory: true))
        try scratch.write("sources", [live]); try scratch.ingest(pages: pages, source: live)
        let remote = asRemote(try scratch.records()).filter { !$0.remoteArchived }
        say("Live pages: \(remote.count)\(complete ? "" : " (incomplete read)")")
        var byDirectory: [String: [ProjectGraphRecord]] = [:]
        for record in remote {
            let path = IdeaProjectBridge.directoryPath(record.value("Local Directory", source: live).display)
            if !path.isEmpty { byDirectory[path, default: []].append(record) }
        }
        let workspace = WorkspaceLocation.resolved.root
        let ideasRoot = workspace.appendingPathComponent("Ideas").canonicalPath
        say("Pages with a Local Directory: \(byDirectory.values.map(\.count).reduce(0, +)); under Ideas: \(byDirectory.keys.filter { $0.hasPrefix(ideasRoot + "/") }.count); "
            + "directories missing on disk: \(byDirectory.keys.filter { !FileManager.default.fileExists(atPath: $0) }.count)")
        let duplicated = byDirectory.filter { $0.value.count > 1 }
        say("Directories claimed by more than one page: \(duplicated.count)" + (duplicated.isEmpty ? "" : " — " + duplicated.keys.sorted().prefix(5).map { URL(fileURLWithPath: $0).lastPathComponent }.joined(separator: ", ")))
        if let field = live.property(named: "Status") {
            let ideaStatus = remote.filter { ProjectViewQuery.normalize($0.remote[field.id]?.display ?? "") == "idea" }
            say("Pages with Status = Idea: \(ideaStatus.count)")
        }

        // Linked local projects keep their identity: page ID first, directory second.
        let projects = try ProjectStore(database: Database(url: Database.preferredURL())).allRecords()
        let linked = projects.filter { $0.notionPageID != nil }
        let livePages = Dictionary(remote.compactMap { record in record.pageID.map { (ProjectGraph.normalizedID($0), record) } }, uniquingKeysWith: { first, _ in first })
        var found = 0, sameDirectory = 0, differentDirectory: [String] = []
        for project in linked {
            guard let page = livePages[ProjectGraph.normalizedID(project.notionPageID!)] else { continue }
            found += 1
            let path = IdeaProjectBridge.directoryPath(page.value("Local Directory", source: live).display)
            if path.isEmpty { continue }
            if URL(fileURLWithPath: path).canonicalPath == URL(fileURLWithPath: project.lastPath).canonicalPath { sameDirectory += 1 } else { differentDirectory.append(project.name) }
        }
        say("Local projects linked to Notion: \(linked.count); page found live: \(found); same Local Directory: \(sameDirectory); different: \(differentDirectory.count)"
            + (differentDirectory.isEmpty ? "" : " (e.g. \(differentDirectory.prefix(5).joined(separator: ", ")))"))

        // Real ideas: what classification would do, without doing it.
        guard let ideas = await BackgroundServiceClient.shared.ideas() else {
            say("Background service unavailable; idea matching skipped"); return problems.isEmpty ? 0 : 1
        }
        let immediate = ideas.filter { URL(fileURLWithPath: $0.canonicalPath).deletingLastPathComponent().canonicalPath == ideasRoot }
        let localGraph = asRemote(try store.records())
        var adopt = 0, create = 0, ambiguous = 0, bound = 0, promoted = 0
        for idea in immediate {
            do {
                let match = try IdeaProjectBridge.existing(serviceID: idea.id, path: idea.canonicalPath, records: localGraph, source: configured)
                if match == nil { create += 1 } else if match?.serviceRecordID == idea.id { bound += 1 } else { adopt += 1 }
                if let match, IdeaProjectBridge.promotedStatus(match, source: configured) != nil, match.serviceRecordID == idea.id { promoted += 1 }
            } catch { ambiguous += 1 }
        }
        let collisions = immediate.filter { IdeaProjectBridge.unlinkedTitleMatch(title: $0.title, records: localGraph, source: configured) != nil }
        say("Ideas whose title matches an unlinked Notion project (held for linking, never duplicated): \(collisions.count)" + (collisions.isEmpty ? "" : " — " + collisions.prefix(8).map(\.title).joined(separator: ", ")))
        say("Ideas folder items: \(immediate.count) of \(ideas.count) service ideas; classified as Potential Project: \(ideas.filter { $0.planning?.potential == .project }.count)")
        say("If classified now — would create a page: \(create), adopt an existing page by exact directory: \(adopt), already bound: \(bound), refused as ambiguous: \(ambiguous); awaiting promotion review: \(promoted)")
        for problem in problems { say("PROBLEM: \(problem)") }
        say(problems.isEmpty ? "Audit passed (read-only)" : "Audit found \(problems.count) problem(s)")
        return problems.isEmpty ? 0 : 1
    }

    // MARK: - Live round trip on one validation page

    static func roundTrip(client: NotionClient, store userStore: ProjectGraphStore, failing: NotionClient) async throws {
        let live = try await client.graphSource(try configuredProjects(userStore).id, kind: .projects)
        guard let statusField = live.property(named: "Status"), let directoryField = live.property(named: "Local Directory"),
              options(statusField).contains("Idea") else { throw Failure(message: "Run audit-idea-projects first: Status/Idea or Local Directory is missing.") }
        let promotedTo = options(statusField).first { $0 == "Active" } ?? options(statusField).first { ProjectViewQuery.normalize($0) != "idea" && !ProjectMetadata(status: $0).isTerminal }
        guard let promotedTo else { throw Failure(message: "Status has no non-terminal option besides Idea.") }

        let stamp = UUID().uuidString
        let title = "Better Workspace idea validation " + stamp
        let directory = try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("BetterWorkspace/IdeaValidation/" + stamp)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let ideaPath = directory.appendingPathComponent("Ideas/" + title).path, projectPath = directory.appendingPathComponent("Projects/" + title).path
        let store = try ProjectGraphStore(database: Database(url: directory.appendingPathComponent("validation.sqlite")))
        try store.write("sources", [live])
        // Existing option values only, so the validation never adds options to the schema.
        func existing(_ name: String) -> String? { live.property(named: name).flatMap { options($0).first } }
        let longSummary = String(repeating: "Potential-project summary segment. ", count: 80) // > 2,000 characters
        var details = IdeaProjectDetails(metadata: .init(domain: existing("domain"), phase: existing("Phase"), projectType: existing("Type")),
                                         oneLiner: "Validation one-liner", summary: longSummary)
        let serviceID = "validation-" + stamp
        guard let titleID = live.schema.object.first(where: { $0.value["type"].string == "title" })?.value["id"].string else { throw Failure(message: "Projects has no title property.") }
        let titleFilter = ProjectJSON(["filter": ["property": titleID, "title": ["equals": title]]])
        let coordinator = NotionProjectSync(store: store, client: client)
        func fetch(_ record: ProjectGraphRecord) async throws -> ProjectGraphRecord {
            let page = try await client.completeProperties(try await client.graphRequest("pages/" + record.pageID!))
            try store.ingest(pages: [page], source: live)
            return try store.record(id: record.id)!
        }
        func remote(_ record: ProjectGraphRecord, _ name: String) -> String {
            guard let field = live.property(named: name) else { return "" }
            return record.remote[field.id]?.display ?? ""
        }

        var validationError: Error?
        do {
            // 1. Create with Status = Idea and the idea's directory.
            var record = try IdeaProjectBridge.applying(serviceID: serviceID, title: title, path: ideaPath, details: details, tags: [], ratings: [:], to: nil, source: live)
            try store.save(record)
            try await coordinator.push(ids: [record.id], reviewed: [record])
            record = try await fetch(try store.record(id: record.id)!)
            try require(record.pageID != nil, "Create returned no page")
            try require(remote(record, "Status") == "Idea", "Status is \(remote(record, "Status")), not Idea")
            try require(IdeaProjectBridge.directoryPath(remote(record, "Local Directory")) == ideaPath, "Local Directory did not round trip")
            if live.property(named: "summary") != nil { try require(remote(record, "summary") == longSummary, "Long summary did not round trip intact") }
            if let domain = details.metadata.domain, live.property(named: "domain") != nil { try require(remote(record, "domain") == domain, "Domain did not round trip") }
            say("1. Created one page with Status = Idea, its directory and metadata (summary of \(longSummary.count) characters intact)")

            // 2. A later edit updates the same page; identity is the binding, not the title.
            details.oneLiner = "Validation one-liner, edited"
            let bound = try IdeaProjectBridge.existing(serviceID: serviceID, path: ideaPath, records: try store.records(), source: live)
            try require(bound?.id == record.id, "The binding did not find the created record")
            record = try IdeaProjectBridge.applying(serviceID: serviceID, title: title, path: ideaPath, details: details, tags: [], ratings: [:], to: bound, source: live)
            try store.save(record)
            try await coordinator.push(ids: [record.id], reviewed: [record], fields: [record.id: Set((record.serviceSnapshot ?? [:]).keys)])
            record = try await fetch(try store.record(id: record.id)!)
            if live.property(named: "one liner") != nil { try require(remote(record, "one liner") == details.oneLiner, "Edit did not reach the same page") }
            let titled = try await client.graphRequest("data_sources/\(live.id)/query", method: "POST", body: titleFilter)
            try require(titled["results"].array.count == 1, "Expected exactly one validation page, found \(titled["results"].array.count)")
            say("2. Edited the same page; exactly one page carries the validation title")

            // 3. Lost binding: a fresh database adopts the page by its exact directory only.
            let fresh = try ProjectGraphStore(database: Database(inMemory: true))
            try fresh.write("sources", [live])
            try fresh.ingest(pages: [try await client.completeProperties(try await client.graphRequest("pages/" + record.pageID!))], source: live)
            let adopted = try IdeaProjectBridge.existing(serviceID: "another-identity", path: ideaPath, records: asRemote(try fresh.records()), source: live)
            try require(adopted?.pageID == record.pageID, "Exact-directory adoption failed")
            try require(try IdeaProjectBridge.existing(serviceID: "another-identity", path: ideaPath + " (similar)", records: asRemote(try fresh.records()), source: live) == nil, "A similar path was adopted")
            say("3. Without a binding, the page is adopted only by its exact directory")

            // 4. Someone changes Status in Notion; the next read offers promotion and stops automatic sends.
            let statusType = statusField.definition["type"].display
            _ = try await client.graphRequest("pages/" + record.pageID!, method: "PATCH", body: ProjectJSON([
                "properties": [statusField.id: [statusType: ["name": promotedTo]]]]))
            record = try await fetch(record)
            try require(IdeaProjectBridge.promotedStatus(record, source: live) == promotedTo, "Status change to \(promotedTo) was not detected")
            try require(!IdeaProjectBridge.canAutomaticallySend(record, source: live), "Automatic sync continued after promotion status")
            let reapplied = try IdeaProjectBridge.applying(serviceID: serviceID, title: title, path: ideaPath, details: details, tags: [], ratings: [:], to: record, source: live)
            try require(!reapplied.changes.contains { $0.id == statusField.id && $0.state == .outgoing }, "A later save would send Status = Idea over the Notion change")
            say("4. Status changed to \(promotedTo) in Notion was detected as a promotion offer; automatic sends stopped")

            // 5. Approved promotion: keep the remote status, update only the directory.
            record.localProjectID = "validation-local-project"
            record.local[statusField.id] = record.remote[statusField.id]; record.baseline[statusField.id] = record.remote[statusField.id]
            record.set("Local Directory", value: directoryField.definition["type"].display == "url" ? .string(URL(fileURLWithPath: projectPath).absoluteString) : ProjectServiceBridge.text(projectPath), source: live)
            record.localPath = projectPath
            try store.save(record)
            let approved: Set<String> = [directoryField.id]
            var failed = false
            do { try await NotionProjectSync(store: store, client: failing).push(ids: [record.id], reviewed: [record], fields: [record.id: approved]) } catch { failed = true }
            try require(failed, "A send with invalid credentials succeeded")
            let pending = try store.record(id: record.id)!
            try require(pending.pageID == record.pageID && pending.localProjectID != nil && pending.localPath == projectPath, "The failed send lost the local promotion")
            say("5a. A failed send (invalid credentials) kept the local promotion and the page binding")
            try await coordinator.push(ids: [pending.id], reviewed: [pending], fields: [pending.id: approved])
            record = try await fetch(try store.record(id: pending.id)!)
            try require(IdeaProjectBridge.directoryPath(remote(record, "Local Directory")) == projectPath, "Directory update did not reach Notion")
            try require(remote(record, "Status") == promotedTo, "Promotion changed the Status chosen in Notion")
            let after = try await client.graphRequest("data_sources/\(live.id)/query", method: "POST", body: titleFilter)
            try require(after["results"].array.count == 1, "Promotion created another page")
            say("5b. Retry updated only the directory on the same page; Status stayed \(promotedTo); still one page")
        } catch { validationError = error }

        // Only this run's page ID is eligible for cleanup.
        var archived = false
        if var record = try store.records().first(where: { $0.pageID != nil }) {
            do {
                record = try await fetch(record)
                try require(record.title == title, "Cleanup refused an unexpected title")
                record.local = record.remote; record.baseline = record.remote; record.archiveRequested = true
                try store.save(record)
                try await coordinator.push(ids: [record.id], reviewed: [record])
                let page = try await client.graphRequest("pages/" + record.pageID!)
                archived = page["archived"].bool || page["in_trash"].bool
            } catch { say("Cleanup pending: \(error.localizedDescription)"); if validationError == nil { validationError = error } }
        }
        say("Validation page archived: \(archived ? "yes" : "no"). Recovery database: \(directory.appendingPathComponent("validation.sqlite").path)")
        if let validationError { throw validationError }
        try require(archived, "The validation page was not archived")
        say("Live idea-project validation passed")
    }
}
#endif
