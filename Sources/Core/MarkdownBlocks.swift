import Foundation

/// The block structure of a Markdown string. Pure, so it is shared and testable.
public enum MarkdownBlocks {
    public enum Block: Equatable, Sendable {
        case heading(level: Int, text: String)
        case paragraph(String)
        case bullet(depth: Int, text: String)
        case numbered(depth: Int, index: String, text: String)
        case task(depth: Int, done: Bool, text: String)
        case code(String)
        case table([[String]])
        case quote(String)
        case rule
    }

    /// Strips a leading `---` … `---` YAML block, as work records begin with.
    public static func withoutFrontMatter(_ text: String) -> String {
        let lines = text.components(separatedBy: .newlines)
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---",
              let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" })
        else { return text }
        return lines[(end + 1)...].joined(separator: "\n")
    }

    public static func parse(_ source: String) -> [Block] {
        var result: [Block] = []
        var paragraph: [String] = []
        var codeLines: [String] = []
        var tableRows: [[String]] = []
        var inCode = false

        func flushParagraph() {
            if paragraph.isEmpty == false {
                result.append(.paragraph(paragraph.joined(separator: " ")))
                paragraph.removeAll()
            }
        }
        func flushTable() {
            if tableRows.isEmpty == false { result.append(.table(tableRows)); tableRows.removeAll() }
        }

        for rawLine in withoutFrontMatter(source).components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            // Two spaces (or a tab) of indentation per nesting level.
            let indent = rawLine.prefix { $0 == " " || $0 == "\t" }
                .reduce(0) { $0 + ($1 == "\t" ? 2 : 1) }
            let depth = min(indent / 2, 4)

            if line.hasPrefix("```") {
                if inCode {
                    result.append(.code(codeLines.joined(separator: "\n")))
                    codeLines.removeAll()
                    inCode = false
                } else {
                    flushParagraph(); flushTable()
                    inCode = true
                }
                continue
            }
            if inCode { codeLines.append(rawLine); continue }

            if line.hasPrefix("|") {
                flushParagraph()
                let cells = line.trimmingCharacters(in: CharacterSet(charactersIn: "|"))
                    .components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
                // The |---|---| separator row carries no content.
                if cells.allSatisfy({ $0.allSatisfy { "-:".contains($0) } && $0.isEmpty == false }) { continue }
                tableRows.append(cells)
                continue
            }
            flushTable()

            if line.isEmpty { flushParagraph(); continue }

            if line.hasPrefix("#") {
                let level = line.prefix(while: { $0 == "#" }).count
                let rest = line.dropFirst(level)
                if level <= 6, rest.isEmpty || rest.hasPrefix(" ") {
                    flushParagraph()
                    result.append(.heading(level: min(level, 4), text: rest.trimmingCharacters(in: .whitespaces)))
                    continue
                }
            }
            if line == "---" || line == "***" || line == "___" {
                flushParagraph(); result.append(.rule); continue
            }
            if line.hasPrefix(">") {
                flushParagraph()
                result.append(.quote(line.dropFirst().trimmingCharacters(in: .whitespaces)))
                continue
            }
            if let marker = ["- ", "* ", "+ "].first(where: { line.hasPrefix($0) }) {
                flushParagraph()
                let content = String(line.dropFirst(marker.count))
                let lower = content.lowercased()
                if lower.hasPrefix("[ ] ") || lower.hasPrefix("[x] ") || lower == "[ ]" || lower == "[x]" {
                    result.append(.task(depth: depth, done: lower.hasPrefix("[x]"),
                                        text: content.dropFirst(3).trimmingCharacters(in: .whitespaces)))
                } else {
                    result.append(.bullet(depth: depth, text: content))
                }
                continue
            }
            if let separator = line.firstIndex(where: { $0 == "." || $0 == ")" }),
               line.distance(from: line.startIndex, to: separator) <= 3,
               Int(line[line.startIndex..<separator]) != nil,
               line[line.index(after: separator)...].first == " " {
                flushParagraph()
                let index = String(line[line.startIndex..<separator])
                let content = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
                result.append(.numbered(depth: depth, index: index, text: content))
                continue
            }
            paragraph.append(line)
        }
        if inCode, codeLines.isEmpty == false { result.append(.code(codeLines.joined(separator: "\n"))) }
        flushTable()
        flushParagraph()
        return result
    }
}
