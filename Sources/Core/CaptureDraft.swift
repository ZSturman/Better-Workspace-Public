import Foundation

/// Entries remain identifiable across partial saves, so a failed filing can retry
/// the existing Inbox file instead of creating another capture.
public struct CaptureDraftEntry: Identifiable, Sendable {
    public enum Content: Sendable {
        case markdown(String)
        case link(url: String, notes: String)
        case file(URL)
        case data(Data, extension: String)
    }
    public let id: UUID
    public var title: String
    public let content: Content

    public init(id: UUID = UUID(), title: String = "", content: Content) {
        self.id = id
        self.title = title
        self.content = content
    }

    public static func note(id: UUID = UUID(), title: String, markdown: String, url: String) -> CaptureDraftEntry? {
        if !url.isEmpty { return .init(id: id, title: title, content: .link(url: url, notes: markdown)) }
        let trimmed = markdown.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if !trimmed.contains("\n"), ["http://", "https://"].contains(where: { trimmed.lowercased().hasPrefix($0) }),
           (try? WorkspaceLink(title: title, url: trimmed)) != nil {
            return .init(id: id, title: title, content: .link(url: trimmed, notes: ""))
        }
        return .init(id: id, title: title, content: .markdown(markdown))
    }

    public var document: (name: String, data: Data, ext: String)? {
        get throws {
            switch content {
            case .markdown(let text):
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw IngestService.IngestError.emptyText
                }
                let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
                let fallback = text.split(separator: "\n").first.flatMap { CaptureNaming.title(fromFirstLine: String($0)) }
                return (name.isEmpty ? fallback ?? CaptureNaming.timestampName() : name, Data(text.utf8), "md")
            case .link(let url, let notes):
                let record = try WorkspaceLink(id: id.uuidString.lowercased(), title: title, url: url, notes: notes)
                return (record.title, Data(record.markdown.utf8), "md")
            case .data(let data, let ext):
                return (title.isEmpty ? CaptureNaming.timestampName() : title, data, ext)
            case .file: return nil
            }
        }
    }
}

public struct CaptureBatchResult: Sendable {
    public struct Saved: Sendable {
        public let id: UUID
        public let url: URL
        public init(id: UUID, url: URL) { self.id = id; self.url = url }
    }
    public struct Failure: Sendable {
        public let id: UUID
        public let message: String
        public init(id: UUID, message: String) { self.id = id; self.message = message }
    }
    public var saved: [Saved] = []
    public var failures: [Failure] = []
    public init() {}
}

/// Portable link document. Front-matter string values use JSON escaping, making
/// the tiny wire format readable without adding a YAML dependency to either app.
public struct WorkspaceLink: Equatable, Sendable {
    public let id: String
    public var title: String
    public var url: String
    public var notes: String

    public enum FormatError: Error, LocalizedError {
        case invalidURL, invalidDocument
        public var errorDescription: String? {
            switch self {
            case .invalidURL: return "Enter a valid HTTP or HTTPS URL."
            case .invalidDocument: return "This is not a supported Workspace link."
            }
        }
    }

    public init(id: String = UUID().uuidString.lowercased(), title: String, url: String, notes: String = "") throws {
        var normalized = url.trimmingCharacters(in: .whitespacesAndNewlines)
        if !normalized.contains(":"), normalized.contains(".") { normalized = "https://" + normalized }
        guard normalized.count <= 4096,
              !normalized.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) }),
              let components = URLComponents(string: normalized),
              ["http", "https"].contains(components.scheme?.lowercased() ?? ""),
              let host = components.host, !host.isEmpty, host.count <= 253,
              components.url != nil else { throw FormatError.invalidURL }
        self.id = id
        self.title = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? host : title
        self.url = normalized
        self.notes = notes
    }

    private static func quoted(_ value: String) -> String {
        String(data: try! JSONEncoder().encode(value), encoding: .utf8)!
    }

    public var markdown: String {
        "---\nbetter-workspace-link: 1\nid: \(Self.quoted(id))\nurl: \(Self.quoted(url))\ntitle: \(Self.quoted(title))\n---\n# \(title.replacingOccurrences(of: "\n", with: " "))\n\n" + notes
    }

    public static func parse(_ text: String) throws -> WorkspaceLink {
        guard text.hasPrefix("---\n"), let end = text.range(of: "\n---\n", range: text.index(text.startIndex, offsetBy: 4)..<text.endIndex) else {
            throw FormatError.invalidDocument
        }
        var fields: [String: String] = [:]
        for line in text[text.index(text.startIndex, offsetBy: 4)..<end.lowerBound].split(separator: "\n") {
            guard let colon = line.firstIndex(of: ":") else { continue }
            fields[String(line[..<colon])] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        func value(_ key: String) throws -> String {
            guard let raw = fields[key], let bytes = raw.data(using: .utf8), let decoded = try? JSONDecoder().decode(String.self, from: bytes) else {
                throw FormatError.invalidDocument
            }
            return decoded
        }
        guard fields["better-workspace-link"] == "1" else { throw FormatError.invalidDocument }
        let body = String(text[end.upperBound...])
        guard let separator = body.range(of: "\n\n"), body.hasPrefix("# ") else { throw FormatError.invalidDocument }
        return try WorkspaceLink(id: value("id"), title: value("title"), url: value("url"), notes: String(body[separator.upperBound...]))
    }
}

extension IngestService {
    public func capture(_ entry: CaptureDraftEntry, source: IngestSource = .quickCapture) throws -> IngestItem {
        if let document = try entry.document {
            let item = try importData(document.data, preferredName: document.name, extension: document.ext, source: source)
            setTitle(document.name, for: item)
            return item
        }
        guard case .file(let url) = entry.content else { throw IngestError.emptyText }
        let item = try importItem(at: url, source: source, title: entry.title)
        setTitle(entry.title.isEmpty ? url.deletingPathExtension().lastPathComponent : entry.title, for: item)
        return item
    }
}

extension MobileCaptureService {
    public func capture(_ entries: [CaptureDraftEntry]) -> CaptureBatchResult {
        var result = CaptureBatchResult()
        for entry in entries {
            do {
                let url: URL
                if let document = try entry.document {
                    url = try captureData(document.data, preferredName: document.name, extension: document.ext)
                } else if case .file(let source) = entry.content {
                    // Use the coordinated copy path, then rename within Inbox if titled.
                    url = try captureFile(at: source, title: entry.title)
                } else { throw CaptureError.emptyBundle }
                result.saved.append(.init(id: entry.id, url: url))
            } catch { result.failures.append(.init(id: entry.id, message: error.localizedDescription)) }
        }
        return result
    }
}
