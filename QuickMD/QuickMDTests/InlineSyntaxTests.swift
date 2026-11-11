import XCTest
import SwiftUI
import AppKit

/// Emphasis, strikethrough, code spans, links and autolinks in the rare cases
/// where QuickMD's hand-written inline parser used to differ from GitHub
/// (1.15 roadmap items 5 + 6). Every expected value is GitHub's own output
/// (`gh api markdown -f mode=gfm`, 2026-11-11, quoted next to the case) or
/// a cmark-gfm spec example (number given), written in the notation of
/// `structure(_:)`.
final class InlineSyntaxTests: XCTestCase {

    private let theme = MarkdownTheme.cached(for: .light)

    /// The first paragraph of `markdown` (definitions below it apply) as
    /// segments: plain text as is, styled text as `FLAGS<link>{text}` — B
    /// bold, I italic, C code (monospaced or the code chip), S struck.
    private func structure(_ markdown: String) -> String {
        for block in MarkdownBlockParser(theme: theme).parse(markdown) {
            if case .text(let attributed) = block.content { return Self.structure(of: attributed) }
        }
        return "<no paragraph>"
    }

    static func structure(of attributed: AttributedString) -> String {
        var segments: [(key: String, text: String)] = []
        for run in attributed.runs {
            let traits = run[AttributeScopes.AppKitAttributes.FontAttribute.self]?.fontDescriptor.symbolicTraits ?? []
            var key = ""
            if traits.contains(.bold) { key += "B" }
            if traits.contains(.italic) { key += "I" }
            if traits.contains(.monoSpace) || run[AttributeScopes.AppKitAttributes.BackgroundColorAttribute.self] != nil {
                key += "C"
            }
            if run[AttributeScopes.AppKitAttributes.StrikethroughStyleAttribute.self] != nil { key += "S" }
            if let link = run.link { key += "<\(link.absoluteString)>" }
            let text = String(attributed[run.range].characters)
            if let last = segments.last, last.key == key {
                segments[segments.count - 1].text += text
            } else {
                segments.append((key, text))
            }
        }
        var out = segments.map { $0.key.isEmpty ? $0.text : "\($0.key){\($0.text)}" }.joined()
        while out.hasSuffix("\n") { out.removeLast() }
        return out
    }

    private func check(_ cases: [(markdown: String, expected: String)], file: StaticString = #filePath, line: UInt = #line) {
        for (markdown, expected) in cases {
            XCTAssertEqual(structure(markdown), expected, markdown, file: file, line: line)
        }
    }

    // MARK: - Item 5: emphasis delimiter rules

    /// A run opens only when left-flanking and closes only when
    /// right-flanking; white space includes the no-break space, punctuation
    /// is ASCII punctuation + Unicode P* (not symbols such as €).
    /// GitHub: `a * foo bar*`, `a*"foo"*`, `* a *` (U+00A0) and `*foo bar *`
    /// stay text; `<em>(foo)</em>` for `*(*foo*)*`; `*(*foo)` text;
    /// `€<em>a</em>€`, `x<em>€a€</em>y`, `«<em>a</em>»`; `£_a_£` text.
    func testFlankingRules() {
        check([
            ("a * foo bar*", "a * foo bar*"),                   // spec 361
            ("a*\"foo\"*", "a*\"foo\"*"),                        // spec 362
            ("*\u{A0}a\u{A0}*", "*\u{A0}a\u{A0}*"),             // spec 363
            ("*foo bar *", "*foo bar *"),                       // spec 375
            ("*(*foo)", "*(*foo)"),                             // spec 377
            ("*(*foo*)*", "I{(foo)}"),                          // spec 378
            ("** foo bar**", "** foo bar**"),                   // spec 388
            ("a**\"foo\"**", "a**\"foo\"**"),                    // spec 389
            ("**(**foo)", "**(**foo)"),                         // spec 401
            ("€*a*€ and x*€a€*y", "€I{a}€ and xI{€a€}y"),
            ("«*a*» and „*a*”", "«I{a}» and „I{a}”"),
            ("£_a_£", "£_a_£"),
        ])
    }

    /// `_` inside a word neither opens nor closes; `*` does.
    /// GitHub: `foo__bar__`, `5__6__78`, `пристаням__стремятся__` text;
    /// `<em>foo_bar_baz</em>`, `<strong>foo__bar__baz</strong>`;
    /// `a<em>b</em>c` but `a_b_c`.
    func testUnderscoreInsideWords() {
        check([
            ("foo__bar__", "foo__bar__"),                       // spec 395
            ("5__6__78", "5__6__78"),                           // spec 396
            ("пристаням__стремятся__", "пристаням__стремятся__"), // spec 397
            ("__foo__bar", "__foo__bar"),                       // spec 409
            ("_foo_bar_baz_", "I{foo_bar_baz}"),                // spec 385
            ("__foo__bar__baz__", "B{foo__bar__baz}"),          // spec 411
            ("a*b*c and a_b_c", "aI{b}c and a_b_c"),
        ])
    }

    /// The "multiple of 3" rule: a run that can open AND close matches only
    /// if the two lengths don't sum to a multiple of 3 (unless both are).
    /// GitHub: `<em>foo<strong>bar</strong>baz</em>`, `<em>foo**bar</em>`,
    /// `foo<strong>bar</strong>***baz`, `<em>foo<strong>bar</strong></em>`.
    func testMultipleOfThreeRule() {
        check([
            ("*foo**bar**baz*", "I{foo}BI{bar}I{baz}"),          // spec 420
            ("*foo**bar*", "I{foo**bar}"),                      // spec 421
            ("foo******bar*********baz", "fooB{bar}***baz"),    // spec 426
            ("*foo**bar***", "I{foo}BI{bar}"),                  // spec 424
        ])
    }

    /// Nested and overlapping runs combine their traits; an emphasis may
    /// close before an opener of the same kind.
    /// GitHub: `<strong>foo <em>bar</em> baz</strong>`,
    /// `<em><strong>foo</strong> bar</em>`, `<em>foo <strong>bar</strong></em>`,
    /// `<strong>foo</strong>` for `****foo****`, `<em><strong>foo</strong></em>`
    /// for `_____foo_____`, `**foo <strong>bar baz</strong>`,
    /// `*foo <em>bar baz</em>`, `<strong>foo, bar, baz</strong>`,
    /// `<em>foo <strong>bar <em>baz</em> bim</strong> bop</em>` (one em
    /// covers baz twice: still italic).
    func testNestedAndOverlappingRuns() {
        check([
            ("**foo *bar* baz**", "B{foo }BI{bar}B{ baz}"),      // spec 437
            ("**foo*bar*baz**", "B{foo}BI{bar}B{baz}"),          // spec 438
            ("***foo** bar*", "BI{foo}I{ bar}"),                // spec 422
            ("*foo **bar***", "I{foo }BI{bar}"),                // spec 423
            ("***foo* bar**", "BI{foo}B{ bar}"),                // spec 439
            ("****foo****", "B{foo}"),                          // spec 473
            ("_____foo_____", "BI{foo}"),                       // spec 477
            ("**foo **bar baz**", "**foo B{bar baz}"),          // spec 480
            ("*foo *bar baz*", "*foo I{bar baz}"),              // spec 481
            ("__foo, __bar__, baz__", "B{foo, bar, baz}"),      // spec 398
            ("*foo **bar *baz* bim** bop*", "I{foo }BI{bar baz bim}I{ bop}"), // spec 427
            ("**foo \"*bar*\" foo**", "B{foo \"}BI{bar}B{\" foo}"), // spec 404
        ])
    }

    /// Code spans and links bind tighter than emphasis, escapes count as
    /// text. GitHub: `<em>a <code>*</code></em>`, `*<a>foo*</a>`,
    /// `_foo <a>bar_</a>`, `foo <em>*</em>`, `<strong>foo <a><em>bar</em></a></strong>`.
    /// (Inside emphasis a code span stays monospaced on its chip and gains
    /// the emphasis traits — "IC".)
    func testCodeAndLinksOutrankEmphasis() {
        check([
            ("*a `*`*", "I{a }IC{*}"),                          // spec 487
            ("*[foo*](/uri)", "*</uri>{foo*}"),                   // spec 529
            ("_foo [bar_](/url)", "_foo </url>{bar_}"),           // spec 483
            ("foo *\\**", "foo I{*}"),                          // spec 446
            ("foo __\\___", "foo B{_}"),                        // spec 461
            ("**foo [*bar*](/url)**", "B{foo }BI</url>{bar}"),  // spec 442
        ])
    }

    /// Emphasis ADDS its traits to what it covers and keeps its look
    /// (option B, decided for 1.15): GitHub draws `<strong><a>docs</a></strong>`
    /// as a link, `<strong><code>make</code></strong>` as code, a footnote
    /// reference as its superscript. Fonts in both scopes.
    func testEmphasisKeepsTheLookOfWhatItCovers() {
        let renderer = MarkdownRenderer(theme: theme, fontScale: 1.5,
                                        footnoteDefinitions: [(id: "1", content: "note")])
        let attributed = renderer.renderInline("**see [docs](u)** *see [it](v)* **run `make`** **a[^1]** ***`x`***")
        func run(_ text: String) -> AttributedString.Runs.Run? {
            attributed.runs.first { String(attributed[$0.range].characters) == text }
        }
        func font(_ text: String) -> NSFont? { run(text)?[AttributeScopes.AppKitAttributes.FontAttribute.self] }
        func traits(_ text: String) -> NSFontDescriptor.SymbolicTraits { font(text)?.fontDescriptor.symbolicTraits ?? [] }
        let linkColor = NSColor(theme.linkColor)
        for link in ["docs", "it"] {
            XCTAssertEqual(run(link)?[AttributeScopes.AppKitAttributes.ForegroundColorAttribute.self], linkColor, link)
            XCTAssertNotNil(run(link)?.foregroundColor, link)
        }
        XCTAssertTrue(traits("docs").contains(.bold))
        XCTAssertTrue(traits("it").contains(.italic))
        XCTAssertTrue(traits("make").isSuperset(of: [.bold, .monoSpace]), "\(traits("make"))")
        XCTAssertEqual(font("make")?.pointSize ?? 0, 13 * 1.5, accuracy: 0.01)
        XCTAssertNotNil(run("make")?[AttributeScopes.AppKitAttributes.BackgroundColorAttribute.self])
        XCTAssertEqual(font("\u{00B9}")?.pointSize ?? 0, 11 * 1.5, accuracy: 0.01, "footnote number keeps its size")
        XCTAssertTrue(traits("x").isSuperset(of: [.bold, .italic, .monoSpace]), "\(traits("x"))")
        XCTAssertNotNil(run("make")?.font, "SwiftUI scope too")
        // Text around them is the ordinary bold body font.
        XCTAssertEqual(font("run "), theme.fonts.appKit(size: 14 * 1.5, weight: .bold))
    }

    // MARK: - Strikethrough (GFM)

    /// One or two tildes, opener and closer of the SAME length; three are
    /// text. GitHub: `<del>one</del> and <del>two</del> and ~~~three~~~ and
    /// ~~mixed~ and <del>a <del>b</del> c</del>`; `<del><strong>bold
    /// strike</strong></del>`; `<em>a <del>b</del> c</em>`.
    func testStrikethroughRuns() {
        check([
            ("~one~ and ~~two~~ and ~~~three~~~ and ~~mixed~", "S{one} and S{two} and ~~~three~~~ and ~~mixed~"),
            ("~a ~~b~~ c~", "S{a b c}"),
            ("~~**bold strike**~~", "BS{bold strike}"),
            ("*a ~~b~~ c*", "I{a }IS{b}I{ c}"),
            ("a ~5 min and ~10 min", "a ~5 min and ~10 min"),
        ])
    }

    // MARK: - Code spans

    /// CommonMark code spans: any run length, closed by a run of exactly that
    /// length, one space stripped from both ends only when both are spaces
    /// and the content is not all spaces; an unclosed run is text as a whole.
    /// GitHub: `<code>`a`</code> and <code>b</code> and <code>c</code> and
    /// <code>  </code> and <code>d`e</code>`; spec 340, 341, 350, 359.
    func testCodeSpanRuns() {
        check([
            ("`` `a` `` and ```b``` and ` c ` and `  ` and ``d`e``", "C{`a`} and C{b} and C{c} and C{  } and C{d`e}"),
            ("` `` `", "C{``}"),                                 // spec 340
            ("`  ``  `", "C{ `` }"),                             // spec 341
            ("` foo `` bar `", "C{foo `` bar}"),                 // spec 350
            ("`foo``bar``", "`fooC{bar}"),                       // spec 359
        ])
    }

    // MARK: - Item 6: links

    /// A title may hold parentheses or the other quote; a `<…>` destination
    /// may hold parentheses. GitHub: `<a href="u" title="x)y">a</a>`,
    /// `<a href="u" title="x (y">b</a>`, `<a href="b)c">c</a>`,
    /// `<a href="u" title="t">d</a>`, `<a href="foo(and(bar)">link</a>`
    /// (spec 507), `<a href="https://x.example" title="title &quot;q&quot;">`.
    func testLinkTitlesAndPointyDestinations() {
        check([
            ("[a](u \"x)y\") and [b](u \"x (y\")", "<u>{a} and <u>{b}"),
            ("[c](<b)c>) and [d](u (t))", "<b)c>{c} and <u>{d}"),
            ("[link](<foo(and(bar)>)", "<foo(and(bar)>{link}"),
            ("[e](https://x.example (title \"q\")) end", "<https://x.example>{e} end"),
            ("[f](https://x.example \"title (with) parens\")", "<https://x.example>{f}"),
            // Lenient on purpose (not GitHub): a destination with spaces is kept whole.
            ("[doc](My Notes.md)", "<My%20Notes.md>{doc}"),
        ])
    }

    /// Links never nest: the INNER link wins and the outer brackets are text.
    /// GitHub: `[a <a href="x">b</a> c](y)`; spec 526, 527, 540, 541.
    func testInnerLinkWins() {
        check([
            ("[a [b](x) c](y)", "[a <x>{b} c](y)"),
            ("[foo [bar](/uri)](/uri)", "[foo </uri>{bar}](/uri)"),                     // spec 526
            ("[foo *[bar [baz](/uri)](/uri)*](/uri)", "[foo I{[bar }I</uri>{baz}I{](/uri)}](/uri)"), // spec 527
            ("[foo [bar](/uri)][ref]\n\n[ref]: /uri", "[foo </uri>{bar}]</uri>{ref}"),  // spec 540
            ("[foo *bar [baz][ref]*][ref]\n\n[ref]: /uri", "[foo I{bar }I</uri>{baz}]</uri>{ref}"), // spec 541
            // An image inside a link is no link: the badge idiom stays one link.
            ("see [![b](https://x.org/i.svg)](https://x)", "see I<https://x>{[Image: b]}"),
        ])
    }

    /// A backtick code span inside or across a link label, and escaped
    /// brackets. GitHub: `<a href="x"><code>a]</code></a>`,
    /// `<code>[a](b)</code>`, `<a href="x">a]b</a>`, `[a](x)`.
    func testBackticksAndEscapesInLabels() {
        check([
            ("[`a]`](x)", "C<x>{a]}"),
            ("`[a](b)`", "C{[a](b)}"),
            ("[a\\]b](x)", "<x>{a]b}"),
            ("\\[a](x)", "[a](x)"),
            ("[link *foo **bar** `#`*](/uri)", "</uri>{link }I</uri>{foo }BI</uri>{bar}I</uri>{ }IC</uri>{#}"), // spec 524
        ])
    }

    /// A full reference with an undefined label is no link, and does not
    /// fall back to a shortcut. GitHub: `[foo][bar] and <a>foo</a> and
    /// <a>foo</a> <a>baz</a>`; spec 579 `[foo]<a href="/url1">bar</a>`.
    func testUndefinedFullReferenceIsNoLink() {
        check([
            ("[foo][bar] and [foo][] and [foo] [baz]\n\n[foo]: /url1\n[baz]: /url3",
             "[foo][bar] and </url1>{foo} and </url1>{foo} </url3>{baz}"),
            ("[foo][bar][baz]\n\n[baz]: /url1\n[foo]: /url2", "[foo]</url1>{bar}"), // spec 579
        ])
    }

    /// A quote (rendered later, through `ReferenceLinks`) resolves brackets
    /// exactly as a paragraph does.
    func testQuotesResolveBracketsLikeParagraphs() {
        let definitions = "\n\n[r]: https://r.example\n[^n]: note"
        let lines = ["[a [b][r] c][r]", "[foo][nope] and [r]", "`[r]` and [x `]`][r]", "<https://y.example/[r]> [r]",
                     "***[r]*** and ~~[r]~~", "see [![i][r]][r]",
                     "~~x[^n]~~ and ***y[^n]*** and `[^n]`"]
        for line in lines {
            let paragraph = structure(line + definitions)
            let blocks = MarkdownBlockParser(theme: theme).parse("> " + line + definitions)
            guard case .blockquote(let quote, _)? = blocks.first?.content else { return XCTFail(line) }
            let rendered = Self.structure(of: MarkdownRenderer(theme: theme).renderQuotedBody(quote))
            XCTAssertEqual(rendered, paragraph, line)
        }
        XCTAssertEqual(structure("[a [b][r] c][r]" + definitions),
                       "[a <https://r.example>{b} c]<https://r.example>{r}")
        // A footnote reference inside `~~…~~` / `***…***` is a reference
        // (their content is parsed since 1.15); inside code it is text.
        XCTAssertEqual(structure("~~x[^n]~~ and ***y[^n]*** and `[^n]`" + definitions),
                       "S{x}BS{\u{00B9}} and BI{y\u{00B9}} and C{[^n]}")
    }

    // MARK: - Autolinks

    /// `<scheme:…>` and `<address@domain>` are links without their brackets,
    /// and outrank emphasis and links. GitHub: `<a href="https://x.example">`,
    /// `<a href="mailto:a@b.example">a@b.example</a>`, spec 605, 534, 489.
    func testAngleAutolinks() {
        check([
            ("<https://x.example> and <a@b.example>", "<https://x.example>{https://x.example} and <mailto:a@b.example>{a@b.example}"),
            ("<MAILTO:FOO@BAR.BAZ>", "<MAILTO:FOO@BAR.BAZ>{MAILTO:FOO@BAR.BAZ}"),
            ("[foo<http://example.com/?search=](uri)>",
             "[foo<http://example.com/?search=%5D(uri)>{http://example.com/?search=](uri)}"),
            ("**a<http://foo.bar/?q=**>", "**a<http://foo.bar/?q=**>{http://foo.bar/?q=**}"),
            // Not autolinks (GitHub: text, the bare URL inside is linked).
            ("< http://foo.bar >", "< <http://foo.bar>{http://foo.bar} >"),
        ])
    }

    /// Bare URLs end where GitHub ends them. GitHub: `see <a>https://x.example/a_(b)</a>.`,
    /// `(<a>https://x.example/c</a>)`, `<a>https://x.example/d</a>,`,
    /// `<em><a>https://x.example/e</a></em>`, `<a href="https://x.example/f?q=1">…</a>&amp;hl;`,
    /// `<a href="http://www.x.example">www.x.example</a>`, `xwww.y.example`
    /// text, `(<a href="http://www.z.example/p">www.z.example/p</a>)`.
    func testBareAutolinkEdges() {
        check([
            ("see https://x.example/a_(b).", "see <https://x.example/a_(b)>{https://x.example/a_(b)}."),
            ("(https://x.example/c) and https://x.example/d,",
             "(<https://x.example/c>{https://x.example/c}) and <https://x.example/d>{https://x.example/d},"),
            ("*https://x.example/e*", "I<https://x.example/e>{https://x.example/e}"),
            ("https://x.example/f?q=1&hl;", "<https://x.example/f?q=1>{https://x.example/f?q=1}&hl;"),
            ("www.x.example and xwww.y.example and (www.z.example/p)",
             "<http://www.x.example>{www.x.example} and xwww.y.example and (<http://www.z.example/p>{www.z.example/p})"),
            ("[see https://x.example/z](https://y.example)", "<https://y.example>{see https://x.example/z}"),
        ])
    }

    /// E-mail addresses in text are links (GFM). GitHub: `<a
    /// href="mailto:a.b-c_d@a.b">a.b-c_d@a.b</a>.`, `x@y.z_` text,
    /// `<em><a href="mailto:x@y.example">…</a></em>`, `<a href="u">m@x.example</a>`,
    /// `<code>c@d.example</code>`; spec 630.
    func testEmailAutolinks() {
        check([
            ("mail a.b-c_d@a.b. and x@y.z_", "mail <mailto:a.b-c_d@a.b>{a.b-c_d@a.b}. and x@y.z_"),
            ("*x@y.example* and [m@x.example](u) and `c@d.example`",
             "I<mailto:x@y.example>{x@y.example} and <u>{m@x.example} and C{c@d.example}"),
            ("hello@mail+xyz.example isn't valid, but hello+xyz@mail.example is.",
             "hello@mail+xyz.example isn't valid, but <mailto:hello+xyz@mail.example>{hello+xyz@mail.example} is."),
        ])
    }

    /// `[l]()` and `[l](<>)` are links with an empty href on GitHub
    /// (`<a href="">l</a>`, spec 495/496): drawn as a link, but no URL
    /// attribute at all — a click does nothing, and `handleLinkActivation`
    /// never sees an empty URL.
    func testEmptyDestinationLooksLikeALinkButHasNoURL() {
        for markdown in ["[l]()", "[l](<>)", "[l]( )"] {
            let attributed = MarkdownRenderer(theme: theme).renderInline(markdown)
            XCTAssertEqual(String(attributed.characters), "l", markdown)
            XCTAssertTrue(attributed.runs.allSatisfy { $0.link == nil }, markdown)
            let run = attributed.runs.first
            XCTAssertEqual(run?[AttributeScopes.AppKitAttributes.ForegroundColorAttribute.self],
                           NSColor(theme.linkColor), markdown)
            XCTAssertNotNil(run?[AttributeScopes.AppKitAttributes.UnderlineStyleAttribute.self], markdown)
        }
    }

    /// A footnote reference ends at the first `]`; the lookup is shared per
    /// line, so 50 000 `[^` with no `]` examine each byte once — proved by
    /// counting, not by the clock — and still render (with a defined
    /// footnote, so the lookup runs) in a paragraph and through
    /// `ReferenceLinks` in a quote.
    func testFootnoteReferenceLookupIsLinear() {
        let line = String(repeating: "[^", count: 50_000)
        let lookup = InlineSyntaxScanner.NextClosingBracket(line)
        var index = line.startIndex
        while index < line.endIndex {
            XCTAssertNil(lookup.at(orAfter: line.utf8.index(index, offsetBy: 2)))
            index = line.utf8.index(index, offsetBy: 2)
        }
        XCTAssertLessThanOrEqual(lookup.bytesExamined, line.utf8.count)

        // Many references with a `]` each: still one pass.
        let refs = String(repeating: "x[^n] ", count: 10_000)
        let refLookup = InlineSyntaxScanner.NextClosingBracket(refs)
        var position = refs.startIndex
        while let start = refs[position...].range(of: "[^")?.upperBound {
            guard let close = refLookup.at(orAfter: start) else { return XCTFail("close") }
            position = close
        }
        XCTAssertLessThanOrEqual(refLookup.bytesExamined, refs.utf8.count)

        let renderer = MarkdownRenderer(theme: theme, footnoteDefinitions: [(id: "n", content: "note")])
        var counts: [Int] = []
        onSmallStack {
            counts = [renderer.renderInline(line).characters.count,
                      ReferenceLinks.inlined("> " + line, definitions: [:], footnoteIds: ["n"]).count]
        }
        XCTAssertEqual(counts, [100_000, 100_002])
    }

    // MARK: - CJK (deliberate deviation from GitHub, see InlineDelimiterStack.push)

    /// Emphasis next to CJK text and CJK punctuation stays emphasis — it was
    /// on main before 1.15 (GitHub leaves the first, second and fourth
    /// literal). Non-CJK text is unaffected (`testFlankingRules`, spec probe).
    func testCJKEmphasisNextToPunctuation() {
        check([
            ("**「テスト」**と", "B{「テスト」}と"),
            ("**テスト。**次", "B{テスト。}次"),
            ("これは**強調**です", "これはB{強調}です"),
            ("これは**「強調」**です", "これはB{「強調」}です"),
            ("**加粗（括号）**文字", "B{加粗（括号）}文字"),
            ("**굵게**는", "B{굵게}는"),
            ("*「斜体」*の", "I{「斜体」}の"),
            // A variation selector after a CJK character: its base decides.
            ("葛\u{E0100}**「a」**", "葛\u{E0100}B{「a」}"),
            // Non-CJK neighbours: CommonMark unchanged (GitHub: literal).
            ("a**\"foo\"**b", "a**\"foo\"**b"),
            ("é**(x)**é", "é**(x)**é"),
        ])
    }

    // MARK: - Headings (policy B)

    /// A heading is bold throughout; code stays monospaced on its chip at
    /// 13/14 of the heading size, italic combines, a link keeps the link
    /// colour, a footnote number keeps 11/14 — and the characters (so the
    /// id: GitHub `title-code-it-l`) do not change.
    func testHeadingKeepsTheLookOfItsRuns() {
        let renderer = MarkdownRenderer(theme: theme, footnoteDefinitions: [(id: "1", content: "n")])
        let title = "Title `code` *it* [l](u)[^1]"
        for level in [1, 2, 4] {
            let heading = renderer.renderHeader(title, level: level)
            let size = renderer.headerFontSize(level: level)
            func run(_ text: String) -> AttributedString.Runs.Run? {
                heading.runs.first { String(heading[$0.range].characters) == text }
            }
            func font(_ text: String) -> NSFont? { run(text)?[AttributeScopes.AppKitAttributes.FontAttribute.self] }
            let code = font("code")?.fontDescriptor.symbolicTraits ?? []
            XCTAssertTrue(code.isSuperset(of: [.bold, .monoSpace]), "\(code)")
            XCTAssertEqual(font("code")?.pointSize ?? 0, size * 13 / 14, accuracy: 0.001)
            XCTAssertNotNil(run("code")?[AttributeScopes.AppKitAttributes.BackgroundColorAttribute.self])
            XCTAssertTrue(font("it")?.fontDescriptor.symbolicTraits.isSuperset(of: [.bold, .italic]) ?? false)
            XCTAssertEqual(run("l")?[AttributeScopes.AppKitAttributes.ForegroundColorAttribute.self],
                           NSColor(theme.linkColor))
            XCTAssertEqual(font("\u{00B9}")?.pointSize ?? 0, size * 11 / 14, accuracy: 0.001)
            XCTAssertEqual(font("Title "), renderer.headerAppKitFont(level: level))
            XCTAssertNotNil(run("code")?.font, "SwiftUI scope too")
        }
        let blocks = MarkdownBlockParser(theme: theme).parse("## Title `code` *it* [l](u)")
        XCTAssertEqual(HeadingAnchors.ids(for: HeadingAnchors.headings(of: blocks, renderer: MarkdownRenderer(theme: theme))
            .map(\.text)), ["title-code-it-l"])
    }

    // MARK: - Review findings (S2, S3, N2)

    /// `<…>` autolinks decode character references in the text and the URL
    /// (GitHub: `href="https://a.example/?a=1&b=2"`, text `…&b=2`); bare
    /// URLs keep them as written (GitHub too).
    func testAngleAutolinkDecodesCharacterReferences() {
        check([
            ("<https://a.example/?a=1&amp;b=2>", "<https://a.example/?a=1&b=2>{https://a.example/?a=1&b=2}"),
            ("https://a.example/?a=1&amp;b=2", "<https://a.example/?a=1&amp;b=2>{https://a.example/?a=1&amp;b=2}"),
        ])
    }

    /// An address right after `/` belongs to a URL. GitHub:
    /// `ftp://user@example.com` text, `<a href="http://user@example.com">`.
    /// GitHub refuses an address only inside an `ftp://` URL; after any
    /// other `/` it links: `sales/<a href="mailto:support@example.com">`,
    /// `path/to/<a href="mailto:me@host.example">`,
    /// `ssh://<a href="mailto:git@github.com">`, `ftp://user@example.com`.
    func testNoEmailInsideAURL() {
        check([
            ("see ftp://user@example.com", "see ftp://user@example.com"),
            ("see http://user@example.com", "see <http://user@example.com>{http://user@example.com}"),
            ("see sales/support@example.com", "see sales/<mailto:support@example.com>{support@example.com}"),
            ("path/to/me@host.example", "path/to/<mailto:me@host.example>{me@host.example}"),
            ("ssh://git@github.com", "ssh://<mailto:git@github.com>{git@github.com}"),  // not a credential (GitHub e-mail case) betterleaks:allow
        ])
    }

    /// A `www.` inside a domain that failed only because its SECOND-TO-LAST
    /// label has an `_` still links when its own domain is the last label.
    /// GitHub: `www._<a href="http://www.example">www.example</a>`,
    /// `a _www.a_b._<a href="http://www.example">www.example</a> z`.
    func testInnerWWWAfterAFailedDomain() {
        check([
            ("www._www.example", "www._<http://www.example>{www.example}"),
            ("a _www.a_b._www.example z", "a _www.a_b._<http://www.example>{www.example} z"),
            ("_www.a.b_x", "_www.a.b_x"),
        ])
    }

    /// A reference label is at most 999 BYTES (cmark): GitHub links a label
    /// of 333 `字` (999 bytes) and leaves one of 400 (1200 bytes) as text.
    func testLinkLabelCapIsInBytes() {
        let short = String(repeating: "字", count: 333)
        let long = String(repeating: "字", count: 400)
        let markdown = "[\(short)] and [\(long)]\n\n[\(short)]: /han333\n[\(long)]: /han400"
        XCTAssertEqual(structure(markdown), "</han333>{\(short)} and [\(long)]")
    }

    /// The footnote numbering scan reads a text as the renderer draws it:
    /// a link's destination holds no reference, its text and an image's alt
    /// do. GitHub: `[t](x[^a]) then[^b]` numbers b only (a unlisted);
    /// `<y [^a]>` destinations too.
    func testFootnoteScanSkipsLinkDestinations() {
        XCTAssertEqual(FootnoteReferenceScan.labels(in: "[t](x[^a]) then[^b] and [u](<y [^a]>)",
                                                    defined: ["a", "b"]), ["b"])
        XCTAssertEqual(FootnoteReferenceScan.labels(in: "[![i](img)](u[^a]) x[^b] [t [^a]](v)",
                                                    defined: ["a", "b"]), ["b", "a"])
        XCTAssertEqual(FootnoteReferenceScan.labels(in: "![x [^a]](y[^b])", defined: ["a", "b"]), ["a"])
        XCTAssertEqual(FootnoteReferenceScan.labels(in: "[a [b](x) c](y[^a])", defined: ["a"]), ["a"],
                       "the inner link wins, so the outer `](y…)` is text")
    }

    /// A definition-list term is a bold context like a heading: code stays
    /// monospaced on its chip, italic stays (policy B).
    func testDefinitionTermKeepsTheLookOfItsRuns() {
        let blocks = MarkdownBlockParser(theme: theme).parse("Term `code` *it*\n: Definition")
        guard case .text(let attributed)? = blocks.first?.content else { return XCTFail("definition list") }
        let structure = Self.structure(of: attributed)
        XCTAssertTrue(structure.hasPrefix("B{Term }BC{code}B{ }BI{it}"), structure)
    }

    /// The scans a long line can repeat — `www.` domains (review B1:
    /// `_www.a.` × N + `_x_` was quadratic), `http(s)://`, e-mail local
    /// parts and domains, `<…>` attempts, reference labels (S2) — do work
    /// proportional to the line: N and 4N measured by counters, no clock.
    func testRepeatedScansDoLinearWork() {
        func autolinkWork(_ line: String) -> Int {
            let scan = MarkdownRenderer.AutolinkScan()
            var index = line.startIndex
            while index < line.endIndex {
                let byte = line.utf8[index]
                if byte == UInt8(ascii: "h") || byte == UInt8(ascii: "w"),
                   let link = MarkdownRenderer.bareAutolink(line[index...], in: line, scan: scan) {
                    index = link.end
                    continue
                }
                index = line.utf8.index(after: index)
            }
            return scan.work
        }
        func emailWork(_ line: String) -> Int {
            var work = 0
            _ = MarkdownRenderer.emailAutolinks(in: line, work: &work)
            return work
        }
        func angleWork(_ line: String) -> Int {
            var total = 0
            var index = line.startIndex
            while index < line.endIndex {
                if line.utf8[index] == UInt8(ascii: "<") {
                    var reach = 0
                    _ = InlineSyntaxScanner.angleAutolink(atStartOf: line[index...], reach: &reach)
                    total += reach
                }
                index = line.utf8.index(after: index)
            }
            return total
        }
        func labelWork(_ line: String) -> Int {
            // Every `]` asks for the label back to its `[` (the bracket stack).
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
        let cases: [(String, (Int) -> String, (String) -> Int)] = [
            ("www failing", { String(repeating: "_www.a.", count: $0) + "_x_" }, autolinkWork),
            ("www second-to-last", { String(repeating: "www._www._www.a_b.c", count: $0) }, autolinkWork),
            ("www linking", { String(repeating: "www.a ", count: $0) }, autolinkWork),
            ("http failing", { String(repeating: "(http://a_.b_", count: $0) }, autolinkWork),
            ("https", { String(repeating: "(https://a.b/c) ", count: $0) }, autolinkWork),
            ("e-mail local parts", { String(repeating: "a.b-c_d", count: $0) + "@" + String(repeating: "x@", count: $0) }, emailWork),
            ("e-mail domains", { String(repeating: "a@b-c.d_", count: $0) }, emailWork),
            ("< e-mail", { String(repeating: "<a.b@", count: $0) }, angleWork),
            ("< scheme", { String(repeating: "<ab:cd", count: $0) }, angleWork),
            ("labels", { String(repeating: "[", count: $0) + String(repeating: "]", count: $0) }, labelWork),
        ]
        let n = 2_000
        for (name, make, work) in cases {
            let small = make(n)
            let large = make(4 * n)
            let (w1, w4) = (work(small), work(large))
            XCTAssertLessThanOrEqual(w1, 4 * small.utf8.count, "\(name): \(w1) for \(small.utf8.count) bytes")
            XCTAssertLessThanOrEqual(w4, 4 * w1 + 2_000, "\(name): N \(w1), 4N \(w4)")
        }
        // The real renderers on the review's inputs (with a definition, so
        // labels are looked up), on the small stack.
        let renderer = MarkdownRenderer(theme: theme, referenceDefinitions: ["a": "https://a.example"])
        let lines = [String(repeating: "_www.a.", count: 16_000) + "_x_",
                     String(repeating: "[", count: 20_000) + "b" + String(repeating: "]", count: 20_000)]
        var counts: [Int] = []
        onSmallStack {
            counts = lines.map { renderer.renderInline($0).characters.count }
                + lines.map { ReferenceLinks.inlined($0, definitions: ["a": "https://a.example"]).count }
        }
        // Nothing is linked; only the final `_x_` is emphasis (its two `_` go).
        XCTAssertEqual(counts, [lines[0].count - 2, lines[1].count, lines[0].count, lines[1].count])
    }

    // MARK: - Adversarial input: linear, no deep recursion

    /// Runs `body` on a thread with the parse task's small (512 KB) stack, so
    /// unbounded recursion crashes here instead of passing on the 8 MB main stack.
    private func onSmallStack(_ body: @escaping () -> Void) {
        let done = DispatchSemaphore(value: 0)
        let thread = Thread { body(); done.signal() }
        thread.stackSize = 512 * 1024
        thread.start()
        XCTAssertEqual(done.wait(timeout: .now() + 30), .success)
    }

    /// Lines built to defeat a naive matcher render on the small stack and
    /// keep every character. (No timing assertion: a quadratic pass over
    /// these 10 000-unit lines would take minutes and hit the wait above.)
    func testAdversarialLinesRenderOnTheSmallStack() {
        let n = 10_000
        let lines = [
            String(repeating: "*", count: n),
            String(repeating: "*a ", count: n / 2) + String(repeating: "a* ", count: n / 2),
            String(repeating: "_a ", count: n / 2) + String(repeating: "a_ ", count: n / 2),
            String(repeating: "**a *", count: n / 4),
            String(repeating: "~", count: n) + " " + String(repeating: "~a ", count: n / 2),
            String(repeating: "[", count: n),
            String(repeating: "[", count: n) + "a" + String(repeating: "](u)", count: n),
            String(repeating: "[a](", count: n / 2),
            String(repeating: "[a](<", count: n / 2),
            String(repeating: "[a](u \"", count: n / 2),
            String(repeating: "[a][", count: n / 2),
            String(repeating: "`", count: n) + " " + String(repeating: "`a ", count: n / 2),
            String(repeating: "` `` ``` ", count: n / 4),
            String(repeating: "<", count: n) + String(repeating: "<a@", count: n / 3),
            String(repeating: "www.a", count: n / 2) + " " + String(repeating: "https://a.b/(", count: n / 4),
            String(repeating: "a@", count: n / 2) + String(repeating: ")", count: n),
        ]
        let renderer = MarkdownRenderer(theme: theme)
        var lengths: [Int] = []
        onSmallStack {
            lengths = lines.map { renderer.renderInline($0).characters.count }
        }
        XCTAssertEqual(lengths.count, lines.count)
        // Nothing here is consumed by a match except the nested links.
        XCTAssertEqual(lengths[0], n)
        XCTAssertEqual(lengths[5], n)
        XCTAssertEqual(lengths[6], 5 * n - 4, "only the innermost [a](u) is a link")
    }
}
