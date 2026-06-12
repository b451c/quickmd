import XCTest
import SwiftUI

/// DocumentSearch (find-in-document) behavior tests: one match entry per
/// occurrence, all block types searched, base highlights only for text blocks.
final class SearchTests: XCTestCase {

    private func parse(_ markdown: String) -> [MarkdownBlock] {
        MarkdownBlockParser(theme: MarkdownTheme.cached(for: .light)).parse(markdown)
    }

    func testEmptyTermYieldsNoResults() {
        let results = DocumentSearch.computeMatches(in: parse("# Hello"), term: "")
        XCTAssertTrue(results.matchBlockIds.isEmpty)
        XCTAssertTrue(results.baseHighlights.isEmpty)
    }

    func testOneEntryPerOccurrence() {
        let blocks = parse("apple apple apple")
        let results = DocumentSearch.computeMatches(in: blocks, term: "apple")
        XCTAssertEqual(results.matchBlockIds.count, 3)
        XCTAssertEqual(Set(results.matchBlockIds).count, 1, "all in the same block")
    }

    func testCaseInsensitiveMatching() {
        let blocks = parse("Apple aPPle APPLE")
        let results = DocumentSearch.computeMatches(in: blocks, term: "apple")
        XCTAssertEqual(results.matchBlockIds.count, 3)
    }

    func testSearchCoversAllBlockTypes() {
        let md = """
        # needle in heading
        needle in text

        ```
        needle in code
        ```
        > needle in quote

        | needle |
        |--------|
        | needle |
        """
        let results = DocumentSearch.computeMatches(in: parse(md), term: "needle")
        XCTAssertEqual(results.matchBlockIds.count, 6,
            "heading + text + code + blockquote + table header + table cell")
    }

    func testBaseHighlightsOnlyForTextBlocks() {
        let md = """
        # needle
        needle text
        """
        let blocks = parse(md)
        let results = DocumentSearch.computeMatches(in: blocks, term: "needle")
        XCTAssertEqual(results.baseHighlights.count, 1)
        let textBlockIds = blocks.compactMap { block -> String? in
            if case .text = block.content { return block.id }
            return nil
        }
        XCTAssertEqual(Set(results.baseHighlights.keys), Set(textBlockIds))
    }

    func testSearchHighlightSetsBackgroundOnMatches() {
        var attr = AttributedString("find the word here")
        attr.font = .system(size: 14)
        let highlighted = searchHighlight(attr, term: "word")
        let highlightedRuns = highlighted.runs.filter { $0.backgroundColor != nil }
        XCTAssertEqual(highlightedRuns.count, 1)
        // The highlighted run must cover exactly the matched substring
        let run = highlightedRuns[0]
        XCTAssertEqual(String(highlighted[run.range].characters), "word")
    }

    func testCountOccurrences() {
        XCTAssertEqual(countOccurrences(in: "aaa", of: "a"), 3)
        XCTAssertEqual(countOccurrences(in: "AaA", of: "a"), 3)
        XCTAssertEqual(countOccurrences(in: "abc", of: ""), 0)
        XCTAssertEqual(countOccurrences(in: "", of: "x"), 0)
    }
}
