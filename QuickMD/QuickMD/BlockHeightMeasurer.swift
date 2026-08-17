import SwiftUI
import AppKit
#if DEBUG
import os
#endif

// MARK: - Block Height Measurement
//
// One place that answers "how tall will this block be?" WITHOUT building a
// single SwiftUI view, so a document's whole height table can be produced in the
// same background task that parses it (v1.9 "own virtualized block list", D3).
//
// Why this file owns the layout constants AND the attributed-string conversion
// instead of each view owning its own:
//
//  1. Parity is the acceptance criterion. The measured height has to equal the
//     height the placed view reports, to the point. That only holds if the
//     measurer lays out the IDENTICAL NSAttributedString at the IDENTICAL width
//     and adds the IDENTICAL chrome — i.e. if there is exactly one definition of
//     each. The views therefore consume `BlockLayout` (via a `Layout` typealias)
//     rather than repeating literals.
//  2. `QuickMDTests` has no TEST_HOST; it compiles a hand-picked subset of app
//     sources directly (see project.pbxproj). The view files are not in that
//     subset — `TextBlockView.swift` transitively needs the vendored SwiftMath
//     sources and its font bundle. So anything the parity tests must share with
//     production has to live in a file that is cheap to compile into the test
//     target: this one. The only thing that stays behind a seam is the math
//     engine itself, injected as `MathRendering`.
//
// Nothing here is actor-isolated, and it only touches value types plus TextKit 1
// objects it creates itself, so it is safe to call from a detached task.

#if DEBUG
// Console.app filter: subsystem == "pl.falami.studio.QuickMD" AND category == "BlockHeights"
private let heightLog = Logger(subsystem: "pl.falami.studio.QuickMD", category: "BlockHeights")
private let heightSignpost = OSSignposter(subsystem: "pl.falami.studio.QuickMD", category: "BlockHeights")
#endif

// MARK: - Layout Metrics (single source of truth)

/// Every fixed geometry value the block views apply, in one place.
///
/// Each view exposes the namespace it uses as `Layout` (e.g.
/// `CodeBlockView.Layout.horizontalPadding`) and reads its paddings from here,
/// so the measurer, the views and the parity tests can never drift apart.
/// Values are the ones that shipped in 1.8.0 — this is a re-homing, not a
/// redesign. Points are at 1.0 zoom unless the member takes a `fontScale`.
enum BlockLayout {

    // MARK: Document chrome (MarkdownView)

    /// Padding and spacing `MarkdownView` puts around and between blocks.
    /// The per-kind `…OuterVerticalPadding` values are the `.padding(.vertical:)`
    /// modifiers applied in `MarkdownView.blockView(for:)`; they are part of a
    /// row's height because the virtualized list hosts that whole view.
    enum Document {
        static let contentHorizontalPadding: CGFloat = 32
        static let contentVerticalPadding: CGFloat = 24
        static let blockSpacing: CGFloat = 8

        static let tableOuterVerticalPadding: CGFloat = 8
        static let codeOuterVerticalPadding: CGFloat = 4
        static let imageOuterVerticalPadding: CGFloat = 8
        /// 1.8.0 applied `.padding(.vertical, 4)` twice to alerts; 8 pt is the
        /// same geometry expressed once.
        static let alertOuterVerticalPadding: CGFloat = 8
        static let mathOuterVerticalPadding: CGFloat = 4
        static let mermaidOuterVerticalPadding: CGFloat = 4
    }

    // MARK: Code blocks

    enum Code {
        static let horizontalPadding: CGFloat = 12
        /// `.padding(.vertical:)` around the code text — smaller when a language
        /// label already separates the code from the top edge.
        static let verticalPaddingWithoutLanguage: CGFloat = 12
        static let verticalPaddingWithLanguage: CGFloat = 8
        static let languageLabelTopPadding: CGFloat = 8
        static let languageLabelBottomPadding: CGFloat = 4
        static let languageLabelFontSize: CGFloat = 11
        static let codeFontSize: CGFloat = 13
        static let cornerRadius: CGFloat = 6

        /// The language label is a SwiftUI `Text` in the *system monospaced*
        /// face (not the theme's code family — `CodeBlockView` asks for
        /// `.system(design: .monospaced)`).
        static func languageLabelFont(fontScale: CGFloat) -> NSFont {
            .monospacedSystemFont(ofSize: languageLabelFontSize * fontScale, weight: .medium)
        }

        static func languageLabelHeight(fontScale: CGFloat) -> CGFloat {
            BlockLayout.singleLineHeight(for: languageLabelFont(fontScale: fontScale))
        }

        /// Fixed vertical chrome around the code text, language label included.
        static func verticalChrome(hasLanguage: Bool, fontScale: CGFloat) -> CGFloat {
            guard hasLanguage else { return 2 * verticalPaddingWithoutLanguage }
            return languageLabelHeight(fontScale: fontScale)
                + languageLabelTopPadding
                + languageLabelBottomPadding
                + 2 * verticalPaddingWithLanguage
        }
    }

    // MARK: Blockquotes

    enum Quote {
        static let barWidth: CGFloat = 3
        static let barGap: CGFloat = 8
        /// Indent of the whole quote (bars included) from the text margin.
        static let leadingInset: CGFloat = 16
        static let verticalPadding: CGFloat = 2

        /// Width the quote body's text view gets at nesting `level`.
        static func bodyWidth(contentWidth: CGFloat, level: Int) -> CGFloat {
            contentWidth - leadingInset - CGFloat(level) * (barWidth + barGap)
        }
    }

    // MARK: GFM alerts

    enum Alert {
        static let horizontalPadding: CGFloat = 12
        static let verticalPadding: CGFloat = 10
        /// VStack spacing between the icon/title row and the body.
        static let stackSpacing: CGFloat = 6
        /// HStack spacing between the icon and the title (horizontal — does not
        /// enter the height, but belongs with the rest of the alert geometry).
        static let titleRowSpacing: CGFloat = 6
        static let iconFontSize: CGFloat = 13
        static let titleFontSize: CGFloat = 14
        static let accentBarWidth: CGFloat = 3
        static let cornerRadius: CGFloat = 4

        /// Height of the icon + title row.
        ///
        /// NOT exact: both children are SwiftUI leaves, and SwiftUI's single-line
        /// `Text` height is not a published function of `NSFont` metrics (measured
        /// deviations of 0…2 pt from `defaultLineHeight`, in both directions,
        /// depending on point size). `singleLineHeight` is the safe upper bound —
        /// see its documentation.
        static func titleRowHeight(theme: MarkdownTheme, fontScale: CGFloat) -> CGFloat {
            let title = theme.fonts.appKit(size: titleFontSize * fontScale, weight: .semibold)
            let icon = NSFont.systemFont(ofSize: iconFontSize * fontScale, weight: .semibold)
            return max(BlockLayout.singleLineHeight(for: title),
                       BlockLayout.singleLineHeight(for: icon))
        }
    }

    // MARK: Headings

    enum Heading {
        static let copyButtonSpacing: CGFloat = 6
        static let copyButtonIconFontSize: CGFloat = 11
        static let copyButtonIconPadding: CGFloat = 4
        /// Fitting size of the hover-to-copy button, measured with
        /// `NSHostingView` (constant across zoom — the icon font is not scaled).
        static let copyButtonWidth: CGFloat = 21
        static let copyButtonHeight: CGFloat = 24
    }

    // MARK: Tables

    enum Table {
        static let cellHorizontalPadding: CGFloat = 12
        static let headerCellVerticalPadding: CGFloat = 8
        static let cellVerticalPadding: CGFloat = 6
        /// Vertical rule between columns.
        static let dividerWidth: CGFloat = 1
        /// Horizontal rule under the header and between rows.
        static let separatorHeight: CGFloat = 1
        /// The rounded outline around the whole table.
        static let borderWidth: CGFloat = 1
        static let cellFontSize: CGFloat = 13
        static let cornerRadius: CGFloat = 4
    }

    // MARK: Images

    enum ImageBlock {
        /// Height of the placeholder shown until the image has loaded (and of
        /// the remote `ProgressView`). The real height only exists on main once
        /// the bitmap is decoded, so this is what a measured row starts at.
        static let placeholderHeight: CGFloat = 100
        static let maxDisplayWidth: CGFloat = 600
    }

    // MARK: Display math

    enum Math {
        static let verticalPadding: CGFloat = 8
        static let fontSize: CGFloat = 20
    }

    // MARK: Mermaid

    enum Mermaid {
        static let verticalPadding: CGFloat = 8
        /// Height a diagram starts at when nothing has measured it yet.
        static let defaultHeight: CGFloat = 200
        static let cornerRadius: CGFloat = 6
    }

    // MARK: - Single-line height of a SwiftUI `Text`

    /// Upper bound for the height a single-line SwiftUI `Text` takes in `font`.
    ///
    /// SwiftUI does not expose its line-height rule and it does not match any
    /// single `NSFont`/`NSLayoutManager` metric: sampled against
    /// `NSHostingView.fittingSize` for system-semibold 6…22 pt, the zoom ladder
    /// 0.8…2.0 and the monospaced label face, `defaultLineHeight` is 0…1 pt too
    /// small and `ceil(ascender) + ceil(-descender)` is 0…1 pt too small at some
    /// sizes and 1 pt too large at others. Their maximum was never below the
    /// real value in any sample, so that is what we use: a row that is a hairline
    /// too tall shows a hairline gap, a row that is a point too short clips the
    /// view it hosts. Pinned by
    /// `BlockHeightMeasurerTests.testSingleLineHeightNeverUnderestimatesSwiftUIText`.
    static func singleLineHeight(for font: NSFont) -> CGFloat {
        // A fresh layout manager per call: NSLayoutManager is not thread-safe and
        // this runs off-main. Chrome heights are computed once per document in
        // `measure`, so the allocation is not on a hot path.
        let byLayoutManager = NSLayoutManager().defaultLineHeight(for: font)
        let byMetrics = ceil(font.ascender) + ceil(-font.descender)
        return max(byLayoutManager, byMetrics)
    }
}

// MARK: - Math seam

/// The two things measurement needs from the math engine. Injected rather than
/// called directly so this file stays free of the vendored SwiftMath sources
/// (see the file header): production installs `MathRendering.swiftMath`
/// (`MathBlockView.swift`), the parity tests install a deterministic stub.
struct MathRendering {
    /// Renders one inline `$…$` segment for an `NSTextAttachment`, or nil when
    /// the LaTeX does not typeset (the caller then falls back to an italic
    /// literal).
    let inlineImage: (_ latex: String, _ theme: MarkdownTheme, _ fontScale: CGFloat) -> NSImage?
    /// Height `MTMathUILabel` will take for a display-math block.
    let displayHeight: (_ latex: String, _ theme: MarkdownTheme, _ fontScale: CGFloat) -> CGFloat

    /// No math engine: inline math degrades to the italic-literal fallback and
    /// display math to zero intrinsic height. Only for tests and previews.
    static let none = MathRendering(inlineImage: { _, _, _ in nil },
                                    displayHeight: { _, _, _ in 0 })
}

// MARK: - AttributedString → NSAttributedString

/// The conversions that decide a block's laid-out text. Shared by the views that
/// display the text and the measurer that predicts its height — the two MUST
/// operate on byte-identical strings.
enum BlockTextConverter {

    /// Does this paragraph contain inline `$…$` math?
    ///
    /// Same test the parse task applies when it fills `TextBlockMeta`, so a
    /// measurement taken without meta classifies the paragraph identically.
    /// `$` alone is cheap to reject, which most paragraphs are.
    static func containsInlineMath(_ plain: String) -> Bool {
        guard plain.contains("$"), let regex = inlineMathRegex else { return false }
        return regex.firstMatch(in: plain, range: NSRange(plain.startIndex..., in: plain)) != nil
    }

    private static let inlineMathRegex = try? NSRegularExpression(pattern: #"\$[^\s$].*?\$"#)

    /// Converts the renderer's dual-scope AttributedString into the
    /// NSAttributedString an `NSTextView`-backed block installs. For paragraphs
    /// containing inline `$...$` math the math segments are rendered to images
    /// and embedded as `NSTextAttachment` — which NSTextView renders natively
    /// (the old SwiftUI `Text` pipeline dropped attachments; that constraint no
    /// longer applies).
    static func makeNSAttributedString(from attributed: AttributedString,
                                       hasInlineMath: Bool,
                                       theme: MarkdownTheme,
                                       fontScale: CGFloat,
                                       math: MathRendering) -> NSAttributedString {
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

                if let image = math.inlineImage(latex, theme, fontScale) {
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

    /// Base font + text color only. This is what `CodeBlockView` installs while
    /// the syntax highlight is still being computed in the background — and the
    /// string the measurer uses, because the highlight only changes colours, so
    /// the laid-out height is independent of it.
    static func plainCode(_ code: String, theme: MarkdownTheme, fontScale: CGFloat) -> NSAttributedString {
        let result = NSMutableAttributedString(string: code)
        let fullRange = NSRange(location: 0, length: (code as NSString).length)
        result.addAttribute(.font,
                            value: theme.fonts.appKit(size: BlockLayout.Code.codeFontSize * fontScale,
                                                      monospaced: true),
                            range: fullRange)
        result.addAttribute(.foregroundColor, value: NSColor(theme.textColor), range: fullRange)
        return result
    }
}

// MARK: - Read-only NSTextView configuration

extension NSTextView {
    /// One-time setup for a read-only, externally-sized text view (used by every
    /// NSTextView-hosted block, and by the parity tests to reproduce a block's
    /// layout exactly).
    ///
    /// SwiftUI owns the frame: `isVerticallyResizable` is off so the text view
    /// never re-sizes itself after layout (an AppKit-side frame change would
    /// invalidate the SwiftUI host, which reassigns the frame, and the two
    /// ping-pong at 100 % CPU — constraints.md, "Block heights are synchronous").
    /// `lineFragmentPadding = 0` + zero inset are what make an independent
    /// TextKit stack (`BlockHeightMeasurer.exactHeight`) wrap identically.
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
}

// MARK: - Height table

/// How a row's height was obtained, and therefore whether the placed view is
/// allowed to correct it (v1.9 D3).
enum RowKind: Equatable {
    /// Laid out here with the real string at the real width — the placed view
    /// cannot know better, and its height reports are ignored.
    case exact
    /// An estimate. The placed view reports its real height once, and the
    /// coordinator applies the correction.
    case reported
}

/// One height per block, in block order, for a specific content width.
struct BlockHeightTable: Equatable {
    let heights: [CGFloat]
    let kinds: [RowKind]
    /// The width the heights were measured at. A row height is only valid for
    /// this width — the list re-measures when it changes.
    let contentWidth: CGFloat

    var count: Int { heights.count }

    static let empty = BlockHeightTable(heights: [], kinds: [], contentWidth: 0)
}

/// `measure`'s output: the height table plus the NSAttributedStrings that had to
/// be built to produce it, so the views don't build them again on main (D12).
///
/// `@unchecked Sendable` because `NSAttributedString` is a reference type and the
/// value crosses back from the parse/measure task to the main actor. The strings
/// are built inside `measure` and never mutated afterwards, so this is a
/// single-ownership hand-off — the same pattern `CodeBlockView` uses for its
/// highlighted string. (Boxing here rather than storing the string on
/// `TextBlockMeta` keeps that struct's plain `Sendable` conformance intact.)
struct MeasuredBlocks: @unchecked Sendable {
    let table: BlockHeightTable
    /// Keyed by `MarkdownBlock.id`, for the blocks whose text renders through
    /// `TextBlockView` (paragraphs/footnotes, quote bodies, alert bodies).
    let converted: [String: NSAttributedString]

    static let empty = MeasuredBlocks(table: .empty, converted: [:])
}

// MARK: - Measurer

/// Computes a whole document's `BlockHeightTable` off the main thread.
///
/// Exact for the NSTextView-backed kinds (`.text`, `.blockquote`, `.alert`,
/// `.codeBlock`): the same string, the same width, the same TextKit 1 settings.
/// An estimate for the kinds whose size only exists once a view is placed
/// (`.heading`, `.table`, `.mathBlock`, `.image`, `.mermaidDiagram`) — those rows
/// are `.reported` and get corrected once by the placed view.
enum BlockHeightMeasurer {

    /// Height of `ns` laid out at `width` by a standalone TextKit 1 stack.
    ///
    /// Deliberately the same recipe `SelfSizingTextView.measuredHeight` runs on
    /// its measuring layout manager: `lineFragmentPadding = 0`, an unbounded
    /// container height, `ensureLayout`, `ceil(usedRect.height)`. Anything else
    /// here breaks parity.
    static func exactHeight(text ns: NSAttributedString, width: CGFloat) -> CGFloat {
        let storage = NSTextStorage(attributedString: ns)
        let layoutManager = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: max(0, width),
                                                    height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        container.widthTracksTextView = false
        container.heightTracksTextView = false
        layoutManager.addTextContainer(container)
        storage.addLayoutManager(layoutManager)
        layoutManager.ensureLayout(for: container)
        return ceil(layoutManager.usedRect(for: container).height)
    }

    /// Measures every block for one `(blocks, theme, fontScale, contentWidth)`
    /// tuple.
    ///
    /// - Parameters:
    ///   - meta: the parse task's per-text-block metadata. Only `hasInlineMath`
    ///     is used; a missing entry is classified with the same rule.
    ///   - contentWidth: the width `MarkdownView.blockView(for:)` output gets —
    ///     the list column width minus `2 * Document.contentHorizontalPadding`.
    ///   - heightSeeds: last-known heights (`BlockHeightCache`) used to seed
    ///     Mermaid rows so a re-created diagram doesn't start at the default.
    ///   - math: see `MathRendering`. Required on purpose: defaulting to
    ///     `.none` would silently mis-measure every paragraph with inline math
    ///     and every display-math block.
    static func measure(blocks: [MarkdownBlock],
                        meta: [String: TextBlockMeta],
                        theme: MarkdownTheme,
                        fontScale: CGFloat,
                        contentWidth: CGFloat,
                        heightSeeds: [String: CGFloat] = [:],
                        math: MathRendering) -> MeasuredBlocks {
        #if DEBUG
        let signpostID = heightSignpost.makeSignpostID()
        let signpostState = heightSignpost.beginInterval("measureHeights", id: signpostID,
                                                         "blocks=\(blocks.count) width=\(Int(contentWidth))")
        let started = DispatchTime.now()
        #endif

        // Chrome that depends only on the theme + zoom: compute once per
        // document, not once per block (each one allocates a layout manager).
        let alertTitleRowHeight = BlockLayout.Alert.titleRowHeight(theme: theme, fontScale: fontScale)
        let codeChromeWithLanguage = BlockLayout.Code.verticalChrome(hasLanguage: true, fontScale: fontScale)
        let codeChromeWithoutLanguage = BlockLayout.Code.verticalChrome(hasLanguage: false, fontScale: fontScale)
        let renderer = MarkdownRenderer(theme: theme, fontScale: fontScale)

        var heights: [CGFloat] = []
        var kinds: [RowKind] = []
        var converted: [String: NSAttributedString] = [:]
        heights.reserveCapacity(blocks.count)
        kinds.reserveCapacity(blocks.count)

        for block in blocks {
            switch block.content {

            case .text(let attributed):
                let hasMath = meta[block.id]?.hasInlineMath
                    ?? BlockTextConverter.containsInlineMath(String(attributed.characters))
                let ns = BlockTextConverter.makeNSAttributedString(
                    from: attributed, hasInlineMath: hasMath,
                    theme: theme, fontScale: fontScale, math: math)
                converted[block.id] = ns
                heights.append(exactHeight(text: ns, width: contentWidth))
                kinds.append(.exact)

            case .blockquote(let content, let level):
                // The quote body is inline-rendered exactly as BlockquoteView
                // does it, and passed to TextBlockView WITHOUT inline math (the
                // view does not opt in), so we must not opt in either.
                let ns = BlockTextConverter.makeNSAttributedString(
                    from: renderer.renderQuotedBody(content), hasInlineMath: false,
                    theme: theme, fontScale: fontScale, math: math)
                converted[block.id] = ns
                let width = BlockLayout.Quote.bodyWidth(contentWidth: contentWidth, level: level)
                heights.append(exactHeight(text: ns, width: width)
                               + 2 * BlockLayout.Quote.verticalPadding)
                kinds.append(.exact)

            case .alert(_, let content):
                var height = alertTitleRowHeight
                    + 2 * BlockLayout.Alert.verticalPadding
                    + 2 * BlockLayout.Document.alertOuterVerticalPadding
                if !content.isEmpty {
                    let ns = BlockTextConverter.makeNSAttributedString(
                        from: renderer.renderQuotedBody(content), hasInlineMath: false,
                        theme: theme, fontScale: fontScale, math: math)
                    converted[block.id] = ns
                    height += BlockLayout.Alert.stackSpacing
                        + exactHeight(text: ns,
                                      width: contentWidth - 2 * BlockLayout.Alert.horizontalPadding)
                }
                heights.append(height)
                kinds.append(.exact)

            case .codeBlock(let code, let language):
                let ns = BlockTextConverter.plainCode(code, theme: theme, fontScale: fontScale)
                let inner = exactHeight(text: ns,
                                        width: contentWidth - 2 * BlockLayout.Code.horizontalPadding)
                heights.append(inner
                               + (language.isEmpty ? codeChromeWithoutLanguage : codeChromeWithLanguage)
                               + 2 * BlockLayout.Document.codeOuterVerticalPadding)
                kinds.append(.exact)

            case .heading(let level, let title, _):
                heights.append(headingEstimate(title: title, level: level,
                                               renderer: renderer, contentWidth: contentWidth))
                kinds.append(.reported)

            case .table(let headers, let rows, let alignments):
                heights.append(tableEstimate(headers: headers, rows: rows, alignments: alignments,
                                             renderer: renderer, theme: theme, fontScale: fontScale,
                                             contentWidth: contentWidth))
                kinds.append(.reported)

            case .mathBlock(let latex):
                heights.append(math.displayHeight(latex, theme, fontScale)
                               + 2 * BlockLayout.Math.verticalPadding
                               + 2 * BlockLayout.Document.mathOuterVerticalPadding)
                kinds.append(.reported)

            case .image:
                heights.append(BlockLayout.ImageBlock.placeholderHeight
                               + 2 * BlockLayout.Document.imageOuterVerticalPadding)
                kinds.append(.reported)

            case .mermaidDiagram:
                heights.append((heightSeeds[block.id] ?? BlockLayout.Mermaid.defaultHeight)
                               + 2 * BlockLayout.Mermaid.verticalPadding
                               + 2 * BlockLayout.Document.mermaidOuterVerticalPadding)
                kinds.append(.reported)
            }
        }

        #if DEBUG
        let elapsedMS = Double(DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1_000_000
        heightSignpost.endInterval("measureHeights", signpostState)
        heightLog.debug("measureHeights: \(blocks.count) blocks, width=\(contentWidth, format: .fixed(precision: 1)), \(elapsedMS, format: .fixed(precision: 2)) ms")
        #endif

        return MeasuredBlocks(
            table: BlockHeightTable(heights: heights, kinds: kinds, contentWidth: contentWidth),
            converted: converted)
    }

    // MARK: - Estimates for the reported kinds

    /// `.heading` — the title is a SwiftUI `Text`, so this is TextKit's height
    /// for the same string at the same width (they agreed to the point for every
    /// heading level sampled, except a 1 pt-per-line difference at 16 pt),
    /// floored at the hover-to-copy button's own height. The HStack is
    /// `.firstTextBaseline`-aligned, which can add another point or two for
    /// single-line H4–H6; the placed view corrects it.
    private static func headingEstimate(title: String, level: Int,
                                        renderer: MarkdownRenderer,
                                        contentWidth: CGFloat) -> CGFloat {
        let attributed = renderer.renderHeader(title, level: level)
        let ns = (try? NSAttributedString(attributed, including: \.appKit))
            ?? NSAttributedString(string: title)
        let textWidth = contentWidth
            - BlockLayout.Heading.copyButtonSpacing
            - BlockLayout.Heading.copyButtonWidth
        return max(exactHeight(text: ns, width: textWidth), BlockLayout.Heading.copyButtonHeight)
    }

    /// `.table` — cells are SwiftUI `Text`, laid out in equal-width columns.
    /// TextKit per cell is affordable because tables are rare and small.
    private static func tableEstimate(headers: [String], rows: [[String]],
                                      alignments: [TextAlignment],
                                      renderer: MarkdownRenderer,
                                      theme: MarkdownTheme, fontScale: CGFloat,
                                      contentWidth: CGFloat) -> CGFloat {
        let columnCount = max(1, max(headers.count, alignments.count, rows.map(\.count).max() ?? 0))
        let showsHeader = headers.contains { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let dividers = CGFloat(columnCount - 1) * BlockLayout.Table.dividerWidth
        let columnWidth = (contentWidth - dividers) / CGFloat(columnCount)
        let cellWidth = max(1, columnWidth - 2 * BlockLayout.Table.cellHorizontalPadding)
        // Floor: an empty cell still occupies one line in SwiftUI, where an
        // empty text container reports no used height.
        let minCellHeight = BlockLayout.singleLineHeight(
            for: theme.fonts.appKit(size: BlockLayout.Table.cellFontSize * fontScale))

        func bandHeight(_ cells: [String], padding: CGFloat) -> CGFloat {
            var tallest = minCellHeight
            for index in 0..<columnCount {
                let text = index < cells.count ? cells[index] : ""
                guard !text.isEmpty else { continue }
                let ns = (try? NSAttributedString(renderer.renderInline(text), including: \.appKit))
                    ?? NSAttributedString(string: text)
                tallest = max(tallest, exactHeight(text: ns, width: cellWidth))
            }
            return tallest + 2 * padding
        }

        var height = 2 * BlockLayout.Document.tableOuterVerticalPadding
        if showsHeader {
            height += bandHeight(headers, padding: BlockLayout.Table.headerCellVerticalPadding)
            height += BlockLayout.Table.separatorHeight
        }
        for (index, row) in rows.enumerated() {
            height += bandHeight(row, padding: BlockLayout.Table.cellVerticalPadding)
            if index < rows.count - 1 { height += BlockLayout.Table.separatorHeight }
        }
        return height
    }

}
