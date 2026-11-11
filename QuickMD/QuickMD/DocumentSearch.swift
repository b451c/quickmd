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
///
/// `focusedText`: the part of the FOCUSED match inside `ranges` is drawn in
/// `color` (a temporary foreground, removed on the next call). A front-matter
/// key is secondary-colour text, which on the orange focus read poorly; the
/// properties table passes its key cells and the theme's text colour, so a
/// focused key reads like a focused value.
func applyNSSearchHighlight(in textView: NSTextView, term: String, focusedOccurrence: Int?,
                            focusedText: (color: NSColor, ranges: [NSRange])? = nil) {
    guard let layoutManager = textView.layoutManager,
          let storage = textView.textStorage else { return }
    let fullRange = NSRange(location: 0, length: storage.length)
    layoutManager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: fullRange)
    // Unconditionally: a reused view may have shown a properties table before.
    layoutManager.removeTemporaryAttribute(.foregroundColor, forCharacterRange: fullRange)

    let yellow = NSColor.systemYellow.withAlphaComponent(0.55)
    let orange = NSColor.systemOrange

    for (occurrenceIndex, found) in searchMatchRanges(in: storage.string, term: term).enumerated() {
        let safeRange = NSIntersectionRange(found, fullRange)
        if safeRange.length > 0 {
            let focused = focusedOccurrence == occurrenceIndex
            layoutManager.addTemporaryAttribute(.backgroundColor, value: focused ? orange : yellow,
                                                forCharacterRange: safeRange)
            if focused, let focusedText {
                for range in focusedText.ranges {
                    let part = NSIntersectionRange(safeRange, range)
                    guard part.length > 0 else { continue }
                    layoutManager.addTemporaryAttribute(.foregroundColor, value: focusedText.color,
                                                        forCharacterRange: part)
                }
            }
        }
    }
}

extension NSTextView {
    /// Where the `occurrence`-th match of `term` is in this view's text (view
    /// coordinates) — the matcher its highlight draws with, so the index is
    /// the block's focused occurrence. Nil past the last match.
    func searchMatchRect(term: String, occurrence: Int) -> NSRect? {
        guard let layoutManager, let textContainer, let storage = textStorage else { return nil }
        let ranges = searchMatchRanges(in: storage.string, term: term)
        guard occurrence >= 0, occurrence < ranges.count else { return nil }
        let range = NSIntersectionRange(ranges[occurrence], NSRange(location: 0, length: storage.length))
        guard range.length > 0 else { return nil }
        let glyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        layoutManager.ensureLayout(forGlyphRange: glyphs)
        let rect = layoutManager.boundingRect(forGlyphRange: glyphs, in: textContainer)
        return rect.offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
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

    // MARK: Focus after a (re-)run

    /// Why a search runs. Decides where the focused match lands and whether
    /// the document scrolls to it.
    enum Trigger: Equatable {
        /// The reader typed: focus the first match and scroll to it.
        case termChanged
        /// A new parse landed with the find bar open (reload, ⌘R, zoom, theme,
        /// fonts): the same term over new blocks. The focus stays where the
        /// reader left it and the document does NOT move — a reload must not
        /// jump the reader.
        case reparsed
    }

    /// The match index focused when a run's results land. `previous` is the
    /// index focused at that moment (⌘G may have moved it while the run was
    /// in flight); a re-parse keeps it when it still exists and clamps it to
    /// the last match otherwise.
    static func focusedIndex(after trigger: Trigger, previous: Int, matchCount: Int) -> Int {
        guard matchCount > 0 else { return 0 }
        switch trigger {
        case .termChanged: return 0
        case .reparsed: return min(max(previous, 0), matchCount - 1)
        }
    }

    /// Whether landing results scroll the document to the focused match.
    static func scrollsToFocus(after trigger: Trigger, matchCount: Int) -> Bool {
        trigger == .termChanged && matchCount > 0
    }

    /// What a ⌘G / ⇧⌘G step that moved the focus from `oldBlockId` to
    /// `newBlockId` scrolls: the new block into view, or — the same block —
    /// the new match within it (which moves only a block taller than the
    /// window). Nil without a focus.
    enum StepScroll: Equatable {
        case toBlock
        case withinBlock
    }

    static func stepScroll(from oldBlockId: String?, to newBlockId: String?) -> StepScroll? {
        guard let newBlockId else { return nil }
        return newBlockId == oldBlockId ? .withinBlock : .toBlock
    }

    /// The focused block and the occurrence within it that the block's
    /// highlight paints orange: match `index` is the k-th entry of its block
    /// in `matchBlockIds` (one entry per occurrence, reading order). Nil when
    /// `index` is out of range.
    static func focus(in matchBlockIds: [String], at index: Int) -> (blockId: String, occurrence: Int)? {
        guard index >= 0, index < matchBlockIds.count else { return nil }
        let blockId = matchBlockIds[index]
        let occurrence = matchBlockIds[..<index].lazy.filter { $0 == blockId }.count
        return (blockId, occurrence)
    }

    /// Every block a `TextBlockView` draws (paragraphs, quote and alert
    /// bodies, headings) and every table is counted on the string its view
    /// SHOWS, with the matcher its highlight uses — so a block's count is its
    /// number of highlights and the focused occurrence indexes them in
    /// reading order (TS-D9 for tables, since 1.14.1 for the text kinds; until
    /// then quotes, alerts and headings were counted on their markdown and an
    /// inline-math paragraph on its `$…$` source, so a term in markup, a URL
    /// or a formula was counted but never drawn and ⌘G drifted).
    ///
    /// `converted` and `tables` are the measurer's strings for THESE blocks
    /// (`MeasuredBlocks` of the same parse — the views install exactly those);
    /// a missing entry falls back to `displayedString`'s own construction,
    /// which yields the same characters. A table's `TableText` is only used
    /// when it was built from this block for this look (the rule
    /// `TableTextRepresentable` applies — pass the theme the view renders
    /// with). Rendered characters do not depend on the theme or the scale, so
    /// the defaults are exact for callers without a view (tests);
    /// `MarkdownView` passes its own so the measured strings are reused.
    ///
    /// Off-main safe: the renderer and `BlockTextConverter` are what the
    /// background measurer runs, and the math engine is never touched
    /// (`displayedString`).
    static func computeMatches(in blocks: [MarkdownBlock], term: String,
                               converted: [String: NSAttributedString] = [:],
                               tables: [String: TableText] = [:],
                               theme: MarkdownTheme = .cached(for: .light),
                               fontScale: CGFloat = 1) -> Results {
        guard !term.isEmpty else { return Results(matchBlockIds: []) }

        var matches: [String] = []
        let renderer = MarkdownRenderer(theme: theme, fontScale: fontScale)

        for block in blocks {
            // Text kinds: the string their TextBlockView shows.
            if let shown = displayedString(of: block, converted: converted, renderer: renderer) {
                let count = searchMatchRanges(in: shown, term: term).count
                matches.append(contentsOf: repeatElement(block.id, count: count))
                continue
            }

            // Collect the text segments for this block
            let segments: [String]
            switch block.content {
            case .text, .blockquote, .alert, .heading:
                // Handled above (`displayedString` covers every one of them;
                // an alert without a body has no text view and counts 0).
                segments = []
            case .table(let headers, let rows, let alignments, let style):
                // Counted on the RENDERED string the table view shows (no
                // markup, no link URLs), with the matcher its highlight uses:
                // every counted match is drawn, and the block's focused
                // occurrence is an index into exactly the highlights, in
                // reading order (TS-D9). 1.12 counted the cells' markdown.
                let string: String
                if let measured = tables[block.id],
                   measured.matches(headers: headers, rows: rows, alignments: alignments, style: style,
                                    theme: theme, fontScale: fontScale) {
                    string = measured.string.string
                } else {
                    string = TableTextBuilder.plainString(headers: headers, rows: rows, alignments: alignments,
                                                          style: style, theme: theme, fontScale: fontScale)
                }
                let count = searchMatchRanges(in: string, term: term).count
                matches.append(contentsOf: repeatElement(block.id, count: count))
                continue
            case .codeBlock(let code, _):
                segments = [code]
            case .image(_, let alt, _):
                segments = [alt]
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

    /// The characters a `TextBlockView`-hosted block shows — the string its
    /// `applyNSSearchHighlight` searches — or nil for the other kinds.
    ///
    /// - The measurer's converted string when there is one: it IS the string
    ///   the view installs (`preconverted`, v1.9 D12).
    /// - Otherwise the construction the view itself runs: the renderer's
    ///   output (`renderQuotedBody` for quote and alert bodies, `renderHeader`
    ///   for headings, the parsed paragraph for `.text`) through
    ///   `BlockTextConverter.makeNSAttributedString`. Without inline math the
    ///   converter's string is the AttributedString's characters (it only
    ///   bridges attributes), so those are taken directly — pinned by
    ///   `SearchTests`. A paragraph WITH inline math — and since v1.15 a
    ///   quote or alert body or a heading with a formula (`$…$` or a quote's
    ///   display `$$…$$`) — shows one attachment character (U+FFFC) per
    ///   formula: its LaTeX is neither counted nor highlighted, the text
    ///   around it is. The converter is run with
    ///   `searchMathPlaceholder`, an engine that never touches SwiftMath
    ///   (main-thread only), so the characters come out of the same code.
    ///   Known limit of this fallback only: a formula SwiftMath refuses to
    ///   typeset is drawn as its italic LaTeX, which the placeholder cannot
    ///   know. `MarkdownView` passes the measured strings (built with the real
    ///   engine) and re-runs the search when they land, so the fallback is
    ///   used only before the first layout.
    static func displayedString(of block: MarkdownBlock,
                                converted: [String: NSAttributedString],
                                renderer: MarkdownRenderer) -> String? {
        switch block.content {
        case .text(let attributed):
            if let shown = converted[block.id] { return shown.string }
            let plain = String(attributed.characters)
            guard BlockTextConverter.containsInlineMath(plain) else { return plain }
            return BlockTextConverter.makeNSAttributedString(
                from: attributed, hasInlineMath: true,
                theme: renderer.theme, fontScale: renderer.fontScale,
                math: searchMathPlaceholder).string
        case .blockquote(let content, _):
            if let shown = converted[block.id] { return shown.string }
            return shownWithFormulas(renderer.renderQuotedBody(content)) {
                BlockTextConverter.quotedBody($0, renderer: renderer, math: searchMathPlaceholder)
            }
        case .alert(_, let content):
            // The title is chrome; an empty body has no text view at all.
            guard !content.isEmpty else { return "" }
            if let shown = converted[block.id] { return shown.string }
            return shownWithFormulas(renderer.renderQuotedBody(content)) {
                BlockTextConverter.quotedBody($0, renderer: renderer, math: searchMathPlaceholder)
            }
        case .heading(let level, let title, _):
            // The measurer keeps the title it measured; without it, rendered
            // here exactly as `HeadingBlockView` renders it.
            if let shown = converted[block.id] { return shown.string }
            return shownWithFormulas(renderer.renderHeader(title, level: level)) {
                BlockTextConverter.headingTitle($0, level: level, renderer: renderer, math: searchMathPlaceholder)
            }
        case .table, .codeBlock, .image, .svgImage, .mathBlock, .mermaidDiagram:
            return nil
        }
    }

    /// Quote and alert bodies, headings (v1.15): the rendered characters, or
    /// — when the text has a formula — the converter's string with each
    /// formula as its attachment character, as a math paragraph is counted.
    private static func shownWithFormulas(_ attributed: AttributedString,
                                          convert: (AttributedString) -> NSAttributedString) -> String {
        BlockTextConverter.needsMath(attributed) ? convert(attributed).string : String(attributed.characters)
    }

    /// A math engine for `displayedString` (and `TableTextBuilder.plainString`) only: every formula "typesets" to
    /// an empty 1×1 image, so the converter emits the attachment character a
    /// typeset formula is drawn as. Thread-safe (no SwiftMath, just NSImage).
    static let searchMathPlaceholder = MathRendering(
        inlineImage: { _, _, _ in NSImage(size: NSSize(width: 1, height: 1)) },
        displayHeight: { _, _, _ in 0 })
}
