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
        XCTAssertEqual(MarkdownZoom.bigger.applied(to: steps.last!), steps.last!)
        XCTAssertEqual(MarkdownZoom.smaller.applied(to: steps.first!), steps.first!)
        XCTAssertEqual(MarkdownZoom.bigger.applied(to: 1.0), 1.1)
        XCTAssertEqual(MarkdownZoom.smaller.applied(to: 1.0), 0.9)
        XCTAssertEqual(MarkdownZoom.actualSize.applied(to: 2.5), 1.0)
        // An off-ladder value snaps to the nearest rung instead of getting stuck
        XCTAssertEqual(MarkdownZoom.bigger.applied(to: 1.04), 1.1)
    }
}
