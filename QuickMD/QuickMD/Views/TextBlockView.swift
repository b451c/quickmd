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
    let onLink: (URL) -> Void

    @State private var cachedNS: NSAttributedString?
    @State private var cachedKey: String = ""

    init(blockId: String, attributed: AttributedString, hasInlineMath: Bool = false,
         theme: MarkdownTheme, fontScale: CGFloat = 1.0, contentVersion: Int = 0,
         searchTerm: String = "", focusedOccurrence: Int? = nil,
         onLink: @escaping (URL) -> Void) {
        self.blockId = blockId
        self.attributed = attributed
        self.hasInlineMath = hasInlineMath
        self.theme = theme
        self.fontScale = fontScale
        self.contentVersion = contentVersion
        self.searchTerm = searchTerm
        self.focusedOccurrence = focusedOccurrence
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
        let ns = (cacheKey == cachedKey ? cachedNS : nil) ?? Self.makeNSAttributedString(
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
            let key = cacheKey
            cachedNS = ns
            cachedKey = key
        }
    }

    // MARK: - AttributedString → NSAttributedString

    /// Converts the renderer's dual-scope AttributedString into an
    /// NSAttributedString. For paragraphs containing inline `$...$` math the
    /// math segments are rendered to images (SwiftMath) and embedded as
    /// NSTextAttachment — which NSTextView renders natively (the old SwiftUI
    /// Text pipeline dropped attachments; that constraint no longer applies).
    nonisolated static func makeNSAttributedString(from attributed: AttributedString,
                                                   hasInlineMath: Bool,
                                                   theme: MarkdownTheme,
                                                   fontScale: CGFloat) -> NSAttributedString {
        guard hasInlineMath else {
            return (try? NSAttributedString(attributed, including: \.appKit))
                ?? NSAttributedString(string: String(attributed.characters))
        }

        let plain = String(attributed.characters)
        let segments = InlineMathSegmenter.split(plain)
        let result = NSMutableAttributedString()
        var attrIndex = attributed.startIndex

        for segment in segments {
            switch segment {
            case .text(let str):
                if let end = attributed.characters.index(attrIndex, offsetBy: str.count,
                                                         limitedBy: attributed.endIndex) {
                    let slice = AttributedString(attributed[attrIndex..<end])
                    if let ns = try? NSAttributedString(slice, including: \.appKit) {
                        result.append(ns)
                    } else {
                        result.append(NSAttributedString(string: str))
                    }
                    attrIndex = end
                }

            case .math(let latex):
                // Skip past the $latex$ in the source AttributedString
                let skipCount = latex.count + 2
                if let end = attributed.characters.index(attrIndex, offsetBy: skipCount,
                                                         limitedBy: attributed.endIndex) {
                    attrIndex = end
                }

                if let image = renderMathImage(latex: latex, theme: theme, fontScale: fontScale) {
                    let attachment = NSTextAttachment()
                    attachment.image = image
                    // Center the math image against the 14pt body cap height
                    let bodyFont = theme.fonts.appKit(size: 14 * fontScale)
                    let yOffset = (bodyFont.capHeight - image.size.height) / 2
                    attachment.bounds = CGRect(x: 0, y: yOffset,
                                               width: image.size.width, height: image.size.height)
                    result.append(NSAttributedString(attachment: attachment))
                } else {
                    // Fallback: italic literal, same as the legacy pipeline
                    var attr = AttributedString(latex)
                    attr.setDualFont(size: 14 * fontScale, italic: true, fonts: theme.fonts)
                    attr.setDualForeground(theme.textColor)
                    if let ns = try? NSAttributedString(attr, including: \.appKit) {
                        result.append(ns)
                    }
                }
            }
        }

        return result
    }

    nonisolated private static func renderMathImage(latex: String, theme: MarkdownTheme, fontScale: CGFloat) -> NSImage? {
        var mathImage = MathImage(
            latex: latex,
            fontSize: 14 * fontScale,
            textColor: NSColor(theme.textColor),
            labelMode: .text,
            textAlignment: .left
        )
        let (error, image, _) = mathImage.asImage()
        guard error == nil, let image = image else { return nil }
        return image
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
