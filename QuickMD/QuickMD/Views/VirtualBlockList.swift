import SwiftUI
import AppKit
import AVFoundation
#if DEBUG
import os
#endif

// MARK: - Virtualized Block List (v1.9 D1/D2/D5–D7/D10/D11)
//
// The document's block list, hosted by AppKit instead of SwiftUI.
//
// Why not `ScrollView` + `VStack`/`LazyVStack` any more:
//
//  * `LazyVStack` sizes the rows it has NOT placed by extrapolating from the
//    ones it has. Markdown rows range from a 17-pt paragraph to a 500-pt code
//    block, so the estimate swings by hundreds of points as rows are placed and
//    unplaced, every visible row shifts, the visible set changes, the estimate
//    swings again — a permanent main-thread layout loop on macOS 15
//    (constraints.md, "Scroll freeze"). Here every row's height is a NUMBER we
//    computed in advance (`BlockHeightTable`); nothing is ever extrapolated.
//  * `VStack` has nothing to estimate, but it places every row up front, which
//    costs main-thread time proportional to the document.
//  * `ScrollViewReader.scrollTo` only resolves ids that are present in the tree,
//    and macOS 13 has no `scrollPosition(id:)`, so exact programmatic scrolling
//    (ToC, search) and scroll-anchor preservation across re-parses were not
//    expressible in SwiftUI on our deployment target.
//
// `NSTableView` gives us virtualization, row reuse, `rect(ofRow:)`,
// `noteHeightOfRows(withIndexesChanged:)` and a clip view we own — which is what
// makes exact scrolling and exact anchor compensation possible. Cells host the
// UNCHANGED SwiftUI block views through `NSHostingView` (D2). Precedent for
// AppKit hosting in this app: `WindowTabbing.swift`.
//
// Feedback discipline (the reason this is not the LazyVStack estimator again):
// rows whose height the measurer can compute exactly (`RowKind.exact`) never
// report anything. Rows whose real size only exists once a view is placed
// (`.reported`: headings, tables, images, display math, Mermaid) report their
// natural height ONCE per model generation; the coordinator applies the
// correction and compensates the scroll offset. No unplaced row is ever
// re-estimated, and no row's height is a function of the height we gave it (the
// hosted content is `fixedSize`d vertically, so the row height cannot feed back
// into the measured height).

#if DEBUG
// Console.app filter: subsystem == "pl.falami.studio.QuickMD" AND category == "VirtualBlockList"
private let listLog = Logger(subsystem: "pl.falami.studio.QuickMD", category: "VirtualBlockList")
private let listSignpost = OSSignposter(subsystem: "pl.falami.studio.QuickMD", category: "VirtualBlockList")
#endif

// MARK: - Block identity for anchor restoration

/// A cheap content fingerprint of one block.
///
/// Used only to find the scroll anchor again after the document changed shape.
/// Neither of the two identities a block already has can do that job:
///
///  * `MarkdownBlock.id` is POSITIONAL (`text-17`), so inserting one block above
///    renumbers every block below it.
///  * `sourceLine` moves with any edit above it.
///
/// The characters are what the reader was actually looking at, so they are the
/// identity we match on. 80 characters distinguishes paragraphs without copying
/// the document, and the kind tag in front keeps a heading from matching a
/// paragraph with the same words.
private func blockSignature(_ block: MarkdownBlock) -> String {
    func head(_ text: String) -> String { String(text.prefix(80)) }
    switch block.content {
    case .text(let attributed):
        return "t|" + head(String(attributed.characters))
    case .table(let headers, let rows, _):
        return "b|\(rows.count)|" + head(headers.joined(separator: "\u{1F}"))
    case .codeBlock(let code, let language):
        return "c|\(language)|" + head(code)
    case .image(let url, let alt):
        return "i|\(head(url))|" + head(alt)
    case .blockquote(let content, let level):
        return "q|\(level)|" + head(content)
    case .alert(let kind, let content):
        return "a|\(kind.rawValue)|" + head(content)
    case .heading(let level, let title, _):
        return "h|\(level)|" + head(title)
    case .mathBlock(let latex):
        return "m|" + head(latex)
    case .mermaidDiagram(let source):
        return "d|" + head(source)
    case .svgImage(let source):
        return "s|" + head(source)
    }
}

struct VirtualBlockList: NSViewRepresentable {

    /// Where a programmatic scroll parks the target row.
    enum Anchor: Equatable {
        /// Row top at the top of the content area (ToC).
        case top
        /// Row centre at the centre of the content area (search).
        case center
    }

    /// One programmatic scroll. `token` is the trigger: the coordinator acts when
    /// it changes, so re-sending the same target scrolls again and an unrelated
    /// body re-evaluation does not.
    struct ScrollRequest: Equatable {
        let blockId: String
        let anchor: Anchor
        let animated: Bool
        let token: Int
    }

    /// How wide the text column may get and how much air it has at the document's
    /// ends — the two numbers reading mode changes (v1.9).
    ///
    /// One value rather than two inputs, so a change is a single `!=` in
    /// `updateNSView` and the anchor is captured and restored exactly once for the
    /// whole switch.
    struct LayoutStyle: Equatable {
        /// Upper bound on the width a block view is laid out at. `nil` = fill the
        /// window, which is every mode but reading mode.
        let maxContentWidth: CGFloat?
        /// Visible gap above the first block and below the last one.
        let verticalPadding: CGFloat

        static let standard = LayoutStyle(maxContentWidth: nil,
                                          verticalPadding: Metrics.contentVerticalPadding)
        static let reading = LayoutStyle(maxContentWidth: Metrics.readingMaxContentWidth,
                                         verticalPadding: Metrics.readingContentVerticalPadding)

        /// The scroll view's top/bottom content inset for this style.
        ///
        /// Not simply `verticalPadding`: `NSTableView` centres each row inside its
        /// rect, which puts HALF the intercell spacing above the first row and
        /// half below the last one (measured). Subtracting that half makes the
        /// gap the reader sees exactly `verticalPadding`, and makes a `.top` jump
        /// to any row — row 0 included — leave that same gap above its content.
        var edgeInset: CGFloat { max(0, verticalPadding - Metrics.blockSpacing / 2) }
    }

    /// Row content, in block order.
    let blocks: [MarkdownBlock]
    /// One height + kind per block, for a specific content width. While
    /// `table.count != blocks.count` the list keeps whatever it is already
    /// showing — a half-measured document is never displayed (D4).
    let table: BlockHeightTable
    /// Bumped by `MarkdownView` on every parse. THE signal that `blocks` are new.
    let contentVersion: Int
    let searchText: String
    let focusedBlockId: String?
    let focusedOccInBlock: Int?
    let scrollRequest: ScrollRequest?
    /// Column width cap + end padding (reading mode vs. everything else). Feeds
    /// BOTH the width the heights are measured at and the width the cells lay
    /// their content out at — one number, so the two cannot drift.
    let layoutStyle: LayoutStyle
    /// Column width − 2 × `contentHorizontalPadding`, capped by
    /// `layoutStyle.maxContentWidth`: the width a block view
    /// actually gets, and therefore the width the heights must be measured at.
    /// Written by the coordinator (never per frame during a live resize — D4).
    @Binding var contentWidth: CGFloat
    /// A `.reported` row's placed view told us its real height. `row` is the
    /// index the height belongs to; `blockId` lets the parent reject a report
    /// that arrives after a re-parse.
    let onHeightReport: (_ blockId: String, _ row: Int, _ height: CGFloat) -> Void
    /// `MarkdownView.blockView(for:)`, type-erased. Rebuilt on every body
    /// evaluation, so a fresh closure always carries the current theme, search
    /// term and focus.
    let content: (MarkdownBlock) -> AnyView
    /// The string a row's text view displays, for rows that have one (S-D2) —
    /// nil for atomic rows. Lets the document selection measure and copy rows
    /// that were never materialized (⌘A + ⌘C on a 10K-line document must not
    /// need the views). `contentVersion` is the version of the INSTALLED blocks
    /// the block comes from, so the parent can tell whether its per-id caches
    /// belong to them (block ids are positional and are reused by every parse).
    let selectableText: (_ block: MarkdownBlock, _ contentVersion: Int) -> NSAttributedString?
    /// ⌘C / context-menu Copy produced this output. The parent writes it to the
    /// pasteboard and shows the toast (`MarkdownView.copySelectionToClipboard`).
    let onCopySelection: (DocumentCopyOutput) -> Void
    /// Bumped by the parent when the document should get the keyboard back
    /// (the graphic preview closed after resigning first responder). Acted on
    /// only when nothing else is focused — see `takeFocusIfWindowHasNone`.
    var focusRequest: Int = 0

    typealias Metrics = BlockLayout.Document

    // MARK: NSViewRepresentable

    func makeCoordinator() -> Coordinator {
        let coordinator = Coordinator()
        // Adopt the pending request's token instead of `.min`: `makeNSView` also
        // runs when SwiftUI re-creates the representable's views (a tab moved
        // between windows, the parent's identity changed), and a coordinator that
        // starts at `.min` replays whatever ToC or search jump happens to be the
        // current value — sending the reader somewhere they left minutes ago.
        coordinator.lastScrollToken = scrollRequest?.token ?? .min
        // Adopted, not defaulted: `makeNSView` configures the scroll view from
        // the same value, so the coordinator must not think a style change is
        // pending on the first `updateNSView`.
        coordinator.layoutStyle = layoutStyle
        return coordinator
    }

    func makeNSView(context: Context) -> NSScrollView {
        let coordinator = context.coordinator

        let tableView = BlockTableView()
        tableView.dataSource = coordinator
        tableView.delegate = coordinator
        // D10 — the table must behave like a scrolling canvas, not like a list:
        // no selection, no header, no grid, no alternating bands, no type-select.
        tableView.selectionHighlightStyle = .none
        tableView.allowsEmptySelection = true
        tableView.allowsMultipleSelection = false
        tableView.allowsColumnSelection = false
        tableView.allowsColumnReordering = false
        tableView.allowsColumnResizing = false
        tableView.allowsTypeSelect = false
        tableView.headerView = nil
        tableView.style = .plain
        tableView.backgroundColor = .clear
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.gridStyleMask = []
        tableView.focusRingType = .none
        // The 8 pt that `VStack(spacing:)` used to put between blocks. Row
        // heights themselves therefore stay exactly what the measurer computed.
        tableView.intercellSpacing = NSSize(width: 0, height: Metrics.blockSpacing)
        tableView.rowSizeStyle = .custom
        tableView.usesAutomaticRowHeights = false
        // The coordinator sets the single column's width to the clip view's width
        // on every frame change (`syncColumnWidth`), because `contentWidth` — the
        // width the heights are measured at — is derived from it. Letting AppKit
        // resize it proportionally instead would make that number a consequence
        // of the column's previous width rather than of the window's.
        tableView.columnAutoresizingStyle = .noColumnAutoresizing

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("QMDBlockColumn"))
        // No `resizingMask`: with `.noColumnAutoresizing` above, AppKit never
        // resizes this column — `syncColumnWidth()` owns its width.
        column.minWidth = 1
        column.maxWidth = .greatestFiniteMagnitude
        tableView.addTableColumn(column)

        let scrollView = BlockScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        // Deliberately NOT autohiding: with the system set to "Show scroll bars:
        // Always" a scroller that appears and disappears changes the clip width,
        // which would change the measured heights, which changes the content
        // height — a loop with the same shape as the one this design removes.
        scrollView.autohidesScrollers = false
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        // The 24 pt (48 in reading mode) that used to be `.padding(.vertical:)`
        // on the stack. As content insets they scroll with the document exactly
        // as before, but AppKit — not us — owns the arithmetic (see
        // `contentTopY`). The half-spacing correction lives in
        // `LayoutStyle.edgeInset`; the coordinator re-applies it when the style
        // changes.
        scrollView.automaticallyAdjustsContentInsets = false
        let edgeInset = layoutStyle.edgeInset
        scrollView.contentInsets = NSEdgeInsets(top: edgeInset, left: 0,
                                               bottom: edgeInset, right: 0)
        scrollView.contentView.drawsBackground = false
        scrollView.contentView.postsBoundsChangedNotifications = true
        scrollView.contentView.postsFrameChangedNotifications = true
        scrollView.documentView = tableView
        // Width follows the clip view (the table's own height is AppKit's job).
        tableView.autoresizingMask = [.width]

        coordinator.attach(scrollView: scrollView, tableView: tableView)
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        // Closures first: an install or a refresh below builds root views from
        // them, and they must be the ones from THIS body evaluation.
        coordinator.content = content
        coordinator.onHeightReport = onHeightReport
        coordinator.setContentWidth = { width in contentWidth = width }
        coordinator.selection.selectableText = selectableText
        coordinator.selection.onCopy = onCopySelection
        if focusRequest != coordinator.lastFocusRequest {
            coordinator.lastFocusRequest = focusRequest
            coordinator.restoreDocumentFocus()
        }
        // Before anything that builds a root view or reads a width: entering or
        // leaving reading mode changes both.
        coordinator.applyLayoutStyle(layoutStyle)
        coordinator.syncWidthIfNeeded(parentValue: contentWidth)

        // A half-measured document is never shown: keep the previous model until
        // a consistent (blocks, table) pair arrives (D4).
        if table.count == blocks.count {
            if coordinator.contentVersion != contentVersion
                || coordinator.blocks.count != blocks.count
                || coordinator.table.contentWidth != table.contentWidth {
                // S7: the model is replaced wholesale, never merged. The parent's
                // table is authoritative at a version/width change; between them
                // the coordinator's own copy is (it holds the height reports).
                coordinator.install(blocks: blocks, table: table, contentVersion: contentVersion)
            } else if coordinator.searchText != searchText
                        || coordinator.focusedBlockId != focusedBlockId
                        || coordinator.focusedOccInBlock != focusedOccInBlock {
                // D11 — same rows, new highlighting: hand the materialized cells
                // a fresh root view. SwiftUI diffs it and `.id(block.id)` keeps
                // each block's state (loaded images, rendered diagrams).
                coordinator.refreshMaterializedRootViews()
            }
        }
        coordinator.searchText = searchText
        coordinator.focusedBlockId = focusedBlockId
        coordinator.focusedOccInBlock = focusedOccInBlock

        if let request = scrollRequest, request.token != coordinator.lastScrollToken {
            coordinator.lastScrollToken = request.token
            coordinator.scroll(to: request)
        }
    }

    // MARK: - Coordinator

    /// Owns the installed model (blocks + height table + generation), the
    /// AppKit objects, and every write to the scroll offset.
    ///
    /// Main-thread only: every entry point is either an `NSViewRepresentable`
    /// callback, an AppKit notification or a SwiftUI preference change.
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {

        // MARK: Installed model

        private(set) var blocks: [MarkdownBlock] = []
        private(set) var table: BlockHeightTable = .empty
        /// `-1` until the first install, so an empty first document still installs.
        private(set) var contentVersion: Int = -1
        /// Bumped on every wholesale replace. Part of a `.reported` row's height
        /// preference, which is what makes the placed view report again after a
        /// re-measure even when its natural height happens to be unchanged.
        private(set) var generation: Int = 0
        private var rowForBlockId: [String: Int] = [:]

        // MARK: Inputs refreshed per update

        var content: (MarkdownBlock) -> AnyView = { _ in AnyView(EmptyView()) }
        var onHeightReport: (String, Int, CGFloat) -> Void = { _, _, _ in }
        var setContentWidth: (CGFloat) -> Void = { _ in }
        var searchText: String = ""
        var focusedBlockId: String?
        var focusedOccInBlock: Int?
        var lastScrollToken: Int = .min
        var lastFocusRequest: Int = 0
        /// Column cap + end padding currently in force. Adopted in
        /// `makeCoordinator` and changed only through `applyLayoutStyle`, which is
        /// what keeps the cells' layout width, the published `contentWidth` and
        /// the scroll insets in agreement.
        var layoutStyle: LayoutStyle = .standard

        // MARK: AppKit

        private weak var scrollView: BlockScrollView?
        private weak var tableView: BlockTableView?

        /// The document selection (v1.11 S-D4). Owned here — one per list, i.e.
        /// one per tab — so it lives exactly as long as the rows it indexes.
        let selection = SelectionController()

        // MARK: contentWidth reporting state

        /// Last width handed to the parent. 0 = never reported, which is the one
        /// case that skips the debounce (the height table is blocked on it).
        private var reportedContentWidth: CGFloat = 0
        private var widthWork: DispatchWorkItem?
        private var frameObserver: NSObjectProtocol?
        /// `updateNSView` has run at least once, so `setContentWidth` is the
        /// parent's binding rather than the placeholder no-op. A width published
        /// before that would be lost — and the height table would never be
        /// measured, leaving a permanently blank document.
        private var isWired = false

        deinit {
            widthWork?.cancel()
            if let frameObserver { NotificationCenter.default.removeObserver(frameObserver) }
        }

        func attach(scrollView: BlockScrollView, tableView: BlockTableView) {
            self.scrollView = scrollView
            self.tableView = tableView
            selection.attach(tableView: tableView)
            tableView.selectionController = selection
            scrollView.selectionController = selection
            scrollView.onEndLiveResize = { [weak self] in
                self?.clipFrameChanged(afterLiveResize: true)
            }
            frameObserver = NotificationCenter.default.addObserver(
                forName: NSView.frameDidChangeNotification,
                object: scrollView.contentView, queue: nil
            ) { [weak self] _ in
                self?.clipFrameChanged(afterLiveResize: false)
            }
        }

        /// One turn later: the request arrives in the same SwiftUI update that
        /// removes the overlay, whose views may still hold focus until then.
        func restoreDocumentFocus() {
            DispatchQueue.main.async { [weak self] in
                self?.tableView?.takeFocusIfWindowHasNone()
            }
        }

        // MARK: - Model installation (D7 anchor preservation)

        /// The whole visible geometry of one scroll position: which row was at
        /// the top of the content area, how far into it we were, and two
        /// identities for finding that row again after the document changed shape
        /// — its content fingerprint (primary) and the source line it started at
        /// (fallback, D8).
        private struct CapturedAnchor {
            let row: Int
            let offsetWithinRow: CGFloat
            let sourceLine: Int
            let signature: String
        }

        func install(blocks newBlocks: [MarkdownBlock], table newTable: BlockHeightTable,
                     contentVersion newVersion: Int) {
            guard let tableView else { return }
            #if DEBUG
            let signpostID = listSignpost.makeSignpostID()
            let state = listSignpost.beginInterval("reloadData", id: signpostID,
                                                   "rows=\(newBlocks.count)")
            let started = DispatchTime.now()
            #endif

            let anchor = captureAnchor()
            let previousCount = blocks.count

            blocks = newBlocks
            table = newTable
            contentVersion = newVersion
            generation += 1
            rowForBlockId = [:]
            rowForBlockId.reserveCapacity(newBlocks.count)
            for (index, block) in newBlocks.enumerated() { rowForBlockId[block.id] = index }
            // Before `reloadData`, which configures cells (atomic-row tints)
            // from it. Clears the selection on a new content version and keeps
            // it across width-only reinstalls (S-D11).
            selection.install(blocks: newBlocks, rowForBlockId: rowForBlockId,
                              contentVersion: newVersion)

            // `reloadData()` re-queries `heightOfRow` for every row (verified on
            // macOS 15 for both an unchanged and a changed row count), so no
            // separate `noteHeightOfRows` pass is needed here.
            tableView.reloadData()
            if let anchor {
                restore(anchor, previousCount: previousCount)
            } else if previousCount == 0 {
                // First content in this list. The top content inset only becomes
                // visible space once the clip view is scrolled to its minimum,
                // and AppKit leaves the origin at 0 — i.e. one inset's worth
                // already "scrolled" — until something moves it. Parking here is
                // what puts the document's top padding on screen at open.
                #if DEBUG
                listLog.debug("install: first content → parking at content top")
                #endif
                setContentTop(0, animated: false)
            } else {
                // Content existed, but where the reader was could not be read
                // (hidden tab, window not laid out yet — see `captureAnchor`).
                // Leaving the clip origin ALONE is the only safe answer: parking
                // at the top would rewind every background tab whenever something
                // global re-measures them (toggling the ToC changes every tab's
                // width), and the offset the tab already has is still the offset
                // it should show when the user switches back to it.
                #if DEBUG
                listLog.debug("install: no anchor and \(previousCount) previous rows → clip origin left unchanged")
                #endif
            }

            #if DEBUG
            listSignpost.endInterval("reloadData", state)
            let elapsedMS = Double(DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1_000_000
            listLog.debug("reloadData: \(newBlocks.count) rows, version=\(newVersion), width=\(newTable.contentWidth, format: .fixed(precision: 1)), anchor=\(anchor.map { "row \($0.row)+\($0.offsetWithinRow)" } ?? "none", privacy: .public), \(elapsedMS, format: .fixed(precision: 2)) ms")
            #endif
        }

        /// The part of a row rect the hosted view actually occupies.
        ///
        /// `NSTableView` centres a row's content inside `rect(ofRow:)`, splitting
        /// `intercellSpacing.height` half above and half below (measured: a 100 pt
        /// row at 8 pt spacing gets rect height 108 with the cell at +4).
        ///
        /// Used for `.center` only, where the block's visual middle is what the
        /// reader's eye goes to. `.top` and the scroll anchor deliberately use the
        /// FULL row rect: its `minY` sits half a spacing above the content, which
        /// — together with the reduced content inset — is what makes every jump
        /// leave the same gap as the top of the document.
        private func rowContentRect(_ row: Int) -> NSRect {
            guard let tableView else { return .zero }
            var rect = tableView.rect(ofRow: row)
            let spacing = tableView.intercellSpacing.height
            rect.origin.y += spacing / 2
            rect.size.height = max(0, rect.size.height - spacing)
            return rect
        }

        /// Where the reader is, or nil when that question has no answer.
        ///
        /// The nil cases are the point of this function. Native window tabbing
        /// gives every tab its OWN `NSWindow`, and a re-measure can be triggered
        /// for all of them at once (toggling the ToC changes every tab's content
        /// width), so this runs on tabs AppKit has never laid out and on windows
        /// restored from a saved session that are not on screen yet. There,
        /// `tableView`'s row geometry is zero or stale and `row(at:)` answers −1
        /// for reasons that have nothing to do with the scroll position —
        /// which is how a hidden tab used to end up anchored on its LAST row and
        /// scrolled to the end of its document.
        private func captureAnchor() -> CapturedAnchor? {
            guard let scrollView, let tableView, !blocks.isEmpty,
                  tableView.numberOfRows > 0 else {
                #if DEBUG
                listLog.debug("captureAnchor: nil — no content")
                #endif
                return nil
            }
            // Laid out at all? An un-laid-out table has zero bounds and answers
            // every geometry query with a placeholder.
            let clipBounds = scrollView.contentView.bounds
            guard tableView.bounds.height > 0,
                  clipBounds.height > 0, clipBounds.width > 0 else {
                #if DEBUG
                listLog.debug("captureAnchor: nil — not laid out (tableH=\(tableView.bounds.height, format: .fixed(precision: 1)), clip=\(clipBounds.width, format: .fixed(precision: 1))×\(clipBounds.height, format: .fixed(precision: 1)))")
                #endif
                return nil
            }
            // On screen at all? A background tab's window is neither visible nor
            // unoccluded, and its scroll offset is whatever the user left it at —
            // which is exactly what we want to keep, untouched.
            // `isVisible` only: a window covered by another app / on another
            // Space still has a valid layout and offset, so its anchor is
            // trustworthy; a non-selected native tab is ordered out and is not.
            guard let window = scrollView.window, window.isVisible else {
                #if DEBUG
                listLog.debug("captureAnchor: nil — window not visible")
                #endif
                return nil
            }

            let top = contentTopY()
            var row = tableView.row(at: NSPoint(x: 0, y: max(0, top)))
            if row < 0 {
                // −1 means "no row at that point", which is only *legitimately*
                // true when we are scrolled past the last row into the bottom
                // inset. Anywhere else it is AppKit telling us the table is not
                // in a state to answer, and anchoring on the last row would jump
                // the document to its end.
                guard top >= tableView.bounds.height - 1 else {
                    #if DEBUG
                    listLog.debug("captureAnchor: nil — row(at: \(top, format: .fixed(precision: 1))) = −1 inside a \(tableView.bounds.height, format: .fixed(precision: 1)) pt table")
                    #endif
                    return nil
                }
                row = tableView.numberOfRows - 1
                #if DEBUG
                listLog.debug("captureAnchor: past the last row → row \(row)")
                #endif
            }
            guard row >= 0, row < blocks.count else { return nil }
            return CapturedAnchor(row: row,
                                  offsetWithinRow: top - tableView.rect(ofRow: row).minY,
                                  sourceLine: blocks[row].sourceLine,
                                  signature: blockSignature(blocks[row]))
        }

        private func restore(_ anchor: CapturedAnchor, previousCount: Int) {
            guard let tableView, !blocks.isEmpty else { return }
            var row = anchor.row
            #if DEBUG
            var matchedBy = "index"
            #endif
            if previousCount != blocks.count || row >= blocks.count {
                // The document changed shape (auto-reload inserted or removed
                // blocks), so the row index means nothing on its own.
                //
                // `sourceLine` alone is not enough either: inserting a few lines
                // above the viewport shifts every following line, so "the first
                // block starting at or after the old line" lands on the block
                // BEFORE the one we were on (observed as a one-block drift on
                // auto-reload). What the reader was looking at is the block's
                // CONTENT, so that is the identity we match on, and `sourceLine`
                // is only the fallback for a block that was itself edited.
                if let matched = nearestSignatureMatch(anchor.signature, near: anchor.row) {
                    row = matched
                    #if DEBUG
                    matchedBy = "signature"
                    #endif
                } else {
                    row = blocks.firstIndex { $0.sourceLine >= anchor.sourceLine } ?? (blocks.count - 1)
                    #if DEBUG
                    matchedBy = "sourceLine"
                    #endif
                }
            }
            guard row >= 0, row < tableView.numberOfRows else { return }
            #if DEBUG
            listLog.debug("restoreAnchor: by \(matchedBy, privacy: .public), row \(anchor.row) → \(row), offset=\(anchor.offsetWithinRow, format: .fixed(precision: 1))")
            #endif
            setContentTop(tableView.rect(ofRow: row).minY + anchor.offsetWithinRow, animated: false)
        }

        /// The row whose content fingerprint equals `signature`, closest to
        /// `row`.
        ///
        /// Nearest rather than first: a document can legitimately repeat a block
        /// (two identical `---` rules, the same one-word paragraph twice), and
        /// after an edit the block we were on is still within a handful of rows
        /// of where it was. One linear pass per reload, and it stops as soon as
        /// no later row can be closer.
        private func nearestSignatureMatch(_ signature: String, near row: Int) -> Int? {
            var best: Int?
            var bestDistance = Int.max
            for (index, block) in blocks.enumerated() {
                // Past the anchor, distance only grows: nothing left can win.
                if index > row, index - row >= bestDistance { break }
                guard blockSignature(block) == signature else { continue }
                let distance = abs(index - row)
                if distance < bestDistance {
                    best = index
                    bestDistance = distance
                }
            }
            return best
        }

        // MARK: - Height reports (D3 "reported" rows)

        /// A placed `.reported` row measured itself. Bounded, converge-once
        /// feedback: the row's height does NOT influence the measurement (the
        /// hosted content is vertically `fixedSize`d), so applying the
        /// correction cannot produce another report.
        func reportHeight(blockId: String, height: CGFloat) {
            guard height > 0 else { return }
            guard let row = rowForBlockId[blockId], row < table.heights.count else { return }
            // Defensive: an exact row cannot know better than the measurer.
            guard row < table.kinds.count, table.kinds[row] == .reported else { return }
            guard abs(height - table.heights[row]) >= 0.5 else { return }

            // The coordinator's own table is patched SYNCHRONOUSLY so that a
            // second report for the same row in the same layout pass compares
            // against this value rather than against the estimate.
            var heights = table.heights
            heights[row] = height
            table = BlockHeightTable(heights: heights, kinds: table.kinds,
                                     contentWidth: table.contentWidth)

            // Everything that touches AppKit waits a turn. This runs from
            // `onPreferenceChange`, i.e. from INSIDE a SwiftUI layout pass, and
            // `noteHeightOfRows` + a clip-origin write both re-enter layout —
            // re-entrancy that AppKit does not promise to survive. One turn later
            // is soon enough: until then the row keeps showing the estimate,
            // which is what it was showing anyway.
            let reportedGeneration = generation
            DispatchQueue.main.async { [weak self] in
                guard let self, let tableView = self.tableView else { return }
                // The model may have been replaced (re-parse, re-measure) or this
                // block may sit at a different row by now.
                guard self.generation == reportedGeneration,
                      self.rowForBlockId[blockId] == row,
                      row < self.table.heights.count else {
                    #if DEBUG
                    listLog.debug("reportHeight: row \(row) (\(blockId, privacy: .public)) dropped — model changed")
                    #endif
                    return
                }
                let target = max(1, self.table.heights[row])
                // Delta against the height AppKit is CURRENTLY laying the row out
                // at, not against the value this particular report replaced:
                // several reports can coalesce into one turn, and the
                // compensation has to cancel the shift the table view is actually
                // about to make. `rect(ofRow:)` includes the intercell spacing
                // (see `rowContentRect`).
                let applied = tableView.rect(ofRow: row).height - tableView.intercellSpacing.height
                let delta = target - applied
                guard abs(delta) >= 0.5 else {
                    self.onHeightReport(blockId, row, target)
                    return
                }
                // A row whose top is above the top of the content area slides the
                // reader's content when it changes height — the row STRADDLING
                // the viewport top included, which is why this is geometry and
                // not `row < firstVisibleRow` (that row is "visible", yet growing
                // it pushes everything the reader can see downwards).
                let startsAboveViewport = tableView.rect(ofRow: row).minY < self.contentTopY()

                NSAnimationContext.beginGrouping()
                NSAnimationContext.current.duration = 0
                tableView.noteHeightOfRows(withIndexesChanged: IndexSet(integer: row))
                NSAnimationContext.endGrouping()

                if startsAboveViewport {
                    self.setContentTop(self.contentTopY() + delta, animated: false)
                }

                #if DEBUG
                listLog.debug("reportHeight: row \(row) (\(blockId, privacy: .public)) \(applied, format: .fixed(precision: 1)) → \(target, format: .fixed(precision: 1))\(startsAboveViewport ? " (compensated)" : "")")
                #endif

                // The parent holds the authoritative table (it feeds the next
                // install), so it has to learn the same number.
                self.onHeightReport(blockId, row, target)
            }
        }

        // MARK: - Programmatic scrolling (D6)

        func scroll(to request: ScrollRequest) {
            guard let tableView, let scrollView,
                  let row = rowForBlockId[request.blockId],
                  row < tableView.numberOfRows else { return }
            let target: CGFloat
            switch request.anchor {
            case .top:
                // Full row rect: with the reduced content inset this leaves the
                // same gap above the heading as the top of the document has.
                target = tableView.rect(ofRow: row).minY
            case .center:
                // Centre of the CONTENT area (between the insets), not of the
                // clip view — with equal top/bottom insets these coincide.
                let insets = scrollView.contentInsets
                let contentHeight = scrollView.contentView.bounds.height - insets.top - insets.bottom
                target = rowContentRect(row).midY - contentHeight / 2
            }
            #if DEBUG
            listLog.debug("scrollRequest: \(request.blockId, privacy: .public) row \(row) anchor=\(request.anchor == .top ? "top" : "center", privacy: .public) target=\(target, format: .fixed(precision: 1))")
            #endif
            setContentTop(target, animated: request.animated)
        }

        // MARK: - Scroll offset arithmetic
        //
        // One conversion, used by capture, restore, compensation and scrolling:
        // "document y of the top edge of the content area" ⇄ "clip view bounds
        // origin". Subtracting the document view's own frame origin keeps this
        // correct whether AppKit expresses the top content inset as a negative
        // clip origin or as an offset document view.

        private func contentTopY() -> CGFloat {
            guard let scrollView, let tableView else { return 0 }
            return scrollView.contentView.bounds.origin.y
                - tableView.frame.origin.y
                + scrollView.contentInsets.top
        }

        private func setContentTop(_ documentY: CGFloat, animated: Bool) {
            guard let scrollView, let tableView else { return }
            let clipView = scrollView.contentView
            let rawY = documentY + tableView.frame.origin.y - scrollView.contentInsets.top
            // AppKit's own clamp: honours the content insets, the document
            // height and the current elasticity, so there is no hand-rolled
            // bounds arithmetic to get wrong.
            let constrained = clipView.constrainBoundsRect(
                NSRect(origin: NSPoint(x: clipView.bounds.origin.x, y: rawY),
                       size: clipView.bounds.size)).origin
            #if DEBUG
            listLog.debug("setContentTop: documentY=\(documentY, format: .fixed(precision: 1)) tableOrigin=\(tableView.frame.origin.y, format: .fixed(precision: 1)) tableH=\(tableView.frame.height, format: .fixed(precision: 1)) clipOrigin=\(clipView.bounds.origin.y, format: .fixed(precision: 1)) clipH=\(clipView.bounds.height, format: .fixed(precision: 1)) insetTop=\(scrollView.contentInsets.top, format: .fixed(precision: 1)) rawY=\(rawY, format: .fixed(precision: 1)) constrained=\(constrained.y, format: .fixed(precision: 1)) animated=\(animated)")
            #endif
            guard abs(constrained.y - clipView.bounds.origin.y) > 0.01
                    || abs(constrained.x - clipView.bounds.origin.x) > 0.01 else { return }

            if animated {
                NSAnimationContext.runAnimationGroup({ context in
                    context.duration = 0.25
                    context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                    clipView.animator().setBoundsOrigin(constrained)
                }, completionHandler: { [weak scrollView] in
                    guard let scrollView else { return }
                    scrollView.reflectScrolledClipView(scrollView.contentView)
                })
                scrollView.reflectScrolledClipView(clipView)
            } else {
                clipView.scroll(to: constrained)
                scrollView.reflectScrolledClipView(clipView)
            }
        }

        // MARK: - contentWidth reporting (D4)

        /// The clip view's width, floored to whole points.
        ///
        /// The quantization is load-bearing, not cosmetic. Two different
        /// thresholds used to decide the same thing: the column moved on a 0.5 pt
        /// change while `contentWidth` was published on a 1 pt change, so a
        /// fractional clip width — routine, the sidebar's `DragGesture` produces
        /// them all day — could lay the cells out up to ~1.5 pt wider than the
        /// width the heights were measured at. Text then wraps one line further
        /// than the row is tall and overflows into the block below. Flooring both
        /// makes the two numbers move together by construction: the column can
        /// only change when a publish is also due, and layout width ==
        /// measurement width exactly.
        private func quantizedClipWidth() -> CGFloat {
            guard let scrollView else { return 0 }
            return floor(scrollView.contentView.bounds.width)
        }

        /// Keeps the single column exactly as wide as the visible content area,
        /// so `column.width` is the authoritative row width.
        private func syncColumnWidth() {
            guard let tableView, let column = tableView.tableColumns.first else { return }
            let available = quantizedClipWidth()
            guard available > 0, abs(column.width - available) > 0.5 else { return }
            column.width = available
        }

        /// The width a block view gets: the visible content width minus the
        /// horizontal padding the cell applies on both sides, capped in reading
        /// mode by `layoutStyle.maxContentWidth`.
        ///
        /// Read from the CLIP VIEW, not from the column, and 0 before the first
        /// layout: `NSTableColumn`'s default width is an arbitrary non-zero
        /// number, and publishing it would measure the whole document at a
        /// nonsense width — for a 10 000-line document, seconds of TextKit work
        /// for a table that is thrown away on the next frame. `syncColumnWidth`
        /// keeps the column equal to this, so the two never disagree.
        ///
        /// This is the ONE definition of the width the heights are measured at,
        /// and `rootView(for:)` expresses the same `min` as a SwiftUI frame — so
        /// layout width == measurement width by construction, at any clip width.
        private func currentContentWidth() -> CGFloat {
            let available = quantizedClipWidth()
            guard available > 0 else { return 0 }
            let inner = available - 2 * Metrics.contentHorizontalPadding
            guard let cap = layoutStyle.maxContentWidth else { return max(0, inner) }
            return max(0, floor(min(inner, cap)))
        }

        // MARK: - Layout style (reading mode)

        /// Reading mode came on or went off.
        ///
        /// Three things move together, and the order is the point:
        ///
        ///  1. the scroll view's end insets (24 pt ⇄ 48 pt),
        ///  2. the cells' layout width (`rootView(for:)` reads the new cap, so the
        ///     MATERIALIZED cells have to be re-hosted — the rest pick it up when
        ///     AppKit builds them),
        ///  3. the width the heights are measured at, published to the parent,
        ///     whose `HeightsIdentity` task re-measures and installs a new table.
        ///
        /// Between 2 and 3 the text re-wraps inside the previous row heights —
        /// the same transient a live resize has, and for the same reason (the
        /// re-measure is the expensive half). The anchor is captured before and
        /// restored after, because changing the top inset alone would slide the
        /// document by the difference.
        func applyLayoutStyle(_ style: LayoutStyle) {
            guard style != layoutStyle else { return }
            let anchor = captureAnchor()
            let previousInset = layoutStyle.edgeInset
            layoutStyle = style
            applyContentInsets()
            refreshMaterializedRootViews()
            if let anchor {
                if anchor.row == 0 {
                    // At the top the larger/smaller inset IS the visible change.
                    restore(anchor, previousCount: blocks.count)
                } else {
                    // Mid-document: keep the content visually still. Preserving
                    // `contentTopY` would shift everything by the inset delta
                    // (a 24 pt jolt on every toggle); keeping the raw clip origin
                    // means restoring the document offset minus that delta.
                    let delta = layoutStyle.edgeInset - previousInset
                    let top = tableView.map { $0.rect(ofRow: anchor.row).minY } ?? 0
                    setContentTop(top + anchor.offsetWithinRow - delta, animated: false)
                }
            }
            #if DEBUG
            listLog.debug("layoutStyle: cap=\(style.maxContentWidth.map { "\(Int($0))" } ?? "none", privacy: .public) padding=\(style.verticalPadding, format: .fixed(precision: 0))")
            #endif
            // Debounced like a resize, NOT immediate: leaving reading mode brings
            // the sidebars back through a 0.2 s animation, and an immediate
            // publish would measure the whole document at the still-sidebar-less
            // width and then again at the settled one. The re-arming debounce
            // collapses entry and exit to exactly one measure each.
            scheduleWidthReport()
        }

        private func applyContentInsets() {
            guard let scrollView else { return }
            let inset = layoutStyle.edgeInset
            scrollView.contentInsets = NSEdgeInsets(top: inset, left: 0, bottom: inset, right: 0)
        }

        private var isLiveResizing: Bool {
            guard let scrollView else { return false }
            return scrollView.inLiveResize || (scrollView.window?.inLiveResize ?? false)
        }

        private func clipFrameChanged(afterLiveResize: Bool) {
            // Always immediate — the text must re-wrap live while the user drags,
            // even though the (expensive) re-measure waits for the drag to settle.
            syncColumnWidth()
            guard isWired else { return }  // the first update picks the width up
            let width = currentContentWidth()
            guard width > 0 else { return }
            // First layout: the height table cannot be produced without a width,
            // so this one does not wait for the debounce.
            if reportedContentWidth == 0 {
                publish(width: width)
                return
            }
            guard abs(width - reportedContentWidth) >= 1 else { return }
            if afterLiveResize {
                publish(width: width)
                return
            }
            scheduleWidthReport()
        }

        /// Called from every `updateNSView`, but acts only in the one case the
        /// frame-change path cannot cover: a width that already existed before
        /// this coordinator was wired (a frame change between `makeNSView` and the
        /// first update, or a re-created representable). Without it the height
        /// table would never be measured and the document would stay blank.
        ///
        /// Deliberately NOT a general fast path: dragging the sidebar re-renders
        /// the parent on every frame while being no AppKit live resize at all, so
        /// publishing from here would re-measure the whole document per frame.
        func syncWidthIfNeeded(parentValue: CGFloat) {
            isWired = true
            syncColumnWidth()
            guard reportedContentWidth == 0 else { return }
            let width = currentContentWidth()
            guard width > 0, !isLiveResizing else { return }
            if abs(width - parentValue) >= 1 {
                publish(width: width)
            } else {
                // The parent already measured at this width (its state outlived
                // our AppKit views) — adopt it instead of re-publishing.
                reportedContentWidth = width
            }
        }

        /// 100 ms debounce; re-arms itself while a live resize is in progress so
        /// text re-wraps live inside the stale row heights and the (expensive)
        /// re-measure happens exactly once, when the drag settles.
        private func scheduleWidthReport() {
            widthWork?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                if self.isLiveResizing {
                    self.scheduleWidthReport()
                    return
                }
                let width = self.currentContentWidth()
                guard width > 0, abs(width - self.reportedContentWidth) >= 1 else { return }
                self.publish(width: width)
            }
            widthWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: work)
        }

        private func publish(width: CGFloat) {
            guard isWired else { return }
            widthWork?.cancel()
            widthWork = nil
            reportedContentWidth = width
            #if DEBUG
            listLog.debug("contentWidth: \(width, format: .fixed(precision: 1))")
            #endif
            // Never inside an AppKit layout pass — SwiftUI state, one turn later.
            DispatchQueue.main.async { [weak self] in self?.setContentWidth(width) }
        }

        // MARK: - Cell content

        /// The hosted SwiftUI tree for one row.
        ///
        /// `fixedSize(vertical:)` is load-bearing: it proposes an unspecified
        /// height to the block view, exactly as `ScrollView` used to, so
        /// resizable content (images, diagram snapshots) keeps its natural
        /// aspect instead of being squeezed into the row we guessed — and so a
        /// row's height can never influence the height reported for it.
        fileprivate func rootView(for row: Int) -> AnyView {
            let block = blocks[row]
            // `blockSpacing`, not 0: a block view whose body is a TUPLE — today
            // only `ImageBlockView` (image + italic alt caption) — has its
            // elements flattened into whatever stack contains it, and in 1.8.0
            // that stack was the document's `VStack(spacing: 8)`. Single-view
            // bodies, which is every other kind, are unaffected by the spacing.
            let base = VStack(alignment: .leading, spacing: Metrics.blockSpacing) {
                content(block)
            }
            // The hosting view is an environment boundary (same reason
            // `\.openURL` is re-injected in `MarkdownView.hostedBlockView`):
            // this is how a text view inside the cell finds the document
            // selection and learns which row it is, with no parameter threaded
            // through every block view.
            .environment(\.blockSelection, BlockSelectionContext(controller: selection, blockId: block.id))
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .fixedSize(horizontal: false, vertical: true)

            // The reading-mode column cap, expressed as a frame so that the LAYOUT
            // SYSTEM computes `min(clipWidth − 2 · padding, cap)` — the exact
            // expression `currentContentWidth()` publishes and the heights are
            // measured with. Baking the number into a padding instead would freeze
            // it at the width it had when this root view was built, and the clip
            // width moves without a rebuild all through a live resize: the cells
            // would then wrap at a width the row heights were never measured for
            // (and NSTableView does not clip its rows). The outer frame centres
            // the capped column; with no cap both frames take the full proposal
            // and change nothing, which is exactly the 1.8.0 geometry.
            //
            // The cap the CELLS use is never narrower than the width the installed
            // height table was measured at: entering reading mode narrows the
            // column only when the 720-measured table lands, so paragraphs never
            // wrap taller than their (still wide) rows and bleed into the block
            // below. Leaving lifts the cap at once — that only creates slack
            // inside rows, never overlap — and the re-measure closes it.
            let cellCap = cellColumnCap
            let column = base
                .frame(maxWidth: cellCap, alignment: .topLeading)
                .frame(maxWidth: .infinity, alignment: .center)

            let reports = row < table.kinds.count && table.kinds[row] == .reported
            if reports {
                return AnyView(
                    column
                        .modifier(RowHeightReporter(blockId: block.id, generation: generation,
                                                    report: { [weak self] id, height in
                                                        self?.reportHeight(blockId: id, height: height)
                                                    }))
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .padding(.horizontal, Metrics.contentHorizontalPadding)
                        .id(block.id)
                )
            }
            return AnyView(
                column
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(.horizontal, Metrics.contentHorizontalPadding)
                    .id(block.id)
            )
        }

        /// The widest the block column may lay out in a cell — see the reading-
        /// mode comment in `rootView(for:)`. Also the width of an atomic row's
        /// selection tint, so the tint covers the column and not the margins.
        private var cellColumnCap: CGFloat {
            let styleCap = layoutStyle.maxContentWidth ?? .infinity
            return table.contentWidth > 0 ? max(styleCap, table.contentWidth) : styleCap
        }

        /// Hands a cell everything about the document selection it draws itself:
        /// the column its tint spans and whether its row is tinted right now.
        private func configureSelectionTint(_ cell: BlockHostingCell, row: Int) {
            cell.selectionTintColumnCap = cellColumnCap
            cell.isSelectionTinted = selection.wantsTint(row: row)
        }

        /// D11 — re-host the MATERIALIZED rows with a freshly built root view.
        /// Rows AppKit has not built a cell for yet pick up the new closure when
        /// it does.
        ///
        /// `preparedContentRect` — not just `visibleRect` — because AppKit
        /// pre-materializes cells above and below the viewport (overdraw). Those
        /// cells exist with the OLD search term baked in, and scrolling them into
        /// view does not rebuild them, so a highlight would simply be missing
        /// until they left the prepared area and came back.
        func refreshMaterializedRootViews() {
            guard let tableView else { return }
            let area = tableView.preparedContentRect.union(tableView.visibleRect)
            let range = tableView.rows(in: area)
            guard range.length > 0 else { return }
            for row in range.location..<(range.location + range.length) {
                guard row >= 0, row < blocks.count else { continue }
                guard let cell = tableView.view(atColumn: 0, row: row,
                                                makeIfNecessary: false) as? BlockHostingCell else { continue }
                cell.hostingView.rootView = rootView(for: row)
                configureSelectionTint(cell, row: row)
            }
        }

        // MARK: - NSTableViewDataSource / Delegate

        func numberOfRows(in tableView: NSTableView) -> Int { blocks.count }

        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
            guard row >= 0, row < table.heights.count else { return 1 }
            // AppKit rejects non-positive row heights.
            return max(1, table.heights[row])
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?,
                       row: Int) -> NSView? {
            guard row >= 0, row < blocks.count else { return nil }
            let root = rootView(for: row)
            if let cell = tableView.makeView(withIdentifier: BlockHostingCell.reuseIdentifier,
                                             owner: self) as? BlockHostingCell {
                cell.hostingView.rootView = root
                configureSelectionTint(cell, row: row)
                return cell
            }
            let cell = BlockHostingCell(rootView: root)
            configureSelectionTint(cell, row: row)
            return cell
        }

        /// Rows are content, not choices — nothing is ever selected (D10).
        func tableView(_ tableView: NSTableView,
                       selectionIndexesForProposedSelection proposedSelectionIndexes: IndexSet) -> IndexSet {
            IndexSet()
        }

        func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }
    }
}

// MARK: - Height reporting

/// One row's natural height, tagged so a report is never mistaken for another's.
///
/// `generation` is why the tag matters: cells are REUSED, and
/// `onPreferenceChange` only fires when the value changes. Without the
/// generation, a row whose natural height happens to equal the value the
/// preference last carried would stay silent after a re-measure — and keep the
/// estimate. With it, every `.reported` row speaks exactly once per generation.
private struct RowHeightReport: Equatable {
    let blockId: String
    let generation: Int
    let height: CGFloat
}

private struct RowHeightPreferenceKey: PreferenceKey {
    static var defaultValue: RowHeightReport? { nil }
    static func reduce(value: inout RowHeightReport?, nextValue: () -> RowHeightReport?) {
        value = value ?? nextValue()
    }
}

/// Applied ONLY to `.reported` rows (`RowKind.reported`). Exact rows are laid
/// out by `BlockHeightMeasurer` with the real string at the real width; letting
/// them report would trade a known-exact number for a round trip.
private struct RowHeightReporter: ViewModifier {
    let blockId: String
    let generation: Int
    let report: (String, CGFloat) -> Void

    func body(content: Content) -> some View {
        content
            .background(
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: RowHeightPreferenceKey.self,
                        value: RowHeightReport(blockId: blockId, generation: generation,
                                               height: proxy.size.height))
                }
            )
            .onPreferenceChange(RowHeightPreferenceKey.self) { value in
                guard let value, value.height > 0 else { return }
                report(value.blockId, value.height)
            }
    }
}

// MARK: - Scroll view

/// Only reason for the subclass: an immediate, non-debounced content-width
/// report when a window resize finishes, so the re-measure lands within a frame
/// or two of the user letting go instead of waiting out the debounce.
final class BlockScrollView: NSScrollView {
    var onEndLiveResize: (() -> Void)?
    /// Clicks in the content insets above the first / below the last row land
    /// on the clip view, whose responder chain ends here, not at the table —
    /// they still belong to the document (a click there clears the selection,
    /// a drag from there selects).
    weak var selectionController: SelectionController?

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        onEndLiveResize?()
    }

    override func mouseDown(with event: NSEvent) {
        guard let selectionController else {
            super.mouseDown(with: event)
            return
        }
        selectionController.mouseDown(with: event)
    }
}

// MARK: - Table view

/// Keyboard scrolling (D10).
///
/// Two reasons this is hand-rolled rather than delegated to AppKit:
///
///  * `NSTableView` would otherwise spend these keys on row selection and
///    type-select, and it does not implement any scrolling action itself.
///  * `NSScrollView` does not implement the `NSStandardKeyBindingResponding`
///    scroll actions either — measured on macOS 15, `responds(to:)` is false for
///    `scrollPageDown:`, `scrollPageUp:`, `scrollLineDown:`, `scrollLineUp:`,
///    `scrollToBeginningOfDocument:` and `scrollToEndOfDocument:`; calling them
///    would raise an unrecognised selector. `pageDown:`/`pageUp:` do exist but
///    were measured to be no-ops on a programmatic call.
///
/// So the distances come from the scroll view's own metrics
/// (`verticalPageScroll` is the page OVERLAP, `verticalLineScroll` the arrow-key
/// step) and the clip view is moved through `constrainBoundsRect`, which is the
/// same clamp AppKit applies to a wheel scroll.
///
/// Since v1.11 the table is THE document's first responder (S-D4): a click
/// anywhere in the document — text included, because the text views refuse
/// first responder — lands focus here, so these keys, ⌘C and ⌘A all reach it.
final class BlockTableView: NSTableView {

    override var acceptsFirstResponder: Bool { true }

    /// The document selection. Weak: the coordinator owns it.
    weak var selectionController: SelectionController?

    // MARK: Document selection (S-D4 / S-D6)

    /// Clicks in the inter-row gaps and margins, and clicks on rows whose
    /// SwiftUI content does not consume them (`NSHostingView` forwards an
    /// unhandled `mouseDown` up the responder chain to here — verified). The
    /// same tracking loop as a click on text. Never `super`: NSTableView's own
    /// tracking would run row selection, which this table never has (D10).
    override func mouseDown(with event: NSEvent) {
        guard let selectionController else {
            super.mouseDown(with: event)
            return
        }
        selectionController.mouseDown(with: event)
    }

    /// Not `super`: NSTableView outlines the clicked row while a context menu
    /// is open ("menu row highlighting") — a list affordance, not a document's.
    override func rightMouseDown(with event: NSEvent) {
        guard let selectionController else {
            super.rightMouseDown(with: event)
            return
        }
        NSMenu.popUpContextMenu(selectionController.contextMenu(for: event), with: event, for: self)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let selectionController else { return super.menu(for: event) }
        return selectionController.contextMenu(for: event)
    }

    /// Edit ▸ Copy (⌘C) and the context menu's Copy: the document selection.
    @objc func copy(_ sender: Any?) {
        selectionController?.copySelection()
    }

    /// Edit ▸ Select All (⌘A): the whole document, not every row of a list.
    override func selectAll(_ sender: Any?) {
        guard let selectionController else {
            super.selectAll(sender)
            return
        }
        selectionController.selectAll()
    }

    /// Edit ▸ Speech ▸ Start Speaking: reads the document selection.
    @objc func startSpeaking(_ sender: Any?) {
        selectionController?.startSpeaking()
    }

    @objc func stopSpeaking(_ sender: Any?) {
        selectionController?.stopSpeaking()
    }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        guard let selectionController else { return super.validateUserInterfaceItem(item) }
        switch item.action {
        case #selector(copy(_:)), #selector(startSpeaking(_:)):
            return selectionController.hasSelection
        case #selector(stopSpeaking(_:)):
            return selectionController.isSpeaking
        case #selector(selectAll(_:)):
            return numberOfRows > 0
        default:
            return super.validateUserInterfaceItem(item)
        }
    }

    // MARK: Services (app menu ▸ Services on the selection)

    /// Offers the selection to services that take text and return nothing
    /// (Look Up in Dictionary, New Note, Search with …). Read-only document:
    /// services that REPLACE the selection are not offered.
    override func validRequestor(forSendType sendType: NSPasteboard.PasteboardType?,
                                 returnType: NSPasteboard.PasteboardType?) -> Any? {
        if let selectionController, selectionController.hasSelection, returnType == nil,
           let sendType, sendType == .string || sendType == .rtf {
            return self
        }
        return super.validRequestor(forSendType: sendType, returnType: returnType)
    }

    // MARK: Initial focus (S-D4)

    /// A freshly opened (or re-hosted) document has nothing focused — the
    /// window itself is first responder — so ⌘A/⌘C would be dead until the
    /// first click. Take focus then, and only then: never from the search
    /// field or any other control that already has it.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        DispatchQueue.main.async { [weak self] in self?.takeFocusIfWindowHasNone() }
    }

    func takeFocusIfWindowHasNone() {
        guard let window, window.isKeyWindow, window.attachedSheet == nil else { return }
        let current = window.firstResponder
        guard current == nil || current === window else { return }
        window.makeFirstResponder(self)
    }

    override func keyDown(with event: NSEvent) {
        guard enclosingScrollView != nil else {
            super.keyDown(with: event)
            return
        }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        // ⌘/⌥/⌃ combinations belong to menus and text views, not to scrolling.
        guard flags.isDisjoint(with: [.command, .option, .control]) else {
            super.keyDown(with: event)
            return
        }

        switch event.keyCode {
        case 121:  // Page Down
            scrollVertically(by: pageDistance)
        case 116:  // Page Up
            scrollVertically(by: -pageDistance)
        case 115:  // Home
            scrollVertically(by: -Self.toTheEnd)
        case 119:  // End
            scrollVertically(by: Self.toTheEnd)
        case 125:  // ↓
            scrollVertically(by: lineDistance)
        case 126:  // ↑
            scrollVertically(by: -lineDistance)
        case 123, 124:  // ← → : the document never scrolls horizontally
            return
        case 49:  // Space / ⇧Space
            scrollVertically(by: flags.contains(.shift) ? -pageDistance : pageDistance)
        default:
            super.keyDown(with: event)
        }
    }

    /// Far enough that `constrainBoundsRect` lands exactly on the document edge.
    private static let toTheEnd: CGFloat = 1e7

    private var pageDistance: CGFloat {
        guard let scrollView = enclosingScrollView else { return 0 }
        // `verticalPageScroll` is the overlap AppKit keeps between pages.
        return max(1, scrollView.contentView.bounds.height - scrollView.verticalPageScroll)
    }

    private var lineDistance: CGFloat {
        enclosingScrollView?.verticalLineScroll ?? 10
    }

    func scrollVertically(by dy: CGFloat) {
        guard let scrollView = enclosingScrollView else { return }
        let clipView = scrollView.contentView
        let proposed = NSRect(origin: NSPoint(x: clipView.bounds.origin.x,
                                             y: clipView.bounds.origin.y + dy),
                              size: clipView.bounds.size)
        let target = clipView.constrainBoundsRect(proposed).origin
        guard abs(target.y - clipView.bounds.origin.y) > 0.01 else { return }
        clipView.scroll(to: target)
        scrollView.reflectScrolledClipView(clipView)
    }
}

extension BlockTableView: NSServicesMenuRequestor {
    /// Services receive the same plain text + RTF as ⌘C (one builder).
    func writeSelection(to pboard: NSPasteboard, types: [NSPasteboard.PasteboardType]) -> Bool {
        guard let output = selectionController?.selectionOutput() else { return false }
        let wanted = types.filter { $0 == .string || $0 == .rtf }
        guard !wanted.isEmpty else { return false }
        pboard.declareTypes(wanted, owner: nil)
        var wrote = false
        if wanted.contains(.string) {
            wrote = pboard.setString(output.plain, forType: .string) || wrote
        }
        if wanted.contains(.rtf),
           let data = try? output.rtf.data(from: NSRange(location: 0, length: output.rtf.length),
                                           documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]) {
            wrote = pboard.setData(data, forType: .rtf) || wrote
        }
        return wrote
    }
}

// MARK: - Cell

/// One row = one `NSHostingView` over the block's SwiftUI view (D2).
///
/// `sizingOptions = []` and a manual frame: the row height comes from the
/// measured `BlockHeightTable`, so the hosting view must not derive its own size
/// from the content (that is the feedback loop this whole design exists to
/// avoid).
final class BlockHostingCell: NSTableCellView {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("QMDBlockCell")

    let hostingView: NSHostingView<AnyView>
    /// Created on first use: most rows are never tinted.
    private var tintView: SelectionTintView?

    /// Whether the document selection covers this row and the row cannot draw
    /// the selection itself (atomic rows — S-D3 — and text rows with no text
    /// view to draw in). Set by the coordinator / selection controller.
    var isSelectionTinted = false {
        didSet {
            guard isSelectionTinted != oldValue else { return }
            if isSelectionTinted {
                if tintView == nil {
                    let tint = SelectionTintView()
                    addSubview(tint, positioned: .above, relativeTo: hostingView)
                    tintView = tint
                }
                tintView?.isHidden = false
                needsLayout = true
            } else {
                tintView?.isHidden = true
            }
        }
    }

    /// The widest the block column gets (reading mode caps it; `.infinity`
    /// otherwise) — the tint covers the column, not the side margins.
    var selectionTintColumnCap: CGFloat = .infinity {
        didSet { if selectionTintColumnCap != oldValue { needsLayout = true } }
    }

    init(rootView: AnyView) {
        hostingView = NSHostingView(rootView: rootView)
        super.init(frame: .zero)
        identifier = Self.reuseIdentifier
        hostingView.sizingOptions = []
        hostingView.translatesAutoresizingMaskIntoConstraints = true
        hostingView.autoresizingMask = [.width, .height]
        addSubview(hostingView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layout() {
        super.layout()
        hostingView.frame = bounds
        if let tintView, !tintView.isHidden {
            // Same geometry `rootView(for:)` gives the content: the horizontal
            // padding on both sides, then the column cap, centred.
            let padding = BlockLayout.Document.contentHorizontalPadding
            let width = max(0, min(bounds.width - 2 * padding, selectionTintColumnCap))
            tintView.frame = NSRect(x: (bounds.width - width) / 2, y: 0,
                                    width: width, height: bounds.height)
        }
    }

    /// Repaint after the window's key state changed (emphasized ⇄ unemphasized).
    func redrawSelectionTint() {
        tintView?.needsDisplay = true
    }
}

/// The highlight over a selected atomic row (S-D3): the selection colour at a
/// third of its strength, so the table / image / diagram stays readable under it.
///
/// Drawn in AppKit, above the hosted SwiftUI content — and invisible to the
/// mouse: `hitTest` answers nil, so the Mermaid diagram's transparent preview
/// button and an image's click-to-enlarge receive their clicks exactly as
/// without a selection.
final class SelectionTintView: NSView {
    static let alpha: CGFloat = 0.35

    override var isOpaque: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let base = (window?.isKeyWindow ?? false)
            ? NSColor.selectedTextBackgroundColor
            : NSColor.unemphasizedSelectedTextBackgroundColor
        base.withAlphaComponent(Self.alpha).setFill()
        dirtyRect.intersection(bounds).fill(using: .sourceOver)
    }
}

// MARK: - Document selection (v1.11 S-D2 … S-D6, S-D11)

/// What a text view inside a cell needs to join the document selection: the
/// controller, and the block its row shows.
///
/// Travels through the SwiftUI environment (`rootView(for:)` injects it at the
/// hosting view, an environment boundary), so the block views need no new
/// parameters — any `SelfSizingTextView` in a cell registers itself under the
/// cell's block id, whatever block view hosts it.
struct BlockSelectionContext: Equatable {
    weak var controller: SelectionController?
    let blockId: String

    /// Identity, not value: a root view rebuilt for the same row (search
    /// highlighting, reading mode) must not look like a change to SwiftUI.
    static func == (lhs: BlockSelectionContext, rhs: BlockSelectionContext) -> Bool {
        lhs.controller === rhs.controller && lhs.blockId == rhs.blockId
    }
}

private struct BlockSelectionKey: EnvironmentKey {
    static let defaultValue: BlockSelectionContext? = nil
}

extension EnvironmentValues {
    /// Set per row by `VirtualBlockList.Coordinator.rootView(for:)`; nil outside
    /// the document list (print/PDF views, previews).
    var blockSelection: BlockSelectionContext? {
        get { self[BlockSelectionKey.self] }
        set { self[BlockSelectionKey.self] = newValue }
    }
}

/// The document's ONE selection and everything that edits, draws and copies it
/// (S-D4). Owned by `VirtualBlockList.Coordinator`; main-thread only (every
/// entry point is an AppKit event, a menu action or a representable update).
///
/// Why one controller and not N native selections: a selection spans rows,
/// rows are cells that come and go, and only one view can be first responder
/// — so a native selection lives in one view, dies with it on reuse, and
/// renders inactive (grey) everywhere else. Here the selection is a value
/// (`DocumentSelection`), the table is the first responder, and each
/// materialized text view draws the part of the selection that falls inside it.
final class SelectionController: NSObject {

    // MARK: Inputs (refreshed by every `updateNSView`)

    /// See `VirtualBlockList.selectableText`.
    var selectableText: (MarkdownBlock, Int) -> NSAttributedString? = { _, _ in nil }
    /// See `VirtualBlockList.onCopySelection`.
    var onCopy: (DocumentCopyOutput) -> Void = { _ in }

    // MARK: Model

    private(set) var selection: DocumentSelection?
    private var blocks: [MarkdownBlock] = []
    private var rowForBlockId: [String: Int] = [:]
    private var contentVersion = Int.min
    /// Selectable-string length per row, for rows measured without a view
    /// (headings today, any off-screen row). Valid for one content version.
    private var lengthCache: [Int: Int] = [:]

    var hasSelection: Bool { !(selection?.isEmpty ?? true) }

    // MARK: AppKit

    private weak var tableView: BlockTableView?

    private final class WeakTextView {
        weak var view: SelfSizingTextView?
        init(_ view: SelfSizingTextView) { self.view = view }
    }

    /// blockId → the text view currently showing that block. Only MATERIALIZED
    /// rows are here, which is what bounds every redraw to the rows on (or
    /// just off) screen.
    private var registry: [String: WeakTextView] = [:]
    private var keyObservers: [NSObjectProtocol] = []

    deinit {
        keyObservers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    func attach(tableView: BlockTableView) {
        self.tableView = tableView
        guard keyObservers.isEmpty else { return }
        // Emphasized (key window) ⇄ unemphasized selection colour. Filtered by
        // window: tabs are separate windows, each with its own controller.
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            keyObservers.append(NotificationCenter.default.addObserver(
                forName: name, object: nil, queue: nil
            ) { [weak self] note in
                guard let self, let window = note.object as? NSWindow,
                      window === self.tableView?.window else { return }
                self.redrawForKeyChange()
                if note.name == NSWindow.didBecomeKeyNotification {
                    // A tab brought to the front with nothing focused: give the
                    // document the keyboard (never taken from a control).
                    self.tableView?.takeFocusIfWindowHasNone()
                }
            })
        }
    }

    /// A new model was installed in the list (before `reloadData`).
    ///
    /// S-D11: a new content version (re-parse — reload, zoom, theme, fonts)
    /// clears the selection, because its offsets point into the OLD strings.
    /// A width-only reinstall (resize, reading mode, sidebars) keeps it: same
    /// blocks, same strings, the offsets are still valid — only the wrap moved.
    func install(blocks newBlocks: [MarkdownBlock], rowForBlockId newRows: [String: Int],
                 contentVersion newVersion: Int) {
        let sameContent = newVersion == contentVersion && newBlocks.count == blocks.count
        blocks = newBlocks
        rowForBlockId = newRows
        contentVersion = newVersion
        guard !sameContent else { return }
        lengthCache = [:]
        guard selection != nil else { return }
        selection = nil
        // Text views only: the cells' tints are reconfigured by the
        // `reloadData` that follows (the table's row geometry is still the old
        // one at this point, so it is not asked about rows here).
        refreshTextViews()
    }

    // MARK: - Registry (S-D5)

    func register(_ view: SelfSizingTextView, blockId: String) {
        if registry.count > 256 { registry = registry.filter { $0.value.view != nil } }
        registry[blockId] = WeakTextView(view)
        // The row may have been tinted while it had no view to draw in. With
        // nothing selected no cell is tinted, so the table is not even asked —
        // this runs inside SwiftUI updates that the table's own tiling drives.
        if hasSelection, let row = rowForBlockId[blockId] { refreshTint(row: row) }
    }

    func unregister(_ view: SelfSizingTextView, blockId: String) {
        guard registry[blockId]?.view === view else { return }
        registry[blockId] = nil
        if hasSelection, let row = rowForBlockId[blockId] { refreshTint(row: row) }
    }

    /// The part of `view`'s string the selection covers (S-D5). Asked by the
    /// view itself whenever it is created or its string is replaced.
    func coveredRange(for view: SelfSizingTextView) -> NSRange? {
        guard let selection, let blockId = view.selectionBlockId,
              let row = rowForBlockId[blockId] else { return nil }
        return selection.range(inRow: row, rowLength: view.selectionTextLength)
    }

    /// Whether `row`'s cell shows the AppKit tint: the selection covers it and
    /// the row has no text view to draw the selection in — atomic rows
    /// (S-D3), and text-kind rows whose text is not an NSTextView (headings
    /// until they become one, S-D7). A row that gains a registered text view
    /// drops the tint by itself (`register`).
    func wantsTint(row: Int) -> Bool {
        guard let selection, !selection.isEmpty, row >= 0, row < blocks.count else { return false }
        let block = blocks[row]
        if Self.isAtomic(block) { return selection.range(inRow: row, rowLength: 1) != nil }
        if let view = registry[block.id]?.view, view.selectionController === self { return false }
        return selection.range(inRow: row, rowLength: rowLength(row)) != nil
    }

    // MARK: - Editing the selection

    private func setSelection(_ newValue: DocumentSelection?) {
        guard newValue != selection else { return }
        selection = newValue
        refreshTextViews()
        refreshTints()
    }

    /// Hands every registered text view its covered range. A view whose range
    /// did not change does not redraw (`selectionCoveredRange.didSet`), so a
    /// drag repaints only the rows whose coverage actually moved.
    private func refreshTextViews() {
        for box in registry.values {
            guard let view = box.view else { continue }
            view.selectionCoveredRange = coveredRange(for: view)
        }
    }

    /// Materialized cells only — `preparedContentRect` included, because AppKit
    /// keeps cells above and below the viewport that scroll in without being
    /// configured again (same reason as `refreshMaterializedRootViews`).
    private func refreshTints() {
        forEachMaterializedCell { cell, row in cell.isSelectionTinted = wantsTint(row: row) }
    }

    private func refreshTint(row: Int) {
        guard let tableView, row >= 0, row < tableView.numberOfRows, row < blocks.count,
              let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? BlockHostingCell
        else { return }
        cell.isSelectionTinted = wantsTint(row: row)
    }

    private func forEachMaterializedCell(_ body: (BlockHostingCell, Int) -> Void) {
        guard let tableView, tableView.numberOfRows > 0 else { return }
        let range = tableView.rows(in: tableView.preparedContentRect.union(tableView.visibleRect))
        guard range.length > 0 else { return }
        for row in range.location..<NSMaxRange(range) where row >= 0 && row < blocks.count {
            guard let cell = tableView.view(atColumn: 0, row: row,
                                            makeIfNecessary: false) as? BlockHostingCell else { continue }
            body(cell, row)
        }
    }

    private func redrawForKeyChange() {
        guard hasSelection else { return }
        for box in registry.values where box.view?.selectionCoveredRange != nil {
            box.view?.needsDisplay = true
        }
        forEachMaterializedCell { cell, _ in cell.redrawSelectionTint() }
    }

    // MARK: - Rows

    /// Rows selected whole, with no text of their own to select (S-D3).
    static func isAtomic(_ block: MarkdownBlock) -> Bool {
        switch block.content {
        case .table, .image, .svgImage, .mathBlock, .mermaidDiagram: return true
        case .text, .codeBlock, .blockquote, .alert, .heading: return false
        }
    }

    /// UTF-16 length of `row`'s selectable string (1 for an atomic row).
    private func rowLength(_ row: Int) -> Int {
        guard row >= 0, row < blocks.count else { return 0 }
        let block = blocks[row]
        if Self.isAtomic(block) { return 1 }
        if let cached = lengthCache[row] { return cached }
        let length = selectableText(block, contentVersion)?.length ?? 0
        lengthCache[row] = length
        return length
    }

    // MARK: - Keyboard / menu (S-D4)

    /// ⌘A. Two points, so the cost does not depend on the document's size.
    func selectAll() {
        setSelection(DocumentSelection.selectAll(rowCount: blocks.count, lengths: rowLength))
    }

    /// `range` of `view`'s row becomes the document selection (AX setter).
    func select(_ range: NSRange, in view: SelfSizingTextView) {
        guard let blockId = view.selectionBlockId, let row = rowForBlockId[blockId] else { return }
        let length = view.selectionTextLength
        let lower = min(max(0, range.location), length)
        let upper = min(max(lower, NSMaxRange(range)), length)
        setSelection(DocumentSelection(anchor: SelectionPoint(row: row, offset: lower),
                                       focus: SelectionPoint(row: row, offset: upper)))
    }

    /// ⌘C: exactly what is highlighted, built from the selectable strings — not
    /// from the views, most of which do not exist for a large selection.
    func copySelection() {
        guard let output = selectionOutput() else { return }
        onCopy(output)
    }

    // MARK: Speech (Edit ▸ Speech)

    private lazy var speech = AVSpeechSynthesizer()

    var isSpeaking: Bool { speech.isSpeaking }

    func startSpeaking() {
        guard let text = selectionOutput()?.plain else { return }
        speech.stopSpeaking(at: .immediate)
        speech.speak(AVSpeechUtterance(string: text))
    }

    func stopSpeaking() {
        speech.stopSpeaking(at: .immediate)
    }

    /// Plain text + RTF of the selection — the ONE builder behind ⌘C, the
    /// context menu, Services and Speech. Nil when nothing is selected.
    func selectionOutput() -> DocumentCopyOutput? {
        guard let selection, let span = selection.rowSpan else { return nil }
        var pieces: [SelectionPiece] = []
        pieces.reserveCapacity(span.count)
        // Table cells: their rendered characters (no `**`). The characters do
        // not depend on the theme, so any theme will do.
        var cellRenderer: MarkdownRenderer?
        func renderedCell(_ markdown: String) -> String {
            let renderer = cellRenderer ?? MarkdownRenderer(theme: MarkdownTheme.cached(for: .light))
            cellRenderer = renderer
            return String(renderer.renderInline(markdown).characters)
        }

        for row in span where row < blocks.count {
            let block = blocks[row]
            switch block.content {
            case .table(let headers, let rows, _):
                guard selection.range(inRow: row, rowLength: 1) != nil else { continue }
                // Same rule as `TableBlockView.showsHeader`: an all-blank header
                // row is not shown, so it is not copied either.
                let showsHeader = headers.contains { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                pieces.append(.table(headers: showsHeader ? headers.map(renderedCell) : nil,
                                     rows: rows.map { $0.map(renderedCell) }))
            case .image(_, let alt):
                guard selection.range(inRow: row, rowLength: 1) != nil else { continue }
                pieces.append(.image(alt: alt))
            case .svgImage:
                guard selection.range(inRow: row, rowLength: 1) != nil else { continue }
                pieces.append(.image(alt: ""))
            case .mathBlock(let latex):
                guard selection.range(inRow: row, rowLength: 1) != nil else { continue }
                pieces.append(.displayMath(latex: latex))
            case .mermaidDiagram(let source):
                guard selection.range(inRow: row, rowLength: 1) != nil else { continue }
                pieces.append(.mermaid(source: source))
            case .codeBlock, .text, .blockquote, .alert, .heading:
                guard let text = selectableText(block, contentVersion),
                      let covered = selection.range(inRow: row, rowLength: text.length) else { continue }
                let part = text.attributedSubstring(from: covered)
                if case .codeBlock = block.content {
                    pieces.append(.code(part))
                } else {
                    pieces.append(.text(part))
                }
            }
        }
        let output = DocumentCopyBuilder.build(pieces)
        return output.plain.isEmpty ? nil : output
    }

    /// Right-click / Control-click anywhere in the document (S-D6): the
    /// document's Copy and Select All — not NSTextView's editing menu, whose
    /// Copy would only know about one row.
    func contextMenu(for event: NSEvent) -> NSMenu {
        if let tableView, let window = tableView.window, window.firstResponder !== tableView {
            window.makeFirstResponder(tableView)
        }
        let menu = NSMenu()
        if let lookUp = lookUpItem(for: event) {
            menu.addItem(lookUp)
            menu.addItem(.separator())
        }
        // Explicit target: validation then asks the table (Copy is enabled iff
        // the selection is non-empty), whatever else is first responder.
        let copy = NSMenuItem(title: "Copy", action: #selector(BlockTableView.copy(_:)), keyEquivalent: "")
        copy.target = tableView
        menu.addItem(copy)
        let all = NSMenuItem(title: "Select All", action: #selector(BlockTableView.selectAll(_:)), keyEquivalent: "")
        all.target = tableView
        menu.addItem(all)
        return menu
    }

    private final class LookUpRequest {
        weak var textView: SelfSizingTextView?
        let range: NSRange
        init(textView: SelfSizingTextView, range: NSRange) {
            self.textView = textView
            self.range = range
        }
    }

    /// "Look Up “word”" for the word under the pointer, when it is over text.
    private func lookUpItem(for event: NSEvent) -> NSMenuItem? {
        guard let hit = hit(atWindowPoint: event.locationInWindow),
              let textView = hit.textView, let local = hit.pointInTextView,
              let index = Self.characterIndex(in: textView, at: local, requireInside: true),
              let storage = textView.textStorage else { return nil }
        let word = textView.selectionRange(forProposedRange: NSRange(location: index, length: 0),
                                           granularity: .selectByWord)
        guard word.length > 0, NSMaxRange(word) <= storage.length else { return nil }
        let text = (storage.string as NSString).substring(with: word)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 64,
              !text.unicodeScalars.contains(where: { $0 == "\u{FFFC}" }) else { return nil }
        let item = NSMenuItem(title: "Look Up \u{201C}\(text)\u{201D}",
                              action: #selector(lookUp(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = LookUpRequest(textView: textView, range: word)
        return item
    }

    @objc private func lookUp(_ sender: NSMenuItem) {
        guard let request = sender.representedObject as? LookUpRequest,
              let textView = request.textView, let storage = textView.textStorage,
              let layoutManager = textView.layoutManager,
              NSMaxRange(request.range) <= storage.length else { return }
        let glyphs = layoutManager.glyphRange(forCharacterRange: request.range, actualCharacterRange: nil)
        guard glyphs.length > 0 else { return }
        let line = layoutManager.lineFragmentRect(forGlyphAt: glyphs.location, effectiveRange: nil)
        let location = layoutManager.location(forGlyphAt: glyphs.location)
        let origin = textView.textContainerOrigin
        textView.showDefinition(for: storage.attributedSubstring(from: request.range),
                                at: NSPoint(x: origin.x + line.minX + location.x,
                                            y: origin.y + line.minY + location.y))
    }

    // MARK: - Hit testing (S-D6)

    private struct Hit {
        let point: SelectionPoint
        /// The press landed inside an atomic row (see `DocumentSelection.dragging`).
        let isAtomic: Bool
        /// The row's text view, when the point maps through one.
        let textView: SelfSizingTextView?
        let pointInTextView: NSPoint?
    }

    /// Maps a window point to a document position THROUGH THE TABLE: row under
    /// the point → that row's registered text view → insertion index. Never
    /// through the view that received the mouse-down, which a drag can scroll
    /// out of the prepared area and the table can recycle for another row.
    ///
    /// Points between rows belong to a row (`rect(ofRow:)` includes half the
    /// intercell spacing on each side); points above or below a row's text
    /// (the gap, an alert's title, a code block's padding) map to the start or
    /// the end of that text; points left or right of it to the line's start or
    /// end. Above the first row / below the last: the document's ends.
    private func hit(atWindowPoint windowPoint: NSPoint) -> Hit? {
        guard let tableView, !blocks.isEmpty, tableView.numberOfRows == blocks.count else { return nil }
        let point = tableView.convert(windowPoint, from: nil)
        let probeX = min(max(point.x, 0), max(0, tableView.bounds.width - 1))
        let row = tableView.row(at: NSPoint(x: probeX, y: point.y))
        guard row >= 0, row < blocks.count else {
            if point.y < tableView.rect(ofRow: 0).minY {
                return Hit(point: SelectionPoint(row: 0, offset: 0), isAtomic: false,
                           textView: nil, pointInTextView: nil)
            }
            let last = blocks.count - 1
            return Hit(point: SelectionPoint(row: last, offset: rowLength(last)), isAtomic: false,
                       textView: nil, pointInTextView: nil)
        }

        let block = blocks[row]
        let rowRect = tableView.rect(ofRow: row)
        if Self.isAtomic(block) {
            // Upper half = before the row, lower half = after it: dragging
            // DOWN selects the row once the pointer is past its middle, and so
            // does dragging UP — symmetrical, like a very tall character.
            return Hit(point: SelectionPoint(row: row, offset: point.y < rowRect.midY ? 0 : 1),
                       isAtomic: true, textView: nil, pointInTextView: nil)
        }

        if let textView = registeredTextView(for: block.id, in: tableView) {
            let local = textView.convert(windowPoint, from: nil)  // flipped
            let length = textView.selectionTextLength
            let offset: Int
            if local.y < 0 {
                offset = 0
            } else if local.y > textView.bounds.height {
                offset = length
            } else {
                let clamped = NSPoint(x: min(max(local.x, 0), textView.bounds.width), y: local.y)
                offset = min(max(0, textView.characterIndexForInsertion(at: clamped)), length)
            }
            return Hit(point: SelectionPoint(row: row, offset: offset), isAtomic: false,
                       textView: textView, pointInTextView: local)
        }

        // A text-kind row with no text view to ask (a heading today): its
        // whole string, by half.
        return Hit(point: SelectionPoint(row: row, offset: point.y < rowRect.midY ? 0 : rowLength(row)),
                   isAtomic: false, textView: nil, pointInTextView: nil)
    }

    /// The registered view for `blockId` — if it is really on display in THIS
    /// table (a recycled view can outlive its registration by a layout pass).
    private func registeredTextView(for blockId: String, in tableView: NSTableView) -> SelfSizingTextView? {
        guard let view = registry[blockId]?.view, view.selectionController === self,
              view.window === tableView.window, !view.isHiddenOrHasHiddenAncestor,
              view.isDescendant(of: tableView) else { return nil }
        return view
    }

    /// The character whose glyph is under `local` (text-view coordinates), or
    /// nil past the end. With `requireInside`, only when the point is ON the
    /// glyph — a click in the empty space after a link must not open it.
    private static func characterIndex(in textView: SelfSizingTextView, at local: NSPoint,
                                       requireInside: Bool) -> Int? {
        guard let layoutManager = textView.layoutManager, let container = textView.textContainer,
              textView.selectionTextLength > 0 else { return nil }
        let origin = textView.textContainerOrigin
        let point = NSPoint(x: local.x - origin.x, y: local.y - origin.y)
        var fraction: CGFloat = 0
        let glyph = layoutManager.glyphIndex(for: point, in: container,
                                             fractionOfDistanceThroughGlyph: &fraction)
        guard glyph < layoutManager.numberOfGlyphs else { return nil }
        if requireInside {
            let box = layoutManager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1),
                                                 in: container)
            guard box.contains(point) else { return nil }
        }
        let index = layoutManager.characterIndexForGlyph(at: glyph)
        return index < textView.selectionTextLength ? index : nil
    }

    // MARK: - Mouse (S-D6)

    /// Pointer travel below which a press-release is a click, not a drag.
    private static let dragThreshold: CGFloat = 3

    /// The ONE tracking loop, for a press anywhere in the document: on text
    /// (`SelfSizingTextView.mouseDown`), in a gap, a margin or a row whose
    /// content did not consume the click (`BlockTableView.mouseDown`), or in
    /// the content insets (`BlockScrollView.mouseDown`).
    ///
    /// Everything it touches is re-resolved per event through `tableView`
    /// (weak) and the registry: the view that received the press may be
    /// recycled for another row by an autoscroll halfway through the drag.
    func mouseDown(with event: NSEvent) {
        guard let tableView, let window = tableView.window else { return }
        // S-D4: a click anywhere makes the table the first responder, so ⌘C
        // works after clicking a gap (it used to be disabled there).
        if window.firstResponder !== tableView { window.makeFirstResponder(tableView) }
        if event.modifierFlags.contains(.control) {
            NSMenu.popUpContextMenu(contextMenu(for: event), with: event, for: tableView)
            return
        }
        guard let start = hit(atWindowPoint: event.locationInWindow) else { return }

        let clickCount = event.clickCount
        let isExtending = event.modifierFlags.contains(.shift) && selection != nil
        var anchor = start.point
        var anchorIsAtomic = start.isAtomic
        var unit: (start: SelectionPoint, end: SelectionPoint)?

        if isExtending, let existing = selection {
            // Shift-click: the focus moves, the anchor stays where it was.
            anchor = existing.anchor
            anchorIsAtomic = false
            setSelection(DocumentSelection(anchor: anchor, focus: start.point))
        } else if clickCount >= 2, let textView = start.textView, let local = start.pointInTextView,
                  let index = Self.characterIndex(in: textView, at: local, requireInside: false) {
            // Double-click = word, triple-click = paragraph, in that row.
            let granularity: NSSelectionGranularity = clickCount == 2 ? .selectByWord : .selectByParagraph
            let range = textView.selectionRange(forProposedRange: NSRange(location: index, length: 0),
                                                granularity: granularity)
            let row = start.point.row
            let selected = (start: SelectionPoint(row: row, offset: range.location),
                            end: SelectionPoint(row: row, offset: NSMaxRange(range)))
            unit = selected
            setSelection(DocumentSelection(anchor: selected.start, focus: selected.end))
        } else {
            // A press clears the old selection at once (like a native one) and
            // parks an empty one here, for a later Shift-click to extend from.
            setSelection(DocumentSelection(collapsedAt: start.point))
        }

        let pressLocation = event.locationInWindow
        let selectionBeforePress = selection
        let installedVersion = contentVersion
        let wasKey = window.isKeyWindow
        var dragged = false
        var lastDrag = event
        var periodicRunning = false
        defer { if periodicRunning { NSEvent.stopPeriodicEvents() } }

        func track(_ windowPoint: NSPoint) {
            guard let focus = hit(atWindowPoint: windowPoint) else { return }
            if let unit {
                setSelection(.extending(unit: unit, to: focus.point))
            } else {
                setSelection(.dragging(from: anchor, anchorIsAtomic: anchorIsAtomic, to: focus.point))
            }
        }

        /// Scrolls if the pointer asks for it; true when it did.
        func autoscrollIfNeeded(_ drag: NSEvent) -> Bool {
            switch autoscrollRequest(at: drag.locationInWindow) {
            case .none:
                return false
            case .outside:
                self.tableView?.autoscroll(with: drag)
            case .screenEdge(let direction):
                self.tableView?.scrollVertically(by: direction * Self.edgeAutoscrollStep)
            }
            return true
        }

        enum Ending { case mouseUp, forceClick(NSEvent), abandoned }
        var ending = Ending.abandoned

        trackingLoop: while true {
            // The gesture is void when the model under it changed (auto-reload
            // re-parsed: anchor and unit index the old strings) or when
            // something modal took over (a sandbox open panel triggered by a
            // row that autoscroll brought in, the window losing key).
            func isVoid() -> Bool {
                contentVersion != installedVersion || NSApp.modalWindow != nil
                    || (wasKey && !window.isKeyWindow)
            }
            if isVoid() { break trackingLoop }
            // A timeout rather than `.distantFuture`: a nested modal session
            // can swallow the mouse-up, and nothing else would end the loop.
            guard let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp, .periodic, .pressure],
                                              until: Date(timeIntervalSinceNow: 0.25),
                                              inMode: .eventTracking, dequeue: true) else {
                if NSEvent.pressedMouseButtons & 1 == 0 { break trackingLoop }
                continue
            }
            if isVoid() { break trackingLoop }
            switch next.type {
            case .leftMouseUp:
                ending = .mouseUp
                break trackingLoop
            case .pressure:
                // Force click (stage 2): Quick Look / Look Up, not a click.
                if next.stage >= 2 {
                    ending = .forceClick(next)
                    break trackingLoop
                }
            case .leftMouseDragged:
                lastDrag = next
                if !dragged {
                    let dx = next.locationInWindow.x - pressLocation.x
                    let dy = next.locationInWindow.y - pressLocation.y
                    guard (dx * dx + dy * dy).squareRoot() >= Self.dragThreshold else { continue }
                    dragged = true
                }
                // Autoscroll now, then on every periodic tick while the pointer
                // stays put (no drag events arrive then).
                if autoscrollIfNeeded(next) {
                    if !periodicRunning {
                        NSEvent.startPeriodicEvents(afterDelay: 0.05, withPeriod: 0.05)
                        periodicRunning = true
                    }
                } else if periodicRunning {
                    NSEvent.stopPeriodicEvents()
                    periodicRunning = false
                }
                track(next.locationInWindow)
            case .periodic:
                guard dragged, autoscrollIfNeeded(lastDrag) else { continue }
                track(lastDrag.locationInWindow)
            default:
                continue
            }
        }

        switch ending {
        case .abandoned:
            // No click semantics: nothing opens, the selection stays as the
            // gesture left it (a re-parse has already cleared it).
            return
        case .forceClick(let pressure):
            // Not a click: undo what the press did to the selection (unless the
            // pointer had already started a drag) and let the text view under
            // the pointer show its Quick Look / Look Up panel.
            if !dragged, contentVersion == installedVersion { setSelection(selectionBeforePress) }
            if let target = hit(atWindowPoint: pressure.locationInWindow)?.textView {
                target.quickLook(with: pressure)
            }
            return
        case .mouseUp:
            break
        }

        // A plain click: the selection is already cleared; a link under the
        // pointer opens through the text view's delegate, i.e. the same
        // `clickedOnLink` → `onLink` → `handleLinkActivation` path as before
        // (including the confirmation for non-web schemes).
        if !dragged, clickCount == 1, !isExtending,
           let release = hit(atWindowPoint: event.locationInWindow),
           let textView = release.textView, let local = release.pointInTextView,
           let index = Self.characterIndex(in: textView, at: local, requireInside: true),
           let link = textView.textStorage?.attribute(.link, at: index, effectiveRange: nil) {
            textView.clicked(onLink: link, at: index)
        }
    }

    /// Points per periodic tick when autoscrolling from a screen-edge zone,
    /// where there is no "distance outside the view" to scale by.
    private static let edgeAutoscrollStep: CGFloat = 16

    private enum AutoscrollRequest {
        /// Above/below the clip view: AppKit's proportional `autoscroll(with:)`.
        case outside
        /// In the edge zone of a clip view that touches the screen edge
        /// (full screen, zoomed window): −1 = up, +1 = down.
        case screenEdge(CGFloat)
    }

    /// Whether a drag at `windowPoint` should scroll the document. Strictly
    /// outside the clip view vertically (sideways never counts — the document
    /// does not scroll horizontally), or — when the clip's edge sits on the
    /// screen's edge, so the pointer cannot get past it — inside a thin zone
    /// along that edge (`SelectionAutoscroll.screenEdgeDirection`).
    private func autoscrollRequest(at windowPoint: NSPoint) -> AutoscrollRequest? {
        guard let clipView = tableView?.enclosingScrollView?.contentView,
              let window = clipView.window else { return nil }
        let point = clipView.convert(windowPoint, from: nil)
        if point.y < clipView.bounds.minY || point.y > clipView.bounds.maxY { return .outside }
        guard let screen = window.screen else { return nil }
        let clipOnScreen = window.convertToScreen(clipView.convert(clipView.bounds, to: nil))
        let pointer = window.convertPoint(toScreen: windowPoint)
        return SelectionAutoscroll.screenEdgeDirection(clipOnScreen: clipOnScreen,
                                                       screenFrame: screen.frame,
                                                       pointer: pointer).map { .screenEdge($0) }
    }
}
