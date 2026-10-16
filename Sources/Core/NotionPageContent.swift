import Foundation

public struct NotionPageContent: Codable, Sendable {
    public let pageID: String
    public let editedAt: Date?
    public let blocks: [ProjectJSON]
    public init(pageID: String, editedAt: Date?, blocks: [ProjectJSON]) { self.pageID = pageID; self.editedAt = editedAt; self.blocks = blocks }
    public var plainText: String { Self.text(blocks) }
    public static func unsupportedBlockCount(_ blocks: [ProjectJSON]) -> Int {
        blocks.reduce(0) { $0 + ($1["type"].string == "unsupported" ? 1 : 0) + unsupportedBlockCount($1["_children"].array) }
    }
    public static func text(_ blocks: [ProjectJSON]) -> String {
        blocks.map { block in
            let type = block["type"].string ?? "unsupported"
            let content = block[type]
            let text = content["rich_text"].array.map(\.display).joined()
            let line: String
            switch type {
            case "heading_1": line = "# " + text
            case "heading_2": line = "## " + text
            case "heading_3": line = "### " + text
            case "bulleted_list_item": line = "• " + text
            case "numbered_list_item": line = "1. " + text
            case "to_do": line = (content["checked"].bool ? "☑ " : "☐ ") + text
            case "divider": line = "—"
            case "image", "video", "audio", "pdf", "file", "embed", "bookmark", "link_preview":
                line = content["caption"].array.map(\.display).joined().isEmpty ? "[\(type)]" : content["caption"].array.map(\.display).joined()
            default: line = text.isEmpty ? "[\(type)]" : text
            }
            let nested = Self.text(block["_children"].array)
            return nested.isEmpty ? line : line + "\n" + nested
        }.joined(separator: "\n\n")
    }
}

public extension NotionClient {
    /// Capture all supported and unsupported blocks losslessly. Nothing is rewritten.
    func pageContent(pageID: String, editedAt: Date?) async throws -> NotionPageContent {
        func children(_ id: String, depth: Int) async throws -> [ProjectJSON] {
            guard depth <= 64 else { throw Failure.malformed("Content nesting exceeds the supported read depth; previous content was retained") }
            var blocks: [ProjectJSON] = [], cursor: String?, seen: Set<String> = []
            repeat {
                let query = cursor.map { "?page_size=100&start_cursor=\($0)" } ?? "?page_size=100"
                let response = try await graphRequest("blocks/\(id)/children" + query)
                guard case .array = response["results"] else { throw Failure.malformed("Incomplete block response") }
                for block in response["results"].array {
                    var complete = block.object
                    if block["has_children"].bool, let child = block["id"].string { complete["_children"] = .array(try await children(child, depth: depth + 1)) }
                    blocks.append(.object(complete))
                }
                cursor = response["has_more"].bool ? response["next_cursor"].string : nil
                if response["has_more"].bool && cursor == nil { throw Failure.malformed("Block pagination has no cursor") }
                if let cursor, !seen.insert(cursor).inserted { throw Failure.malformed("Block pagination repeated a cursor") }
            } while cursor != nil
            return blocks
        }
        return try await .init(pageID: pageID, editedAt: editedAt, blocks: children(pageID, depth: 0))
    }
}

public enum ProjectDates {
    public static func parse(_ raw: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: raw) { return date }
        formatter.formatOptions.insert(.withFractionalSeconds)
        if let date = formatter.date(from: raw) { return date }
        let day = DateFormatter(); day.locale = Locale(identifier: "en_US_POSIX"); day.calendar = Calendar(identifier: .gregorian); day.timeZone = TimeZone(secondsFromGMT: 0); day.dateFormat = "yyyy-MM-dd"; day.isLenient = false
        guard let date = day.date(from: raw), day.string(from: date) == raw else { return nil }
        return date
    }
}
