import Foundation

/// Marks a display formula inside a quote or alert body (v1.15): a paragraph
/// that is nothing but `$$…$$` formulas (`MarkdownRenderer.quotedBodyLines`).
/// The value is the formula's LaTeX as written (line breaks kept); the
/// characters it covers are its source on one line, so a body line is still
/// one line. `BlockTextConverter.makeMathString` draws it as a centred
/// display formula. Not part of the AppKit scope, like
/// `InlineFormulaAttribute`.
enum DisplayMathAttribute: AttributedStringKey {
    typealias Value = String
    static let name = "qmdDisplayMath"
}

/// Marks an inline formula in the renderer's output (v1.15): the run's
/// characters are the formula's SOURCE — its delimiters (`$` or `$$`, a
/// `&#36;` delimiter written as `$`) around the LaTeX exactly as the author
/// wrote it, escapes intact — because `MarkdownRenderer` decides formulas on
/// the source line (`InlineMathSegmenter.formulas(in:)`) and draws each one
/// as an opaque atom, like a code span. `InlineMathSegmenter.pieces(of:)`
/// reads only this attribute; it never looks for `$` in rendered text.
/// The value differs between neighbouring formulas so their runs never
/// merge (`$a$$b$`). Not part of the AppKit scope, so the NSAttributedString
/// a view installs never carries it.
enum InlineFormulaAttribute: AttributedStringKey {
    struct Value: Hashable {
        /// The formula's number in its line.
        let index: Int
        /// Delimiter width: 1 for `$…$`, 2 for an in-text `$$…$$`.
        let width: Int
    }
    static let name = "qmdInlineFormula"
}

/// Decides the inline formulas of a line — THE inline-math rule: the
/// renderer asks it on the SOURCE line before the inline pass
/// (`formulas(in:)`) and draws each formula as an opaque atom tagged
/// `InlineFormulaAttribute`; the views, the measurer, search, print and every
/// "does this need the math engine" test (`BlockTextConverter
/// .containsInlineMath`, `needsMath`) read those atoms (`pieces(of:)`,
/// `hasMath`), never a second pattern. Pure Foundation — shared by the app
/// and the unit tests.
///
/// Why the source (v1.15 seam review): the inline pass used to run first,
/// so emphasis, brackets, strikethrough and autolinks ate a formula's
/// characters before anyone knew it was one — `$f^*$ and $g^*$` came out
/// italic with both formulas broken, `$[c,d](u)$` a link. Precedence:
/// a code span beats a formula (`` `$x$` `` is code; a formula never holds
/// a code span — `$a `x` b$` is text and code, as on GitHub); a formula
/// beats emphasis, strikethrough, links and autolinks — where GitHub, which
/// finds math after its inline pass, breaks `$f^*$ and $g^*$`,
/// `$a*b$ … $c*d$`, `$(a)_n + x_{i}$` and `$[c,d](u)$` (quoted in
/// `MathInTextKindsTests`), QuickMD typesets them.
///
/// The rule (GitHub's output from `gh api markdown -f mode=gfm`, quoted in
/// `MathInTextKindsTests`):
/// - OPENING: any unescaped `$` may open, whatever precedes it — 1.14.4's
///   rule, kept on purpose (the owner's call): `中文$x$中文`, `—$x$`,
///   `=$x$`, `"$x$"`, `[$x$]`, a `$` after a no-break space stay formulas,
///   although GitHub opens only at the start or after white space or `(`.
///   Not followed by white space (`$ a$` is text).
/// - CLOSING (GitHub's): the closer is the NEXT unescaped `$` (`$$` for a
///   `$$` opener), not preceded by white space; if an ASCII letter, digit or
///   `_` follows it, it closes nothing and that opener fails — `$HOME/$USER`,
///   `$5-$10`, `=$A$1`, `US$5 and US$6`, `$x$s` are text — except a formula
///   that can only be LaTeX (`isScientific`: `H$_2$O`, `x$^2$y`,
///   `2$\times$3`), which 1.14.4 typeset and still does. Markup after the
///   closer is no letter (`$x$**b**`, `$x$[l](u)`, `$x$<sup>2</sup>`,
///   `` $x$`c` ``): formulas, as on GitHub and in 1.14.4; an `_` after it
///   closes when it can only end an emphasis opened before the formula
///   (`_$g$_`), never in `$a$_ end`.
/// - A formula never spans a line break, a code span, nor the edge of a
///   link (`[$a](u) b$`, `$q [b$](u)` are text; brackets inside the formula
///   are LaTeX: `$[a,b]$`, `$[c,d](u)$`, `$(a,b]$`). Digits are a formula
///   (`$5$`, as GitHub).
/// - `$$…$$` inside text is an INLINE formula (GitHub's `js-inline-math`);
///   its content holds no `$`, and a run of three or more `$` is text
///   (`$$$x$$$`, `$$a$b$$` as on GitHub). A quote paragraph made only of
///   `$$…$$` and a top-level `$$` line are display math, decided before this
///   (`MarkdownRenderer.quotedBodyLines`, the parser).
/// - An escaped dollar (`\$`) is never a delimiter — QuickMD's long-standing
///   rule; GitHub's API treats `\$x\$` as math, which the app deliberately
///   does not. A dollar written as a character reference (`&#36;`, `&#x24;`)
///   IS one, as on GitHub. Inside a formula nothing is decoded or unescaped:
///   the LaTeX is the source (`$50\%$`, `$a\,b$`, `$a &amp; b$`).
enum InlineMathSegmenter {

    enum Segment: Equatable {
        case text(String)
        case math(String)
    }

    /// A segment as the views draw it: text as is, a formula as the LaTeX to
    /// typeset, with the number of Characters it spans in the rendered text
    /// (`$…$`), and its delimiter (`$`, or `$$` for an in-text `$$…$$`) —
    /// copy writes it back around the LaTeX.
    struct Piece: Equatable {
        let segment: Segment
        let length: Int
        var delimiter: String = "$"
    }

    /// One inline formula of a source line, in UTF-8 offsets from its start.
    struct Formula: Equatable {
        /// The opening delimiter's first byte.
        let start: Int
        /// The LaTeX: `contentStart..<contentEnd`.
        let contentStart: Int
        let contentEnd: Int
        /// Just past the closing delimiter.
        let end: Int
        /// 1 for `$…$`, 2 for `$$…$$`.
        let width: Int
    }

    /// The paragraph's text and formulas, from the renderer's string: the one
    /// split the screen, the measurer, search and print share. A formula is
    /// a run tagged `InlineFormulaAttribute` (the renderer's atom, its
    /// characters the source); everything else is text, whatever `$` it has.
    static func pieces(of attributed: AttributedString) -> [Piece] {
        var result: [Piece] = []
        var text = ""
        var textLength = 0
        var formula: (mark: InlineFormulaAttribute.Value, source: String, length: Int)?
        func flushText() {
            guard textLength > 0 else { return }
            result.append(Piece(segment: .text(text), length: textLength))
            text = ""
            textLength = 0
        }
        func flushFormula() {
            guard let current = formula else { return }
            let latex = String(current.source.dropFirst(current.mark.width).dropLast(current.mark.width))
            result.append(Piece(segment: .math(latex), length: current.length,
                                delimiter: String(repeating: "$", count: current.mark.width)))
            formula = nil
        }
        for run in attributed.runs {
            let characters = attributed.characters[run.range]
            if let mark = run[InlineFormulaAttribute.self] {
                if let current = formula, current.mark == mark {
                    formula = (mark, current.source + String(characters), current.length + characters.count)
                } else {
                    flushFormula()
                    flushText()
                    formula = (mark, String(characters), characters.count)
                }
            } else {
                flushFormula()
                text += String(characters)
                textLength += characters.count
            }
        }
        flushFormula()
        flushText()
        return result
    }

    /// Whether `pieces(of:)` has a formula — the one "needs the math engine"
    /// decision for every kind. Walks runs, not characters.
    static func hasMath(_ attributed: AttributedString) -> Bool {
        attributed.runs.contains { $0[InlineFormulaAttribute.self] != nil }
    }

    /// `formulas(in:)` over plain text, as segments (formulas as their
    /// source LaTeX) — for callers and tests that have only characters.
    static func split(_ text: String) -> [Segment] {
        let found = formulas(in: text)
        guard !found.isEmpty else { return text.isEmpty ? [] : [.text(text)] }
        let utf8 = text.utf8
        func index(_ offset: Int) -> String.Index { utf8.index(utf8.startIndex, offsetBy: offset) }
        var result: [Segment] = []
        var textStart = 0
        for formula in found {
            if textStart < formula.start { result.append(.text(String(text[index(textStart)..<index(formula.start)]))) }
            result.append(.math(String(text[index(formula.contentStart)..<index(formula.contentEnd)])))
            textStart = formula.end
        }
        if textStart < utf8.count { result.append(.text(String(text[index(textStart)...]))) }
        return result
    }

    private static let dollar = UInt8(ascii: "$")
    private static let backslash = UInt8(ascii: "\\")
    private static let backtick = UInt8(ascii: "`")
    private static let ampersand = UInt8(ascii: "&")
    private static let underscore = UInt8(ascii: "_")
    private static let newline = UInt8(ascii: "\n")

    private static func isASCIILetter(_ byte: UInt8) -> Bool {
        (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A)
    }
    private static func isASCIIDigit(_ byte: UInt8) -> Bool { byte >= 0x30 && byte <= 0x39 }
    /// ASCII punctuation — what a backslash escapes (CommonMark).
    private static func isASCIIPunctuation(_ byte: UInt8) -> Bool {
        (byte >= 0x21 && byte <= 0x2F) || (byte >= 0x3A && byte <= 0x40)
            || (byte >= 0x5B && byte <= 0x60) || (byte >= 0x7B && byte <= 0x7E)
    }
    private static func isASCIIWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x20 || (byte >= 0x09 && byte <= 0x0D)
    }

    /// The inline formulas of one SOURCE line, left to right — see the type's
    /// doc for the rule. Linear in the line; a line with neither `$` nor `&`
    /// costs one byte search.
    ///
    /// - `codeSpans`: the inline pass's own table for `text`, so both agree
    ///   on every code span (one is made when nil).
    /// - `escapes`: false where a backslash is a plain character (a
    ///   properties value, `MarkdownRenderer.escapesDisabled`).
    /// - `entities`: false where character references stay as written
    ///   (`entitiesLiteral`): `&#36;` is then no dollar.
    static func formulas(in text: String, codeSpans: InlineSyntaxScanner.CodeSpanTable? = nil,
                         escapes: Bool = true, entities: Bool = true) -> [Formula] {
        let hasDollar = text.utf8.contains(dollar)
        guard hasDollar || (entities && text.utf8.contains(ampersand)) else { return [] }
        let bytes = Array(text.utf8)
        let count = bytes.count

        // 1. Tokens: every dollar that may delimit, with what lies between.
        var dollars: [(start: Int, end: Int)] = []
        /// Closed code spans / line breaks before each dollar (prefix counts).
        var codesBefore: [Int] = []
        var breaksBefore: [Int] = []
        var closingBrackets: [Int] = []
        var firstOpenBracket = Int.max
        var firstUnderscore = Int.max
        var codes = 0
        var breaks = 0
        var table = codeSpans
        var i = 0
        while i < count {
            let byte = bytes[i]
            switch byte {
            case backslash where escapes && i + 1 < count && isASCIIPunctuation(bytes[i + 1]):
                i += 2
                continue
            case backtick:
                if table == nil { table = InlineSyntaxScanner.CodeSpanTable(text) }
                let utf8 = text.utf8
                let span = table!.span(at: text[utf8.index(utf8.startIndex, offsetBy: i)...])
                if span.content != nil { codes += 1 }
                i = utf8.distance(from: utf8.startIndex, to: span.end)
                continue
            case dollar:
                dollars.append((i, i + 1))
                codesBefore.append(codes)
                breaksBefore.append(breaks)
            case ampersand where entities:
                if let end = dollarReference(bytes, at: i) {
                    dollars.append((i, end))
                    codesBefore.append(codes)
                    breaksBefore.append(breaks)
                    i = end
                    continue
                }
            case UInt8(ascii: "["): firstOpenBracket = min(firstOpenBracket, i)
            case UInt8(ascii: "]"): closingBrackets.append(i)
            case underscore: firstUnderscore = min(firstUnderscore, i)
            case newline: breaks += 1
            default: break
            }
            i += 1
        }
        guard dollars.count >= 2 else { return [] }

        func adjacent(_ a: Int, _ b: Int) -> Bool { b < dollars.count && dollars[a].end == dollars[b].start }
        /// A line break between dollar `a` and dollar `b` (a < b).
        func breaksLine(_ a: Int, _ b: Int) -> Bool { breaksBefore[b] != breaksBefore[a] }
        func scalar(at offset: Int) -> Unicode.Scalar? {
            var iterator = bytes[offset...].makeIterator()
            var decoder = UTF8()
            if case .scalarValue(let scalar) = decoder.decode(&iterator) { return scalar }
            return nil
        }
        func scalar(before offset: Int) -> Unicode.Scalar? {
            var lead = offset - 1
            while lead > 0, bytes[lead] & 0xC0 == 0x80 { lead -= 1 }
            return lead >= 0 ? scalar(at: lead) : nil
        }
        /// A scalar that joins the character before it — after a `$` it
        /// would make one Character of delimiter and text.
        func extends(_ scalar: Unicode.Scalar?) -> Bool {
            guard let scalar, !scalar.isASCII else { return false }
            return scalar.properties.isGraphemeExtend || scalar.properties.generalCategory == .spacingMark
                || scalar.value == 0x200D
        }
        /// GitHub: a closer followed by an ASCII letter, digit or `_` closes
        /// nothing. An `_` run that can only end an emphasis opened before
        /// the formula (`_$g$_`) is markup, not a letter.
        func mayClose(after end: Int, opener: Int) -> Bool {
            guard end < count else { return true }
            let next = bytes[end]
            if isASCIILetter(next) || isASCIIDigit(next) { return false }
            guard next == underscore else { return !extends(scalar(at: end)) }
            var after = end
            while after < count, bytes[after] == underscore { after += 1 }
            return firstUnderscore < opener
                && (after == count || isASCIIWhitespace(bytes[after]) || isASCIIPunctuation(bytes[after]))
        }
        /// Scientific notation glued to words (the owner's call, 1.14.4 kept
        /// it): a formula that can only be LaTeX closes even before a letter
        /// or digit — a command (`2$\times$3`, `$\alpha$1`) or ONE sub- or
        /// superscript (`H$_2$O`, `CO$_2$`, `x$^2$y`, `10$^{-3}$m`): `_` or
        /// `^` then one letter or digit, or a `{…}` group, and nothing else.
        /// Shell and Makefile variables do not look like that: `$_FOO$BAR`
        /// (`_` then a word), `$^ $@`, `echo $_ and $x` stay text.
        func isScientific(_ start: Int, _ end: Int) -> Bool {
            let length = end - start
            guard length >= 2 else { return false }
            switch bytes[start] {
            case backslash:
                return isASCIILetter(bytes[start + 1])
            case underscore, UInt8(ascii: "^"):
                if length == 2 { return isASCIILetter(bytes[start + 1]) || isASCIIDigit(bytes[start + 1]) }
                return bytes[start + 1] == UInt8(ascii: "{") && bytes[end - 1] == UInt8(ascii: "}")
                    && !bytes[(start + 2)..<(end - 1)].contains(UInt8(ascii: "}"))
            default:
                return false
            }
        }
        /// The formula would cut a link in two: a `]` of its own that ends a
        /// link text opened before it (`[$a](u) b$`), or a `[` of its own
        /// whose `]` after it starts a link tail (`$q [b$](u)`). Brackets
        /// that pair up inside are LaTeX (`$[c,d](u)$`).
        func crossesLink(opener: Int, _ start: Int, _ end: Int, closerEnd: Int) -> Bool {
            var depth = 0
            var j = start
            while j < end {
                let byte = bytes[j]
                if byte == backslash, escapes, j + 1 < end, isASCIIPunctuation(bytes[j + 1]) { j += 2; continue }
                if byte == UInt8(ascii: "[") {
                    depth += 1
                } else if byte == UInt8(ascii: "]") {
                    if depth > 0 {
                        depth -= 1
                    } else if firstOpenBracket < opener, j + 1 < end,
                              bytes[j + 1] == UInt8(ascii: "(") || bytes[j + 1] == UInt8(ascii: "[") {
                        return true
                    }
                }
                j += 1
            }
            guard depth > 0 else { return false }
            // The first `]` after the formula (binary search).
            var low = 0
            var high = closingBrackets.count
            while low < high {
                let mid = (low + high) / 2
                if closingBrackets[mid] < closerEnd { low = mid + 1 } else { high = mid }
            }
            guard low < closingBrackets.count else { return false }
            let close = closingBrackets[low]
            return close + 1 < count && (bytes[close + 1] == UInt8(ascii: "(") || bytes[close + 1] == UInt8(ascii: "["))
        }

        // 2. Openers and closers, over the dollars.
        var result: [Formula] = []
        var k = 0
        while k < dollars.count {
            // A run of three or more dollars is text (`$$$x$$$`).
            var run = k + 1
            while adjacent(run - 1, run) { run += 1 }
            let width = run - k
            if width >= 3 { k = run; continue }
            let contentStart = dollars[run - 1].end
            // The next delimiter of the same width; a line break ends the search.
            let close = run
            guard close < dollars.count, !breaksLine(k, close) else { k = run; continue }
            if width == 2, !(adjacent(close, close + 1) && !adjacent(close + 1, close + 2)) {
                // `$$…$$` holds no single `$`: `$$a$b$$` is text as a whole
                // (GitHub) — skip to its closing `$$` on this line, if any,
                // so `$b$` inside is no formula either.
                var end = close
                while end + 1 < dollars.count, !adjacent(end, end + 1), !breaksLine(k, end + 1) { end += 1 }
                if adjacent(end, end + 1), !breaksLine(k, end) { k = end + 2; continue }
                // Past the whole opener: the second `$` of a failed `$$` is
                // no opener of its own (`$$a$` is text, as in 1.14.4).
                k = run
                continue
            }
            let contentEnd = dollars[close].start
            let closerEnd = dollars[close + width - 1].end
            guard contentEnd > contentStart,
                  let first = scalar(at: contentStart), !first.properties.isWhitespace, !extends(first),
                  let last = scalar(before: contentEnd), !last.properties.isWhitespace,
                  codesBefore[close] == codesBefore[k],  // a code span inside: the code wins
                  !crossesLink(opener: dollars[k].start, contentStart, contentEnd, closerEnd: closerEnd) else {
                k = run
                continue
            }
            guard mayClose(after: closerEnd, opener: dollars[k].start)
                    || (isScientific(contentStart, contentEnd) && !extends(scalar(at: closerEnd))) else {
                // A `$` glued to a word (`$USER`, `$10`) neither closes nor
                // opens: `$a$b c$`, `PS1="$USER@$HOST"` stay text.
                k = close + width
                continue
            }
            result.append(Formula(start: dollars[k].start, contentStart: contentStart, contentEnd: contentEnd,
                                  end: closerEnd, width: width))
            k = close + width
        }
        return result
    }

    /// `&#36;`, `&#x24;` (any digit count HTMLEntities accepts) at `start`:
    /// the offset past its `;`, or nil.
    private static func dollarReference(_ bytes: [UInt8], at start: Int) -> Int? {
        var i = start + 1
        guard i < bytes.count, bytes[i] == UInt8(ascii: "#") else { return nil }
        i += 1
        guard i < bytes.count else { return nil }
        let hex = bytes[i] == UInt8(ascii: "x") || bytes[i] == UInt8(ascii: "X")
        if hex { i += 1 }
        var value = 0
        var digits = 0
        while i < bytes.count, digits <= (hex ? 6 : 7) {
            let byte = bytes[i]
            let digit: Int
            if isASCIIDigit(byte) {
                digit = Int(byte - 0x30)
            } else if hex, (byte | 0x20) >= 0x61, (byte | 0x20) <= 0x66 {
                digit = Int((byte | 0x20) - 0x61 + 10)
            } else {
                break
            }
            value = value * (hex ? 16 : 10) + digit
            digits += 1
            i += 1
        }
        guard digits > 0, digits <= (hex ? 6 : 7), i < bytes.count, bytes[i] == UInt8(ascii: ";"),
              value == 0x24 else { return nil }
        return i + 1
    }
}
