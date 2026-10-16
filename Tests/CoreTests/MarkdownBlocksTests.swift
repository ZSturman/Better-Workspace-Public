import XCTest
@testable import BetterWorkspaceCore

/// The block structure every Markdown display (Mac and phone) renders from.
final class MarkdownBlocksTests: XCTestCase {
    typealias B = MarkdownBlocks.Block

    func testAWorkRecordReadsAsMarkdownWithoutItsFrontMatter() {
        let record = """
        ---
        better-workspace: 1
        title: "Ship it"
        ---

        # Ship it

        Some **bold** context.
        - [ ] Write tests
        - [x] Draft the plan
          - nested detail
        1. First
        2) Second
        """
        XCTAssertEqual(MarkdownBlocks.parse(record), [
            .heading(level: 1, text: "Ship it"),
            .paragraph("Some **bold** context."),
            .task(depth: 0, done: false, text: "Write tests"),
            .task(depth: 0, done: true, text: "Draft the plan"),
            .bullet(depth: 1, text: "nested detail"),
            .numbered(depth: 0, index: "1", text: "First"),
            .numbered(depth: 0, index: "2", text: "Second"),
        ])
    }

    func testTablesCodeQuotesAndRules() {
        let text = """
        | Name | Count |
        |------|------:|
        | A | 1 |

        ```
        let x = 1
        ```
        > Quoted
        ---
        """
        XCTAssertEqual(MarkdownBlocks.parse(text), [
            .table([["Name", "Count"], ["A", "1"]]),
            .code("let x = 1"),
            .quote("Quoted"),
            .rule,
        ])
    }

    func testWhatLooksLikeSyntaxButIsNot() {
        XCTAssertEqual(MarkdownBlocks.parse("#hashtag stays text"), [.paragraph("#hashtag stays text")])
        XCTAssertEqual(MarkdownBlocks.parse("2026.10 was busy"), [.paragraph("2026.10 was busy")])
        XCTAssertEqual(MarkdownBlocks.parse("one\ntwo\n\nthree"), [.paragraph("one two"), .paragraph("three")])
        XCTAssertEqual(MarkdownBlocks.withoutFrontMatter("---\nnot closed"), "---\nnot closed",
                       "An unclosed opening rule is not front matter")
    }
}
