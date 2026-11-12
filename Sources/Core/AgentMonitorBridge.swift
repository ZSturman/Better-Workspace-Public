import Foundation

/// The write half of the Local AI Agent Completion Monitor.
///
/// The monitor (a separate project) watches coding-agent sessions and decides, with a local
/// model, which tasks an agent finished and which follow-ups it left. It never renders or
/// edits `.bw.md` records itself: it hands this bridge a manifest, and every change goes
/// through `WorkItemService`, the same conflict-aware service the editor uses.
///
/// Guarantees, per operation:
/// - **create** writes a new task into the configured task queue. The id is derived from
///   the monitor's fingerprint, so a replay after a crash reports `exists` instead of
///   making a second copy; an existing record with the same fingerprint is also `exists`.
/// - **complete** / **progress** re-read the record by id and refuse (`stale`) when its
///   modification date differs from the one the analysis saw — a newer edit in Finder or
///   the app always wins. A record that is gone is `missing` and is never recreated.
///   Notes are appended to the body; nothing a person wrote is removed.
/// - **revert** restores the exact previous bytes of a record the monitor changed, or moves
///   a task it created to the Trash (recoverable), and only if the record is unchanged
///   since the monitor's own write.
///
/// The prior content of every changed record is returned so the monitor's history can undo it.
public enum AgentMonitorBridge {
    public struct Manifest: Codable, Sendable {
        public var version: Int
        public var projectPath: String
        public var source: Source?
        public var create: [Create]?
        public var complete: [Update]?
        public var progress: [Update]?
        public var revert: [Revert]?
    }

    public struct Source: Codable, Sendable {
        public var agent: String?
        public var agentName: String?
        public var sessionID: String?
        public var jobID: String?
        public var title: String?
        public var endedAt: String?
    }

    public struct Create: Codable, Sendable {
        public var id: String
        public var title: String
        public var body: String
        public var stage: String
        public var priority: String
        public var due: String?
        public var actionMetadata: WorkItemActionMetadata
    }

    public struct Update: Codable, Sendable {
        public var id: String
        public var path: String
        public var expectedModifiedAt: Double
        public var note: String
        public var markInProgress: Bool?
    }

    public struct Revert: Codable, Sendable {
        public var id: String
        public var path: String
        public var expectedModifiedAt: Double
        /// nil: the monitor created this record; reverting moves it to the Trash.
        public var previousContent: String?
    }

    public struct Receipt: Codable, Sendable, Equatable {
        public var op: String
        public var id: String
        /// applied, exists, stale, missing, not-open, invalid or error.
        public var result: String
        public var path: String?
        public var modifiedAt: Double?
        public var previousContent: String?
        public var message: String?
    }

    public struct NextAction: Codable, Sendable, Equatable {
        public var id: String
        public var title: String
        public var delegation: String?
        public var priority: String
    }

    public struct ProjectState: Codable, Sendable, Equatable {
        public var open: Int
        public var highOpen: Int
        public var nextAction: NextAction?
    }

    public struct Response: Codable, Sendable {
        public var receipts: [Receipt]
        public var project: ProjectState
    }

    public enum Failure: LocalizedError {
        case invalid(String)
        public var errorDescription: String? { if case .invalid(let message) = self { return message }; return nil }
    }

    /// - Parameters:
    ///   - queues: every work-queue folder (read to find records by id or fingerprint).
    ///   - taskQueue: where new tasks are created.
    ///   - trash: replaces the system Trash in tests.
    public static func apply(_ manifest: Manifest, workspace: WorkspaceLocation, queues: [URL], taskQueue: URL,
                             trash: URL? = nil, now: Date = Date()) throws -> Response {
        guard manifest.version == 1 else { throw Failure.invalid("Unsupported manifest version \(manifest.version)") }
        let projectsRoot = workspace.url(for: .projects).canonicalPath
        let parts = manifest.projectPath.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0] == "Projects", let name = parts.last.map(String.init),
              !name.isEmpty, !name.hasPrefix("_"), !name.hasPrefix("."),
              FileManager.default.fileExists(atPath: projectsRoot + "/" + name) else {
            throw Failure.invalid("“\(manifest.projectPath)” is not a project in this workspace")
        }
        let root = workspace.root.canonicalPath + "/"
        guard taskQueue.canonicalPath.hasPrefix(root),
              queues.allSatisfy({ $0.canonicalPath.hasPrefix(root) }) else {
            throw Failure.invalid("Work queues must be inside the workspace")
        }
        let service = WorkItemService()
        var items = scan(queues + [taskQueue], service: service)
        var receipts: [Receipt] = []

        func current(_ id: String) -> WorkItem? {
            guard let known = items.first(where: { $0.id == id }) else { return nil }
            return service.read(at: known.url).flatMap { $0.id == id ? $0 : nil }
        }
        func unchanged(_ item: WorkItem, _ expected: Double) -> Bool {
            guard let actual = item.modifiedAt?.timeIntervalSince1970 else { return false }
            return abs(actual - expected) <= 0.002
        }
        func remember(_ item: WorkItem) { items = WorkItemService.merged(items, upserting: [item], removingPaths: []) }
        func text(_ url: URL) -> String? { try? String(contentsOf: url, encoding: .utf8) }

        for create in manifest.create ?? [] {
            var receipt = Receipt(op: "create", id: create.id, result: "applied")
            if let existing = items.first(where: { $0.id == create.id || ($0.projectPath == manifest.projectPath
                    && $0.actionMetadata?.fingerprint == create.actionMetadata.fingerprint) }) {
                receipt.result = "exists"; receipt.id = existing.id; receipt.path = existing.url.path
                receipt.modifiedAt = existing.modifiedAt?.timeIntervalSince1970
                receipts.append(receipt); continue
            }
            let title = create.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty, title.count <= 120, create.actionMetadata.isValid,
                  let stage = WorkItemStage(rawValue: create.stage),
                  let priority = WorkItemPriority(rawValue: create.priority) else {
                receipt.result = "invalid"; receipt.message = "Title, stage, priority or action metadata is invalid"
                receipts.append(receipt); continue
            }
            var draft = WorkItem(id: create.id, kind: .task, title: title, stage: stage, priority: priority,
                                 projectPath: manifest.projectPath,
                                 dueDate: create.due.flatMap(parseDate), body: create.body,
                                 url: taskQueue.appendingPathComponent("placeholder"))
            draft.actionMetadata = create.actionMetadata
            do {
                let saved = try service.create(draft, in: taskQueue)
                remember(saved)
                receipt.path = saved.url.path; receipt.modifiedAt = saved.modifiedAt?.timeIntervalSince1970
            } catch {
                receipt.result = "error"; receipt.message = error.localizedDescription
            }
            receipts.append(receipt)
        }

        for (op, updates) in [("complete", manifest.complete ?? []), ("progress", manifest.progress ?? [])] {
            for update in updates {
                var receipt = Receipt(op: op, id: update.id, result: "applied", path: update.path)
                guard var item = current(update.id) else {
                    receipt.result = "missing"; receipts.append(receipt); continue
                }
                receipt.path = item.url.path
                guard item.projectPath == manifest.projectPath else {
                    receipt.result = "invalid"; receipt.message = "The task belongs to another project"
                    receipts.append(receipt); continue
                }
                guard unchanged(item, update.expectedModifiedAt) else {
                    receipt.result = "stale"; receipt.message = "Changed after the session was analysed"
                    receipts.append(receipt); continue
                }
                guard item.isOpen else { receipt.result = "not-open"; receipts.append(receipt); continue }
                let previous = text(item.url)
                let note = update.note.trimmingCharacters(in: .whitespacesAndNewlines)
                if !note.isEmpty, !item.body.contains(note) {
                    item.body = item.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ? note : item.body.trimmingCharacters(in: .newlines) + "\n\n" + note
                }
                if op == "complete" {
                    item.status = .completed
                    item.completedAt = now
                } else if update.markInProgress == true, item.status == .open {
                    item.status = .inProgress
                }
                do {
                    let saved = try service.update(item)
                    remember(saved)
                    receipt.modifiedAt = saved.modifiedAt?.timeIntervalSince1970
                    receipt.previousContent = previous
                } catch {
                    switch error as? WorkItemService.WorkItemError {
                    case .missing?: receipt.result = "missing"
                    case .changedOnDisk?: receipt.result = "stale"
                    case nil: receipt.result = "error"
                    }
                    receipt.message = error.localizedDescription
                }
                receipts.append(receipt)
            }
        }

        for revert in manifest.revert ?? [] {
            var receipt = Receipt(op: "revert", id: revert.id, result: "applied", path: revert.path)
            guard let item = current(revert.id) else { receipt.result = "missing"; receipts.append(receipt); continue }
            receipt.path = item.url.path
            guard item.projectPath == manifest.projectPath, unchanged(item, revert.expectedModifiedAt) else {
                receipt.result = "stale"; receipt.message = "Changed after the monitor's write; left as it is"
                receipts.append(receipt); continue
            }
            do {
                if let previous = revert.previousContent {
                    let staged = item.url.deletingLastPathComponent()
                        .appendingPathComponent(WorkItemService.stagingPrefix + UUID().uuidString + WorkItemService.stagingSuffix)
                    try Data(previous.utf8).write(to: staged, options: .withoutOverwriting)
                    do { _ = try FileManager.default.replaceItemAt(item.url, withItemAt: staged) }
                    catch { try? FileManager.default.removeItem(at: staged); throw error }
                    if let restored = service.read(at: item.url) {
                        remember(restored); receipt.modifiedAt = restored.modifiedAt?.timeIntervalSince1970
                    }
                } else {
                    receipt.path = try service.trash(item, into: trash)?.path
                    items.removeAll { $0.id == item.id }
                }
            } catch {
                receipt.result = "error"; receipt.message = error.localizedDescription
            }
            receipts.append(receipt)
        }

        let project = items.filter { $0.projectPath == manifest.projectPath && $0.kind == .task }
        let next = WorkItemRecommendation.nextAction(in: project, allItems: items)
        let state = ProjectState(
            open: project.filter(\.isOpen).count,
            highOpen: project.filter { $0.isOpen && ($0.actionMetadata.map { ["P0", "P1"].contains($0.priority) } ?? ($0.priority == .high)) }.count,
            nextAction: next.map { NextAction(id: $0.id, title: $0.title, delegation: $0.actionMetadata?.delegation, priority: $0.actionPriorityLabel) })
        return Response(receipts: receipts, project: state)
    }

    /// Records in the given folders only — never a walk of the whole workspace.
    static func scan(_ folders: [URL], service: WorkItemService) -> [WorkItem] {
        var seen = Set<String>()
        var all: [WorkItem] = []
        for folder in folders where seen.insert(folder.canonicalPath).inserted {
            all += service.items(under: folder)
        }
        return WorkItemService.indexed(all)
    }

    static func parseDate(_ raw: String) -> Date? {
        if let date = ISO8601DateFormatter().date(from: raw) { return date }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        for format in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: raw) { return date }
        }
        return nil
    }
}
