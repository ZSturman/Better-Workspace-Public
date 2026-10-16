import Foundation

/// Explicit, optimistic editing for small plain-text Workspace files.
///
/// This is intentionally separate from `FilesystemService`: browsing remains read-only,
/// while an inspector save is an obvious person-initiated write. A save only succeeds
/// when the bytes still match the snapshot that was opened, so another editor's change
/// is never silently replaced.
public final class TextDocumentService: @unchecked Sendable {
    public static let maximumEditableBytes = 1_024 * 1_024

    public enum Error: LocalizedError {
        case unsupported(URL)
        case tooLarge(URL)
        case missing(URL)
        case changedOnDisk(URL)
        case notText(URL)

        public var errorDescription: String? {
            switch self {
            case let .unsupported(url): return "“\(url.lastPathComponent)” is not a supported text file."
            case let .tooLarge(url): return "“\(url.lastPathComponent)” is larger than 1 MB, so edit it in a dedicated editor."
            case let .missing(url): return "“\(url.lastPathComponent)” was moved or deleted outside Better Workspace."
            case let .changedOnDisk(url): return "“\(url.lastPathComponent)” changed in another app. Reload it before saving."
            case let .notText(url): return "“\(url.lastPathComponent)” is not UTF-8 text."
            }
        }
    }

    public struct Snapshot: Sendable, Equatable {
        public let text: String
        fileprivate let bytes: Data

        fileprivate init(text: String, bytes: Data) {
            self.text = text
            self.bytes = bytes
        }
    }

    public init() {}

    /// Keep binary, package, database, and rich-text formats out of a plain-text editor.
    public static func supportsEditing(_ url: URL) -> Bool {
        ["md", "markdown", "mdown", "txt", "log", "out", "err",
         "json", "jsonl", "plist", "toml", "yaml", "yml", "xml", "html", "css",
         "swift", "py", "js", "ts", "tsx", "jsx", "rb", "go", "rs", "c", "h", "m", "cpp", "sh", "lua",
         "sql", "ini", "conf", "csv", "tsv"].contains(url.pathExtension.lowercased())
    }

    public func read(at url: URL) throws -> Snapshot {
        guard Self.supportsEditing(url) else { throw Error.unsupported(url) }
        guard FileManager.default.fileExists(atPath: url.path) else { throw Error.missing(url) }
        let bytes = try Data(contentsOf: url)
        guard bytes.count <= Self.maximumEditableBytes else { throw Error.tooLarge(url) }
        guard let text = String(data: bytes, encoding: .utf8) else { throw Error.notText(url) }
        return Snapshot(text: text, bytes: bytes)
    }

    /// Re-checks the exact original bytes immediately before an atomic replacement.
    /// `replaceItemAt` deliberately preserves the file's creation date and extended
    /// attributes; those belong to the person and other tools, not this editor.
    public func save(_ text: String, at url: URL, expecting snapshot: Snapshot) throws -> Snapshot {
        guard FileManager.default.fileExists(atPath: url.path) else { throw Error.missing(url) }
        let current = try Data(contentsOf: url)
        guard current == snapshot.bytes else { throw Error.changedOnDisk(url) }
        let replacement = Data(text.utf8)
        guard replacement.count <= Self.maximumEditableBytes else { throw Error.tooLarge(url) }
        let staged = url.deletingLastPathComponent()
            .appendingPathComponent(".bw-text-save-\(UUID().uuidString).tmp")
        try replacement.write(to: staged, options: .withoutOverwriting)
        do {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: staged)
        } catch {
            try? FileManager.default.removeItem(at: staged)
            throw error
        }
        return Snapshot(text: text, bytes: replacement)
    }
}
