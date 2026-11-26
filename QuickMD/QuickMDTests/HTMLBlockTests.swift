import XCTest
import SwiftUI
import AppKit

/// HTML in Markdown (`HTMLBlockSyntax`): constructs QuickMD recognises and
/// draws natively instead of showing their tags as text.
final class HTMLBlockTests: XCTestCase {

    private func parse(_ markdown: String) -> [MarkdownBlock] {
        MarkdownBlockParser(theme: MarkdownTheme.cached(for: .light)).parse(markdown)
    }

    private func plainText(_ block: MarkdownBlock) -> String? {
        if case .text(let attr) = block.content {
            return String(attr.characters).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    private func texts(_ blocks: [MarkdownBlock]) -> [String] {
        blocks.compactMap(plainText)
    }

    // MARK: - Comments

    func testOneLineCommentDrawsNothing() {
        let blocks = parse("before\n\n<!-- a note -->\n\nafter")
        XCTAssertEqual(texts(blocks), ["before", "after"])
    }

    func testMultiLineCommentDrawsNothing() {
        let blocks = parse("before\n\n<!--\n# not a heading\n- not a list\n-->\n\nafter")
        XCTAssertEqual(texts(blocks), ["before", "after"])
        XCTAssertFalse(blocks.contains { if case .heading = $0.content { return true } else { return false } })
    }

    func testCommentInterruptsAParagraph() {
        let blocks = parse("one\n<!-- c -->\ntwo")
        XCTAssertEqual(texts(blocks), ["one", "two"])
    }

    func testEmptyCommentFormsClose() {
        XCTAssertEqual(texts(parse("<!-->\nafter")), ["after"])
        XCTAssertEqual(texts(parse("<!--->\nafter")), ["after"])
    }

    func testUnclosedCommentRunsToTheEnd() {
        XCTAssertEqual(texts(parse("before\n\n<!-- never closed\n\nstill hidden")), ["before"])
    }

    func testCommentIndentedFourSpacesIsNotAComment() {
        // Four spaces: not an HTML block start (CommonMark). This parser has no
        // top-level indented code, so the line stays visible.
        let blocks = parse("    <!-- shown -->")
        XCTAssertFalse(texts(blocks).isEmpty)
    }

    func testCommentInsideFenceIsCode() {
        let blocks = parse("```\n<!-- code -->\n```")
        guard case .codeBlock(let code, _)? = blocks.first?.content else { return XCTFail("no code block") }
        XCTAssertEqual(code, "<!-- code -->")
    }

    func testDefinitionsInsideACommentAreNotDefinitions() {
        let blocks = parse("<!--\n[^1]: commented out\n-->\n\ntext")
        XCTAssertEqual(texts(blocks), ["text"], "no footnotes section from a commented-out definition")
    }

    func testInlineCommentIsHidden() {
        XCTAssertEqual(texts(parse("a <!-- x --> b")), ["a b"])
        XCTAssertEqual(texts(parse("a<!-- x -->b")), ["ab"])
        XCTAssertEqual(texts(parse("**bold**<!-- x --> text")), ["bold text"])
    }

    func testInlineUnclosedCommentIsText() {
        XCTAssertEqual(texts(parse("a <!-- b")), ["a <!-- b"])
    }

    func testCommentInsideCodeSpanIsCode() {
        XCTAssertEqual(texts(parse("`<!-- x -->`")), ["<!-- x -->"])
    }

    func testManyUnclosedInlineCommentsStayText() {
        let line = String(repeating: "<!-- ", count: 2_000)
        XCTAssertEqual(texts(parse("x " + line)).first?.count, ("x " + line).trimmingCharacters(in: .whitespaces).count)
    }
}
