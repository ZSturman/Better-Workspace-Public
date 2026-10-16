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
    public func importItems(_ urls: [URL], into directory: URL? = nil) throws -> [URL] {
        let target = try validatedDirectory(directory ?? ideasRoot)
        return try urls.map { source in
            let ext = source.pathExtension
            let base = source.deletingPathExtension().lastPathComponent
            let destination = uniqueURL(in: target, base: base, extension: ext)
            try fileManager.copyItem(at: source, to: destination)
            return destination
        }
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
