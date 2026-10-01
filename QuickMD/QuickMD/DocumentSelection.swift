import Foundation
import AppKit

// MARK: - Document-wide text selection (v1.11 S1)
//
// The document is a virtualized list of blocks, each hosted in its own table
// cell, and a paragraph's text view only exists while its row is materialized.
// A native NSTextView selection therefore cannot be the source of truth: it
// lives in ONE view, dies with that view on cell reuse, and renders grey in
// every view that is not the first responder. The selection is a pure value
// instead — two (row, offset) points — and the views only draw the part of it
// that falls inside them (`SelectionController` in VirtualBlockList.swift).
//
// This file is compiled into BOTH the app and the test target (no view code,
// no SwiftMath), so everything here is unit-tested directly.

// MARK: - Selection points

/// A position in the document.
///
/// `offset` is a UTF-16 offset into the row's SELECTABLE STRING — exactly the
/// string the row's text view displays (`NSString` indexing, the same unit
/// TextKit uses, so a point maps to a glyph without conversion). For an atomic
/// row (table, image, display math, diagram) the string is a single unit:
/// `0` = before the row, `1` = after it.
struct SelectionPoint: Comparable, Hashable {
    var row: Int
    var offset: Int

    static func < (lhs: SelectionPoint, rhs: SelectionPoint) -> Bool {
        lhs.row != rhs.row ? lhs.row < rhs.row : lhs.offset < rhs.offset
    }
}

/// The document selection: where the gesture started (`anchor`) and where it is
/// now (`focus`). The two are NOT ordered — a drag upwards has the focus before
/// the anchor — because Shift-click extends from the anchor, so which end the
/// user started at has to survive. Use `normalized` for reading.
///
/// Pure value, no AppKit: everything that maps it to pixels lives in the views.
struct DocumentSelection: Equatable {
    var anchor: SelectionPoint
    var focus: SelectionPoint

    init(anchor: SelectionPoint, focus: SelectionPoint) {
        self.anchor = anchor
        self.focus = focus
    }

    /// An empty selection parked at `point` — what a plain click leaves behind,
    /// so a following Shift-click has something to extend from (Preview/Safari).
    init(collapsedAt point: SelectionPoint) {
        self.init(anchor: point, focus: point)
    }

    /// Start and end in document order.
    var normalized: (start: SelectionPoint, end: SelectionPoint) {
        anchor <= focus ? (anchor, focus) : (focus, anchor)
    }

    var isEmpty: Bool { anchor == focus }

    /// First and last row the selection touches (an empty selection touches
    /// nothing). A row in this span can still have an empty covered range — a
    /// selection that ends at offset 0 of a row does not cover any of it.
    var rowSpan: ClosedRange<Int>? {
        guard !isEmpty else { return nil }
        let (start, end) = normalized
        return start.row...end.row
    }

    /// The part of `row` the selection covers, as a range into the row's
    /// selectable string, or nil when it covers nothing of it.
    ///
    /// `rowLength` is the selectable string's UTF-16 length (1 for an atomic
    /// row). Offsets are clamped to it: a selection is built from strings that
    /// can be re-laid out but never change length within one content version,
    /// and clamping keeps a stale offset from producing an out-of-bounds range
    /// for a view to draw.
    func range(inRow row: Int, rowLength: Int) -> NSRange? {
        guard !isEmpty, rowLength > 0 else { return nil }
        let (start, end) = normalized
        guard row >= start.row, row <= end.row else { return nil }
        let lower = row == start.row ? min(max(0, start.offset), rowLength) : 0
        let upper = row == end.row ? min(max(0, end.offset), rowLength) : rowLength
        guard upper > lower else { return nil }
        return NSRange(location: lower, length: upper - lower)
    }

    /// ⌘A: from the start of the first row to the end of the last one.
    ///
    /// `lengths` is asked for the LAST row only — the selection is two points,
    /// so selecting a 10 000-row document does not have to build 10 000 strings.
    /// Nil for an empty document.
    static func selectAll(rowCount: Int, lengths: (Int) -> Int) -> DocumentSelection? {
        guard rowCount > 0 else { return nil }
        let last = rowCount - 1
        return DocumentSelection(anchor: SelectionPoint(row: 0, offset: 0),
                                 focus: SelectionPoint(row: last, offset: max(0, lengths(last))))
    }

    /// The selection during a drag that started at `anchor`.
    ///
    /// When the drag started INSIDE an atomic row the row is selected whole as
    /// soon as the pointer leaves it — in whichever direction — and a drag that
    /// stays inside it selects nothing (there is no per-cell selection; S-D3).
    /// So the anchor's offset is not where the press happened but the edge
    /// that puts the row inside the selection: before it (0) when the focus is
    /// below, after it (1) when the focus is above.
    static func dragging(from anchor: SelectionPoint, anchorIsAtomic: Bool,
                         to focus: SelectionPoint) -> DocumentSelection {
        guard anchorIsAtomic else { return DocumentSelection(anchor: anchor, focus: focus) }
        if focus.row > anchor.row {
            return DocumentSelection(anchor: SelectionPoint(row: anchor.row, offset: 0), focus: focus)
        }
        if focus.row < anchor.row {
            return DocumentSelection(anchor: SelectionPoint(row: anchor.row, offset: 1), focus: focus)
        }
        return DocumentSelection(collapsedAt: SelectionPoint(row: anchor.row, offset: 0))
    }

    /// The selection during a drag that followed a double/triple click.
    ///
    /// `unit` is the word/paragraph the multi-click selected. While the focus
    /// is inside it, the unit stays selected; outside it, the selection runs
    /// from the unit's FAR edge to the focus, so the clicked word never gets
    /// cut in half. (Extending by character rather than by word/paragraph is
    /// the accepted simplification of S-D6.)
    static func extending(unit: (start: SelectionPoint, end: SelectionPoint),
                          to focus: SelectionPoint) -> DocumentSelection {
        if focus < unit.start { return DocumentSelection(anchor: unit.end, focus: focus) }
        if focus > unit.end { return DocumentSelection(anchor: unit.start, focus: focus) }
        return DocumentSelection(anchor: unit.start, focus: unit.end)
    }
}

// MARK: - Autoscroll at the screen edge

/// Drag-autoscroll normally starts when the pointer leaves the document's
/// clip view. That is impossible when the clip view's edge IS the screen's
/// edge (full screen, a zoomed window with the Dock hidden): the pointer
/// stops at the last pixel. So when an edge of the clip view lies on the
/// screen's edge, a thin zone inside it counts as "outside".
enum SelectionAutoscroll {
    /// Depth of the zone inside the clip view, in points.
    static let edgeZone: CGFloat = 6
    /// How close the clip's edge must be to the screen's edge to count as on it.
    static let edgeTolerance: CGFloat = 2

    /// +1 (scroll down) / −1 (scroll up) / nil. Screen coordinates: y grows
    /// upwards, so the clip's BOTTOM edge is `minY`.
    static func screenEdgeDirection(clipOnScreen clip: NSRect, screenFrame screen: NSRect,
                                    pointer: NSPoint) -> CGFloat? {
        if abs(clip.minY - screen.minY) <= edgeTolerance, pointer.y <= clip.minY + edgeZone {
            return 1
        }
        if abs(clip.maxY - screen.maxY) <= edgeTolerance, pointer.y >= clip.maxY - edgeZone {
            return -1
        }
        return nil
    }
}

// MARK: - Drawing under opaque text backgrounds

/// The layout manager of a document text view (`SelfSizingTextView`).
///
/// The view paints the document selection in `drawBackground(in:)`, i.e.
/// BEFORE the layout manager draws the text's own `.backgroundColor` runs — and
/// an inline `code` chip's background is opaque, so a covered chip showed no
/// selection at all. This subclass swaps the selection colour in for the
/// covered part of such a run. Search highlights are layout-manager TEMPORARY
/// attributes and are left alone, so they still draw on top of the selection.
///
/// Drawing only: nothing here touches glyph generation or layout, so a view
/// with this layout manager wraps exactly like the measurer's plain stack
/// (pinned by `DocumentSelectionTests.testSelectionLayoutManagerKeepsLayout`).
final class DocumentSelectionLayoutManager: NSLayoutManager {

    /// The part of the text the document selection covers (set by the view).
    var selectionCoveredRange: NSRange?

    override func fillBackgroundRectArray(_ rectArray: UnsafePointer<NSRect>, count rectCount: Int,
                                          forCharacterRange charRange: NSRange, color: NSColor) {
        super.fillBackgroundRectArray(rectArray, count: rectCount, forCharacterRange: charRange, color: color)
        guard let covered = selectionCoveredRange,
              let container = textContainers.first else { return }
        let overlap = NSIntersectionRange(covered, charRange)
        guard overlap.length > 0 else { return }
        // A temporary background (search highlight) wins over the selection.
        if temporaryAttribute(.backgroundColor, atCharacterIndex: charRange.location,
                              effectiveRange: nil) != nil { return }
        let glyphs = glyphRange(forCharacterRange: overlap, actualCharacterRange: nil)
        guard glyphs.length > 0 else { return }
        let origin = firstTextView?.textContainerOrigin ?? .zero
        let isKey = firstTextView?.window?.isKeyWindow ?? false
        let selection = isKey ? NSColor.selectedTextBackgroundColor
                              : NSColor.unemphasizedSelectedTextBackgroundColor
        // Clip to the run's own rects: the chip keeps its shape, only its
        // colour becomes the selection's.
        guard let context = NSGraphicsContext.current else { return }
        context.saveGraphicsState()
        let clip = NSBezierPath()
        for index in 0..<rectCount { clip.appendRect(rectArray[index]) }
        clip.addClip()
        selection.setFill()
        enumerateEnclosingRects(forGlyphRange: glyphs, withinSelectedGlyphRange: glyphs,
                                in: container) { rect, _ in
            rect.offsetBy(dx: origin.x, dy: origin.y).fill(using: .sourceOver)
        }
        context.restoreGraphicsState()
    }
}

// MARK: - Inline math source

extension NSAttributedString.Key {
    /// The LaTeX source of an inline `$…$` math attachment, set by
    /// `BlockTextConverter` on the attachment character.
    ///
    /// An `NSTextAttachment` is U+FFFC in the string, so without this a copied
    /// paragraph would carry "the integral of" → "\u{FFFC}". The copy builder
    /// writes `$<latex>$` in its place. A custom key draws nothing and changes
    /// no layout, so the measured height of the paragraph is unaffected.
    static let qmdInlineMathSource = NSAttributedString.Key("pl.falami.studio.QuickMD.inlineMathSource")
}

// MARK: - Copy output (S-D8)

/// One row's contribution to a copy, already cut to what the selection covers.
enum SelectionPiece {
    /// Paragraphs, list chunks, quote and alert bodies, headings: the covered
    /// substring of the row's selectable string. Leading/trailing blank lines
    /// are layout (a text chunk starts with the blank lines that separated it
    /// from the previous block), runs of blank lines inside collapse.
    case text(NSAttributedString)
    /// A code block's covered substring — VERBATIM. Blank lines inside code are
    /// content, so none of the paragraph clean-up applies.
    case code(NSAttributedString)
    /// A table, as tab-separated values of the cells' RENDERED text (no `**`).
    /// `headers` is nil for a headerless table (the view shows no header band).
    case table(headers: [String]?, rows: [[String]])
    /// An image or SVG block: its alt text, or nothing when it has none.
    case image(alt: String)
    /// A display-math block: `$$\n<latex>\n$$`.
    case displayMath(latex: String)
    /// A Mermaid diagram: its source in a ```mermaid fence.
    case mermaid(source: String)
}

/// What a copy writes to the pasteboard. `plain == rtf.string` by construction.
struct DocumentCopyOutput {
    let plain: String
    /// Theme colours removed: pasting a dark-theme selection into Mail must not
    /// produce white text on white paper. Fonts, traits, links and paragraph
    /// styles are kept; attachments are not (inline math becomes its source).
    let rtf: NSAttributedString
}

/// Turns covered pieces into clipboard text. Pure: the caller decides what is
/// covered, this decides how it reads once pasted.
enum DocumentCopyBuilder {

    /// Rows are joined with one blank line, like Markdown paragraphs.
    static let rowSeparator = "\n\n"

    static func build(_ pieces: [SelectionPiece]) -> DocumentCopyOutput {
        let result = NSMutableAttributedString()
        for piece in pieces {
            let part = attributed(for: piece)
            guard part.length > 0 else { continue }
            if result.length > 0 { result.append(NSAttributedString(string: rowSeparator)) }
            result.append(part)
        }
        let full = NSRange(location: 0, length: result.length)
        // Colours come from the theme the document is displayed in, not from
        // the content — see `DocumentCopyOutput.rtf`.
        result.removeAttribute(.foregroundColor, range: full)
        result.removeAttribute(.backgroundColor, range: full)
        result.removeAttribute(.qmdInlineMathSource, range: full)
        return DocumentCopyOutput(plain: result.string, rtf: result)
    }

    private static func attributed(for piece: SelectionPiece) -> NSAttributedString {
        switch piece {
        case .text(let text):
            let cleaned = replacingAttachments(in: text)
            trimBlankLines(cleaned)
            collapseBlankLineRuns(cleaned)
            return cleaned
        case .code(let code):
            return replacingAttachments(in: code)
        case .table(let headers, let rows):
            return NSAttributedString(string: tsv(headers: headers, rows: rows))
        case .image(let alt):
            return NSAttributedString(string: alt.trimmingCharacters(in: .whitespacesAndNewlines))
        case .displayMath(let latex):
            return NSAttributedString(string: "$$\n" + latex + "\n$$")
        case .mermaid(let source):
            return NSAttributedString(string: "```mermaid\n" + source + "\n```")
        }
    }

    /// Tab-separated values: one line per row, header first when there is one.
    /// A tab or line break inside a cell would split it, so those become spaces.
    static func tsv(headers: [String]?, rows: [[String]]) -> String {
        let columnCount = max(headers?.count ?? 0, rows.map(\.count).max() ?? 0)
        func line(_ cells: [String]) -> String {
            (0..<columnCount).map { index in
                let cell = index < cells.count ? cells[index] : ""
                return cell.components(separatedBy: CharacterSet(charactersIn: "\t\n\r\u{2028}\u{2029}"))
                    .joined(separator: " ")
            }.joined(separator: "\t")
        }
        var lines: [String] = []
        if let headers { lines.append(line(headers)) }
        lines.append(contentsOf: rows.map(line))
        return lines.joined(separator: "\n")
    }

    /// Inline-math attachments become `$<latex>$` in the font of the text
    /// before them; any other attachment is dropped (RTF cannot carry it and a
    /// U+FFFC in plain text is noise).
    private static func replacingAttachments(in text: NSAttributedString) -> NSMutableAttributedString {
        let result = NSMutableAttributedString(attributedString: text)
        var attachmentRanges: [NSRange] = []
        result.enumerateAttribute(.attachment, in: NSRange(location: 0, length: result.length)) { value, range, _ in
            if value != nil { attachmentRanges.append(range) }
        }
        // Back to front, so earlier ranges stay valid while later ones change length.
        for range in attachmentRanges.reversed() {
            var replacement = NSAttributedString(string: "")
            if let latex = result.attribute(.qmdInlineMathSource, at: range.location, effectiveRange: nil) as? String {
                var attributes: [NSAttributedString.Key: Any] = [:]
                if range.location > 0 {
                    attributes = result.attributes(at: range.location - 1, effectiveRange: nil)
                    attributes[.attachment] = nil
                    attributes[.qmdInlineMathSource] = nil
                    attributes[.link] = nil
                }
                replacement = NSAttributedString(string: "$" + latex + "$", attributes: attributes)
            }
            result.replaceCharacters(in: range, with: replacement)
        }
        return result
    }

    /// Removes leading and trailing BLANK LINES — whitespace up to and including
    /// a line break — but not the indentation of the first line (nested list
    /// items carry their nesting in leading spaces) and not trailing spaces on
    /// the last line (they were selected and they are not a line).
    private static func trimBlankLines(_ text: NSMutableAttributedString) {
        let string = text.string as NSString
        let whitespace = CharacterSet.whitespacesAndNewlines
        func isWhitespace(_ index: Int) -> Bool {
            guard let scalar = Unicode.Scalar(string.character(at: index)) else { return false }
            return whitespace.contains(scalar)
        }
        func isLineBreak(_ index: Int) -> Bool {
            let unit = string.character(at: index)
            return unit == 0x0A || unit == 0x0D || unit == 0x2028 || unit == 0x2029
        }

        // Trailing: the whitespace run at the end, from its FIRST line break on.
        var tailStart = string.length
        while tailStart > 0, isWhitespace(tailStart - 1) { tailStart -= 1 }
        var cut = string.length
        for index in tailStart..<string.length where isLineBreak(index) {
            cut = index
            break
        }
        if cut < string.length {
            text.deleteCharacters(in: NSRange(location: cut, length: string.length - cut))
        }

        // Leading: the whitespace run at the start, up to its LAST line break.
        let current = text.string as NSString
        var headEnd = 0
        while headEnd < current.length {
            guard let scalar = Unicode.Scalar(current.character(at: headEnd)),
                  whitespace.contains(scalar) else { break }
            headEnd += 1
        }
        var lastBreak = -1
        for index in 0..<headEnd {
            let unit = current.character(at: index)
            if unit == 0x0A || unit == 0x0D || unit == 0x2028 || unit == 0x2029 { lastBreak = index }
        }
        if headEnd == current.length {
            // Nothing but whitespace: no content at all.
            text.deleteCharacters(in: NSRange(location: 0, length: current.length))
        } else if lastBreak >= 0 {
            text.deleteCharacters(in: NSRange(location: 0, length: lastBreak + 1))
        }
    }

    private static let blankLineRun = try? NSRegularExpression(pattern: "\n{3,}")

    /// Three or more consecutive line breaks become two: a renderer chunk
    /// separates paragraphs with an extra blank line that is spacing, not text.
    private static func collapseBlankLineRuns(_ text: NSMutableAttributedString) {
        guard let blankLineRun else { return }
        let matches = blankLineRun.matches(in: text.string, range: NSRange(location: 0, length: text.length))
        for match in matches.reversed() {
            text.replaceCharacters(in: NSRange(location: match.range.location + 2,
                                               length: match.range.length - 2), with: "")
        }
    }
}

// MARK: - Clipboard + copy summary (S-D8 / S-D9)

/// The ONE place a copy reaches the pasteboard (S-D9): the selection (⌘C,
/// context menu, auto-copy), Copy Markdown (⌘⇧C), Copy section (heading
/// button, ToC) and the code block's copy button. One path, so every copy
/// shows the same "Copied N characters · M words" toast for what was written.
enum DocumentClipboard {

    /// Writes plain text and, when given, RTF in one pasteboard transaction
    /// (`rtf: nil` for Markdown source and code — plain text is what they are).
    /// Returns the toast text for this copy (`summary(for:)`), so the caller
    /// that owns the toast cannot show a different count than was copied.
    @discardableResult
    static func write(plain: String, rtf: NSAttributedString?,
                      to pasteboard: NSPasteboard = .general) -> String {
        pasteboard.clearContents()
        var types: [NSPasteboard.PasteboardType] = [.string]
        let rtfData = rtf.flatMap {
            try? $0.data(from: NSRange(location: 0, length: $0.length),
                         documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        }
        if rtfData != nil { types.append(.rtf) }
        pasteboard.declareTypes(types, owner: nil)
        pasteboard.setString(plain, forType: .string)
        if let rtfData { pasteboard.setData(rtfData, forType: .rtf) }
        return summary(for: plain)
    }

    /// "Copied 1,234 characters · 210 words".
    ///
    /// Characters are `Character`s (what a reader counts: "é" is one, an emoji
    /// is one), words are whitespace-separated tokens. "1 character" is
    /// singular; the word count is left out below 2, where it says nothing
    /// the character count did not. Numbers use the locale's grouping.
    static func summary(for plain: String, locale: Locale = .current) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = locale
        func format(_ value: Int) -> String {
            formatter.string(from: NSNumber(value: value)) ?? String(value)
        }
        let characters = plain.count
        var text = "Copied \(format(characters)) " + (characters == 1 ? "character" : "characters")
        let words = plain.split(whereSeparator: { $0.isWhitespace }).count
        if words >= 2 {
            text += " \u{00B7} \(format(words)) words"
        }
        return text
    }
}

// MARK: - Auto-copy (S-D10)

/// How the document selection reached its current value — what decides
/// whether "Copy selected text automatically" copies it.
enum SelectionChange: Equatable {
    /// The mouse went up after a drag from a plain press.
    case drag
    /// A double- (word) or triple-click (paragraph), with or without a drag
    /// after it.
    case multiClick
    /// Shift-click (or Shift-drag) extending the existing selection.
    case shiftClick
    /// ⌘A, Edit ▸ Select All, the context menu's Select All.
    case selectAll
    /// A press and release without movement — it collapses the selection.
    case click
    /// Code changed it, not the reader (search, a model install, the AX
    /// setter). Never copied: the reader did not ask for anything.
    case programmatic

    /// The gesture a finished mouse press was. Shift wins over the click
    /// count (a Shift-double-click extends, like a native text view), and a
    /// multi-click stays one even if the pointer moved afterwards.
    static func mouseGesture(isExtending: Bool, isMultiClick: Bool, dragged: Bool) -> SelectionChange {
        if isExtending { return .shiftClick }
        if isMultiClick { return .multiClick }
        return dragged ? .drag : .click
    }
}

/// Settings ▸ General ▸ "Copy selected text automatically".
///
/// Off by default: an automatic copy REPLACES whatever the reader copied in
/// another app, so it has to be something they chose. When on, the copy
/// happens once, at the END of a gesture — never during a drag (dozens of
/// pasteboard writes and toasts per second) and never for a change the
/// reader did not make.
enum SelectionAutoCopy {
    /// `@AppStorage` key (Settings) and the defaults key the controller reads.
    static let defaultsKey = "autoCopySelection"

    /// Read at each gesture end rather than pushed into every open document:
    /// `@AppStorage` writes `UserDefaults.standard` synchronously, so the
    /// Settings toggle is in effect for the very next gesture in every tab.
    static func isEnabled(in defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: defaultsKey)
    }

    /// Whether the selection left by `change` is copied.
    static func shouldCopy(after change: SelectionChange, selection: DocumentSelection?,
                           enabled: Bool) -> Bool {
        guard enabled, let selection, !selection.isEmpty else { return false }
        switch change {
        case .drag, .multiClick, .shiftClick, .selectAll:
            return true
        case .click, .programmatic:
            return false
        }
    }
}
