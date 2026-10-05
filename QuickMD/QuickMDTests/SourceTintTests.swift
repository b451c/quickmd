import XCTest
import SwiftUI

/// Block-level source tint (v1.12 S-D14a): the mapping from the REAL parser's
/// blocks to buffer ranges. Every fixture goes through `MarkdownBlockParser`,
/// so these also pin that the tint follows the parser's idea of structure.
final class SourceTintTests: XCTestCase {

    private let parser = MarkdownBlockParser(theme: MarkdownTheme.cached(for: .light))

    private func spans(_ text: String) -> [SourceTint.Span] {
        let ns = text as NSString
        return SourceTint.spans(for: parser.parse(text), lineStarts: SourceEditSupport.lineStarts(in: ns), in: ns)
    }

    /// The tinted text and its kind, in order — readable assertions.
    private func tinted(_ text: String) -> [(String, SourceTint.Kind)] {
        let ns = text as NSString
        return spans(text).map { (ns.substring(with: $0.range), $0.kind) }
    }

    private func assertTinted(_ text: String, _ expected: [(String, SourceTint.Kind)],
                              file: StaticString = #filePath, line: UInt = #line) {
        let actual = tinted(text)
        XCTAssertEqual(actual.map(\.0), expected.map(\.0), file: file, line: line)
        XCTAssertEqual(actual.map(\.1), expected.map(\.1), file: file, line: line)
        assertWellFormed(spans(text), length: (text as NSString).length, file: file, line: line)
    }

    /// In the buffer, in order, non-empty, never overlapping.
    private func assertWellFormed(_ spans: [SourceTint.Span], length: Int,
                                  file: StaticString = #filePath, line: UInt = #line) {
        var end = 0
        for span in spans {
            XCTAssertGreaterThan(span.range.length, 0, file: file, line: line)
            XCTAssertGreaterThanOrEqual(span.range.location, end, "overlap", file: file, line: line)
            XCTAssertLessThanOrEqual(NSMaxRange(span.range), length, file: file, line: line)
            end = NSMaxRange(span.range)
        }
    }

    // MARK: - Kinds and extents

    func testATXHeadingTintsItsLineOnly() {
        assertTinted("Intro\n\n## Title ##\nBody under it\n", [("## Title ##", .heading)])
    }

    func testSetextHeadingsTintTheUnderlineToo() {
        assertTinted("Title\n=====\nBody\n\nSub\n---\n\nMore\n",
                     [("Title\n=====", .heading), ("Sub\n---", .heading)])
    }

    func testFencedCodeKeepsInnerBlankLinesAndDropsTrailingOnes() {
        assertTinted("```swift\nlet a = 1\n\nlet b = 2\n```\n\n   \nAfter\n",
                     [("```swift\nlet a = 1\n\nlet b = 2\n```", .verbatim)])
    }

    func testFrontMatterAtTheTop() {
        assertTinted("---\ntitle: Notes\ntags: [a]\n---\n# Heading\n",
                     [("---\ntitle: Notes\ntags: [a]\n---", .verbatim), ("# Heading", .heading)])
    }

    func testBlockquote() {
        assertTinted("> one\n> two\n\nParagraph\n", [("> one\n> two", .quote)])
    }

    func testNestedQuoteLevelsAreSeparateSpans() {
        assertTinted("> outer\n>> inner\n", [("> outer", .quote), (">> inner", .quote)])
    }

    func testAlert() {
        assertTinted("Before\n\n> [!WARNING]\n> Careful.\n\nAfter\n", [("> [!WARNING]\n> Careful.", .quote)])
    }

    func testCodeBlockAtTheEndWithoutTrailingNewline() {
        assertTinted("Text\n\n```\ncode\n```", [("```\ncode\n```", .verbatim)])
    }

    func testAdjacentBlocksDoNotOverlap() {
        assertTinted("```\na\n```\n# H\n> q\n$$\nx^2\n$$",
                     [("```\na\n```", .verbatim), ("# H", .heading), ("> q", .quote), ("$$\nx^2\n$$", .verbatim)])
    }

    func testMermaidSvgAndMathAreVerbatim() {
        assertTinted("```mermaid\ngraph TD\n```\n\n```svg\n<svg/>\n```\n\n$$a+b$$\n",
                     [("```mermaid\ngraph TD\n```", .verbatim), ("```svg\n<svg/>\n```", .verbatim),
                      ("$$a+b$$", .verbatim)])
    }

    func testParagraphsListsTablesAndImagesAreNotTinted() {
        assertTinted("Para *em* [link](x)\n\n- item\n- item\n\n| a | b |\n|---|---|\n| 1 | 2 |\n\n![alt](x.png)\n", [])
    }

    func testHeadingInsideCodeIsNotAHeading() {
        assertTinted("```\n# not a heading\n```\n", [("```\n# not a heading\n```", .verbatim)])
    }

    func testRangesAreUTF16() {
        let text = "# 😀 Héllo\n\n> e\u{301}\n"
        assertTinted(text, [("# 😀 Héllo", .heading), ("> e\u{301}", .quote)])
        XCTAssertEqual(spans(text).first?.range, NSRange(location: 0, length: 10))
    }

    // MARK: - Edge cases

    func testEmptyDocument() {
        XCTAssertEqual(spans(""), [])
        XCTAssertEqual(spans("\n\n"), [])
    }

    func testRangesAreClampedToTheBuffer() {
        let text = "a\nb"
        let ns = text as NSString
        let blocks = [
            MarkdownBlock.codeBlock(index: 0, code: "b", language: "", sourceLine: 1),
            MarkdownBlock.heading(index: 1, level: 1, title: "x", sourceLine: 7),
            MarkdownBlock.blockquote(index: 2, content: "y", level: 1, sourceLine: -1),
        ]
        let result = SourceTint.spans(for: blocks, lineStarts: SourceEditSupport.lineStarts(in: ns), in: ns)
        XCTAssertEqual(result, [SourceTint.Span(range: NSRange(location: 2, length: 1), kind: .verbatim)])
    }

    func testOutOfOrderBlocksNeverOverlap() {
        let text = "one\ntwo\nthree\n"
        let ns = text as NSString
        let blocks = [
            MarkdownBlock.codeBlock(index: 0, code: "", language: "", sourceLine: 1),
            MarkdownBlock.blockquote(index: 1, content: "", level: 1, sourceLine: 0),
        ]
        let result = SourceTint.spans(for: blocks, lineStarts: SourceEditSupport.lineStarts(in: ns), in: ns)
        assertWellFormed(result, length: ns.length)
    }

    func testMixedDocumentIsWellFormed() {
        let text = """
        ---
        a: 1
        ---
        Title
        =====

        > [!NOTE]
        > n

        ```
        x
        ```
        [ref]: https://example.com
        ## H
        > a
        >> b
        Text[^1]

        [^1]: foot
        """
        let result = spans(text)
        XCTAssertFalse(result.isEmpty)
        assertWellFormed(result, length: (text as NSString).length)
    }
}
