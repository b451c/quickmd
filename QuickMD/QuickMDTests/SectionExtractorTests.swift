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

    // MARK: - Contents depth (#42)

    func testContentsDepthFiltersByLevel() {
        let toc = headings(of: "# A\n## B\n### C\n#### D\n##### E\n###### F")
        XCTAssertEqual(ToCDepth.visible(toc, maxLevel: ToCDepth.all).map(\.title), ["A", "B", "C", "D", "E", "F"])
        XCTAssertEqual(ToCDepth.visible(toc, maxLevel: 2).map(\.title), ["A", "B"])
        XCTAssertEqual(ToCDepth.visible(toc, maxLevel: 4).map(\.title), ["A", "B", "C", "D"])
        XCTAssertEqual(ToCDepth.choices.first?.maxLevel, ToCDepth.all, "All Headings is the default and first")
    }

    // MARK: - Heading anchors (#43)

    private func anchorHeadings(of markdown: String) -> [(id: String, text: String)] {
        let theme = MarkdownTheme.cached(for: .light)
        return HeadingAnchors.headings(of: MarkdownBlockParser(theme: theme).parse(markdown),
                                       renderer: MarkdownRenderer(theme: theme))
    }

    /// The ids GitHub's renderer gave the same headings (2026-10-29): markup
    /// is gone before the slug, repeats count like github-slugger.
    func testHeadingIdsMatchGitHub() {
        let md = """
        ## Some Header
        ## What's new in 1.2?
        ## C++ & C# notes
        ## API: `fetch()` returns **data**
        ## See [the docs](https://example.com) here
        ## Zażółć gęślą jaźń
        ## Hello  World
        ## foo_bar-baz
        ## Émoji 🎉 party
        ## Intro
        ## Intro
        ## Intro-1
        ## Intro
        ## 1. Getting Started
        ## A — B – C
        ## Ünïcödé Straße
        ## Trailing spaces ##
        ## Path/to\\file.md
        ## “Quoted” ‘text’
        ## 100% done (really!)
        ## x² Ⅳ ½ 3
        ## Love ❤️ it
        ## Family 👨‍👩‍👧 here
        ## foo \\###
        ## Ω Σ Δ
        ## 中文 标题
        ## İstanbul
        """
        let ids = HeadingAnchors.ids(for: anchorHeadings(of: md).map(\.text))
        XCTAssertEqual(ids, [
            "some-header", "whats-new-in-12", "c--c-notes", "api-fetch-returns-data",
            "see-the-docs-here", "zażółć-gęślą-jaźń", "hello--world", "foo_bar-baz",
            "émoji--party", "intro", "intro-1", "intro-1-1", "intro-2", "1-getting-started",
            "a--b--c", "ünïcödé-straße", "trailing-spaces", "pathtofilemd", "quoted-text",
            "100-done-really", "x-\u{2173}--3", "love-\u{FE0F}-it", "family-\u{200D}\u{200D}-here",
            "foo-", "ω-σ-δ", "中文-标题", "i\u{307}stanbul",
        ])
    }

    func testFragmentFindsItsHeading() {
        let headings = anchorHeadings(of: """
        # Guide
        ## Install Guide
        ## Intro
        ## Intro
        """)
        let id = { HeadingAnchors.headingId(forFragment: $0, in: headings) }
        XCTAssertEqual(id("install-guide"), headings[1].id)
        // Hand-written: the fragment's own slug
        XCTAssertEqual(id("Install Guide"), headings[1].id)
        XCTAssertEqual(id("Install-Guide"), headings[1].id)
        // The second "Intro" is `intro-1`
        XCTAssertEqual(id("intro"), headings[2].id)
        XCTAssertEqual(id("intro-1"), headings[3].id)
        XCTAssertNil(id("missing"))
        XCTAssertNil(id(""))
    }

    func testEmptyFragmentAndTopAreTheTopOfTheDocument() {
        // `## 🚀` slugs to "", the id `#` would otherwise match (review 2026-10-29)
        let emoji = anchorHeadings(of: "# Guide\n## 🚀\n## Usage")
        XCTAssertEqual(HeadingAnchors.target(forFragment: "", in: emoji), .top)
        XCTAssertEqual(HeadingAnchors.target(forFragment: "top", in: emoji), .top)
        XCTAssertEqual(HeadingAnchors.target(forFragment: "usage", in: emoji), .heading(emoji[2].id))
        XCTAssertEqual(HeadingAnchors.target(forFragment: "nope", in: emoji), .none)
        // A heading that claims `top` wins, as an element with that id does in a browser
        let claimed = anchorHeadings(of: "# Intro\n## Top")
        XCTAssertEqual(HeadingAnchors.target(forFragment: "top", in: claimed), .heading(claimed[1].id))
    }

    func testInDocumentFragmentOfALink() {
        let fragment = { HeadingAnchors.inDocumentFragment(of: URL(string: $0)!) }
        XCTAssertEqual(fragment("#install"), "install")
        XCTAssertEqual(fragment("#"), "")
        XCTAssertEqual(fragment("#za%C5%BC%C3%B3%C5%82%C4%87"), "zażółć")
        // The renderer's fallback for a destination URL(string:) rejects
        XCTAssertEqual(fragment("%23some%20header"), "some header")
        XCTAssertNil(fragment("other.md#install"))
        XCTAssertNil(fragment("https://example.com/#install"))
        XCTAssertNil(fragment("file:///tmp/a.md#install"))
        XCTAssertNil(fragment("docs/install"))
    }
}
