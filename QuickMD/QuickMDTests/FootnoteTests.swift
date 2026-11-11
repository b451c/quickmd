import XCTest
import SwiftUI
import AppKit

/// Footnotes as GitHub numbers and reads them (1.15 roadmap items 7 + 8).
/// Every expected value below comes from GitHub's renderer
/// (`gh api markdown -f mode=markdown`, 2026-11-11), quoted in each test as
/// `{label=number}` for a reference's `<sup>` and the list in its order.
final class FootnoteTests: XCTestCase {

    private let theme = MarkdownTheme.cached(for: .light)

    private func parse(_ markdown: String) -> [MarkdownBlock] {
        MarkdownBlockParser(theme: theme).parse(markdown)
    }

    private func text(_ block: MarkdownBlock) -> String? {
        if case .text(let attr) = block.content {
            return String(attr.characters).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    /// The footnote list's entries (the synthetic last block, rule dropped),
    /// or nil when the document lists no footnote.
    private func notes(_ blocks: [MarkdownBlock]) -> [String]? {
        guard let last = blocks.last, let shown = text(last), shown.hasPrefix("─") else { return nil }
        return Array(shown.components(separatedBy: "\n").dropFirst())
    }

    /// The texts of the document's own blocks (no footnote list).
    private func bodyTexts(_ blocks: [MarkdownBlock]) -> [String] {
        blocks.compactMap(text).filter { !$0.hasPrefix("─") }
    }

    // MARK: - Numbering (item 7)

    /// GitHub: `Alpha{b=1} then{a=2} again{b=1}.`, list `Note B.`, `Note A.`;
    /// `[^c]` is never referenced and not listed. Before: numbers by
    /// definition order (`Alpha²`, `then¹`) and all three listed.
    func testFootnotesAreNumberedByTheirFirstReference() {
        let blocks = parse("Alpha[^b] then[^a] again[^b].\n\n[^a]: Note A.\n[^b]: Note B.\n[^c]: Unused.\n")
        XCTAssertEqual(bodyTexts(blocks), ["Alpha\u{00B9} then\u{00B2} again\u{00B9}."])
        XCTAssertEqual(notes(blocks), ["1. Note B.", "2. Note A."])
    }

    /// GitHub: numeric labels are labels, `P{1=1} and{2=2} and{10=3}`, list
    /// one, two, ten — whatever order the definitions stand in.
    func testNumericLabelsAreNumberedByReferenceNotByLabel() {
        let blocks = parse("P[^1] and[^2] and[^10].\n\n[^10]: ten\n[^2]: two\n[^1]: one\n")
        XCTAssertEqual(bodyTexts(blocks), ["P\u{00B9} and\u{00B2} and\u{00B3}."])
        XCTAssertEqual(notes(blocks), ["1. one", "2. two", "3. ten"])
    }

    /// GitHub: a definition nothing references draws nothing — no list at
    /// all; a reference without a definition stays `[^zz]`.
    func testUnreferencedDefinitionsAreNotListed() {
        let blocks = parse("Missing[^zz] here.\n\n[^a]: A.\n")
        XCTAssertEqual(bodyTexts(blocks), ["Missing[^zz] here."])
        XCTAssertNil(notes(blocks))
    }

    /// GitHub (`X[^Note] y[^NOTE]` with `[^note]:`): both `{note=1}`, one entry.
    func testLabelsAreCaseInsensitiveAndKeepOneNumber() {
        let blocks = parse("X[^Note] y[^NOTE].\n\n[^note]: N.\n")
        XCTAssertEqual(bodyTexts(blocks), ["X\u{00B9} y\u{00B9}."])
        XCTAssertEqual(notes(blocks), ["1. N."])
    }

    /// GitHub: `Head{h=1}` (id `head1`), `quote{q=2}`, `item{l=3}`,
    /// `t{t=4}` (table header), `alert{n=5}`, `Text{p=6}`; list H Q L T N P —
    /// the definitions stand in the reverse order.
    func testReferencesInEveryBlockKindCountInDocumentOrder() {
        let md = """
        # Head[^h]

        > quote[^q]

        - item[^l]

        | t[^t] |
        |---|
        | c |

        > [!NOTE]
        > alert[^n]

        Text[^p].

        [^p]: P.
        [^n]: N.
        [^t]: T.
        [^l]: L.
        [^q]: Q.
        [^h]: H.
        """
        let blocks = parse(md)
        let plain = MarkdownRenderer(theme: theme)
        guard case .heading(let level, let title, _) = blocks[0].content,
              case .blockquote(let quote, _) = blocks[1].content,
              case .table(let headers, _, _, _) = blocks[3].content,
              case .alert(_, let alert) = blocks[4].content else {
            return XCTFail("blocks: \(blocks.map(\.content))")
        }
        XCTAssertEqual(String(plain.renderHeader(title, level: level).characters), "Head\u{00B9}")
        XCTAssertEqual(String(plain.renderQuotedBody(quote).characters), "quote\u{00B2}")
        XCTAssertTrue(text(blocks[2])?.hasSuffix("item\u{00B3}") == true, text(blocks[2]) ?? "nil")
        XCTAssertEqual(String(plain.renderInline(headers[0]).characters), "t\u{2074}")
        XCTAssertEqual(String(plain.renderQuotedBody(alert).characters), "alert\u{2075}")
        XCTAssertEqual(text(blocks[5]), "Text\u{2076}.")
        XCTAssertEqual(notes(blocks), ["1. H.", "2. Q.", "3. L.", "4. T.", "5. N.", "6. P."])
        let anchors = HeadingAnchors.headings(of: blocks, renderer: plain)
        XCTAssertEqual(HeadingAnchors.ids(for: anchors.map(\.text)), ["head1"])
    }

    /// GitHub: `# T{a=1} and{b=2}` has the id `t1-and2` — the heading's
    /// numbers are the new ones (definition order gave `t2-and1`).
    func testHeadingIdsUseTheFirstReferenceNumbers() {
        let blocks = parse("# T[^a] and[^b]\n\nP[^b]\n\n[^b]: B\n[^a]: A\n")
        let anchors = HeadingAnchors.headings(of: blocks, renderer: MarkdownRenderer(theme: theme))
        XCTAssertEqual(HeadingAnchors.ids(for: anchors.map(\.text)), ["t1-and2"])
        XCTAssertEqual(notes(blocks), ["1. A", "2. B"])
    }

    /// A definition's text counts where the definition STANDS (GitHub walks
    /// the document): `P1{b=1}`, then `[^a]: A refers{c=2}` above `P2{a=3}`;
    /// list B, C, A. And a footnote cited only by an UNREFERENCED definition
    /// is still listed (`P1{b=1}`, list B, Y — X dropped).
    func testReferencesInsideDefinitionsCountWhereTheDefinitionStands() {
        let blocks = parse("P1[^b]\n\n[^a]: A refers[^c].\n\nP2[^a]\n\n[^b]: B\n[^c]: C\n")
        XCTAssertEqual(bodyTexts(blocks), ["P1\u{00B9}", "P2\u{00B3}"])
        XCTAssertEqual(notes(blocks), ["1. B", "2. C", "3. A refers\u{00B2}."])

        let orphan = parse("P1[^b]\n\n[^x]: X refers[^y].\n[^b]: B\n[^y]: Y\n")
        XCTAssertEqual(notes(orphan), ["1. B", "2. Y"])

        // A footnote that cites itself keeps its number (`self{a=1}`).
        XCTAssertEqual(notes(parse("P[^a]\n\n[^a]: self[^a] ref\n")), ["1. self\u{00B9} ref"])
    }

    /// GitHub: `` `x[^a]` `` and a fenced `[^a]` are code, `\[^a]` is text —
    /// none is a reference, so `and{b=1}` and only B is listed.
    func testCodeAndEscapesAreNoReferences() {
        let blocks = parse("Code `x[^a]` and[^b] \\[^a].\n\n```\n[^a]\n```\n\n[^a]: A.\n[^b]: B.\n")
        XCTAssertEqual(text(blocks[0]), "Code x[^a] and\u{00B9} [^a].")
        XCTAssertEqual(notes(blocks), ["1. B."])
    }

    /// GitHub: `P[^x {a=1} and {b=2}` — an undefined `[^x` does not swallow
    /// the reference after it.
    func testAnUndefinedLabelDoesNotHideTheNextReference() {
        let blocks = parse("P[^x [^a] and [^b]\n\n[^b]: B\n[^a]: A\n")
        XCTAssertEqual(bodyTexts(blocks), ["P[^x \u{00B9} and \u{00B2}"])
        XCTAssertEqual(notes(blocks), ["1. A", "2. B"])
    }

    // MARK: - Multi-line definitions (item 8)

    /// GitHub: `<p>first line⏎lazy line</p>` inside the footnote (a soft
    /// break), `After.` a paragraph of its own. Before: `lazy line` was a
    /// body paragraph.
    func testALazyLineContinuesTheFootnote() {
        let blocks = parse("Text[^a] end.\n\n[^a]: first line\nlazy line\n\nAfter.\n")
        XCTAssertEqual(bodyTexts(blocks), ["Text\u{00B9} end.", "After."])
        XCTAssertEqual(notes(blocks), ["1. first line lazy line"])
        // A table row and `===` are lazy text too (GitHub d37/d31).
        XCTAssertEqual(notes(parse("P[^a]\n\n[^a]: note\n| a | b |\n")), ["1. note | a | b |"])
        XCTAssertEqual(notes(parse("P[^a]\n\n[^a]: note\nmore\n===\n")), ["1. note more ==="])
    }

    /// GitHub: a paragraph indented 4 columns after blank lines is the
    /// footnote's next paragraph (`<p>first para</p><p>second para</p>`),
    /// also after two blanks or a tab; 2 columns is not (a body paragraph).
    func testIndentedParagraphsContinueTheFootnote() {
        let blocks = parse("Text[^a] end.\n\n[^a]: first para\n\n    second para\n\nAfter.\n")
        XCTAssertEqual(bodyTexts(blocks), ["Text\u{00B9} end.", "After."])
        XCTAssertEqual(notes(blocks), ["1. first para", "second para"])
        XCTAssertEqual(notes(parse("P[^a]\n\n[^a]: note\n\n\n    after two blanks\n")), ["1. note", "after two blanks"])
        XCTAssertEqual(notes(parse("P[^a]\n\n[^a]: note\n\n\tafter tab\n")), ["1. note", "after tab"])

        let shallow = parse("P[^a] q[^b]\n\n[^a]: one\n  two-space\n\n  two-space para\n\n[^b]: B\n")
        XCTAssertEqual(bodyTexts(shallow), ["P\u{00B9} q\u{00B2}", "two-space para"])
        XCTAssertEqual(notes(shallow), ["1. one two-space", "2. B"])

        // An empty `[^a]:` takes an indented first line (GitHub `indented first`).
        XCTAssertEqual(notes(parse("Text[^a].\n\n[^a]:\n    indented first\n")), ["1. indented first"])
        // A hard break stays a line break (GitHub `line one<br>`).
        XCTAssertEqual(notes(parse("P[^a]\n\n[^a]: line one  \n  hard break before\n")),
                       ["1. line one", "hard break before"])
        // A code span may run over the soft break (GitHub `<code>code span</code>`).
        XCTAssertEqual(notes(parse("P[^a]\n\n[^a]: one `code\nspan` two\n")), ["1. one code span two"])
    }

    /// GitHub: a `[x]: url` line RIGHT UNDER `[^a]: note` is the footnote's
    /// text (`note⏎[x]: <a>https://example.com</a>`) and `[x]` stays
    /// literal; above the footnote, or after a blank line, it defines `x`.
    /// Before: it always defined `x`. Indented 4 under the footnote it is
    /// text as well; indented 4 after a blank line it defines `x` again.
    func testALinkDefinitionRightUnderAFootnoteIsItsText() {
        func shape(_ md: String) -> (body: String?, links: [String], notes: [String]?) {
            let blocks = parse(md)
            guard case .text(let attr) = blocks[0].content else { return (nil, [], notes(blocks)) }
            return (text(blocks[0]), attr.runs.compactMap { $0.link?.absoluteString }, notes(blocks))
        }
        let under = shape("Text[^a] and [x].\n\n[^a]: note\n[x]: https://example.com\n")
        XCTAssertEqual(under.body, "Text\u{00B9} and [x].")
        XCTAssertEqual(under.links, [])
        XCTAssertEqual(under.notes, ["1. note [x]: https://example.com"])

        for md in ["Text[^a] and [x].\n\n[x]: https://example.com\n[^a]: note\n",
                   "Text[^a] and [x].\n\n[^a]: note\n\n[x]: https://example.com\n",
                   "Text[^a] and [x].\n\n[^a]: note\n\n    [x]: https://example.com\n"] {
            let shown = shape(md)
            XCTAssertEqual(shown.body, "Text\u{00B9} and x.", md)
            XCTAssertEqual(shown.links, ["https://example.com"], md)
            XCTAssertEqual(shown.notes, ["1. note"], md)
        }

        let indentedUnder = shape("Text[^a] and [x].\n\n[^a]: note\n    [x]: https://example.com\n")
        XCTAssertEqual(indentedUnder.links, [])
        XCTAssertEqual(indentedUnder.notes, ["1. note [x]: https://example.com"])

        // In a chain of footnotes it is the LAST one's text (GitHub d33).
        let chain = parse("P[^a]\n\n[^a]: note\n[^b]: other\n[x]: https://e.com\n\n[x] and[^b]\n")
        XCTAssertEqual(bodyTexts(chain), ["P\u{00B9}", "[x] and\u{00B2}"])
        XCTAssertEqual(notes(chain), ["1. note", "2. other [x]: https://e.com"])
    }

    /// GitHub: a block start ends the definition — a list item (any number),
    /// a heading, a rule, a fence, a quote, an HTML block, another footnote —
    /// and nothing is lazy after an EMPTY `[^a]:` (e41: `lazy after empty`
    /// is a body paragraph, the footnote is empty).
    func testABlockStartEndsTheFootnote() {
        func kinds(_ blocks: [MarkdownBlock]) -> [String] {
            blocks.dropLast().map { block in
                switch block.content {
                case .text(let attr): return "t:" + String(attr.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                case .heading(let level, let title, _): return "h\(level):\(title)"
                case .codeBlock(let code, _): return "c:\(code)"
                case .blockquote(let content, _): return "q:\(content)"
                default: return "other"
                }
            }
        }
        let cases: [(String, [String])] = [
            ("P[^a]\n\n[^a]: note\n- list item\n", ["t:P\u{00B9}", "t:\u{2022} list item"]),
            ("P[^a]\n\n[^a]: note\n2. two\n", ["t:P\u{00B9}", "t:2. two"]),
            ("P[^a]\n\n[^a]: note\n# Heading\n", ["t:P\u{00B9}", "h1:Heading"]),
            ("P[^a]\n\n[^a]: note\n```\nfence\n```\n", ["t:P\u{00B9}", "c:fence"]),
            ("P[^a]\n\n[^a]: note\n> quote\n", ["t:P\u{00B9}", "q:quote"]),
            ("P[^a]\n\n[^a]: note\n<div>html</div>\n", ["t:P\u{00B9}", "t:<div>html</div>"]),
        ]
        for (md, expected) in cases {
            let blocks = parse(md)
            XCTAssertEqual(notes(blocks), ["1. note"], md)
            XCTAssertEqual(kinds(blocks), expected, md)
        }
        // `---` is a rule of the document, not a Setext underline of the note.
        let rule = parse("P[^a]\n\n[^a]: note\n---\n")
        XCTAssertEqual(notes(rule), ["1. note"])
        XCTAssertFalse(rule.contains { if case .heading = $0.content { return true }; return false })

        let empty = parse("P[^a]\n\n[^a]:\nlazy after empty\n")
        XCTAssertEqual(bodyTexts(empty), ["P\u{00B9}", "lazy after empty"])
        XCTAssertEqual(notes(empty), ["1."])

        // The next definition (GitHub `one`, `two`).
        XCTAssertEqual(notes(parse("Text[^a] [^b].\n\n[^a]: one\n[^b]: two\n")), ["1. one", "2. two"])
    }

    /// GitHub (f61): the duplicate `[^a]:` and its lazy line are dropped;
    /// the first definition is the footnote, `After.` a paragraph.
    func testADuplicateDefinitionTakesItsLinesAlong() {
        let blocks = parse("P[^a]\n\n[^a]: first\n[^a]: second\nlazy of the duplicate\n\nAfter.\n")
        XCTAssertEqual(bodyTexts(blocks), ["P\u{00B9}", "After."])
        XCTAssertEqual(notes(blocks), ["1. first"])
    }

    /// Source lines stay the document's: the blocks after a multi-line
    /// definition keep their original lines (section copy, Source Edit
    /// landing), the footnote list anchors to the last line.
    func testBlocksAfterAMultiLineDefinitionKeepTheirSourceLines() {
        let md = "Text[^a]\n\n[^a]: one\nlazy\n\n    more\n\n# After\n\nPara\n"
        let blocks = parse(md)
        XCTAssertEqual(blocks.map(\.sourceLine), [0, 7, 9, 10])
        XCTAssertEqual(text(blocks[2]), "Para")
        XCTAssertEqual(notes(blocks), ["1. one lazy", "more"])
        let toc = ToCEntry.entries(of: blocks)
        XCTAssertEqual(toc.map(\.sourceLine), [7])
    }

    /// The scan that numbers footnotes follows `tryParseFootnoteRef`: only
    /// defined labels, escapes and code skipped, normalised labels.
    func testFootnoteReferenceScan() {
        let defined: Set<String> = ["a", "b", "ss"]
        XCTAssertEqual(ReferenceLinks.footnoteReferences(in: "x[^B] `[^a]` \\[^a] [^ẞ] [^zz] [^a]", defined: defined),
                       ["b", "ss", "a"])
        XCTAssertEqual(ReferenceLinks.footnoteReferences(in: "[^a]", defined: []), [])
        XCTAssertEqual(ReferenceLinks.footnoteReferences(in: "[^] [^", defined: defined), [])
    }
}
