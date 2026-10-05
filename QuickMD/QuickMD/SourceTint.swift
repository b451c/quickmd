import Foundation

// MARK: - Source tint (v1.12 S-D14a)
//
// Block-level colour for the raw Markdown in the source editor, so headings,
// fences and quotes stand out while scanning. Pure mapping from the REAL
// parser's output (`MarkdownBlockParser`) to character ranges — no Markdown
// grammar of its own: re-detecting structure outside the parser is exactly
// what desynchronised section copy once (constraints "Section copy boundaries
// come from parser sourceLine"). For the same reason there is no inline tint
// (emphasis, links): that would need a second grammar.
//
// No AppKit state, so the file is compiled into BOTH the app and the test
// target. The editor applies the result as temporary layout-manager
// attributes (`SourceEditorController`).
//
// Known cosmetic gap: a document with footnote definitions gets a synthetic
// footnotes block from the parser, anchored to the document's LAST line. If
// that line is the last line of a quote or a fence (no trailing newline), the
// synthetic block takes it as its own start, so the quote / fence ends one
// line early and that last line stays untinted.

enum SourceTint {

    /// What a tinted range is; the editor maps each kind to a theme colour.
    enum Kind: Equatable, Sendable {
        /// ATX or Setext heading.
        case heading
        /// Code, mermaid and svg fences, display math, YAML front matter:
        /// text the renderer shows verbatim (or as a picture of itself).
        case verbatim
        /// Blockquotes and GFM alerts.
        case quote
    }

    struct Span: Equatable, Sendable {
        /// UTF-16 range in the buffer the blocks were parsed from. Ends at the
        /// last tinted line's last character — its newline is not included,
        /// so consecutive spans never touch, let alone overlap.
        let range: NSRange
        let kind: Kind
    }

    /// The ranges to colour for `blocks`, parsed from `text`.
    ///
    /// Extents — an APPROXIMATION, good for colour only: blocks record where
    /// they start (`sourceLine`), not where they end. So a fenced or quoted
    /// block is taken to run from its first line up to the line before the
    /// next block's first line, minus trailing blank lines. Lines the parser
    /// drops without making a block of them (reference-link and footnote
    /// definitions, HTML wrapper-only lines such as `</div>`) right after such
    /// a block are therefore tinted with it. Anything that needs real block
    /// ends (section copy, landing) must not use this.
    ///
    /// A heading tints its own line; a Setext heading also its underline.
    /// That is told apart from the parser's own data, not by matching `===`
    /// / `---`: the parser's Setext title is the trimmed line itself, while
    /// an ATX title is what follows the `#` run, which can never equal the
    /// whole line. (The underline is taken to be the next line; a reference
    /// definition squeezed between the two would be tinted instead.)
    ///
    /// - Parameters:
    ///   - blocks: `MarkdownBlockParser.parse(text)`, with `sourceLine`s
    ///     non-decreasing (the parser guarantees it; out-of-order input is
    ///     still clamped so spans never overlap).
    ///   - lineStarts: `SourceEditSupport.lineStarts(in: text)`.
    ///   - text: the parsed text, read only to recognise blank lines.
    static func spans(for blocks: [MarkdownBlock], lineStarts: [Int], in text: NSString) -> [Span] {
        let length = text.length
        let lineCount = lineStarts.count
        guard lineCount > 0, length > 0 else { return [] }

        /// End of 0-based `line`'s content: before its newline, or the
        /// buffer's end for the last line.
        func contentEnd(_ line: Int) -> Int {
            line + 1 < lineCount ? lineStarts[line + 1] - 1 : length
        }
        func isBlank(_ line: Int) -> Bool {
            let start = lineStarts[line]
            let range = NSRange(location: start, length: max(0, contentEnd(line) - start))
            // The parser's notion of blank: nothing but `.whitespaces`.
            return text.rangeOfCharacter(from: nonWhitespace, options: [], range: range).location == NSNotFound
        }

        var spans: [Span] = []
        // First character a new span may start at — the end of the last one.
        var floor = 0
        for (index, block) in blocks.enumerated() {
            guard let kind = kind(of: block) else { continue }
            let first = block.sourceLine
            guard first >= 0, first < lineCount else { continue }
            // Blocks sharing a line (several images on one) are not a boundary.
            let boundary = blocks[(index + 1)...].first(where: { $0.sourceLine > first })?.sourceLine ?? lineCount
            let limit = min(boundary, lineCount) - 1
            var last: Int
            if case .heading(_, let title, _) = block.content {
                last = first
                if first + 1 <= limit, isSetext(line: first, title: title, in: text, contentEnd: contentEnd(first),
                                                lineStarts: lineStarts) {
                    last = first + 1
                }
            } else {
                last = limit
                while last > first, isBlank(last) { last -= 1 }
            }
            let start = max(lineStarts[first], floor)
            let end = min(contentEnd(last), length)
            guard end > start else { continue }
            spans.append(Span(range: NSRange(location: start, length: end - start), kind: kind))
            floor = end
        }
        return spans
    }

    /// Non-blank characters, by the parser's `.whitespaces` trimming rule.
    private static let nonWhitespace = CharacterSet.whitespaces.inverted

    static func kind(of block: MarkdownBlock) -> Kind? {
        switch block.content {
        case .heading:
            return .heading
        case .codeBlock, .mermaidDiagram, .svgImage, .mathBlock:
            return .verbatim
        case .blockquote, .alert:
            return .quote
        case .text, .table, .image:
            return nil
        }
    }

    /// Whether the heading on `line` is a Setext one: its line, trimmed the
    /// way the parser trims it, IS the parser's title.
    private static func isSetext(line: Int, title: String, in text: NSString, contentEnd: Int,
                                 lineStarts: [Int]) -> Bool {
        let start = lineStarts[line]
        let content = text.substring(with: NSRange(location: start, length: max(0, contentEnd - start)))
        return content.trimmingCharacters(in: .whitespaces) == title
    }
}
