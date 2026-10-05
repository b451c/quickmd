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

/// The editor's text view. A subclass only so it has its own type in the view
/// hierarchy (accessibility, debugging); all behaviour lives in the
/// controller, which is its delegate.
final class SourceTextView: NSTextView {}

/// The editor's scroll view. Reports `tile()` — the one place AppKit lays out
/// the clip view after a resize, a scroller change or the find bar appearing —
/// so the column geometry is recomputed from the clip width it just set; the
/// end of a live resize, when the deferred exact scroll position lands; and
/// the wheel, which cancels that deferred position (the user moved on).
final class SourceEditorScrollView: NSScrollView {
    var onTile: (() -> Void)?
    var onEndLiveResize: (() -> Void)?
    var onScrollWheel: (() -> Void)?

    override func scrollWheel(with event: NSEvent) {
        onScrollWheel?()
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
/// An `NSObject` because it is the text view's delegate.
final class SourceEditorController: NSObject, NSTextViewDelegate {

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
    func makeScrollView(style: Style) -> NSScrollView {
        if let scrollView {
            apply(style: style)
            return scrollView
        }
        let scrollView = SourceEditorScrollView()
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
        scrollView.onScrollWheel = { [weak self] in self?.dropPendingAnchor() }
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
        scrollLaidOut(toY: estimatedTop - anchor.offset)
        // Laying out the screen around it can refine the line's estimate;
        // follow it once so the same text is really at the top.
        let refinedTop = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil,
                                                        withoutAdditionalLayout: true).minY
        if refinedTop != estimatedTop { scrollClip(toY: refinedTop - anchor.offset) }
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
        // AppKit itself nudges the clip by a line or two while background
        // layout refines the estimate; more than half a screen is a scroll
        // by the user (scroller drag, keyboard paging — the wheel already
        // dropped the anchor), and their position wins.
        guard let scrollView else { return }
        let clip = scrollView.contentView.bounds
        guard abs(clip.minY - pendingAnchorClipY) <= clip.height / 2 else { return }
        restore(anchor)
    }

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
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        pendingTopOffset = nil
        dropPendingAnchor()
        scrollClip(toY: 0)
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

    func focus() {
        textView.window?.makeFirstResponder(textView)
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

    /// Scrolls the clip to container-y `y` after laying out the screenful it
    /// will show: near the end of the buffer the rest of the text decides how
    /// far the clip may scroll, and an estimated remainder would leave the
    /// clip past the view's real end once layout catches up.
    private func scrollLaidOut(toY y: CGFloat) {
        guard let scrollView else { return }
        let visible = NSRect(x: 0, y: max(y, 0), width: textContainer.size.width,
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

    /// The character at the top of the visible area and how far its line
    /// starts above that top — what `apply(style:)` puts back.
    private struct TopAnchor {
        let character: Int
        let offset: CGFloat
    }

    private func topVisibleAnchor() -> TopAnchor? {
        guard let scrollView, textStorage.length > 0, textContainer.size.width > 0 else { return nil }
        let top = scrollView.contentView.bounds.minY
        guard top > 0 else { return nil }
        let glyph = layoutManager.glyphIndex(for: NSPoint(x: 0, y: top), in: textContainer)
        var line = NSRange()
        let lineTop = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: &line).minY
        // The fragment's FIRST character: after a rewrap that is the
        // character whose line goes back to the top.
        let character = layoutManager.characterIndexForGlyph(at: line.location)
        return TopAnchor(character: character, offset: lineTop - top)
    }

    private func restore(_ anchor: TopAnchor) {
        guard textContainer.size.width > 0 else { return }
        scrollLaidOut(toY: lineTop(atCharacter: anchor.character) - anchor.offset)
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
    /// Services, an input method) is refused and re-inserted LF-normalised
    /// through the normal insertion path, so undo records exactly what landed
    /// in the buffer. Scalar check (constraint 14): Swift hides "\r" inside
    /// "\r\n" from Character-based `contains`. Per keystroke this looks at the
    /// typed characters only.
    func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange,
                  replacementString: String?) -> Bool {
        guard let replacementString, replacementString.unicodeScalars.contains("\r") else { return true }
        textView.insertText(MarkdownDocument.normalizeLineEndings(replacementString),
                            replacementRange: affectedCharRange)
        return false
    }

    /// Return keeps the line's indentation, Tab / Shift-Tab indent and outdent
    /// (S-D5); Escape goes to the session and never opens completion.
    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        let selection = textView.selectedRange()
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)):
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
            return false
        }
    }

    func textDidChange(_ notification: Notification) {
        cachedIndentUnit = nil
        // A kept top line is a character offset; an edit may have moved it.
        dropPendingAnchor()
        onChange?()
    }
}
