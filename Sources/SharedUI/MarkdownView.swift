import SwiftUI
import BetterWorkspaceCore

/// A small block-level Markdown renderer, shared by the Mac and iPhone/iPad apps.
///
/// SwiftUI's `AttributedString(markdown:)` handles inline styling but flattens
/// headings, lists and code blocks — which is most of what a task's notes, a README or
/// a Reference document is made of. This renders the block structure (headings, nested
/// and numbered lists, `- [ ]` checklists, quotes, code, tables, rules) and hands each
/// line's inline styling — bold, italic, code, links — to `AttributedString`.
/// Leading YAML front matter (a work record's `---` header) is not shown.
struct MarkdownView: View {
    let text: String
    var baseSize: CGFloat = MarkdownView.defaultSize

    #if os(macOS)
    static let defaultSize: CGFloat = 13
    #else
    static let defaultSize: CGFloat = 16
    #endif

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(MarkdownBlocks.parse(text).enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func view(for block: MarkdownBlocks.Block) -> some View {
        switch block {
        case .heading(let level, let text):
            Text(MarkdownInline.attributed(text))
                .font(.system(size: headingSize(level), weight: level <= 2 ? .semibold : .medium))
                .padding(.top, level <= 2 ? 6 : 2)
                .fixedSize(horizontal: false, vertical: true)
        case .paragraph(let text):
            Text(MarkdownInline.attributed(text)).font(.system(size: baseSize))
                .fixedSize(horizontal: false, vertical: true)
        case .bullet(let depth, let text):
            listRow(depth: depth, marker: Text(depth.isMultiple(of: 2) ? "•" : "◦"), text: text)
        case .numbered(let depth, let index, let text):
            listRow(depth: depth, marker: Text("\(index).").monospacedDigit(), text: text)
        case .task(let depth, let done, let text):
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Image(systemName: done ? "checkmark.square.fill" : "square")
                    .font(.system(size: baseSize))
                    .foregroundStyle(done ? Color.accentColor : Color.secondary)
                    .accessibilityLabel(done ? "Done" : "Not done")
                Text(MarkdownInline.attributed(text)).font(.system(size: baseSize))
                    .strikethrough(done)
                    .foregroundStyle(done ? .secondary : .primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, 4 + CGFloat(depth) * 16)
        case .code(let code):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code).font(.system(size: baseSize - 1, design: .monospaced))
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: 6))
        case .table(let rows):
            ScrollView(.horizontal, showsIndicators: false) {
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 4) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { index, cells in
                        GridRow {
                            ForEach(Array(cells.enumerated()), id: \.offset) { _, cell in
                                Text(MarkdownInline.attributed(cell))
                                    .font(.system(size: baseSize - 1, weight: index == 0 ? .semibold : .regular))
                            }
                        }
                        if index == 0 { Divider() }
                    }
                }
            }
            .padding(8)
            .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
        case .quote(let text):
            HStack(alignment: .top, spacing: 8) {
                Rectangle().fill(Color.secondary.opacity(0.35)).frame(width: 2)
                Text(MarkdownInline.attributed(text)).font(.system(size: baseSize)).foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
        case .rule:
            Divider().padding(.vertical, 2)
        }
    }

    private func listRow(depth: Int, marker: Text, text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            marker.font(.system(size: baseSize)).foregroundStyle(.secondary)
            Text(MarkdownInline.attributed(text)).font(.system(size: baseSize))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.leading, 4 + CGFloat(depth) * 16)
    }

    private func headingSize(_ level: Int) -> CGFloat {
        switch level {
        case 1: return baseSize + 8
        case 2: return baseSize + 5
        case 3: return baseSize + 2
        default: return baseSize + 1
        }
    }
}

/// One-line Markdown for summaries in lists and cards: inline styling kept, block
/// markers (`#`, `- `, `> `, `- [ ]`) dropped, lines joined, so a `lineLimit` reads
/// like prose instead of showing raw syntax.
enum MarkdownInline {
    static func attributed(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }

    static func summary(_ text: String) -> AttributedString {
        let lines = MarkdownBlocks.parse(text).compactMap { block -> String? in
            switch block {
            case .heading(_, let text), .paragraph(let text), .bullet(_, let text), .quote(let text),
                 .numbered(_, _, let text), .task(_, _, let text):
                return text
            case .code, .table, .rule:
                return nil
            }
        }
        return attributed(lines.joined(separator: " · "))
    }
}
