import SwiftUI
import AppKit

// MARK: - Block Height Cache

/// Remembers the last measured height of each block, keyed by block id.
/// LazyVStack destroys and recreates views during scroll; without this a
/// recreated view starts at a placeholder height and "jumps" when its real
/// height arrives, making upward scrolling stutter. Since 1.8.0 text and code
/// blocks size synchronously (`SelfSizingTextView.size(fitting:)`) and no longer
/// need it — Mermaid diagrams (height arrives from the WebView) still do.
///
/// Main-thread only BY CONVENTION (all reads/writes happen from SwiftUI view
/// inits / height callbacks dispatched to main). Deliberately NOT @MainActor:
/// view initializers are nonisolated on older SDKs where the SwiftUI View
/// protocol annotates only `body`, and an isolated init call there is a hard
/// compile error (caught by CI on the GitHub runner toolchain).
final class BlockHeightCache {
    private var heights: [String: CGFloat] = [:]

    func height(for id: String) -> CGFloat? { heights[id] }
    func set(_ height: CGFloat, for id: String) { heights[id] = height }
    func removeAll() { heights.removeAll() }

    /// A value copy for `BlockHeightMeasurer.measure(heightSeeds:)` — the
    /// measurer runs off-main and must not read this reference type from there.
    var snapshot: [String: CGFloat] { heights }
}

// MARK: - Shared NSTextView Search Highlight

/// Search highlighting for NSTextView-hosted blocks (code + text + headings +
/// blockquotes). Applied via the layout manager's temporary attributes — no
/// rebuild of the text storage. Main-thread by convention (called from
/// updateNSView); not @MainActor for older-SDK compatibility (see
/// BlockHeightCache note).
func applyNSSearchHighlight(in textView: NSTextView, term: String, focusedOccurrence: Int?) {
    guard let layoutManager = textView.layoutManager,
          let storage = textView.textStorage else { return }
    let fullRange = NSRange(location: 0, length: storage.length)
    layoutManager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: fullRange)

    guard !term.isEmpty else { return }

    let plain = storage.string as NSString
    let needle = term.lowercased() as NSString
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

// MARK: - Text Block View

/// NSTextView-backed rendering for text-bearing blocks (paragraphs, headings,
/// blockquote bodies, the footnote block). Replaces SwiftUI
/// `Text(...).textSelection(.enabled)`, whose internal SelectionOverlay made
/// LazyVStack unusable (constraints.md, bug B). NSTextView gives native
/// selection, native link handling, and — unlike SwiftUI Text — renders
/// NSTextAttachment, so inline math embeds directly.
struct TextBlockView: View {
    let blockId: String
    let attributed: AttributedString
    var hasInlineMath: Bool = false
    let theme: MarkdownTheme
    var fontScale: CGFloat = 1.0
    /// Bumped by MarkdownView every time a parse produces new blocks. This is
    /// the cache-invalidation signal — see `cacheKey`.
    var contentVersion: Int = 0
    var searchTerm: String = ""
    var focusedOccurrence: Int? = nil
    /// The converted string, already built off-main by `BlockHeightMeasurer`
    /// (it has to build it to measure the row anyway — v1.9 D12). When present
    /// we skip `makeNSAttributedString` entirely, on first render and on every
    /// cell reuse. `nil` for a row whose block is not in the current measured
    /// table — `VirtualBlockList` keeps rendering the PREVIOUS generation's
    /// blocks until the new parse and its height table land together, and
    /// those rows fall back to converting once and caching it in `cachedNS`.
    /// That fallback is load-bearing, not a leftover: without it text blocks
    /// go blank in that window.
    var preconverted: NSAttributedString? = nil
    let onLink: (URL) -> Void

    @State private var cachedNS: NSAttributedString?
    @State private var cachedKey: String = ""

    init(blockId: String, attributed: AttributedString, hasInlineMath: Bool = false,
         theme: MarkdownTheme, fontScale: CGFloat = 1.0, contentVersion: Int = 0,
         searchTerm: String = "", focusedOccurrence: Int? = nil,
         preconverted: NSAttributedString? = nil,
         onLink: @escaping (URL) -> Void) {
        self.blockId = blockId
        self.attributed = attributed
        self.hasInlineMath = hasInlineMath
        self.theme = theme
        self.fontScale = fontScale
        self.contentVersion = contentVersion
        self.searchTerm = searchTerm
        self.focusedOccurrence = focusedOccurrence
        self.preconverted = preconverted
        self.onLink = onLink
    }

    /// Keyed on `contentVersion`, NOT on a theme/scale/length fingerprint.
    /// `attributed` is rebuilt by the parse for every theme, colour-scheme and
    /// zoom change, and a font-size-only change leaves the character count
    /// identical — so any content-blind key reports a false hit and pins the
    /// previous render (that is what made zoom lag one step behind). The
    /// version counter changes exactly when a new `attributed` arrives.
    private var cacheKey: String {
        "\(contentVersion)|\(blockId)"
    }

    var body: some View {
        let ns = preconverted
            ?? (cacheKey == cachedKey ? cachedNS : nil)
            ?? Self.makeNSAttributedString(
                from: attributed, hasInlineMath: hasInlineMath, theme: theme, fontScale: fontScale)

        // Height comes from BlockTextView.sizeThatFits (synchronous, per width) —
        // no state round-trip, so lazy re-creation can't jump or oscillate.
        BlockTextView(
            attributed: ns,
            searchTerm: searchTerm,
            focusedOccurrence: focusedOccurrence,
            onLink: onLink
        )
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: cacheKey) {
            // Nothing to cache when the string was handed to us already built —
            // and skipping the @State write avoids a pointless re-render per cell.
            guard preconverted == nil else { return }
            let key = cacheKey
            cachedNS = ns
            cachedKey = key
        }
    }

    // MARK: - AttributedString → NSAttributedString

    /// Converts the renderer's dual-scope AttributedString into an
    /// NSAttributedString, with inline `$...$` math embedded as
    /// `NSTextAttachment` images.
    ///
    /// The implementation lives in `BlockTextConverter` (BlockHeightMeasurer.swift)
    /// because `BlockHeightMeasurer` sizes a row by laying out this exact string;
    /// this wrapper just binds the production math engine.
    nonisolated static func makeNSAttributedString(from attributed: AttributedString,
                                                   hasInlineMath: Bool,
                                                   theme: MarkdownTheme,
                                                   fontScale: CGFloat) -> NSAttributedString {
        BlockTextConverter.makeNSAttributedString(from: attributed, hasInlineMath: hasInlineMath,
                                                  theme: theme, fontScale: fontScale,
                                                  math: .swiftMath)
    }
}

// MARK: - NSTextView Wrapper

/// Read-only, self-sizing NSTextView for one block. Reuses `SelfSizingTextView`
/// (CodeBlockView.swift) for synchronous height measurement and update
/// short-circuiting.
private struct BlockTextView: NSViewRepresentable {
    let attributed: NSAttributedString
    let searchTerm: String
    let focusedOccurrence: Int?
    let onLink: (URL) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onLink: onLink) }

    func makeNSView(context: Context) -> SelfSizingTextView {
        let textView = SelfSizingTextView()
        textView.configureForSelfSizing()
        textView.delegate = context.coordinator
        // Keep the renderer's link color/underline — only add the pointer cursor.
        // (NSTextView's default linkTextAttributes would repaint links blue.)
        textView.linkTextAttributes = [.cursor: NSCursor.pointingHand]
        return textView
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: SelfSizingTextView, context: Context) -> CGSize? {
        nsView.size(fitting: proposal)
    }

    func updateNSView(_ textView: SelfSizingTextView, context: Context) {
        context.coordinator.onLink = onLink

        let textChanged = (textView.cachedAttributed !== attributed)
        if textChanged {
            textView.textStorage?.setAttributedString(attributed)
            textView.cachedAttributed = attributed
            textView.invalidateMeasurement()
        }

        let searchChanged = (textView.lastSearchTerm != searchTerm) ||
                            (textView.lastFocusedOccurrence != focusedOccurrence)
        if textChanged || searchChanged {
            applyNSSearchHighlight(in: textView, term: searchTerm, focusedOccurrence: focusedOccurrence)
            textView.lastSearchTerm = searchTerm
            textView.lastFocusedOccurrence = focusedOccurrence
        }

    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var onLink: (URL) -> Void

        init(onLink: @escaping (URL) -> Void) { self.onLink = onLink }

        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            if let url = link as? URL {
                onLink(url)
                return true
            }
            if let string = link as? String, let url = URL(string: string) {
                onLink(url)
                return true
            }
            return false
        }
    }
}
