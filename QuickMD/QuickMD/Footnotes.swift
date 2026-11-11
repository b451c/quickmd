import Foundation

// MARK: - Footnotes (1.15): numbering and multi-line definitions
//
// What GitHub (cmark-gfm) does, every rule checked with `gh api markdown -f
// mode=markdown` on synthetic input (2026-11-11; the cases are the tests in
// `FootnoteTests`). The parser's definition pre-pass drives all of it:
// `FootnoteNumbering` decides the numbers, `FootnoteDefinitionBody` which
// lines belong to a definition; where its continuation lines start is the
// list item's content column the definition sits in (`ListNesting`).

/// The labels of the DEFINED footnotes a text references, in order, the
/// way `MarkdownRenderer.tryParseFootnoteRef` finds them in the text it
/// draws: a backslash escape is no reference, nor is anything in a code
/// span (CommonMark: a backtick run is closed by the next run of the SAME
/// length; an unclosed run is literal), a label runs to the first `]`, and
/// an undefined `[^x` moves on by one character — so `[^x [^a]` references
/// `a`. Emphasis and strikethrough do not hide a reference (GitHub numbers
/// `~~x[^a]~~`).
///
/// It uses the renderer's own scanners, so the two cannot disagree: code
/// spans through `InlineSyntaxScanner.CodeSpanTable`, a `<…>` autolink
/// (`angleAutolink`) is skipped whole (its text is no reference), and the
/// `]` comes from `NextClosingBracket`. Linear in the text: each scanner
/// looks at every byte a bounded number of times.
enum FootnoteReferenceScan {
    static func labels(in text: String, defined: Set<String>) -> [String] {
        guard !defined.isEmpty, text.contains("[^") else { return [] }
        var text = text
        text.makeContiguousUTF8()
        let utf8 = text.utf8
        let codeSpans = InlineSyntaxScanner.CodeSpanTable(text)
        let closing = InlineSyntaxScanner.NextClosingBracket(text)
        var labels: [String] = []
        var index = text.startIndex
        while index < text.endIndex {
            let byte = utf8[index]
            let next = utf8.index(after: index)
            if byte == UInt8(ascii: "\\"), next < text.endIndex, isEscapable(utf8[next]) {
                index = utf8.index(after: next)
                continue
            }
            if byte == UInt8(ascii: "`") {
                index = codeSpans.span(at: text[index...]).end
                continue
            }
            if byte == UInt8(ascii: "<"), let autolink = InlineSyntaxScanner.angleAutolink(atStartOf: text[index...]) {
                index = autolink.end
                continue
            }
            if byte == UInt8(ascii: "["), next < text.endIndex, utf8[next] == UInt8(ascii: "^") {
                let labelStart = utf8.index(after: next)
                if let close = closing.at(orAfter: labelStart), close > labelStart {
                    let label = ReferenceLabel.normalized(text[labelStart..<close])
                    if defined.contains(label) {
                        labels.append(label)
                        index = utf8.index(after: close)
                        continue
                    }
                }
            }
            index = next
        }
        return labels
    }

    /// ASCII punctuation (`MarkdownTheme.escapableChars`).
    private static func isEscapable(_ byte: UInt8) -> Bool {
        byte < 0x80 && MarkdownTheme.escapableChars.contains(Character(Unicode.Scalar(byte)))
    }
}

/// Footnote numbers by the order of each footnote's FIRST reference in the
/// document — not by where or in which order the definitions stand. A
/// definition's own text is read where the definition stands, so a
/// reference inside it counts at that point (`[^a]: see[^c]` above the
/// paragraph that first cites `[^a]` gives c the lower number), also when
/// nothing references that definition or when it is a duplicate that is
/// never shown: GitHub drops those from the list but keeps the footnotes
/// they cite. A footnote that is never referenced gets no number and is
/// not listed.
///
/// The parser hands it the document's kept lines (`keep`) and each
/// definition's text (`note`) in document order, and asks for the order
/// once all definitions are known — a reference may stand above its
/// definition. A paragraph is read as the renderer reads it, its soft
/// breaks joined (`MarkdownRenderer.joinSoftBreaks`): a code span may run
/// over a line break and hide a `[^a]` on the next line.
struct FootnoteNumbering {
    /// Texts that may hold references (`[^`), in document order.
    private var texts: [String] = []
    /// The kept lines since the last break, joined when the run ends.
    private var run: [String] = []
    private var runHasReference = false

    /// A line the block loop gets. Table rows are read alone (cells never
    /// share a code span); a blank line ends the run.
    mutating func keep(_ line: String) {
        if MarkdownRenderer.isBlankLine(line) || line.contains("|") {
            flush()
            add(line)
            return
        }
        run.append(line)
        if line.contains("[^") { runHasReference = true }
    }

    /// A text read on its own (a definition's drawn lines), after the run
    /// before it.
    mutating func note(_ text: String) {
        flush()
        add(text)
    }

    /// The defined labels in the order of their first reference; labels
    /// never referenced are left out.
    mutating func order(defined: Set<String>) -> [String] {
        flush()
        var seen = Set<String>()
        var order: [String] = []
        for text in texts {
            for label in FootnoteReferenceScan.labels(in: text, defined: defined)
            where seen.insert(label).inserted {
                order.append(label)
            }
        }
        return order
    }

    private mutating func flush() {
        if runHasReference {
            for joined in MarkdownRenderer.joinSoftBreaks(run) { add(joined) }
        }
        run.removeAll()
        runHasReference = false
    }

    private mutating func add(_ text: String) {
        if text.contains("[^") { texts.append(text) }
    }
}

// MARK: - Multi-line footnote definitions

/// The lines a footnote definition (`[^n]: text`) goes on with, read as
/// GitHub reads them (cmark-gfm's footnote container). Indents count from
/// the definition's container column — 0 at the top level, the content
/// column of the list item it sits in (`ListNesting`): GitHub counts a
/// definition's continuation indent (4) from there, so `  [^a]: x` at the
/// top level goes on at 4 columns, the same line under `- item` at 6:
/// - a line indented 4+ columns belongs to the definition, also after
///   blank lines (a new paragraph of the footnote). Inside it a fence or
///   an indented code block is code, an ATX heading, a rule or an HTML
///   block closes the paragraph; at a paragraph's start a link definition
///   defines the link (as anywhere);
/// - a LAZY line — not blank, no `>`, no block starts on it
///   (`MarkdownBlockParser.startsNoBlock`) — continues the footnote's OPEN
///   paragraph (also a list item's or a paragraph of link definitions
///   only). So does a `[x]: url` line under the text: a link definition
///   cannot interrupt a paragraph, it is footnote TEXT and defines nothing.
///   Nothing is lazy after an empty `[^n]:`, a code block or a heading;
/// - anything else ends the definition.
///
/// Inside the footnote the text keeps paragraph rules (soft breaks join,
/// hard breaks stay). Code lines are kept literally, one per drawn line;
/// lists and quotes nested in a footnote stay lines of text, not drawn as
/// those blocks.
struct FootnoteDefinitionBody {
    /// The content lines, indentation removed; "" separates paragraphs.
    /// A code line is backslash-escaped, ends in a hard break and keeps
    /// its indentation as no-break spaces (`codeLine`).
    private(set) var lines: [String]
    /// Columns a line needs to be the definition's (not a lazy line).
    private let contentColumn: Int
    /// The last line is paragraph text a lazy line may continue.
    private var paragraphOpen: Bool
    /// The open paragraph holds link definitions only, so far.
    private var onlyDefinitions = false
    /// A fence opened inside the footnote.
    private var fence: MarkdownBlockParser.Fence?

    init(firstLine: String, containerColumn: Int = 0) {
        let empty = MarkdownRenderer.isBlankLine(firstLine)
        lines = empty ? [] : [firstLine]
        paragraphOpen = !empty
        contentColumn = containerColumn + 4
    }

    /// The footnote's text, paragraphs separated by an empty line.
    var content: String { lines.joined(separator: "\n") }

    enum Step: Equatable {
        /// The line is the footnote's.
        case taken
        /// The line defines a link inside the footnote (`text`: the line
        /// without the footnote's indentation, for the link pattern).
        case linkDefinition(String)
        /// The definition ended before this line; the line is the
        /// document's again.
        case ended
    }

    /// Takes the next NON-blank line. `afterBlank`: blank lines stand between
    /// it and the definition's previous line. `isLinkDefinition` records a
    /// link definition and says whether the text was one.
    mutating func take(_ line: String, afterBlank: Bool,
                       isLinkDefinition: (String) -> Bool) -> Step {
        guard MarkdownBlockParser.indentColumns(line) >= contentColumn else {
            guard !afterBlank, fence == nil, paragraphOpen, MarkdownBlockParser.startsNoBlock(line),
                  !MarkdownBlockParser.markerLine(line).hasPrefix(">") else { return .ended }
            if onlyDefinitions, isLinkDefinition(line) { return .linkDefinition(line) }
            lines.append(line)
            onlyDefinitions = false
            return .taken
        }
        let text = MarkdownBlockParser.removingIndentation(line, upTo: contentColumn)
        let marker = MarkdownBlockParser.markerLine(text)
        if let open = fence {
            if afterBlank { lines.append(Self.codeLine("")) }
            if MarkdownBlockParser.closesFence(marker, open) {
                fence = nil
            } else {
                lines.append(Self.codeLine(text))
            }
            return .taken
        }
        let startsBlock = afterBlank || !paragraphOpen
        if afterBlank { separate() }
        let indent = MarkdownBlockParser.indentColumns(text)
        if startsBlock, indent >= 4 {
            // Indented code (a paragraph's own continuation never is).
            separate()
            lines.append(Self.codeLine(MarkdownBlockParser.removingIndentation(text, upTo: 4)))
            paragraphOpen = false
            onlyDefinitions = false
            return .taken
        }
        if indent < 4, let opening = MarkdownBlockParser.fenceOpening(marker) {
            separate()
            fence = opening
            paragraphOpen = false
            onlyDefinitions = false
            return .taken
        }
        if startsBlock || onlyDefinitions, isLinkDefinition(text) {
            paragraphOpen = true
            onlyDefinitions = true
            return .linkDefinition(text)
        }
        lines.append(text)
        let range = NSRange(marker.startIndex..., in: marker)
        let closesParagraph = MarkdownBlockParser.headerRegex.firstMatch(in: marker, range: range) != nil
            || MarkdownRenderer.isThematicBreak(marker) || MarkdownBlockParser.startsHTMLBlock(marker)
        paragraphOpen = !closesParagraph
        onlyDefinitions = false
        return .taken
    }

    /// A paragraph break before what comes next (none at the start).
    private mutating func separate() {
        if let last = lines.last, last != "" { lines.append("") }
    }

    /// A code line as the footnote list draws it: every character literal
    /// (ASCII punctuation backslash-escaped, so no Markdown and no footnote
    /// reference inside), the indentation as no-break spaces (the drawn
    /// lines lose their leading spaces), a hard break after it. An empty
    /// code line is dropped.
    private static func codeLine(_ text: String) -> String {
        guard !MarkdownRenderer.isBlankLine(text) else { return "" }
        var out = ""
        var leading = true
        for character in text {
            if leading, character == " " || character == "\t" {
                out += character == "\t" ? "\u{00A0}\u{00A0}\u{00A0}\u{00A0}" : "\u{00A0}"
                continue
            }
            leading = false
            if MarkdownTheme.escapableChars.contains(character) { out.append("\\") }
            out.append(character)
        }
        while out.last == " " || out.last == "\t" { out.removeLast() }
        return out + "  "
    }

    /// The footnote as the list draws it: each paragraph's lines joined by
    /// the paragraph rules (`MarkdownRenderer.joinSoftBreaks`: a soft break
    /// is a space, a hard break a new line), leading indentation dropped,
    /// one entry per drawn line.
    static func displayLines(of content: String) -> [String] {
        MarkdownRenderer.joinSoftBreaks(content.components(separatedBy: "\n"))
            .filter { !MarkdownRenderer.isBlankLine($0) }
            .map { String($0.drop(while: { $0 == " " || $0 == "\t" })) }
    }
}
