import SwiftUI
import AppKit
#if DEBUG
import os
#endif

// MARK: - Code Block View
//
// Renders a fenced code block with syntax highlighting.
// Uses NSTextView (via NSViewRepresentable) instead of SwiftUI Text(AttributedString).
//
// Why NSTextView:
//  1. SwiftUI Text(AttributedString) calls NSAttributedString.replacingLineBreakModes,
//     which is exponentially expensive for box-drawing Unicode (┌│─└) common in
//     ASCII art / tree diagrams. Combined with LazyVStack create/destroy cycles
//     this caused 890MB freezes (v1.3.3 incident).
//  2. NSTextView has native line-fragment layout, no Text-AttributedString trap.
//  3. Native NSTextView selection supports cross-line drag with auto-scroll
//     (SwiftUI textSelection lacks this in lazy contexts).

#if DEBUG
// MARK: - Debug instrumentation (DEBUG builds only — stripped from Release)
//
// Console.app filter: subsystem == "pl.falami.studio.QuickMD" AND category == "CodeBlock"
// Or: log stream --predicate 'subsystem == "pl.falami.studio.QuickMD"' --level debug
private let codeLog = Logger(subsystem: "pl.falami.studio.QuickMD", category: "CodeBlock")
private let codeSignpost = OSSignposter(subsystem: "pl.falami.studio.QuickMD", category: "CodeBlock")
#endif

struct CodeBlockView: View {
    let code: String
    let language: String
    let theme: MarkdownTheme
    var fontScale: CGFloat = 1.0
    var searchText: String = ""
    var focusedOccurrence: Int? = nil

    /// Cache of the highlighted NSAttributedString. Keyed by `cacheKey` so we
    /// only recompute when the code or theme actually changes — not on every
    /// scroll-induced body re-evaluation.
    @State private var cachedAttributed: NSAttributedString?
    @State private var cachedKey: String = ""
    @State private var isHovered = false
    @State private var justCopied = false

    private var cacheKey: String {
        // theme.name + isDark + code font + a content fingerprint. isDark
        // matters because "Auto" keeps its name across light/dark palette
        // flips; the code family because Settings can change it under an
        // unchanged theme name. We use code.count + first/last chars to keep
        // the key cheap; if anyone manages a collision we just recompute.
        "\(theme.name)|\(theme.isDark)|\(theme.fonts.code ?? "")|\(fontScale)|\(code.count)|\(code.prefix(8))…\(code.suffix(8))"
    }

    var body: some View {
        // Show the cached highlighted string when valid; otherwise fall back to
        // a cheap plain-attributed version until `.task(id:)` finishes. The
        // highlight (5 regex passes) is NEVER computed synchronously in body —
        // the eager VStack renders every block on document open, and per-block
        // main-thread regex work was a measurable share of large-doc open time.
        let attributed = (cacheKey == cachedKey ? cachedAttributed : nil) ?? Self.plainAttributedString(code: code, theme: theme, fontScale: fontScale)

        return ZStack(alignment: .topTrailing) {
            VStack(alignment: .leading, spacing: 0) {
                if !language.isEmpty {
                    Text(language)
                        .font(.system(size: 11 * fontScale, weight: .medium, design: .monospaced))
                        .foregroundColor(theme.secondaryTextColor)
                        .padding(.horizontal, 12)
                        .padding(.top, 8)
                        .padding(.bottom, 4)
                }

                CodeTextView(
                    attributed: attributed,
                    searchTerm: searchText,
                    focusedOccurrence: focusedOccurrence
                )
                .padding(.horizontal, 12)
                .padding(.vertical, language.isEmpty ? 12 : 8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(theme.codeBackgroundColor)
            .clipShape(RoundedRectangle(cornerRadius: 6))

            // Hover-to-reveal copy button — the single most common action on a
            // code block in documentation.
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(code, forType: .string)
                justCopied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    justCopied = false
                }
            } label: {
                Image(systemName: justCopied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 11))
                    .foregroundColor(justCopied ? .green : .secondary)
                    .padding(5)
                    .background(theme.backgroundColor.opacity(0.85))
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .focusable(false)
            .help("Copy code")
            .accessibilityLabel("Copy code")
            .opacity(isHovered || justCopied ? 1 : 0)
            .padding(6)
        }
        .onHover { hovering in
            isHovered = hovering
        }
        .task(id: cacheKey) {
            // Compute (or recompute on theme/code change) off the main thread,
            // once per (code, theme) tuple — not per body eval.
            let key = cacheKey
            let code = self.code
            let theme = self.theme
            let fontScale = self.fontScale
            let boxed = await Task.detached(priority: .userInitiated) {
                SendableAttributedString(value: Self.computeHighlightedAttributedString(code: code, theme: theme, fontScale: fontScale))
            }.value
            // The task is cancelled when cacheKey changes (zoom, theme, content).
            // Without this guard a superseded highlight can land last and stick.
            guard !Task.isCancelled else { return }
            cachedAttributed = boxed.value
            cachedKey = key
        }
    }

    // MARK: - Attributed String Construction

    /// Base font + text color only — cheap enough for body while the real
    /// highlight is being computed in the background task.
    nonisolated static func plainAttributedString(code: String, theme: MarkdownTheme, fontScale: CGFloat) -> NSAttributedString {
        let result = NSMutableAttributedString(string: code)
        let fullRange = NSRange(location: 0, length: (code as NSString).length)
        result.addAttribute(.font, value: theme.fonts.appKit(size: 13 * fontScale, monospaced: true), range: fullRange)
        result.addAttribute(.foregroundColor, value: NSColor(theme.textColor), range: fullRange)
        return result
    }

    /// Full syntax highlight. Static + nonisolated so the detached task can run
    /// it off the main actor, capturing plain values (code + theme), not the view.
    nonisolated static func computeHighlightedAttributedString(code: String, theme: MarkdownTheme, fontScale: CGFloat) -> NSAttributedString {
        #if DEBUG
        let signpostID = codeSignpost.makeSignpostID()
        let state = codeSignpost.beginInterval("compute", id: signpostID, "lines=\(code.split(separator: "\n").count)")
        defer { codeSignpost.endInterval("compute", state) }
        #endif

        let result = NSMutableAttributedString(string: code)
        let fullRange = NSRange(location: 0, length: (code as NSString).length)
        let baseFont = theme.fonts.appKit(size: 13 * fontScale, monospaced: true)

        result.addAttribute(.font, value: baseFont, range: fullRange)
        result.addAttribute(.foregroundColor, value: NSColor(theme.textColor), range: fullRange)

        // IndexSet keeps overlap checks O(log n) per match; the previous
        // array-of-ranges scan was quadratic on match-heavy blocks.
        var colored = IndexSet()

        func apply(regex: NSRegularExpression, color: Color) {
            let nsColor = NSColor(color)
            for match in regex.matches(in: code, range: fullRange) {
                guard let range = Range(match.range), !range.isEmpty else { continue }
                guard !colored.intersects(integersIn: range) else { continue }
                result.addAttribute(.foregroundColor, value: nsColor, range: match.range)
                colored.insert(integersIn: range)
            }
        }

        // Same priority as v1.4: strings > comments > others
        apply(regex: CodeHighlightRegex.string, color: theme.stringColor)
        apply(regex: CodeHighlightRegex.comment, color: theme.commentColor)
        apply(regex: CodeHighlightRegex.number, color: theme.numberColor)
        apply(regex: CodeHighlightRegex.keyword, color: theme.keywordColor)
        apply(regex: CodeHighlightRegex.type, color: theme.typeColor)

        #if DEBUG
        codeLog.debug("compute: \(code.count) chars, \(colored.rangeView.count) ranges, theme=\(theme.name, privacy: .public)")
        #endif
        return result
    }
}

/// Transfer box for a freshly built, no-longer-mutated NSAttributedString
/// crossing from the highlight task back to the main actor. Single ownership
/// hand-off — safe despite NSAttributedString not being Sendable.
private struct SendableAttributedString: @unchecked Sendable {
    let value: NSAttributedString
}

// MARK: - Static Regex Patterns (compiled once, reused)
// File-scope (not members of the View struct) so they are not swept into the
// View's implicit @MainActor isolation — the highlight runs on a background task.
private enum CodeHighlightRegex {
    static let comment = try! NSRegularExpression(pattern: #"(//.*|#.*|--.*)"#)
    static let string = try! NSRegularExpression(pattern: #"\"[^\"]*\"|'[^']*'"#)
    static let number = try! NSRegularExpression(pattern: #"\b\d+\.?\d*\b"#)
    static let keyword = try! NSRegularExpression(pattern: #"\b(func|function|def|class|struct|enum|let|var|const|if|else|for|while|return|import|from|pub|fn|async|await|try|catch|throw|new|self|this|nil|null|true|false|None|True|False)\b"#)
    static let type = try! NSRegularExpression(pattern: #"\b[A-Z][a-zA-Z0-9]*\b"#)
}

// MARK: - NSTextView Wrapper

/// Self-sizing, read-only NSTextView wrapper. Its height is answered
/// synchronously from `sizeThatFits` (see `SelfSizingTextView.measuredHeight`),
/// never round-tripped through SwiftUI state. Search highlighting is applied via
/// `temporaryAttributes` on the layout manager (no rebuild of the text storage).
private struct CodeTextView: NSViewRepresentable {
    let attributed: NSAttributedString
    let searchTerm: String
    let focusedOccurrence: Int?

    func makeNSView(context: Context) -> SelfSizingTextView {
        #if DEBUG
        let signpostID = codeSignpost.makeSignpostID()
        let state = codeSignpost.beginInterval("makeNSView", id: signpostID)
        defer { codeSignpost.endInterval("makeNSView", state) }
        #endif

        let textView = SelfSizingTextView()
        textView.configureForSelfSizing()
        #if DEBUG
        codeLog.debug("makeNSView: created NSTextView, attr length=\(attributed.length)")
        #endif
        return textView
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: SelfSizingTextView, context: Context) -> CGSize? {
        nsView.size(fitting: proposal)
    }

    func updateNSView(_ textView: SelfSizingTextView, context: Context) {
        #if DEBUG
        let signpostID = codeSignpost.makeSignpostID()
        let state = codeSignpost.beginInterval("updateNSView", id: signpostID, "len=\(attributed.length) search=\(searchTerm.isEmpty ? "no" : "yes")")
        defer { codeSignpost.endInterval("updateNSView", state) }
        #endif

        // Identity-equal NSAttributedString instances mean nothing has changed —
        // skip ALL work (this is the common path during scroll-induced body evals
        // when the cached attributed string is reused across renders).
        let storageRef = textView.textStorage
        let textChanged = (textView.cachedAttributed !== attributed)

        if textChanged {
            #if DEBUG
            codeLog.debug("updateNSView: text CHANGED — full setAttributedString")
            #endif
            storageRef?.setAttributedString(attributed)
            textView.cachedAttributed = attributed
            textView.invalidateMeasurement()
        }

        // Search highlight only re-applied when the term or focused-occurrence changed.
        let searchChanged = (textView.lastSearchTerm != searchTerm) ||
                            (textView.lastFocusedOccurrence != focusedOccurrence)
        if textChanged || searchChanged {
            applyNSSearchHighlight(in: textView, term: searchTerm, focusedOccurrence: focusedOccurrence)
            textView.lastSearchTerm = searchTerm
            textView.lastFocusedOccurrence = focusedOccurrence
        }

    }

    // Search highlighting shared with TextBlockView — see applyNSSearchHighlight
    // in Views/TextBlockView.swift.
}

// MARK: - Self-Sizing NSTextView

/// Read-only NSTextView whose height is a pure function of the proposed width,
/// answered synchronously from the wrapper's `sizeThatFits` via
/// `size(fitting:)`. Used by `CodeTextView` and `BlockTextView`.
///
/// Measurement runs on a *second* layout manager attached to the same text
/// storage (`measureLayoutManager`), never on the display container: the
/// display container keeps AppKit's default `widthTracksTextView`, so it always
/// wraps at the frame SwiftUI gave us, and a proposal probe at some other width
/// can neither reflow the visible text nor leave the container at a stale
/// width. Same storage + same padding ⇒ both managers wrap identically, so the
/// measured height is exactly the drawn height.
///
/// SwiftUI owns the frame: `isVerticallyResizable` is off so the text view
/// never re-sizes itself after layout (an AppKit-side frame change would
/// invalidate the SwiftUI host, which reassigns the frame, and the two
/// ping-pong at 100 % CPU).
///
/// History: until 1.8.0 the height travelled the other way — `layout()`
/// measured the text and pushed it into SwiftUI `@State` (`.frame(height:)`)
/// on the next runloop turn, so every freshly created block changed size after
/// appearing. See constraints.md ("Block heights are synchronous").
final class SelfSizingTextView: NSTextView {
    /// Identity reference to the last-applied attributed string. Lets the wrapper
    /// short-circuit `updateNSView` work when SwiftUI hands us the same instance.
    var cachedAttributed: NSAttributedString?
    /// Last applied search term + focused occurrence. Lets us skip
    /// `applySearchHighlight` when neither changed.
    var lastSearchTerm: String = ""
    var lastFocusedOccurrence: Int?

    private var measuredWidth: CGFloat = -1
    private var measuredHeight: CGFloat = 0

    private lazy var measureContainer: NSTextContainer = {
        let tc = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        tc.lineFragmentPadding = 0
        tc.widthTracksTextView = false
        tc.heightTracksTextView = false
        return tc
    }()

    private lazy var measureLayoutManager: NSLayoutManager = {
        let lm = NSLayoutManager()
        lm.addTextContainer(measureContainer)
        textStorage?.addLayoutManager(lm)
        return lm
    }()

    /// One-time setup shared by both wrappers (call right after init).
    func configureForSelfSizing() {
        isEditable = false
        isSelectable = true
        drawsBackground = false
        textContainerInset = .zero
        textContainer?.lineFragmentPadding = 0
        textContainer?.widthTracksTextView = true
        isHorizontallyResizable = false
        isVerticallyResizable = false
        autoresizingMask = []
        allowsUndo = false
        usesFindBar = false
        // Touch the TextKit 1 layout manager up front (macOS 12+ text views
        // start in TextKit 2 and switch on first access) so display and
        // measurement share one text storage from the start.
        _ = layoutManager
    }

    /// Forget the cached measurement (call after the text storage changed).
    func invalidateMeasurement() { measuredWidth = -1 }

    /// Height of the current text laid out at `width`, cached per width.
    func measuredHeight(forWidth width: CGFloat) -> CGFloat {
        if abs(width - measuredWidth) < 0.5 { return measuredHeight }
        let lm = measureLayoutManager
        measureContainer.containerSize = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        lm.ensureLayout(for: measureContainer)
        measuredHeight = ceil(lm.usedRect(for: measureContainer).height)
        measuredWidth = width
        return measuredHeight
    }

    /// `sizeThatFits` implementation shared by both wrappers. A concrete width
    /// proposal is measured; an unspecified/zero/infinite width (LazyVStack's
    /// estimate queries) returns the last measurement so the estimate never
    /// reflows the text at a bogus width — or nil (SwiftUI default) before the
    /// first real layout.
    func size(fitting proposal: ProposedViewSize) -> CGSize? {
        if let width = proposal.width, width.isFinite, width > 0 {
            return CGSize(width: width, height: measuredHeight(forWidth: width))
        }
        return measuredWidth > 0 ? CGSize(width: measuredWidth, height: measuredHeight) : nil
    }
}
