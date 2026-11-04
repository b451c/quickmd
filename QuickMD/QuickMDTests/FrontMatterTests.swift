import XCTest
import SwiftUI

/// YAML front matter as a properties table (v1.14.2).
///
/// `FrontMatter.properties(fromYAML:)` reads one small YAML subset and answers
/// nil for everything else, so the parser keeps the yaml code block — the
/// lossless fallback. Pinned here: every accepted form, every refused one, and
/// what the parser emits for each.
final class FrontMatterTests: XCTestCase {

    private func properties(_ yaml: String) -> [String]? {
        FrontMatter.properties(fromYAML: yaml)?.map { "\($0.key)=\($0.value)" }
    }

    private func parse(_ markdown: String) -> [MarkdownBlock] {
        MarkdownBlockParser(theme: MarkdownTheme.cached(for: .light)).parse(markdown)
    }

    // MARK: - Accepted subset

    func testScalarsKeysWithSpacesAndObsidianSamples() {
        XCTAssertEqual(properties("""
        title: Weekly review
        created: 2026-11-02
        source: "https://example.com/article"
        Due date: tomorrow
        cssclasses:
        """), ["title=Weekly review", "created=2026-11-02", "source=https://example.com/article",
               "Due date=tomorrow", "cssclasses="])
    }

    func testBlockSequencesIndentedOrAtColumnZero() {
        XCTAssertEqual(properties("tags:\n  - a\n  - b"), ["tags=a, b"])
        XCTAssertEqual(properties("tags:\n- a\n- b\nnext: x"), ["tags=a, b", "next=x"])
        XCTAssertEqual(properties("tags:\n    - \"quoted, item\"\n    - 'it''s'"), ["tags=quoted, item\u{2028}it's"])
        XCTAssertEqual(properties("tags:\n  - a\n  # between items\n\n  - b"), ["tags=a, b"])
    }

    func testFlowSequences() {
        XCTAssertEqual(properties("aliases: [Review 45]"), ["aliases=Review 45"])
        XCTAssertEqual(properties("tags: [a, b, \"c, d\"]"), ["tags=a\u{2028}b\u{2028}c, d"])
        XCTAssertEqual(properties("tags: ['x', y ]  "), ["tags=x, y"])
        XCTAssertEqual(properties("tags: []"), ["tags="])
        XCTAssertEqual(properties("tags: [ ]"), ["tags="])
    }

    /// An item that itself contains a comma would read as two items in a
    /// ", " list: then (and only then) every item of THAT list gets its own
    /// line — U+2028 inside the cell's one paragraph.
    func testListWithACommaInAnItemShowsOneItemPerLine() throws {
        XCTAssertEqual(properties("authors:\n  - \"Doe, Jane\"\n  - Smith\ntags: [x, y]\nplaces: ['Paris, FR', Rome]"),
                       ["authors=Doe, Jane\u{2028}Smith", "tags=x, y", "places=Paris, FR\u{2028}Rome"])
        XCTAssertEqual(properties("a:\n  - 1,5\n  - 2"), ["a=1,5\u{2028}2"], "any comma, not only \", \"")
        XCTAssertEqual(properties("note: one, two"), ["note=one, two"], "a scalar is not a list")

        // The table cell keeps it as one paragraph with a line break inside.
        let blocks = parse("---\nauthors: [\"Doe, Jane\", Smith]\n---\n")
        guard case .table(let headers, let rows, let alignments, let style) = blocks.first?.content else {
            return XCTFail("expected a properties table")
        }
        let table = TableTextBuilder.build(headers: headers, rows: rows, alignments: alignments, style: style,
                                           theme: MarkdownTheme.cached(for: .light), fontScale: 1)
        let valueRange = table.layout.cellRanges[0][1]
        XCTAssertEqual((table.string.string as NSString).substring(with: valueRange), "Doe, Jane\u{2028}Smith")
        let wide = TableTextBuilder.height(of: table.string, width: 600)
        let oneLine = TableTextBuilder.build(headers: [], rows: [["authors", "Doe Jane, Smith"]],
                                             alignments: alignments, style: style,
                                             theme: MarkdownTheme.cached(for: .light), fontScale: 1)
        XCTAssertGreaterThan(wide, TableTextBuilder.height(of: oneLine.string, width: 600) + 10, "two lines")
    }

    func testQuotedScalars() {
        XCTAssertEqual(properties(#"a: "say \"hi\" \\ there""#), [#"a=say "hi" \ there"#])
        XCTAssertEqual(properties("a: 'it''s # not a comment'"), ["a=it's # not a comment"])
        XCTAssertEqual(properties(#"k: "x #y""#), ["k=x #y"])
        XCTAssertEqual(properties(#"a: """#), ["a="])
    }

    func testPlainValuesTrimmedAndCommentsStripped() {
        XCTAssertEqual(properties("status:   draft   "), ["status=draft"])
        XCTAssertEqual(properties("k: a#b"), ["k=a#b"])
        XCTAssertEqual(properties("url: https://x.y/#frag"), ["url=https://x.y/#frag"])
        XCTAssertEqual(properties("url: https://x.org/#anchor"), ["url=https://x.org/#anchor"])
        XCTAssertEqual(properties("# leading comment\n\nkey: v\n# trailing"), ["key=v"])
        XCTAssertEqual(properties("key: a | b"), ["key=a | b"])
        XCTAssertEqual(properties("key : spaced"), ["key=spaced"])
    }

    // MARK: - Refused (nil = the yaml code block)

    func testEverythingOutsideTheSubsetIsNil() {
        let refused: [(String, String)] = [
            ("nested mapping", "author:\n  name: Ann"),
            ("block scalar |", "notes: |\n  line one"),
            ("block scalar >", "notes: >\n  folded"),
            ("block scalar |-", "notes: |-\n  x"),
            ("block scalar >+", "notes: >+\n  x"),
            ("multi-line plain scalar", "title: first\n  continued"),
            ("continuation of a list item", "tags:\n  - a\n    more"),
            ("anchor", "a: &anchor value"),
            ("alias", "b: *anchor"),
            ("tag", "c: !!str 5"),
            ("flow mapping", "d: {x: 1}"),
            ("nested flow sequence", "e: [a, [b]]"),
            ("flow mapping in a flow sequence", "e: [a, {b: 1}]"),
            ("unclosed flow sequence", "e: [a, b"),
            ("empty flow item", "e: [a, , b]"),
            ("tab indentation", "tags:\n\t- a"),
            ("sequence item that is a mapping", "people:\n  - name: x"),
            ("nested sequence", "tags:\n  - - a"),
            ("item under a key with a value", "tags: x\n  - a"),
            ("item with no key", "- a"),
            ("mixed list indentation", "tags:\n  - a\n- b"),
            ("unsupported escape", #"a: "tab\t""#),
            ("unterminated quote", "a: \"open"),
            ("text after a closing quote", #"a: "x" y"#),
            ("no colon", "just text"),
            ("colon without a space", "key:value"),
            ("quoted key", "\"key\": v"),
            ("complex key", "? key"),
            ("only comments", "# one\n# two"),
            // A comment in a value would hide text: the code block shows it all.
            ("issue number after ' #'", "issue: Fix #42"),
            ("value starting with #", "tags: #project"),
            ("trailing comment on a plain value", "status: draft # wip"),
            ("comment as an empty value", "tags: # a comment\n  - a"),
            ("comment after a closing quote", #"k: "a" # c"#),
            ("comment after a flow sequence", "tags: [x, y] # c"),
            ("comment inside a flow sequence", "tags: [x # c, y]"),
            ("flow item starting with #", "tags: [#x]"),
            ("comment on a sequence item", "tags:\n  - a # c"),
            ("comment after a quoted sequence item", "tags:\n  - \"a\" # c"),
            ("value that is a sequence entry", "a: - b"),
        ]
        for (label, yaml) in refused {
            XCTAssertNil(FrontMatter.properties(fromYAML: yaml), label)
        }
    }

    // MARK: - Parser

    static let weeklyReview = """
    ---
    title: Weekly review
    aliases: [Review 45]
    tags:
      - work
      - review
    created: 2026-11-02
    status: draft
    source: "https://example.com/article"
    ---
    # Weekly review

    Notes from the week.
    """

    func testParserEmitsAPropertiesTableAndLeavesTheRestAlone() {
        let blocks = parse(Self.weeklyReview)
        guard case .table(let headers, let rows, let alignments, let style) = blocks.first?.content else {
            return XCTFail("expected a properties table, got \(blocks.map(\.id))")
        }
        XCTAssertEqual(style, .properties)
        XCTAssertEqual(headers, [])
        XCTAssertEqual(alignments, [.leading, .leading])
        XCTAssertEqual(rows, [["title", "Weekly review"], ["aliases", "Review 45"], ["tags", "work, review"],
                              ["created", "2026-11-02"], ["status", "draft"],
                              ["source", "https://example.com/article"]])
        XCTAssertEqual(blocks[0].sourceLine, 0)
        XCTAssertEqual(blocks[0].id, "table-0")

        // What follows is exactly what follows a yaml code block (same lines,
        // same ids): replace the front matter by one and compare.
        let nested = Self.weeklyReview.replacingOccurrences(of: "status: draft", with: "status:\n  x: y")
        let fallback = parse(nested)
        guard case .codeBlock(_, "yaml") = fallback.first?.content else {
            return XCTFail("nested map front matter must stay a yaml code block")
        }
        XCTAssertEqual(fallback[0].sourceLine, 0)
        XCTAssertEqual(blocks.count, fallback.count)
        XCTAssertEqual(blocks.dropFirst().map(\.id), fallback.dropFirst().map(\.id))
        XCTAssertEqual(blocks.dropFirst().map(\.sourceLine), fallback.dropFirst().map(\.sourceLine).map { $0 - 1 })
        guard case .heading(1, "Weekly review", 10) = blocks[1].content else {
            return XCTFail("heading after front matter, got \(blocks[1].content)")
        }
        XCTAssertEqual(blocks[1].sourceLine, 10)
    }

    func testOnlyCommentsKeepsTheCodeBlockAndBlankKeepsNothing() {
        let comments = parse("---\n# just a note\n---\nText")
        guard case .codeBlock(let code, "yaml") = comments.first?.content else {
            return XCTFail("comment-only front matter stays a yaml code block")
        }
        XCTAssertEqual(code, "# just a note")
        let blank = parse("---\n\n---\nText")
        guard case .text = blank.first?.content, blank.count == 1 else {
            return XCTFail("blank front matter shows no block, got \(blank.map(\.id))")
        }
    }

    /// `...` closes front matter too, and grid tables after it stay `.grid`.
    func testDotsFenceAndGridTablesUnaffected() {
        let blocks = parse("---\na: 1\n...\n\n| H | I |\n|---|---|\n| x | y |")
        guard case .table(_, _, _, .properties) = blocks.first?.content,
              case .table(["H", "I"], [["x", "y"]], _, .grid) = blocks.last?.content else {
            return XCTFail("got \(blocks.map(\.content))")
        }
        XCTAssertEqual(blocks.last?.sourceLine, 4)
    }

    /// The heading after front matter is still found by section copy / ToC
    /// at its own source line (the table adds no heading).
    func testNoHeadingFromTheProperties() {
        let headings = parse(Self.weeklyReview).compactMap { block -> Int? in
            if case .heading(_, _, let line) = block.content { return line }
            return nil
        }
        XCTAssertEqual(headings, [10])
    }
}
