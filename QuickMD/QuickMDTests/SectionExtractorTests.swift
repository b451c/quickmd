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

    /// A value only `defaults write` can store (outside 2, 3, 4, 6) left both
    /// Pickers without a selected item; it reads as the nearest choice.
    func testContentsDepthOutsideTheChoicesReadsAsTheNearest() {
        let tags = Set(ToCDepth.choices.map(\.maxLevel))
        for stored in [-3, 0, 1, 2, 3, 4, 5, 6, 7, 99, Int.max, Int.min] {
            XCTAssertTrue(tags.contains(ToCDepth.normalized(stored)), "\(stored) must be a Picker tag")
        }
        XCTAssertEqual([0, 1, 2, 3, 4, 5, 6, 7, 42].map(ToCDepth.normalized), [2, 2, 2, 3, 4, 6, 6, 6, 6])
    }

    // MARK: - Settings tab (remembered by identifier)

    /// The Settings tab was remembered by INDEX; the update reads that index
    /// once (when the identifier key is absent) and maps it to the same tab.
    func testSettingsTabMigratesTheLegacyIndex() throws {
        XCTAssertEqual(SettingsTab.allCases, [.general, .themes, .fonts, .editor], "legacy index order")
        XCTAssertEqual([0, 1, 2, 3].map(SettingsTab.fromLegacyIndex), [.general, .themes, .fonts, .editor])
        XCTAssertEqual([-1, 4, 99].map(SettingsTab.fromLegacyIndex), [.general, .general, .general])
        XCTAssertEqual(SettingsTab.fromLegacyIndex(nil), .general)

        let suite = try TemporaryDefaults("SettingsTab")
        defer { suite.remove() }
        let defaults = suite.defaults
        XCTAssertEqual(SettingsTab.initial(in: defaults), .general, "fresh install")
        defaults.set(2, forKey: SettingsTab.legacyIndexKey)
        XCTAssertEqual(SettingsTab.initial(in: defaults), .fonts, "the tab SwiftUI remembered")
        defaults.set(SettingsTab.editor.rawValue, forKey: SettingsTab.defaultsKey)
        XCTAssertEqual(SettingsTab.initial(in: defaults), .editor, "the identifier wins once written")
        defaults.set("removed-tab", forKey: SettingsTab.defaultsKey)
        XCTAssertEqual(SettingsTab.initial(in: defaults), .fonts, "an unknown identifier falls back")
        XCTAssertEqual(SettingsTab.legacyIndexKey, "com_apple_SwiftUI_Settings_selectedTabIndex")
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

    /// Character references in a heading show as their characters (GitHub
    /// decodes them before its slug) — ids from GitHub's renderer
    /// (`gh api markdown`, 2026-11-04). A code span keeps the reference, and a
    /// decoded `&#42;` is a literal `*`, not emphasis.
    func testHeadingEntitiesAreDecodedLikeGitHub() {
        let headings = anchorHeadings(of: """
        # Q&amp;A &lt;tag&gt; &#169;
        ## Tom &amp; Jerry
        ## `a &amp; b`
        ## R&amp;D &nbsp;x
        ## a &#42;b&#42;
        ## [Q&amp;A](#x) here
        ## **Tom &amp; Jerry**
        ## 5 &lt; 6
        """)
        XCTAssertEqual(headings.map(\.text), [
            "Q&A <tag> ©", "Tom & Jerry", "a &amp; b", "R&D \u{00A0}x", "a *b*",
            "Q&A here", "Tom & Jerry", "5 < 6",
        ])
        XCTAssertEqual(HeadingAnchors.ids(for: headings.map(\.text)), [
            "qa-tag-", "tom--jerry", "a-amp-b", "rd-x", "a-b", "qa-here", "tom--jerry-1", "5--6",
        ])

        // The heading view, search, print and the measurer all draw `renderHeader`.
        let renderer = MarkdownRenderer(theme: MarkdownTheme.cached(for: .light))
        let italic = renderer.renderHeader("a &#42;b&#42;", level: 2)
        XCTAssertEqual(italic.runs.count, 1, "no emphasis run from a decoded asterisk")
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

    /// Review R3: `URL(string:)` comes first, so every destination macOS
    /// accepts keeps its URL exactly (IDN hosts included on 14+); our encoder
    /// only runs when the parse fails — on macOS 13 that includes `[` `]` in a
    /// path and a second `#`, which must still become links.
    func testLinkURLFallsBackOnlyWhenTheParseFails() throws {
        guard #available(macOS 14, *) else { throw XCTSkip("needs the strict-parse API to emulate macOS 13") }
        let strict: (String) -> URL? = { URL(string: $0, encodingInvalidCharacters: false) }
        let cases: [(String, String)] = [
            ("docs/a[1].md", "docs/a%5B1%5D.md"),
            ("https://x/?a[]=1", "https://x/?a%5B%5D=1"),
            ("a#b#c", "a#b%23c"),
            ("README.md#Install Guide", "README.md#Install%20Guide"),
            ("https://example.com/docs_(v2)#top", "https://example.com/docs_(v2)#top"),
        ]
        for (destination, expected) in cases {
            let url = try XCTUnwrap(MarkdownRenderer.linkURL(for: destination, parse: strict), destination)
            XCTAssertEqual(url.absoluteString, expected, destination)
        }
        XCTAssertEqual(try XCTUnwrap(MarkdownRenderer.linkURL(for: "a#b#c", parse: strict))
                        .fragment(percentEncoded: false), "b#c")

        // The default parse (this OS): whatever URL(string:) gives, unchanged.
        for destination in ["https://bücher.de/x", "docs/a[1].md", "https://x/?a[]=1", "README.md#Install Guide",
                            "a%20b.md#x", "mailto:a@b.c"] {
            XCTAssertEqual(MarkdownRenderer.linkURL(for: destination), URL(string: destination), destination)
        }
    }

    /// `other.md#section`: the fragment is parked for the other document's
    /// window (which takes it once laid out, or at once when already open).
    func testCrossDocumentAnchorIsHandedToTheOtherDocument() throws {
        let anchors = CrossDocumentAnchors()
        let link = try XCTUnwrap(MarkdownRenderer.linkURL(for: "other.md#Install Guide"))
        let fragment = try XCTUnwrap(CrossDocumentAnchors.fragment(of: link))
        XCTAssertEqual(fragment, "Install Guide")
        XCTAssertNil(CrossDocumentAnchors.fragment(of: try XCTUnwrap(MarkdownRenderer.linkURL(for: "other.md"))))
        XCTAssertEqual(CrossDocumentAnchors.fragment(of: try XCTUnwrap(MarkdownRenderer.linkURL(for: "other.md#"))), "",
                       "an empty fragment is the top, as in-document")

        let target = URL(fileURLWithPath: "/docs/guide/other.md")
        let posted = expectation(forNotification: CrossDocumentAnchors.requested, object: nil) { note in
            note.object as? String == "/docs/guide/other.md"
        }
        let now = Date()
        anchors.request(fragment, for: URL(fileURLWithPath: "/docs/guide/./sub/../other.md"), now: now)
        wait(for: [posted], timeout: 1)

        XCTAssertNil(anchors.take(for: URL(fileURLWithPath: "/docs/guide/another.md"), now: now))
        XCTAssertNil(anchors.take(for: nil, now: now))
        XCTAssertEqual(anchors.take(for: target, now: now.addingTimeInterval(2)), "Install Guide")
        XCTAssertNil(anchors.take(for: target, now: now), "taken once")

        anchors.request("intro", for: target, now: now)
        XCTAssertNil(anchors.take(for: target, now: now.addingTimeInterval(CrossDocumentAnchors.lifetime + 1)),
                     "a stale request never moves a window opened much later")
        XCTAssertNil(anchors.take(for: target, now: now), "and it is gone")
    }

    /// A link destination becomes the same URL on every macOS: macOS 13's
    /// `URL(string:)` rejects spaces / non-ASCII (14+ encodes them), and the
    /// old 13 fallback encoded the `#` too, so `README.md#Install Guide` was a
    /// file named "README.md#Install Guide". Every result must also parse
    /// WITHOUT the OS encoding anything (strict parse on 14+), i.e. the
    /// string handed to `URL(string:)` is already valid as macOS 13 sees it.
    func testLinkURLKeepsTheFragmentDelimiterOnEveryMacOS() throws {
        func link(_ destination: String) throws -> URL {
            let url = try XCTUnwrap(MarkdownRenderer.linkURL(for: destination), destination)
            if #available(macOS 14, *) {
                XCTAssertNotNil(URL(string: url.absoluteString, encodingInvalidCharacters: false),
                                "\(destination) must not rely on the OS encoding it")
            }
            return url
        }

        let sameFile = try link("README.md#Install Guide")
        XCTAssertEqual(sameFile.relativeString, "README.md#Install%20Guide")
        XCTAssertEqual(sameFile.path, "README.md")
        XCTAssertEqual(sameFile.fragment(percentEncoded: false), "Install Guide")

        let other = try link("Zażółć notes.md#Sekcja Ł#2")
        XCTAssertEqual(other.path, "Zażółć notes.md")
        XCTAssertEqual(other.fragment(percentEncoded: false), "Sekcja Ł#2", "a later # belongs to the fragment")

        XCTAssertEqual(HeadingAnchors.inDocumentFragment(of: try link("#Install Guide")), "Install Guide")

        let web = try link("https://example.com/a b?q=x y#frag z")
        XCTAssertEqual(web.host, "example.com")
        XCTAssertEqual(web.fragment(percentEncoded: false), "frag z")

        XCTAssertEqual(try link("100% done.md").relativeString, "100%25%20done.md", "a bare % is not an escape")
        XCTAssertEqual(try link("a%20b.md#x").relativeString, "a%20b.md#x", "valid URLs are untouched")
        XCTAssertEqual(try link("https://example.com/docs_(v2)#top").absoluteString,
                       "https://example.com/docs_(v2)#top")
    }
}
