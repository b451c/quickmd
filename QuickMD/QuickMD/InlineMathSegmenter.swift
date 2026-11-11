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

/// Splits paragraph text into alternating plain-text and inline-math segments
/// — THE inline-math rule: the views, the measurer, search, print and every
/// "does this need the math engine" test (`BlockTextConverter
/// .containsInlineMath`, `needsMath`) ask this, never a second pattern.
/// Pure Foundation — shared by the app and the unit tests.
///
/// GitHub's rule, measured with `gh api markdown -f mode=gfm` (2026-11-11):
/// - an opening `$` (or `$$`) stands at the start or after a space, tab,
///   line break or `(` — `x$a$`, `1$a$`, `é$a$`, `-$a$`, `"$a$"` are text;
/// - it is not followed by white space, and the closing one not preceded by
///   it (`$ a$`, `$a $` are text);
/// - the closing `$` is the NEXT unescaped `$` (a `$$` opener closes with
///   the next `$$`); a closer followed by an ASCII letter, digit or `_`
///   closes nothing and that opener fails — `$HOME/$USER`, `$5-$10`,
///   `$a$1`, `$a$b c$` are text, `$a$é`, `$a$.` are math;
/// - a formula never spans a line break; digits are a formula (`$5$`);
/// - `$$…$$` inside text is an INLINE formula like `$…$` (GitHub:
///   `text <math-renderer class="js-inline-math">$$x$$</math-renderer> more`);
///   a quote paragraph made only of `$$…$$` is display math, decided before
///   this (`MarkdownRenderer.quotedBodyLines`), and so is a top-level `$$`
///   line (the parser).
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
        var offset = 0
        return delimited(plain, escaped: escaped, softBreaks: softBreaks).map { segment, width in
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
        delimited(text, escaped: escaped, softBreaks: false).map(\.segment)
    }

    /// `split` with each formula's delimiter width (1 for `$`, 2 for `$$`).
    private static func delimited(_ text: String, escaped: Set<Int>,
                                  softBreaks: Bool) -> [(segment: Segment, width: Int)] {
        let chars = Array(text)
        let count = chars.count
        func isDollar(_ k: Int) -> Bool { k < count && chars[k] == "$" && !escaped.contains(k) }
        /// GitHub: only the start, white space or `(` may precede an opener.
        func mayOpen(_ k: Int) -> Bool {
            guard k > 0 else { return true }
            let previous = chars[k - 1]
            return previous == " " || previous == "\t" || previous == "\n" || previous == "("
        }
        /// GitHub: a closer followed by an ASCII letter, digit or `_` closes nothing.
        func mayClose(after k: Int) -> Bool {
            guard k < count else { return true }
            let next = chars[k]
            return !(next.isASCII && (next.isLetter || next.isNumber || next == "_"))
        }

        var result: [(segment: Segment, width: Int)] = []
        var textStart = 0
        var k = 0
        while k < count {
            guard isDollar(k), mayOpen(k) else { k += 1; continue }
            let width = isDollar(k + 1) ? 2 : 1
            let contentStart = k + width
            // The next delimiter of the same width; a line break ends the search.
            var close = contentStart
            while close < count, softBreaks || chars[close] != "\n",
                  !(isDollar(close) && (width == 1 || isDollar(close + 1))) {
                close += 1
            }
            let closes = close < count && (softBreaks || chars[close] != "\n")
            let content = closes ? chars[contentStart..<close] : []
            guard closes, let first = content.first, let last = content.last,
                  !first.isWhitespace, !last.isWhitespace, mayClose(after: close + width) else {
                k += 1
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
