import XCTest
import SwiftUI

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

    // MARK: - Headers

    func testRenderHeaderClampsLevel() {
        // Levels outside 1...6 must not crash (sizes array has 6 entries)
        _ = renderer.renderHeader("title", level: 0)
        _ = renderer.renderHeader("title", level: 99)
    }
}
