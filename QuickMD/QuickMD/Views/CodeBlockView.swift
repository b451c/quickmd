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
    var searchText: String = ""
    var focusedOccurrence: Int? = nil

    @State private var contentHeight: CGFloat = 20
    /// Cache of the highlighted NSAttributedString. Keyed by `cacheKey` so we
    /// only recompute when the code or theme actually changes — not on every
    /// scroll-induced body re-evaluation.
    @State private var cachedAttributed: NSAttributedString?
    @State private var cachedKey: String = ""

    private var cacheKey: String {
        // theme.name + a content fingerprint. We use code.count + first/last chars
        // to keep the key cheap; if anyone manages a collision we just recompute.
        "\(theme.name)|\(code.count)|\(code.prefix(8))…\(code.suffix(8))"
    }

    var body: some View {
        let attributed = (cacheKey == cachedKey ? cachedAttributed : nil) ?? computeHighlightedAttributedString()

        return VStack(alignment: .leading, spacing: 0) {
            if !language.isEmpty {
                Text(language)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(theme.secondaryTextColor)
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                    .padding(.bottom, 4)
            }

            CodeTextView(
                attributed: attributed,
                searchTerm: searchText,
                focusedOccurrence: focusedOccurrence,
                contentHeight: $contentHeight
            )
            .frame(height: contentHeight)
            .padding(.horizontal, 12)
            .padding(.vertical, language.isEmpty ? 12 : 8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(theme.codeBackgroundColor)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .task(id: cacheKey) {
            // Compute (or recompute on theme/code change) on the main actor — the
            // work is cheap for typical blocks but cached so this runs once per
            // (code, theme) tuple, not per body eval.
            let key = cacheKey
            let attr = computeHighlightedAttributedString()
            cachedAttributed = attr
            cachedKey = key
        }
    }

    // MARK: - Static Regex Patterns (compiled once, reused)

    private static let commentRegex = try! NSRegularExpression(pattern: #"(//.*|#.*|--.*)"#)
    private static let stringRegex = try! NSRegularExpression(pattern: #"\"[^\"]*\"|'[^']*'"#)
    private static let numberRegex = try! NSRegularExpression(pattern: #"\b\d+\.?\d*\b"#)
    private static let keywordRegex = try! NSRegularExpression(pattern: #"\b(func|function|def|class|struct|enum|let|var|const|if|else|for|while|return|import|from|pub|fn|async|await|try|catch|throw|new|self|this|nil|null|true|false|None|True|False)\b"#)
    private static let typeRegex = try! NSRegularExpression(pattern: #"\b[A-Z][a-zA-Z0-9]*\b"#)

    // MARK: - Highlighted NSAttributedString

    private func computeHighlightedAttributedString() -> NSAttributedString {
        #if DEBUG
        let signpostID = codeSignpost.makeSignpostID()
        let state = codeSignpost.beginInterval("compute", id: signpostID, "lines=\(code.split(separator: "\n").count)")
        defer { codeSignpost.endInterval("compute", state) }
        #endif

        let result = NSMutableAttributedString(string: code)
        let fullRange = NSRange(location: 0, length: (code as NSString).length)
        let baseFont = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)

        result.addAttribute(.font, value: baseFont, range: fullRange)
        result.addAttribute(.foregroundColor, value: NSColor(theme.textColor), range: fullRange)

        var coloredRanges: [NSRange] = []

        func apply(regex: NSRegularExpression, color: Color) {
            let nsColor = NSColor(color)
            for match in regex.matches(in: code, range: fullRange) {
                let range = match.range
                let overlaps = coloredRanges.contains { $0.intersection(range) != nil }
                guard !overlaps else { continue }
                result.addAttribute(.foregroundColor, value: nsColor, range: range)
                coloredRanges.append(range)
            }
        }

        // Same priority as v1.4: strings > comments > others
        apply(regex: Self.stringRegex, color: theme.stringColor)
        apply(regex: Self.commentRegex, color: theme.commentColor)
        apply(regex: Self.numberRegex, color: theme.numberColor)
        apply(regex: Self.keywordRegex, color: theme.keywordColor)
        apply(regex: Self.typeRegex, color: theme.typeColor)

        #if DEBUG
        codeLog.debug("compute: \(code.count) chars, \(coloredRanges.count) ranges, theme=\(theme.name, privacy: .public)")
        #endif
        return result
    }
}

// MARK: - NSTextView Wrapper

/// Self-sizing, read-only NSTextView wrapper. Reports its computed height to the
/// parent SwiftUI view via `contentHeight` binding so SwiftUI can give it the
/// correct frame. Search highlighting is applied via `temporaryAttributes` on the
/// layout manager (no rebuild of the text storage).
private struct CodeTextView: NSViewRepresentable {
    let attributed: NSAttributedString
    let searchTerm: String
    let focusedOccurrence: Int?
    @Binding var contentHeight: CGFloat

    func makeNSView(context: Context) -> SelfSizingTextView {
        #if DEBUG
        let signpostID = codeSignpost.makeSignpostID()
        let state = codeSignpost.beginInterval("makeNSView", id: signpostID)
        defer { codeSignpost.endInterval("makeNSView", state) }
        #endif

        let textView = SelfSizingTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.allowsUndo = false
        textView.usesFindBar = false
        textView.heightCallback = { [weak textView] newHeight in
            guard textView != nil else { return }
            DispatchQueue.main.async {
                if abs(self.contentHeight - newHeight) > 0.5 {
                    self.contentHeight = newHeight
                }
            }
        }
        #if DEBUG
        codeLog.debug("makeNSView: created NSTextView, attr length=\(attributed.length)")
        #endif
        return textView
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
        }

        // Search highlight only re-applied when the term or focused-occurrence changed.
        let searchChanged = (textView.lastSearchTerm != searchTerm) ||
                            (textView.lastFocusedOccurrence != focusedOccurrence)
        if textChanged || searchChanged {
            applySearchHighlight(in: textView)
            textView.lastSearchTerm = searchTerm
            textView.lastFocusedOccurrence = focusedOccurrence
        }

        // Refresh the height callback closure (the binding may capture different
        // state across renders).
        textView.heightCallback = { [weak textView] newHeight in
            guard textView != nil else { return }
            DispatchQueue.main.async {
                if abs(self.contentHeight - newHeight) > 0.5 {
                    self.contentHeight = newHeight
                }
            }
        }

        // Only force a height recompute when text actually changed; otherwise the
        // text view's own layout() callback handles width changes naturally.
        if textChanged {
            textView.recomputeHeightIfNeeded()
        }
    }

    private func applySearchHighlight(in textView: NSTextView) {
        guard let layoutManager = textView.layoutManager,
              let storage = textView.textStorage else { return }
        let fullRange = NSRange(location: 0, length: storage.length)
        layoutManager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: fullRange)

        guard !searchTerm.isEmpty else { return }

        let plain = storage.string as NSString
        let needle = searchTerm.lowercased() as NSString
        let lowerHaystack = (storage.string.lowercased()) as NSString
        guard needle.length > 0, lowerHaystack.length >= needle.length else { return }

        let yellow = NSColor.systemYellow.withAlphaComponent(0.55)
        let orange = NSColor.systemOrange

        var location = 0
        var occurrenceIndex = 0
        while location < lowerHaystack.length {
            let searchRange = NSRange(location: location, length: lowerHaystack.length - location)
            let found = lowerHaystack.range(of: needle as String, options: [], range: searchRange)
            if found.location == NSNotFound { break }
            let safeRange = NSIntersectionRange(found, NSRange(location: 0, length: plain.length))
            if safeRange.length > 0 {
                let color = (focusedOccurrence == occurrenceIndex) ? orange : yellow
                layoutManager.addTemporaryAttribute(.backgroundColor, value: color, forCharacterRange: safeRange)
            }
            location = found.location + max(found.length, 1)
            occurrenceIndex += 1
        }
    }
}

// MARK: - Self-Sizing NSTextView

/// NSTextView that reports its content height through `heightCallback` whenever
/// layout completes. Used by `CodeTextView` to drive the SwiftUI `.frame(height:)`.
final class SelfSizingTextView: NSTextView {
    var heightCallback: ((CGFloat) -> Void)?
    /// Identity reference to the last-applied attributed string. Lets the wrapper
    /// short-circuit `updateNSView` work when SwiftUI hands us the same instance.
    var cachedAttributed: NSAttributedString?
    /// Last applied search term + focused occurrence. Lets us skip
    /// `applySearchHighlight` when neither changed.
    var lastSearchTerm: String = ""
    var lastFocusedOccurrence: Int?

    private var lastReportedHeight: CGFloat = -1
    private var lastLayoutWidth: CGFloat = -1

    override func layout() {
        super.layout()
        // Only recompute if width actually changed — saves work on no-op layout
        // passes triggered by parent scroll/redraw cycles.
        if abs(bounds.width - lastLayoutWidth) > 0.5 {
            lastLayoutWidth = bounds.width
            recomputeHeightIfNeeded()
        }
    }

    override func resize(withOldSuperviewSize oldSize: NSSize) {
        super.resize(withOldSuperviewSize: oldSize)
        recomputeHeightIfNeeded()
    }

    func recomputeHeightIfNeeded() {
        guard let lm = layoutManager, let tc = textContainer else { return }
        let width = bounds.width > 0 ? bounds.width : tc.containerSize.width
        if width > 0 {
            tc.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        }
        lm.ensureLayout(for: tc)
        let used = lm.usedRect(for: tc).height
        let h = ceil(used)
        if abs(h - lastReportedHeight) > 0.5 {
            lastReportedHeight = h
            heightCallback?(h)
        }
    }
}

// MARK: - NSRange Helpers

private extension NSRange {
    func intersection(_ other: NSRange) -> NSRange? {
        let start = max(location, other.location)
        let end = min(location + length, other.location + other.length)
        if start < end {
            return NSRange(location: start, length: end - start)
        }
        return nil
    }
}
