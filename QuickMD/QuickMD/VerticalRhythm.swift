//
//  VerticalRhythm.swift
//  QuickMD
//
//  The space between blocks: one system for the document list and for
//  print/PDF. Compiled into the app AND the test target (no view code).
//

import AppKit

// MARK: - The rhythm

extension BlockLayout {

    /// How much space separates two blocks.
    ///
    /// Every gap is a multiple of the body size at the current zoom,
    /// `u = 14 × fontScale`, so the whole column scales with the text. A gap
    /// depends ONLY on the two blocks around it: never on whether the source
    /// had a blank line between them (the parser keeps blank lines out of the
    /// rows) and never on where a long block was cut into rows. Rows are
    /// CommonMark blocks, so the same pair of blocks is the same distance apart
    /// everywhere, in every document.
    ///
    /// A gap is measured one of two ways:
    /// - **edge to edge** between two non-heading blocks: from the bottom of
    ///   the upper block's last line box, or its box edge (the background of a
    ///   code block, a quote, a table), to the top of the lower one's;
    /// - **optically** around a heading: from the last BASELINE above it (or a
    ///   box edge) to the heading's CAP TOP, and from the heading's last
    ///   baseline to the next block's cap top or box edge. A heading then has
    ///   the same air under it whatever follows (a paragraph, a list, a code
    ///   block, a table) and the same air above it whatever precedes.
    ///
    /// A row carries its gap as space ABOVE its block (`BlockHeightTable
    /// .spacingAbove`); the first row has none, and neither does a row that only
    /// continues the one before it (`MarkdownBlock.joinsPrevious`).
    enum Spacing {

        /// Body text size at 1.0 zoom: `MarkdownRenderer`'s paragraph font.
        static let bodySize: CGFloat = 14

        /// One unit of the rhythm at `fontScale`.
        static func unit(fontScale: CGFloat) -> CGFloat { bodySize * fontScale }

        /// Between two non-heading blocks, edge to edge: paragraphs, lists,
        /// rules and boxes alike. 24.5 pt at 100 %.
        static let blockMargin: CGFloat = 1.75

        /// Under every heading, optical: its last baseline to the next block's
        /// cap top or box edge. 31.5 pt at 100 %.
        static let headingBelow: CGFloat = 2.25

        /// A heading directly under its parent (a deeper level right after a
        /// shallower one), optical. A little tighter than `headingBelow`, so
        /// the two titles read as one unit. 28 pt at 100 %.
        static let headingUnderHeading: CGFloat = 2.0

        /// Above a heading of level 1…6, optical: the last baseline (or box
        /// edge) above it to its cap top. Larger for the higher levels, so a
        /// section break reads stronger than a subsection break.
        static let headingAbove: [CGFloat] = [4.75, 4.25, 3.75, 3.5, 3.5, 3.5]

        /// `headingAbove` for `level`, clamped to 1…6.
        static func headingAbove(level: Int) -> CGFloat {
            headingAbove[max(1, min(level, 6)) - 1]
        }

        /// What a row is, as far as spacing goes.
        enum Role: Equatable {
            /// Paragraphs, lists, rules: line boxes.
            case text
            case heading(level: Int)
            /// A block with a fixed edge: code, quote, alert, table, image,
            /// formula, diagram.
            case box
            /// The front-matter properties table at the top of a document. A
            /// heading right under it is the document's title, not a section
            /// break, so it gets `blockMargin`, edge to edge.
            case frontMatter
        }

        /// Air inside a row, between the row's edges and what the reader sees.
        struct Edges: Equatable {
            /// Row top → cap top of the first line (text, heading), or the box edge.
            var inkAbove: CGFloat
            /// Last baseline (text, heading), or the box edge → row bottom.
            var inkBelow: CGFloat
            /// Row top → the first line box, or the box edge (0 for text).
            var boxAbove: CGFloat
            /// The last line box, or the box edge → row bottom (0 for text).
            var boxBelow: CGFloat

            /// A box `top` / `bottom` points inside the row's edges: its ink
            /// and its box are the same edge.
            static func box(top: CGFloat, bottom: CGFloat) -> Edges {
                Edges(inkAbove: top, inkBelow: bottom, boxAbove: top, boxBelow: bottom)
            }

            /// Text set `padding` points inside the row on both sides, with no
            /// visible box around it: a quote, whose bars span the text's line
            /// boxes — the eye reads the TEXT. Optical edges on its ink, box
            /// edges on its line boxes, exactly as a paragraph's, so a quote's
            /// text sits where a paragraph's would, under a heading and
            /// between blocks.
            static func text(_ ink: TextInk, padding: CGFloat) -> Edges {
                Edges(inkAbove: padding + ink.firstBaseline - ink.firstCapHeight,
                      inkBelow: padding + ink.height - ink.lastBaseline,
                      boxAbove: padding, boxBelow: padding)
            }

            /// Text laid out as `ink` describes, `top` points below the row's
            /// top edge, in a row `rowHeight` tall (default: the text's own
            /// height plus `top`). Its line boxes are the row's edges.
            static func text(_ ink: TextInk, top: CGFloat = 0, rowHeight: CGFloat? = nil) -> Edges {
                let height = rowHeight ?? (top + ink.height)
                return Edges(inkAbove: top + ink.firstBaseline - ink.firstCapHeight,
                             inkBelow: height - top - ink.lastBaseline,
                             boxAbove: 0, boxBelow: 0)
            }
        }

        /// Where a laid-out string's ink starts and ends (TextKit 1, the same
        /// layout `BlockHeightMeasurer.exactHeight` runs): see
        /// `BlockHeightMeasurer.textInk`.
        struct TextInk: Equatable {
            /// `exactHeight` of the string.
            let height: CGFloat
            /// From the text's top to the first line's baseline.
            let firstBaseline: CGFloat
            /// The largest cap height among the first line's fonts.
            let firstCapHeight: CGFloat
            /// From the text's top to the last line's baseline.
            let lastBaseline: CGFloat
        }

        /// One row's input to the rhythm.
        struct Row: Equatable {
            let role: Role
            let edges: Edges
            /// `MarkdownBlock.joinsPrevious`.
            let joinsPrevious: Bool
        }

        /// The space to put above `row`'s block when `previous` is the row
        /// before it (nil: the document's first row).
        ///
        /// The edges are subtracted from the target, so the reader sees the
        /// target whatever air the two blocks already have inside their rows.
        /// Whole points, never negative.
        static func above(_ row: Row, after previous: Row?, fontScale: CGFloat) -> CGFloat {
            guard let previous, !row.joinsPrevious else { return 0 }
            let target: CGFloat
            let optical: Bool
            switch (previous.role, row.role) {
            case (.heading(let upper), .heading(let lower)) where lower > upper:
                target = headingUnderHeading
                optical = true
            case (.frontMatter, .heading):
                target = blockMargin
                optical = false
            case (_, .heading(let level)):
                target = headingAbove(level: level)
                optical = true
            case (.heading, _):
                target = headingBelow
                optical = true
            default:
                target = blockMargin
                optical = false
            }
            let air = optical ? previous.edges.inkBelow + row.edges.inkAbove
                              : previous.edges.boxBelow + row.edges.boxAbove
            return max(0, (target * unit(fontScale: fontScale) - air).rounded())
        }

        /// `above` for every row of a document, in order.
        static func column(_ rows: [Row], fontScale: CGFloat) -> [CGFloat] {
            var spacing: [CGFloat] = []
            spacing.reserveCapacity(rows.count)
            for index in rows.indices {
                spacing.append(above(rows[index], after: index > 0 ? rows[index - 1] : nil,
                                     fontScale: fontScale))
            }
            return spacing
        }
    }
}

// MARK: - A row of the document list

/// Where a block sits inside its row of `VirtualBlockList`.
///
/// A row is the space above its block (`BlockHeightTable.spacing(_:)`) and
/// then the block, top-aligned. `NSTableView` is flipped, so `minY` is the
/// row's top edge. Every place that turns a row into a position goes through
/// here: a jump lands on the BLOCK, not on the space above it.
enum RowGeometry {

    /// The block's part of `rowRect`: everything below the space above.
    static func contentRect(rowRect: NSRect, spacingAbove: CGFloat) -> NSRect {
        let inset = min(max(0, spacingAbove), rowRect.height)
        return NSRect(x: rowRect.minX, y: rowRect.minY + inset,
                      width: rowRect.width, height: rowRect.height - inset)
    }

    /// The document y a `.top` jump puts at the top of the content area: the
    /// block's top. The space above the block stays above the viewport, so
    /// the content inset alone is the gap the reader sees — the same as above
    /// the document's first block.
    static func topTarget(rowRect: NSRect, spacingAbove: CGFloat) -> CGFloat {
        contentRect(rowRect: rowRect, spacingAbove: spacingAbove).minY
    }

    /// The document y a `.center` jump puts at the top of a content area
    /// `visibleHeight` tall: the block's middle in the middle of it.
    static func centerTarget(rowRect: NSRect, spacingAbove: CGFloat, visibleHeight: CGFloat) -> CGFloat {
        contentRect(rowRect: rowRect, spacingAbove: spacingAbove).midY - visibleHeight / 2
    }

    /// Where a search jump (⌘G) puts the content top. The block's middle at
    /// the centre — unless the block is taller than the content area (a big
    /// table, a long code block): then the focused MATCH's middle
    /// (`matchMidY`, document y) at the centre, so every match in the block is
    /// brought to the eye and stepping between them scrolls. `needsMatch`: a
    /// tall block whose match is not known yet (its view is not on display) —
    /// the jump goes to the block and aims at the match when it lands.
    ///
    /// `withinBlock`: a step between two matches of the same block. A block
    /// that fits the content area is not moved for it (nil) — it was centred
    /// when the search arrived in it.
    static func searchTarget(rowRect: NSRect, spacingAbove: CGFloat, visibleHeight: CGFloat,
                             matchMidY: CGFloat?, withinBlock: Bool = false) -> (target: CGFloat, needsMatch: Bool)? {
        let block = contentRect(rowRect: rowRect, spacingAbove: spacingAbove)
        guard block.height > visibleHeight else {
            if withinBlock { return nil }
            return (centerTarget(rowRect: rowRect, spacingAbove: spacingAbove, visibleHeight: visibleHeight), false)
        }
        if let matchMidY { return (matchMidY - visibleHeight / 2, false) }
        return (centerTarget(rowRect: rowRect, spacingAbove: spacingAbove, visibleHeight: visibleHeight), true)
    }

    /// The scroll anchor: how far below the row's BLOCK top the content top
    /// is. Negative when the content top is in the space above the block.
    /// Relative to the block, not to the row's edge, because that space
    /// changes with zoom and with the block's neighbours; the reader's place
    /// in the block does not.
    static func anchorOffset(contentTop: CGFloat, rowRect: NSRect, spacingAbove: CGFloat) -> CGFloat {
        contentTop - topTarget(rowRect: rowRect, spacingAbove: spacingAbove)
    }

    /// The content top that puts the reader back at `anchorOffset` below the
    /// row's block top — in whatever layout the row has now.
    static func contentTop(anchorOffset: CGFloat, rowRect: NSRect, spacingAbove: CGFloat) -> CGFloat {
        topTarget(rowRect: rowRect, spacingAbove: spacingAbove) + anchorOffset
    }

    /// Whether the content top is still exactly where `anchorOffset` below the
    /// row's block top puts it (to half a point) — i.e. nothing has scrolled
    /// since the anchor was set, other than compensations that moved the block
    /// and the content top together.
    static func isAt(anchorOffset: CGFloat, contentTop: CGFloat, rowRect: NSRect, spacingAbove: CGFloat) -> Bool {
        abs(contentTop - self.contentTop(anchorOffset: anchorOffset, rowRect: rowRect,
                                         spacingAbove: spacingAbove)) < 0.5
    }

    /// Where to put the content top for a reader `offset` below a block whose
    /// height in the current layout is `blockHeight`: at `offset`, unless the
    /// block would then be wholly above the visible area (`topInset`, the top
    /// content inset, still shows content) while its height is only an
    /// estimate — an image placeholder, the diagram default. Its view would
    /// never be built, never report its real height, and the reader would
    /// stay in whatever follows the estimate. The content top then goes to the
    /// block's last point instead, so the block is on screen and reports, and
    /// the anchor is placed again at `offset` when it does (`reportAction`).
    static func anchorPlacement(offset: CGFloat, blockHeight: CGFloat, topInset: CGFloat,
                                heightIsEstimate: Bool) -> CGFloat {
        guard heightIsEstimate, offset - topInset >= blockHeight else { return offset }
        return max(0, blockHeight - 1)
    }

    /// What a `.reported` row's height change does to the scroll offset.
    enum ReportAction: Equatable {
        /// Nothing: the change is below what the reader is anchored on.
        case keep
        /// Move the content top by the change: it is above the anchor, so the
        /// anchor stays where it is on screen.
        case shift
        /// The anchored block itself: place the anchor again (`anchorPlacement`)
        /// against the block's new height.
        case placeAnchor
    }

    /// The rule for a height report of `row`. A block changes height at its
    /// BOTTOM (rows are top-aligned), so the change moves everything below it.
    ///
    /// With an anchor (`anchorRow`: the list's last anchor while the content
    /// top is still where it put it, or the target of a jump in flight) the
    /// anchored block is what stays put: rows above it shift the content top
    /// with them — rows in view above a jump target included, so a search hit
    /// stays centred while the images above it load — and the anchored block
    /// itself is placed again. Its offset was measured at its real height
    /// while the block sat at an estimate; compensating would move the reader
    /// by the estimate's error, a whole image.
    ///
    /// Without one (the reader scrolled), a block whose top is above the
    /// content top — the one straddling it included — shifts the content top,
    /// and a block whose top is in view needs nothing. `contentTop` must be
    /// read BEFORE the table applies the change (at the end of the document
    /// AppKit clamps the clip origin when the table shrinks).
    static func reportAction(row: Int, anchorRow: Int?, blockTop: CGFloat, contentTop: CGFloat) -> ReportAction {
        guard let anchorRow else { return blockTop < contentTop ? .shift : .keep }
        if row < anchorRow { return .shift }
        return row == anchorRow ? .placeAnchor : .keep
    }

    /// Whether a point at `y` in a row belongs to the row BEFORE it: the upper
    /// half of the space above a block is nearer the previous block, so a drag
    /// that stops there ends after that block, not before this one.
    static func belongsToPreviousRow(y: CGFloat, rowRect: NSRect, spacingAbove: CGFloat) -> Bool {
        y < rowRect.minY + min(max(0, spacingAbove), rowRect.height) / 2
    }

    /// Whether `y` is in the upper half of the row's BLOCK — the space above
    /// the block does not count. An atomic row (an image, a formula) is
    /// selected once a drag passes its middle.
    static func isInUpperHalf(y: CGFloat, rowRect: NSRect, spacingAbove: CGFloat) -> Bool {
        y < contentRect(rowRect: rowRect, spacingAbove: spacingAbove).midY
    }
}

// MARK: - Print / PDF

/// The rhythm for print and PDF (`PDFExportManager.generateMultiPagePDF`):
/// the same `BlockLayout.Spacing` rules, applied to the edges of the PRINTED
/// views (`MarkdownPrintableBlockView`), which have no outer paddings and no
/// heading copy button.
enum PrintRhythm {

    /// Role and edges of `block` as `MarkdownPrintableBlockView` prints it at
    /// `width`, at 1.0 zoom.
    ///
    /// Text and headings print through SwiftUI `Text`, which ignores paragraph
    /// styles, so their ink is measured without them. Every box (code, quote,
    /// alert, table, image, diagram) prints its background or its picture from
    /// its frame's edge; a display formula has its vertical padding.
    /// Front matter (either form) is the parser's call: `isFrontMatter`.
    ///
    /// A printed quote has a background, so unlike the screen's it keeps its
    /// box edge. A diagram printed as a picture (`diagramIsPicture`; without
    /// one it prints its source as a code block) starts where its ink does,
    /// `Mermaid.inkInset` inside the picture, as on screen.
    static func row(for block: MarkdownBlock, renderer: MarkdownRenderer, width: CGFloat,
                    diagramIsPicture: Bool = false) -> BlockLayout.Spacing.Row {
        typealias Spacing = BlockLayout.Spacing
        let role: Spacing.Role
        let edges: Spacing.Edges
        switch block.content {
        case .text(let attributed):
            role = .text
            edges = .text(BlockHeightMeasurer.textInk(text: printed(attributed), width: width))
        case .heading(let level, let title, _):
            role = .heading(level: level)
            edges = .text(BlockHeightMeasurer.textInk(text: printed(renderer.renderHeader(title, level: level)),
                                                      width: width))
        case .mathBlock:
            role = .box
            edges = .box(top: BlockLayout.Math.verticalPadding, bottom: BlockLayout.Math.verticalPadding)
        case .mermaidDiagram where diagramIsPicture:
            role = .box
            edges = .box(top: BlockLayout.Mermaid.inkInset, bottom: BlockLayout.Mermaid.inkInset)
        case .table, .codeBlock, .blockquote, .alert, .image, .svgImage, .mermaidDiagram:
            role = .box
            edges = .box(top: 0, bottom: 0)
        }
        return Spacing.Row(role: block.isFrontMatter ? .frontMatter : role, edges: edges,
                           joinsPrevious: block.joinsPrevious)
    }

    /// The string as SwiftUI `Text` lays it out: no paragraph styles.
    private static func printed(_ attributed: AttributedString) -> NSAttributedString {
        let ns = NSMutableAttributedString(attributedString:
            (try? NSAttributedString(attributed, including: \.appKit))
                ?? NSAttributedString(string: String(attributed.characters)))
        ns.removeAttribute(.paragraphStyle, range: NSRange(location: 0, length: ns.length))
        return ns
    }

    /// A block to print: its height, the space above it, and whether it must
    /// not end a page (a heading keeps with the block after it).
    struct Block: Equatable {
        let height: CGFloat
        let spacingAbove: CGFloat
        let keepsWithNext: Bool
    }

    /// One printed piece of a block — the whole block, or one slice of a
    /// block taller than the room it gets: its part of the block (`offset`,
    /// `height`), its page and its y from the top of the page's content area.
    struct Slice: Equatable {
        let block: Int
        let offset: CGFloat
        let height: CGFloat
        let page: Int
        let y: CGFloat
    }

    /// The least of a sliced block that has to fit below a heading kept with
    /// it: two lines of body text.
    static let minimumFirstSlice: CGFloat = 40

    /// Lays `blocks` out top to bottom on pages `pageHeight` tall.
    ///
    /// - A block gets its `spacingAbove` unless it is first on its page — the
    ///   page's margin already separates it from the page above.
    /// - A block that does not fit below the last one starts a new page; a
    ///   block taller than a page starts one and is sliced, a page per slice.
    /// - Keep with next: a run of headings (`keepsWithNext`, an H2 and the H3
    ///   under it) never ends a page. When the block after the run starts a
    ///   new page, the run moves to that page with it — if the run and the
    ///   block fit on one page; otherwise nothing would be gained and the run
    ///   stays. A block taller than a page is not moved: its first slice
    ///   fills the rest of the run's page (moving the run first when not even
    ///   `minimumFirstSlice` fits there), so a heading is kept with that first
    ///   slice and nothing loops.
    static func paginate(_ blocks: [Block], pageHeight: CGFloat) -> [Slice] {
        var slices: [Slice] = []
        slices.reserveCapacity(blocks.count)
        var page = 0
        var bottom: CGFloat = 0        // of the last slice on `page`
        var pageIsEmpty = true

        func put(_ block: Int, offset: CGFloat = 0, height: CGFloat, at y: CGFloat) {
            slices.append(Slice(block: block, offset: offset, height: height, page: page, y: y))
            bottom = y + height
            pageIsEmpty = false
        }
        func newPage() {
            page += 1
            bottom = 0
            pageIsEmpty = true
        }
        /// The headings that end the current page right before `block`, as
        /// indices into `slices` (empty: none).
        func headingRun(before block: Int) -> Range<Int> {
            var first = slices.count
            var expected = block - 1
            while first > 0 {
                let last = slices[first - 1]
                guard last.page == page, last.block == expected, last.offset == 0,
                      blocks[last.block].keepsWithNext else { break }
                first -= 1
                expected -= 1
            }
            return first..<slices.count
        }
        /// Moving a run helps only when something precedes it on its page.
        func canMove(_ run: Range<Int>) -> Bool { !run.isEmpty && slices[run.lowerBound].y > 0 }
        /// Moves `run` to the top of a new page.
        func moveToNewPage(_ run: Range<Int>) {
            let moved = Array(slices[run])
            slices.removeSubrange(run)
            newPage()
            for slice in moved {
                put(slice.block, height: slice.height,
                    at: pageIsEmpty ? 0 : bottom + blocks[slice.block].spacingAbove)
            }
        }
        func runHeight(_ run: Range<Int>) -> CGFloat {
            guard let first = run.first else { return 0 }
            return slices[run.last ?? first].y + slices[run.last ?? first].height - slices[first].y
        }

        for (index, block) in blocks.enumerated() {
            let y = pageIsEmpty ? 0 : bottom + block.spacingAbove
            let run = headingRun(before: index)
            if block.height <= pageHeight {
                if pageIsEmpty || y + block.height <= pageHeight {
                    put(index, height: block.height, at: y)
                } else if canMove(run), runHeight(run) + block.spacingAbove + block.height <= pageHeight {
                    moveToNewPage(run)
                    put(index, height: block.height, at: bottom + block.spacingAbove)
                } else {
                    newPage()
                    put(index, height: block.height, at: 0)
                }
                continue
            }

            // Taller than a page: sliced, a page per slice — except the first
            // slice after a heading run, which fills the rest of the run's page.
            var offset: CGFloat = 0
            if !run.isEmpty, pageHeight - y < minimumFirstSlice, canMove(run) {
                moveToNewPage(run)
            }
            let top = pageIsEmpty ? 0 : bottom + block.spacingAbove
            if !run.isEmpty, pageHeight - top >= minimumFirstSlice {
                let first = pageHeight - top
                put(index, height: first, at: top)
                offset = first
            }
            while offset < block.height {
                if !pageIsEmpty { newPage() }
                let height = min(pageHeight, block.height - offset)
                put(index, offset: offset, height: height, at: 0)
                offset += height
            }
        }
        return slices
    }
}
