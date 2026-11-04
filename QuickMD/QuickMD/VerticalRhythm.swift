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
    ///
    /// - Parameter isFirst: the block is the document's first (front matter).
    static func row(for block: MarkdownBlock, isFirst: Bool,
                    renderer: MarkdownRenderer, width: CGFloat) -> BlockLayout.Spacing.Row {
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
        case .table(_, _, _, let style):
            role = style == .properties && isFirst ? .frontMatter : .box
            edges = .box(top: 0, bottom: 0)
        case .mathBlock:
            role = .box
            edges = .box(top: BlockLayout.Math.verticalPadding, bottom: BlockLayout.Math.verticalPadding)
        case .codeBlock, .blockquote, .alert, .image, .svgImage, .mermaidDiagram:
            role = .box
            edges = .box(top: 0, bottom: 0)
        }
        return Spacing.Row(role: role, edges: edges, joinsPrevious: block.joinsPrevious)
    }

    /// The string as SwiftUI `Text` lays it out: no paragraph styles.
    private static func printed(_ attributed: AttributedString) -> NSAttributedString {
        let ns = NSMutableAttributedString(attributedString:
            (try? NSAttributedString(attributed, including: \.appKit))
                ?? NSAttributedString(string: String(attributed.characters)))
        ns.removeAttribute(.paragraphStyle, range: NSRange(location: 0, length: ns.length))
        return ns
    }

    /// Where a segment lands: its page and its y from the top of the page's
    /// content area.
    struct Placement: Equatable {
        let page: Int
        let y: CGFloat
    }

    /// Lays `segments` (a block, or one slice of a block taller than a page)
    /// out top to bottom on pages `pageHeight` tall.
    ///
    /// A segment gets its `spacingAbove` unless it is first on its page — the
    /// page's margin already separates it from the page above. A segment that
    /// does not fit below the last one starts a new page.
    static func paginate(_ segments: [(height: CGFloat, spacingAbove: CGFloat)],
                         pageHeight: CGFloat) -> [Placement] {
        var placements: [Placement] = []
        placements.reserveCapacity(segments.count)
        var page = 0
        var bottom: CGFloat = 0
        var pageIsEmpty = true
        for segment in segments {
            var y = pageIsEmpty ? 0 : bottom + segment.spacingAbove
            if !pageIsEmpty, y + segment.height > pageHeight {
                page += 1
                y = 0
            }
            placements.append(Placement(page: page, y: y))
            bottom = y + segment.height
            pageIsEmpty = false
        }
        return placements
    }
}
