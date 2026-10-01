import XCTest
import SwiftUI
import AppKit

/// v1.11 S-D7: heading titles moved from SwiftUI `Text` (in a
/// `.firstTextBaseline` HStack with the copy button) to an NSTextView with the
/// button as an overlay. These tests pin that the move is invisible:
/// the same string and attributes, the same first-baseline alignment of the
/// button, and the same row height as the old SwiftUI heading.
///
/// The views themselves are not compiled into the test bundle, so the old
/// heading is rebuilt here from its pre-v1.11 body, and the new one from the
/// pieces `HeadingBlockView` composes: `BlockTextConverter` (the string),
/// `BlockHeightMeasurer.exactHeight` (the NSTextView's height — its parity with
/// `SelfSizingTextView` is pinned by `BlockHeightMeasurerTests`) and
/// `BlockLayout.Heading.titleGeometry` (the insets and the floor).
final class HeadingLayoutTests: XCTestCase {

    private typealias Metrics = BlockLayout.Heading

    private let levelSizes: [CGFloat] = [32, 26, 22, 18, 16, 14]

    private static let longTitle = String(repeating: "Wrapping heading words ", count: 8)
        .trimmingCharacters(in: .whitespaces)

    private func hostedHeight<V: View>(_ view: V) -> CGFloat {
        NSHostingView(rootView: view).fittingSize.height
    }

    /// The heading's copy button, built exactly as `HeadingBlockView` builds it.
    private var copyButton: some View {
        Button {} label: {
            Image(systemName: "doc.on.doc")
                .font(.system(size: Metrics.copyButtonIconFontSize))
                .foregroundColor(.secondary.opacity(0.7))
                .padding(Metrics.copyButtonIconPadding)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(0)
    }

    /// The pre-v1.11 `HeadingBlockView` body, at a fixed column width.
    private func oldHeadingHeight(_ attributed: AttributedString, width: CGFloat) -> CGFloat {
        hostedHeight(
            HStack(alignment: .firstTextBaseline, spacing: Metrics.copyButtonSpacing) {
                Text(attributed)
                copyButton
            }
            .frame(width: width)
            .fixedSize(horizontal: false, vertical: true)
        )
    }

    /// The v1.11 `HeadingBlockView` composition around a text view that sizes
    /// itself like `SelfSizingTextView` (TextKit height at the proposed width).
    private func newHeadingHeight(_ ns: NSAttributedString, firstFont: NSFont?,
                                  width: CGFloat) -> CGFloat {
        let geometry = Metrics.titleGeometry(titleFirstBaseline: Metrics.titleFirstBaseline(font: firstFont))
        return hostedHeight(
            TextKitHeightView(attributed: ns)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, Metrics.copyButtonReservedWidth)
                .padding(.top, geometry.titleTopInset)
                .frame(minHeight: geometry.minimumHeight, alignment: .top)
                .overlay(alignment: .topTrailing) {
                    copyButton.padding(.top, geometry.buttonTopInset)
                }
                .frame(width: width)
                .fixedSize(horizontal: false, vertical: true)
        )
    }

    private func headingString(_ title: String, level: Int, theme: MarkdownTheme,
                               fontScale: CGFloat) -> (AttributedString, NSAttributedString) {
        let rendered = MarkdownRenderer(theme: theme, fontScale: fontScale).renderHeader(title, level: level)
        let ns = BlockTextConverter.makeNSAttributedString(from: rendered, hasInlineMath: false,
                                                           theme: theme, fontScale: fontScale,
                                                           math: .none)
        return (rendered, ns)
    }

    // MARK: - String

    /// The title view shows — and the selection copies — `renderHeader`'s
    /// output converted for AppKit: same characters, the heading font on every
    /// character, the theme's text colour, links kept, `$…$` literal.
    func testHeadingStringIsRenderHeaderConvertedForAppKit() {
        let titles = ["Plain title", "Title with **bold** and *italic*", "Title with `code`",
                      "See [the docs](https://example.com/docs)", "Energy $E = mc^2$ literal"]
        for dark in [false, true] {
            let theme = MarkdownTheme.cached(for: dark ? .dark : .light)
            for scale in [1.0, 1.5] as [CGFloat] {
                for level in 1...6 {
                    for title in titles {
                        let (rendered, ns) = headingString(title, level: level, theme: theme, fontScale: scale)
                        let context = "H\(level) @\(scale) dark=\(dark) '\(title)'"
                        // The font the view aligns the copy button to.
                        let headerFont = MarkdownRenderer(theme: theme, fontScale: scale)
                            .headerAppKitFont(level: level)
                        let direct = try? NSAttributedString(rendered, including: \.appKit)
                        XCTAssertEqual(ns, direct, context)
                        XCTAssertEqual(ns.string, String(rendered.characters), context)
                        XCTAssertGreaterThan(ns.length, 0, context)

                        let expectedSize = levelSizes[level - 1] * scale
                        for index in 0..<ns.length {
                            guard let font = ns.attribute(.font, at: index, effectiveRange: nil) as? NSFont else {
                                XCTFail("\(context): no font at \(index)")
                                break
                            }
                            XCTAssertEqual(font.pointSize, expectedSize, accuracy: 0.01, context)
                            XCTAssertEqual(font, headerFont, "\(context): font at \(index)")
                            XCTAssertTrue(font.fontDescriptor.symbolicTraits.contains(.bold), context)
                            XCTAssertNotNil(ns.attribute(.foregroundColor, at: index, effectiveRange: nil),
                                            "\(context): no AppKit colour at \(index)")
                            XCTAssertNil(ns.attribute(.attachment, at: index, effectiveRange: nil), context)
                        }
                        if title.contains("](") {
                            var hasLink = false
                            ns.enumerateAttribute(.link, in: NSRange(location: 0, length: ns.length)) { value, _, _ in
                                if value != nil { hasLink = true }
                            }
                            XCTAssertTrue(hasLink, "\(context): link lost in conversion")
                        }
                        if title.contains("$") {
                            XCTAssertTrue(ns.string.contains("$E = mc^2$"), context)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Geometry

    /// `copyButtonBaselineOffset` is the real button's first baseline: hosted
    /// next to a 100 pt baseline-less view on a shared first baseline, the
    /// union is `100 + (height − baseline)`.
    func testCopyButtonBaselineMatchesTheRealButton() {
        let union = hostedHeight(
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Color.clear.frame(width: 1, height: 100)
                copyButton
            }
        )
        let buttonHeight = hostedHeight(copyButton)
        XCTAssertEqual(buttonHeight, Metrics.copyButtonHeight, accuracy: 1)
        XCTAssertEqual(100 + buttonHeight - union, Metrics.copyButtonBaselineOffset, accuracy: 0.5)
    }

    /// `titleFirstBaseline(font:)` is where TextKit really puts the first
    /// baseline of a heading's text view, for every level, zoom step and a
    /// few families (the button aligns to it).
    func testTitleFirstBaselineIsTextKitsFirstLineBaseline() {
        for family in [nil, "Georgia", "Helvetica Neue", "Avenir Next"] as [String?] {
            let fonts = DocumentFonts(body: family, code: nil)
            for scale in [0.8, 1.0, 1.25, 1.5, 2.0] as [CGFloat] {
                for size in levelSizes {
                    var attributed = AttributedString(Self.longTitle)
                    attributed.setDualFont(size: size * scale, bold: true, fonts: fonts)
                    let ns = BlockTextConverter.makeNSAttributedString(
                        from: attributed, hasInlineMath: false,
                        theme: MarkdownTheme.cached(for: .light), fontScale: scale, math: .none)
                    let storage = NSTextStorage(attributedString: ns)
                    let layoutManager = NSLayoutManager()
                    storage.addLayoutManager(layoutManager)
                    let container = NSTextContainer(size: NSSize(width: 300, height: CGFloat.greatestFiniteMagnitude))
                    container.lineFragmentPadding = 0
                    layoutManager.addTextContainer(container)
                    layoutManager.ensureLayout(for: container)
                    let fragment = layoutManager.lineFragmentRect(forGlyphAt: 0, effectiveRange: nil)
                    let laidOut = fragment.minY + layoutManager.location(forGlyphAt: 0).y
                    let font = fonts.appKit(size: size * scale, weight: .bold)
                    XCTAssertEqual(Metrics.titleFirstBaseline(font: font), laidOut,
                                   accuracy: 0.01, "\(family ?? "system") \(size)pt @\(scale)")
                }
            }
        }
    }

    func testTitleGeometryReproducesTheBaselineUnion() {
        let b = Metrics.copyButtonBaselineOffset
        // Large title: the button moves down, the title stays at the top.
        let large = Metrics.titleGeometry(titleFirstBaseline: b + 15)
        XCTAssertEqual(large, .init(titleTopInset: 0, buttonTopInset: 15,
                                    minimumHeight: 15 + Metrics.copyButtonHeight))
        // Small title: the title moves down, the button stays at the top.
        let small = Metrics.titleGeometry(titleFirstBaseline: b - 2)
        XCTAssertEqual(small, .init(titleTopInset: 2, buttonTopInset: 0,
                                    minimumHeight: Metrics.copyButtonHeight))
        // No title font: no insets at all.
        XCTAssertEqual(Metrics.titleGeometry(titleFirstBaseline: Metrics.titleFirstBaseline(font: nil)),
                       .init(titleTopInset: 0, buttonTopInset: 0, minimumHeight: Metrics.copyButtonHeight))
    }

    // MARK: - Row height: new NSTextView heading vs old SwiftUI heading

    /// The `.reported` heading row must not change height with the move.
    ///
    /// Single-line titles (the common case, and the only case where the
    /// copy button decides the height): identical to the point, H1–H6, 100 %
    /// and 150 %, light and dark, at a narrow column, the reading-mode column
    /// and a wide one.
    ///
    /// Wrapping titles: the title is now laid out by TextKit — like every
    /// paragraph — and at a few point sizes of the system font SwiftUI's line
    /// height is 1 pt taller than TextKit's (16 pt = H5 at 100 %, 21 pt = H6
    /// at 150 %; measured: there is no closed form for SwiftUI's rule). Those
    /// rows are therefore up to 1 pt PER LINE shorter than before; everywhere
    /// else they match within 1 pt. The tolerance below is derived per font
    /// from that measured line-height difference, so any other drift fails.
    func testHeadingRowHeightMatchesTheSwiftUIHeading() {
        let widths: [CGFloat] = [260, 720, 1000]
        for dark in [false, true] {
            let theme = MarkdownTheme.cached(for: dark ? .dark : .light)
            for scale in [1.0, 1.5] as [CGFloat] {
                for level in 1...6 {
                    for title in ["Heading", Self.longTitle] {
                        let (rendered, ns) = headingString(title, level: level, theme: theme, fontScale: scale)
                        let font = MarkdownRenderer(theme: theme, fontScale: scale).headerAppKitFont(level: level)
                        for width in widths {
                            let old = oldHeadingHeight(rendered, width: width)
                            let new = newHeadingHeight(ns, firstFont: font, width: width)
                            let textWidth = width - Metrics.copyButtonReservedWidth
                            let lines = lineCount(ns, width: textWidth)
                            let context = "H\(level) @\(scale) dark=\(dark) w=\(width) lines=\(lines): old \(old) new \(new)"
                            if lines == 1 {
                                XCTAssertEqual(new, old, accuracy: 1, context)
                            } else {
                                let perLine = swiftUILineExcess(font)
                                XCTAssertEqual(new, old, accuracy: 1 + perLine * CGFloat(lines), context)
                                XCTAssertLessThanOrEqual(new, old + 1, context)
                            }
                        }
                    }
                }
            }
        }
    }

    /// Lines TextKit breaks `ns` into at `width`.
    private func lineCount(_ ns: NSAttributedString, width: CGFloat) -> Int {
        let storage = NSTextStorage(attributedString: ns)
        let layoutManager = NSLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: width, height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        layoutManager.addTextContainer(container)
        layoutManager.ensureLayout(for: container)
        var lines = 0
        layoutManager.enumerateLineFragments(forGlyphRange: NSRange(location: 0, length: layoutManager.numberOfGlyphs)) { _, _, _, _, _ in
            lines += 1
        }
        return lines
    }

    /// How much taller one SwiftUI `Text` line is than one TextKit line in
    /// the heading's font (0 at most sizes, 1 at a few), measured over ten
    /// hard-broken lines.
    private func swiftUILineExcess(_ font: NSFont) -> CGFloat {
        let tenLines = Array(repeating: "Line", count: 10).joined(separator: "\n")
        let swiftUI = hostedHeight(Text(tenLines).font(Font(font as CTFont)).fixedSize())
        let ns = NSAttributedString(string: tenLines, attributes: [.font: font])
        let textKit = BlockHeightMeasurer.exactHeight(text: ns, width: 10_000)
        return max(0, ceil((swiftUI - textKit) / 10))
    }
}

/// A text view that sizes itself the way `SelfSizingTextView` does: TextKit's
/// height for the string at the proposed width.
private struct TextKitHeightView: NSViewRepresentable {
    let attributed: NSAttributedString

    func makeNSView(context: Context) -> NSTextView {
        let textView = NSTextView()
        textView.configureForSelfSizing()
        textView.textStorage?.setAttributedString(attributed)
        return textView
    }

    func updateNSView(_ nsView: NSTextView, context: Context) {}

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSTextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width.isFinite, width > 0 else { return nil }
        return CGSize(width: width, height: BlockHeightMeasurer.exactHeight(text: attributed, width: width))
    }
}
