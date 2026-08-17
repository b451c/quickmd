import SwiftUI
import AppKit
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
    /// Column width − 2 × `contentHorizontalPadding`: the width a block view
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
        // The 24 pt that used to be `.padding(.vertical:)` on the stack. As
        // content insets they scroll with the document exactly as before, but
        // AppKit — not us — owns the arithmetic (see `contentTopY`).
        //
        // Why not exactly 24: `NSTableView` centres each row inside its rect,
        // which puts HALF the intercell spacing above the first row and half
        // below the last one (measured). Subtracting that half here makes the
        // visible gap at both ends of the document exactly
        // `contentVerticalPadding`, and makes a `.top` jump to any row — row 0
        // included — leave exactly that same gap above the row's content.
        scrollView.automaticallyAdjustsContentInsets = false
        let edgeInset = max(0, Metrics.contentVerticalPadding - Metrics.blockSpacing / 2)
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

        // MARK: AppKit

        private weak var scrollView: BlockScrollView?
        private weak var tableView: BlockTableView?

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
        /// horizontal padding the cell applies on both sides.
        ///
        /// Read from the CLIP VIEW, not from the column, and 0 before the first
        /// layout: `NSTableColumn`'s default width is an arbitrary non-zero
        /// number, and publishing it would measure the whole document at a
        /// nonsense width — for a 10 000-line document, seconds of TextKit work
        /// for a table that is thrown away on the next frame. `syncColumnWidth`
        /// keeps the column equal to this, so the two never disagree.
        private func currentContentWidth() -> CGFloat {
            let available = quantizedClipWidth()
            guard available > 0 else { return 0 }
            return max(0, available - 2 * Metrics.contentHorizontalPadding)
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
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .fixedSize(horizontal: false, vertical: true)

            let reports = row < table.kinds.count && table.kinds[row] == .reported
            if reports {
                return AnyView(
                    base
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
                base
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(.horizontal, Metrics.contentHorizontalPadding)
                    .id(block.id)
            )
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
                return cell
            }
            return BlockHostingCell(rootView: root)
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

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        onEndLiveResize?()
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
/// This runs only when the key event reaches the table: a click inside a block
/// makes that block's `NSTextView` the first responder, and text views handle
/// these keys themselves — exactly as in 1.8.0.
final class BlockTableView: NSTableView {

    override var acceptsFirstResponder: Bool { true }

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

    private func scrollVertically(by dy: CGFloat) {
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
    }
}
