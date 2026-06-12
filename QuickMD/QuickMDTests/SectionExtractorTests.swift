import XCTest

/// Section copy ("Copy section" on headings / ToC) regression tests.
/// The extractor takes its boundaries from parser-assigned source lines, so
/// these tests parse real markdown and derive headings exactly like
/// MarkdownView does.
final class SectionExtractorTests: XCTestCase {

    private func headings(of markdown: String) -> [ToCEntry] {
        let blocks = MarkdownBlockParser(theme: MarkdownTheme.cached(for: .light)).parse(markdown)
        return blocks.compactMap { block in
            if case .heading(let level, let title, let sourceLine) = block.content {
                return ToCEntry(id: block.id, level: level, title: title, sourceLine: sourceLine)
            }
            return nil
        }
    }

    func testSectionEndsAtNextSameLevelHeading() {
        let md = """
        ## First
        content one

        ## Second
        content two
        """
        let toc = headings(of: md)
        let section = SectionExtractor.extractSection(from: md, entry: toc[0], headings: toc)
        XCTAssertEqual(section, "## First\ncontent one")
    }

    func testSectionIncludesLowerLevelSubsections() {
        let md = """
        # Top
        intro
        ## Sub
        sub content
        # Next
        """
        let toc = headings(of: md)
        let section = SectionExtractor.extractSection(from: md, entry: toc[0], headings: toc)
        XCTAssertEqual(section, "# Top\nintro\n## Sub\nsub content")
    }

    func testLastSectionRunsToEndOfFile() {
        let md = """
        ## Only
        line one
        line two
        """
        let toc = headings(of: md)
        let section = SectionExtractor.extractSection(from: md, entry: toc[0], headings: toc)
        XCTAssertEqual(section, "## Only\nline one\nline two")
    }

    func testHeadingInsideCodeFenceDoesNotBreakSectionCopy() {
        // Regression: an earlier implementation re-scanned the raw text with its
        // own heading regex and counted "#" comment lines inside code fences,
        // desynchronizing occurrence indices and copying the wrong section
        // (or nothing).
        let md = """
        # A
        ```bash
        # just a comment
        # another comment
        ```
        ## B
        content B
        ## C
        content C
        """
        let toc = headings(of: md)
        XCTAssertEqual(toc.map(\.title), ["A", "B", "C"])
        let section = SectionExtractor.extractSection(from: md, entry: toc[1], headings: toc)
        XCTAssertEqual(section, "## B\ncontent B")
    }

    func testSetextSectionBoundaries() {
        let md = """
        Title
        =====
        intro

        Second
        ======
        more
        """
        let toc = headings(of: md)
        XCTAssertEqual(toc.count, 2)
        let section = SectionExtractor.extractSection(from: md, entry: toc[0], headings: toc)
        XCTAssertEqual(section, "Title\n=====\nintro")
    }

    func testTrailingBlankLinesAreTrimmed() {
        let md = "## H\ncontent\n\n\n\n## Next"
        let toc = headings(of: md)
        let section = SectionExtractor.extractSection(from: md, entry: toc[0], headings: toc)
        XCTAssertEqual(section, "## H\ncontent")
    }

    func testUnknownEntryReturnsNil() {
        let md = "## H\ncontent"
        let toc = headings(of: md)
        let stranger = ToCEntry(id: "heading-999", level: 2, title: "X", sourceLine: 0)
        XCTAssertNil(SectionExtractor.extractSection(from: md, entry: stranger, headings: toc))
    }
}
