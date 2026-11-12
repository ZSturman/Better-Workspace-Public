import Foundation

/// Explicit file mutations that the Ideas workspace permits. Ideas are the one
/// organized area that doubles as a small working notebook: people can add material
/// to an idea and edit its text without leaving Better Workspace. All other areas
/// remain browse-only.
public final class IdeaFileService: @unchecked Sendable {
    public enum Error: LocalizedError {
        case outsideIdeas
        case emptyName

        public var errorDescription: String? {
            switch self {
            case .outsideIdeas: return "That location is outside the Ideas folder."
            case .emptyName: return "Enter a name first."
            }
        }
    }

    private let ideasRoot: URL
    private let fileManager = FileManager.default

    public init(ideasRoot: URL) {
        self.ideasRoot = ideasRoot.canonical
    }

    @discardableResult
    public func createNote(named name: String, in directory: URL? = nil) throws -> URL {
        let target = try validatedDirectory(directory ?? ideasRoot)
        let base = try sanitizedName(name)
        let url = uniqueURL(in: target, base: base, extension: "md")
        try "# \(base)\n\n".write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// Creates a top-level idea with its own editable Markdown note.
    public func createIdea(named name: String) throws -> URL {
        let root = try validatedDirectory(ideasRoot)
        let title = try sanitizedName(name)
        let base = CaptureNaming.safeFilename(title)
        let folder = CaptureNaming.uniqueURL(in: root, base: base, extension: "")
        try Self.publishFolder(at: folder) { staged in
            let note = staged.appendingPathComponent(base).appendingPathExtension("md")
            try Data("# \(title)\n\n".utf8).write(to: note, options: .withoutOverwriting)
        }
        return folder
    }

    /// Build a complete folder on the same volume before exposing it at its final
    /// name. Cleanup only touches the private staging directory.
    static func publishFolder(at destination: URL, beforePublish: ((URL, FileIdentity) throws -> Void)? = nil,
                              build: (URL) throws -> Void) throws {
        let fm = FileManager.default
        let parent = destination.deletingLastPathComponent()
        try WorkspaceLocalPathChecks.rejectSymlinks(to: parent)
        guard let identity = FileIdentityResolver.identity(of: parent) else { throw CocoaError(.fileNoSuchFile) }
        let staging = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                 appropriateFor: parent, create: true)
        var checkpointed = false
        defer { if !checkpointed { try? fm.removeItem(at: staging) } }
        let folder = staging.appendingPathComponent("Idea", isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: false)
        try build(folder)
        try WorkspaceLocalPathChecks.rejectSymlinks(to: parent)
        guard FileIdentityResolver.identity(of: parent) == identity else { throw CocoaError(.fileNoSuchFile) }
        try beforePublish?(folder, identity)
        checkpointed = beforePublish != nil
        guard renameatx_np(AT_FDCWD, folder.path, AT_FDCWD, destination.path, UInt32(RENAME_EXCL)) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        checkpointed = false
    }

    @discardableResult
    public func createFolder(named name: String, in directory: URL? = nil) throws -> URL {
        let target = try validatedDirectory(directory ?? ideasRoot)
        let url = uniqueURL(in: target, base: try sanitizedName(name), extension: "")
        try fileManager.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    /// Copies selected Finder items, preserving the originals. The destination is made
    /// unique rather than replacing an existing idea attachment.
    @discardableResult
    /// Adds files the person chose (or dropped) to Ideas, keeping the idea layout:
    /// - at the Ideas root, each file becomes its own idea folder (a folder is copied as is);
    /// - in a top-level idea, files go under its `Attachments/` and its note links them;
    /// - anywhere deeper, files are copied where asked.
    public func importItems(_ urls: [URL], into directory: URL? = nil) throws -> [URL] {
        let target = try validatedDirectory(directory ?? ideasRoot)
        let isRoot = target.canonicalPath == ideasRoot.canonicalPath
        let isIdea = target.deletingLastPathComponent().canonicalPath == ideasRoot.canonicalPath
        return try urls.map { source in
            let ext = source.pathExtension
            let base = source.deletingPathExtension().lastPathComponent
            let isDirectory = (try? source.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            if isRoot && !isDirectory {
                let name = CaptureNaming.safeFilename(base)
                let folder = CaptureNaming.uniqueURL(in: target, base: name, extension: "")
                try Self.publishFolder(at: folder) { staged in
                    if ["md", "markdown", "mdown"].contains(ext.lowercased()) {
                        try fileManager.copyItem(at: source, to: staged.appendingPathComponent(name).appendingPathExtension("md"))
                    } else {
                        try IdeaFolderLayout.build(in: staged, base: name, title: base, markdown: nil, attachments: [
                            .init(name: base, ext: ext) { try FileManager.default.copyItem(at: source, to: $0) }])
                    }
                }
                return folder
            }
            if isIdea && !isDirectory && !["md", "markdown", "mdown", "txt"].contains(ext.lowercased()) {
                let attachments = target.appendingPathComponent(IdeaFolderLayout.attachmentsFolder, isDirectory: true)
                try WorkspaceLocalPathChecks.rejectSymlinks(to: attachments)
                try fileManager.createDirectory(at: attachments, withIntermediateDirectories: true)
                let destination = uniqueURL(in: attachments, base: base, extension: ext)
                try fileManager.copyItem(at: source, to: destination)
                linkAttachment(destination.lastPathComponent, inIdea: target)
                return destination
            }
            let destination = uniqueURL(in: target, base: base, extension: ext)
            try fileManager.copyItem(at: source, to: destination)
            return destination
        }
    }

    /// Appends a link to the idea's own note (`<idea>/<idea>.md`) when it has one.
    /// Best effort: the attachment is already saved either way.
    private func linkAttachment(_ name: String, inIdea idea: URL) {
        let note = idea.appendingPathComponent(idea.lastPathComponent).appendingPathExtension("md")
        guard (try? WorkspaceLocalPathChecks.rejectSymlinks(to: note)) != nil,
              let handle = try? FileHandle(forWritingTo: note) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data(("\n" + IdeaFolderLayout.link(name) + "\n").utf8))
    }

    public static func isEditableText(_ url: URL) -> Bool {
        TextDocumentService.supportsEditing(url)
    }

    private func validatedDirectory(_ directory: URL) throws -> URL {
        let target = directory.canonical
        guard isInsideIdeas(target), (try? target.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
            throw Error.outsideIdeas
        }
        return target
    }

    private func isInsideIdeas(_ url: URL) -> Bool {
        let path = url.canonicalPath
        return path == ideasRoot.canonicalPath || path.hasPrefix(ideasRoot.canonicalPath + "/")
    }

    private func sanitizedName(_ raw: String) throws -> String {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = value.replacingOccurrences(of: "/", with: "-")
        guard name.isEmpty == false, name != ".", name != ".." else { throw Error.emptyName }
        return name
    }

    private func uniqueURL(in directory: URL, base: String, extension ext: String) -> URL {
        func candidate(_ suffix: String = "") -> URL {
            let name = base + suffix
            return ext.isEmpty ? directory.appendingPathComponent(name)
                : directory.appendingPathComponent(name).appendingPathExtension(ext)
        }
        var result = candidate()
        var number = 2
        while fileManager.fileExists(atPath: result.path) {
            result = candidate(" \(number)")
            number += 1
        }
        return result
    }
}
