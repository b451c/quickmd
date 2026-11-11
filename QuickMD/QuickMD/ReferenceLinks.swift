import Foundation

// MARK: - Reference labels

/// CommonMark's label matching, in ONE place for every lookup (the
/// definition pre-pass that stores, the renderer, `InlineSyntaxScanner`,
/// `ReferenceLinks`): runs of whitespace — line breaks included, as in a
/// Setext title's `[link⏎text]` — become one space, the ends are trimmed,
/// and the label is Unicode case-folded, not lowercased: GitHub (cmark's
/// `utf8proc_case_fold`) matches `[ẞ]` to `[SS]:` and `[straße]` to
/// `[STRASSE]:` (`gh api markdown`, 2026-11-04). Whitespace is cmark's
/// (space, tab, line feed, line tabulation, form feed, return), so a
/// no-break space stays a character of the label.
enum ReferenceLabel {
    static func normalized<S: StringProtocol>(_ label: S) -> String {
        var collapsed = ""
        var pendingSpace = false
        var ascii = true
        for scalar in label.unicodeScalars {
            switch scalar {
            case " ", "\t", "\n", "\u{0B}", "\u{0C}", "\r":
                pendingSpace = !collapsed.isEmpty
            default:
                if pendingSpace { collapsed.append(" "); pendingSpace = false }
                if !scalar.isASCII { ascii = false }
                collapsed.unicodeScalars.append(scalar)
            }
        }
        // ASCII labels (nearly all): lowercasing IS the fold, no bridging.
        return ascii ? collapsed.lowercased() : collapsed.folding(options: .caseInsensitive, locale: nil)
    }

    /// The `]` closing a label whose text starts at `start` (just past its
    /// `[`): the first UNESCAPED one, so `[x][a\]b]` reads the label `a\]b`.
    /// An unescaped `[` inside makes it no label (CommonMark, GitHub) → nil.
    /// The label is matched as written, backslashes included
    /// (`[a\]b]: url` defines `a\]b`). `InlineSyntaxScanner.matchLabel` is
    /// the same rule over bytes.
    static func closingBracket(in text: Substring, from start: Substring.Index) -> Substring.Index? {
        var index = start
        while index < text.endIndex {
            let character = text[index]
            if character == "\\" {
                let next = text.index(after: index)
                if next < text.endIndex, MarkdownTheme.escapableChars.contains(text[next]) {
                    index = text.index(after: next)
                    continue
                }
            } else if character == "]" {
                return index
            } else if character == "[" {
                return nil
            }
            index = text.index(after: index)
        }
        return nil
    }
}

// MARK: - Reference links inside quotes, alerts and table cells

/// Rewrites reference-style links and images (`[text][id]`, `[text][]`,
/// `[text]`, `![alt][id]`, `![alt][]`, `![alt]`) whose definition exists into
/// their inline form (`[text](<url>)`), for the block kinds whose RAW markdown
/// is stored and rendered later: blockquotes, alerts, table cells and
/// headings.
///
/// Why rewrite instead of handing those renderers the definitions: paragraphs
/// are rendered inside the parser with the document's definitions, but a
/// quote, alert or table keeps its markdown and is rendered again by every
/// consumer — the views, `BlockHeightMeasurer` (whose `.exact` heights must
/// match the view), search, print — each with a definition-less
/// `MarkdownRenderer`. Resolving the references once, where the definitions
/// are known, gives every one of them the same text with no new plumbing, so
/// they cannot disagree.
///
/// The scan mirrors `MarkdownRenderer.renderInlineFormatting` where it
/// decides brackets: escapes, code spans and autolinks are copied as
/// written (they hide brackets), and links are resolved the renderer's way —
/// a bracket stack, `InlineSyntaxScanner.linkTail` at every `]` (inline,
/// full, collapsed, shortcut; an undefined full label is no link), and a
/// link deactivates the `[`s before it (the inner link wins). Images use
/// `InlineSyntaxScanner.image`'s rules. A resolved reference becomes
/// `](<url>)` right at its `]`; the text before it was already rewritten
/// by the same walk (`[![b][img]][link]`). The destination is `<url>` with
/// `\ < > ( )` backslash-escaped, which `InlineSyntaxScanner` reads back as
/// exactly `url` (an escaped paren does not count for pairing either).
enum ReferenceLinks {

    /// What the document defines: link/image definitions (ids lowercased)
    /// and footnote ids in definition order (a reference's number is its
    /// 1-based position, as `tryParseFootnoteRef` numbers it).
    private struct Sources {
        let definitions: [String: String]
        let footnoteIds: [String]
    }

    /// `text` with every resolvable reference inlined. Unchanged when there is
    /// nothing defined or no `[`.
    ///
    /// `quoteBody`: `text` is a blockquote / alert body, which the renderers
    /// read through `MarkdownRenderer.joinSoftBreaks` — a paragraph's lines
    /// are ONE logical line there, so a code span or a link may span lines.
    /// Each soft-break group is scanned as that joined line; a group the scan
    /// leaves alone keeps its original lines, a changed one becomes its joined
    /// line (plus "  " when it ended in a hard break), which the renderer's
    /// join reproduces exactly. Otherwise (a table cell: one line, no soft
    /// breaks) every line is scanned as is.
    ///
    /// Footnote references (`[^note]`) become `[^<marker>N]`
    /// (`MarkdownRenderer.numberedFootnoteMarker` + the number): Markdown has
    /// no inline form for "footnote number N", and a definition-less renderer
    /// draws that form as the same superscript a paragraph's `[^note]` gets.
    static func inlined(_ text: String, definitions: [String: String], footnoteIds: [String] = [],
                        quoteBody: Bool = false) -> String {
        guard !definitions.isEmpty || !footnoteIds.isEmpty, text.contains("[") else { return text }
        let sources = Sources(definitions: definitions, footnoteIds: footnoteIds)
        let lines = text.components(separatedBy: "\n")
        guard quoteBody else {
            return lines.map { inlinedLine($0, sources: sources) }.joined(separator: "\n")
        }
        let groups = MarkdownRenderer.joinSoftBreaksIndexed(lines)
        var out: [String] = []
        for (index, group) in groups.enumerated() {
            let end = index + 1 < groups.count ? groups[index + 1].first : lines.count
            let rewritten = inlinedLine(group.line, sources: sources)
            if rewritten == group.line {
                out.append(contentsOf: lines[group.first..<end])
            } else {
                out.append(rewritten + (MarkdownRenderer.endsWithHardBreak(lines[end - 1]) ? "  " : ""))
            }
        }
        return out.joined(separator: "\n")
    }

    /// A heading's title with every resolvable reference inlined. Headings
    /// are stored as raw Markdown and rendered by definition-less renderers
    /// (the view, measurer, anchors, search, Contents, print), like a quote.
    /// The title is scanned as ONE run, line breaks included, because that
    /// is how `renderHeader` / `headingAnchorText` read a Setext title — a
    /// link across its break (`[Link⏎text][r]`) is one link — and the breaks
    /// stay, since the anchor drops them where the shown title has a space.
    static func inlinedHeading(_ title: String, definitions: [String: String],
                               footnoteIds: [String] = []) -> String {
        guard !definitions.isEmpty || !footnoteIds.isEmpty, title.contains("[") else { return title }
        return inlinedLine(title, sources: Sources(definitions: definitions, footnoteIds: footnoteIds))
    }

    private static func inlinedLine(_ line: String, sources: Sources) -> String {
        let definitions = sources.definitions
        guard line.contains("[") else { return line }
        var text = line
        text.makeContiguousUTF8()
        let utf8 = text.utf8
        let pairs = InlineSyntaxScanner.PairTable(text)
        let codeSpans = InlineSyntaxScanner.CodeSpanTable(text)
        let closingBrackets = InlineSyntaxScanner.NextClosingBracket(text)
        let autolinks = MarkdownRenderer.AutolinkScan()
        var out = ""
        var remaining = text[...]
        /// Which `]` closes a link: the renderer's own rule.
        var brackets = InlineSyntaxScanner.LinkBrackets<Void>()

        while let first = remaining.first {
            // Escapes first, as the renderer: `\[` never opens anything.
            if first == "\\", remaining.utf8.count >= 2 {  // O(1), not a Character count
                let escaped = remaining[remaining.index(after: remaining.startIndex)]
                if MarkdownTheme.escapableChars.contains(escaped) {
                    out += remaining.prefix(2)
                    remaining = remaining.dropFirst(2)
                    continue
                }
            }
            // Code spans and autolinks hide brackets, as in the renderer.
            if first == "`" {
                let end = codeSpans.span(at: remaining).end
                out += remaining[..<end]
                remaining = text[end...]
                continue
            }
            if first == "<", let autolink = InlineSyntaxScanner.angleAutolink(atStartOf: remaining) {
                out += remaining[..<autolink.end]
                remaining = text[autolink.end...]
                continue
            }
            if first == "h" || first == "w",
               let autolink = MarkdownRenderer.bareAutolink(remaining, in: text, scan: autolinks) {
                out += remaining[..<autolink.end]
                remaining = text[autolink.end...]
                continue
            }
            // `tryParseFootnoteRef` runs before links.
            if remaining.hasPrefix("[^"), let (numbered, rest) = footnote(remaining, sources: sources, closing: closingBrackets) {
                out += numbered
                remaining = rest
                continue
            }
            if remaining.hasPrefix("![") {
                if let inline = InlineSyntaxScanner.image(atStartOf: remaining, references: [:], pairs: pairs) {
                    out += remaining[..<inline.end]
                    remaining = remaining[inline.end...]
                    continue
                }
                if let image = InlineSyntaxScanner.image(atStartOf: remaining, references: definitions,
                                                         pairs: pairs) {
                    out += "![\(image.alt)](\(inlineDestination(image.url)))"
                    remaining = remaining[image.end...]
                    continue
                }
                out.append("!")
                remaining = remaining.dropFirst()
                continue
            }
            if first == "[" {
                let labelStart = utf8.index(after: remaining.startIndex)
                brackets.open(labelStart: labelStart, ())
                out.append("[")
                remaining = text[labelStart...]
                continue
            }
            if first == "]" {
                let afterClose = utf8.index(after: remaining.startIndex)
                if let (_, tail) = brackets.close(at: remaining.startIndex, in: text, references: definitions,
                                                  pairs: pairs) {
                    switch tail {
                    case .inline(_, let end):
                        out += text[remaining.startIndex..<end]  // the `](…)` as written
                        remaining = text[end...]
                    case .reference(let url, let end):
                        out += "](\(inlineDestination(url)))"
                        remaining = text[end...]
                    }
                    continue
                }
                out.append("]")
                remaining = text[afterClose...]
                continue
            }
            out.append(first)
            remaining = remaining.dropFirst()
        }
        return out
    }

    /// `tryParseFootnoteRef` at a `[^`: the id runs to the first `]`; a known
    /// id becomes its numbered form, anything else is left to the link scan.
    private static func footnote(_ remaining: Substring, sources: Sources,
                                 closing: InlineSyntaxScanner.NextClosingBracket) -> (String, Substring)? {
        let afterBracket = remaining.dropFirst(2)
        guard let close = closing.at(orAfter: afterBracket.startIndex) else { return nil }
        let id = String(afterBracket[..<close])
        guard !id.isEmpty,
              let index = sources.footnoteIds.firstIndex(of: ReferenceLabel.normalized(id)) else { return nil }
        return ("[^\(MarkdownRenderer.numberedFootnoteMarker)\(index + 1)]", afterBracket[afterBracket.index(after: close)...])
    }

    /// `<url>`, which `InlineSyntaxScanner.linkDestination` reads back as
    /// exactly `url`: the characters that would end the pointy form or pair
    /// up with the link's own parentheses are backslash-escaped (the scanner
    /// unescapes ASCII punctuation), and so is `&` — the definition's
    /// references were decoded when it was read, a second decode must not
    /// turn a literal `&amp;` into `&`. A definition is one line, so no line
    /// break.
    private static func inlineDestination(_ url: String) -> String {
        var escaped = "<"
        for character in url {
            if "\\<>()&".contains(character) { escaped.append("\\") }
            escaped.append(character)
        }
        return escaped + ">"
    }
}
