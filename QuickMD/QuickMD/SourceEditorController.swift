import AppKit
import SwiftUI

// MARK: - Source editor (v1.12 S-D1, S-D3–S-D6, S-D13, S-D15)
//
// The raw-Markdown editing surface: one NSTextView in an NSScrollView, plus the
// small controller API the Source Edit session drives. AppKit only — the
// SwiftUI wrapper (`Views/SourceEditorView.swift`) is nothing but wiring — so
// this file is compiled into BOTH the app and the test target and the whole
// editor is exercised headlessly.
//
// Deliberately NOT built from the document's text machinery
// (`SelfSizingTextView`, `configureForSelfSizing`, the selection layout
// manager, the link delegate): all of that is read-only by design and refuses
// first responder. This is a plain, editable, plain-text TextKit 1 view.
//
// Main-thread by convention, deliberately NOT @MainActor — SwiftUI view
// callbacks that create/drive this are nonisolated on the older SDK the CI
// runner builds with (constraints "CI builds on an OLDER SDK").

/// The editor's text view. Behaviour lives in the controller (its delegate);
/// the subclass holds the two things that must not depend on that delegate.
final class SourceTextView: NSTextView {
    /// The editor's own undo stack, held STRONGLY here. `delegate` is weak:
    /// were the controller gone while the view is still in a window, the
    /// delegate's `undoManager(for:)` would no longer be asked and AppKit
    /// would fall back to `window.undoManager` — the viewer NSDocument's,
    /// which autosaves in place (spec S-D1). The delegate method stays as a
    /// second layer.
    var editorUndoManager: UndoManager?
    /// Called once the view is in a window (a deferred `focus()`).
    var onMoveToWindow: (() -> Void)?
    /// True while text from a pasteboard is being inserted (paste, Services,
    /// a drop) — the CR-normalising re-insert names its undo step after it.
    private(set) var isReadingPasteboard = false

    override func readSelection(from pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        isReadingPasteboard = true
        defer { isReadingPasteboard = false }
        return super.readSelection(from: pboard, type: type)
    }

    override var undoManager: UndoManager? {
        editorUndoManager ?? super.undoManager
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { onMoveToWindow?() }
    }
}

/// The editor's scroll view. Reports `tile()` — the one place AppKit lays out
/// the clip view after a resize, a scroller change or the find bar appearing —
/// so the column geometry is recomputed from the clip width it just set; the
/// end of a live resize, when the deferred exact scroll position lands; and
/// the wheel and the start of a live scroll (scroller drag, trackpad), which
/// cancel that deferred position: the user moved on.
final class SourceEditorScrollView: NSScrollView {
    var onTile: (() -> Void)?
    var onEndLiveResize: (() -> Void)?
    var onUserScroll: (() -> Void)?
    private var liveScrollObserver: NSObjectProtocol?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        liveScrollObserver = NotificationCenter.default.addObserver(
            forName: NSScrollView.willStartLiveScrollNotification, object: self, queue: nil
        ) { [weak self] _ in self?.onUserScroll?() }
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    deinit {
        if let liveScrollObserver { NotificationCenter.default.removeObserver(liveScrollObserver) }
    }

    override func scrollWheel(with event: NSEvent) {
        onUserScroll?()
        super.scrollWheel(with: event)
    }

    override func tile() {
        super.tile()
        onTile?()
    }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        onEndLiveResize?()
    }
}

/// Owns the editor's text view and everything about it the session needs:
/// the buffer, the caret, scrolling, find, style and its own undo stack.
///
/// An `NSObject` because it is the text view's and the storage's delegate.
final class SourceEditorController: NSObject, NSTextViewDelegate, NSTextStorageDelegate {

    /// Everything the editor's look depends on. Equal styles are a no-op in
    /// `apply(style:)`, so SwiftUI may hand the same one on every update.
    struct Style: Equatable {
        var theme: MarkdownTheme
        var fontScale: Double
        var isReadingLayout: Bool

        /// `MarkdownTheme` is not `Equatable`; compare what the editor reads
        /// from it. Colours as well as the name: a custom theme re-imported
        /// under the same name may change them.
        static func == (lhs: Style, rhs: Style) -> Bool {
            lhs.fontScale == rhs.fontScale
                && lhs.isReadingLayout == rhs.isReadingLayout
                && lhs.theme.name == rhs.theme.name
                && lhs.theme.isDark == rhs.theme.isDark
                && lhs.theme.textColor == rhs.theme.textColor
                && lhs.theme.backgroundColor == rhs.theme.backgroundColor
                && lhs.theme.fonts == rhs.theme.fonts
        }
    }

    /// The user changed the buffer (typing, paste, undo, redo, `replaceAll`).
    /// Never fired by `load` or `apply(style:)`.
    var onChange: (() -> Void)?
    /// Escape reached the text view. Consumed here so it never opens
    /// NSTextView's completion list; the session decides what Esc means.
    var onEscape: (() -> Void)?

    /// The editor's OWN undo stack, handed to the text view through
    /// `undoManager(for:)`. Never `window.undoManager`: that one belongs to
    /// SwiftUI's viewer NSDocument, which autosaves in place — if it ever
    /// became edited AppKit would write the ORIGINAL text over the file
    /// (spec S-D1).
    let undoManager = UndoManager()

    /// The editing view. Internal for the session (first-responder checks)
    /// and for the tests, which inspect its configuration.
    let textView: SourceTextView

    private let textStorage: NSTextStorage
    private let layoutManager: NSLayoutManager
    private let textContainer: NSTextContainer
    private var scrollView: SourceEditorScrollView?
    private(set) var style: Style?

    /// `SourceEditSupport.indentUnit(for:)` scans the buffer, so it is cached
    /// and dropped on every change: only a Tab that follows an edit pays for
    /// a scan, ordinary typing never does.
    private var cachedIndentUnit: String?
    /// A line-to-top scroll asked for before the view had a width (the
    /// session places the caret right after mounting the editor, before the
    /// first layout pass). Performed by the first geometry update that can.
    private var pendingTopOffset: Int?
    private var isUpdatingGeometry = false

    /// The top line being kept across a relayout (width, inset or font
    /// change) until its EXACT position lands — see `relayoutKeepingTop`.
    private var pendingAnchor: TopAnchor?
    /// Where the estimated restore put the clip; if the clip has moved far
    /// since, the user scrolled and the exact restore must not yank them back.
    private var pendingAnchorClipY: CGFloat = 0
    private var exactRestoreWork: DispatchWorkItem?
    /// Quiet time after the last relayout before the exact restore runs —
    /// the rendered list's width debounce (`VirtualBlockList`), for the same
    /// reason: sidebars animate over 0.2 s and every frame changes the width.
    private static let exactRestoreDelay: TimeInterval = 0.1
    /// The exact restore re-lays out everything above the anchor, so its cost
    /// grows with the anchor's offset. Measured headlessly (Debug app; the
    /// cost is all AppKit layout), 2026-10-05: an anchor 400 000 UTF-16 units
    /// in costs ~160 ms with short 25-character lines (the worst case: one
    /// line fragment per 25 units) and ~85 ms with long wrapping lines; at the
    /// end of a 2 MB buffer it would be ~700 / ~400 ms — per zoom step or
    /// sidebar toggle. Below the limit the pause passes for part of the
    /// resize / zoom; beyond it the estimate is kept (the right text stays on
    /// screen within a line or two, only the scroller is approximate). The
    /// explicit jumps (`placeCaret`, `scroll(toLine:)`) are exact at any offset.
    static let exactRestoreCharacterLimit = 400_000
    /// The same budget in lines: layout cost follows line fragments, not
    /// UTF-16 units, so a file of very short lines would get several times
    /// the work under the character limit alone. 400 000 units at the
    /// measured worst case of 25 characters per line = 16 000 lines.
    static let exactRestoreLineLimit = 16_000
    /// `focus()` asked for before the view had a window (the session mounts
    /// and focuses in one pass); honoured when it gets one.
    private var focusRequested = false
    /// Re-entrancy guard for the attribute fix-up in `didProcessEditing`.
    private var isFixingAttributes = false

    override init() {
        // An explicit TextKit 1 stack: an NSTextView created with a container
        // that already belongs to an NSLayoutManager never builds TextKit 2.
        textStorage = NSTextStorage()
        layoutManager = NSLayoutManager()
        // Lay out only what is looked at — a 5 MB buffer would otherwise be
        // laid out in full on every edit near the top.
        layoutManager.allowsNonContiguousLayout = true
        textStorage.addLayoutManager(layoutManager)
        textContainer = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        // The container's width is set from the column geometry, never from
        // the view (`updateGeometry`); padding 0 like the rendered text, so the
        // first character sits exactly on the column's edge.
        textContainer.widthTracksTextView = false
        textContainer.heightTracksTextView = false
        textContainer.lineFragmentPadding = 0
        layoutManager.addTextContainer(textContainer)
        textView = SourceTextView(frame: .zero, textContainer: textContainer)
        super.init()
        textView.editorUndoManager = undoManager
        textView.onMoveToWindow = { [weak self] in self?.focusIfRequested() }
        textStorage.delegate = self
        configureTextView()
    }

    private func configureTextView() {
        let view = textView
        view.delegate = self
        view.isEditable = true
        view.isSelectable = true
        view.allowsUndo = true
        // Plain text: the buffer is the file. Nothing may add attributes,
        // images or "smart" rewrites the user did not type.
        view.isRichText = false
        view.importsGraphics = false
        view.allowsImageEditing = false
        view.usesFontPanel = false
        view.usesRuler = false
        view.isRulerVisible = false
        view.usesInspectorBar = false
        view.allowsDocumentBackgroundColorChange = false
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isAutomaticSpellingCorrectionEnabled = false
        view.isAutomaticTextCompletionEnabled = false
        view.isAutomaticLinkDetectionEnabled = false
        view.isAutomaticDataDetectionEnabled = false
        view.smartInsertDeleteEnabled = false
        view.isGrammarCheckingEnabled = false
        // Off by default; the context menu can still turn it on.
        view.isContinuousSpellCheckingEnabled = false
        // ⌘F while editing is the text view's own find bar (S-D6).
        view.usesFindBar = true
        view.isIncrementalSearchingEnabled = true
        // Soft wrap at the column edge, no horizontal scrolling.
        view.isHorizontallyResizable = false
        view.isVerticallyResizable = true
        view.minSize = .zero
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.autoresizingMask = [.width]
        view.drawsBackground = true
        view.setAccessibilityIdentifier("source-editor")
    }

    // MARK: - Hierarchy

    /// Builds the scroll view once and returns it on every later call (the
    /// representable's `makeNSView`). The text view exists from `init`, so
    /// `load` / `text` work before this is ever called.
    ///
    /// ONE live `SourceEditorView` per controller: there is one view, and an
    /// NSView has one superview. If SwiftUI briefly keeps two representables
    /// (a removal transition, an identity change), the view is detached from
    /// the old host before the new one gets it, never shared between them —
    /// and the old host is left EMPTY. So the integrator must not put a
    /// `.transition` on the editor overlay, and must keep its identity stable
    /// across Reading Mode / zoom / theme changes (style flows through
    /// `apply(style:)`, never through a new view identity).
    func makeScrollView(style: Style) -> NSScrollView {
        if let scrollView {
            scrollView.removeFromSuperview()
            apply(style: style)
            return scrollView
        }
        let scrollView = SourceEditorScrollView(frame: .zero)
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        // Same as the rendered list: a scroller that autohides changes the
        // clip width, and the column must be the list's column.
        scrollView.autohidesScrollers = false
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets()
        scrollView.documentView = textView
        scrollView.onTile = { [weak self] in self?.updateGeometry() }
        scrollView.onEndLiveResize = { [weak self] in self?.finishRelayout() }
        scrollView.onUserScroll = { [weak self] in self?.dropPendingAnchor() }
        self.scrollView = scrollView
        apply(style: style)
        return scrollView
    }

    // MARK: - Style

    /// Theme / zoom / layout changes. Attribute-only: the storage is restyled
    /// directly (no `shouldChangeText`), so nothing is registered for undo and
    /// `onChange` does not fire; the selection is untouched and the line at
    /// the top of the visible area stays there.
    func apply(style newStyle: Style) {
        guard newStyle != style else { return }
        let fontChanged = style.map { Self.font(for: $0) != Self.font(for: newStyle) } ?? true
        let colorChanged = style.map { $0.theme.textColor != newStyle.theme.textColor } ?? true
        style = newStyle

        let theme = newStyle.theme
        let appearance = NSAppearance(named: theme.isDark ? .darkAqua : .aqua)
        // Nothing else in the app sets an appearance: a dark theme on a light
        // system would get light scrollers, selection and find bar otherwise.
        scrollView?.appearance = appearance
        textView.appearance = appearance
        let background = NSColor(theme.backgroundColor)
        textView.backgroundColor = background
        scrollView?.backgroundColor = background
        textView.insertionPointColor = NSColor(theme.textColor)

        if fontChanged || colorChanged {
            relayoutKeepingTop {
                let attributes = baseAttributes
                textView.typingAttributes = attributes
                if textStorage.length > 0 {
                    textStorage.beginEditing()
                    textStorage.setAttributes(attributes, range: NSRange(location: 0, length: textStorage.length))
                    textStorage.endEditing()
                }
            }
        }
        updateGeometry()
    }

    /// The code font at the current zoom — the same face and size as the
    /// rendered code blocks (`CodeBlockView`, `BlockLayout.Code`).
    private static func font(for style: Style) -> NSFont {
        style.theme.fonts.appKit(size: BlockLayout.Code.codeFontSize * CGFloat(style.fontScale),
                                 monospaced: true)
    }

    /// Font + colour for the whole buffer (plain text: one run).
    private var baseAttributes: [NSAttributedString.Key: Any] {
        guard let style else { return [:] }
        return [.font: Self.font(for: style), .foregroundColor: NSColor(style.theme.textColor)]
    }

    // MARK: - Column geometry

    /// Where the text column sits in a clip view of a given width.
    struct ColumnGeometry: Equatable {
        /// `textContainerInset.width`: the column's left edge.
        let horizontalInset: CGFloat
        /// The text container's width: where lines wrap.
        let columnWidth: CGFloat
        /// `textContainerInset.height`: air above the first and below the last line.
        let verticalInset: CGFloat
    }

    /// The rendered document's column, reproduced so the text does not jump
    /// sideways when the mode toggles. `VirtualBlockList.currentContentWidth()`
    /// computes `inner = floor(clip) − 2 × contentHorizontalPadding` (32 pt)
    /// and, in reading mode, `floor(min(inner, 720))`; its cells centre that
    /// column in the `floor(clip)`-wide table column, i.e. the column starts
    /// at `(floor(clip) − column) / 2` — 32 pt exactly in the standard layout,
    /// never less in reading mode. The vertical gap is the list's visible gap
    /// above the first block (`LayoutStyle.verticalPadding`: 24 / 48 pt).
    static func columnGeometry(clipWidth: CGFloat, isReadingLayout: Bool) -> ColumnGeometry {
        let available = floor(max(clipWidth, 0))
        let inner = available - 2 * BlockLayout.Document.contentHorizontalPadding
        let column = isReadingLayout
            ? max(0, floor(min(inner, BlockLayout.Document.readingMaxContentWidth)))
            : max(0, inner)
        let vertical = isReadingLayout
            ? BlockLayout.Document.readingContentVerticalPadding
            : BlockLayout.Document.contentVerticalPadding
        return ColumnGeometry(horizontalInset: max(0, (available - column) / 2),
                              columnWidth: column, verticalInset: vertical)
    }

    /// Applies `columnGeometry` for the current clip width. Called from the
    /// scroll view's `tile()` (resizes) and from `apply(style:)` (reading
    /// layout toggles). Cheap when nothing changed; a new column keeps the
    /// top line (`relayoutKeepingTop`).
    private func updateGeometry() {
        guard !isUpdatingGeometry, let scrollView, let style else { return }
        isUpdatingGeometry = true
        defer { isUpdatingGeometry = false }
        let clip = scrollView.contentView.bounds.size
        let geometry = Self.columnGeometry(clipWidth: clip.width, isReadingLayout: style.isReadingLayout)
        let inset = NSSize(width: geometry.horizontalInset, height: geometry.verticalInset)
        // At least as tall as the clip, so a click below a short text still
        // lands in the text view (and places the caret at the end).
        textView.minSize = NSSize(width: 0, height: clip.height)
        if textView.frame.width != clip.width || textView.frame.height < clip.height {
            textView.setFrameSize(NSSize(width: clip.width, height: max(textView.frame.height, clip.height)))
        }
        if textView.textContainerInset != inset || textContainer.size.width != geometry.columnWidth {
            relayoutKeepingTop {
                if textView.textContainerInset != inset {
                    textView.textContainerInset = inset
                }
                if textContainer.size.width != geometry.columnWidth {
                    textContainer.size = NSSize(width: geometry.columnWidth,
                                                height: CGFloat.greatestFiniteMagnitude)
                }
            }
        }
        if geometry.columnWidth > 0, let offset = pendingTopOffset {
            pendingTopOffset = nil
            scrollToTop(characterOffset: offset)
        }
    }

    /// Runs a change that invalidates the layout (column width, inset, font)
    /// and keeps the line at the top of the visible area where it was.
    ///
    /// In two steps, because exact costs: after a relayout, the exact position
    /// of a line N characters in needs those N characters laid out again —
    /// measured ~1.7 s for the end of a 5 MB buffer — and a resize or a
    /// sidebar animation changes the width every frame. So every change
    /// restores the anchor at once through the layout manager's ESTIMATE
    /// (non-contiguous layout lays out only around it, ~1 ms: the same text
    /// stays on screen, only the scroller is approximate), and the exact
    /// position lands once the changes stop — 100 ms later, or at the end of
    /// a live resize — unless the user has scrolled in between.
    private func relayoutKeepingTop(_ change: () -> Void) {
        let anchor = pendingAnchor ?? topVisibleAnchor()
        change()
        guard let anchor, textContainer.size.width > 0, textStorage.length > 0 else {
            pendingAnchor = nil
            return
        }
        let glyph = layoutManager.glyphIndexForCharacter(at: min(anchor.character, textStorage.length - 1))
        let estimatedTop = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).minY
        scrollLaidOut(toY: clipY(forLineTop: estimatedTop, anchor))
        // Laying out the screen around it can refine the line's estimate;
        // follow it once so the same text is really at the top.
        let refinedTop = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil,
                                                        withoutAdditionalLayout: true).minY
        if refinedTop != estimatedTop { scrollClip(toY: clipY(forLineTop: refinedTop, anchor)) }
        pendingAnchor = anchor
        pendingAnchorClipY = scrollView?.contentView.bounds.minY ?? 0
        exactRestoreWork?.cancel()
        exactRestoreWork = nil
        // During a live resize the exact restore waits for its end
        // (`onEndLiveResize`): a pause in the drag must not stall it.
        guard scrollView?.inLiveResize != true else { return }
        let work = DispatchWorkItem { [weak self] in self?.finishRelayout() }
        exactRestoreWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.exactRestoreDelay, execute: work)
    }

    /// The exact half of `relayoutKeepingTop`.
    private func finishRelayout() {
        exactRestoreWork?.cancel()
        exactRestoreWork = nil
        guard let anchor = pendingAnchor else { return }
        pendingAnchor = nil
        guard isExactRestoreAffordable(at: anchor.character) else { return }
        // AppKit itself nudges the clip by a line or two while background
        // layout refines the estimate; more than half a screen is a scroll
        // that slipped past the explicit cancels (wheel, live scroll,
        // keyboard commands), and the user's position wins.
        guard let scrollView else { return }
        let clip = scrollView.contentView.bounds
        guard abs(clip.minY - pendingAnchorClipY) <= clip.height / 2 else { return }
        restore(anchor)
    }

    /// Whether an exact top-line restore at `character` stays within both
    /// budgets. The line count scans up to the anchor — only once the
    /// character limit already holds, so the scan is bounded too.
    private func isExactRestoreAffordable(at character: Int) -> Bool {
        guard character < Self.exactRestoreCharacterLimit else { return false }
        return SourceEditSupport.line(containing: character, in: textStorage.mutableString)
            < Self.exactRestoreLineLimit
    }

    /// A relayout's exact top-line restore is still to come (tests wait on it).
    var isRestorePending: Bool { pendingAnchor != nil }

    /// An explicit scroll supersedes a top line still being kept.
    private func dropPendingAnchor() {
        exactRestoreWork?.cancel()
        exactRestoreWork = nil
        pendingAnchor = nil
    }

    // MARK: - Buffer

    /// The buffer (LF only). A copy — for saving and comparing, not per keystroke.
    var text: String { textStorage.string }

    /// Replaces everything WITHOUT an undo entry and without `onChange`:
    /// entering the editor, adopting a clean external change. The undo stack
    /// is cleared (it described a different text), the caret goes to 0.
    func load(_ text: String) {
        let normalized = MarkdownDocument.normalizeLineEndings(text)
        textStorage.beginEditing()
        textStorage.replaceCharacters(in: NSRange(location: 0, length: textStorage.length),
                                      with: NSAttributedString(string: normalized, attributes: baseAttributes))
        textStorage.endEditing()
        cachedIndentUnit = nil
        undoManager.removeAllActions()
        textView.breakUndoCoalescing()
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        pendingTopOffset = nil
        dropPendingAnchor()
        scrollClip(toY: 0)
    }

    /// `load` for a buffer the user is looking at: adopting a clean external
    /// change, or reverting after Don't Save on close (S-D9). Same contract —
    /// no undo entry, no `onChange`, the undo stack is cleared — but the
    /// caret keeps its line and column and the line at the top of the visible
    /// area stays there, each clamped to the new text: an external rewrite of
    /// a paragraph elsewhere must not throw the user back to line 0.
    /// Positions are carried as (line, column), not as offsets — an edit
    /// above the caret shifts every offset below it. Nothing pending survives
    /// pointing into the old text: a relayout's kept top line becomes the
    /// line kept here (it is the truer top while its exact pass is due), and
    /// an entry scroll still waiting for a width is re-targeted. The top line
    /// lands exactly within the exact-restore budgets (characters and lines),
    /// by the estimate beyond them — the same trade-off as a relayout.
    func reload(_ text: String) {
        let normalized = MarkdownDocument.normalizeLineEndings(text)
        let old = textStorage.mutableString
        func lineAndColumn(_ offset: Int) -> (line: Int, column: Int) {
            let line = SourceEditSupport.line(containing: offset, in: old)
            return (line, offset - SourceEditSupport.lineStart(line, in: old))
        }
        let caret = lineAndColumn(textView.selectedRange().location)
        let top = (pendingAnchor ?? topVisibleAnchor()).map {
            (position: lineAndColumn($0.character), offset: $0.offset)
        }
        let pendingTopLine = pendingTopOffset.map { SourceEditSupport.line(containing: $0, in: old) }

        textStorage.beginEditing()
        textStorage.replaceCharacters(in: NSRange(location: 0, length: textStorage.length),
                                      with: NSAttributedString(string: normalized, attributes: baseAttributes))
        textStorage.endEditing()
        cachedIndentUnit = nil
        undoManager.removeAllActions()
        textView.breakUndoCoalescing()
        dropPendingAnchor()
        pendingTopOffset = nil

        let new = textStorage.mutableString
        func offset(line: Int, column: Int) -> Int {
            // `lineRange` clamps a line past the end to the last line.
            let range = SourceEditSupport.lineRange(line, in: new)
            return range.location + min(column, range.length)
        }
        textView.setSelectedRange(NSRange(location: offset(line: caret.line, column: caret.column), length: 0))
        if let pendingTopLine {
            // Not laid out yet: the entry scroll still has to happen, now in
            // the new text.
            pendingTopOffset = SourceEditSupport.lineStart(pendingTopLine, in: new)
        } else if let top {
            let anchor = TopAnchor(character: offset(line: top.position.line, column: top.position.column),
                                   offset: top.offset)
            if isExactRestoreAffordable(at: anchor.character) {
                restore(anchor)
            } else if textContainer.size.width > 0, textStorage.length > 0 {
                let glyph = layoutManager.glyphIndexForCharacter(at: min(anchor.character, textStorage.length - 1))
                let estimatedTop = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).minY
                scrollLaidOut(toY: clipY(forLineTop: estimatedTop, anchor))
            }
        } else {
            scrollClip(toY: 0)
        }
    }

    /// Replaces everything as ONE undoable edit (Discard Changes, Load Disk
    /// Version — ⌘Z brings the previous text back). Fires `onChange`. The
    /// caret keeps its offset where the new text is long enough.
    func replaceAll(with text: String) {
        let normalized = MarkdownDocument.normalizeLineEndings(text)
        let caret = textView.selectedRange().location
        let newLength = (normalized as NSString).length
        perform(range: NSRange(location: 0, length: textStorage.length), replacement: normalized,
                selection: NSRange(location: min(caret, newLength), length: 0), scrollToSelection: false)
    }

    // MARK: - Caret and scrolling

    /// 0-based line of the selection start. Scans the buffer up to the caret:
    /// for user actions (leaving, saving), not per keystroke.
    var caretLine: Int {
        SourceEditSupport.line(containing: textView.selectedRange().location, in: textStorage.mutableString)
    }

    /// Caret at the start of 0-based `line` (clamped) and that line scrolled
    /// to the top of the visible area — where the reader's eyes already are
    /// (S-D3). "Top" keeps the column's vertical inset above the line, the
    /// same gap a `.top` jump leaves in the rendered list; a line too close to
    /// the end to reach the top is shown with the document's end at the bottom.
    func placeCaret(atLine line: Int) {
        let offset = SourceEditSupport.lineStart(line, in: textStorage.mutableString)
        textView.setSelectedRange(NSRange(location: offset, length: 0))
        scrollToTop(characterOffset: offset)
    }

    /// Selects `range` (clamped) and scrolls it into view.
    func select(_ range: NSRange) {
        let length = textStorage.length
        let location = min(max(range.location, 0), length)
        let clamped = NSRange(location: location, length: min(max(range.length, 0), length - location))
        textView.setSelectedRange(clamped)
        dropPendingAnchor()
        textView.scrollRangeToVisible(clamped)
    }

    /// 0-based `line` at the top of the visible area, caret untouched (ToC
    /// clicks while editing, S-D13).
    func scroll(toLine line: Int) {
        scrollToTop(characterOffset: SourceEditSupport.lineStart(line, in: textStorage.mutableString))
    }

    /// Makes the text view first responder — now, or as soon as it is in a
    /// window (the session mounts the editor and focuses it in one pass).
    func focus() {
        guard let window = textView.window else {
            focusRequested = true
            return
        }
        focusRequested = false
        window.makeFirstResponder(textView)
    }

    /// Drops a deferred `focus()`: the session left the mode before the view
    /// ever reached a window, and a later mount must not take the focus.
    func cancelPendingFocus() {
        focusRequested = false
    }

    private func focusIfRequested() {
        guard focusRequested else { return }
        focus()
    }

    /// Scrolls so the line containing `offset` starts `verticalInset` below
    /// the top of the visible area: the clip's origin goes to the line's top
    /// in CONTAINER coordinates (`textContainerOrigin.y` is that inset).
    private func scrollToTop(characterOffset offset: Int) {
        guard scrollView != nil, textContainer.size.width > 0 else {
            pendingTopOffset = offset
            return
        }
        pendingTopOffset = nil
        dropPendingAnchor()
        scrollLaidOut(toY: lineTop(atCharacter: offset))
    }

    /// Scrolls the clip to `y` (view coordinates) after laying out the
    /// screenful it will show: near the end of the buffer the rest of the
    /// text decides how far the clip may scroll, and an estimated remainder
    /// would leave the clip past the view's real end once layout catches up.
    private func scrollLaidOut(toY y: CGFloat) {
        guard let scrollView else { return }
        let visible = NSRect(x: 0, y: max(y - textView.textContainerOrigin.y, 0),
                             width: textContainer.size.width,
                             height: scrollView.contentView.bounds.height)
        layoutManager.ensureLayout(forBoundingRect: visible, in: textContainer)
        textView.sizeToFit()
        scrollClip(toY: y)
    }

    /// Top of the line fragment holding character `index`, in container
    /// coordinates — EXACT, not estimated: with non-contiguous layout the
    /// position of a line far into the buffer is a guess until everything
    /// above it has been laid out, so layout is ensured up to it first.
    private func lineTop(atCharacter index: Int) -> CGFloat {
        let length = textStorage.length
        let index = min(max(index, 0), length)
        if index == length {
            // The empty line after a trailing newline (or of an empty text)
            // is the extra line fragment, which exists only once layout has
            // reached the end.
            layoutManager.ensureLayout(for: textContainer)
            if layoutManager.extraLineFragmentTextContainer != nil {
                return layoutManager.extraLineFragmentRect.minY
            }
            guard length > 0 else { return 0 }
            return lineFragmentTop(atCharacter: length - 1)
        }
        layoutManager.ensureLayout(forCharacterRange: NSRange(location: 0, length: index + 1))
        return lineFragmentTop(atCharacter: index)
    }

    private func lineFragmentTop(atCharacter index: Int) -> CGFloat {
        let glyph = layoutManager.glyphIndexForCharacter(at: index)
        return layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil,
                                              withoutAdditionalLayout: true).minY
    }

    private func scrollClip(toY y: CGFloat) {
        guard let scrollView else { return }
        let clip = scrollView.contentView
        var bounds = clip.bounds
        bounds.origin = NSPoint(x: 0, y: y)
        clip.scroll(to: clip.constrainBoundsRect(bounds).origin)
        scrollView.reflectScrolledClipView(clip)
    }

    /// The line at the top edge of the visible area and how far its top is
    /// from that edge — what a relayout puts back.
    ///
    /// Measured in CONTAINER coordinates on both sides (the clip's origin
    /// minus `textContainerOrigin.y`), so a change of the vertical inset —
    /// Reading Mode, 24 ⇄ 48 pt — leaves the line exactly where it was on
    /// screen instead of shifting it by the inset delta.
    private struct TopAnchor {
        let character: Int
        /// The line's top minus the visible top, container coordinates.
        let offset: CGFloat
    }

    private func topVisibleAnchor() -> TopAnchor? {
        guard let scrollView, textStorage.length > 0, textContainer.size.width > 0 else { return nil }
        let clipTop = scrollView.contentView.bounds.minY
        guard clipTop > 0 else { return nil }
        let top = clipTop - textView.textContainerOrigin.y
        let glyph = layoutManager.glyphIndex(for: NSPoint(x: 0, y: max(top, 0)), in: textContainer)
        var line = NSRange()
        let lineTop = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: &line).minY
        // The fragment's FIRST character: after a rewrap that is the
        // character whose line goes back to the top.
        let character = layoutManager.characterIndexForGlyph(at: line.location)
        return TopAnchor(character: character, offset: lineTop - top)
    }

    /// The clip origin that puts `anchor`'s line, now at container-y
    /// `lineTop`, back at its distance from the visible top.
    private func clipY(forLineTop lineTop: CGFloat, _ anchor: TopAnchor) -> CGFloat {
        lineTop - anchor.offset + textView.textContainerOrigin.y
    }

    private func restore(_ anchor: TopAnchor) {
        guard textContainer.size.width > 0 else { return }
        scrollLaidOut(toY: clipY(forLineTop: lineTop(atCharacter: anchor.character), anchor))
    }

    // MARK: - Find (S-D6)

    var isFindBarVisible: Bool { scrollView?.isFindBarVisible ?? false }

    func showFind() { performFinder(.showFindInterface) }
    func findNext() { performFinder(.nextMatch) }
    func findPrevious() { performFinder(.previousMatch) }
    func hideFind() { performFinder(.hideFindInterface) }

    /// `performTextFinderAction(_:)` reads the action from the sender's `tag`.
    private func performFinder(_ action: NSTextFinder.Action) {
        let sender = NSMenuItem()
        sender.tag = action.rawValue
        textView.performTextFinderAction(sender)
    }

    // MARK: - Edits

    /// One replacement through NSTextView's own change path, as ONE undo
    /// group of its own: `shouldChangeText` registers the undo and consults
    /// the delegate, `didChangeText` posts `textDidChange`. Coalescing is
    /// broken on both sides so the edit never merges with surrounding typing.
    private func perform(range: NSRange, replacement: String, selection: NSRange,
                         scrollToSelection: Bool = true) {
        undoManager.beginUndoGrouping()
        defer { undoManager.endUndoGrouping() }
        textView.breakUndoCoalescing()
        guard textView.shouldChangeText(in: range, replacementString: replacement) else { return }
        textStorage.replaceCharacters(in: range,
                                      with: NSAttributedString(string: replacement, attributes: baseAttributes))
        textView.didChangeText()
        textView.breakUndoCoalescing()
        textView.setSelectedRange(selection)
        if scrollToSelection { textView.scrollRangeToVisible(selection) }
    }

    private func perform(_ edit: SourceEditSupport.TextEdit) {
        perform(range: edit.range, replacement: edit.replacement, selection: edit.selection)
    }

    private var indentUnit: String {
        if let cachedIndentUnit { return cachedIndentUnit }
        let unit = SourceEditSupport.indentUnit(for: textStorage.mutableString)
        cachedIndentUnit = unit
        return unit
    }

    // MARK: - NSTextViewDelegate

    func undoManager(for view: NSTextView) -> UndoManager? {
        undoManager
    }

    /// The buffer never contains U+000D. A change carrying a CR (paste, drop,
    /// Services, an input method) is refused and re-applied LF-normalised as
    /// an edit of its own (`perform`: own undo group, coalescing broken on
    /// both sides) — through `insertText` it would count as typing and merge
    /// with the keystrokes around it into one undo step. Scalar check
    /// (constraint 14): Swift hides "\r" inside "\r\n" from Character-based
    /// `contains`. Per keystroke this looks at the typed characters only.
    func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange,
                  replacementString: String?) -> Bool {
        guard let replacementString, replacementString.unicodeScalars.contains("\r") else { return true }
        let normalized = MarkdownDocument.normalizeLineEndings(replacementString)
        let end = affectedCharRange.location + (normalized as NSString).length
        perform(range: affectedCharRange, replacement: normalized,
                selection: NSRange(location: end, length: 0))
        // The refused change was a paste, so the step replacing it is one.
        // AppKit exposes no localized name for it; the app's menus are English.
        if self.textView.isReadingPasteboard { undoManager.setActionName("Paste") }
        return false
    }

    /// The multi-range variant (the find bar's Replace All, multi-selection
    /// edits). NSTextView asks this one instead of the single-range method
    /// when the delegate implements it, so it must close the same CR route.
    /// One range → the single-range path above; several → every replacement
    /// LF-normalised and applied back to front (earlier ranges stay valid)
    /// as ONE undo step.
    func textView(_ textView: NSTextView, shouldChangeTextInRanges affectedRanges: [NSValue],
                  replacementStrings: [String]?) -> Bool {
        guard let replacementStrings, replacementStrings.count == affectedRanges.count,
              replacementStrings.contains(where: { $0.unicodeScalars.contains("\r") }) else { return true }
        if affectedRanges.count == 1 {
            return self.textView(textView, shouldChangeTextIn: affectedRanges[0].rangeValue,
                                 replacementString: replacementStrings[0])
        }
        let normalized = replacementStrings.map(MarkdownDocument.normalizeLineEndings)
        undoManager.beginUndoGrouping()
        defer { undoManager.endUndoGrouping() }
        textView.breakUndoCoalescing()
        guard textView.shouldChangeText(inRanges: affectedRanges, replacementStrings: normalized) else {
            return false
        }
        let edits = zip(affectedRanges.map(\.rangeValue), normalized).sorted { $0.0.location > $1.0.location }
        for (range, replacement) in edits {
            textStorage.replaceCharacters(in: range,
                                          with: NSAttributedString(string: replacement, attributes: baseAttributes))
        }
        textView.didChangeText()
        textView.breakUndoCoalescing()
        return false
    }

    /// Return keeps the line's indentation, Tab / Shift-Tab indent and outdent
    /// (S-D5); Escape goes to the session and never opens completion.
    /// Shift-Return (`insertLineBreak:`, which would insert U+2028 — a line
    /// separator the parser does not split on) and Option-Return
    /// (`insertNewlineIgnoringFieldEditor:`) are plain Returns here: the
    /// buffer's only line break is "\n".
    ///
    /// Any other command (arrows, paging, Home / End) is the user moving:
    /// it cancels a pending exact top-line restore, then runs as usual.
    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        let selection = textView.selectedRange()
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)),
             #selector(NSResponder.insertLineBreak(_:)),
             #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
            perform(SourceEditSupport.newlineEdit(in: textStorage.mutableString, selection: selection))
            return true
        case #selector(NSResponder.insertTab(_:)):
            if let edit = SourceEditSupport.indentEdit(in: textStorage.mutableString,
                                                       selection: selection, unit: indentUnit) {
                perform(edit)
            }
            return true
        case #selector(NSResponder.insertBacktab(_:)):
            if let edit = SourceEditSupport.outdentEdit(in: textStorage.mutableString,
                                                        selection: selection, unit: indentUnit) {
                perform(edit)
            }
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            onEscape?()
            return true
        default:
            dropPendingAnchor()
            return false
        }
    }

    // MARK: - NSTextStorageDelegate

    /// Plain text has ONE style. Restyling (`apply(style:)`) rewrites the
    /// storage's attributes, but undo operations keep the text they removed
    /// with the attributes it had — undoing a deletion after a zoom would
    /// bring back a run in the old font. Every character edit is therefore
    /// stamped with the current base font and colour; attribute changes are
    /// left alone (they are ours). Changing attributes, not characters, is
    /// what `didProcessEditing` allows. Per keystroke this touches the typed
    /// range. ADDED, not replaced: `setAttributes` would also strip what
    /// NSTextView itself keeps on the range — the marked-text underline of an
    /// input method or a dead key composing there.
    func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions,
                     range editedRange: NSRange, changeInLength delta: Int) {
        guard editedMask.contains(.editedCharacters), !isFixingAttributes,
              editedRange.length > 0, NSMaxRange(editedRange) <= textStorage.length else { return }
        let attributes = baseAttributes
        guard !attributes.isEmpty else { return }
        isFixingAttributes = true
        defer { isFixingAttributes = false }
        textStorage.addAttributes(attributes, range: editedRange)
    }

    func textDidChange(_ notification: Notification) {
        cachedIndentUnit = nil
        // A kept top line is a character offset; an edit may have moved it.
        dropPendingAnchor()
        onChange?()
    }
}
