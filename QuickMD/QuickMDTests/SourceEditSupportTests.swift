import XCTest
import SwiftUI

/// Source Edit helpers (v1.12 S-D3, S-D5, S-D10, S-D14b): line <-> UTF-16
/// position mapping, the landing block, the selection carry-over lookup and the
/// indentation edits.
///
/// All texts are LF-only — the editor buffer never holds U+000D (constraint
/// 14), so CRLF is deliberately not a case here. Positions are UTF-16, so
/// every mapping is also checked with emoji (surrogate pairs), combining marks
/// and CJK in front of the position.
final class SourceEditSupportTests: XCTestCase {

    private typealias S = SourceEditSupport

    private func utf16(_ s: String) -> Int { (s as NSString).length }

    /// Applies an edit the way the text view will.
    private func apply(_ edit: S.TextEdit, to text: String) -> String {
        (text as NSString).replacingCharacters(in: edit.range, with: edit.replacement)
    }

    // MARK: - Lines

    func testLineStartEmptyText() {
        XCTAssertEqual(S.lineStart(0, in: ""), 0)
        XCTAssertEqual(S.lineStart(5, in: ""), 0)
        XCTAssertEqual(S.lineStart(-1, in: ""), 0)
        XCTAssertEqual(S.lineRange(0, in: ""), NSRange(location: 0, length: 0))
        XCTAssertEqual(S.line(containing: 0, in: ""), 0)
        XCTAssertEqual(S.lineCount(in: ""), 1)
    }

    func testSingleLineWithoutNewline() {
        let text = "hello"
        XCTAssertEqual(S.lineStart(0, in: text), 0)
        XCTAssertEqual(S.lineStart(3, in: text), 0, "past the end clamps to the last line")
        XCTAssertEqual(S.lineRange(0, in: text), NSRange(location: 0, length: 5))
        XCTAssertEqual(S.line(containing: 5, in: text), 0)
        XCTAssertEqual(S.lineCount(in: text), 1)
    }

    func testTrailingNewlineMakesAnEmptyLastLine() {
        let text = "a\nbc\n"
        XCTAssertEqual(S.lineCount(in: text), 3)
        XCTAssertEqual(S.lineStart(1, in: text), 2)
        XCTAssertEqual(S.lineStart(2, in: text), 5)
        XCTAssertEqual(S.lineStart(9, in: text), 5, "clamped to the empty last line")
        XCTAssertEqual(S.lineRange(1, in: text), NSRange(location: 2, length: 2))
        XCTAssertEqual(S.lineRange(2, in: text), NSRange(location: 5, length: 0))
        XCTAssertEqual(S.line(containing: 1, in: text), 0, "the newline belongs to its line")
        XCTAssertEqual(S.line(containing: 2, in: text), 1, "after a newline = next line")
        XCTAssertEqual(S.line(containing: 5, in: text), 2)
    }

    func testClamping() {
        let text = "one\ntwo\nthree"
        XCTAssertEqual(S.lineStart(-3, in: text), 0)
        XCTAssertEqual(S.lineStart(99, in: text), 8)
        XCTAssertEqual(S.lineRange(99, in: text), NSRange(location: 8, length: 5))
        XCTAssertEqual(S.lineRange(-1, in: text), NSRange(location: 0, length: 3))
        XCTAssertEqual(S.line(containing: -10, in: text), 0)
        XCTAssertEqual(S.line(containing: 1000, in: text), 2)
    }

    func testEmptyLinesInTheMiddle() {
        let text = "a\n\n\nb"
        XCTAssertEqual(S.lineCount(in: text), 4)
        XCTAssertEqual(S.lineRange(1, in: text), NSRange(location: 2, length: 0))
        XCTAssertEqual(S.lineRange(2, in: text), NSRange(location: 3, length: 0))
        XCTAssertEqual(S.lineStart(3, in: text), 4)
        XCTAssertEqual(S.line(containing: 3, in: text), 2)
    }

    func testUTF16OffsetsAfterEmojiCombiningMarksAndCJK() {
        // 👍🏽 = 4 UTF-16 units (two surrogate pairs), "é" written e + U+0301 = 2,
        // CJK = 1 each. One Swift Character each — a Character count would be wrong.
        let first = "👍🏽 e\u{0301}"
        let second = "日本語 🎉x"
        let text = first + "\n" + second + "\nend"
        XCTAssertEqual(S.lineStart(1, in: text), utf16(first) + 1)
        XCTAssertEqual(S.lineStart(2, in: text), utf16(first) + 1 + utf16(second) + 1)
        XCTAssertEqual(S.lineRange(1, in: text),
                       NSRange(location: utf16(first) + 1, length: utf16(second)))
        // Offset of "x", directly after a surrogate pair.
        let x = (text as NSString).range(of: "x").location
        XCTAssertEqual(S.line(containing: x, in: text), 1)
        // An offset INSIDE a surrogate pair still maps to that pair's line.
        let party = (text as NSString).range(of: "🎉").location
        XCTAssertEqual(S.line(containing: party + 1, in: text), 1)
        XCTAssertEqual(S.line(containing: utf16(first), in: text), 0)
        XCTAssertEqual(S.line(containing: utf16(first) + 1, in: text), 1)
    }

    func testOnlyLineFeedSeparatesLines() {
        // U+2028 / U+0085 are line breaks to NSString.lineRange but not to the
        // parser, whose sourceLine counts "\n" only.
        let text = "a\u{2028}b\u{0085}c\nd"
        XCTAssertEqual(S.lineCount(in: text), 2)
        XCTAssertEqual(S.lineStart(1, in: text), 6)
    }

    func testLongLinesCrossChunkBoundaries() {
        // Lines longer than the internal 4096-unit chunk, with emoji on the seams.
        let long = String(repeating: "ab😀", count: 3000)  // 12 000 units
        let text = long + "\n" + long + "\n" + long
        let length = utf16(long)
        XCTAssertEqual(S.lineStart(1, in: text), length + 1)
        XCTAssertEqual(S.lineStart(2, in: text), 2 * (length + 1))
        XCTAssertEqual(S.line(containing: 2 * length + 1, in: text), 1)
        XCTAssertEqual(S.line(containing: 2 * length + 2, in: text), 2)
        XCTAssertEqual(S.lineRange(1, in: text), NSRange(location: length + 1, length: length))
        // Return at the end of a long line scans backwards across chunks.
        let edit = S.newlineEdit(in: "    " + long, selection: NSRange(location: 4 + length, length: 0))
        XCTAssertEqual(edit.replacement, "\n    ")
        // Indenting lines longer than a chunk, selection from mid line 0 to mid line 2.
        let indent = S.indentEdit(in: text, selection: NSRange(location: 5, length: 2 * length), unit: "\t")
        XCTAssertEqual(indent.map { apply($0, to: text) }, "\t" + long + "\n\t" + long + "\n\t" + long)
        XCTAssertEqual(indent?.selection, NSRange(location: 6, length: 2 * length + 2))
    }

    // MARK: Large documents
    //
    // These catch QUADRATIC behaviour — which on 200k lines takes minutes, not
    // seconds — not millisecond regressions: the bound is deliberately loose
    // (Debug build, shared CI runner). Measured locally in Debug: well under
    // half a second per test. The text is an NSMutableString, like the text
    // storage the editor passes in.

    private static let largeLine = "Some *Markdown* line with ünïcödé and 😀 in it."
    private static let quadraticGuard: TimeInterval = 10

    private func largeDocument() -> NSMutableString {
        NSMutableString(string: Array(repeating: Self.largeLine, count: 200_000).joined(separator: "\n"))
    }

    func testLargeDocumentLookupsAreLinear() {
        let text = largeDocument()
        let lineLength = utf16(Self.largeLine)
        XCTAssertGreaterThan(text.length, 9_000_000)
        let started = Date()
        let lastStart = S.lineStart(199_999, in: text)
        let lineNumber = S.line(containing: text.length - 1, in: text)
        let range = S.lineRange(150_000, in: text)
        let starts = S.lineStarts(in: text)
        let found = S.sourceRange(ofSelection: "ünïcödé", in: text, lines: 199_990..<200_000)
        let unit = S.indentUnit(for: text)
        let newline = S.newlineEdit(in: text, selection: NSRange(location: text.length, length: 0))
        let elapsed = Date().timeIntervalSince(started)
        print("SourceEditSupport large lookups: \(elapsed) s")

        XCTAssertEqual(lastStart, text.length - lineLength)
        XCTAssertEqual(lineNumber, 199_999)
        XCTAssertEqual(range.length, lineLength)
        XCTAssertEqual(starts.count, 200_000)
        XCTAssertEqual(starts[150_000], range.location)
        XCTAssertEqual(starts.last, lastStart)
        XCTAssertEqual(found?.location, starts[199_990] + (Self.largeLine as NSString).range(of: "ünïcödé").location)
        XCTAssertEqual(unit, "    ")
        XCTAssertEqual(newline.replacement, "\n")
        XCTAssertLessThan(elapsed, Self.quadraticGuard, "lookups on 200k lines took \(elapsed) s")
    }

    func testLargeDocumentSelectAllIndentAndOutdent() {
        let text = largeDocument()
        let original = text.copy() as! NSString
        let all = NSRange(location: 0, length: text.length)
        let started = Date()
        guard let indent = S.indentEdit(in: text, selection: all, unit: "\t") else { return XCTFail() }
        text.replaceCharacters(in: indent.range, with: indent.replacement)
        guard let outdent = S.outdentEdit(in: text, selection: indent.selection, unit: "\t") else { return XCTFail() }
        text.replaceCharacters(in: outdent.range, with: outdent.replacement)
        let elapsed = Date().timeIntervalSince(started)
        print("SourceEditSupport large indent + outdent: \(elapsed) s")

        XCTAssertEqual(indent.range, all)
        XCTAssertEqual(indent.selection, NSRange(location: 0, length: all.length + 200_000))
        XCTAssertEqual(text as NSString, original, "indent then outdent restores the text")
        XCTAssertEqual(outdent.selection, all)
        XCTAssertLessThan(elapsed, Self.quadraticGuard, "indent + outdent of 200k lines took \(elapsed) s")
    }

    // MARK: - Batch line starts and the NSString core

    func testLineStartsMatchesLineStart() {
        for text in ["", "x", "a\n", "a\nbc\n\nd", "😀\n日本\ne\u{0301}\n"] {
            let starts = S.lineStarts(in: text)
            XCTAssertEqual(starts.count, S.lineCount(in: text), text.debugDescription)
            for (line, start) in starts.enumerated() {
                XCTAssertEqual(start, S.lineStart(line, in: text), "\(text.debugDescription) line \(line)")
            }
        }
        XCTAssertEqual(S.lineStarts(in: ""), [0])
        XCTAssertEqual(S.lineStarts(in: "a\nbc\n"), [0, 2, 5])
    }

    func testMutableStringCoreAgreesWithStringOverloads() {
        let string = "  a\n\tb 😀\n    c"
        let mutable = NSMutableString(string: string)
        XCTAssertEqual(S.lineStart(2, in: mutable), S.lineStart(2, in: string))
        XCTAssertEqual(S.indentUnit(for: mutable), S.indentUnit(for: string))
        let all = NSRange(location: 0, length: mutable.length)
        XCTAssertEqual(S.indentEdit(in: mutable, selection: all, unit: "  "),
                       S.indentEdit(in: string, selection: all, unit: "  "))
        XCTAssertEqual(S.outdentEdit(in: mutable, selection: all, unit: "  "),
                       S.outdentEdit(in: string, selection: all, unit: "  "))
        XCTAssertEqual(S.newlineEdit(in: mutable, selection: NSRange(location: 5, length: 0)),
                       S.newlineEdit(in: string, selection: NSRange(location: 5, length: 0)))
    }

    // MARK: - Landing block

    private func blocks(_ lines: [Int]) -> [MarkdownBlock] {
        lines.enumerated().map { MarkdownBlock.text(index: $0.offset, AttributedString("b"), sourceLine: $0.element) }
    }

    func testBlockIndexEmpty() {
        XCTAssertNil(S.blockIndex(containingLine: 0, in: []))
        XCTAssertNil(S.blockIndex(containingLine: 7, in: []))
    }

    func testBlockIndexBasic() {
        let list = blocks([0, 2, 5, 9])
        XCTAssertEqual(S.blockIndex(containingLine: 0, in: list), 0)
        XCTAssertEqual(S.blockIndex(containingLine: 1, in: list), 0, "line inside block 0")
        XCTAssertEqual(S.blockIndex(containingLine: 2, in: list), 1)
        XCTAssertEqual(S.blockIndex(containingLine: 8, in: list), 2)
        XCTAssertEqual(S.blockIndex(containingLine: 9, in: list), 3)
        XCTAssertEqual(S.blockIndex(containingLine: 500, in: list), 3, "after the last block")
    }

    func testBlockIndexBeforeFirstBlock() {
        // Front matter / blank lines above the first block.
        let list = blocks([4, 6])
        XCTAssertEqual(S.blockIndex(containingLine: 0, in: list), 0)
        XCTAssertEqual(S.blockIndex(containingLine: 3, in: list), 0)
        XCTAssertEqual(S.blockIndex(containingLine: -1, in: list), 0)
    }

    func testBlockIndexSharedLinesPicksTheFirst() {
        // Three images on line 3, two blocks on the last line.
        let list = blocks([0, 3, 3, 3, 7, 10, 10])
        XCTAssertEqual(S.blockIndex(containingLine: 3, in: list), 1)
        XCTAssertEqual(S.blockIndex(containingLine: 5, in: list), 1)
        XCTAssertEqual(S.blockIndex(containingLine: 10, in: list), 5)
        XCTAssertEqual(S.blockIndex(containingLine: 99, in: list), 5)
        XCTAssertEqual(S.blockIndex(containingLine: 2, in: blocks([2, 2, 2])), 0)
        XCTAssertEqual(S.blockIndex(containingLine: 1, in: blocks([2, 2, 2])), 0)
    }

    func testBlockIndexMatchesLinearRule() {
        let list = blocks([1, 1, 2, 4, 4, 4, 5, 8, 8, 12])
        for line in -1...14 {
            let lastAtOrBefore = list.lastIndex { $0.sourceLine <= line }
            let expected = lastAtOrBefore.map { last in
                list.firstIndex { $0.sourceLine == list[last].sourceLine }!
            } ?? 0
            XCTAssertEqual(S.blockIndex(containingLine: line, in: list), expected, "line \(line)")
        }
    }

    // MARK: - Selection carry-over

    func testSelectionFoundInsideMarkup() {
        let text = "# Title\n\nSome **bold** text with a tpyo here.\nNext line"
        let range = S.sourceRange(ofSelection: "tpyo", in: text, lines: 2..<3)
        XCTAssertEqual(range.map { (text as NSString).substring(with: $0) }, "tpyo")
        XCTAssertEqual(S.sourceRange(ofSelection: "bold", in: text, lines: 2..<3),
                       (text as NSString).range(of: "bold"))
    }

    // MARK: - Selection carry-over with context

    private func match(_ selected: String, before: String = "", after: String = "",
                       in text: String, lines: Range<Int> = 0..<1) -> Int? {
        S.sourceRange(ofSelection: selected, before: before, after: after, in: text, lines: lines)?.location
    }

    func testContextPicksTheFirstOrTheSecondOccurrence() {
        let text = "teh cat and teh dog"
        XCTAssertEqual(match("teh", after: " cat and teh dog", in: text), 0)
        XCTAssertEqual(match("teh", before: "teh cat and ", after: " dog", in: text), 12)
    }

    /// `[docs](https://x.io/docs) see docs` renders as "docs see docs": the
    /// URL holds a third occurrence the reader cannot see, so position
    /// counting would pick the wrong one.
    func testContextSeesPastALinkURL() {
        let text = "[docs](https://x.io/docs) see docs"
        XCTAssertEqual(match("docs", after: " see docs", in: text), 1, "the link text")
        XCTAssertEqual(match("docs", before: "docs see ", in: text), 30, "the last word")
    }

    func testContextWithASingleMatch() {
        XCTAssertEqual(match("cat", before: "something else ", after: " entirely", in: "a cat here"), 2)
    }

    func testNoContextFallsBackToTheFirstMatch() {
        XCTAssertEqual(match("ab", in: "ab ab ab"), 0)
        XCTAssertEqual(match("ab", before: "  ", after: "\n", in: "ab ab ab"), 0, "whitespace-only context")
        XCTAssertNil(match("zz", before: "a", in: "ab ab ab"))
    }

    func testContextMatchesAtTheEdgesOfTheRange() {
        let text = "intro\nword middle word\noutro"
        // Line 1 only: its first and last characters are matches too.
        XCTAssertEqual(match("word", after: " middle word", in: text, lines: 1..<2), 6)
        XCTAssertEqual(match("word", before: "word middle ", in: text, lines: 1..<2), 18)
        // Context from outside the range does not pull a match in from there.
        XCTAssertNil(match("intro", after: "\nword", in: text, lines: 1..<2))
    }

    func testContextIgnoresWhitespaceAtTheEdges() {
        // Rendered soft-break joins / trimmed spaces vs. the source's newline.
        let text = "one teh\nteh two"
        XCTAssertEqual(match("teh", before: "one teh ", after: " two", in: text, lines: 0..<2), 8)
        XCTAssertEqual(match("teh", before: "one  ", after: "  teh two", in: text, lines: 0..<2), 4)
    }

    func testSelectionIsTrimmed() {
        let text = "alpha beta\ngamma"
        XCTAssertEqual(S.sourceRange(ofSelection: "  beta\n", in: text, lines: 0..<1),
                       NSRange(location: 6, length: 4))
    }

    func testSelectionNilCases() {
        let text = "alpha beta\ngamma\ndelta"
        XCTAssertNil(S.sourceRange(ofSelection: "", in: text, lines: 0..<3))
        XCTAssertNil(S.sourceRange(ofSelection: " \n\t", in: text, lines: 0..<3))
        XCTAssertNil(S.sourceRange(ofSelection: "omega", in: text, lines: 0..<3))
        XCTAssertNil(S.sourceRange(ofSelection: "gamma", in: text, lines: 0..<1), "outside the line range")
        XCTAssertNil(S.sourceRange(ofSelection: "alpha", in: text, lines: 1..<1), "empty range")
        XCTAssertNil(S.sourceRange(ofSelection: "alpha", in: text, lines: 5..<9), "past the end")
        XCTAssertNil(S.sourceRange(ofSelection: "alpha", in: "", lines: 0..<1))
        // A match that would run past the last line of the range.
        XCTAssertNil(S.sourceRange(ofSelection: "gamma\ndelta", in: text, lines: 1..<2))
        // The trailing newline of the last line is not part of the range.
        XCTAssertNil(S.sourceRange(ofSelection: "x\ny", in: "x\ny", lines: 0..<1))
    }

    func testSelectionFirstOccurrenceWithinRangeOnly() {
        let text = "word one\nword two\nword three"
        XCTAssertEqual(S.sourceRange(ofSelection: "word", in: text, lines: 1..<3),
                       NSRange(location: 9, length: 4), "the occurrence on line 0 is outside")
        XCTAssertEqual(S.sourceRange(ofSelection: "word", in: text, lines: 0..<3),
                       NSRange(location: 0, length: 4))
    }

    func testSelectionSpanningLinesAndClampedUpperBound() {
        let text = "first para\nsecond para\nthird"
        XCTAssertEqual(S.sourceRange(ofSelection: "para\nsecond", in: text, lines: 0..<2),
                       NSRange(location: 6, length: 11))
        XCTAssertEqual(S.sourceRange(ofSelection: "third", in: text, lines: 2..<50),
                       NSRange(location: 23, length: 5))
        XCTAssertEqual(S.sourceRange(ofSelection: "first", in: text, lines: -2..<1),
                       NSRange(location: 0, length: 5))
    }

    func testSelectionIsLiteralAndUTF16() {
        // Precomposed "é" (U+00E9) must NOT match e + U+0301: literal, not canonical.
        let decomposed = "caf" + "e\u{0301}"
        XCTAssertNil(S.sourceRange(ofSelection: "caf\u{00E9}", in: decomposed, lines: 0..<1))
        let text = "😀😀 日本 target\n"
        let range = S.sourceRange(ofSelection: "target", in: text, lines: 0..<1)
        XCTAssertEqual(range, NSRange(location: 8, length: 6))
        XCTAssertEqual(S.sourceRange(ofSelection: "*", in: "a*b", lines: 0..<1),
                       NSRange(location: 1, length: 1), "no regex/glob semantics")
    }

    // MARK: - Indent unit

    func testIndentUnit() {
        XCTAssertEqual(S.indentUnit(for: ""), "    ")
        XCTAssertEqual(S.indentUnit(for: "plain\n  spaces\n"), "    ")
        XCTAssertEqual(S.indentUnit(for: "\tfirst line"), "\t")
        XCTAssertEqual(S.indentUnit(for: "a\n    b\n\tc"), "\t")
        XCTAssertEqual(S.indentUnit(for: "a\tb\n  c\t"), "    ", "a tab not at a line start does not count")
    }

    // MARK: - Return

    func testNewlineKeepsLeadingWhitespace() {
        let text = "  \t- item"
        let edit = S.newlineEdit(in: text, selection: NSRange(location: 9, length: 0))
        XCTAssertEqual(edit.range, NSRange(location: 9, length: 0))
        XCTAssertEqual(edit.replacement, "\n  \t")
        XCTAssertEqual(edit.selection, NSRange(location: 13, length: 0))
        XCTAssertEqual(apply(edit, to: text), "  \t- item\n  \t")
    }

    func testNewlineOnlyWhitespaceBeforeTheCaret() {
        let text = "a\n        code"
        // Caret inside the indentation (column 3 of line 1).
        let edit = S.newlineEdit(in: text, selection: NSRange(location: 5, length: 0))
        XCTAssertEqual(edit.replacement, "\n   ")
        // Caret at column 0: no indentation is carried.
        XCTAssertEqual(S.newlineEdit(in: text, selection: NSRange(location: 2, length: 0)).replacement, "\n")
    }

    func testNewlineWithoutIndentAndEdges() {
        XCTAssertEqual(S.newlineEdit(in: "", selection: NSRange(location: 0, length: 0)).replacement, "\n")
        XCTAssertEqual(S.newlineEdit(in: "abc", selection: NSRange(location: 3, length: 0)).replacement, "\n")
        // Caret on the empty last line after a trailing newline.
        let edit = S.newlineEdit(in: "    x\n", selection: NSRange(location: 6, length: 0))
        XCTAssertEqual(edit.replacement, "\n")
    }

    func testNewlineReplacesSelection() {
        let text = "    keep DROP rest"
        let edit = S.newlineEdit(in: text, selection: NSRange(location: 9, length: 5))
        XCTAssertEqual(apply(edit, to: text), "    keep \n    rest")
        XCTAssertEqual(edit.selection, NSRange(location: 14, length: 0))
    }

    func testNewlineAfterEmoji() {
        let text = "x\n\t😀 y"
        let caret = utf16(text)
        let edit = S.newlineEdit(in: text, selection: NSRange(location: caret, length: 0))
        XCTAssertEqual(edit.replacement, "\n\t")
        XCTAssertEqual(edit.selection.location, caret + 2)
    }

    // MARK: - Tab / Shift-Tab

    func testTabWithCaretInsertsUnit() {
        let text = "ab"
        let edit = S.indentEdit(in: text, selection: NSRange(location: 1, length: 0), unit: "    ")
        XCTAssertEqual(edit.map { apply($0, to: text) }, "a    b")
        XCTAssertEqual(edit?.selection, NSRange(location: 5, length: 0))
    }

    func testTabWithSingleLineSelectionReplacesIt() {
        let text = "one two\nthree"
        let edit = S.indentEdit(in: text, selection: NSRange(location: 4, length: 3), unit: "\t")
        XCTAssertEqual(edit.map { apply($0, to: text) }, "one \t\nthree")
        XCTAssertEqual(edit?.selection, NSRange(location: 5, length: 0))
    }

    func testTabOnEmptyText() {
        let edit = S.indentEdit(in: "", selection: NSRange(location: 0, length: 0), unit: "\t")
        XCTAssertEqual(edit.map { apply($0, to: "") }, "\t")
    }

    func testTabIndentsTouchedLinesSkippingEmptyAndColumnZeroEnd() {
        let text = "a\nb\n\nc\nd"
        // From inside line 0 to column 0 of line 4 ("d"): lines 0–3 touched, 2 is empty.
        let selection = NSRange(location: 1, length: 6)
        let edit = S.indentEdit(in: text, selection: selection, unit: "  ")
        XCTAssertEqual(edit.map { apply($0, to: text) }, "  a\n  b\n\n  c\nd")
        // Same text still selected: "\nb\n\nc\n" moved by the inserted units.
        XCTAssertEqual(edit?.selection, NSRange(location: 3, length: 10))
        XCTAssertEqual(edit.map { (apply($0, to: text) as NSString).substring(with: $0.selection) },
                       "\n  b\n\n  c\n")
    }

    func testTabOnWholeLineSelectedWithItsNewlineIndents() {
        // Triple-click selects a line including its newline: indent, don't replace.
        let text = "one\ntwo\nthree"
        let edit = S.indentEdit(in: text, selection: NSRange(location: 4, length: 4), unit: "\t")
        XCTAssertEqual(edit.map { apply($0, to: text) }, "one\n\ttwo\nthree")
        XCTAssertEqual(edit?.selection, NSRange(location: 4, length: 5),
                       "a selection starting at column 0 takes the new indent in")
    }

    func testTabNilWhenAllTouchedLinesAreEmpty() {
        XCTAssertNil(S.indentEdit(in: "\n\n\n", selection: NSRange(location: 0, length: 2), unit: "\t"))
    }

    func testIndentIsOneEditCoveringTheTouchedLines() {
        let text = "keep\nx\ny\nkeep"
        let edit = S.indentEdit(in: text, selection: NSRange(location: 5, length: 3), unit: "\t")
        XCTAssertEqual(edit?.range, NSRange(location: 5, length: 3))
        XCTAssertEqual(edit?.replacement, "\tx\n\ty")
    }

    func testShiftTabRemovesOneLevel() {
        let text = "\ttab\n      six\n  two\nnone\n"
        let unit = "    "
        let edit = S.outdentEdit(in: text, selection: NSRange(location: 0, length: utf16(text)), unit: unit)
        XCTAssertEqual(edit.map { apply($0, to: text) }, "tab\n  six\ntwo\nnone\n")
    }

    func testShiftTabWithTabUnitRemovesTabOrFourSpaces() {
        let text = "\t\ta\n      b"
        let edit = S.outdentEdit(in: text, selection: NSRange(location: 0, length: utf16(text)), unit: "\t")
        XCTAssertEqual(edit.map { apply($0, to: text) }, "\ta\n  b")
    }

    func testShiftTabCaretOutdentsItsLine() {
        let text = "a\n        bc\nd"
        let edit = S.outdentEdit(in: text, selection: NSRange(location: 11, length: 0), unit: "    ")
        XCTAssertEqual(edit.map { apply($0, to: text) }, "a\n    bc\nd")
        XCTAssertEqual(edit?.selection, NSRange(location: 7, length: 0), "caret stays before \"c\"")
        // Caret inside the removed indentation moves to the line start.
        let inside = S.outdentEdit(in: text, selection: NSRange(location: 4, length: 0), unit: "    ")
        XCTAssertEqual(inside?.selection, NSRange(location: 2, length: 0))
    }

    func testShiftTabNilWithoutLeadingWhitespace() {
        XCTAssertNil(S.outdentEdit(in: "a\nb", selection: NSRange(location: 0, length: 3), unit: "\t"))
        XCTAssertNil(S.outdentEdit(in: "", selection: NSRange(location: 0, length: 0), unit: "    "))
        XCTAssertNil(S.outdentEdit(in: "x\n\n", selection: NSRange(location: 2, length: 0), unit: "    "))
    }

    func testShiftTabSkipsColumnZeroEndLine() {
        let text = "  a\n  b"
        let edit = S.outdentEdit(in: text, selection: NSRange(location: 0, length: 4), unit: "  ")
        XCTAssertEqual(edit.map { apply($0, to: text) }, "a\n  b")
    }

    /// Indent then outdent restores text AND selection, for several shapes.
    func testIndentOutdentRoundTrips() {
        let text = "# Head 😀\n  item one\n\n\tcode é\nlast line"
        let length = utf16(text)
        let cases: [NSRange] = [
            NSRange(location: 0, length: length),                     // everything
            NSRange(location: 3, length: 20),                         // mid-line to mid-line
            NSRange(location: 0, length: S.lineStart(2, in: text)),   // whole lines 0–1
            NSRange(location: S.lineStart(1, in: text) + 2, length: S.lineStart(4, in: text) - S.lineStart(1, in: text)), // ends at column 2
        ]
        for unit in ["    ", "\t"] {
            for selection in cases {
                guard let indent = S.indentEdit(in: text, selection: selection, unit: unit) else {
                    XCTFail("indent \(selection) produced nothing"); continue
                }
                let indented = apply(indent, to: text)
                guard let outdent = S.outdentEdit(in: indented, selection: indent.selection, unit: unit) else {
                    XCTFail("outdent \(selection) produced nothing"); continue
                }
                // A tab-indented line indented with spaces loses its spaces
                // first, so compare against the same text the indent produced.
                XCTAssertEqual(apply(outdent, to: indented), text, "unit \(unit.debugDescription), \(selection)")
                XCTAssertEqual(outdent.selection, selection, "unit \(unit.debugDescription), \(selection)")
            }
        }
    }

    func testCaretTabThenShiftTabRoundTrip() {
        let text = "line\n  x"
        let caret = NSRange(location: 6, length: 0)
        guard let indent = S.indentEdit(in: text, selection: caret, unit: "  ") else { return XCTFail() }
        let indented = apply(indent, to: text)
        XCTAssertEqual(indented, "line\n    x")
        guard let outdent = S.outdentEdit(in: indented, selection: indent.selection, unit: "  ") else { return XCTFail() }
        XCTAssertEqual(apply(outdent, to: indented), text)
        XCTAssertEqual(outdent.selection, NSRange(location: 6, length: 0))
    }
}
