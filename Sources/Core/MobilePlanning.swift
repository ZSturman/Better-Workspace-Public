import Foundation

public struct MobileIdeaAttachment: Identifiable, Hashable, Sendable, Codable {
    public let path: String
    public let name: String
    public let isDirectory: Bool
    public var id: String { path }
    public init(path: String, name: String, isDirectory: Bool = false) {
        self.path = path; self.name = name; self.isDirectory = isDirectory
    }
}

/// Complete, reviewable planning changes. Originals travel with updates so the Mac
/// can refuse a stale edit without trusting a disposable CloudKit revision.
public struct MobilePlanningEdit: Identifiable, Hashable, Sendable, Codable {
    /// Deletion commands move the selected item to the Mac’s recoverable Trash.
    public enum Operation: String, Codable, Sendable { case previewIdea, saveIdeaPlanning, promoteIdea, scheduleCapture, saveProject, previewProject, saveWork, saveIdea, createIdea, createProject, trashWork, trashIdea, trashProject, trashEntry, reviewInbox, fileCapture }
    public let id: UUID
    public var operation: Operation
    public var title: String
    public var description: String
    public var work: MobileWorkItem?
    public var originalWork: MobileWorkItem?
    public var originalIdea: MobileIdea?
    public var originalEntry: MobileWorkspaceEntry?
    public var tagIDs: Set<String>
    public var inboxReview: OverviewInboxCommand?
    public var captureFiling: WidgetCaptureFiling?
    public var projectEdit: MobileProjectEdit?
    public var captureReview: MobileCaptureReview?
    public var ideaPlanning: IdeaPlanning?
    public var ideaPromotion: IdeaPromotionKind?

    public init(id: UUID = UUID(), operation: Operation, title: String, description: String = "",
                work: MobileWorkItem? = nil, originalWork: MobileWorkItem? = nil,
                originalIdea: MobileIdea? = nil, originalEntry: MobileWorkspaceEntry? = nil, tagIDs: Set<String> = [], inboxReview: OverviewInboxCommand? = nil, captureFiling: WidgetCaptureFiling? = nil, projectEdit: MobileProjectEdit? = nil, captureReview: MobileCaptureReview? = nil, ideaPlanning: IdeaPlanning? = nil, ideaPromotion: IdeaPromotionKind? = nil) {
        self.ideaPlanning = ideaPlanning; self.ideaPromotion = ideaPromotion
        self.captureReview = captureReview
        self.projectEdit = projectEdit
        self.id = id; self.operation = operation; self.title = title; self.description = description
        self.work = work; self.originalWork = originalWork; self.originalIdea = originalIdea; self.originalEntry = originalEntry; self.tagIDs = tagIDs; self.inboxReview = inboxReview; self.captureFiling = captureFiling
    }
}

public struct MobilePlanningReceipt: Sendable {
    public let id: UUID
    public let applied: Bool
    public let message: String?
    public let workModifiedAt: Date?
    public let appliedAt: Date?
}

/// Only app-private drafts are stored here. Entries remain until the Mac reports a
/// result, even after CloudKit accepts the immutable command.
public final class MobilePlanningDraftStore {
    private let defaults: UserDefaults
    private let key = "BWMobilePlanningDrafts"
    private let ledger: WidgetCommandStore?
    private var loadedIDs: Set<UUID> = []
    public init(defaults: UserDefaults = .standard, ledger: WidgetCommandStore? = nil) { self.defaults = defaults; self.ledger = ledger }
    public func load() -> [MobilePlanningEdit] {
        if let ledger {
            let drafts = ((try? ledger.records()) ?? []).filter { !$0.settled && $0.state != .cancelled }.compactMap(\.edit)
            loadedIDs = Set(drafts.map(\.id)); return drafts
        }
        guard let data = defaults.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([MobilePlanningEdit].self, from: data)) ?? []
    }
    public func save(_ edits: [MobilePlanningEdit]) {
        if let ledger {
            for edit in edits { try? ledger.append(.planning(edit)) }
            try? ledger.settle(loadedIDs.subtracting(edits.map(\.id)))
            loadedIDs.formUnion(edits.map(\.id)); return
        }
        if let data = try? JSONEncoder().encode(edits) { defaults.set(data, forKey: key) }
    }
}

/// Filesystem operations invoked only by an explicit mobile Save. No directory
/// traversal, foreign metadata, or remote Notion writes are permitted here.
public enum MobilePlanningFiles {
    public static let maximumTextBytes = 32_768
    public enum Error: LocalizedError {
        case invalid(String), conflict
        public var errorDescription: String? {
            switch self {
            case .invalid(let message): return message
            case .conflict: return "This record changed on the Mac. Refresh and review your saved phone draft before saving again."
            }
        }
    }

    public static func resolve(_ path: String, workspace: WorkspaceLocation) throws -> URL {
        guard let normalized = MobileWorkspacePath.normalizedRelative(path),
              !normalized.split(separator: "/").contains(where: { NoiseFilter.isForeignMetadata(name: String($0)) || NoiseFilter.foreignTopLevelDirectories.contains(String($0)) || $0.hasPrefix(".") })
        else { throw Error.invalid("That location cannot be edited.") }
        // Foundation does not resolve a symlink ancestor when the trailing file does
        // not exist yet. Check each existing component before creating anything.
        var ancestor = workspace.root
        for component in normalized.split(separator: "/") {
            ancestor.appendPathComponent(String(component))
            var info = stat()
            if lstat(ancestor.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFLNK {
                throw Error.invalid("Choose an ordinary workspace location instead of a symbolic link.")
            }
        }
        let url = workspace.root.appendingPathComponent(normalized).canonical
        guard url.resolvingSymlinksInPath().canonicalPath.hasPrefix(workspace.root.resolvingSymlinksInPath().canonicalPath + "/") else {
            throw Error.invalid("That location is outside the workspace.")
        }
        return url
    }

    public static func normalizedWorkBody(_ text: String) -> String {
        let text = text.replacingOccurrences(of: "\r\n", with: "\n")
        return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : text.trimmingCharacters(in: .newlines)
    }

    public static func matches(_ item: WorkItem, original: MobileWorkItem, workspace: WorkspaceLocation? = nil, respectModifiedDate: Bool = true) -> Bool {
        var projectPath = item.projectPath
        if let workspace, let raw = projectPath, raw.hasPrefix(workspace.root.canonicalPath + "/") {
            projectPath = String(raw.dropFirst(workspace.root.canonicalPath.count + 1))
        }
        func dateToken(_ value: Date?) -> Double? { value.map { floor($0.timeIntervalSince1970) } }
        return
        item.id == original.id && item.title == original.title && item.kind == original.kind
            && item.status == original.status && item.stage == original.stage && item.priority == original.priority
            && projectPath == original.projectPath && dateToken(item.dueDate) == dateToken(original.dueDate)
            && (!respectModifiedDate || original.body != nil || original.modifiedAt == nil || item.modifiedAt == original.modifiedAt)
            && (original.body == nil || item.body == normalizedWorkBody(original.body ?? ""))
            && (original.actionMetadata == nil || item.actionMetadata == original.actionMetadata)
            && (original.featureIDs == nil || item.featureIDs == original.featureIDs)
            && (original.milestoneIDs == nil || item.milestoneIDs == original.milestoneIDs)
            && (original.dependencyIDs == nil || item.dependencyIDs == original.dependencyIDs)
    }

    /// The record a phone edit names: the file at its last-known path, or — when that
    /// path is stale — the record carrying the same stable ID. A path goes stale when a
    /// phone-created item lands in its project's `Work` folder rather than the
    /// placeholder path the phone showed, or when someone moved the file in Finder.
    /// Answers nil only when neither exists.
    public static func locateWork(_ original: MobileWorkItem, among known: [WorkItem],
                                  workspace: WorkspaceLocation, service: WorkItemService) throws -> WorkItem? {
        let url = try resolve(original.path, workspace: workspace)
        if let item = service.read(at: url), item.id == original.id { return item }
        guard let moved = known.first(where: { $0.id == original.id }) else { return nil }
        // Re-read: the caller's list may predate an edit made since, and the comparison
        // that follows must see what is on disk now.
        return service.read(at: moved.url).flatMap { $0.id == original.id ? $0 : nil }
    }

    /// Moves the record named by a `trashWork` edit to the Trash (`into` replaces the
    /// system Trash in an isolated test). Refuses a record changed since the phone last
    /// saw it. A record that is already gone counts as done, so a retry after a lost
    /// receipt does not turn into an error. Returns the record that was trashed.
    @discardableResult
    public static func trashWork(_ edit: MobilePlanningEdit, among known: [WorkItem], workspace: WorkspaceLocation,
                                 service: WorkItemService, into folder: URL? = nil) throws -> WorkItem? {
        guard edit.operation == .trashWork, let original = edit.originalWork else {
            throw Error.invalid("The work record to delete is missing.")
        }
        guard let item = try locateWork(original, among: known, workspace: workspace, service: service) else { return nil }
        guard matches(item, original: original, workspace: workspace) else { throw Error.conflict }
        guard item.url.canonicalPath.hasPrefix(workspace.root.canonicalPath + "/") else { throw Error.invalid("That work record is outside the workspace.") }
        let path = String(item.url.canonicalPath.dropFirst(workspace.root.canonicalPath.count + 1))
        _ = try WorkspaceTrash.resolve(path, workspace: workspace)
        try service.trash(item, into: folder)
        return item
    }

    /// Whether a downloaded index already shows an applied edit's result, so the phone
    /// can stop overlaying its own copy. For an update it is enough that the record no
    /// longer looks like the original: the index has caught up to this edit or a later one.
    public static func index(_ snapshot: MobileWorkspaceSnapshot, reflects edit: MobilePlanningEdit) -> Bool {
        switch edit.operation {
        case .previewIdea: return true
        case .saveIdeaPlanning:
            guard let original = edit.originalIdea, let current = snapshot.ideas.first(where: { $0.path == original.path }) else { return false }
            return current.planning == edit.ideaPlanning || current.planning != original.planning
        case .promoteIdea:
            return !snapshot.ideas.contains { $0.path == edit.originalIdea?.path }
        case .scheduleCapture: return true // Scheduling has no optimistic filesystem overlay.
        case .previewProject: return true // This read-only request is settled by its receipt.
        case .saveProject:
            guard let change = edit.projectEdit, let details = snapshot.entries.first(where: { $0.path == change.original.path })?.projectDetails else { return false }
            return details.ratings == change.ratings && (details.oneLiner ?? "") == change.oneLiner && (details.summary ?? "") == change.summary
        case .fileCapture: return false // Settled by its explicit Mac receipt.
        case .reviewInbox:
            // Settled once the Mac publishes a digest checked after the decision that no
            // longer offers the same item.
            guard let overview = snapshot.overview else { return false }
            let items = overview.reviewItems ?? overview.inboxItem.map { [$0] } ?? []
            if edit.inboxReview?.action == .prioritize {
                return items.first { $0.id == edit.inboxReview?.item.id }?.priority == edit.inboxReview?.priority
            }
            return !items.contains { $0.id == edit.inboxReview?.item.id }
        case .trashIdea, .trashProject, .trashEntry:
            guard let entry = edit.originalEntry else { return false }
            return !snapshot.entries.contains { $0.path == entry.path || $0.path.hasPrefix(entry.path + "/") }
                && !snapshot.ideas.contains { $0.path == entry.path || $0.path.hasPrefix(entry.path + "/") }
                && !snapshot.workItems.contains { $0.path == entry.path || $0.path.hasPrefix(entry.path + "/") }
        case .trashWork:
            guard let original = edit.originalWork else { return true }
            return snapshot.workItems.contains { $0.id == original.id } == false
        case .saveWork:
            guard let work = edit.work else { return true }
            guard let current = snapshot.workItems.first(where: { $0.id == work.id }) else {
                // An applied update whose record has gone was deleted since; keeping the
                // draft would bring a deleted task back. A creation may simply not be
                // indexed yet.
                return edit.originalWork != nil
            }
            guard let original = edit.originalWork else { return true }
            return sameEditableFields(current, original) == false || sameEditableFields(current, work)
        case .saveIdea:
            guard let original = edit.originalIdea, let current = snapshot.ideas.first(where: { $0.id == original.id }) else { return false }
            return current.title == edit.title && (current.description ?? "") == edit.description
                || current.title != original.title || current.description != original.description
        case .createIdea:
            return snapshot.ideas.contains { $0.path.contains(edit.id.uuidString) }
        case .createProject:
            return snapshot.entries.contains { $0.path == projectPath(for: edit) }
        }
    }

    static func sameEditableFields(_ lhs: MobileWorkItem, _ rhs: MobileWorkItem) -> Bool {
        func day(_ date: Date?) -> Double? { date.map { floor($0.timeIntervalSince1970) } }
        return lhs.title == rhs.title && lhs.kind == rhs.kind && lhs.status == rhs.status && lhs.stage == rhs.stage
            && lhs.priority == rhs.priority && lhs.projectPath == rhs.projectPath && day(lhs.dueDate) == day(rhs.dueDate)
            // Links count only where `rhs` says something: nil is "not changed here".
            && (rhs.featureIDs.map { (lhs.featureIDs ?? []) == $0 } ?? true)
            && (rhs.milestoneIDs.map { (lhs.milestoneIDs ?? []) == $0 } ?? true)
    }

    public static func validate(_ edit: MobilePlanningEdit) throws {
        if edit.operation == .previewIdea {
            guard let original = edit.originalIdea, MobileWorkspacePath.normalizedRelative(original.path) == original.path,
                  original.path.hasPrefix("Ideas/"), original.path.split(separator: "/").count == 2 else { throw Error.invalid("Choose a local idea to preview.") }
        }
        if edit.operation == .saveIdeaPlanning || edit.operation == .promoteIdea {
            guard let original = edit.originalIdea, MobileWorkspacePath.normalizedRelative(original.path) == original.path,
                  original.path.hasPrefix("Ideas/"), original.path.split(separator: "/").count == 2 else { throw Error.invalid("Choose an immediate child of Ideas.") }
            if edit.operation == .saveIdeaPlanning {
                guard let planning = edit.ideaPlanning, original.serviceID != nil else { throw Error.invalid("Wait for the updated Mac and idea service to publish this idea.") }
                try planning.validate(original: original.planning)
            } else if edit.ideaPromotion == nil || original.modifiedAt == nil || original.serviceID == nil { throw Error.invalid("Choose a promotion destination and refresh the idea first.") }
        }
        if edit.operation == .scheduleCapture {
            guard let review = edit.captureReview, (1...5).contains(review.priority),
                  review.capture.name == URL(fileURLWithPath: review.capture.name).lastPathComponent,
                  !review.capture.name.hasPrefix("."), !review.capture.name.isEmpty,
                  review.until?.timeIntervalSince1970.isFinite != false else { throw Error.invalid("Choose an inbox capture and priority from 1 to 5.") }
        }
        if edit.operation == .saveProject {
            guard let change = edit.projectEdit else { throw Error.invalid("Missing project details.") }
            try change.validate()
        }
        if edit.operation == .previewProject {
            guard let entry = edit.originalEntry, entry.parentPath == "Projects", entry.isDirectory,
                  MobileWorkspacePath.normalizedRelative(entry.path) == entry.path, entry.path.split(separator: "/").count == 2 else {
                throw Error.invalid("Choose a local project to preview.")
            }
        }
        if [.trashIdea, .trashProject, .trashEntry].contains(edit.operation) {
            guard let entry = edit.originalEntry, entry.modifiedAt != nil,
                  MobileWorkspacePath.normalizedRelative(entry.path) == entry.path,
                  entry.path.split(separator: "/").count >= 2,
                  edit.operation == .trashEntry || (entry.path.split(separator: "/").count == 2
                    && entry.parentPath == (edit.operation == .trashIdea ? "Ideas" : "Projects")),
                  entry.parentPath == String(entry.path.split(separator: "/").dropLast().joined(separator: "/")),
                  edit.operation != .trashProject || entry.isDirectory else {
                throw Error.invalid("Refresh this item before deleting it.")
            }
        }
        if edit.operation == .fileCapture {
            guard let filing = edit.captureFiling, !filing.capture.name.hasPrefix("."), filing.capture.name == URL(fileURLWithPath: filing.capture.name).lastPathComponent,
                  MobileWorkspacePath.normalizedRelative(filing.destination) == filing.destination, filing.destination.split(separator: "/").count == 1 else {
                throw Error.invalid("Choose a published Workspace folder for this capture.")
            }
        }
        if edit.operation == .reviewInbox {
            guard let command = edit.inboxReview, MobileWorkspacePath.normalizedRelative(command.item.path) == command.item.path,
                  command.item.category != "To Organize", command.item.preview.utf8.count <= maximumTextBytes,
                  command.action != .snooze || command.until != nil,
                  command.action != .prioritize || command.priority.map({ (1...5).contains($0) }) == true else { throw Error.invalid("This inbox decision is incomplete or requires the Mac.") }
        }
        guard !edit.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              edit.title.utf8.count <= 512, !edit.title.contains("\n"),
              edit.description.utf8.count <= maximumTextBytes,
              (edit.work?.body?.utf8.count ?? 0) <= maximumTextBytes else {
            throw Error.invalid("Enter a title and keep the description under 32 KB.")
        }
    }

    public static func projectPath(for edit: MobilePlanningEdit) -> String {
        // The generated suffix makes retries address exactly the same new directory
        // without claiming an existing project with a matching title.
        "Projects/" + CaptureNaming.safeFilename(edit.title) + " (" + edit.id.uuidString + ")"
    }

    public static func createProject(_ edit: MobilePlanningEdit, workspace: WorkspaceLocation) throws -> URL {
        try validate(edit)
        let root = try resolve("Projects", workspace: workspace)
        guard (try? root.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
            throw Error.invalid("Create the Projects area on the Mac first.")
        }
        let url = try resolve(projectPath(for: edit), workspace: workspace)
        // A UUID-addressed folder is safe to revisit after a lost acknowledgement.
        if FileManager.default.fileExists(atPath: url.path) {
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
                throw Error.invalid("The new project location is already a file.")
            }
        } else {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        }
        return url
    }

    public static func ideaText(title: String, description: String) -> String { "# \(title)\n\n\(description)" }
    public static func splitIdeaText(_ text: String, fallbackTitle: String) -> (String, String) {
        guard text.hasPrefix("# "), let end = text.firstIndex(of: "\n") else { return (fallbackTitle, text) }
        return (String(text[text.index(text.startIndex, offsetBy: 2)..<end]),
                String(text[text.index(after: end)...]).trimmingCharacters(in: .newlines))
    }

    public static func createIdea(_ edit: MobilePlanningEdit, workspace: WorkspaceLocation) throws -> URL {
        try validate(edit)
        let root = try resolve("Ideas", workspace: workspace)
        guard (try? root.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
            throw Error.invalid("Create the Ideas area on the Mac first.")
        }
        let path = "Ideas/" + CaptureNaming.safeFilename(edit.title) + " (" + edit.id.uuidString + ").md"
        let url = try resolve(path, workspace: workspace)
        let text = ideaText(title: edit.title, description: edit.description)
        if FileManager.default.fileExists(atPath: url.path) {
            guard try String(contentsOf: url, encoding: .utf8) == text else { throw Error.conflict }
        } else {
            try Data(text.utf8).write(to: url, options: .withoutOverwriting)
        }
        return url
    }
}
