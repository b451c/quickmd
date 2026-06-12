import SwiftUI
import AppKit

// MARK: - Block Height Cache

/// Remembers the last measured height of each block, keyed by block id.
/// LazyVStack destroys and recreates views during scroll; without this a
/// recreated NSTextView starts at a placeholder height and "jumps" when its
/// real height arrives, making upward scrolling stutter. Main-thread only
/// (all reads/writes happen from SwiftUI body / height callbacks).
@MainActor
final class BlockHeightCache {
    private var heights: [String: CGFloat] = [:]

    func height(for id: String) -> CGFloat? { heights[id] }
    func set(_ height: CGFloat, for id: String) { heights[id] = height }
    func removeAll() { heights.removeAll() }
}

// MARK: - Shared NSTextView Search Highlight

/// Search highlighting for NSTextView-hosted blocks (code + text + headings +
/// blockquotes). Applied via the layout manager's temporary attributes — no
/// rebuild of the text storage.
@MainActor
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
    var searchTerm: String = ""
    var focusedOccurrence: Int? = nil
    let heightCache: BlockHeightCache
    let onLink: (URL) -> Void

    @State private var contentHeight: CGFloat
    @State private var cachedNS: NSAttributedString?
    @State private var cachedKey: String = ""

    init(blockId: String, attributed: AttributedString, hasInlineMath: Bool = false,
         theme: MarkdownTheme, searchTerm: String = "", focusedOccurrence: Int? = nil,
         heightCache: BlockHeightCache, onLink: @escaping (URL) -> Void) {
        self.blockId = blockId
        self.attributed = attributed
        self.hasInlineMath = hasInlineMath
        self.theme = theme
        self.searchTerm = searchTerm
        self.focusedOccurrence = focusedOccurrence
        self.heightCache = heightCache
        self.onLink = onLink
        // Seed with the last measured height so lazy re-creation doesn't jump.
        _contentHeight = State(initialValue: heightCache.height(for: blockId) ?? 18)
    }

    /// isDark is part of the key: "Auto" resolves to different palettes per
    /// system appearance while keeping the same name.
    private var cacheKey: String {
        "\(theme.name)|\(theme.isDark)|\(blockId)|\(attributed.characters.count)"
    }

    var body: some View {
        let ns = (cacheKey == cachedKey ? cachedNS : nil) ?? Self.makeNSAttributedString(
            from: attributed, hasInlineMath: hasInlineMath, theme: theme)

        BlockTextView(
            attributed: ns,
            searchTerm: searchTerm,
            focusedOccurrence: focusedOccurrence,
            onLink: onLink,
            onHeight: { [weak heightCache] height in
                heightCache?.set(height, for: blockId)
                if abs(contentHeight - height) > 0.5 {
                    contentHeight = height
                }
            }
        )
        .frame(height: contentHeight)
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
                                                   theme: MarkdownTheme) -> NSAttributedString {
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

                if let image = renderMathImage(latex: latex, theme: theme) {
                    let attachment = NSTextAttachment()
                    attachment.image = image
                    // Center the math image against the 14pt body cap height
                    let bodyFont = NSFont.systemFont(ofSize: 14)
                    let yOffset = (bodyFont.capHeight - image.size.height) / 2
                    attachment.bounds = CGRect(x: 0, y: yOffset,
                                               width: image.size.width, height: image.size.height)
                    result.append(NSAttributedString(attachment: attachment))
                } else {
                    // Fallback: italic literal, same as the legacy pipeline
                    var attr = AttributedString(latex)
                    attr.setDualFont(size: 14, italic: true)
                    attr.setDualForeground(theme.textColor)
                    if let ns = try? NSAttributedString(attr, including: \.appKit) {
                        result.append(ns)
                    }
                }
            }
        }

        return result
    }

    nonisolated private static func renderMathImage(latex: String, theme: MarkdownTheme) -> NSImage? {
        var mathImage = MathImage(
            latex: latex,
            fontSize: 14,
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
/// (CodeBlockView.swift) for height reporting and update short-circuiting.
private struct BlockTextView: NSViewRepresentable {
    let attributed: NSAttributedString
    let searchTerm: String
    let focusedOccurrence: Int?
    let onLink: (URL) -> Void
    let onHeight: (CGFloat) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onLink: onLink) }

    func makeNSView(context: Context) -> SelfSizingTextView {
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
        textView.delegate = context.coordinator
        // Keep the renderer's link color/underline — only add the pointer cursor.
        // (NSTextView's default linkTextAttributes would repaint links blue.)
        textView.linkTextAttributes = [.cursor: NSCursor.pointingHand]
        textView.heightCallback = { newHeight in
            DispatchQueue.main.async { onHeight(newHeight) }
        }
        return textView
    }

    func updateNSView(_ textView: SelfSizingTextView, context: Context) {
        context.coordinator.onLink = onLink

        let textChanged = (textView.cachedAttributed !== attributed)
        if textChanged {
            textView.textStorage?.setAttributedString(attributed)
            textView.cachedAttributed = attributed
        }

        let searchChanged = (textView.lastSearchTerm != searchTerm) ||
                            (textView.lastFocusedOccurrence != focusedOccurrence)
        if textChanged || searchChanged {
            applyNSSearchHighlight(in: textView, term: searchTerm, focusedOccurrence: focusedOccurrence)
            textView.lastSearchTerm = searchTerm
            textView.lastFocusedOccurrence = focusedOccurrence
        }

        textView.heightCallback = { newHeight in
            DispatchQueue.main.async { onHeight(newHeight) }
        }

        if textChanged {
            textView.recomputeHeightIfNeeded()
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
