import XCTest
import SwiftUI
import AppKit

/// Blocks a list item owns (v1.15, `ListNesting`): an indented or fenced code
/// block under an item is a code block drawn at the item's text, a second
/// paragraph of the item starts there too, and the list's numbering and
/// marker alignment go on past them. Expected structures come from GitHub's
/// renderer (`gh api markdown -f mode=gfm`); the relevant HTML is quoted at
/// each test.
final class ListContentTests: XCTestCase {

    private let theme = MarkdownTheme.cached(for: .light)

    private func parse(_ markdown: String, fontScale: CGFloat = 1.0) -> [MarkdownBlock] {
        MarkdownBlockParser(theme: theme, fontScale: fontScale).parse(markdown)
    }

    private func measure(_ blocks: [MarkdownBlock], width: CGFloat = 640) -> MeasuredBlocks {
        BlockHeightMeasurer.measure(blocks: blocks, theme: theme, fontScale: 1, contentWidth: width,
                                    math: MathRendering(inlineImage: { _, _, _ in NSImage(size: NSSize(width: 24, height: 12)) },
                                                        displayHeight: { _, _, _ in 40 }))
    }

    /// The shape of the block list: `T:` + text, `C(indent):` + code.
    private func shape(_ blocks: [MarkdownBlock]) -> [String] {
        blocks.map { block in
            switch block.content {
            case .text(let attributed): return "T:" + String(attributed.characters)
            case .codeBlock(let code, let language):
                return "C" + (language.isEmpty ? "" : "[\(language)]") + (block.listIndent > 0 ? ">" : "") + ":" + code
            default: return block.id
            }
        }
    }

    /// Each paragraph of a text block: its text and its NSParagraphStyle.
    private func paragraphs(_ block: MarkdownBlock) throws -> [(text: String, style: NSParagraphStyle?)] {
        guard case .text(let attributed) = block.content else { return [] }
        let string = try NSAttributedString(attributed, including: \.appKit)
        var result: [(String, NSParagraphStyle?)] = []
        let text = string.string as NSString
        text.enumerateSubstrings(in: NSRange(location: 0, length: text.length), options: .byParagraphs) {
            paragraph, range, _, _ in
            result.append((paragraph ?? "",
                           string.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle))
        }
        return result
    }

    /// Where the item text of a text block's FIRST paragraph (a list item)
    /// starts — wrapped lines hang there, the first line's text too.
    private func itemTextX(_ block: MarkdownBlock) throws -> CGFloat {
        try XCTUnwrap(paragraphs(block).first?.style?.headIndent)
    }

    // MARK: - Indented code

    /// ```
    /// 1. Step one
    ///
    ///        indented code under the item
    ///
    /// 2. Step two
    /// ```
    /// GitHub: `<ol><li><p>Step one</p><pre><code>indented code under the item
    /// </code></pre></li><li><p>Step two</p></li></ol>`
    func testIndentedCodeUnderAnItemIsACodeBlockAtTheItemText() throws {
        let blocks = parse("1. Step one\n\n       indented code under the item\n\n2. Step two")
        XCTAssertEqual(shape(blocks), ["T:1. Step one", "C>:indented code under the item", "T:2. Step two"])
        XCTAssertEqual(blocks.map(\.sourceLine), [0, 2, 4])
        let itemX = try itemTextX(blocks[0])
        XCTAssertEqual(blocks[1].listIndent, itemX, accuracy: 0.01)
        // The numbering and the marker alignment go on past the code.
        XCTAssertEqual(try itemTextX(blocks[2]), itemX, accuracy: 0.01)
    }

    /// A bullet, a task item, a wide marker gap and a tab all count from the
    /// item's CONTENT column. GitHub (each): `<li>…<pre><code>…</code></pre></li>`,
    /// the tab case's code keeping the one column the tab left: `<code> tab-indented code`.
    func testIndentedCodeCountsFromTheContentColumn() throws {
        let bullet = parse("- item one\n\n      code under bullet\n- item two")
        XCTAssertEqual(shape(bullet), ["T:• item one", "C>:code under bullet", "T:• item two"])
        XCTAssertEqual(bullet[1].listIndent, try itemTextX(bullet[0]), accuracy: 0.01)

        let task = parse("- [ ] task one\n\n      code under a task item\n\n- [x] task two")
        XCTAssertEqual(shape(task), ["T:☐ task one", "C>:code under a task item", "T:☑ task two"])
        XCTAssertEqual(task[1].listIndent, try itemTextX(task[0]), accuracy: 0.01)

        let wide = parse("-   wide item\n\n        code under wide item (8 spaces)")
        XCTAssertEqual(shape(wide).last, "C>:code under wide item (8 spaces)")

        let tab = parse("1. Step one\n\n\t    tab-indented code\n\n2. Step two")
        XCTAssertEqual(shape(tab), ["T:1. Step one", "C>: tab-indented code", "T:2. Step two"])
    }

    /// Two columns short of the code indent: a paragraph of the item.
    /// GitHub: `<li><p>Step one</p><p>five spaces only (2 past content)</p></li>`
    func testLessThanFourColumnsPastTheContentIsAParagraphOfTheItem() throws {
        let blocks = parse("1. Step one\n\n     five spaces only (2 past content)\n\n2. Step two")
        XCTAssertEqual(blocks.count, 3)
        XCTAssertFalse(shape(blocks).contains { $0.hasPrefix("C") })
        XCTAssertEqual(try paragraphs(blocks[1]).first?.text, "    five spaces only (2 past content)")
    }

    /// An indented line right after the item's text continues it (an
    /// indented code block cannot interrupt a paragraph).
    /// GitHub: `<li>item text<br>indented continuation, not code</li>`
    func testAnIndentedLineAfterItemTextIsNotCode() {
        let blocks = parse("- item text\n      indented continuation, not code\n- next")
        XCTAssertEqual(shape(blocks), ["T:• item text indented continuation, not code\n• next"])
    }

    /// Blank lines inside the code are code; the trailing one is not, and the
    /// list goes on after it.
    /// GitHub: `<pre><code>line one\n\nline three after blank\n</code></pre></li><li><p>Next</p>`
    func testBlankLinesInsideIndentedCodeAreCode() {
        let blocks = parse("1. Step\n\n       line one\n\n       line three after blank\n2. Next")
        XCTAssertEqual(shape(blocks), ["T:1. Step", "C>:line one\n\nline three after blank", "T:2. Next"])
        XCTAssertEqual(blocks.map(\.sourceLine), [0, 2, 5])
    }

    /// Inside indented code a fence, a heading or an item marker is code.
    func testIndentedCodeTakesMarkersLiterally() {
        let blocks = parse("- item\n\n      ```\n      # not a heading\n      - not an item\n\n- next")
        XCTAssertEqual(shape(blocks), ["T:• item", "C>:```\n# not a heading\n- not an item", "T:• next"])
    }

    // MARK: - Fenced code

    /// GitHub: `<li><p>Step two</p><div class="highlight highlight-source-shell"><pre>fenced code inside the item</pre></div><p>A second paragraph of the same item.</p></li>`
    func testFencedCodeInsideAnItemIsAtTheItemText() throws {
        let blocks = parse("""
        1. Step one
        2. Step two

           ```sh
           fenced code inside the item
           ```

           A second paragraph of the same item.

        3. Step three
        """)
        XCTAssertEqual(shape(blocks), ["T:1. Step one\n2. Step two", "C[sh]>:fenced code inside the item",
                                       "T:    A second paragraph of the same item.", "T:3. Step three"])
        let itemX = try itemTextX(blocks[0])
        XCTAssertEqual(blocks[1].listIndent, itemX, accuracy: 0.01)
        XCTAssertEqual(try itemTextX(blocks[3]), itemX, accuracy: 0.01)

        // Tight: right under the item line. GitHub: `<li>item one\n<pre><code>…`
        let tight = parse("- item one\n  ```\n  code right after the item line\n  ```\n- item two")
        XCTAssertEqual(shape(tight), ["T:• item one", "C>:code right after the item line", "T:• item two"])
        XCTAssertEqual(tight[1].listIndent, try itemTextX(tight[0]), accuracy: 0.01)
    }

    /// A fence indented less than the item's content column is not in it:
    /// GitHub ends the list (`<ol><li>Step one</li></ol><pre><code>…`), so
    /// the code stays at the margin.
    func testAFenceShortOfTheContentColumnIsNotTheItems() {
        let blocks = parse("1. Step one\n\n  ```\n  fence indented 2 under a 3-wide marker\n  ```\n\n2. Step two")
        XCTAssertEqual(shape(blocks)[1], "C:fence indented 2 under a 3-wide marker")
        XCTAssertEqual(blocks[1].listIndent, 0)
    }

    // MARK: - Nesting, numbering, the end of the list

    /// Code under the third level is at the third level's text, and that
    /// level's numbering goes on after it.
    /// GitHub: `<ul><li>level one<ul><li>level two<ol><li><p>level three ordered</p><pre><code>…</code></pre></li><li><p>level three again</p>…`
    func testCodeUnderTheThirdLevelIsAtThatLevelsText() throws {
        let blocks = parse("""
        - level one
          - level two
            1. level three ordered

                   code under level three

            2. level three again
          - level two again
        - level one again
        """)
        XCTAssertEqual(blocks.count, 3)
        XCTAssertEqual(shape(blocks)[1], "C>:code under level three")
        let first = try paragraphs(blocks[0])
        XCTAssertEqual(first.last?.text, "        1. level three ordered")
        let levelThreeX = try XCTUnwrap(first.last?.style?.headIndent)
        XCTAssertEqual(blocks[1].listIndent, levelThreeX, accuracy: 0.01)
        XCTAssertEqual(try itemTextX(blocks[2]), levelThreeX, accuracy: 0.01)
        // Deeper than the first level's text, as on GitHub.
        XCTAssertGreaterThan(blocks[1].listIndent, try XCTUnwrap(first.first?.style?.headIndent))
    }

    /// GitHub: `<ol start="8"><li><p>Eight</p><pre><code>code</code></pre></li><li><p>Nine</p></li><li><p>Ten</p></li></ol>`
    /// — one list: "8." and "9." hang under "10."'s width like a list without code.
    func testNumberingAndAlignmentContinueAcrossTheCode() throws {
        let blocks = parse("8. Eight\n\n   ```\n   code\n   ```\n\n9. Nine\n10. Ten")
        XCTAssertEqual(shape(blocks), ["T:8. Eight", "C>:code", "T:9. Nine\n10. Ten"])
        let hangs = try (paragraphs(blocks[0]) + paragraphs(blocks[2])).map { try XCTUnwrap($0.style?.headIndent) }
        XCTAssertEqual(Set(hangs).count, 1, "\(hangs)")
        XCTAssertEqual(blocks[1].listIndent, hangs[0], accuracy: 0.01)
    }

    /// A paragraph at the margin ends the list; what follows is not the
    /// list's. GitHub: `…</li></ol><p>Paragraph that ends the list.</p><ol start="2">`
    func testAParagraphAtTheMarginEndsTheList() throws {
        let blocks = parse("1. Step one\n\n   ```\n   code in item\n   ```\n\nParagraph that ends the list.\n\n2. Step two")
        XCTAssertEqual(shape(blocks)[2], "T:Paragraph that ends the list.")
        XCTAssertNil(try paragraphs(blocks[2]).first?.style)
        XCTAssertGreaterThan(blocks[1].listIndent, 0)

        // After the code, an unindented line is not lazy: the list is over.
        // GitHub: `…</li></ol><p>not indented after code<br>2. Next</p>`
        let lazy = parse("1. Step\n\n   ```\n   code\n   ```\nnot indented after code\n2. Next")
        XCTAssertEqual(shape(lazy).last, "T:not indented after code 2. Next")
        XCTAssertNil(try paragraphs(lazy[2]).first?.style)
    }

    // MARK: - Paragraphs of an item

    /// GitHub: `<li><p>item one</p><p>second paragraph of item one</p></li>`.
    /// Drawn at the item's text (every line: wrapped ones hang there too); the
    /// characters carry one indent unit more than the item for print/PDF and
    /// copy, as a nested item's do.
    func testASecondParagraphStartsAtTheItemText() throws {
        let blocks = parse("- item one\n\n  second paragraph of item one that is long enough to wrap "
                           + String(repeating: "and wrap ", count: 30) + "\n\n- item two")
        XCTAssertEqual(blocks.count, 3)
        let paragraph = try XCTUnwrap(paragraphs(blocks[1]).first)
        XCTAssertTrue(paragraph.text.hasPrefix("    second paragraph"))
        let itemX = try itemTextX(blocks[0])
        let style = try XCTUnwrap(paragraph.style)
        XCTAssertEqual(style.headIndent, itemX, accuracy: 0.01)
        let spaces = ("    " as NSString).size(withAttributes: [.font: theme.fonts.appKit(size: 14)]).width
        XCTAssertEqual(style.firstLineHeadIndent + spaces, itemX, accuracy: 0.01)

        // The text is laid out at the item's x: the first glyph of the words.
        let measured = measure(blocks)
        let string = try XCTUnwrap(measured.converted[blocks[1].id])
        let storage = NSTextStorage(attributedString: string)
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: 640, height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
        let wordStart = (string.string as NSString).range(of: "second").location
        let x = layout.location(forGlyphAt: layout.glyphIndexForCharacter(at: wordStart)).x
            + layout.lineFragmentRect(forGlyphAt: 0, effectiveRange: nil).minX
        XCTAssertEqual(x, itemX, accuracy: 0.6)
        let wrapped = layout.lineFragmentUsedRect(forGlyphAt: layout.glyphIndexForCharacter(at: string.length - 1),
                                                  effectiveRange: nil)
        XCTAssertEqual(wrapped.minX, itemX, accuracy: 0.6)
    }

    /// A paragraph outside any list is untouched.
    func testAParagraphOutsideAListHasNoItemColumn() throws {
        let blocks = parse("Intro.\n\n  indented paragraph\n\n- item")
        XCTAssertNil(try paragraphs(blocks[1]).first?.style)
        XCTAssertEqual(try paragraphs(blocks[1]).first?.text, "  indented paragraph")
    }

    /// A line after a hard break is more of the item's paragraph, so the
    /// next ordered item is an item, not text. GitHub (gfm and markdown):
    /// `<ol><li>item 1<br>line two</li><li>item 2</li></ol>`; a plain
    /// paragraph keeps `2.` as text: `<p>para<br>line two\n2. not an item</p>`.
    func testAHardBreakInsideAnItemKeepsTheNextItem() throws {
        let blocks = parse("1. item 1  \n   line two\n2. item 2")
        let lines = try paragraphs(blocks[0])
        XCTAssertEqual(lines.map(\.text), ["1. item 1", "    line two", "2. item 2"])
        XCTAssertEqual(lines[1].style?.headIndent, lines[0].style?.headIndent)
        XCTAssertEqual(MarkdownRenderer.joinSoftBreaks(["para  ", "line two", "2. not an item"]),
                       ["para", "line two 2. not an item"])
    }

    /// Twelve items of four hard-broken lines are cut into two rows
    /// (`textChunkLineLimit`): every item is one, and "8."/"9." above and
    /// below the cut hang under "12."'s width like the rest.
    func testHardBrokenItemsCutIntoRowsKeepOneTextEdge() throws {
        let markdown = (1...12).map { "\($0). item \($0)  \n   line two  \n   line three  \n   line four" }
            .joined(separator: "\n")
        let blocks = parse(markdown)
        XCTAssertEqual(blocks.map(\.joinsPrevious), [false, true])
        let items = try blocks.flatMap { try paragraphs($0) }.filter { $0.text.first?.isNumber == true }
        XCTAssertEqual(items.count, 12)
        XCTAssertEqual(Set(items.map { $0.style?.headIndent ?? -1 }).count, 1)
    }

    // MARK: - Measurer, rhythm

    /// The measurer lays the code out at the width the view gives it: the
    /// column less the list indent (the view pads by it).
    func testIndentedCodeIsMeasuredAtTheNarrowerWidth() throws {
        let long = String(repeating: "x", count: 300)
        let blocks = parse("1. Step\n\n   ```\n   \(long)\n   ```")
        let code = blocks[1]
        XCTAssertGreaterThan(code.listIndent, 0)
        let atItem = measure(blocks, width: 200).table.heights[1]
        let flat = code.withListIndent(0)
        let atNarrowerColumn = measure([flat], width: 200 - code.listIndent).table.heights[0]
        XCTAssertEqual(atItem, atNarrowerColumn)
        XCTAssertGreaterThan(atItem, measure([flat], width: 200).table.heights[0])
        XCTAssertEqual(BlockLayout.Code.textWidth(contentWidth: 200, listIndent: code.listIndent),
                       200 - code.listIndent - 2 * BlockLayout.Code.horizontalPadding)
    }

    /// No new rhythm numbers: list text → code in the item → list text has
    /// the same gaps as paragraph → code → paragraph (`blockMargin`, edge to
    /// edge — text → box and box → text).
    func testGapsAroundCodeInAnItemAreTheTextBoxPairs() {
        let inItem = measure(parse("1. Step one\n\n       code\n\n2. Step two")).table.spacingAbove
        let flat = measure(parse("Step one\n\n```\ncode\n```\n\nStep two")).table.spacingAbove
        XCTAssertEqual(inItem.count, 3)
        XCTAssertEqual(inItem[1], flat[1], accuracy: 0.01)
        XCTAssertEqual(inItem[2], flat[2], accuracy: 0.01)
    }

    /// Zoom: the indent is in points at the parse's scale — the item's text
    /// x at that zoom (not 1.5 × the 100 % value: marker widths do not scale
    /// linearly with the font size).
    func testTheIndentFollowsTheItemAtEveryZoom() throws {
        let markdown = "- item\n\n      code"
        for scale: CGFloat in [1, 1.5, 2] {
            let blocks = parse(markdown, fontScale: scale)
            XCTAssertEqual(blocks[1].listIndent, try itemTextX(blocks[0]), accuracy: 0.01)
            XCTAssertGreaterThan(blocks[1].listIndent, 16 * scale)
        }
    }

    // MARK: - Review fixes

    /// An image line is paragraph text (CommonMark): the item's paragraph
    /// goes on, so a deeper line after it is more text, not code.
    /// GitHub: `<li>item\n<a…><img alt="i"…></a>\nmore text</li>`
    func testAnImageLineKeepsTheItemsParagraphOpen() throws {
        for image in ["![i](https://x.org/a.png)", "<img src=\"https://x.org/a.png\" alt=\"i\">"] {
            let blocks = parse("- item\n  \(image)\n      more text")
            XCTAssertFalse(shape(blocks).contains { $0.hasPrefix("C") }, image)
            let last = try XCTUnwrap(paragraphs(try XCTUnwrap(blocks.last)).first)
            XCTAssertEqual(last.text, "    more text", image)
            XCTAssertEqual(last.style?.headIndent ?? -1, try itemTextX(blocks[0]), accuracy: 0.01, image)
        }
    }

    /// Definitions in an item's indented code are code: nothing is defined.
    /// GitHub: `<pre><code>[ref]: https://example.com\n[^1]: note\n</code></pre>`
    /// and `<p>See [ref] and x[^1].</p>`
    func testDefinitionsInsideIndentedCodeStayCode() {
        let blocks = parse("1. Step\n\n       [ref]: https://example.com\n       [^1]: note\n\nSee [ref] and x[^1].")
        let shapes = shape(blocks)
        XCTAssertEqual(shapes.count, 3, "\(shapes)")    // no footnotes block
        XCTAssertEqual(shapes[1], "C>:[ref]: https://example.com\n[^1]: note")
        XCTAssertEqual(shapes[2], "T:See [ref] and x[^1].")
    }

    /// A link definition at the margin ends the list: the indented line
    /// after it is not the item's. GitHub: `<ul><li>a</li></ul><pre><code>  code`
    /// (top-level indented code, which QuickMD keeps as text — out of scope).
    func testALinkDefinitionAtTheMarginEndsTheList() {
        let blocks = parse("- a\n\n[x]: http://y\n\n      code")
        XCTAssertFalse(shape(blocks).contains { $0.hasPrefix("C") }, "\(shape(blocks))")
    }

    /// A picture, a table, a quote or a formula under an item stays at the
    /// margin (only code is indented), but it is the item's: code after it
    /// is still the item's code and the numbering goes on.
    /// GitHub: all of them and every `<pre><code>code after …` inside the
    /// first `<li>`, then `<li><p>Next</p></li>`.
    func testOtherBlocksUnderAnItemKeepTheListGoing() throws {
        let blocks = parse("""
        1. Step

           ![i](https://x.org/a.png)

               code after image

           | a | b |
           |---|---|
           | 1 | 2 |

               code after table

           > quote

               code after quote

           $$
           x
           $$

               code after math

        2. Next
        """)
        let codes = blocks.filter { if case .codeBlock = $0.content { return true }; return false }
        XCTAssertEqual(codes.count, 4, "\(shape(blocks))")
        let itemX = try itemTextX(blocks[0])
        for code in codes { XCTAssertEqual(code.listIndent, itemX, accuracy: 0.01) }
        let next = try XCTUnwrap(blocks.last)
        XCTAssertEqual(try paragraphs(next).first?.text, "2. Next")
        XCTAssertEqual(try itemTextX(next), itemX, accuracy: 0.01)
    }

    /// Only a code block is drawn at the item's text; a diagram fence under
    /// an item is not indented (its views know nothing of an indent).
    func testADiagramFenceUnderAnItemIsNotIndented() {
        let blocks = parse("- item\n\n  ```mermaid\n  graph TD; A-->B\n  ```\n\n  ```svg\n  <svg/>\n  ```")
        for block in blocks.dropFirst() { XCTAssertEqual(block.listIndent, 0, block.id) }
    }

    /// The code box never moves in more than half the column, in the
    /// measurer and the view alike (one function), so a deep item in a
    /// narrow column still leaves the code a width.
    func testTheCodeIndentIsClampedToHalfTheColumn() {
        let deep = (0..<9).map { String(repeating: "  ", count: $0) + "- level \($0)" }.joined(separator: "\n")
        let blocks = parse(deep + "\n\n" + String(repeating: " ", count: 16 + 6) + "code", fontScale: 2)
        let code = try! XCTUnwrap(blocks.last)
        XCTAssertEqual(shape([code]).first, "C>:code")
        let width: CGFloat = 200
        XCTAssertGreaterThan(code.listIndent, width / 2)
        XCTAssertEqual(BlockLayout.Code.leadingInset(listIndent: code.listIndent, contentWidth: width), width / 2)
        XCTAssertEqual(BlockLayout.Code.textWidth(contentWidth: width, listIndent: code.listIndent),
                       width / 2 - 2 * BlockLayout.Code.horizontalPadding)
        // The row is measured at that width: as a flat block at half the column.
        let flat = code.withListIndent(0)
        XCTAssertEqual(measure([code], width: width).table.heights[0],
                       measure([flat], width: width / 2).table.heights[0])
        XCTAssertEqual(BlockLayout.Code.leadingInset(listIndent: 30, contentWidth: width), 30)
    }

    /// Print has no list gutter (SwiftUI `Text` ignores the paragraph
    /// style): the code lines up with the item's characters there.
    func testPrintedIndentLeavesTheGutterOut() throws {
        let blocks = MarkdownBlockParser(colorScheme: .light).parse("1. Step\n\n       code")
        let prefix = ("1. " as NSString).size(withAttributes: [.font: MarkdownTheme.exportTheme(for: .light).fonts.appKit(size: 14)]).width
        XCTAssertEqual(MarkdownRenderer.printedListIndent(blocks[1].listIndent), prefix, accuracy: 0.01)
        XCTAssertEqual(MarkdownRenderer.printedListIndent(0), 0)
    }

    // MARK: - Content column

    func testContentColumnOfAnItem() {
        XCTAssertEqual(ListNesting.contentColumn(ofItem: "- a"), 2)
        XCTAssertEqual(ListNesting.contentColumn(ofItem: "1. a"), 3)
        XCTAssertEqual(ListNesting.contentColumn(ofItem: "10) a"), 4)
        XCTAssertEqual(ListNesting.contentColumn(ofItem: "  - a"), 4)
        XCTAssertEqual(ListNesting.contentColumn(ofItem: "-    a"), 5)   // four spaces: all marker gap
        XCTAssertEqual(ListNesting.contentColumn(ofItem: "-     a"), 2)  // five: one gap + indented content
        XCTAssertEqual(ListNesting.contentColumn(ofItem: "\t- a"), 6)
        XCTAssertEqual(ListNesting.contentColumn(ofItem: "- [ ] task"), 2)
    }
}
