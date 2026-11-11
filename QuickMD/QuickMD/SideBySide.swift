import AppKit

// MARK: - Source Edit side by side (#55)
//
// The editor on the left, the rendered document on the right. The rendered
// side follows the BUFFER — the one deliberate exception to "rendered text ==
// disk" (constraints "Source Edit"): `currentText`, print, export and the
// session still see only what is on disk. Everything that decides what the
// preview shows, when it re-parses and how wide the window must be lives here,
// pure, so the rules are tested without a window.

// MARK: - Menu state

/// Source Edit (v1.12 S-D12) as the File menu sees the focused document: the
/// title of "Edit Source" / "Done Editing", whether Save and Discard Changes
/// are enabled, and the commands that must be off while the editor shows
/// (Export, Print, Copy Markdown, Open in External Editor act on the SAVED
/// text, not the one the user is looking at). Non-optional for the same
/// reason as `FocusedExportNameKey`.
struct SourceEditMenuState: Equatable {
    let isEditing: Bool
    let isDirty: Bool
    /// The editor and the rendered document side by side (File ▸ Edit Side
    /// by Side). Not "Split View": that is the macOS window feature.
    var isSideBySide = false

    var canSave: Bool { isEditing && isDirty }

    /// Print, Export as PDF and Copy Markdown act on the SAVED text. Off
    /// while editing — side by side too, where the preview shows the buffer.
    var allowsSavedTextCommands: Bool { !isEditing }

    /// ⌥⇧⌘E's title: "Editor Only" only while editing side by side; from
    /// reading or the editor alone it turns side by side on.
    static func sideBySideTitle(for state: SourceEditMenuState?) -> String {
        state?.isEditing == true && state?.isSideBySide == true ? "Editor Only" : "Edit Side by Side"
    }
}

// MARK: - What the preview shows

/// The text the rendered list shows instead of the saved text, or nil (the
/// saved text). ONE rule, applied on every buffer change (debounced), on every
/// buffer replacement (load / reload: no `onChange`), on every commit of the
/// rendered text, on toggling and on leaving — a path that skips it leaves the
/// preview showing text that is neither the buffer nor the disk.
struct SideBySidePreview: Equatable {

    /// What the list shows instead of the saved text; nil = the saved text.
    private(set) var text: String?

    /// The rule. `buffer` is asked only while the split shows: reading it
    /// copies the whole buffer.
    ///
    /// Equality is `SourceEditSession.isSameText` (UTF-16 code units), as for
    /// "dirty": a buffer that differs from the disk only in normalization is
    /// unsaved text, and the preview shows it.
    static func text(isShowing: Bool, buffer: () -> String, rendered: String) -> String? {
        guard isShowing else { return nil }
        let buffer = buffer()
        return SourceEditSession.isSameText(buffer, rendered) ? nil : buffer
    }

    /// Applies the rule; true when `text` changed (the view publishes it).
    @discardableResult
    mutating func refresh(isShowing: Bool, buffer: () -> String, rendered: String) -> Bool {
        let next = Self.text(isShowing: isShowing, buffer: buffer, rendered: rendered)
        switch (next, text) {
        case (nil, nil):
            return false
        case let (next?, current?) where SourceEditSession.isSameText(next, current):
            return false
        default:
            text = next
            return true
        }
    }

    /// What the list renders: the preview while the split shows, otherwise
    /// ALWAYS the saved text — a preview left over from the split (leaving
    /// publishes its reset a moment later) never reaches the list.
    static func renderedSource(isShowing: Bool, preview: String?, current: String) -> String {
        isShowing ? (preview ?? current) : current
    }

    /// The text a section copy slices: the one the headings it is given were
    /// parsed from (`installedText`). In the split that is the buffer the
    /// preview shows — slicing the disk text at the buffer's heading lines
    /// copied the wrong lines (or nothing) after an edit above the heading.
    /// Outside side by side (reading, the editor alone) exactly as before:
    /// the saved text.
    static func sectionSource(isShowing: Bool, installed: String?, current: String) -> String {
        isShowing ? (installed ?? current) : current
    }
}

// MARK: - When the preview re-parses

/// Paces the preview's re-parse while the user types.
///
/// - Debounce 0.3 s, but at most `maximumWait` after the first edit not yet
///   shown — continuous typing never pauses, and the preview must not freeze.
/// - Single flight: while a parse is running (ANY parse of this window: the
///   preview's, a zoom's, a theme's) nothing is published; the latest buffer
///   goes out when it lands. So at most one preview parse runs, and none is
///   started only to be superseded (the detached parse cannot be cancelled —
///   superseded ones used to pile up, each holding tens of MB on a 1 MB file).
/// - Big documents (above `largeDocumentLength` UTF-16 units) widen both
///   waits to the last parse's duration and measure the maximum wait from the
///   END of the last parse: while typing, the preview keeps a core busy about
///   half of the time at most.
///
/// Per keystroke: one timer re-armed (`bufferChanged`), nothing read or
/// copied. Main-thread by convention, like `SourceEditSession`.
final class PreviewRefreshScheduler {

    static let debounce: TimeInterval = 0.3
    static let maximumWait: TimeInterval = 1
    static let largeDocumentLength = 256 * 1024

    /// Publishes the preview (the view applies `SideBySidePreview`).
    var publish: () -> Void = {}

    /// Seconds on a monotonic clock; injectable for the tests.
    var now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    /// Runs `work` after `delay` seconds; injectable for the tests.
    var schedule: (_ delay: TimeInterval, _ work: DispatchWorkItem) -> Void = { delay, work in
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private(set) var parsesInFlight = 0
    private(set) var lastParseDuration: TimeInterval = 0
    private var lastParseEnd: TimeInterval?
    /// The first edit not shown yet, and the latest one.
    private var firstPendingEdit: TimeInterval?
    private var lastEdit: TimeInterval = 0
    private var bufferLength = 0
    /// Something must be published once no parse runs.
    private var publishWhenIdle = false
    private var timer: DispatchWorkItem?

    /// The buffer changed (typing, undo, replaceAll). `length` is its UTF-16
    /// length (O(1) from the text storage).
    func bufferChanged(length: Int) {
        let time = now()
        bufferLength = length
        lastEdit = time
        if firstPendingEdit == nil { firstPendingEdit = time }
        arm()
    }

    /// Publish now — or, while a parse runs, the moment it lands. For every
    /// replacement of the buffer or the saved text, toggling and leaving: the
    /// preview must not wait for a debounce, and it must never stay stale.
    func flush() {
        cancelTimer()
        firstPendingEdit = nil
        guard parsesInFlight == 0 else {
            publishWhenIdle = true
            return
        }
        publishWhenIdle = false
        publish()
    }

    /// A parse of this window started (the view's parse task).
    func parseStarted() {
        parsesInFlight += 1
    }

    /// That parse finished, landed or not.
    func parseFinished(duration: TimeInterval) {
        parsesInFlight = max(parsesInFlight - 1, 0)
        lastParseDuration = duration
        lastParseEnd = now()
        guard parsesInFlight == 0 else { return }
        if firstPendingEdit != nil {
            // Typing went on during the parse: its own deadline, measured
            // from now for a big document.
            arm()
        } else if publishWhenIdle {
            publishWhenIdle = false
            publish()
        }
    }

    /// Nothing pending survives (the view disappeared, the session left).
    func cancel() {
        cancelTimer()
        firstPendingEdit = nil
        publishWhenIdle = false
    }

    /// When the pending edits go out: `debounce` after the last one, at most
    /// `maximumWait` after the first. A big document waits at least as long
    /// as its last parse took, for both, and the maximum wait starts at the
    /// end of that parse if it is later: parse, wait as long, parse again.
    func deadline() -> TimeInterval? {
        guard let first = firstPendingEdit else { return nil }
        guard bufferLength > Self.largeDocumentLength else {
            return min(lastEdit + Self.debounce, first + Self.maximumWait)
        }
        let debounce = max(Self.debounce, lastParseDuration)
        let maximumWait = max(Self.maximumWait, lastParseDuration)
        let waitStart = max(first, lastParseEnd ?? first)
        return min(lastEdit + debounce, waitStart + maximumWait)
    }

    private func arm() {
        cancelTimer()
        guard let deadline = deadline() else { return }
        let work = DispatchWorkItem { [weak self] in self?.timerFired() }
        timer = work
        schedule(max(deadline - now(), 0), work)
    }

    private func timerFired() {
        timer = nil
        guard parsesInFlight == 0 else {
            // `parseFinished` re-arms: the edits are still pending.
            return
        }
        firstPendingEdit = nil
        publishWhenIdle = false
        publish()
    }

    private func cancelTimer() {
        timer?.cancel()
        timer = nil
    }
}

// MARK: - How wide the window must be

/// Side by side needs room for two columns: the editor and the preview get
/// at least `minimumDocumentWidth` together (two ~350 pt halves), beside
/// whatever sidebars show.
enum SideBySideLayout {

    static let minimumDocumentWidth: CGFloat = 700
    /// The window's own floor outside the split (`MarkdownView`'s frame).
    static let standardMinimumWidth: CGFloat = 400

    enum Fit: Equatable {
        /// Wide enough already.
        case fits
        /// Grow the window to this frame first.
        case grow(to: NSRect)
        /// The screen cannot hold it (or the window cannot be resized).
        case tooNarrow
    }

    /// The window content width side by side needs, with `sidebars` points
    /// of sidebars beside the document.
    static func requiredContentWidth(sidebars: CGFloat) -> CGFloat {
        minimumDocumentWidth + max(sidebars, 0)
    }

    /// What entering side by side does to a window whose frame is
    /// `windowFrame` with `contentWidth` points of content. Grows to the right
    /// and keeps the top edge; moves left only as far as the screen's visible
    /// frame requires. A full-screen window cannot grow.
    static func fit(windowFrame: NSRect, contentWidth: CGFloat, requiredContentWidth: CGFloat,
                    screenFrame: NSRect?, isFullScreen: Bool) -> Fit {
        let missing = (requiredContentWidth - contentWidth).rounded(.up)
        guard missing > 0 else { return .fits }
        guard !isFullScreen else { return .tooNarrow }
        var frame = windowFrame
        frame.size.width += missing
        guard let screen = screenFrame else { return .grow(to: frame) }
        guard frame.width <= screen.width else { return .tooNarrow }
        if frame.maxX > screen.maxX { frame.origin.x = screen.maxX - frame.width }
        if frame.minX < screen.minX { frame.origin.x = screen.minX }
        return .grow(to: frame)
    }
}
