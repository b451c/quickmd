import XCTest
import SwiftUI
import AppKit

/// Inline-formatting tests for MarkdownRenderer: asserts on the rendered
/// plain text (markers consumed) and on semantic attributes (links).
final class RendererTests: XCTestCase {

    private var renderer: MarkdownRenderer {
        MarkdownRenderer(theme: MarkdownTheme.cached(for: .light))
    }

    private func rendered(_ text: String) -> String {
        String(renderer.renderInline(text).characters)
    }

    // MARK: - Emphasis

    func testBoldConsumesMarkers() {
        XCTAssertEqual(rendered("**bold**"), "bold")
        XCTAssertEqual(rendered("__bold__"), "bold")
    }

    func testItalicConsumesMarkers() {
        XCTAssertEqual(rendered("*italic*"), "italic")
    }

    func testBoldItalicConsumesMarkers() {
        XCTAssertEqual(rendered("***both***"), "both")
    }

    func testMidWordUnderscoreIsNotItalic() {
        XCTAssertEqual(rendered("snake_case_name"), "snake_case_name")
    }

    func testStrikethroughConsumesMarkers() {
        XCTAssertEqual(rendered("~~gone~~"), "gone")
    }

    func testNestedEmphasisInsideBold() {
        XCTAssertEqual(rendered("**bold *and italic* text**"), "bold and italic text")
    }

    // MARK: - Inline code

    func testInlineCodeSingleBacktick() {
        XCTAssertEqual(rendered("`code`"), "code")
    }

    func testInlineCodeDoubleBacktickStripsOneSpace() {
        XCTAssertEqual(rendered("`` `literal` ``"), "`literal`")
    }

    // MARK: - Escapes

    func testEscapedAsteriskIsLiteral() {
        XCTAssertEqual(rendered("\\*not italic\\*"), "*not italic*")
    }

    // MARK: - Links

    func testInlineLinkAttachesURL() {
        let attr = renderer.renderInline("[text](https://example.com)")
        XCTAssertEqual(String(attr.characters), "text")
        XCTAssertEqual(attr.runs.compactMap(\.link).first?.absoluteString, "https://example.com")
    }

    func testLinkWithParenthesesInURL() {
        let attr = renderer.renderInline("[wiki](https://en.wikipedia.org/wiki/Foo_(bar))")
        XCTAssertEqual(attr.runs.compactMap(\.link).first?.absoluteString,
                       "https://en.wikipedia.org/wiki/Foo_(bar)")
    }

    func testReferenceLinkResolvesFromDefinitions() {
        let refRenderer = MarkdownRenderer(theme: MarkdownTheme.cached(for: .light),
                                           referenceDefinitions: ["ref": "https://example.com"])
        let attr = refRenderer.renderInline("[text][ref]")
        XCTAssertEqual(attr.runs.compactMap(\.link).first?.absoluteString, "https://example.com")
    }

    func testInlineLinkTitleIsNotPartOfTheURL() {
        let attr = renderer.renderInline(#"[text](https://example.com "Title")"#)
        XCTAssertEqual(String(attr.characters), "text")
        XCTAssertEqual(attr.runs.compactMap(\.link).map(\.absoluteString), ["https://example.com"])
    }

    func testLinkTextMayContainBalancedBrackets() {
        let attr = renderer.renderInline("[a [b] c](https://example.com)")
        XCTAssertEqual(String(attr.characters), "a [b] c")
        XCTAssertEqual(attr.runs.compactMap(\.link).first?.absoluteString, "https://example.com")
    }

    func testLinkDestinationWithSpacesIsKeptWhole() {
        let attr = renderer.renderInline("[doc](My Notes.md)")
        XCTAssertEqual(String(attr.characters), "doc")
        XCTAssertEqual(attr.runs.compactMap(\.link).first?.absoluteString, "My%20Notes.md")
    }

    /// Runs `body` on a thread with the parse task's small (512 KB) stack, so
    /// unbounded recursion crashes here instead of passing on the 8 MB main stack.
    private func onSmallStack(_ body: @escaping () -> Void) {
        let done = DispatchSemaphore(value: 0)
        let thread = Thread { body(); done.signal() }
        thread.stackSize = 512 * 1024
        thread.start()
        XCTAssertEqual(done.wait(timeout: .now() + 30), .success)   // a hang detector, not a speed bound
    }

    /// Links cannot contain links: link text renders with links disabled, so
    /// nesting is bounded at one level however many brackets there are.
    /// Linear, not a wall-clock bound: 8× the nesting may cost at most 24×
    /// the CPU time (quadratic ≈ 64×) — `CostScaling`.
    func testDeeplyNestedLinkBracketsDoNotRecurse() {
        func nested(_ n: Int) -> String {
            String(repeating: "[", count: n) + "![a](b)" + String(repeating: "](u)", count: n)
        }
        let markdown = nested(5000)
        var text = ""
        onSmallStack {
            text = String(self.renderer.render(markdown).characters)
        }
        XCTAssertTrue(text.contains("[Image: a]"))
        let renderer = self.renderer
        let cost = CostScaling.compare(small: 625, limit: 24) { n in
            let markdown = nested(n)
            return { _ = renderer.render(markdown) }
        }
        XCTAssertLessThanOrEqual(cost.ratio, 24, cost.description)
    }

    /// Unclosed brackets cost O(1) each: the renderer keeps a bracket stack
    /// (no forward scan per `[`), and the only per-`]` work — checking the
    /// text as a reference label — is capped (`isLinkLabel`). Proved by
    /// counting that work for N and 4N, not by the clock (the 1 s assert
    /// this replaced depended on the machine).
    func testUnclosedBracketsRenderInLinearTime() {
        func labelWork(_ line: String) -> Int {
            var work = 0
            var openers: [String.Index] = []
            var index = line.startIndex
            while index < line.endIndex {
                let byte = line.utf8[index]
                if byte == UInt8(ascii: "[") { openers.append(line.utf8.index(after: index)) }
                if byte == UInt8(ascii: "]"), let open = openers.popLast() {
                    _ = InlineSyntaxScanner.isLinkLabel(line[open..<index], work: &work)
                }
                index = line.utf8.index(after: index)
            }
            return work
        }
        let small = String(repeating: "[[a] ", count: 5_000)
        let large = String(repeating: "[[a] ", count: 20_000)
        XCTAssertLessThanOrEqual(labelWork(large), 4 * labelWork(small))
        XCTAssertLessThanOrEqual(labelWork(large), large.utf8.count)
        // With a definition, so every `]` really asks for its label.
        let refRenderer = MarkdownRenderer(theme: MarkdownTheme.cached(for: .light),
                                           referenceDefinitions: ["b": "https://b.example"])
        let text = String(refRenderer.render(large).characters)
        XCTAssertTrue(text.hasPrefix("[[a] [[a]"))
        XCTAssertEqual(text.count, large.count, "every character kept (trailing space trimmed, newline added)")
    }

    func testInlineScreenshotImageWithSpaces() {
        XCTAssertEqual(rendered("see ![shot](Screenshot 2024-10-01 at 10.00.00.png) here"),
                       "see [Image: shot] here")
    }

    // MARK: - Inline images (D10 / D11)

    private var refRenderer: MarkdownRenderer {
        MarkdownRenderer(theme: MarkdownTheme.cached(for: .light),
                         referenceDefinitions: ["ref": "https://x.org/ref.png"])
    }

    func testInlineHttpImageCarriesItsLink() {
        let attr = renderer.renderInline("see ![pic](https://x.org/p.png) here")
        XCTAssertEqual(String(attr.characters), "see [Image: pic] here")
        XCTAssertEqual(attr.runs.compactMap(\.link).map(\.absoluteString), ["https://x.org/p.png"])
    }

    /// Clicking an embedded image used to open a multi-MB "Open data: link?" alert.
    func testInlineDataImageHasNoLink() {
        let attr = renderer.renderInline("see ![pic](data:image/png;base64,iVBORw0KGgo=) and ![x](DATA:image/gif;base64,R0lG)")
        XCTAssertEqual(String(attr.characters), "see [Image: pic] and [Image: x]")
        XCTAssertTrue(attr.runs.compactMap(\.link).isEmpty)
    }

    func testInlineImageWithEmptyAlt() {
        XCTAssertEqual(rendered("![](https://x.org/p.png)"), "[Image]")
    }

    func testInlineImageTitleAndPointyDestination() {
        let titled = renderer.renderInline(#"![a](https://x.org/p.png "t")"#)
        XCTAssertEqual(titled.runs.compactMap(\.link).map(\.absoluteString), ["https://x.org/p.png"])
        XCTAssertEqual(String(titled.characters), "[Image: a]")
        XCTAssertEqual(rendered("![a](<p q.png>) after"), "[Image: a] after")
    }

    func testInlineReferenceImagesResolve() {
        for markdown in ["![b][ref]", "![ref][]", "![ref]", "![b][REF]"] {
            let attr = refRenderer.renderInline(markdown)
            XCTAssertTrue(String(attr.characters).hasPrefix("[Image: "), "\(markdown) → \(String(attr.characters))")
            XCTAssertFalse(String(attr.characters).contains("!"), markdown)
            XCTAssertEqual(attr.runs.compactMap(\.link).map(\.absoluteString), ["https://x.org/ref.png"], markdown)
        }
    }

    func testUndefinedReferenceImageStaysLiteral() {
        XCTAssertEqual(String(refRenderer.renderInline("![b][nope]").characters), "![b][nope]")
        XCTAssertEqual(rendered("![b]"), "![b]")
    }

    /// The badge idiom: the link text holds an image. The placeholder carries
    /// the OUTER link; nothing of the syntax leaks into the text.
    func testLinkWrappedImageCarriesTheOuterLink() {
        let attr = renderer.renderInline("[![b](https://x.org/img.svg)](https://x)")
        let text = String(attr.characters)
        XCTAssertTrue(text.contains("Image: b"), text)
        XCTAssertFalse(text.contains("]("), text)
        XCTAssertEqual(Set(attr.runs.compactMap(\.link).map(\.absoluteString)), ["https://x"])
    }

    func testLinkWrappedReferenceImageCarriesTheOuterLink() {
        let attr = refRenderer.renderInline("[![b][ref]](https://x) and [![b][ref]][ref]")
        let text = String(attr.characters)
        XCTAssertEqual(text, "[Image: b] and [Image: b]")
        XCTAssertEqual(attr.runs.compactMap(\.link).map(\.absoluteString),
                       ["https://x", "https://x.org/ref.png"])
    }

    func testLinkWrappedDataImageCarriesTheOuterLinkOnly() {
        let attr = renderer.renderInline("[![b](data:image/png;base64,AAAA)](https://x)")
        XCTAssertEqual(String(attr.characters), "[Image: b]")
        XCTAssertEqual(Set(attr.runs.compactMap(\.link).map(\.absoluteString)), ["https://x"])
    }

    func testAutolink() {
        let attr = renderer.renderInline("see https://example.com/page now")
        XCTAssertEqual(attr.runs.compactMap(\.link).first?.absoluteString, "https://example.com/page")
    }

    // MARK: - Task lists

    func testTaskListCheckboxes() {
        let unchecked = String(renderer.render("- [ ] todo").characters)
        let checked = String(renderer.render("- [x] done").characters)
        XCTAssertTrue(unchecked.contains("☐"))
        XCTAssertTrue(checked.contains("☑"))
    }

    // MARK: - List indentation

    /// Paragraph style of the first list item in `markdown`, as the NSTextView
    /// pipeline sees it (SwiftUI `Text` ignores paragraph styles entirely).
    private func listStyle(_ markdown: String, scale: CGFloat = 1.0) throws -> NSParagraphStyle {
        let r = MarkdownRenderer(theme: MarkdownTheme.cached(for: .light), fontScale: scale)
        let ns = try NSAttributedString(r.render(markdown), including: \.appKit)
        let style = ns.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        return try XCTUnwrap(style, "list item carries no paragraph style")
    }

    /// The bug: with no hanging indent a wrapped item's continuation lines fall
    /// back to the marker's margin, so bullets/numbers and text share one edge.
    func testListItemHangsWrappedLinesPastItsMarker() throws {
        for markdown in ["- alpha", "1. alpha", "- [ ] alpha", "- [x] alpha"] {
            let style = try listStyle(markdown)
            XCTAssertGreaterThan(style.firstLineHeadIndent, 0,
                                 "\(markdown): marker sits flush against the text margin")
            XCTAssertGreaterThan(style.headIndent, style.firstLineHeadIndent,
                                 "\(markdown): wrapped lines are not hung under the item text")
        }
    }

    /// Every paragraph style in `markdown`, in document order.
    private func listStyles(_ markdown: String) throws -> [NSParagraphStyle] {
        let r = MarkdownRenderer(theme: MarkdownTheme.cached(for: .light), fontScale: 1)
        let ns = try NSAttributedString(r.render(markdown), including: \.appKit)
        var out: [NSParagraphStyle] = []
        ns.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: ns.length)) { v, _, _ in
            if let style = v as? NSParagraphStyle { out.append(style) }
        }
        return out
    }

    /// The items of ONE list must share a hanging indent, or their text starts
    /// at a different x. The body font is not monospaced, so "1. " and "10. "
    /// are 18.47 pt and 31.00 pt wide at a 21 pt body — a 12.5 pt step, visible
    /// at a glance on any list that crosses ten items.
    func testOrderedItemsOfOneListShareTheirHangingIndent() throws {
        let markdown = (1...12).map { "\($0). alpha" }.joined(separator: "\n")
        let indents = Set(try listStyles(markdown).map { $0.headIndent })
        XCTAssertEqual(indents.count, 1,
                       "items of one list hang at \(indents.sorted()) instead of sharing one indent")
    }

    /// X where the item TEXT (after "N. ") starts on each line of `markdown`,
    /// laid out by TextKit exactly as the NSTextView pipeline does. This is the
    /// visual truth: a shared `headIndent` alone only aligns wrapped lines,
    /// while the first line starts wherever `firstLineHeadIndent` + the marker
    /// glyphs put it.
    private func textStartXs(_ markdown: String) throws -> [CGFloat] {
        let r = MarkdownRenderer(theme: MarkdownTheme.cached(for: .light), fontScale: 1)
        let ns = try NSAttributedString(r.render(markdown), including: \.appKit)
        let storage = NSTextStorage(attributedString: ns)
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: 2000, height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
        layout.ensureLayout(for: container)

        let text = ns.string as NSString
        var xs: [CGFloat] = []
        for match in try NSRegularExpression(pattern: #"^ *\d+\. "#, options: .anchorsMatchLines)
            .matches(in: ns.string, range: NSRange(location: 0, length: text.length)) {
            let glyph = layout.glyphIndexForCharacter(at: match.range.upperBound)
            let fragment = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            xs.append(fragment.minX + layout.location(forGlyphAt: glyph).x)
        }
        return xs
    }

    private func assertOneTextEdge(_ markdown: String, items: Int,
                                   file: StaticString = #filePath, line: UInt = #line) throws {
        let xs = try textStartXs(markdown)
        XCTAssertEqual(xs.count, items, "items found", file: file, line: line)
        for x in xs.dropFirst() {
            XCTAssertEqual(x, xs[0], accuracy: 0.01,
                           "item text edges \(xs.map { ($0 * 100).rounded() / 100 })", file: file, line: line)
        }
    }

    /// The real requirement behind PR #27: the TEXT of every item of one list
    /// starts at the same x, markers right-aligned under the widest one.
    func testOrderedItemTextOfOneListStartsAtOneX() throws {
        try assertOneTextEdge((1...12).map { "\($0). alpha" }.joined(separator: "\n"), items: 12)
    }

    /// "9. " is wider than "1. " in the body font although both are three
    /// characters — the widest marker is measured, not counted.
    func testWidestMarkerIsMeasuredNotCounted() throws {
        try assertOneTextEdge((1...9).map { "\($0). alpha" }.joined(separator: "\n"), items: 9)
    }

    /// Blank lines (loose lists), nested bullets and continuation text between
    /// the items keep them in one list.
    func testLooseAndNestedContentKeepsOrderedListTogether() throws {
        let markdown = """
        1. alpha

        2. beta
           - nested bullet
             continued
        3. gamma
            1. nested ordered
            2. nested ordered
        10. delta
        """
        let xs = try textStartXs(markdown)
        XCTAssertEqual(xs.count, 6)
        for i in [1, 2, 5] { XCTAssertEqual(xs[i], xs[0], accuracy: 0.01, "outer list at \(xs)") }
        XCTAssertEqual(xs[3], xs[4], accuracy: 0.01, "nested list at \(xs)")
        XCTAssertGreaterThan(xs[3], xs[0], "nested list must sit deeper than its parent")
    }

    /// A paragraph at the list's own margin ends the list: the next ordered
    /// item is a new list and hangs under its own marker only.
    func testParagraphAtListMarginEndsTheList() throws {
        let xs = try textStartXs("1. alpha\n\nplain paragraph\n\n10. beta")
        XCTAssertEqual(xs.count, 2)
        XCTAssertGreaterThan(xs[1], xs[0], "separate lists keep their own marker widths")
    }

    /// The narrowest marker is pushed right, never left of the list gutter, and
    /// the widest one stays at the gutter itself.
    func testWidestMarkerStaysAtTheGutter() throws {
        let styles = try listStyles((1...10).map { "\($0). alpha" }.joined(separator: "\n"))
        let firstLines = styles.map { $0.firstLineHeadIndent }
        XCTAssertEqual(firstLines.min() ?? -1, try listStyle("- alpha").firstLineHeadIndent, accuracy: 0.01)
        XCTAssertEqual(firstLines.last ?? -1, firstLines.min() ?? -1, accuracy: 0.01, "item 10 is the widest")
        XCTAssertGreaterThan(firstLines[0], firstLines[9], "item 1 is pushed right under 10")
    }

    /// A wider marker has to hang further, or "10." would overlap its own text.
    func testWiderOrderedMarkerHangsFurther() throws {
        let single = try listStyle("1. alpha")
        let double = try listStyle("10. alpha")
        XCTAssertGreaterThan(double.headIndent, single.headIndent)
    }

    func testNestedItemsIndentDeeperThanTheirParent() {
        // Two-space and four-space nesting are both common, and neither may
        // collapse a level onto its parent's margin.
        for unit in ["  ", "    "] {
            let levels = (0...3).map { MarkdownRenderer.listLevel(for: Substring(String(repeating: unit, count: $0))) }
            XCTAssertEqual(levels, levels.sorted(), "unit '\(unit)': levels not monotonic")
            XCTAssertEqual(Set(levels).count, levels.count, "unit '\(unit)': two levels share one margin")
            XCTAssertEqual(levels.first, 0, "unit '\(unit)': top level must be 0")
        }
    }

    func testTabIndentIsOneNestingStep() {
        XCTAssertEqual(MarkdownRenderer.listLevel(for: "\t"), 1)
        XCTAssertEqual(MarkdownRenderer.listLevel(for: "\t\t"), 2)
    }

    func testListLevelIsCappedForRunawayIndents() {
        XCTAssertLessThanOrEqual(MarkdownRenderer.listLevel(for: Substring(String(repeating: " ", count: 400))), 8)
    }

    /// Indents are point values, so they have to follow ⌘+ / ⌘- like the fonts.
    func testListIndentScalesWithZoom() throws {
        let normal = try listStyle("- alpha")
        let zoomed = try listStyle("- alpha", scale: 2.0)
        XCTAssertEqual(zoomed.firstLineHeadIndent, normal.firstLineHeadIndent * 2, accuracy: 0.01)
        XCTAssertGreaterThan(zoomed.headIndent, normal.headIndent)
    }

    /// Nesting must stay in the characters too: the print/PDF pipeline renders
    /// through SwiftUI `Text`, which drops paragraph styles.
    func testNestingSurvivesInPlainTextForPrintPipeline() {
        let out = String(renderer.render("- top\n  - nested\n").characters)
        XCTAssertTrue(out.contains("• top"))
        XCTAssertTrue(out.contains("    • nested"))
    }

    // MARK: - Definition lists

    private func definitionList(_ groups: [MarkdownRenderer.DefinitionGroup],
                                scale: CGFloat = 1.0) -> AttributedString {
        MarkdownRenderer(theme: MarkdownTheme.cached(for: .light), fontScale: scale)
            .renderDefinitionList(groups: groups)
    }

    /// The indent has to live in the CHARACTERS as well: print/PDF renders the
    /// block through SwiftUI `Text`, which ignores NSParagraphStyle, so without
    /// the spaces a printed definition would share its term's left edge.
    func testDefinitionListPlainTextCarriesTheIndentForPrint() {
        let attr = definitionList([.init(terms: ["Apple"], definitions: ["A fruit"])])
        XCTAssertEqual(String(attr.characters), "Apple\n    A fruit\n")
    }

    func testDefinitionGroupsAreSeparatedByABlankLine() {
        let attr = definitionList([
            .init(terms: ["Apple"], definitions: ["fruit"]),
            .init(terms: ["Orange"], definitions: ["citrus"])
        ])
        XCTAssertEqual(String(attr.characters), "Apple\n    fruit\n\nOrange\n    citrus\n")
    }

    /// Paragraph style / font of the definition body, as only the NSTextView
    /// pipeline sees them.
    private func definitionBody(_ groups: [MarkdownRenderer.DefinitionGroup],
                                scale: CGFloat = 1.0) throws -> (font: NSFont, style: NSParagraphStyle) {
        let attr = definitionList(groups, scale: scale)
        let ns = try NSAttributedString(attr, including: \.appKit)
        // First character of the definition text, past "term\n" + the indent spaces.
        let plain = String(attr.characters)
        let offset = try XCTUnwrap(plain.range(of: "\n    ")).upperBound
        let index = plain.distance(from: plain.startIndex, to: offset)
        let font = try XCTUnwrap(ns.attribute(.font, at: index, effectiveRange: nil) as? NSFont)
        let style = try XCTUnwrap(ns.attribute(.paragraphStyle, at: index, effectiveRange: nil) as? NSParagraphStyle,
                                  "definition body carries no paragraph style")
        return (font, style)
    }

    func testDefinitionBodyIsIndentedAndHangsItsWrappedLines() throws {
        let groups: [MarkdownRenderer.DefinitionGroup] = [.init(terms: ["Apple"], definitions: ["A fruit"])]
        let body = try definitionBody(groups)
        XCTAssertEqual(body.style.firstLineHeadIndent, 24, accuracy: 0.01)
        XCTAssertGreaterThan(body.style.headIndent, body.style.firstLineHeadIndent,
                             "wrapped lines must hang under the definition text, not under its indent spaces")

        // The term itself sits at the text margin, in semibold.
        let ns = try NSAttributedString(definitionList(groups), including: \.appKit)
        let termStyle = ns.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        XCTAssertEqual(termStyle?.firstLineHeadIndent ?? 0, 0, accuracy: 0.01)
        let termFont = try XCTUnwrap(ns.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        XCTAssertTrue(termFont.fontDescriptor.symbolicTraits.contains(.bold), "term must be semibold")
        XCTAssertFalse(body.font.fontDescriptor.symbolicTraits.contains(.bold), "definition must not be bold")
    }

    /// Indents are point values, so ⌘+ / ⌘- has to move them like the fonts.
    func testDefinitionIndentScalesWithZoom() throws {
        let groups: [MarkdownRenderer.DefinitionGroup] = [.init(terms: ["Apple"], definitions: ["A fruit"])]
        let normal = try definitionBody(groups)
        let zoomed = try definitionBody(groups, scale: 2.0)
        XCTAssertEqual(zoomed.style.firstLineHeadIndent, normal.style.firstLineHeadIndent * 2, accuracy: 0.01)
        XCTAssertGreaterThan(zoomed.style.headIndent, normal.style.headIndent)
    }

    func testDefinitionListRendersInlineFormatting() {
        let attr = definitionList([.init(terms: ["**Apple** pie"],
                                         definitions: ["A [fruit](https://example.com)"])])
        XCTAssertEqual(String(attr.characters), "Apple pie\n    A fruit\n")
        XCTAssertEqual(attr.runs.compactMap(\.link).first?.absoluteString, "https://example.com")
    }

    func testDefinitionBodyJoinsSoftBreaks() {
        let attr = definitionList([.init(terms: ["Term"], definitions: ["first part\nwrapped tail"])])
        XCTAssertEqual(String(attr.characters), "Term\n    first part wrapped tail\n")
    }

    /// A hard break inside a definition keeps two lines — both still indented.
    func testDefinitionBodyKeepsHardBreaks() throws {
        let attr = definitionList([.init(terms: ["Term"], definitions: ["first part  \nsecond line"])])
        XCTAssertEqual(String(attr.characters), "Term\n    first part\n    second line\n")
        let ns = try NSAttributedString(attr, including: \.appKit)
        let secondLine = try XCTUnwrap(String(attr.characters).range(of: "second"))
        let index = String(attr.characters).distance(from: String(attr.characters).startIndex,
                                                    to: secondLine.lowerBound)
        let style = ns.attribute(.paragraphStyle, at: index, effectiveRange: nil) as? NSParagraphStyle
        XCTAssertEqual(style?.firstLineHeadIndent ?? 0, 24, accuracy: 0.01)
    }

    // MARK: - Soft line breaks

    /// CommonMark: a single newline inside a paragraph is a soft break,
    /// rendered as a space — not a visible line break.
    func testSingleNewlineJoinsParagraphLines() {
        let out = String(renderer.render("one\ntwo").characters)
        XCTAssertTrue(out.contains("one two"), "soft break rendered as line break: \(out)")
    }

    func testBlankLineStillSeparatesParagraphs() {
        let out = String(renderer.render("one\n\ntwo").characters)
        XCTAssertFalse(out.contains("one two"))
    }

    func testTrailingDoubleSpaceIsHardBreak() {
        let out = String(renderer.render("one  \ntwo").characters)
        XCTAssertTrue(out.contains("one\ntwo"))
    }

    func testTrailingBackslashIsHardBreak() {
        let out = String(renderer.render("one\\\ntwo").characters)
        XCTAssertTrue(out.contains("one\ntwo"))
        XCTAssertFalse(out.contains("\\"), "hard-break backslash must be consumed")
    }

    func testEscapedTrailingBackslashIsNotHardBreak() {
        // `one\\` is a literal backslash, so the newline stays a soft break.
        let out = String(renderer.render("one\\\\\ntwo").characters)
        XCTAssertTrue(out.contains("one\\ two"))
    }

    func testStructuralLinesAreNotGluedIntoParagraph() {
        XCTAssertFalse(String(renderer.render("para\n# Title").characters).contains("para #"))
        XCTAssertFalse(String(renderer.render("para\n- item").characters).contains("para •"))
        XCTAssertFalse(String(renderer.render("para\n1. item").characters).contains("para 1."))
    }

    func testListItemsKeepTheirOwnLines() {
        let out = String(renderer.render("- one\n- two").characters)
        XCTAssertTrue(out.contains("• one\n"))
        XCTAssertTrue(out.contains("• two"))
    }

    func testContinuationLineLeadingIndentIsDropped() {
        let out = String(renderer.render("one\n   two").characters)
        XCTAssertTrue(out.contains("one two"))
    }

    /// The bug: wrapped item text on its own (indented) source lines fell out
    /// of the item and rendered as a flush-left paragraph. Lazy continuation
    /// pulls it back into the item, where the hanging indent applies.
    func testListItemAbsorbsWrappedContinuationLines() {
        let out = String(renderer.render("- first part,\n  wrapped middle,\n  wrapped tail").characters)
        XCTAssertTrue(out.contains("• first part, wrapped middle, wrapped tail"))
    }

    func testOrderedItemAbsorbsWrappedContinuationLines() {
        let out = String(renderer.render("1. first part\n   wrapped tail").characters)
        XCTAssertTrue(out.contains("1. first part wrapped tail"))
    }

    func testTaskItemAbsorbsWrappedContinuationLines() {
        let out = String(renderer.render("- [ ] first part\n  wrapped tail").characters)
        XCTAssertTrue(out.contains("☐ first part wrapped tail"))
    }

    func testNextListItemIsNotAbsorbedAsContinuation() {
        let out = String(renderer.render("- one\n- two").characters)
        XCTAssertTrue(out.contains("• one\n"))
        XCTAssertTrue(out.contains("• two"))
    }

    func testBlankLineEndsListItemParagraph() {
        let out = String(renderer.render("- item\n\npara").characters)
        XCTAssertFalse(out.contains("item para"))
    }

    // MARK: - Footnote references

    func testFootnoteReferenceRendersSuperscript() {
        let fnRenderer = MarkdownRenderer(theme: MarkdownTheme.cached(for: .light),
                                          footnoteDefinitions: [(id: "note", content: "text")])
        let out = String(fnRenderer.renderInline("word[^note]").characters)
        XCTAssertEqual(out, "word\u{00B9}")
    }

    func testUnknownFootnoteReferenceLeftAsText() {
        let out = rendered("word[^missing]")
        XCTAssertEqual(out, "word[^missing]")
    }

    // MARK: - Dual-scope attributes (NSTextView pipeline)

    func testRenderedTextCarriesAppKitFontAndColor() throws {
        // TextBlockView converts via NSAttributedString(_, including: \.appKit).
        // If the renderer ever stops dual-stamping, the NSTextView pipeline
        // silently loses all fonts/colors — this pins the contract.
        let attr = renderer.renderInline("plain **bold** `code`")
        let ns = try NSAttributedString(attr, including: \.appKit)
        var fontsSeen = 0
        ns.enumerateAttribute(.font, in: NSRange(location: 0, length: ns.length)) { value, _, _ in
            if value is NSFont { fontsSeen += 1 }
        }
        XCTAssertGreaterThan(fontsSeen, 0, "AppKit font attribute missing after conversion")
        var colorsSeen = 0
        ns.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: ns.length)) { value, _, _ in
            if value is NSColor { colorsSeen += 1 }
        }
        XCTAssertGreaterThan(colorsSeen, 0, "AppKit color attribute missing after conversion")
    }

    func testLinkSurvivesAppKitConversion() throws {
        let attr = renderer.renderInline("[text](https://example.com)")
        let ns = try NSAttributedString(attr, including: \.appKit)
        var linkFound: URL?
        ns.enumerateAttribute(.link, in: NSRange(location: 0, length: ns.length)) { value, _, _ in
            if let url = value as? URL { linkFound = url }
        }
        XCTAssertEqual(linkFound?.absoluteString, "https://example.com")
    }

    // MARK: - Inline math segmentation

    func testInlineMathSegmentation() {
        let segments = InlineMathSegmenter.split("before $x^2$ after")
        XCTAssertEqual(segments, [.text("before "), .math("x^2"), .text(" after")])
    }

    func testCurrencyIsNotMath() {
        let segments = InlineMathSegmenter.split("costs $100 and $200 total")
        XCTAssertEqual(segments, [.text("costs $100 and $200 total")])
    }

    func testDoubleDollarSkipped() {
        let segments = InlineMathSegmenter.split("a $$display$$ b")
        XCTAssertEqual(segments, [.text("a $$display$$ b")])
    }

    // MARK: - Headers

    func testRenderHeaderClampsLevel() {
        // Levels outside 1...6 must not crash (sizes array has 6 entries)
        _ = renderer.renderHeader("title", level: 0)
        _ = renderer.renderHeader("title", level: 99)
    }

    // MARK: - Zoom (⌘+ / ⌘-)

    /// Both style scopes must scale, or one of the two pipelines (SwiftUI Text
    /// vs. NSTextView) would keep rendering at the unzoomed size.
    func testFontScaleAppliesToBothScopes() {
        let scaled = MarkdownRenderer(theme: MarkdownTheme.cached(for: .light), fontScale: 2.0)
        let run = scaled.renderHeader("title", level: 1).runs.first!
        XCTAssertEqual(run[AttributeScopes.AppKitAttributes.FontAttribute.self]?.pointSize, 64)  // 32 × 2
        XCTAssertNotNil(run.font)
    }

    /// Body paragraphs travel through the parser, not renderHeader — the path
    /// that was silently dropping the zoom in the first cut.
    func testFontScaleReachesBodyTextBlocks() {
        func bodySizes(_ scale: CGFloat) -> [CGFloat] {
            let parser = MarkdownBlockParser(theme: MarkdownTheme.cached(for: .light), fontScale: scale)
            return parser.parse("# Title\n\nSome **body** text.\n").flatMap { block -> [CGFloat] in
                guard case .text(let attr) = block.content else { return [] }
                return attr.runs.compactMap { $0[AttributeScopes.AppKitAttributes.FontAttribute.self]?.pointSize }
            }
        }
        XCTAssertEqual(bodySizes(1.0), [14, 14, 14])
        XCTAssertEqual(bodySizes(2.0), [28, 28, 28])
    }

    func testZoomStepsClampAtBothEnds() {
        let steps = MarkdownZoom.steps
        XCTAssertEqual(MarkdownZoom.bigger.applied(to: steps.last!, defaultScale: 1.0), steps.last!)
        XCTAssertEqual(MarkdownZoom.smaller.applied(to: steps.first!, defaultScale: 1.0), steps.first!)
        XCTAssertEqual(MarkdownZoom.bigger.applied(to: 1.0, defaultScale: 1.0), 1.1)
        XCTAssertEqual(MarkdownZoom.smaller.applied(to: 1.0, defaultScale: 1.0), 0.9)
        XCTAssertEqual(MarkdownZoom.actualSize.applied(to: 2.5, defaultScale: 1.0), 1.0)
        // An off-ladder value snaps to the nearest rung instead of getting stuck
        XCTAssertEqual(MarkdownZoom.bigger.applied(to: 1.04, defaultScale: 1.0), 1.1)
    }

    // MARK: Default zoom (#48)

    func testDefaultZoomChoicesAreRungsOfTheZoomLadder() {
        for choice in DefaultZoom.choices {
            XCTAssertTrue(MarkdownZoom.steps.contains(choice), "\(choice) is not a zoom step")
        }
    }

    func testDefaultZoomNormalizedKeepsExactChoices() {
        for choice in DefaultZoom.choices {
            XCTAssertEqual(DefaultZoom.normalized(choice), choice)
        }
    }

    func testDefaultZoomNormalizedSnapsToNearestChoice() {
        XCTAssertEqual(DefaultZoom.normalized(1.2), 1.25)
        XCTAssertEqual(DefaultZoom.normalized(1.6), 1.5)
        // Tie rule: exactly between two choices → the smaller one
        XCTAssertEqual(DefaultZoom.normalized(1.05), 1.0)
        XCTAssertEqual(DefaultZoom.normalized(1.875), 1.75)
        // Out of range clamps to the nearest end
        XCTAssertEqual(DefaultZoom.normalized(5.0), 2.0)
        XCTAssertEqual(DefaultZoom.normalized(0.1), 0.9)
    }

    func testDefaultZoomNormalizedRejectsGarbage() {
        XCTAssertEqual(DefaultZoom.normalized(0), 1.0)
        XCTAssertEqual(DefaultZoom.normalized(-1.25), 1.0)
        XCTAssertEqual(DefaultZoom.normalized(.nan), 1.0)
        XCTAssertEqual(DefaultZoom.normalized(.infinity), 1.0)
        XCTAssertEqual(DefaultZoom.normalized(-.infinity), 1.0)
    }

    func testDefaultZoomTitles() {
        XCTAssertEqual(DefaultZoom.title(for: 1.0), "100%")
        XCTAssertEqual(DefaultZoom.title(for: 1.25), "125%")
        XCTAssertEqual(DefaultZoom.title(for: 1.1), "110%")
        XCTAssertEqual(DefaultZoom.title(for: 0.9), "90%")
    }

    func testDefaultZoomStoredReadsItsOwnSuite() throws {
        let suite = try TemporaryDefaults("DefaultZoom")
        defer { suite.remove() }
        let defaults = suite.defaults

        XCTAssertEqual(DefaultZoom.stored(in: defaults), 1.0, "missing key")
        defaults.set(1.25, forKey: DefaultZoom.defaultsKey)
        XCTAssertEqual(DefaultZoom.stored(in: defaults), 1.25)
        defaults.set(1.2, forKey: DefaultZoom.defaultsKey)
        XCTAssertEqual(DefaultZoom.stored(in: defaults), 1.25)
        defaults.set("abc", forKey: DefaultZoom.defaultsKey)
        XCTAssertEqual(DefaultZoom.stored(in: defaults), 1.0, "non-numeric garbage")
    }

    func testActualSizeReturnsToTheDefaultAndStepsMoveFromThere() {
        XCTAssertEqual(MarkdownZoom.actualSize.applied(to: 2.5, defaultScale: 1.25), 1.25)
        XCTAssertEqual(MarkdownZoom.actualSize.applied(to: 1.25, defaultScale: 1.25), 1.25)
        XCTAssertEqual(MarkdownZoom.bigger.applied(to: 1.25, defaultScale: 1.25), 1.5)
        XCTAssertEqual(MarkdownZoom.smaller.applied(to: 1.25, defaultScale: 1.25), 1.1)
    }

    // MARK: - Character references (decoded like GitHub)

    /// Expected strings from `gh api markdown` (2026-11-04): named references
    /// from the full HTML5 table (`&ngE;` is two code points), numeric ones
    /// per CommonMark (0, a surrogate or > U+10FFFF → U+FFFD), a reference
    /// without its `;` or with an unknown name stays as written, and decoding
    /// happens after inline parsing (`&#42;x&#42;` is "*x*", not emphasis).
    func testCharacterReferencesDecodeLikeGitHub() {
        XCTAssertEqual(HTMLEntities.decode("AT&amp;T &copy; a&nbsp;b &rarr; &#35; &#0; &#xD800; &#1234567; &bogus; &amp &ngE; &#X41;"),
                       "AT&T © a\u{00A0}b → # \u{FFFD} \u{FFFD} \u{FFFD} &bogus; &amp \u{2267}\u{0338} A")
        XCTAssertEqual(HTMLEntities.decode("&CounterClockwiseContourIntegral; &#12345678; &#x1234567; &#; &#x; & ;"),
                       "\u{2233} &#12345678; &#x1234567; &#; &#x; & ;", "too many digits, no digits: literal")
        XCTAssertEqual(HTMLEntities.decode("&NewLine;&Tab;"), "\n\t")
        XCTAssertEqual(HTMLEntities.decode("no ampersand"), "no ampersand")

        let line = "AT&amp;T `&amp;` **&lt;b&gt;** ~~&gt;~~ ***&gt;*** [&amp;](http://x) ![a&amp;b](i.png) &#42;x&#42;"
        XCTAssertEqual(rendered(line), "AT&T &amp; <b> > > & [Image: a&b] *x*")
        let attributed = renderer.renderInline("&#42;x&#42;")
        XCTAssertEqual(attributed.runs.count, 1, "a decoded asterisk opens no emphasis")
    }

    /// Every kind that renders inline text decodes — paragraph, list, quote,
    /// alert, table cell, heading, footnote — and never a code block; a
    /// front-matter VALUE keeps its references, as GitHub shows front matter
    /// as plain text.
    func testCharacterReferencesDecodeInEveryTextKindButCodeAndFrontMatter() {
        let theme = MarkdownTheme.cached(for: .light)
        let md = """
        ---
        title: A&amp;B
        ---
        Para &copy; 2026[^n]

        - item &rarr; next

        > quote &amp; more

        > [!NOTE]
        > alert &hellip;

        | h&amp;h |
        |---|
        | cell&nbsp;x |

        ## Q&amp;A

        ```
        code &amp; stays
        ```

        ![a&amp;b](pic.png)

        [^n]: Note &amp; text
        """
        let blocks = MarkdownBlockParser(theme: theme).parse(md)
        let plain = MarkdownRenderer(theme: theme)
        var shown: [String] = []
        for block in blocks {
            switch block.content {
            case .text(let attributed): shown.append(String(attributed.characters))
            case .blockquote(let content, _), .alert(_, let content):
                shown.append(String(plain.renderQuotedBody(content).characters))
            case .table(let headers, let rows, let alignments, let style):
                shown.append(TableTextBuilder.plainString(headers: headers, rows: rows, alignments: alignments,
                                                          style: style, theme: theme, fontScale: 1))
            case .heading(let level, let title, _):
                shown.append(String(plain.renderHeader(title, level: level).characters))
            case .codeBlock(let code, _): shown.append(code)
            case .image(_, let alt, _, _): shown.append("image:" + alt)
            default: break
            }
        }
        let all = shown.joined(separator: "|")
        for expected in ["title\nA&amp;B\n", "Para © 2026", "item → next", "quote & more", "alert …",
                         "h&h\ncell\u{00A0}x\n", "Q&A", "code &amp; stays", "image:a&b", "Note & text"] {
            XCTAssertTrue(all.contains(expected), "\(expected.debugDescription) in \(all.debugDescription)")
        }
    }


    /// Review R5: CommonMark lets a backslash escape ANY ASCII punctuation
    /// (`\&amp;` is the text "&amp;"); expected from `gh api markdown`. `\$`
    /// is the one exception (keeps its backslash: inline math is found in the
    /// rendered text). The Contents sidebar shows exactly the heading's text.
    func testEveryASCIIPunctuationEscapesAndTheToCShowsTheHeadingText() {
        XCTAssertEqual(rendered("a \\&amp; \\< \\~x\\~ \\\" \\@ \\^ \\, b"), "a &amp; < ~x~ \" @ ^ , b")
        XCTAssertEqual(rendered("\\$5"), "$5", "an escaped dollar (R9: tagged, never math)")
        let heading = String(renderer.renderHeader("\\&amp; `&lt;x&gt;`", level: 1).characters)
        XCTAssertEqual(heading, "&amp; &lt;x&gt;")

        let entry = ToCEntry(id: "heading-0", level: 1, title: "\\&amp; `&lt;x&gt;` **Q&amp;A**", sourceLine: 0)
        XCTAssertEqual(entry.shownTitle(renderer: renderer), "&amp; &lt;x&gt; Q&A", "the ToC row = the heading")
        XCTAssertEqual(entry.shownTitle(renderer: renderer),
                       String(renderer.renderHeader(entry.title, level: 1).characters))
    }


    // MARK: - LaTeX escapes inside inline math (review R11)

    /// Inline math is found in the RENDERED text, after every `\<punct>`
    /// escape ran; the formula must still reach the engine with its LaTeX
    /// escapes (`$50\%$` typesets "50%": a bare `%` starts a TeX comment).
    /// Text outside the formula keeps Markdown's escapes. The copy tag carries
    /// the same LaTeX, and print uses the same `pieces(of:)`.
    func testInlineMathKeepsItsLaTeXEscapes() throws {
        for (source, latex) in [("$50\\%$", "50\\%"), ("$a\\,b$", "a\\,b"), ("$\\{x\\}$", "\\{x\\}"),
                                ("$a\\_b$", "a\\_b"), ("$a\\$b$", "a\\$b"), ("$a\\;b\\:c$", "a\\;b\\:c")] {
            XCTAssertEqual(shownParagraph("x " + source + " y").formulas, [latex], source)
        }
        let mixed = shownParagraph("Price \\$5, \\* and $a\\,b + \\{c\\}$ then \\_")
        XCTAssertEqual(mixed.formulas, ["a\\,b + \\{c\\}"])
        XCTAssertEqual(mixed.text, "Price $5, * and \u{FFFC} then _")

        // The copy tag (DocumentCopyBuilder writes `$<tag>$`) is the LaTeX too.
        let theme = MarkdownTheme.cached(for: .light)
        guard case .text(let attributed)? = MarkdownBlockParser(theme: theme).parse("t $50\\%$").first?.content else {
            return XCTFail("paragraph")
        }
        let ns = BlockTextConverter.makeNSAttributedString(
            from: attributed, hasInlineMath: true, theme: theme, fontScale: 1,
            math: MathRendering(inlineImage: { _, _, _ in NSImage(size: NSSize(width: 1, height: 1)) },
                                displayHeight: { _, _, _ in 0 }))
        var tags: [String] = []
        ns.enumerateAttribute(.qmdInlineMathSource, in: NSRange(location: 0, length: ns.length)) { value, _, _ in
            if let value = value as? String { tags.append(value) }
        }
        XCTAssertEqual(tags, ["50\\%"])
        XCTAssertEqual(InlineMathSegmenter.pieces(of: attributed).map(\.length), [2, 5], "spans in the rendered text: $50%$")
    }

    // MARK: - Formatting inside link text (review R13)

    /// A link's text is inline Markdown, as on GitHub (`gh api markdown`):
    /// `<a><strong>Docs</strong></a>`, `<a><em>plain</em></a>`,
    /// `<a><code>npm install</code></a>`, `<a><del>old</del></a>`,
    /// `<a>a <strong>b</strong> c</a>`, `<a href=u>https://x.com</a>`,
    /// `<a>a &amp; b</a>` — and the whole visible text carries the link.
    func testLinkTextIsInlineMarkdown() {
        let line = "[**Docs**](u) [*plain*](v) [`npm install`](u) [~~old~~](u) [a **b** c](u) [https://x.com](u) [a &amp; b](u)"
        let attributed = renderer.renderInline(line)
        XCTAssertEqual(String(attributed.characters), "Docs plain npm install old a b c https://x.com a & b")
        func run(_ text: String) -> AttributedString.Runs.Run? {
            attributed.runs.first { String(attributed[$0.range].characters) == text }
        }
        func font(_ text: String) -> NSFont? { run(text)?[AttributeScopes.AppKitAttributes.FontAttribute.self] }
        XCTAssertTrue(font("Docs")?.fontDescriptor.symbolicTraits.contains(.bold) ?? false)
        XCTAssertTrue(font("plain")?.fontDescriptor.symbolicTraits.contains(.italic) ?? false)
        XCTAssertTrue(font("npm install")?.fontDescriptor.symbolicTraits.contains(.monoSpace) ?? false)
        XCTAssertNotNil(run("old")?[AttributeScopes.AppKitAttributes.StrikethroughStyleAttribute.self])
        XCTAssertTrue(font("b")?.fontDescriptor.symbolicTraits.contains(.bold) ?? false)
        // Every visible character outside the spaces between links is linked;
        // the autolink-looking text links to the OUTER destination.
        for linked in ["Docs", "plain", "npm install", "old", "a ", "b", " c", "a & b"] {
            XCTAssertNotNil(run(linked)?.link, linked)
        }
        XCTAssertEqual(run("https://x.com")?.link?.absoluteString, "u")
    }

    // MARK: - Escapes in link text (review R12)

    /// A link's text with a backslash escape is parsed like the image case:
    /// GitHub shows "cost $5 and $6" (no formula) and "a * b"; a link without
    /// escapes or images keeps its exact plain text.
    func testLinkTextEscapesAreParsed() {
        let cost = shownParagraph("[cost \\$5 and \\$6](https://x.example)")
        XCTAssertEqual(cost.text, "cost $5 and $6")
        XCTAssertEqual(cost.formulas, [])
        let star = renderer.renderInline("[a \\* b](u) and [*plain*](v)")
        XCTAssertEqual(String(star.characters), "a * b and plain", "R13: link text is inline Markdown")
        XCTAssertEqual(Set(star.runs.compactMap { $0.link?.absoluteString }), ["u", "v"])
        XCTAssertTrue(star.runs.filter { String(star[$0.range].characters).contains("*") }.allSatisfy { $0.link != nil },
                      "the whole link text stays linked")
        // The same in a quote, through ReferenceLinks' rewrite.
        let blocks = MarkdownBlockParser(theme: MarkdownTheme.cached(for: .light))
            .parse("> [a \\* b][d] and [c \\$5][d]\n\n[d]: https://d.example")
        guard case .blockquote(let quote, _) = blocks[0].content else { return XCTFail("quote") }
        XCTAssertEqual(String(renderer.renderQuotedBody(quote).characters), "a * b and c $5")
    }

    // MARK: - Plain-text code blocks draw no token colours (1.15)

    /// Numbers, quoted strings, keyword-looking words and comment-looking
    /// lines — everything the generic highlighter colours.
    private static let colourBait = """
        Build finished in 42.5 s with 3 warnings
        Error: "config.yaml" not found, using 'defaults'
        if true then return nil for each Class
        # this looks like a comment
        // so does this one
        """

    /// The foreground colours of `string`, one per run.
    private func foregroundColours(_ string: NSAttributedString) -> Set<NSColor> {
        var colours = Set<NSColor>()
        string.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: string.length)) { value, _, _ in
            if let colour = value as? NSColor { colours.insert(colour) }
        }
        return colours
    }

    /// ```` ```text ```` / ```` ```plaintext ```` (+ Linguist's one-word
    /// aliases of "Text"): GitHub draws them without any token colour —
    /// `gh api markdown -f mode=gfm` gives `<pre lang="text"><code>Build
    /// finished in 42.5 s …</code></pre>`, no `pl-*` span — so the block is
    /// `plainCode` exactly: one colour (the text colour), the same font, the
    /// same characters. Case and words after the language do not matter
    /// (`text title=a` → `<pre lang="text" data-meta="title=a">`).
    func testPlainTextCodeBlocksHaveNoTokenColours() {
        for scheme in [ColorScheme.light, .dark] {
            let theme = MarkdownTheme.cached(for: scheme)
            let plain = BlockTextConverter.plainCode(Self.colourBait, theme: theme, fontScale: 1.25)
            for language in ["text", "plaintext", "Text", "PLAINTEXT", "text title=a", "text\t{.x}",
                             "fundamental", "parindent"] {
                let shown = BlockTextConverter.highlightedCode(Self.colourBait, language: language,
                                                               theme: theme, fontScale: 1.25)
                XCTAssertTrue(shown.isEqual(to: plain), "```\(language) (\(scheme)) is plainCode")
                XCTAssertEqual(foregroundColours(shown), [NSColor(theme.textColor)], "```\(language)")
                XCTAssertFalse(BlockTextConverter.colorsCodeTokens(language: language))
            }
        }
    }

    /// Every other info string keeps the generic colouring, unchanged: real
    /// languages, and also what GitHub leaves uncoloured or colours its own
    /// way — no info string, an unknown word, `txt` (GitHub: Adblock Filter
    /// List), `console` (shell session), `plain`, `textile` (a prefix is not
    /// the word). Only the colours differ from `plainCode`: characters and
    /// fonts are the same, so the measured height and search are unchanged.
    func testOtherCodeBlocksKeepTheirTokenColours() {
        let theme = MarkdownTheme.cached(for: .light)
        let plain = BlockTextConverter.plainCode(Self.colourBait, theme: theme, fontScale: 1)
        for language in ["swift", "", "foobar", "txt", "console", "plain", "textile", "python text"] {
            XCTAssertTrue(BlockTextConverter.colorsCodeTokens(language: language), "```\(language)")
            let shown = BlockTextConverter.highlightedCode(Self.colourBait, language: language,
                                                           theme: theme, fontScale: 1)
            XCTAssertEqual(shown.string, plain.string)
            XCTAssertFalse(shown.isEqual(to: plain), "```\(language) is coloured")
            let colours = foregroundColours(shown)
            for token in [theme.numberColor, theme.stringColor, theme.keywordColor, theme.commentColor] {
                XCTAssertTrue(colours.contains(NSColor(token)), "```\(language)")
            }
            var fontsMatch = true
            shown.enumerateAttribute(.font, in: NSRange(location: 0, length: shown.length)) { value, range, _ in
                if (value as? NSFont) != (plain.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont) {
                    fontsMatch = false
                }
            }
            XCTAssertTrue(fontsMatch, "```\(language): colours only")
        }
    }

    // MARK: - Code spans outrank brackets (review R16)

    /// A `]` or `[` inside a code span pairs with nothing (CommonMark); cases
    /// and expected output from `gh api markdown`.
    func testCodeSpansOutrankBrackets() {
        func check(_ markdown: String, text: String, links: [String], code: [String],
                   file: StaticString = #filePath, line: UInt = #line) {
            let attributed = renderer.renderInline(markdown)
            XCTAssertEqual(String(attributed.characters), text, markdown, file: file, line: line)
            XCTAssertEqual(Set(attributed.runs.compactMap { $0.link?.absoluteString }), Set(links), markdown,
                           file: file, line: line)
            let monospaced = attributed.runs.filter {
                $0[AttributeScopes.AppKitAttributes.FontAttribute.self]?.fontDescriptor.symbolicTraits
                    .contains(.monoSpace) ?? false
            }.map { String(attributed[$0.range].characters) }
            XCTAssertEqual(monospaced, code, markdown, file: file, line: line)
        }
        check("[a `](` b](u)", text: "a ]( b", links: ["u"], code: ["]("])
        check("[x `]` y]", text: "[x ] y]", links: [], code: ["]"])
        check("[a ``]`` b](u)", text: "a ] b", links: ["u"], code: ["]"])
        check("[a ` b](u)", text: "a ` b", links: ["u"], code: [])
        check("[a \\` b](u) c`", text: "a ` b c`", links: ["u"], code: [])
        check("`[a](u)`", text: "[a](u)", links: [], code: ["[a](u)"])

        // A standalone image whose alt holds a code span with `]`.
        let blocks = MarkdownBlockParser(theme: MarkdownTheme.cached(for: .light)).parse("![alt `]` x](i.png)")
        guard case .image(let url, let alt, _, _)? = blocks.first?.content else { return XCTFail("image") }
        XCTAssertEqual(url, "i.png")
        XCTAssertEqual(alt, "alt `]` x")
    }

    /// The renderer's runs as "<link>text" / "`code`" pieces joined by "|".
    private func runs(_ markdown: String) -> String {
        let attributed = renderer.renderInline(markdown)
        return attributed.runs.map { run in
            let text = String(attributed[run.range].characters)
            let mono = run[AttributeScopes.AppKitAttributes.FontAttribute.self]?.fontDescriptor.symbolicTraits
                .contains(.monoSpace) ?? false
            return (run.link.map { "<\($0.absoluteString)>" } ?? "") + (mono ? "`\(text)`" : text)
        }.joined(separator: "|")
    }

    /// The renderer never starts a code span inside a link destination it
    /// consumed, so the bracket scans must not either: a backtick in a URL
    /// must not swallow a later link's `[` (4c0afbf did). The reviewer's
    /// corpus; every case now renders as GitHub does (`gh api markdown`) —
    /// the last three differed until 1.15 (R17: emphasis/strikethrough won
    /// over code, 3+ backtick code spans were literal).
    func testLinkDestinationsHideBackticksFromTheBracketScan() {
        // GitHub: two links "a" and "b `c".
        XCTAssertEqual(runs("[a](u`x) and [b `c](v)"), "<u%60x>a| and |<v>b `c")
        // GitHub: both links, a trailing backtick.
        XCTAssertEqual(runs("[a](<u`>) [b](v) `"), "<u%60>a| |<v>b| `")
        // GitHub-equal.
        XCTAssertEqual(runs("[a `](` b](u)"), "<u>a |<u>`](`|<u> b")
        XCTAssertEqual(runs("![a`b](i.png) [c](u) x`y"), "![a|`b](i.png) [c](u) x`|y")
        XCTAssertEqual(runs("[x](u) `` [y]` `` [z](v)"), "<u>x| |`[y]``| |<v>z")
        XCTAssertEqual(runs("[a ``b]`` c](u)"), "<u>a |<u>`b]`|<u> c")
        XCTAssertEqual(runs("[a \\`b](u) c`"), "<u>a |<u>`|<u>b| c`")
        XCTAssertEqual(runs("[^n`] [d](u) `"), "[^n|`] [d](u) `")
        XCTAssertEqual(runs("`[` [a](u) `]`"), "`[`| |<u>a| |`]`")
        // Code outranks emphasis and strikethrough, and a ``` run is a code
        // span too (1.15; before, emphasis won and ``` stayed literal).
        // GitHub: `***a <code>b*** [c</code> d](u)`,
        // `~~x<code>~~ [y](u) z</code>`, `[a <code>b](u) c</code>`.
        XCTAssertEqual(runs("***a `b*** [c` d](u)"), "***a |`b*** [c`| d](u)")
        XCTAssertEqual(runs("~~x`~~ [y](u) z`"), "~~x|`~~ [y](u) z`")
        XCTAssertEqual(runs("[a ```b](u) c```"), "[a |`b](u) c`")
    }

    // MARK: - Link text = the same inline Markdown, linked (review R15)

    /// A link's text is drawn exactly as the same text outside a link (every
    /// character and attribute), plus the link colour, underline and URL — at
    /// any zoom. (Until 1.15 plain link text took a fast path that skipped
    /// the inline pass and this test pinned the two paths equal; the link
    /// text is now part of the line's one pass, so there is one path.)
    func testLinkTextIsTheSameInlineMarkdownLinked() {
        let texts = ["Install", "Read the guide", "Zażółć gęślą", "a & b", "AT&amp;T &copy;", "50% off $5",
                     "x < y > z", "e-mail: a@b.c", "1. not a list", "# not a heading", "  spaced  ", "emoji 🚀",
                     "a_b", "a \\* b", "`c` d", "~~s~~ t"]
        for scale in [1.0, 1.5] as [CGFloat] {
            let renderer = MarkdownRenderer(theme: MarkdownTheme.cached(for: .dark), fontScale: scale)
            for text in texts {
                var expected = renderer.renderInline(text)
                expected.setDualForeground(renderer.theme.linkColor)
                expected.setDualUnderline()
                expected.link = URL(string: "https://x.example")
                let linked = renderer.renderInline("[\(text)](https://x.example)")
                XCTAssertEqual(linked, expected, "\(text) @\(scale)")
                // Every run is the outer link — no e-mail (mailto:) or bare
                // autolink of its own inside a link's text (review N6).
                XCTAssertEqual(Set(linked.runs.map { $0.link?.absoluteString }), ["https://x.example"], text)
            }
        }
        XCTAssertTrue(renderer.renderInline("e-mail: a@b.c").runs.contains { $0.link?.scheme == "mailto" },
                      "outside a link the address IS linked")
    }

    // MARK: - Formula source in headings (review R14)

    /// Headings show a formula's SOURCE (no inline math there yet), and it
    /// keeps its LaTeX escapes: `# H \% $a\,b$` shows "H % $a\,b$". The
    /// heading view, ids, the Contents sidebar and search all read this text.
    func testHeadingFormulaSourceKeepsItsEscapes() {
        let title = "H \\% $a\\,b$ and $50\\%$"
        let shown = String(renderer.renderHeader(title, level: 1).characters)
        XCTAssertEqual(shown, "H % $a\\,b$ and $50\\%$")
        XCTAssertEqual(String(renderer.renderHeader("Price \\$5 and \\$6", level: 2).characters), "Price $5 and $6",
                       "escaped dollars are no formula")
        let entry = ToCEntry(id: "heading-0", level: 1, title: title, sourceLine: 0)
        XCTAssertEqual(entry.shownTitle(renderer: renderer), shown)
        let theme = MarkdownTheme.cached(for: .light)
        let blocks = MarkdownBlockParser(theme: theme).parse("# " + title)
        XCTAssertEqual(HeadingAnchors.headings(of: blocks, renderer: renderer).map(\.text), [shown])
        XCTAssertEqual(DocumentSearch.computeMatches(in: blocks, term: "a\\,b").matchBlockIds.count, 1,
                       "search finds what the heading shows")
    }

    // MARK: - References in link destinations (review R10)

    /// A destination's character references are decoded (hrefs from
    /// `gh api markdown`: `a?b=1&amp;c=2` → `a?b=1&c=2`, `<a b&copy;>` →
    /// `a%20b%C2%A9`), in inline links, images and reference definitions; a
    /// definition inlined into a quote is decoded exactly once.
    func testLinkDestinationsDecodeCharacterReferences() {
        let theme = MarkdownTheme.cached(for: .light)
        let md = """
        [x](a?b=1&amp;c=2) [z](<a b&copy;>) [r] [twice] `[c](a&amp;b)`

        ![i](p&amp;q.png)

        > quoted [r] and [twice]

        [r]: /u?x=1&amp;y=2
        [twice]: /v?k=&amp;amp;
        """
        let blocks = MarkdownBlockParser(theme: theme).parse(md)
        func links(_ attributed: AttributedString) -> [String] {
            attributed.runs.compactMap { $0.link?.absoluteString }
        }
        guard case .text(let paragraph) = blocks[0].content else { return XCTFail("paragraph") }
        XCTAssertEqual(links(paragraph), ["a?b=1&c=2", "a%20b%C2%A9", "/u?x=1&y=2", "/v?k=&amp;"])
        XCTAssertTrue(String(paragraph.characters).hasSuffix("[c](a&amp;b)"), "code span untouched")
        guard case .image(let url, _, _, _) = blocks[1].content else { return XCTFail("image") }
        XCTAssertEqual(url, "p&q.png")
        guard case .blockquote(let quote, _) = blocks[2].content else { return XCTFail("quote") }
        XCTAssertEqual(links(renderer.renderQuotedBody(quote)), ["/u?x=1&y=2", "/v?k=&amp;"],
                       "inlined definitions are not decoded a second time")
    }

    // MARK: - Escaped dollars (review R9)

    /// The text a paragraph's row shows, with every formula as "⟨latex⟩" (a
    /// stub engine records what it was asked to typeset).
    private func shownParagraph(_ markdown: String) -> (text: String, formulas: [String]) {
        let theme = MarkdownTheme.cached(for: .light)
        var formulas: [String] = []
        let engine = MathRendering(inlineImage: { latex, _, _ in
            formulas.append(latex)
            return NSImage(size: NSSize(width: 1, height: 1))
        }, displayHeight: { _, _, _ in 0 })
        let blocks = MarkdownBlockParser(theme: theme).parse(markdown)
        guard case .text(let attributed)? = blocks.first?.content else { return ("", []) }
        let plain = String(attributed.characters)
        let ns = BlockTextConverter.makeNSAttributedString(
            from: attributed, hasInlineMath: BlockTextConverter.containsInlineMath(plain),
            theme: theme, fontScale: 1, math: engine)
        return (ns.string, formulas)
    }

    /// `\$` is a dollar sign (GitHub: "Price $5 and $10"), never a delimiter;
    /// inside a formula it stays `\$` in the LaTeX; a dollar made by `&#36;`
    /// IS a delimiter (GitHub renders `&#36;x&#36;` as math); a code span keeps
    /// `\$` as written. Print (`PrintableMath.text`) and search use the same
    /// split (`literalDollars`).
    func testEscapedDollarsAreNeverMathDelimiters() {
        let price = shownParagraph("Price \\$5 and \\$10")
        XCTAssertEqual(price.text, "Price $5 and $10")
        XCTAssertEqual(price.formulas, [])

        let inside = shownParagraph("Cost $a\\$b$ here")
        XCTAssertEqual(inside.formulas, ["a\\$b"], "the escaped dollar goes back into the LaTeX")
        XCTAssertEqual(inside.text, "Cost \u{FFFC} here")

        let entity = shownParagraph("Then &#36;x^2&#36; is math")
        XCTAssertEqual(entity.formulas, ["x^2"], "a reference-made dollar is a delimiter")

        let code = shownParagraph("Use `\\$HOME` and \\$PATH")
        XCTAssertEqual(code.text, "Use \\$HOME and $PATH")
        XCTAssertEqual(code.formulas, [])

        // Table cells, quotes and alerts have no inline math: the dollar shows.
        let theme = MarkdownTheme.cached(for: .light)
        let cell = TableTextBuilder.plainString(headers: ["a"], rows: [["\\$5 and \\$10"]], alignments: [.leading],
                                                style: .grid, theme: theme, fontScale: 1)
        XCTAssertTrue(cell.contains("$5 and $10\n"))
        XCTAssertEqual(String(renderer.renderQuotedBody("Pay \\$5").characters), "Pay $5")
        // The segmenter itself: offsets of escaped dollars never delimit.
        XCTAssertEqual(InlineMathSegmenter.split("a $5 and $6", escaped: [2, 9]), [.text("a $5 and $6")])
    }

}

// MARK: - Ordinary Markdown renders exactly as before the 1.15 inline rewrite

extension RendererTests {

    /// A varied, ordinary document — no rare delimiter or link cases — whose
    /// rendered runs must not change when the inline parser does.
    static let ordinaryDocument = """
    # Release notes for **QuickMD** and `quickmd`

    A paragraph with **bold**, *italic*, __bold too__, _italic too_, ***both*** and ~~struck~~ text.
    Inline `code`, ``double `tick` code``, a [link](https://example.com), a [titled link](https://example.com/a "Title")
    and a [reference link][docs] plus [docs] as a shortcut. Snake_case_names and 2*3*4 stay plain.
    Escapes: \\*not italic\\*, \\_not\\_, \\[not a link\\], 50\\% and AT&amp;T &copy; 2026.
    A bare https://example.com/page link, an image ![logo](logo.png) and a footnote[^1].

    ## Lists

    - First item with **bold** and a [link](https://x.example/b)
    - Second item with `code` and *emphasis*
      - Nested item with ~~old~~ text
    1. Ordered **one**
    2. Ordered *two*
    - [ ] Task with `code`
    - [x] Done task with [link](https://x.example/c)

    > A quote with **bold**, *italic*, `code` and a [reference][docs].
    > Second line of the quote.

    > [!NOTE]
    > An alert with **bold** and a [link](https://x.example/d).

    | Column **A** | Column `B` | Link |
    |---|:---:|---:|
    | *one* | `two` | [three](https://x.example/e) |
    | ~~four~~ | five_six | https://x.example/f |

    Term
    : Definition with **bold** and `code`.

    Last paragraph: **bold with spaces inside**, *a phrase in italics*, and `x * y` code.

    [docs]: https://docs.example.com
    [^1]: The footnote with *emphasis*.
    """

    /// The rendered runs of every inline-rendered piece of `markdown`, one
    /// line per run: text, AppKit font, colours, decorations, link, tags,
    /// and whether the SwiftUI scope carries font/colour too.
    static func runDump(_ markdown: String) -> String {
        let theme = MarkdownTheme.cached(for: .light)
        let renderer = MarkdownRenderer(theme: theme)
        func color(_ color: NSColor?) -> String {
            guard let rgb = color?.usingColorSpace(.sRGB) else { return "-" }
            return String(format: "%.3f,%.3f,%.3f,%.3f", rgb.redComponent, rgb.greenComponent,
                          rgb.blueComponent, rgb.alphaComponent)
        }
        func dump(_ label: String, _ attributed: AttributedString) -> [String] {
            [label] + attributed.runs.map { run in
                let font = run[AttributeScopes.AppKitAttributes.FontAttribute.self]
                var line = "  \"\(String(attributed[run.range].characters))\""
                line += " font=\(font.map { "\($0.fontName) \($0.pointSize)" } ?? "-")"
                line += " fg=\(color(run[AttributeScopes.AppKitAttributes.ForegroundColorAttribute.self]))"
                line += " bg=\(color(run[AttributeScopes.AppKitAttributes.BackgroundColorAttribute.self]))"
                if run[AttributeScopes.AppKitAttributes.UnderlineStyleAttribute.self] != nil { line += " u" }
                if run[AttributeScopes.AppKitAttributes.StrikethroughStyleAttribute.self] != nil { line += " s" }
                if let link = run.link { line += " link=\(link.absoluteString)" }
                if run[EscapedCharacterAttribute.self] != nil { line += " esc" }
                if let number = run[FootnoteNumberAttribute.self] { line += " fn=\(number)" }
                line += " ui=\(run.font != nil ? "f" : "-")\(run.foregroundColor != nil ? "c" : "-")"
                    + "\(run.backgroundColor != nil ? "b" : "-")"
                return line
            }
        }
        var lines: [String] = []
        for block in MarkdownBlockParser(theme: theme).parse(markdown) {
            switch block.content {
            case .text(let attributed): lines += dump("text", attributed)
            case .heading(let level, let title, _): lines += dump("h\(level)", renderer.renderHeader(title, level: level))
            case .blockquote(let content, _): lines += dump("quote", renderer.renderQuotedBody(content))
            case .alert(_, let content): lines += dump("alert", renderer.renderQuotedBody(content))
            case .table(let headers, let rows, _, _):
                for cell in headers + rows.flatMap({ $0 }) { lines += dump("cell", renderer.renderInline(cell)) }
            default: lines.append("other")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Dumped from the renderer BEFORE the 1.15 rewrite (main 53ec549):
    /// every run of the ordinary document — characters, fonts, colours,
    /// decorations, links, tags — must stay exactly this. One run changed on
    /// purpose: the heading's code span `quickmd` is bold MONOSPACED at 13/14
    /// of the heading size (policy B, owner's board) — it was the bold body
    /// font at full size.
    static let ordinaryDocumentDump = #"""
    h1
      "Release notes for QuickMD and " font=.AppleSystemUIFontBold 32.0 fg=0.000,0.000,0.000,1.000 bg=- ui=fc-
      "quickmd" font=.AppleSystemUIFontMonospaced-Bold 29.714285714285715 fg=0.000,0.000,0.000,1.000 bg=0.950,0.950,0.950,1.000 ui=fcb
    text
      "A paragraph with " font=.AppleSystemUIFont 14.0 fg=0.000,0.000,0.000,1.000 bg=- ui=fc-
      "bold" font=.AppleSystemUIFontBold 14.0 fg=0.000,0.000,0.000,1.000 bg=- ui=fc-
      ", " font=.AppleSystemUIFont 14.0 fg=0.000,0.000,0.000,1.000 bg=- ui=fc-
      "italic" font=.SFNS-RegularItalic 14.0 fg=0.000,0.000,0.000,1.000 bg=- ui=fc-
      ", " font=.AppleSystemUIFont 14.0 fg=0.000,0.000,0.000,1.000 bg=- ui=fc-
      "bold too" font=.AppleSystemUIFontBold 14.0 fg=0.000,0.000,0.000,1.000 bg=- ui=fc-
      ", " font=.AppleSystemUIFont 14.0 fg=0.000,0.000,0.000,1.000 bg=- ui=fc-
      "italic too" font=.SFNS-RegularItalic 14.0 fg=0.000,0.000,0.000,1.000 bg=- ui=fc-
      ", " font=.AppleSystemUIFont 14.0 fg=0.000,0.000,0.000,1.000 bg=- ui=fc-
      "both" font=.SFNS-BoldItalic 14.0 fg=0.000,0.000,0.000,1.000 bg=- ui=fc-
      " and " font=.AppleSystemUIFont 14.0 fg=0.000,0.000,0.000,1.000 bg=- ui=fc-
      "struck" font=.AppleSystemUIFont 14.0 fg=0.000,0.000,0.000,1.000 bg=- s ui=fc-
      " text. Inline " font=.AppleSystemUIFont 14.0 fg=0.000,0.000,0.000,1.000 bg=- ui=fc-
      "code" font=.AppleSystemUIFontMonospaced-Regular 13.0 fg=0.000,0.000,0.000,1.000 bg=0.950,0.950,0.950,1.000 ui=fcb
      ", " font=.AppleSystemUIFont 14.0 fg=0.000,0.000,0.000,1.000 bg=- ui=fc-
      "double `tick` code" font=.AppleSystemUIFontMonospaced-Regular 13.0 fg=0.000,0.000,0.000,1.000 bg=0.950,0.950,0.950,1.000 ui=fcb
      ", a " font=.AppleSystemUIFont 14.0 fg=0.000,0.000,0.000,1.000 bg=- ui=fc-
      "link" font=.AppleSystemUIFont 14.0 fg=0.000,0.569,1.000,1.000 bg=- u link=https://example.com ui=fc-
      ", a " font=.AppleSystemUIFont 14.0 fg=0.000,0.000,0.000,1.000 bg=- ui=fc-
      "titled link" font=.AppleSystemUIFont 14.0 fg=0.000,0.569,1.000,1.000 bg=- u link=https://example.com/a ui=fc-
      " and a " font=.AppleSystemUIFont 14.0 fg=0.000,0.000,0.000,1.000 bg=- ui=fc-
      "reference link" font=.AppleSystemUIFont 14.0 fg=0.000,0.569,1.000,1.000 bg=- u link=https://docs.example.com ui=fc-
      " plus " font=.AppleSystemUIFont 14.0 fg=0.000,0.000,0.000,1.000 bg=- ui=fc-
      "docs" font=.AppleSystemUIFont 14.0 fg=0.000,0.569,1.000,1.000 bg=- u link=https://docs.example.com ui=fc-
      " as a shortcut. Snake_case_names and 2" font=.AppleSystemUIFont 14.0 fg=0.000,0.000,0.000,1.000 bg=- ui=fc-
      "3" font=.SFNS-RegularItalic 14.0 fg=0.000,0.000,0.000,1.000 bg=- ui=fc-
      "4 stay plain. Escapes: " font=.AppleSystemUIFont 14.0 fg=0.000,0.000,0.000,1.000 bg=- ui=fc-
      "*" font=.AppleSystemUIFont 14.0 fg=0.000,0.000,0.000,1.000 bg=- esc ui=fc-
      "not italic" font=.AppleSystemUIFont 14.0 fg=0.000,0.000,0.000,1.000 bg=- ui=fc-
      "*" font=.AppleSystemUIFont 14.0 fg=0.000,0.000,0.000,1.000 bg=- esc ui=fc-
      ", " font=.AppleSystemUIFont 14.0 fg=0.000,0.000,0.000,1.000 bg=- ui=fc-
      "_" font=.AppleSystemUIFont 14.0 fg=0.000,0.000,0.000,1.000 bg=- esc ui=fc-
      "not" font=.AppleSystemUIFont 14.0 fg=0.000,0.000,0.000,1.000 bg=- ui=fc-
      "_" font=.AppleSystemUIFont 14.0 fg=0.000,0.000,0.000,1.000 bg=- esc ui=fc-
      ", " font=.AppleSystemUIFont 14.0 fg=0.000,0.000,0.000,1.000 bg=- ui=fc-
      "[" font=.AppleSystemUIFont 14.0 fg=0.000,0.000,0.000,1.000 bg=- esc ui=fc-
      "not a link" font=.AppleSystemUIFont 14.0 fg=0.000,0.000,0.000,1.000 bg=- ui=fc-
      "]" font=.AppleSystemUIFont 14.0 fg=0.000,0.000,0.000,1.000 bg=- esc ui=fc-
      ", 50" font=.AppleSystemUIFont 14.0 fg=0.000,0.000,0.000,1.000 bg=- ui=fc-
      "%" font=.AppleSystemUIFont 14.0 fg=0.000,0.000,0.000,1.000 bg=- esc ui=fc-
      " and AT&T © 2026. A bare " font=.AppleSystemUIFont 14.0 fg=0.000,0.000,0.000,1.000 bg=- ui=fc-
      "https://example.com/page" font=.AppleSystemUIFont 14.0 fg=0.000,0.569,1.000,1.000 bg=- u link=https://example.com/page ui=fc-
      " link, an image " font=.AppleSystemUIFont 14.0 fg=0.000,0.000,0.000,1.000 bg=- ui=fc-
      "[Image: logo]" font=.SFNS-RegularItalic 14.0 fg=0.400,0.400,0.400,1.000 bg=- link=logo.png ui=fc-
      " and a footnote" font=.AppleSystemUIFont 14.0 fg=0.000,0.000,0.000,1.000 bg=- ui=fc-
      "¹" font=.AppleSystemUIFontBold 11.0 fg=0.000,0.569,1.000,1.000 bg=- fn=1 ui=fc-
      "." font=.AppleSystemUIFont 14.0 fg=0.000,0.000,0.000,1.000 bg=- ui=fc-
    h2
      "Lists" font=.AppleSystemUIFontBold 26.0 fg=0.000,0.000,0.000,1.000 bg=- ui=fc-
    text
      "• First item with " font=.AppleSystemUIFont 14.0 fg=0.000,0.000,0.000,1.000 bg=- ui=fc-
      "bold" font=.AppleSystemUIFontBold 14.0 fg=0.000,0.000,0.000,1.000 bg=- ui=fc-
      " and a " font=.AppleSystemUIFont 14.0 fg=0.000,0.000,0.000,1.000 bg=- ui=fc-
      "link" font=.AppleSystemUIFont 14.0 fg=0.000,0.569,1.000,1.000 bg=- u link=https://x.example/b ui=fc-
      "
    " font=- fg=- bg=- ui=---
      "• Second item with " font=.AppleSystemUIFont 14.0 fg=0.000,0.000,0.000,1.000 bg=- ui=fc-
      "code" font=.AppleSystemUIFontMonospaced-Regular 13.0 fg=0.000,0.000,0.000,1.000 bg=0.950,0.950,0.950,1.000 ui=fcb
      " and " font=.AppleSystemUIFont 14.0 fg=0.000,0.000,0.000,1.000 bg=- ui=fc-
      "emphasis" font=.SFNS-RegularItalic 14.0 fg=0.000,0.000,0.000,1.000 bg=- ui=fc-
      "
    " font=- fg=- bg=- ui=---
      "    • Nested item with " font=.AppleSystemUIFont 14.0 fg=0.000,0.000,0.000,1.000 bg=- ui=fc-
      "old" font=.AppleSystemUIFont 14.0 fg=0.000,0.000,0.000,1.000 bg=- s ui=fc-
      " text" font=.AppleSystemUIFont 14.0 fg=0.000,0.000,0.000,1.000 bg=- ui=fc-
      "
    " font=- fg=- bg=- ui=---
      "1. Ordered " font=.AppleSystemUIFont 14.0 fg=0.000,0.000,0.000,1.000 bg=- ui=fc-
      "one" font=.AppleSystemUIFontBold 14.0 fg=0.000,0.000,0.000,1.000 bg=- ui=fc-
      "
    " font=- fg=- bg=- ui=---
      "2. Ordered " font=.AppleSystemUIFont 14.0 fg=0.000,0.000,0.000,1.000 bg=- ui=fc-
      "two" font=.SFNS-RegularItalic 14.0 fg=0.000,0.000,0.000,1.000 bg=- ui=fc-
      "
    " font=- fg=- bg=- ui=---
      "☐ Task with " font=.AppleSystemUIFont 14.0 fg=0.000,0.000,0.000,1.000 bg=- ui=fc-
      "code" font=.AppleSystemUIFontMonospaced-Regular 13.0 fg=0.000,0.000,0.000,1.000 bg=0.950,0.950,0.950,1.000 ui=fcb
      "
    " font=- fg=- bg=- ui=---
      "☑ " font=.AppleSystemUIFont 14.0 fg=0.188,0.820,0.345,1.000 bg=- ui=fc-
      "Done task with " font=.AppleSystemUIFont 14.0 fg=0.400,0.400,0.400,1.000 bg=- s ui=fc-
      "link" font=.AppleSystemUIFont 14.0 fg=0.400,0.400,0.400,1.000 bg=- u s link=https://x.example/c ui=fc-
    quote
      "A quote with " font=.AppleSystemUIFont 14.0 fg=0.000,0.000,0.000,1.000 bg=- ui=fc-
      "bold" font=.AppleSystemUIFontBold 14.0 fg=0.000,0.000,0.000,1.000 bg=- ui=fc-
      ", " font=.AppleSystemUIFont 14.0 fg=0.000,0.000,0.000,1.000 bg=- ui=fc-
      "italic" font=.SFNS-RegularItalic 14.0 fg=0.000,0.000,0.000,1.000 bg=- ui=fc-
      ", " font=.AppleSystemUIFont 14.0 fg=0.000,0.000,0.000,1.000 bg=- ui=fc-
      "code" font=.AppleSystemUIFontMonospaced-Regular 13.0 fg=0.000,0.000,0.000,1.000 bg=0.950,0.950,0.950,1.000 ui=fcb
      " and a " font=.AppleSystemUIFont 14.0 fg=0.000,0.000,0.000,1.000 bg=- ui=fc-
      "reference" font=.AppleSystemUIFont 14.0 fg=0.000,0.569,1.000,1.000 bg=- u link=https://docs.example.com ui=fc-
      ". Second line of the quote." font=.AppleSystemUIFont 14.0 fg=0.000,0.000,0.000,1.000 bg=- ui=fc-
    alert
      "An alert with " font=.AppleSystemUIFont 14.0 fg=0.000,0.000,0.000,1.000 bg=- ui=fc-
      "bold" font=.AppleSystemUIFontBold 14.0 fg=0.000,0.000,0.000,1.000 bg=- ui=fc-
      " and a " font=.AppleSystemUIFont 14.0 fg=0.000,0.000,0.000,1.000 bg=- ui=fc-
      "link" font=.AppleSystemUIFont 14.0 fg=0.000,0.569,1.000,1.000 bg=- u link=https://x.example/d ui=fc-
      "." font=.AppleSystemUIFont 14.0 fg=0.000,0.000,0.000,1.000 bg=- ui=fc-
    cell
      "Column " font=.AppleSystemUIFont 14.0 fg=0.000,0.000,0.000,1.000 bg=- ui=fc-
      "A" font=.AppleSystemUIFontBold 14.0 fg=0.000,0.000,0.000,1.000 bg=- ui=fc-
    cell
      "Column " font=.AppleSystemUIFont 14.0 fg=0.000,0.000,0.000,1.000 bg=- ui=fc-
      "B" font=.AppleSystemUIFontMonospaced-Regular 13.0 fg=0.000,0.000,0.000,1.000 bg=0.950,0.950,0.950,1.000 ui=fcb
    cell
      "Link" font=.AppleSystemUIFont 14.0 fg=0.000,0.000,0.000,1.000 bg=- ui=fc-
    cell
      "one" font=.SFNS-RegularItalic 14.0 fg=0.000,0.000,0.000,1.000 bg=- ui=fc-
    cell
      "two" font=.AppleSystemUIFontMonospaced-Regular 13.0 fg=0.000,0.000,0.000,1.000 bg=0.950,0.950,0.950,1.000 ui=fcb
    cell
      "three" font=.AppleSystemUIFont 14.0 fg=0.000,0.569,1.000,1.000 bg=- u link=https://x.example/e ui=fc-
    cell
      "four" font=.AppleSystemUIFont 14.0 fg=0.000,0.000,0.000,1.000 bg=- s ui=fc-
    cell
      "five_six" font=.AppleSystemUIFont 14.0 fg=0.000,0.000,0.000,1.000 bg=- ui=fc-
    cell
      "https://x.example/f" font=.AppleSystemUIFont 14.0 fg=0.000,0.569,1.000,1.000 bg=- u link=https://x.example/f ui=fc-
    text
      "Term" font=.AppleSystemUIFontBold 14.0 fg=0.000,0.000,0.000,1.000 bg=- ui=fc-
      "
    " font=- fg=- bg=- ui=---
      "    Definition with " font=.AppleSystemUIFont 14.0 fg=0.000,0.000,0.000,1.000 bg=- ui=fc-
      "bold" font=.AppleSystemUIFontBold 14.0 fg=0.000,0.000,0.000,1.000 bg=- ui=fc-
      " and " font=.AppleSystemUIFont 14.0 fg=0.000,0.000,0.000,1.000 bg=- ui=fc-
      "code" font=.AppleSystemUIFontMonospaced-Regular 13.0 fg=0.000,0.000,0.000,1.000 bg=0.950,0.950,0.950,1.000 ui=fcb
      "." font=.AppleSystemUIFont 14.0 fg=0.000,0.000,0.000,1.000 bg=- ui=fc-
    text
      "Last paragraph: " font=.AppleSystemUIFont 14.0 fg=0.000,0.000,0.000,1.000 bg=- ui=fc-
      "bold with spaces inside" font=.AppleSystemUIFontBold 14.0 fg=0.000,0.000,0.000,1.000 bg=- ui=fc-
      ", " font=.AppleSystemUIFont 14.0 fg=0.000,0.000,0.000,1.000 bg=- ui=fc-
      "a phrase in italics" font=.SFNS-RegularItalic 14.0 fg=0.000,0.000,0.000,1.000 bg=- ui=fc-
      ", and " font=.AppleSystemUIFont 14.0 fg=0.000,0.000,0.000,1.000 bg=- ui=fc-
      "x * y" font=.AppleSystemUIFontMonospaced-Regular 13.0 fg=0.000,0.000,0.000,1.000 bg=0.950,0.950,0.950,1.000 ui=fcb
      " code." font=.AppleSystemUIFont 14.0 fg=0.000,0.000,0.000,1.000 bg=- ui=fc-
    text
      "────────────────────────────────
    " font=.AppleSystemUIFont 12.0 fg=0.400,0.400,0.400,1.000 bg=- ui=fc-
      "1. " font=.AppleSystemUIFontBold 12.0 fg=0.400,0.400,0.400,1.000 bg=- ui=fc-
      "The footnote with emphasis." font=.AppleSystemUIFont 12.0 fg=0.400,0.400,0.400,1.000 bg=- ui=fc-
    """#

    func testOrdinaryDocumentRendersExactlyAsBefore() {
        XCTAssertEqual(Self.runDump(Self.ordinaryDocument), Self.ordinaryDocumentDump)
    }
}

// MARK: - The 1.15 inline rules, pinned as decided

extension RendererTests {

    /// What 1.15 changed on purpose (review S1; owner's board): nested
    /// emphasis combines, `~` strikethrough, emphasis keeps code / links /
    /// footnotes (policy B, headings too), CJK-friendly flanking, `www.`,
    /// e-mail and `<…>` autolinks, escaped pipes in cells. Dumped from the
    /// branch once the board was accepted; a later change to any of these
    /// shows up here.
    static let decidedDocument = #"""
    Nested: **a *b* c**, ***x***, *a **b** c*, ~~**s**~~ and ~one~ and ~~two~~.
    CJK: **「テスト」**と、**テスト。**次、これは**強調**です、**加粗（括号）**文字、**굵게**는.
    Links: see www.example.org, mail a.b@c.example, <https://x.example/?a=1&amp;b=2>, https://x.example/p_(q).
    Code: **run `make`**, *run `make`*, a footnote **a[^1]**, **see [docs](https://x.example)**.

    ## Heading with **`code`**, *it* and [link](https://x.example)

    | A \| B | `c \| d` | **[l](https://x.example)** |
    |---|---|---|
    | x \| y | *i* `c` | ~~s~~ www.x.example |

    > Quote with **`code`**, a@b.example and [ref][docs].

    [docs]: https://docs.example.com
    [^1]: Note.
    """#
}

extension RendererTests {
    /// `decidedDocument` as the branch renders it after the owner accepted
    /// the board (policy B, CJK-friendly flanking, 2026-11-11).
    static let decidedDocumentDump = #"""
    text
      "Nested: " font=.AppleSystemUIFont 14.0 fg=0.000,0.000,0.000,1.000 bg=- ui=fc-
      "a " font=.AppleSystemUIFontBold 14.0 fg=0.000,0.000,0.000,1.000 bg=- ui=fc-
      "b" font=.SFNS-BoldItalic 14.0 fg=0.000,0.000,0.000,1.000 bg=- ui=fc-
      " c" font=.AppleSystemUIFontBold 14.0 fg=0.000,0.000,0.000,1.000 bg=- ui=fc-
      ", " font=.AppleSystemUIFont 14.0 fg=0.000,0.000,0.000,1.000 bg=- ui=fc-
      "x" font=.SFNS-BoldItalic 14.0 fg=0.000,0.000,0.000,1.000 bg=- ui=fc-
      ", " font=.AppleSystemUIFont 14.0 fg=0.000,0.000,0.000,1.000 bg=- ui=fc-
      "a " font=.SFNS-RegularItalic 14.0 fg=0.000,0.000,0.000,1.000 bg=- ui=fc-
      "b" font=.SFNS-BoldItalic 14.0 fg=0.000,0.000,0.000,1.000 bg=- ui=fc-
      " c" font=.SFNS-RegularItalic 14.0 fg=0.000,0.000,0.000,1.000 bg=- ui=fc-
      ", " font=.AppleSystemUIFont 14.0 fg=0.000,0.000,0.000,1.000 bg=- ui=fc-
      "s" font=.AppleSystemUIFontBold 14.0 fg=0.000,0.000,0.000,1.000 bg=- s ui=fc-
      " and " font=.AppleSystemUIFont 14.0 fg=0.000,0.000,0.000,1.000 bg=- ui=fc-
      "one" font=.AppleSystemUIFont 14.0 fg=0.000,0.000,0.000,1.000 bg=- s ui=fc-
      " and " font=.AppleSystemUIFont 14.0 fg=0.000,0.000,0.000,1.000 bg=- ui=fc-
      "two" font=.AppleSystemUIFont 14.0 fg=0.000,0.000,0.000,1.000 bg=- s ui=fc-
      ". CJK: " font=.AppleSystemUIFont 14.0 fg=0.000,0.000,0.000,1.000 bg=- ui=fc-
      "「テスト」" font=.AppleSystemUIFontBold 14.0 fg=0.000,0.000,0.000,1.000 bg=- ui=fc-
      "と、" font=.AppleSystemUIFont 14.0 fg=0.000,0.000,0.000,1.000 bg=- ui=fc-
      "テスト。" font=.AppleSystemUIFontBold 14.0 fg=0.000,0.000,0.000,1.000 bg=- ui=fc-
      "次、これは" font=.AppleSystemUIFont 14.0 fg=0.000,0.000,0.000,1.000 bg=- ui=fc-
      "強調" font=.AppleSystemUIFontBold 14.0 fg=0.000,0.000,0.000,1.000 bg=- ui=fc-
      "です、" font=.AppleSystemUIFont 14.0 fg=0.000,0.000,0.000,1.000 bg=- ui=fc-
      "加粗（括号）" font=.AppleSystemUIFontBold 14.0 fg=0.000,0.000,0.000,1.000 bg=- ui=fc-
      "文字、" font=.AppleSystemUIFont 14.0 fg=0.000,0.000,0.000,1.000 bg=- ui=fc-
      "굵게" font=.AppleSystemUIFontBold 14.0 fg=0.000,0.000,0.000,1.000 bg=- ui=fc-
      "는. Links: see " font=.AppleSystemUIFont 14.0 fg=0.000,0.000,0.000,1.000 bg=- ui=fc-
      "www.example.org" font=.AppleSystemUIFont 14.0 fg=0.000,0.569,1.000,1.000 bg=- u link=http://www.example.org ui=fc-
      ", mail " font=.AppleSystemUIFont 14.0 fg=0.000,0.000,0.000,1.000 bg=- ui=fc-
      "a.b@c.example" font=.AppleSystemUIFont 14.0 fg=0.000,0.569,1.000,1.000 bg=- u link=mailto:a.b@c.example ui=fc-
      ", " font=.AppleSystemUIFont 14.0 fg=0.000,0.000,0.000,1.000 bg=- ui=fc-
      "https://x.example/?a=1&b=2" font=.AppleSystemUIFont 14.0 fg=0.000,0.569,1.000,1.000 bg=- u link=https://x.example/?a=1&b=2 ui=fc-
      ", " font=.AppleSystemUIFont 14.0 fg=0.000,0.000,0.000,1.000 bg=- ui=fc-
      "https://x.example/p_(q)" font=.AppleSystemUIFont 14.0 fg=0.000,0.569,1.000,1.000 bg=- u link=https://x.example/p_(q) ui=fc-
      ". Code: " font=.AppleSystemUIFont 14.0 fg=0.000,0.000,0.000,1.000 bg=- ui=fc-
      "run " font=.AppleSystemUIFontBold 14.0 fg=0.000,0.000,0.000,1.000 bg=- ui=fc-
      "make" font=.AppleSystemUIFontMonospaced-Bold 13.0 fg=0.000,0.000,0.000,1.000 bg=0.950,0.950,0.950,1.000 ui=fcb
      ", " font=.AppleSystemUIFont 14.0 fg=0.000,0.000,0.000,1.000 bg=- ui=fc-
      "run " font=.SFNS-RegularItalic 14.0 fg=0.000,0.000,0.000,1.000 bg=- ui=fc-
      "make" font=.AppleSystemUIFontMonospaced-RegularItalic 13.0 fg=0.000,0.000,0.000,1.000 bg=0.950,0.950,0.950,1.000 ui=fcb
      ", a footnote " font=.AppleSystemUIFont 14.0 fg=0.000,0.000,0.000,1.000 bg=- ui=fc-
      "a" font=.AppleSystemUIFontBold 14.0 fg=0.000,0.000,0.000,1.000 bg=- ui=fc-
      "¹" font=.AppleSystemUIFontBold 11.0 fg=0.000,0.569,1.000,1.000 bg=- fn=1 ui=fc-
      ", " font=.AppleSystemUIFont 14.0 fg=0.000,0.000,0.000,1.000 bg=- ui=fc-
      "see " font=.AppleSystemUIFontBold 14.0 fg=0.000,0.000,0.000,1.000 bg=- ui=fc-
      "docs" font=.AppleSystemUIFontBold 14.0 fg=0.000,0.569,1.000,1.000 bg=- u link=https://x.example ui=fc-
      "." font=.AppleSystemUIFont 14.0 fg=0.000,0.000,0.000,1.000 bg=- ui=fc-
    h2
      "Heading with " font=.AppleSystemUIFontBold 26.0 fg=0.000,0.000,0.000,1.000 bg=- ui=fc-
      "code" font=.AppleSystemUIFontMonospaced-Bold 24.142857142857142 fg=0.000,0.000,0.000,1.000 bg=0.950,0.950,0.950,1.000 ui=fcb
      ", " font=.AppleSystemUIFontBold 26.0 fg=0.000,0.000,0.000,1.000 bg=- ui=fc-
      "it" font=.SFNS-BoldItalic 26.0 fg=0.000,0.000,0.000,1.000 bg=- ui=fc-
      " and " font=.AppleSystemUIFontBold 26.0 fg=0.000,0.000,0.000,1.000 bg=- ui=fc-
      "link" font=.AppleSystemUIFontBold 26.0 fg=0.000,0.569,1.000,1.000 bg=- u link=https://x.example ui=fc-
    cell
      "A | B" font=.AppleSystemUIFont 14.0 fg=0.000,0.000,0.000,1.000 bg=- ui=fc-
    cell
      "c | d" font=.AppleSystemUIFontMonospaced-Regular 13.0 fg=0.000,0.000,0.000,1.000 bg=0.950,0.950,0.950,1.000 ui=fcb
    cell
      "l" font=.AppleSystemUIFontBold 14.0 fg=0.000,0.569,1.000,1.000 bg=- u link=https://x.example ui=fc-
    cell
      "x | y" font=.AppleSystemUIFont 14.0 fg=0.000,0.000,0.000,1.000 bg=- ui=fc-
    cell
      "i" font=.SFNS-RegularItalic 14.0 fg=0.000,0.000,0.000,1.000 bg=- ui=fc-
      " " font=.AppleSystemUIFont 14.0 fg=0.000,0.000,0.000,1.000 bg=- ui=fc-
      "c" font=.AppleSystemUIFontMonospaced-Regular 13.0 fg=0.000,0.000,0.000,1.000 bg=0.950,0.950,0.950,1.000 ui=fcb
    cell
      "s" font=.AppleSystemUIFont 14.0 fg=0.000,0.000,0.000,1.000 bg=- s ui=fc-
      " " font=.AppleSystemUIFont 14.0 fg=0.000,0.000,0.000,1.000 bg=- ui=fc-
      "www.x.example" font=.AppleSystemUIFont 14.0 fg=0.000,0.569,1.000,1.000 bg=- u link=http://www.x.example ui=fc-
    quote
      "Quote with " font=.AppleSystemUIFont 14.0 fg=0.000,0.000,0.000,1.000 bg=- ui=fc-
      "code" font=.AppleSystemUIFontMonospaced-Bold 13.0 fg=0.000,0.000,0.000,1.000 bg=0.950,0.950,0.950,1.000 ui=fcb
      ", " font=.AppleSystemUIFont 14.0 fg=0.000,0.000,0.000,1.000 bg=- ui=fc-
      "a@b.example" font=.AppleSystemUIFont 14.0 fg=0.000,0.569,1.000,1.000 bg=- u link=mailto:a@b.example ui=fc-
      " and " font=.AppleSystemUIFont 14.0 fg=0.000,0.000,0.000,1.000 bg=- ui=fc-
      "ref" font=.AppleSystemUIFont 14.0 fg=0.000,0.569,1.000,1.000 bg=- u link=https://docs.example.com ui=fc-
      "." font=.AppleSystemUIFont 14.0 fg=0.000,0.000,0.000,1.000 bg=- ui=fc-
    text
      "────────────────────────────────
    " font=.AppleSystemUIFont 12.0 fg=0.400,0.400,0.400,1.000 bg=- ui=fc-
      "1. " font=.AppleSystemUIFontBold 12.0 fg=0.400,0.400,0.400,1.000 bg=- ui=fc-
      "Note." font=.AppleSystemUIFont 12.0 fg=0.400,0.400,0.400,1.000 bg=- ui=fc-
    """#

    func testDecidedInlineRulesRenderAsPinned() {
        XCTAssertEqual(Self.runDump(Self.decidedDocument), Self.decidedDocumentDump)
    }
}
