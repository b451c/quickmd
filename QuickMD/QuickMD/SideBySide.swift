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
/// - Hiding never waits: leaving side by side clears the preview at once
///   (`hide`), even while a parse runs — a reset deferred to the parse's end
///   came BACK when side by side was turned on again meanwhile.
/// - While Source Edit is active, the window's parse task waits for a running
///   parse to finish (`waitUntilIdle`): toggling or leaving changes the
///   list's text while a parse runs, and a second detached parse must not
///   start next to it. Outside Source Edit it waits ONLY for a running parse
///   of preview text (left over from a session that just ended) — the
///   viewer's own parses (zoom, theme, reload, open) start at once and
///   supersede each other exactly as before side by side existed.
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
    /// The running parses of PREVIEW text (side by side, buffer != disk).
    private(set) var previewParsesInFlight = 0
    private(set) var lastParseDuration: TimeInterval = 0
    private var lastParseEnd: TimeInterval?
    /// The first edit not shown yet, and the latest one.
    private var firstPendingEdit: TimeInterval?
    private var lastEdit: TimeInterval = 0
    private var bufferLength = 0
    /// Something must be published once no parse runs.
    private var publishWhenIdle = false
    private var timer: DispatchWorkItem?
    /// Run once no parse is in flight (`whenIdle`).
    private var idleWaiters: [() -> Void] = []

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

    /// Side by side is gone (toggled off, the session left): publish NOW,
    /// whatever runs — the view's rule then says "no preview". Clearing never
    /// waits for a parse; only showing a new buffer does.
    func hide() {
        cancel()
        publish()
    }

    /// Must a parse task started now wait? Editing: while ANY parse runs
    /// (one detached parse at a time). Not editing: only while a parse of
    /// preview text runs — otherwise the viewer's scheduling is untouched.
    func mustWait(isEditing: Bool) -> Bool {
        isEditing ? parsesInFlight > 0 : previewParsesInFlight > 0
    }

    /// `body` runs once `mustWait(isEditing:)` is false: now, or after a
    /// parse finished — re-checked then, as another may have started first.
    func whenIdle(isEditing: Bool = true, _ body: @escaping () -> Void) {
        guard mustWait(isEditing: isEditing) else { return body() }
        idleWaiters.append { [weak self] in
            guard let self else { return body() }
            self.whenIdle(isEditing: isEditing, body)
        }
    }

    /// `whenIdle` for the view's parse task. A task cancelled while it waits
    /// still wakes (when the running parse ends) and then returns without
    /// parsing. The view calls it only when `mustWait` — a task that need
    /// not wait has no suspension point added.
    func waitUntilIdle(isEditing: Bool) async {
        repeat {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                whenIdle(isEditing: isEditing) { continuation.resume() }
            }
        } while mustWait(isEditing: isEditing)
    }

    /// A parse of this window started (the view's parse task); `isPreview`:
    /// of preview text.
    func parseStarted(isPreview: Bool = false) {
        parsesInFlight += 1
        if isPreview { previewParsesInFlight += 1 }
    }

    /// That parse finished, landed or not.
    func parseFinished(duration: TimeInterval, isPreview: Bool = false) {
        parsesInFlight = max(parsesInFlight - 1, 0)
        if isPreview { previewParsesInFlight = max(previewParsesInFlight - 1, 0) }
        lastParseDuration = duration
        lastParseEnd = now()
        // Waiters re-check their own condition (a viewer task waits only for
        // preview parses, which may end while another parse still runs).
        defer {
            let waiters = idleWaiters
            idleWaiters.removeAll()
            waiters.forEach { $0() }
        }
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

    /// The window's minimum content width while side by side shows, decided
    /// right after `fit` was applied (`contentWidth`: the window's content
    /// width THEN, grown or not): what side by side needs when the window has
    /// it, otherwise never more than the window already has — a minimum above
    /// that would push the window off the screen or clip the content (full
    /// screen, a Split View tile, a small screen); the halves just get
    /// narrower. Never below the window's usual floor.
    static func minimumContentWidth(required: CGFloat, contentWidth: CGFloat) -> CGFloat {
        max(min(required, contentWidth), standardMinimumWidth)
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

// MARK: - Giving the grown width back

/// Who owns the width side by side added to a window: ONE state for the whole
/// process, keyed by the window GROUP (a window and its native tabs share one
/// frame). Pure: windows are opaque ids, sizes are passed in — the caller
/// (`WindowSizeMemory`) resolves a window's group at QUERY time
/// (`tabbedWindows ?? [window]`), never from a list captured when it grew, so
/// a tab that joins the group later belongs to it and a tab dragged out into
/// its own window does not. No window is referenced, only ids.
///
/// Rules (each a test in `SideBySideTests`):
/// - The first growth of a group records its pre-grow SIZE; a later growth
///   keeps it — unless the user resized the window by hand since the last
///   growth (its size is no longer the grown size, 1 pt tolerance; a move is
///   not a resize): then the user's size is the new pre-grow size.
/// - The group is grown while at least one of its tabs shows side by side.
/// - While grown, the size to remember (resize end, close, quit) is the
///   pre-grow size — unless the user resized by hand: then theirs.
/// - Only the LAST side-by-side tab leaving (toggle off, Done / Esc, closing
///   it) gives the width back, and only if the size is still the grown one;
///   the caller keeps the current origin (`restoredFrame`). Never while
///   another tab of the group still shows side by side.
/// - Full screen: nothing is remembered meanwhile; leaving side by side in
///   full screen defers the give-back to the exit from full screen (AppKit
///   puts the grown frame back then). Full screen ENTERED while side by side
///   needs nothing: leaving full screen restores the grown size, the group is
///   still grown.
struct SideBySideGrowthState: Equatable {

    struct Entry: Equatable {
        /// The size before the growth (what is given back / remembered).
        var preGrowSize: NSSize
        /// The size the last growth set.
        var grownSize: NSSize
        /// The windows (tabs) of the group showing side by side.
        var sideBySide: Set<Int>
        /// Nobody shows side by side any more, but the group was in full
        /// screen: the give-back waits for its exit. The group's windows then.
        var waitingForFullScreenExit: Set<Int> = []

        var members: Set<Int> { sideBySide.union(waitingForFullScreenExit) }
    }

    private(set) var entries: [Entry] = []

    /// 1 pt: AppKit rounds the frames it is given.
    static func same(_ a: NSSize, _ b: NSSize) -> Bool {
        abs(a.width - b.width) < 1 && abs(a.height - b.height) < 1
    }

    private func index(of group: Set<Int>) -> Int? {
        entries.firstIndex { !$0.members.isDisjoint(with: group) }
    }

    func isGrown(group: Set<Int>) -> Bool { index(of: group) != nil }

    /// Window `window` (of `group`) grew from `before` to `after`.
    mutating func didGrow(window: Int, group: Set<Int>, from before: NSSize, to after: NSSize) {
        guard let i = index(of: group) else {
            entries.append(Entry(preGrowSize: before, grownSize: after, sideBySide: [window]))
            return
        }
        // Resized by hand since the last growth: that size is the user's.
        if !Self.same(before, entries[i].grownSize) { entries[i].preGrowSize = before }
        entries[i].grownSize = after
        entries[i].sideBySide.insert(window)
        entries[i].waitingForFullScreenExit = []
    }

    /// Window `window` shows side by side without growing (it fit): a grown
    /// group stays grown until this tab leaves too.
    mutating func didShowWithoutGrowing(window: Int, group: Set<Int>) {
        guard let i = index(of: group) else { return }
        entries[i].sideBySide.insert(window)
    }

    /// Window `window` stops showing side by side — left it, or is closing.
    /// `remaining`: the windows of its group that stay (itself included when
    /// it only left side by side; its tabs when it closes). Returns the width
    /// to give back to `remaining` now, or nil.
    mutating func didLeave(window: Int, remaining: Set<Int>, size: NSSize, isFullScreen: Bool) -> CGFloat? {
        guard let i = entries.firstIndex(where: { $0.sideBySide.contains(window) }) else { return nil }
        entries[i].sideBySide.remove(window)
        // Another tab still shows side by side: it needs the width.
        guard entries[i].sideBySide.isEmpty else { return nil }
        if isFullScreen && !remaining.isEmpty {
            entries[i].waitingForFullScreenExit = remaining
            return nil
        }
        let entry = entries.remove(at: i)
        guard !remaining.isEmpty, !isFullScreen, Self.same(size, entry.grownSize) else { return nil }
        return entry.preGrowSize.width
    }

    /// The group left full screen and has size `size` again.
    mutating func didExitFullScreen(group: Set<Int>, size: NSSize) -> CGFloat? {
        guard let i = index(of: group), entries[i].sideBySide.isEmpty,
              !entries[i].waitingForFullScreenExit.isEmpty else { return nil }
        let entry = entries.remove(at: i)
        return Self.same(size, entry.grownSize) ? entry.preGrowSize.width : nil
    }

    /// A window closed (after its size was remembered and `didLeave` ran):
    /// forget it; a group's state goes with its last window.
    mutating func didClose(window: Int) {
        for i in entries.indices.reversed() {
            entries[i].sideBySide.remove(window)
            entries[i].waitingForFullScreenExit.remove(window)
            if entries[i].members.isEmpty { entries.remove(at: i) }
        }
    }

    /// What `WindowSizeMemory` may remember for a window of `group` whose size
    /// is `size`: nil in full screen, the pre-grow size while grown and not
    /// resized by hand, otherwise the size itself.
    func sizeToRemember(group: Set<Int>, size: NSSize, isFullScreen: Bool) -> NSSize? {
        guard !isFullScreen else { return nil }
        guard let i = index(of: group), Self.same(size, entries[i].grownSize) else { return size }
        return entries[i].preGrowSize
    }

    /// The frame giving `width` back to a window at `current`: the current
    /// origin (never an old position or display), moved only as far as the
    /// screen's visible frame needs.
    static func restoredFrame(current: NSRect, width: CGFloat, screen: NSRect?) -> NSRect {
        var frame = current
        frame.size.width = width
        if let screen {
            if frame.maxX > screen.maxX { frame.origin.x = screen.maxX - frame.width }
            if frame.minX < screen.minX { frame.origin.x = screen.minX }
        }
        return frame
    }
}
