import Foundation

/// The optional places a piece of work can belong: a project, features, milestones.
///
/// Every one of them is optional. A capture filed as a feature from the menu bar with
/// no project is still a feature; it shows in its queue's Needs Attention section until
/// someone says where it goes. The same value is chosen on the Mac and on the phone.
public struct WorkItemLinks: Codable, Hashable, Sendable {
    /// Workspace-relative project directory, e.g. `Projects/Better Workspace`.
    public var projectPath: String?
    public var featureIDs: [String]
    public var milestoneIDs: [String]

    public init(projectPath: String? = nil, featureIDs: [String] = [], milestoneIDs: [String] = []) {
        let trimmed = projectPath?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.projectPath = trimmed?.isEmpty == false ? trimmed : nil
        self.featureIDs = featureIDs
        self.milestoneIDs = milestoneIDs
    }

    public static let none = WorkItemLinks()
    public var isEmpty: Bool { projectPath == nil && featureIDs.isEmpty && milestoneIDs.isEmpty }

    /// Which links make sense for a kind: a feature does not belong to a feature, nor a
    /// milestone to a milestone. Anything else is offered.
    public static func offersFeature(for kind: WorkItemKind) -> Bool { kind == .task || kind == .milestone }
    public static func offersMilestone(for kind: WorkItemKind) -> Bool { kind == .task || kind == .feature }

    /// Drops links a kind cannot hold, so switching a draft from task to feature does not
    /// leave the feature linked to a feature.
    public func applicable(to kind: WorkItemKind) -> WorkItemLinks {
        WorkItemLinks(projectPath: projectPath,
                      featureIDs: Self.offersFeature(for: kind) ? featureIDs : [],
                      milestoneIDs: Self.offersMilestone(for: kind) ? milestoneIDs : [])
    }

    /// The JSON a phone capture carries them in; `nil` when there is nothing to carry.
    public var encoded: String? {
        guard isEmpty == false, let data = try? JSONEncoder().encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public static func decode(_ text: String?) -> WorkItemLinks? {
        guard let data = text?.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(WorkItemLinks.self, from: data)
    }
}

extension WorkItem {
    public var links: WorkItemLinks {
        get { WorkItemLinks(projectPath: projectPath, featureIDs: featureIDs, milestoneIDs: milestoneIDs) }
        set { projectPath = newValue.projectPath; featureIDs = newValue.featureIDs; milestoneIDs = newValue.milestoneIDs }
    }

    /// Open features and milestones that do not say which project they are for. They
    /// are real work, not errors, but they are listed first in their queue until placed.
    public var needsAttention: Bool {
        isOpen && (kind == .feature || kind == .milestone) && (projectPath ?? "").isEmpty
    }
}

/// Text notes sitting loose in a work-queue folder.
///
/// A queue lists `.bw.md` work items only, so a note filed there before captures
/// became work items is invisible in the app. These are offered for conversion.
public enum StrandedQueueNotes {
    public static let textExtensions: Set<String> = ["md", "markdown", "txt"]

    public static func isStranded(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        guard name.hasPrefix(".") == false, name.hasSuffix(WorkItemService.fileSuffix) == false,
              NoiseFilter.isForeignMetadata(name: name) == false
        else { return false }
        return textExtensions.contains(url.pathExtension.lowercased())
    }

    /// Notes directly inside `folder`; `nil` when the folder could not be read, which is
    /// not the same as having none.
    public static func notes(in folder: URL) -> [URL]? {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return nil }
        return names.map { folder.appendingPathComponent($0) }
            .filter { url in
                var isDirectory: ObjCBool = false
                return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
                    && isDirectory.boolValue == false && isStranded(url)
            }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }
}

/// What a captured note becomes as a work item: its name is the title and its text the
/// notes, without a leading heading that only repeats the title.
public enum WorkItemPromotion {
    public static func content(of url: URL) -> (title: String, body: String) {
        let title = url.deletingPathExtension().lastPathComponent
        let text = StrandedQueueNotes.textExtensions.contains(url.pathExtension.lowercased())
            ? (try? String(contentsOf: url, encoding: .utf8)) ?? "" : ""
        return (title, body(text, title: title))
    }

    public static func body(_ text: String, title: String) -> String {
        var lines = text.components(separatedBy: "\n")
        if let first = lines.first?.trimmingCharacters(in: .whitespaces), first.hasPrefix("#") {
            let heading = first.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)
            if heading == title { lines.removeFirst() }
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

extension MobileWorkItem {
    public var links: WorkItemLinks {
        WorkItemLinks(projectPath: projectPath, featureIDs: featureIDs ?? [], milestoneIDs: milestoneIDs ?? [])
    }

    /// The phone's view of `WorkItem.needsAttention`.
    public var needsAttention: Bool {
        status != .completed && (kind == .feature || kind == .milestone) && (projectPath ?? "").isEmpty
    }
}
