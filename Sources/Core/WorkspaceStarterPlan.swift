import Foundation
import Darwin

/// A shallow, reviewed setup action. Existing contents and metadata are never read.
public struct WorkspaceStarterPlan: Equatable, Sendable {
    public struct Category: Identifiable, Equatable, Sendable {
        public let name: String
        public let purpose: String
        public var id: String { name }
    }
    public static let categories: [Category] = [
        .init(name: "Projects", purpose: "Project folders and their existing files"),
        .init(name: "Ideas", purpose: "Early ideas and potential projects"),
        .init(name: "To Do", purpose: "Tasks and next actions"),
        .init(name: "Features", purpose: "Plans for capabilities to build"),
        .init(name: "Milestones", purpose: "Checkpoints and outcomes"),
        .init(name: "For Reference", purpose: "Notes and reference material")
    ]
    public enum Status: String, Sendable { case create, reuse, blocked }
    public struct Entry: Identifiable, Equatable, Sendable {
        public let category: Category
        public let status: Status
        public let identity: FileIdentity?
        public let explanation: String
        public var id: String { category.id }
    }
    public struct Outcome: Sendable {
        public let created: [String]
        public let issue: String?
    }
    public let root: URL
    public let rootIdentity: FileIdentity
    private let rootCreatedAt: Date
    public let entries: [Entry]

    public static func preview(root: URL) throws -> Self {
        let root = root.standardizedFileURL
        try WorkspaceLocalPathChecks.rejectSymlinks(to: root)
        let values = try root.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey, .creationDateKey])
        guard values.isDirectory == true, values.isPackage != true,
              let identity = FileIdentityResolver.identity(of: root), let created = values.creationDate else {
            throw WorkspaceReplicaError.invalid("Choose an existing ordinary Workspace folder.")
        }
        let names = try FileManager.default.contentsOfDirectory(atPath: root.path)
        let entries = categories.map { category -> Entry in
            let url = root.appendingPathComponent(category.name)
            let matches = names.filter { $0.compare(category.name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
            guard matches.isEmpty else {
                let details = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey])
                if matches == [category.name], details?.isDirectory == true,
                   details?.isSymbolicLink != true, details?.isPackage != true,
                   let id = FileIdentityResolver.identity(of: url) {
                    return .init(category: category, status: .reuse, identity: id, explanation: "Keep existing folder and all its contents")
                }
                return .init(category: category, status: .blocked, identity: nil,
                             explanation: "An existing file, link, package or matching name is preserved. Skip this category.")
            }
            return .init(category: category, status: .create, identity: nil, explanation: "Create empty folder")
        }
        return .init(root: root, rootIdentity: identity, rootCreatedAt: created, entries: entries)
    }

    /// Pins the reviewed root and uses exclusive mkdirat; a late file/link is never
    /// followed or replaced. Partial success is reported, never rolled back by deletion.
    public func apply(selected: Set<String>) throws -> Outcome {
        guard !selected.isEmpty, selected.isSubset(of: Set(entries.filter { $0.status == .create }.map(\.id))) else {
            throw WorkspaceReplicaError.invalid("Select only missing folders from this preview.")
        }
        guard try Self.preview(root: root) == self else { throw WorkspaceReplicaError.changed }
        let descriptor = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw WorkspaceReplicaError.invalid("The Workspace folder cannot be opened safely. Review it again.") }
        defer { close(descriptor) }
        var status = stat()
        guard fstat(descriptor, &status) == 0,
              FileIdentity(volume: String(status.st_dev), fileID: UInt64(status.st_ino)) == rootIdentity else { throw WorkspaceReplicaError.changed }
        var created: [String] = []
        for entry in entries where selected.contains(entry.id) {
            do {
                try WorkspaceLocalPathChecks.rejectSymlinks(to: root)
                guard FileIdentityResolver.identity(of: root) == rootIdentity else { throw WorkspaceReplicaError.changed }
                guard mkdirat(descriptor, entry.id, 0o755) == 0 else {
                    throw WorkspaceReplicaError.invalid("A folder could not be created or its destination changed. Review the remaining folders again.")
                }
                created.append(entry.id)
            } catch { return .init(created: created, issue: error.localizedDescription) }
        }
        return .init(created: created, issue: nil)
    }
}
