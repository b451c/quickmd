import Foundation

/// Marks a character the author backslash-escaped (`\$`, `\%`, `\,`): the
/// renderer draws it without the backslash, but inline math is found in the
/// RENDERED text, so `InlineMathSegmenter` needs to know what was escaped:
/// - an escaped `$` never opens or closes a formula (`Price \$5 and \$10`);
/// - inside a formula every escaped character gets its backslash back, so
///   the LaTeX reaches SwiftMath intact (`$50\%$`, `$a\,b$`, `$\{x\}$`).
/// A dollar made by a character reference (`&#36;`) is NOT tagged: GitHub
/// reads that one as a math delimiter. Not part of the AppKit scope, so the
/// NSAttributedString a view installs never carries it.
enum EscapedCharacterAttribute: AttributedStringKey {
    typealias Value = Bool
    static let name = "qmdEscapedCharacter"
}

/// Marks a display formula inside a quote or alert body (v1.15): a paragraph
/// that is nothing but `$$…$$` formulas (`MarkdownRenderer.quotedBodyLines`).
/// The value is the formula's LaTeX as written (line breaks kept); the
/// characters it covers are its source on one line, so a body line is still
/// one line. `BlockTextConverter.makeMathString` draws it as a centred
/// display formula. Not part of the AppKit scope, like
/// `EscapedCharacterAttribute`.
enum DisplayMathAttribute: AttributedStringKey {
    typealias Value = String
    static let name = "qmdDisplayMath"
}

/// Marks a heading formula's source as `renderHeader` rebuilt it (the
/// formula's index): keeps it a run of its own when the heading look gives
/// it and the text after it the same font, so a markup boundary after the
/// closer (`$x$**b**`) still reads as one. Not in the AppKit scope.
enum FormulaSourceAttribute: AttributedStringKey {
    typealias Value = Int
    static let name = "qmdFormulaSource"
}

/// Splits paragraph text into alternating plain-text and inline-math segments
/// — THE inline-math rule: the views, the measurer, search, print and every
/// "does this need the math engine" test (`BlockTextConverter
/// .containsInlineMath`, `needsMath`) ask this, never a second pattern.
/// Pure Foundation — shared by the app and the unit tests.
///
/// The rule (v1.15; GitHub's output from `gh api markdown -f mode=gfm`,
/// quoted in `MathInTextKindsTests`):
/// - OPENING: any unescaped `$` may open, whatever precedes it — 1.14.4's
///   rule, kept on purpose (the owner's call): `中文$x$中文`, `—$x$`,
///   `=$x$`, `"$x$"`, `[$x$]`, a `$` after a no-break space stay formulas,
///   although GitHub opens only at the start or after white space or `(`.
///   Not followed by white space (`$ a$` is text).
/// - CLOSING (GitHub's): the closer is the NEXT unescaped `$` (`$$` for a
///   `$$` opener), not preceded by white space; if an ASCII letter, digit or
///   `_` follows it IN THE SOURCE, it closes nothing and that opener fails —
///   `$HOME/$USER`, `$5-$10`, `=$A$1`, `US$5 and US$6`, `$x$s` are text —
///   except a formula that can only be LaTeX (`isScientific`: `H$_2$O`,
///   `x$^2$y`, `2$\times$3`), which 1.14.4 typeset and still does.
///   "In the source": the rendered text has lost the markup, so a closer
///   followed by a markup boundary (a new attribute run: `$x$**b**`,
///   `$x$[l](u)`, `$x$<sup>2</sup>`, `$x$` then a code span) closes — those
///   are formulas on GitHub and were in 1.14.4.
/// - A formula never spans a line break, nor the edge of a link
///   (`[$a](u) b$` is text). Digits are a formula (`$5$`, as GitHub).
/// - `$$…$$` inside text is an INLINE formula (GitHub's `js-inline-math`);
///   its content holds no `$`, and a run of three or more `$` is text
///   (`$$$x$$$`, `$$a$b$$` as on GitHub). A quote paragraph made only of
///   `$$…$$` and a top-level `$$` line are display math, decided before this
///   (`MarkdownRenderer.quotedBodyLines`, the parser).
/// Escaped dollars (`\$`, `EscapedCharacterAttribute`) and a code span's `$`
/// are never delimiters — QuickMD's long-standing rule; GitHub's API treats
/// `\$x\$` as math, which the app deliberately does not.
enum InlineMathSegmenter {

    /// The Character offsets, in `String(attributed.characters)`, of every
    /// character the author escaped (`EscapedCharacterAttribute`). Empty for
    /// almost every paragraph: only tagged runs are walked.
    static func escapedCharacters(in attributed: AttributedString) -> Set<Int> {
        var offsets: Set<Int> = []
        let characters = attributed.characters
        for run in attributed.runs where run[EscapedCharacterAttribute.self] == true {
            var offset = characters.distance(from: characters.startIndex, to: run.range.lowerBound)
            for _ in characters[run.range] {
                offsets.insert(offset)
                offset += 1
            }
        }
        return offsets
    }

    enum Segment: Equatable {
        case text(String)
        case math(String)
    }

    /// A segment as the views draw it: text as is, a formula as the LaTeX to
    /// typeset (escaped characters with their backslash back, `tex`), with
    /// the number of Characters it spans in the rendered text (`$…$`), and
    /// its delimiter (`$`, or `$$` for an in-text `$$…$$`) — copy writes it
    /// back around the LaTeX.
    struct Piece: Equatable {
        let segment: Segment
        let length: Int
        var delimiter: String = "$"
    }

    /// The paragraph's text and formulas, from the renderer's string: the one
    /// split the screen, the measurer, search and print share.
    ///
    /// `softBreaks`: a "\n" in `attributed` is a soft line break of ONE
    /// paragraph (a Setext title's id text keeps them), which a formula may
    /// span as it spans the space the break reads as everywhere else.
    static func pieces(of attributed: AttributedString, softBreaks: Bool = false) -> [Piece] {
        let plain = String(attributed.characters)
        guard plain.contains("$") else { return plain.isEmpty ? [] : [Piece(segment: .text(plain), length: plain.count)] }
        let escaped = escapedCharacters(in: attributed)
        let (runStarts, linkEdges) = boundaries(in: attributed)
        var offset = 0
        return delimited(plain, escaped: escaped, softBreaks: softBreaks,
                         runStarts: runStarts, linkEdges: linkEdges).map { segment, width in
            switch segment {
            case .text(let text):
                offset += text.count
                return Piece(segment: segment, length: text.count)
            case .math(let source):
                let piece = Piece(segment: .math(tex(source, escaped: escaped, contentStart: offset + width)),
                                  length: source.count + 2 * width,
                                  delimiter: String(repeating: "$", count: width))
                offset += piece.length
                return piece
            }
        }
    }

    /// Character offsets where an attribute run starts (markup the rendered
    /// text lost: a closer followed by one is followed by markup in the
    /// source) and where the link changes (a formula never spans one). Runs,
    /// not characters, are walked.
    static func boundaries(in attributed: AttributedString) -> (runStarts: Set<Int>, linkEdges: Set<Int>) {
        let characters = attributed.characters
        var runStarts: Set<Int> = []
        var linkEdges: Set<Int> = []
        var offset = 0
        for run in attributed.runs {
            if offset > 0 { runStarts.insert(offset) }
            offset += characters[run.range].count
        }
        offset = 0
        for (link, range) in attributed.runs[\.link] {
            _ = link
            if offset > 0 { linkEdges.insert(offset) }
            offset += characters[range].count
        }
        return (runStarts, linkEdges)
    }

    /// Whether `pieces(of:)` has a formula — the one "needs the math engine"
    /// decision for every kind.
    static func hasMath(_ attributed: AttributedString) -> Bool {
        guard attributed.characters.contains("$") else { return false }
        return pieces(of: attributed).contains { if case .math = $0.segment { return true } else { return false } }
    }

    /// A formula's LaTeX: `source` (as rendered) with a backslash put back
    /// before every character that was escaped — by offset, never by
    /// character, so a `$` or `%` the author did not escape stays as it is.
    /// `contentStart` is the offset of `source`'s first character.
    static func tex(_ source: String, escaped: Set<Int>, contentStart: Int) -> String {
        guard !escaped.isEmpty else { return source }
        var latex = ""
        for (index, character) in source.enumerated() {
            if escaped.contains(contentStart + index) { latex.append("\\") }
            latex.append(character)
        }
        return latex
    }

    /// `escaped`: Character offsets of escaped characters
    /// (`escapedCharacters(in:)`). An escaped `$` is never a delimiter, so it
    /// stays text or, inside a formula, part of its LaTeX.
    static func split(_ text: String, escaped: Set<Int> = []) -> [Segment] {
        delimited(text, escaped: escaped, softBreaks: false, runStarts: [], linkEdges: []).map(\.segment)
    }

    /// `split` with each formula's delimiter width (1 for `$`, 2 for `$$`).
    /// `runStarts` / `linkEdges`: `boundaries(in:)` (empty for plain text).
    private static func delimited(_ text: String, escaped: Set<Int>, softBreaks: Bool,
                                  runStarts: Set<Int>, linkEdges: Set<Int>) -> [(segment: Segment, width: Int)] {
        let chars = Array(text)
        let count = chars.count
        func isDollar(_ k: Int) -> Bool { k >= 0 && k < count && chars[k] == "$" && !escaped.contains(k) }
        /// GitHub: a closer followed by an ASCII letter, digit or `_` in the
        /// source closes nothing — a markup boundary in between is source.
        func mayClose(before k: Int) -> Bool {
            guard k < count, !runStarts.contains(k) else { return true }
            let next = chars[k]
            return !(next.isASCII && (next.isLetter || next.isNumber || next == "_"))
        }
        func breaksLine(_ k: Int) -> Bool { !softBreaks && chars[k] == "\n" }
        /// Scientific notation glued to words (the owner's call, 1.14.4 kept
        /// it): a formula that can only be LaTeX closes even before a letter
        /// or digit — a command (`2$\times$3`, `$\alpha$1`) or ONE sub- or
        /// superscript (`H$_2$O`, `CO$_2$`, `x$^2$y`, `10$^{-3}$m`): `_` or
        /// `^` then one letter or digit, or a `{…}` group, and nothing else.
        /// Shell and Makefile variables do not look like that: `$_FOO$BAR`
        /// (`_` then a word), `$^ $@`, `echo $_ and $x` stay text.
        func isScientific(_ content: ArraySlice<Character>) -> Bool {
            guard let first = content.first else { return false }
            let rest = content.dropFirst()
            switch first {
            case "\\":
                return rest.first.map { $0.isASCII && $0.isLetter } ?? false
            case "_", "^":
                if rest.count == 1, let only = rest.first { return only.isASCII && (only.isLetter || only.isNumber) }
                return rest.first == "{" && rest.last == "}" && !rest.dropFirst().dropLast().contains("}")
            default:
                return false
            }
        }

        var result: [(segment: Segment, width: Int)] = []
        var textStart = 0
        var k = 0
        while k < count {
            guard isDollar(k) else { k += 1; continue }
            // A run of three or more dollars is text (`$$$x$$$`).
            var run = k
            while isDollar(run) { run += 1 }
            if run - k >= 3 { k = run; continue }
            let width = run - k
            let contentStart = k + width
            // The next delimiter of the same width; a line break ends the search.
            var close = contentStart
            while close < count, !breaksLine(close), !isDollar(close) { close += 1 }
            var closes = close < count && isDollar(close)
            if closes, width == 2, !(isDollar(close + 1) && !isDollar(close + 2)) {
                // `$$…$$` holds no single `$`: `$$a$b$$` is text as a whole
                // (GitHub) — skip to its closing `$$` on this line, if any,
                // so `$b$` inside is no formula either.
                var end = close
                while end < count, !breaksLine(end), !(isDollar(end) && isDollar(end + 1)) { end += 1 }
                if end < count, isDollar(end) { k = end + 2; continue }
                closes = false
            }
            let content = closes ? chars[contentStart..<close] : []
            guard closes, let first = content.first, let last = content.last,
                  !first.isWhitespace, !last.isWhitespace,
                  !linkEdges.contains(where: { $0 > k && $0 <= close + width - 1 }) else {
                // Past the whole opener: the second `$` of a failed `$$` is
                // no opener of its own (`$$a$` is text, as in 1.14.4).
                k = run
                continue
            }
            guard mayClose(before: close + width) || isScientific(content) else {
                // A `$` glued to a word (`$USER`, `$10`) neither closes nor
                // opens: `$a$b c$`, `PS1="$USER@$HOST"` stay text.
                k = close + width
                continue
            }
            if textStart < k { result.append((.text(String(chars[textStart..<k])), 0)) }
            result.append((.math(String(content)), width))
            k = close + width
            textStart = k
        }
        if textStart < count { result.append((.text(String(chars[textStart..<count])), 0)) }
        return result
    }
}
