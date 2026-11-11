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
    /// (Inside emphasis a code span keeps its chip but takes the emphasis
    /// font, as before 1.15 — hence "BC"/"IC".)
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
                     "***[r]*** and ~~[r]~~", "see [![i][r]][r]"]
        for line in lines {
            let paragraph = structure(line + definitions)
            let blocks = MarkdownBlockParser(theme: theme).parse("> " + line + definitions)
            guard case .blockquote(let quote, _)? = blocks.first?.content else { return XCTFail(line) }
            let rendered = Self.structure(of: MarkdownRenderer(theme: theme).renderQuotedBody(quote))
            XCTAssertEqual(rendered, paragraph, line)
        }
        XCTAssertEqual(structure("[a [b][r] c][r]" + definitions),
                       "[a <https://r.example>{b} c]<https://r.example>{r}")
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
