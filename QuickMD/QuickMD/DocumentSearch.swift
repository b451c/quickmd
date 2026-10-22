import SwiftUI
import AppKit

// MARK: - Parser Output

/// Per-text-block precomputed metadata. Built on the parser's background thread so
/// the main thread doesn't have to do `String(attr.characters)` + regex per render.
struct TextBlockMeta: Sendable {
    let plain: String
    let hasInlineMath: Bool
}

/// Bundle of parser results so the background-detached parse returns one value.
struct ParsedDocument: Sendable {
    let blocks: [MarkdownBlock]
    let textMeta: [String: TextBlockMeta]
}

// MARK: - Shared Search Highlighting

/// The ranges (UTF-16, into `string`) of every occurrence of `term`, in order:
/// case-insensitive (both sides `lowercased()`), otherwise Foundation's default
/// comparison, non-overlapping. The ONE matcher behind the NSTextView-hosted
/// highlights (`applyNSSearchHighlight`) — and behind `DocumentSearch`'s count
/// for tables, which is how a table's count equals what its view highlights.
///
/// The ranges must index the ORIGINAL string (the highlight applies them to
/// the view's storage). Lowercasing can change the UTF-16 length ("İ" U+0130
/// becomes "i̇", two units), and a range found in the lowercased copy then
/// points one unit further per such character — every later highlight of the
/// row (a whole table) drifts and the last one can be clipped. Only then is
/// the original searched with `.caseInsensitive`; ordinary text keeps the
/// lowercased search exactly as before.
func searchMatchRanges(in string: String, term: String) -> [NSRange] {
    guard !term.isEmpty else { return [] }
    let original = string as NSString
    let lowerHaystack = string.lowercased() as NSString
    let lengthPreserved = lowerHaystack.length == original.length
    let haystack = lengthPreserved ? lowerHaystack : original
    let needle = (lengthPreserved ? term.lowercased() : term) as NSString
    let options: NSString.CompareOptions = lengthPreserved ? [] : .caseInsensitive
    guard needle.length > 0, haystack.length >= needle.length else { return [] }

    var ranges: [NSRange] = []
    var location = 0
    while location < haystack.length {
        let searchRange = NSRange(location: location, length: haystack.length - location)
        let found = haystack.range(of: needle as String, options: options, range: searchRange)
        if found.location == NSNotFound { break }
        ranges.append(found)
        location = found.location + max(found.length, 1)
    }
    return ranges
}

/// Search highlighting for NSTextView-hosted blocks (code + text + headings +
/// blockquotes + tables). Applied via the layout manager's temporary
/// attributes — no rebuild of the text storage. Main-thread by convention
/// (called from updateNSView); not @MainActor for older-SDK compatibility (see
/// the BlockHeightCache note in TextBlockView.swift). Lives here, not with the
/// views, so the tests (which do not compile the views) can run it.
func applyNSSearchHighlight(in textView: NSTextView, term: String, focusedOccurrence: Int?) {
    guard let layoutManager = textView.layoutManager,
          let storage = textView.textStorage else { return }
    let fullRange = NSRange(location: 0, length: storage.length)
    layoutManager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: fullRange)

    let yellow = NSColor.systemYellow.withAlphaComponent(0.55)
    let orange = NSColor.systemOrange

    for (occurrenceIndex, found) in searchMatchRanges(in: storage.string, term: term).enumerated() {
        let safeRange = NSIntersectionRange(found, fullRange)
        if safeRange.length > 0 {
            let color = (focusedOccurrence == occurrenceIndex) ? orange : yellow
            layoutManager.addTemporaryAttribute(.backgroundColor, value: color, forCharacterRange: safeRange)
        }
    }
}

// MARK: - Document Search

/// Pure search-match computation over parsed blocks. Free of any UI state so
/// MarkdownView can dispatch it to a background task for large documents
/// (typing in the find bar used to recompute every text block's highlight
/// synchronously on the main thread).
enum DocumentSearch {

    struct Results: Sendable {
        let matchBlockIds: [String]
    }

    /// `tables`, `theme` and `fontScale` locate the string each `.table`
    /// block's view shows: the measurer's `TableText` when it was built from
    /// this block for this look (the rule `TableTextRepresentable` applies —
    /// pass the theme the view renders with), otherwise
    /// `TableTextBuilder.plainString` — the same characters, rendered without
    /// building the table. Rendered characters do not depend on the theme or
    /// the scale, so the defaults are exact for callers without a view (tests);
    /// `MarkdownView` passes its own so the measured strings are reused.
    static func computeMatches(in blocks: [MarkdownBlock], term: String,
                               tables: [String: TableText] = [:],
                               theme: MarkdownTheme = .cached(for: .light),
                               fontScale: CGFloat = 1) -> Results {
        guard !term.isEmpty else { return Results(matchBlockIds: []) }

        var matches: [String] = []

        for block in blocks {
            // Collect the text segments for this block
            let segments: [String]
            switch block.content {
            case .text(let attr):
                segments = [String(attr.characters)]
            case .table(let headers, let rows, let alignments):
                // Counted on the RENDERED string the table view shows (no
                // markup, no link URLs), with the matcher its highlight uses:
                // every counted match is drawn, and the block's focused
                // occurrence is an index into exactly the highlights, in
                // reading order (TS-D9). 1.12 counted the cells' markdown.
                let string: String
                if let measured = tables[block.id],
                   measured.matches(headers: headers, rows: rows, alignments: alignments,
                                    theme: theme, fontScale: fontScale) {
                    string = measured.string.string
                } else {
                    string = TableTextBuilder.plainString(headers: headers, rows: rows, alignments: alignments,
                                                          theme: theme, fontScale: fontScale)
                }
                let count = searchMatchRanges(in: string, term: term).count
                matches.append(contentsOf: repeatElement(block.id, count: count))
                continue
            case .codeBlock(let code, _):
                segments = [code]
            case .blockquote(let content, _):
                segments = [content]
            case .alert(_, let content):
                segments = [content]
            case .image(_, let alt, _):
                segments = [alt]
            case .heading(_, let title, _):
                segments = [title]
            case .mathBlock(let latex):
                segments = [latex]
            case .mermaidDiagram(let source):
                segments = [source]
            case .svgImage:
                // Markup, not prose: a hit inside `<path d="...">` could be
                // neither shown nor highlighted, so SVG blocks are not searched.
                segments = []
            }

            // Count individual occurrences across all segments — with the
            // matcher `applyNSSearchHighlight` draws with, so a text row's
            // count is its number of highlights (a length-changing lowercase,
            // "İ", switches both to `.caseInsensitive` on the original).
            for segment in segments {
                let count = searchMatchRanges(in: segment, term: term).count
                matches.append(contentsOf: repeatElement(block.id, count: count))
            }
        }

        return Results(matchBlockIds: matches)
    }
}
