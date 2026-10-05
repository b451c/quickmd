import Foundation

// MARK: - Reading position (v1.11 E-D1)
//
// ⌘E hands the document to the user's editor AT THE LINE THEY ARE READING. The
// answer lives in the virtualized list's coordinator (scroll geometry, the
// document selection), but the question is asked by `MarkdownView` — once, at
// the moment ⌘E runs. A handle object bridges the two instead of SwiftUI state:
// publishing the top row through `@State` would re-evaluate the whole document
// body on every scroll tick for a value that is read a few times per session.
//
// This file is compiled into BOTH the app and the test target (no view code),
// so the rule itself is unit-tested directly.

/// Where the reader is, asked for on demand.
///
/// `MarkdownView` owns one per tab (`@State`, reference identity — mutating it
/// never re-renders anything); `VirtualBlockList`'s coordinator installs the
/// `provider` on every update. Main-thread by convention (filled from
/// `updateNSView`, read from a button/menu action); deliberately not
/// `@MainActor`, because SwiftUI View helpers are nonisolated on the older SDK
/// the CI runner builds with.
final class DocumentReadingPosition {

    /// Answers `editorLine()`. Nil until the list has been wired up.
    var provider: (() -> Int?)?
    /// Answers `selectionHint()`. Installed next to `provider`.
    var selectionProvider: (() -> SourceEditSession.SelectionHint?)?

    /// The 1-based editor line the reader is at, or nil when there is no answer
    /// (empty document, list not laid out yet) — the caller then opens the file
    /// plainly.
    func editorLine() -> Int? { provider?() }

    /// The rendered selection as Source Edit's entry hint (S-D14b), or nil
    /// when nothing is selected.
    func selectionHint() -> SourceEditSession.SelectionHint? { selectionProvider?() }

    // MARK: Pure rule

    /// The row ⌘E should land on: the FIRST row of a non-empty selection (the
    /// reader pointed at it), otherwise the row at the top of the visible
    /// content area — the same row the scroll anchor is captured from.
    static func targetRow(selection: DocumentSelection?, topRow: Int?) -> Int? {
        if let selection, let span = selection.rowSpan {
            return span.lowerBound
        }
        return topRow
    }

    /// `targetRow` mapped to the line an editor understands.
    ///
    /// `MarkdownBlock.sourceLine` is 0-based (the index into the ORIGINAL
    /// document's lines — `MarkdownBlockParser` stamps `lineMap[i]`, and front
    /// matter starting on the very first line is `sourceLine: 0`). Every editor
    /// counts from 1, hence `+ 1`. A row index outside `blocks` (a stale
    /// selection/anchor racing a re-install) answers nil, never a wrong line.
    static func editorLine(selection: DocumentSelection?, topRow: Int?,
                           blocks: [MarkdownBlock]) -> Int? {
        guard let row = targetRow(selection: selection, topRow: topRow),
              blocks.indices.contains(row) else { return nil }
        return blocks[row].sourceLine + 1
    }

    /// The selection's plain text plus the source lines to look for it in:
    /// from the first selected block's `sourceLine` up to (not including) the
    /// `sourceLine` of the block after the last selected one — to the end of
    /// the text when there is none. Nil for empty text or rows outside
    /// `blocks` (a stale selection racing a re-install).
    static func selectionHint(text: String, rows: ClosedRange<Int>,
                              blocks: [MarkdownBlock]) -> SourceEditSession.SelectionHint? {
        guard !text.isEmpty, blocks.indices.contains(rows.lowerBound),
              blocks.indices.contains(rows.upperBound) else { return nil }
        let start = blocks[rows.lowerBound].sourceLine
        let next = rows.upperBound + 1
        let end = next < blocks.count ? blocks[next].sourceLine : Int.max
        guard end > start else { return nil }
        return SourceEditSession.SelectionHint(text: text, lines: start..<end)
    }
}
