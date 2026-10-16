import Foundation

/// A portable social-post record. Unlike an opaque scheduling row, this is one
/// ordinary Markdown file that remains readable and editable in Finder or any text
/// editor. Better Workspace only creates these during an explicitly confirmed import.
public enum SocialPostStatus: String, CaseIterable, Codable, Sendable, Identifiable {
    case draft, review, ready, scheduled, posted, error

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .draft: return "Draft"
        case .review: return "Needs review"
        case .ready: return "Ready"
        case .scheduled: return "Scheduled"
        case .posted: return "Posted"
        case .error: return "Needs attention"
        }
    }

    public var symbolName: String {
        switch self {
        case .draft: return "square.and.pencil"
        case .review: return "eye"
        case .ready: return "checkmark.seal"
        case .scheduled: return "calendar"
        case .posted: return "checkmark.circle.fill"
        case .error: return "exclamationmark.triangle"
        }
    }
}

public struct SocialPost: Identifiable, Hashable, Sendable {
    public let id: String
    public var title: String
    public var status: SocialPostStatus
    public var platforms: [String]
    /// Set only when the source explicitly says the post is scheduled. A legacy date
    /// alone is not a calendar commitment.
    public var scheduledAt: Date?
    public var linkedInURL: URL?
    public var blueskyURL: URL?
    public var linkedInContent: String
    public var blueskyContent: String
    public var originalContent: String
    public var sourceURL: URL?
    public var postingError: String?
    public let url: URL
    public let modifiedAt: Date?

    public init(id: String, title: String, status: SocialPostStatus = .draft,
                platforms: [String] = [], scheduledAt: Date? = nil,
                linkedInURL: URL? = nil, blueskyURL: URL? = nil,
                linkedInContent: String = "", blueskyContent: String = "",
                originalContent: String = "", sourceURL: URL? = nil,
                postingError: String? = nil, url: URL, modifiedAt: Date? = nil) {
        self.id = id
        self.title = title
        self.status = status
        self.platforms = platforms
        self.scheduledAt = scheduledAt
        self.linkedInURL = linkedInURL
        self.blueskyURL = blueskyURL
        self.linkedInContent = linkedInContent
        self.blueskyContent = blueskyContent
        self.originalContent = originalContent
        self.sourceURL = sourceURL
        self.postingError = postingError
        self.url = url
        self.modifiedAt = modifiedAt
    }

    public var preview: String {
        let text = linkedInContent.isEmpty == false ? linkedInContent
            : (blueskyContent.isEmpty == false ? blueskyContent : originalContent)
        return text.replacingOccurrences(of: "\n", with: " ")
    }
}

/// The on-disk contract for social posts. It intentionally recognizes only files
/// carrying both this suffix and marker; unrelated Markdown in Social Posts is never
/// treated as a post.
public final class SocialPostService: @unchecked Sendable {
    public static let markerKey = "better-workspace-social-post"
    public static let fileSuffix = ".social.md"
    private let fm = FileManager.default

    public init() {}

    public func create(_ post: SocialPost, in directory: URL) throws -> SocialPost {
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        var suffix = 1
        while suffix <= 100 {
            let stem = CaptureNaming.safeFilename(post.title)
            let name = suffix == 1 ? "\(stem)\(Self.fileSuffix)" : "\(stem) \(suffix)\(Self.fileSuffix)"
            let url = directory.appendingPathComponent(name)
            let copy = SocialPost(id: post.id, title: post.title, status: post.status,
                                  platforms: post.platforms, scheduledAt: post.scheduledAt,
                                  linkedInURL: post.linkedInURL, blueskyURL: post.blueskyURL,
                                  linkedInContent: post.linkedInContent, blueskyContent: post.blueskyContent,
                                  originalContent: post.originalContent, sourceURL: post.sourceURL,
                                  postingError: post.postingError, url: url)
            // `createFile` fails rather than replacing another tool's file, closing
            // the usual check-then-write race without ever overwriting a post.
            if fm.createFile(atPath: url.path, contents: Data(render(copy).utf8)) {
                return read(at: url) ?? copy
            }
            suffix += 1
        }
        throw CocoaError(.fileWriteFileExists)
    }

    public func read(at url: URL) -> SocialPost? {
        guard url.lastPathComponent.hasSuffix(Self.fileSuffix),
              let text = try? String(contentsOf: url, encoding: .utf8),
              let parsed = parse(text), parsed.values[Self.markerKey] == "1",
              let id = parsed.values["id"], id.isEmpty == false,
              let title = parsed.values["title"], title.isEmpty == false
        else { return nil }
        var fresh = url
        fresh.removeAllCachedResourceValues()
        let modified = (try? fresh.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        return SocialPost(
            id: id, title: title,
            status: SocialPostStatus(rawValue: parsed.values["status"] ?? "") ?? .draft,
            platforms: list(parsed.values["platforms"]), scheduledAt: date(parsed.values["scheduled-at"]),
            linkedInURL: parsed.values["linkedin-url"].flatMap(URL.init(string:)),
            blueskyURL: parsed.values["bluesky-url"].flatMap(URL.init(string:)),
            linkedInContent: parsed.sections["LinkedIn"] ?? "",
            blueskyContent: parsed.sections["Bluesky"] ?? "",
            originalContent: parsed.sections["Original"] ?? "",
            sourceURL: parsed.values["source-url"].flatMap(URL.init(string:)),
            postingError: parsed.values["posting-error"], url: url.canonical, modifiedAt: modified
        )
    }

    public func items(in directory: URL) -> [SocialPost] {
        guard let urls = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil,
                                                     options: [.skipsHiddenFiles]) else { return [] }
        return urls.compactMap(read(at:)).sorted { lhs, rhs in
            if lhs.status != rhs.status { return rank(lhs.status) < rank(rhs.status) }
            if lhs.scheduledAt != rhs.scheduledAt {
                return (lhs.scheduledAt ?? .distantFuture) < (rhs.scheduledAt ?? .distantFuture)
            }
            return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
        }
    }

    private func rank(_ status: SocialPostStatus) -> Int {
        switch status {
        case .error: return 0
        case .review: return 1
        case .ready: return 2
        case .scheduled: return 3
        case .draft: return 4
        case .posted: return 5
        }
    }

    private func render(_ post: SocialPost) -> String {
        let scheduledAt = post.scheduledAt.map(iso) ?? ""
        let linkedInURL = post.linkedInURL?.absoluteString ?? ""
        let blueskyURL = post.blueskyURL?.absoluteString ?? ""
        let sourceURL = post.sourceURL?.absoluteString ?? ""
        let postingError = post.postingError ?? ""
        var lines = ["---", "\(Self.markerKey): 1", "id: \(scalar(post.id))",
                     "title: \(scalar(post.title))", "status: \(post.status.rawValue)",
                     "platforms: \(post.platforms.joined(separator: ", "))"]
        lines.append("scheduled-at: \(scheduledAt)")
        lines.append("linkedin-url: \(linkedInURL)")
        lines.append("bluesky-url: \(blueskyURL)")
        lines.append("source-url: \(sourceURL)")
        lines.append("posting-error: \(scalar(postingError))")
        lines += ["---", "", "# \(post.title)", ""]
        appendSection("LinkedIn", post.linkedInContent, to: &lines)
        appendSection("Bluesky", post.blueskyContent, to: &lines)
        appendSection("Original", post.originalContent, to: &lines)
        if let source = post.sourceURL { lines += ["## Source", "", "[Originally in Notion](\(source.absoluteString))", ""] }
        return lines.joined(separator: "\n")
    }

    private func appendSection(_ name: String, _ content: String, to lines: inout [String]) {
        guard content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else { return }
        lines += ["## \(name)", "", content.trimmingCharacters(in: .whitespacesAndNewlines), ""]
    }

    private func scalar(_ value: String) -> String {
        guard let encoded = try? String(data: JSONSerialization.data(withJSONObject: [value]), encoding: .utf8) else { return value }
        return String(encoded.dropFirst().dropLast())
    }

    private func iso(_ value: Date) -> String { ISO8601DateFormatter().string(from: value) }

    private func date(_ value: String?) -> Date? {
        guard let value, value.isEmpty == false else { return nil }
        return ISO8601DateFormatter().date(from: value)
    }

    private func list(_ value: String?) -> [String] {
        (value ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { $0.isEmpty == false }
    }

    private func parse(_ text: String) -> (values: [String: String], sections: [String: String])? {
        guard text.hasPrefix("---\n"), let end = text.range(of: "\n---\n") else { return nil }
        var values: [String: String] = [:]
        for line in text[text.index(text.startIndex, offsetBy: 4)..<end.lowerBound].split(separator: "\n") {
            guard let divider = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<divider])
            var value = String(line[line.index(after: divider)...]).trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("\"") && value.hasSuffix("\""),
               let data = "[\(value)]".data(using: .utf8),
               let decoded = try? JSONSerialization.jsonObject(with: data) as? [String], let first = decoded.first {
                value = first
            }
            values[key] = value
        }
        let body = String(text[end.upperBound...])
        var sections: [String: String] = [:]
        let names = ["LinkedIn", "Bluesky", "Original", "Source"]
        for (index, name) in names.enumerated() {
            guard let range = body.range(of: "## \(name)\n") else { continue }
            let start = range.upperBound
            let next = names[(index + 1)...].compactMap { body.range(of: "## \($0)\n", range: start..<body.endIndex)?.lowerBound }.min() ?? body.endIndex
            sections[name] = String(body[start..<next]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return (values, sections)
    }
}
