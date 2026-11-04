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
//     each. The views therefore consume `BlockLayout` (via a `Metrics`
//     typealias) rather than repeating literals.
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
//
// THREAD RULE — THE MATH ENGINE IS MAIN-THREAD ONLY.
//
// SwiftMath is not thread-safe: `MTMathAtomFactory` reads and lazily populates
// unsynchronized statics (`supportedLatexSymbols` and friends, some of them
// dictionaries of reference-type `MTMathAtom`s handed out by reference),
// `MTFontManager` caches fonts check-then-act, and the main thread is already
// inside that code displaying math while a background measure would enter it
// again. So the off-main call passes `math: nil`: every row that needs the
// engine — a paragraph whose plain text contains inline `$…$`, and every
// `.mathBlock` — is left at a placeholder height and its index is listed in
// `MeasuredBlocks.mathPendingRows`, with no `converted` entry. The caller then
// finishes exactly those rows on the main actor with `measureMathRows` before
// the table is used for layout. Passing a non-nil engine off the main thread is
// a data race; only main-actor callers (and the tests, which inject a pure
// stub) may do it.

#if DEBUG
// Console.app filter: subsystem == "pl.falami.studio.QuickMD" AND category == "BlockHeights"
private let heightLog = Logger(subsystem: "pl.falami.studio.QuickMD", category: "BlockHeights")
private let heightSignpost = OSSignposter(subsystem: "pl.falami.studio.QuickMD", category: "BlockHeights")
#endif

// MARK: - Layout Metrics (single source of truth)

/// Every fixed geometry value the block views apply, in one place.
///
/// Each view exposes the namespace it uses as `Metrics` (e.g.
/// `CodeBlockView.Metrics.horizontalPadding`) and reads its paddings from here,
/// so the measurer, the views and the parity tests can never drift apart.
/// Values are the ones that shipped in 1.8.0 — this is a re-homing, not a
/// redesign. Points are at 1.0 zoom unless the member takes a `fontScale`.
enum BlockLayout {

    // MARK: Document chrome (MarkdownView)

    /// Padding `MarkdownView` puts around the document and around blocks.
    /// The per-kind `…OuterVerticalPadding` values are the `.padding(.vertical:)`
    /// modifiers applied in `MarkdownView.blockView(for:)`; they are part of a
    /// row's height because the virtualized list hosts that whole view. The
    /// space BETWEEN blocks is `BlockLayout.Spacing` (VerticalRhythm.swift).
    enum Document {
        static let contentHorizontalPadding: CGFloat = 32
        static let contentVerticalPadding: CGFloat = 24

        // MARK: Reading mode (v1.9)
        //
        // Distraction-free reading changes exactly two numbers of the document
        // column: it stops growing past a comfortable measure and gets more air
        // above and below. Everything else about a block's geometry is the same,
        // so `BlockHeightMeasurer` needs no reading-mode branch at all — it is
        // handed the clamped `contentWidth` like any other width.

        /// Upper bound on the text column in reading mode; wider windows centre
        /// the column instead of stretching the lines. 720 pt is ~90 characters
        /// at the 16 pt default body size — past that the eye loses the line it
        /// came from on the way back to the left margin.
        static let readingMaxContentWidth: CGFloat = 720
        /// `contentVerticalPadding`'s reading-mode counterpart: the top and
        /// bottom breathing room, doubled, because in reading mode nothing else
        /// occupies the top of the window.
        static let readingContentVerticalPadding: CGFloat = 48

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

        // MARK: Hover-to-copy button
        //
        // `CodeBlockView.body` is a `ZStack(alignment: .topTrailing)` whose second
        // child is the copy button, hidden with `.opacity(0)` — it is ALWAYS in
        // the hierarchy, so the ZStack is as tall as the taller of the two
        // children. For a short fence (one line, or an empty one, especially at
        // small zoom) that is the button, not the code. Its icon font is a fixed
        // `.system(size:)` — deliberately not multiplied by `fontScale`, like the
        // heading's copy button — so the floor is one constant for every zoom
        // level.

        static let copyButtonIconFontSize: CGFloat = 11
        static let copyButtonIconPadding: CGFloat = 5
        static let copyButtonOuterPadding: CGFloat = 6
        /// Fitting height of the copy button as `CodeBlockView` places it:
        /// an 11 pt `doc.on.doc` (16 pt tall) + 2 × 5 pt icon padding
        /// + 2 × 6 pt outer padding. Measured with `NSHostingView` and pinned by
        /// `BlockHeightMeasurerTests.testCodeCopyButtonConstantsMatchTheRealButton`.
        static let copyButtonFloorHeight: CGFloat = 38

        /// The language label is a SwiftUI `Text` in the *system monospaced*
        /// face (not the theme's code family — `CodeBlockView` asks for
        /// `.system(design: .monospaced)`).
        static func languageLabelFont(fontScale: CGFloat) -> NSFont {
            .monospacedSystemFont(ofSize: languageLabelFontSize * fontScale, weight: .medium)
        }

        /// Height of the language-label row.
        ///
        /// EXACT, not an estimate: `CodeBlockView` pins its label to this value
        /// (`.lineLimit(1)` + `.frame(height:)`) instead of letting SwiftUI pick
        /// a single-line height of its own — see `BlockLayout.singleLineHeight`.
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
        /// Clamped — deep nesting in a narrow window takes the raw value
        /// negative (see `BlockLayout.clampedWidth`).
        static func bodyWidth(contentWidth: CGFloat, level: Int) -> CGFloat {
            BlockLayout.clampedWidth(contentWidth - leadingInset
                                     - CGFloat(level) * (barWidth + barGap))
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
        /// EXACT, not an estimate: both children are SwiftUI leaves whose own
        /// single-line height is not a published function of `NSFont` metrics
        /// (measured deviations of 0…2 pt from `defaultLineHeight`, in both
        /// directions, depending on point size), so `AlertBlockView` pins the
        /// HStack to this value with `.frame(height:)` rather than letting
        /// SwiftUI choose. `singleLineHeight` is the safe upper bound of what
        /// SwiftUI would have chosen — see its documentation.
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
        /// The button's first text baseline, from its top edge (4 pt padding +
        /// the SF Symbol's ascent at 11 pt), measured with `NSHostingView`.
        /// Constant across zoom for the same reason as the size.
        static let copyButtonBaselineOffset: CGFloat = 16

        /// Trailing room the title gives up for the button. The title's text
        /// view is padded by this much and the button lives in that strip
        /// (an overlay, never an HStack sibling of the NSViewRepresentable —
        /// constraints.md, scroll-freeze rule 4); `headingEstimate` wraps the
        /// title at the same reduced width.
        static let copyButtonReservedWidth: CGFloat = copyButtonSpacing + copyButtonWidth

        // MARK: Horizontal placement of the copy button

        /// The width the title wraps at inside a heading row `rowWidth` wide —
        /// the row minus the reserved strip, as the title's padding gives it.
        static func titleWrapWidth(rowWidth: CGFloat) -> CGFloat {
            BlockLayout.clampedWidth(rowWidth - copyButtonReservedWidth)
        }

        /// Leading edge of the copy button, from the row's leading edge.
        ///
        /// v1.10's `HStack { Text(title); button; Spacer }` put the button
        /// `copyButtonSpacing` after the title's widest laid-out line; the
        /// overlay reproduces that. Clamped to the row's trailing edge (and to
        /// zero for a row narrower than the button), so a title that fills its
        /// line lands the button where it sat in v1.11–1.13. The reserved strip
        /// keeps the title off the button in every case.
        static func copyButtonLeading(titleUsedWidth: CGFloat, rowWidth: CGFloat) -> CGFloat {
            max(0, min(titleUsedWidth + copyButtonSpacing, rowWidth - copyButtonWidth))
        }

        /// Width of the widest line TextKit 1 lays `title` out in at
        /// `wrapWidth` — the same settings the title's `SelfSizingTextView`
        /// uses (`lineFragmentPadding = 0`, unbounded height).
        static func titleUsedWidth(_ title: NSAttributedString, wrapWidth: CGFloat) -> CGFloat {
            let storage = NSTextStorage(attributedString: title)
            let layoutManager = NSLayoutManager()
            let container = NSTextContainer(size: NSSize(width: max(0, wrapWidth),
                                                        height: CGFloat.greatestFiniteMagnitude))
            container.lineFragmentPadding = 0
            container.widthTracksTextView = false
            container.heightTracksTextView = false
            layoutManager.addTextContainer(container)
            storage.addLayoutManager(layoutManager)
            layoutManager.ensureLayout(for: container)
            var widest: CGFloat = 0
            layoutManager.enumerateLineFragments(
                forGlyphRange: NSRange(location: 0, length: layoutManager.numberOfGlyphs)
            ) { _, usedRect, _, _, _ in
                widest = max(widest, usedRect.maxX)
            }
            return ceil(widest)
        }

        /// The cache key for a heading title's layout: exactly the inputs that
        /// decide its laid-out width — the title, the level, the zoom and the
        /// document fonts. Colours (theme, light/dark) and the parse version do
        /// not change a glyph's advance, so they stay out: a reload, a Source
        /// Edit save or a theme switch keeps hitting the same entry.
        static func titleLayoutKey(title: String, level: Int, fontScale: CGFloat,
                                   fonts: DocumentFonts) -> String {
            "\(level)|\(fontScale)|\(fonts.body ?? "")|\(fonts.code ?? "")|\(title)"
        }

        /// `titleUsedWidth` behind two caches, for `HeadingBlockView.body`: a
        /// hover toggle re-evaluates the body and must cost a lookup, and a
        /// live-resize step must cost one TextKit layout — the converted title
        /// is width-independent, so it is cached once per `key`
        /// (`titleLayoutKey`) and only the used width is cached per wrap width.
        /// `makeTitle` runs when the string is not cached. The cached string
        /// may carry another theme's colours; it is only ever measured. NSCache
        /// is thread-safe and evicts under memory pressure.
        static func titleUsedWidth(cachedAs key: String, wrapWidth: CGFloat,
                                   makeTitle: () -> NSAttributedString) -> CGFloat {
            let widthKey = "\(wrapWidth)|\(key)" as NSString
            if let hit = usedWidthCache.object(forKey: widthKey) {
                return CGFloat(hit.doubleValue)
            }
            let titleKey = key as NSString
            let title: NSAttributedString
            if let cached = titleCache.object(forKey: titleKey) {
                title = cached
            } else {
                title = makeTitle()
                titleCache.setObject(title, forKey: titleKey)
            }
            let width = titleUsedWidth(title, wrapWidth: wrapWidth)
            usedWidthCache.setObject(NSNumber(value: Double(width)), forKey: widthKey)
            return width
        }

        private static let titleCache: NSCache<NSString, NSAttributedString> = {
            let cache = NSCache<NSString, NSAttributedString>()
            cache.countLimit = 1024
            return cache
        }()

        private static let usedWidthCache: NSCache<NSString, NSNumber> = {
            let cache = NSCache<NSString, NSNumber>()
            // A few hundred visible headings × a handful of widths per resize.
            cache.countLimit = 2048
            return cache
        }()

        /// Vertical placement of a heading's title and its copy button.
        ///
        /// Until v1.11 the heading was `HStack(alignment: .firstTextBaseline)
        /// { Text(title); button }`, so the row was the UNION of the two views
        /// aligned on their first baselines. The title is now an NSTextView and
        /// the button an overlay (which takes no space), so that union is
        /// reproduced here explicitly:
        /// - the shared baseline sits at `max(titleBaseline, buttonBaseline)`;
        /// - the title is pushed down by `titleTopInset` (non-zero only for
        ///   small headings whose ascent is below the button's baseline, H4–H6);
        /// - the button is pushed down by `buttonTopInset` (large headings);
        /// - the row is at least `minimumHeight` — the button's bottom edge.
        /// With TextKit's first-line baseline this matches the old SwiftUI
        /// heading to the point for every single-line heading H1–H6 at 100 %
        /// and 150 % (pinned by `HeadingLayoutTests`).
        struct TitleGeometry: Equatable {
            let titleTopInset: CGFloat
            let buttonTopInset: CGFloat
            let minimumHeight: CGFloat
        }

        static func titleGeometry(titleFirstBaseline: CGFloat) -> TitleGeometry {
            let baseline = max(titleFirstBaseline, copyButtonBaselineOffset)
            let buttonTop = baseline - copyButtonBaselineOffset
            return TitleGeometry(titleTopInset: baseline - titleFirstBaseline,
                                 buttonTopInset: buttonTop,
                                 minimumHeight: buttonTop + copyButtonHeight)
        }

        /// TextKit 1's baseline offset for a first line set in `font` — where
        /// the title's NSTextView draws its first baseline (zero insets, no
        /// paragraph spacing). nil font (an empty title) aligns the title's
        /// top with the button's baseline, i.e. no insets at all.
        static func titleFirstBaseline(font: NSFont?) -> CGFloat {
            guard let font else { return copyButtonBaselineOffset }
            // A fresh layout manager, same reason as `singleLineHeight`.
            return NSLayoutManager().defaultBaselineOffset(for: font)
        }
    }

    // MARK: Tables

    /// Since v1.13 a table is one NSTextView over an `NSTextTable` built by
    /// `TableTextBuilder`; the builder (cell paddings, rules, font) and
    /// `TableTextView` (clip, outline) read these, and the row is `.exact`.
    enum Table {
        static let cellHorizontalPadding: CGFloat = 12
        static let headerCellVerticalPadding: CGFloat = 8
        static let cellVerticalPadding: CGFloat = 6
        /// Vertical rule between columns (a cell's trailing border).
        static let dividerWidth: CGFloat = 1
        /// Horizontal rule under the header and between rows (a cell's bottom
        /// border).
        static let separatorHeight: CGFloat = 1
        /// The rounded outline around the whole table, centred on its edge.
        static let borderWidth: CGFloat = 1
        /// Every cell, header included, at this size × zoom, regular weight:
        /// the size `MarkdownRenderer.renderInline` stamps on each run, i.e.
        /// what 1.12 actually drew (its 13 pt / semibold header modifiers lost
        /// to the runs' own font). The builder gives each cell's terminating
        /// "\n" this font too, so an empty cell is one line of it.
        static let cellFontSize: CGFloat = 14
        static let cornerRadius: CGFloat = 4
        /// A `.properties` table's key column (widest key + paddings) never
        /// takes more than this share of the table's width; longer keys wrap.
        /// Screen (`FullWidthTextTable`) and print (`PrintableTableView`).
        static let keyColumnMaxFraction: CGFloat = 0.4
    }

    // MARK: Images

    enum ImageBlock {
        /// Height of the placeholder shown until the image has loaded (and of
        /// the remote `ProgressView`). The real height only exists on main once
        /// the bitmap is decoded, so this is what a measured row starts at.
        static let placeholderHeight: CGFloat = 100
        static let maxDisplayWidth: CGFloat = 600
        /// Between an image and its italic alt-text caption. `ImageBlockView`'s
        /// body is a two-view tuple, flattened into the row's `VStack`, so this
        /// is that stack's spacing (the 8 pt the 1.8.0 document stack had).
        static let captionSpacing: CGFloat = 8

        /// Scale the fitted 100% width, then keep the result inside the column.
        static func displayWidth(fontScale: CGFloat, contentWidth: CGFloat) -> CGFloat {
            let available = max(1, contentWidth)
            return min(available, min(maxDisplayWidth, available) * fontScale)
        }

        /// The size a picture — a bitmap image (`ImageBlockView`) or an SVG
        /// (`SVGBlockView`) — is drawn at, from its own size (`NSImage.size`:
        /// the ORIGINAL pixel size for a bitmap, see `ImageLoader`, the declared
        /// size for an SVG): `displayWidth`, never wider than its own width ×
        /// zoom (D4, GitHub parity) or an HTML `<img width>` in its place, at
        /// its aspect ratio. The height is rounded to whole points, so it is
        /// pixel-exact at 1× and 2×. The views FRAME the picture with this and
        /// the measurer sizes the row with it: once a picture's size is known,
        /// its row is exact at every width and zoom.
        static func pictureSize(imageSize: CGSize, htmlWidth: ImageWidth?, fontScale: CGFloat,
                                contentWidth: CGFloat) -> CGSize {
            let cap = displayWidth(fontScale: fontScale, contentWidth: contentWidth)
            let width: CGFloat
            if let htmlWidth {
                width = htmlWidth.displayWidth(cap: cap, fontScale: fontScale)
            } else if imageSize.width > 0 {
                width = min(cap, imageSize.width * fontScale)
            } else {
                width = cap
            }
            guard imageSize.width > 0, imageSize.height > 0 else {
                return CGSize(width: width, height: placeholderHeight)
            }
            return CGSize(width: width, height: (width * imageSize.height / imageSize.width).rounded())
        }

        /// The alt-text caption under an image (`ImageCaption`): 12 pt × zoom,
        /// system italic.
        static let captionFontSize: CGFloat = 12

        static func captionFont(fontScale: CGFloat) -> NSFont {
            let size = captionFontSize * fontScale
            let base = NSFont.systemFont(ofSize: size)
            return NSFont(descriptor: base.fontDescriptor.withSymbolicTraits(.italic), size: size) ?? base
        }

        /// The caption's height at `contentWidth`: its lines, broken by TextKit
        /// as SwiftUI breaks them, × `singleLineHeight` — an upper bound of
        /// SwiftUI's own line height, which no font metric reproduces.
        /// `ImageCaption` is at least this tall, so the row is exactly this
        /// whenever the two agree on the lines, and grows (and reports) if
        /// they ever don't, rather than clipping. 0 without a caption.
        static func captionHeight(alt: String, fontScale: CGFloat, contentWidth: CGFloat) -> CGFloat {
            guard !alt.isEmpty else { return 0 }
            let font = captionFont(fontScale: fontScale)
            // A fresh stack per call: TextKit is not thread-safe and this runs
            // off-main in the measurer.
            let storage = NSTextStorage(string: alt, attributes: [.font: font])
            let layoutManager = NSLayoutManager()
            storage.addLayoutManager(layoutManager)
            let container = NSTextContainer(size: NSSize(width: BlockLayout.clampedWidth(contentWidth),
                                                         height: .greatestFiniteMagnitude))
            container.lineFragmentPadding = 0
            layoutManager.addTextContainer(container)
            layoutManager.ensureLayout(for: container)
            var lines = 0
            layoutManager.enumerateLineFragments(forGlyphRange: layoutManager.glyphRange(for: container)) { _, _, _, _, _ in
                lines += 1
            }
            return CGFloat(max(1, lines)) * BlockLayout.singleLineHeight(for: font)
        }

        /// An image row: the view's body is a two-view tuple (picture, then the
        /// caption), so the row's vertical padding applies to EACH of them, and
        /// the row's stack puts `captionSpacing` between them (measured in the
        /// GUI: a 1024 px icon at 819 pt reports 8 + 600 + 8 + 8 + 8 + 15 + 8 =
        /// 655). `picture` is `pictureSize(...).height`, or the 100 pt loading
        /// view while the size is unknown.
        static func rowHeight(picture: CGFloat, alt: String, fontScale: CGFloat, contentWidth: CGFloat) -> CGFloat {
            let outer = BlockLayout.Document.imageOuterVerticalPadding
            guard !alt.isEmpty else { return picture + 2 * outer }
            return picture + 2 * outer + captionSpacing
                + captionHeight(alt: alt, fontScale: fontScale, contentWidth: contentWidth) + 2 * outer
        }
    }

    // MARK: Display math

    enum Math {
        static let verticalPadding: CGFloat = 8
        static let fontSize: CGFloat = 20
        /// Height a display-math row starts at when the measurement ran without
        /// the math engine (the off-main `measure(math: nil)` — see the file
        /// header), until `measureMathRows` replaces it on the main actor. The
        /// same 100 pt an unloaded image starts at.
        static let placeholderHeight: CGFloat = 100
    }

    // MARK: Mermaid

    enum Mermaid {
        static let verticalPadding: CGFloat = 8
        /// Space between the diagram's box and its first ink, at 1.0: the
        /// `diagramPadding` Mermaid puts around a flowchart, class or state
        /// graph inside its SVG (8 px), drawn at the diagram's scale — the
        /// zoom, for a diagram narrower than the column. The diagram has no
        /// frame, so this is where the eye sees it start (measured: 8–9 pt).
        static let inkInset: CGFloat = 8
        /// Height a diagram starts at when nothing has measured it yet.
        static let defaultHeight: CGFloat = 200
        static let cornerRadius: CGFloat = 6
        /// The least height the web view reports (`MermaidWebView`).
        static let minimumHeight: CGFloat = 50

        /// What a rendered diagram's height follows from, as the inline web view
        /// posts it (`mermaidGeometry` in mermaid-template.html): the SVG's
        /// natural size (its viewBox) and what the page adds below it.
        struct Geometry: Equatable {
            var naturalWidth: CGFloat
            var naturalHeight: CGFloat
            var overhead: CGFloat
        }

        /// The diagram's height in a web view `contentWidth` wide at
        /// `fontScale` — the template's `resizeDiagram`: the natural size ×
        /// zoom, never wider than the view (`window.innerWidth`, whole CSS
        /// px), plus the page's overhead, and at least `minimumHeight`.
        static func diagramHeight(_ geometry: Geometry, fontScale: CGFloat, contentWidth: CGFloat) -> CGFloat {
            let viewport = floor(contentWidth)
            guard geometry.naturalWidth > 0, geometry.naturalHeight > 0, viewport > 0 else { return defaultHeight }
            let fit = viewport / geometry.naturalWidth
            let factor = min(fontScale * min(1, fit), fit)
            return max(minimumHeight, geometry.naturalHeight * factor + geometry.overhead)
        }

        /// A diagram row: the diagram, the view's padding and the row's.
        static func rowHeight(diagram: CGFloat) -> CGFloat {
            diagram + 2 * verticalPadding + 2 * BlockLayout.Document.mermaidOuterVerticalPadding
        }
    }

    // MARK: - Derived text widths

    /// Clamps a derived text-container width to a positive value.
    ///
    /// Every width the measurer lays text out at is `contentWidth` minus some
    /// chrome, and `contentWidth` can legitimately be tiny (narrow window with
    /// both sidebars open) or zero (before the first layout). A non-positive
    /// container width does not throw — TextKit just breaks after every word, so
    /// a one-line paragraph "measures" hundreds of points tall, and a negative
    /// one is undefined territory nothing checks. The views can't go there
    /// either: SwiftUI's padding/frame chain floors the width it proposes at 0.
    /// 1 pt is the narrowest column that still behaves like a column.
    ///
    /// Every derived width goes through here: text, code, alert body,
    /// `Quote.bodyWidth`, the heading estimate and the table's cells.
    static func clampedWidth(_ width: CGFloat) -> CGFloat { max(1, width) }

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
    ///
    /// The two rows built on it — the alert's title row and the code block's
    /// language label — do not merely get estimated with it: the views PIN
    /// themselves to it (`.frame(height:)`, plus `.lineLimit(1)` for the label),
    /// so those rows are exact by construction and the only residue of the
    /// mismatch is at most a hairline of extra space inside the row.
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
///
/// `MathRendering.swiftMath` is MAIN-ACTOR-ONLY — see the thread rule in the
/// file header. An off-main `measure` takes `math: nil` and defers those rows.
struct MathRendering {
    /// Renders one inline `$…$` segment for an `NSTextAttachment`, or nil when
    /// the LaTeX does not typeset (the caller then falls back to an italic
    /// literal).
    let inlineImage: (_ latex: String, _ theme: MarkdownTheme, _ fontScale: CGFloat) -> NSImage?
    /// Height `MTMathUILabel` will take for a display-math block.
    let displayHeight: (_ latex: String, _ theme: MarkdownTheme, _ fontScale: CGFloat) -> CGFloat
    /// False when the engine cannot typeset this display formula at all (an
    /// unsupported command such as `\not\le`). `MTMathUILabel` would draw an
    /// empty row for it, so `substitutingUntypesettableMath` shows the source
    /// instead. Defaults to "always typesets" so stubs keep their old behaviour.
    var typesets: (_ latex: String) -> Bool = { _ in true }

    /// No math engine: inline math degrades to the italic-literal fallback and
    /// display math to zero intrinsic height. Only for tests and previews.
    static let none = MathRendering(inlineImage: { _, _, _ in nil },
                                    displayHeight: { _, _, _ in 0 })

    /// `blocks` with every `.mathBlock` this engine cannot typeset turned into a
    /// ```` ```latex ```` code block of the same LaTeX — same `id` (ids are
    /// positional) and same `sourceLine`.
    ///
    /// Why a block substitution and not a fallback inside `MathBlockView`: the
    /// row would then have to be a code block for the view, the measurer
    /// (`.exact` height), search, selection/copy, Source Edit landing and
    /// print/PDF alike — six places that would each need their own "failed
    /// math" branch. Swapping the block once per parse, before anything is laid
    /// out, gives all of them the existing code-block path.
    ///
    /// Same thread rule as `measure(math:)`: the engine behind `.swiftMath` is
    /// main-thread only, so call this on the main thread with it (the parse
    /// task's main-actor step, `PDFExportManager.generateMultiPagePDF` for
    /// print and PDF). Documents without display math return without consulting
    /// the engine.
    func substitutingUntypesettableMath(in blocks: [MarkdownBlock]) -> [MarkdownBlock] {
        guard blocks.contains(where: { if case .mathBlock = $0.content { return true } else { return false } })
        else { return blocks }
        return blocks.map { block in
            guard case .mathBlock(let latex) = block.content, !typesets(latex) else { return block }
            return MarkdownBlock(id: block.id,
                                 content: .codeBlock(code: latex, language: "latex"),
                                 sourceLine: block.sourceLine)
        }
    }
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
                    // Tagged with its source so a copy can write `$latex$`
                    // instead of U+FFFC (DocumentCopyBuilder). Draws nothing,
                    // lays out nothing — the measured height is unchanged.
                    let embedded = NSMutableAttributedString(attachment: attachment)
                    embedded.addAttribute(.qmdInlineMathSource, value: latex,
                                          range: NSRange(location: 0, length: embedded.length))
                    result.append(embedded)
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

// MARK: - Document cell text view

/// The base of every text view the document list hosts (`SelfSizingTextView`,
/// `TableTextView`): a text view that never scrolls the document because it
/// was resized.
///
/// NSTextView keeps the part of itself that is visible visible while it
/// resizes: `_setFrameSize:forceScroll:` → `scrollRectToVisible:` on the
/// enclosing clip view. A text view lying in the list's top content inset is
/// visible to it but not to `scrollRectToVisible:`, which measures against the
/// inset-adjusted area — so any width change (Reading Mode, a sidebar, a window
/// resize) with a text row under the top inset scrolled the DOCUMENT until that
/// row's text sat at the content top (seen: -24.5 and -37.5 pt on leaving
/// Reading Mode, which moved the reader). These views are cells of the list,
/// and the list owns the scroll position. An explicit request (VoiceOver's
/// scroll to element) still scrolls.
///
/// Here rather than next to `SelfSizingTextView` so the unit tests, which
/// compile this file, run the very class.
class DocumentCellTextView: NSTextView {
    /// Nesting depth of `setFrameSize` — AppKit re-enters it from inside, so a
    /// flag would be cleared by the inner call before the outer one scrolls.
    private var frameSizeChanges = 0

    override func setFrameSize(_ newSize: NSSize) {
        frameSizeChanges += 1
        defer { frameSizeChanges -= 1 }
        super.setFrameSize(newSize)
    }

    override func scrollToVisible(_ rect: NSRect) -> Bool {
        if frameSizeChanges > 0 { return false }
        return super.scrollToVisible(rect)
    }
}

// MARK: - Image caption

/// The italic alt-text line under an image (`ImageBlockView`). Here rather
/// than in the view's file so the unit tests host the very view the measurer
/// sizes (`BlockLayout.ImageBlock.captionHeight`): at least that tall, so the
/// row is exact whenever SwiftUI breaks the caption into the lines TextKit
/// counted.
struct ImageCaption: View {
    let alt: String
    let color: Color
    let fontScale: CGFloat
    let contentWidth: CGFloat

    var body: some View {
        Text(alt)
            .font(.system(size: BlockLayout.ImageBlock.captionFontSize * fontScale))
            .foregroundColor(color)
            .italic()
            .frame(minHeight: BlockLayout.ImageBlock.captionHeight(alt: alt, fontScale: fontScale,
                                                                   contentWidth: contentWidth),
                   alignment: .topLeading)
    }
}

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
    /// The size of every image this document has shown (`NSImage.size`, the
    /// original pixel size), by its link as written. An `NSString` key, like
    /// `ImageLoader`'s caches: a multi-megabyte `data:` link hashes in
    /// constant time. Per document, because a relative link names another file
    /// in another folder. A re-parse keeps them: they are keyed by the link.
    private var imageSizes: [NSString: CGSize] = [:]

    func height(for id: String) -> CGFloat? { heights[id] }
    func set(_ height: CGFloat, for id: String) { heights[id] = height }
    /// Forgets the block-id heights (a re-parse: ids are positional).
    func removeAll() { heights.removeAll() }

    func setImageSize(_ size: CGSize, for url: String) {
        guard size.width > 0, size.height > 0 else { return }
        imageSizes[url as NSString] = size
    }
    func imageSize(for url: String) -> CGSize? { imageSizes[url as NSString] }

    /// A value copy for `BlockHeightMeasurer.measure(heightSeeds:)` — the
    /// measurer runs off-main and must not read this reference type from there.
    var snapshot: [String: CGFloat] { heights }
    /// The same for `measure(imageSizes:)`.
    var imageSizesSnapshot: [NSString: CGSize] { imageSizes }
}

// MARK: - Mermaid geometry

/// The geometry (`BlockLayout.Mermaid.Geometry`) of every diagram a web view
/// has rendered, by theme and source. With it a diagram that rendered once
/// never starts at the 200 pt default again: the measurer and the view's
/// first frame compute its height at any width and zoom. Process-wide, like
/// `MermaidSnapshotStore`, because a diagram re-created from a snapshot never
/// runs its web view — in this document or another. Locked: the measurer
/// reads it off-main.
enum MermaidGeometryStore {
    private static let lock = NSLock()
    private static var geometries: [NSString: BlockLayout.Mermaid.Geometry] = [:]
    /// Entries are tiny; the cap only keeps a session-long store bounded.
    static let limit = 1024

    private static func key(source: String, isDark: Bool) -> NSString { "\(isDark)|\(source)" as NSString }

    static func set(_ geometry: BlockLayout.Mermaid.Geometry, source: String, isDark: Bool) {
        guard geometry.naturalWidth > 0, geometry.naturalHeight > 0 else { return }
        let key = key(source: source, isDark: isDark)
        lock.lock()
        defer { lock.unlock() }
        if geometries.count >= limit, geometries[key] == nil { geometries.removeAll() }
        geometries[key] = geometry
    }

    static func geometry(source: String, isDark: Bool) -> BlockLayout.Mermaid.Geometry? {
        let key = key(source: source, isDark: isDark)
        lock.lock()
        defer { lock.unlock() }
        return geometries[key]
    }

    /// The diagram's height at `fontScale` and `contentWidth`, if it ever
    /// rendered in this theme.
    static func diagramHeight(source: String, isDark: Bool, fontScale: CGFloat,
                              contentWidth: CGFloat) -> CGFloat? {
        geometry(source: source, isDark: isDark).map {
            BlockLayout.Mermaid.diagramHeight($0, fontScale: fontScale, contentWidth: contentWidth)
        }
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
    /// The BLOCK's height: what its view lays out at, what a `.reported` row
    /// reports and what the parity tests pin. The list row is taller by
    /// `spacingAbove` (see `rowHeight`).
    let heights: [CGFloat]
    let kinds: [RowKind]
    /// The width the heights were measured at. A row height is only valid for
    /// this width — the list re-measures when it changes.
    let contentWidth: CGFloat
    /// The space above each block (`BlockLayout.Spacing`; row 0: 0). Part of
    /// the block's list row, above its view.
    let spacingAbove: [CGFloat]

    var count: Int { heights.count }

    /// The space above row `row`'s block; 0 outside the table.
    func spacing(_ row: Int) -> CGFloat {
        row >= 0 && row < spacingAbove.count ? spacingAbove[row] : 0
    }

    /// The list row's height: the space above the block, then the block.
    func rowHeight(_ row: Int) -> CGFloat {
        row >= 0 && row < heights.count ? spacing(row) + heights[row] : 0
    }

    /// This table with row `row`'s block height replaced — a `.reported` row
    /// measured itself. Only the block changes: its space above, and every
    /// other row, stay as measured.
    func replacingHeight(_ height: CGFloat, at row: Int) -> BlockHeightTable {
        guard row >= 0, row < heights.count else { return self }
        var heights = heights
        heights[row] = height
        return BlockHeightTable(heights: heights, kinds: kinds, contentWidth: contentWidth,
                                spacingAbove: spacingAbove)
    }

    static let empty = BlockHeightTable(heights: [], kinds: [], contentWidth: 0, spacingAbove: [])
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
    /// Keyed by `MarkdownBlock.id`, for every `.table` block: the string and
    /// cell layout the row was measured with, which `TableTextView` installs
    /// as is (same D12 hand-off as `converted`).
    let tables: [String: TableText]
    /// Rows whose height could not be computed because `measure` was called
    /// without the math engine (`math: nil` — the off-main call, see the file
    /// header): paragraphs containing inline `$…$` and `.mathBlock` rows. Their
    /// `heights` entry is a placeholder and `converted` has no entry for them.
    /// The caller MUST hand them to `BlockHeightMeasurer.measureMathRows` on the
    /// main actor before using the table for layout. Empty whenever `measure`
    /// got a real engine.
    let mathPendingRows: [Int]
    /// Every row's input to `BlockLayout.Spacing` — what `table.spacingAbove`
    /// was derived from, kept so `measureMathRows` can update the rows it
    /// finishes and derive the column again without measuring anything else.
    let rhythm: [BlockLayout.Spacing.Row]

    /// This measurement with row `row`'s block height replaced (see
    /// `BlockHeightTable.replacingHeight`).
    func replacingHeight(_ height: CGFloat, at row: Int) -> MeasuredBlocks {
        MeasuredBlocks(table: table.replacingHeight(height, at: row), converted: converted,
                       tables: tables, mathPendingRows: mathPendingRows, rhythm: rhythm)
    }

    static let empty = MeasuredBlocks(table: .empty, converted: [:], tables: [:], mathPendingRows: [],
                                      rhythm: [])
}

// MARK: - Measurer

/// Computes a whole document's `BlockHeightTable` off the main thread.
///
/// Exact for the NSTextView-backed kinds (`.text`, `.blockquote`, `.alert`,
/// `.codeBlock`, and since v1.13 `.table`): the same string, the same width, the
/// same TextKit 1 settings. An estimate for the kinds whose size only exists once
/// a view is placed (`.heading`, `.mathBlock`, `.image`, `.mermaidDiagram`) —
/// those rows are `.reported` and get corrected once by the placed view.
enum BlockHeightMeasurer {

    /// Height of `ns` laid out at `width` by a standalone TextKit 1 stack.
    ///
    /// Deliberately the same recipe `SelfSizingTextView.measuredHeight` runs on
    /// its measuring layout manager: `lineFragmentPadding = 0`, an unbounded
    /// container height, `ensureLayout`, `ceil(usedRect.height)`. Anything else
    /// here breaks parity.
    static func exactHeight(text ns: NSAttributedString, width: CGFloat) -> CGFloat {
        autoreleasepool {
            let (layoutManager, container, storage) = laidOut(ns, width: width)
            return withExtendedLifetime(storage) { ceil(layoutManager.usedRect(for: container).height) }
        }
    }

    /// `exactHeight`, plus where the text's ink starts and ends — the edges
    /// `BlockLayout.Spacing` measures optical gaps from. ONE layout pass: the
    /// baselines are read from the layout `exactHeight` computes anyway.
    ///
    /// Both run in their own autorelease pool: TextKit autoreleases parts of
    /// every stack it lays out, and one measure pass lays out every text row —
    /// thousands in a prose document, whose peak memory grew with the row
    /// count (5000 paragraphs: 37.7 MB → 26.1 MB, no time cost).
    static func textInk(text ns: NSAttributedString, width: CGFloat) -> BlockLayout.Spacing.TextInk {
        autoreleasepool { textInkInPool(text: ns, width: width) }
    }

    private static func textInkInPool(text ns: NSAttributedString, width: CGFloat) -> BlockLayout.Spacing.TextInk {
        let (layoutManager, container, storage) = laidOut(ns, width: width)
        return withExtendedLifetime(storage) {
            let height = ceil(layoutManager.usedRect(for: container).height)
            let glyphCount = layoutManager.numberOfGlyphs
            guard glyphCount > 0 else {
                return .init(height: height, firstBaseline: 0, firstCapHeight: 0, lastBaseline: height)
            }
            func baseline(ofGlyph glyph: Int) -> CGFloat {
                layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).minY
                    + layoutManager.location(forGlyphAt: glyph).y
            }
            var firstLine = NSRange()
            _ = layoutManager.lineFragmentRect(forGlyphAt: 0, effectiveRange: &firstLine)
            let firstCharacters = layoutManager.characterRange(forGlyphRange: firstLine, actualGlyphRange: nil)
            var capHeight: CGFloat = 0
            storage.enumerateAttribute(.font, in: firstCharacters, options: []) { value, _, _ in
                if let font = value as? NSFont { capHeight = max(capHeight, font.capHeight) }
            }
            return .init(height: height, firstBaseline: baseline(ofGlyph: 0), firstCapHeight: capHeight,
                         lastBaseline: baseline(ofGlyph: glyphCount - 1))
        }
    }

    /// The TextKit 1 stack both functions above lay `ns` out on. The storage
    /// is returned too, and the caller must keep it alive while it reads the
    /// layout: the layout manager does not retain it.
    private static func laidOut(_ ns: NSAttributedString, width: CGFloat)
        -> (NSLayoutManager, NSTextContainer, NSTextStorage) {
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
        return (layoutManager, container, storage)
    }

    /// Measures every block for one `(blocks, theme, fontScale, contentWidth)`
    /// tuple.
    ///
    /// - Parameters:
    ///   - contentWidth: the width `MarkdownView.blockView(for:)` output gets —
    ///     the list column width minus `2 * Document.contentHorizontalPadding`.
    ///   - heightSeeds: last-known heights (`BlockHeightCache`) used to seed
    ///     Mermaid rows so a re-created diagram doesn't start at the default.
    ///   - imageSizes: the sizes of the images this document has shown
    ///     (`BlockHeightCache.imageSizesSnapshot`): such an image's row is
    ///     computed (`BlockLayout.ImageBlock`) instead of starting at the
    ///     loading view. SVG sizes come from `SVGImageDecoder`, diagram
    ///     geometry from `MermaidGeometryStore`.
    ///   - math: the math engine, or `nil` when the call is NOT on the main
    ///     thread — see the thread rule in the file header. With `nil`, rows
    ///     that need the engine come back at a placeholder height, listed in
    ///     `MeasuredBlocks.mathPendingRows`, for `measureMathRows` to finish on
    ///     main. `kinds` never depends on this: a row is classified the same way
    ///     either side of that split. Not defaulted on purpose — an implicit
    ///     `.none` would silently mis-measure math instead of deferring it.
    ///
    /// Whether a paragraph has inline math is decided HERE, with
    /// `BlockTextConverter.containsInlineMath` — the same function the parse task
    /// applies for `TextBlockMeta`. The measurer used to accept that flag as a
    /// parameter, which made it possible for the caller to hand in an answer that
    /// disagreed with the one the view computes, i.e. to measure a different
    /// string than the one displayed.
    static func measure(blocks: [MarkdownBlock],
                        theme: MarkdownTheme,
                        fontScale: CGFloat,
                        contentWidth: CGFloat,
                        heightSeeds: [String: CGFloat] = [:],
                        imageSizes: [NSString: CGSize] = [:],
                        math: MathRendering?) -> MeasuredBlocks {
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
        let mathChrome = 2 * BlockLayout.Math.verticalPadding
            + 2 * BlockLayout.Document.mathOuterVerticalPadding
        // Stand-in for a paragraph deferred by `math: nil` — one body line, so a
        // pending row is at least the right order of magnitude on screen if it is
        // ever shown before `measureMathRows` runs.
        let pendingParagraphHeight = BlockLayout.singleLineHeight(
            for: theme.fonts.appKit(size: 14 * fontScale))
        let renderer = MarkdownRenderer(theme: theme, fontScale: fontScale)

        // Derived widths, clamped once (see `BlockLayout.clampedWidth`).
        let textWidth = BlockLayout.clampedWidth(contentWidth)
        let codeWidth = BlockLayout.clampedWidth(contentWidth - 2 * BlockLayout.Code.horizontalPadding)
        let alertBodyWidth = BlockLayout.clampedWidth(contentWidth - 2 * BlockLayout.Alert.horizontalPadding)

        // `makeNSAttributedString` takes an engine even for strings that have no
        // math in them; those calls never reach it (`hasInlineMath: false`, and
        // paragraphs that do have math are deferred instead when `math` is nil).
        let engine = math ?? .none

        var heights: [CGFloat] = []
        var kinds: [RowKind] = []
        var rhythm: [BlockLayout.Spacing.Row] = []
        var converted: [String: NSAttributedString] = [:]
        var tables: [String: TableText] = [:]
        var mathPendingRows: [Int] = []
        heights.reserveCapacity(blocks.count)
        kinds.reserveCapacity(blocks.count)
        rhythm.reserveCapacity(blocks.count)

        for (row, block) in blocks.enumerated() {
            // Text and headings have their edges measured below; every other
            // kind's are fixed by its view (`boxRhythm`) — a quote's from its
            // text's ink.
            var textEdges: BlockLayout.Spacing.Edges?
            var quoteInk: BlockLayout.Spacing.TextInk?
            switch block.content {

            case .text(let attributed):
                let hasMath = BlockTextConverter.containsInlineMath(String(attributed.characters))
                if hasMath, math == nil {
                    // Building the string means rendering `$…$` segments through
                    // the math engine, which this thread may not touch. The
                    // edges are a placeholder too, until `measureMathRows`.
                    mathPendingRows.append(heights.count)
                    heights.append(pendingParagraphHeight)
                    kinds.append(.exact)
                    textEdges = .box(top: 0, bottom: 0)
                } else {
                    let ns = BlockTextConverter.makeNSAttributedString(
                        from: attributed, hasInlineMath: hasMath,
                        theme: theme, fontScale: fontScale, math: engine)
                    converted[block.id] = ns
                    let ink = textInk(text: ns, width: textWidth)
                    heights.append(ink.height)
                    kinds.append(.exact)
                    textEdges = .text(ink)
                }

            case .blockquote(let content, let level):
                // The quote body is inline-rendered exactly as BlockquoteView
                // does it, and passed to TextBlockView WITHOUT inline math (the
                // view does not opt in), so we must not opt in either — which is
                // also why a quote never needs the math engine.
                let ns = BlockTextConverter.makeNSAttributedString(
                    from: renderer.renderQuotedBody(content), hasInlineMath: false,
                    theme: theme, fontScale: fontScale, math: engine)
                converted[block.id] = ns
                let width = BlockLayout.Quote.bodyWidth(contentWidth: contentWidth, level: level)
                let ink = textInk(text: ns, width: width)
                quoteInk = ink
                heights.append(ink.height + 2 * BlockLayout.Quote.verticalPadding)
                kinds.append(.exact)

            case .alert(_, let content):
                var height = alertTitleRowHeight
                    + 2 * BlockLayout.Alert.verticalPadding
                    + 2 * BlockLayout.Document.alertOuterVerticalPadding
                if !content.isEmpty {
                    let ns = BlockTextConverter.makeNSAttributedString(
                        from: renderer.renderQuotedBody(content), hasInlineMath: false,
                        theme: theme, fontScale: fontScale, math: engine)
                    converted[block.id] = ns
                    height += BlockLayout.Alert.stackSpacing
                        + exactHeight(text: ns, width: alertBodyWidth)
                }
                heights.append(height)
                kinds.append(.exact)

            case .codeBlock(let code, let language):
                heights.append(codeRowHeight(code: code, theme: theme, fontScale: fontScale,
                                             codeWidth: codeWidth,
                                             chrome: language.isEmpty ? codeChromeWithoutLanguage
                                                                      : codeChromeWithLanguage))
                kinds.append(.exact)

            case .heading(let level, let title, _):
                let heading = headingRow(title: title, level: level,
                                         renderer: renderer, contentWidth: contentWidth)
                heights.append(heading.height)
                kinds.append(.reported)
                textEdges = heading.edges

            case .table(let headers, let rows, let alignments, let style):
                // The string `TableTextView` installs (it is handed this very
                // instance), at the width its frame gets: the whole column.
                // A `.properties` key column's 40 % cap depends on that width,
                // so it is part of this measurement like wrapping is.
                let table = TableTextBuilder.build(headers: headers, rows: rows, alignments: alignments,
                                                   style: style, theme: theme, fontScale: fontScale)
                tables[block.id] = table
                heights.append(TableTextBuilder.height(of: table.string, width: textWidth)
                               + 2 * BlockLayout.Document.tableOuterVerticalPadding)
                kinds.append(.exact)

            case .mathBlock(let latex):
                if let math {
                    heights.append(math.displayHeight(latex, theme, fontScale) + mathChrome)
                } else {
                    mathPendingRows.append(heights.count)
                    heights.append(BlockLayout.Math.placeholderHeight + mathChrome)
                }
                kinds.append(.reported)

            case .image(let url, let alt, let htmlWidth):
                // An image this document has shown has a known size, and the
                // row is what the view draws for it (`ImageBlock.rowHeight`) at
                // any width and zoom. Until then: the loading view, 100 pt
                // plus the caption — also exact, until the image arrives. Still
                // `.reported`: a link whose file changed, or failed, reports.
                let picture = imageSizes[url as NSString].map {
                    BlockLayout.ImageBlock.pictureSize(imageSize: $0, htmlWidth: htmlWidth, fontScale: fontScale,
                                                       contentWidth: contentWidth).height
                } ?? BlockLayout.ImageBlock.placeholderHeight
                heights.append(BlockLayout.ImageBlock.rowHeight(picture: picture, alt: alt, fontScale: fontScale,
                                                                contentWidth: contentWidth))
                kinds.append(.reported)

            case .svgImage(let source):
                // The markup is in the block, so its size is known here: decoded
                // once (off-main safe) and cached by `SVGImageDecoder`, where the
                // view finds it too. Markup that does not decode shows a notice
                // and reports.
                let picture = SVGImageDecoder.size(of: source).map {
                    BlockLayout.ImageBlock.pictureSize(imageSize: $0, htmlWidth: nil, fontScale: fontScale,
                                                       contentWidth: contentWidth).height
                } ?? BlockLayout.ImageBlock.placeholderHeight
                heights.append(picture + 2 * BlockLayout.Document.imageOuterVerticalPadding)
                kinds.append(.reported)

            case .mermaidDiagram(let source):
                // A diagram that rendered once (in either document, from either
                // its web view or the snapshot that came of it) has its height
                // computed for this width and zoom; else this block's last
                // height (a width-only re-measure), else the default.
                let diagram = MermaidGeometryStore.diagramHeight(source: source, isDark: theme.isDark,
                                                                 fontScale: fontScale, contentWidth: contentWidth)
                    ?? heightSeeds[block.id]
                    ?? BlockLayout.Mermaid.defaultHeight
                heights.append(BlockLayout.Mermaid.rowHeight(diagram: diagram))
                kinds.append(.reported)
            }
            rhythm.append(textEdges.map { rhythmRow(block, edges: $0) }
                          ?? boxRhythm(block, fontScale: fontScale, quoteInk: quoteInk))
        }

        #if DEBUG
        let elapsedMS = Double(DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1_000_000
        heightSignpost.endInterval("measureHeights", signpostState)
        heightLog.debug("measureHeights: \(blocks.count) blocks, width=\(contentWidth, format: .fixed(precision: 1)), \(mathPendingRows.count) math rows deferred, \(elapsedMS, format: .fixed(precision: 2)) ms")
        #endif

        return MeasuredBlocks(
            table: BlockHeightTable(heights: heights, kinds: kinds, contentWidth: contentWidth,
                                    spacingAbove: BlockLayout.Spacing.column(rhythm, fontScale: fontScale)),
            converted: converted,
            tables: tables,
            mathPendingRows: mathPendingRows,
            rhythm: rhythm)
    }

    // MARK: - Rhythm inputs

    /// A text or heading row's rhythm input, from its measured edges.
    private static func rhythmRow(_ block: MarkdownBlock, edges: BlockLayout.Spacing.Edges)
        -> BlockLayout.Spacing.Row {
        let role: BlockLayout.Spacing.Role
        if case .heading(let level, _, _) = block.content {
            role = .heading(level: level)
        } else {
            role = .text
        }
        return BlockLayout.Spacing.Row(role: role, edges: edges, joinsPrevious: block.joinsPrevious)
    }

    /// The rhythm input of a row whose edges its view fixes: the vertical
    /// padding between the row's edge and the visible box (or the picture) —
    /// where the eye sees the block start. Two blocks have no visible box: a
    /// quote is read by its text (`quoteInk`, its edges are a paragraph's,
    /// `Edges.text(_:padding:)`), a diagram by its first ink
    /// (`Mermaid.inkInset`). A display formula's picture IS its ink (measured:
    /// within 1.5 pt). Front matter (either form) is the parser's call.
    private static func boxRhythm(_ block: MarkdownBlock, fontScale: CGFloat,
                                  quoteInk: BlockLayout.Spacing.TextInk? = nil) -> BlockLayout.Spacing.Row {
        typealias Document = BlockLayout.Document
        let role: BlockLayout.Spacing.Role = block.isFrontMatter ? .frontMatter : .box
        let pad: CGFloat
        switch block.content {
        case .blockquote:
            pad = BlockLayout.Quote.verticalPadding
            if let quoteInk {
                return BlockLayout.Spacing.Row(role: role, edges: .text(quoteInk, padding: pad),
                                               joinsPrevious: block.joinsPrevious)
            }
        case .alert: pad = Document.alertOuterVerticalPadding
        case .codeBlock: pad = Document.codeOuterVerticalPadding
        case .table:
            pad = Document.tableOuterVerticalPadding
        case .mathBlock: pad = Document.mathOuterVerticalPadding + BlockLayout.Math.verticalPadding
        case .mermaidDiagram:
            pad = Document.mermaidOuterVerticalPadding + BlockLayout.Mermaid.verticalPadding
                + BlockLayout.Mermaid.inkInset * fontScale
        case .image, .svgImage: pad = Document.imageOuterVerticalPadding
        case .text, .heading: pad = 0  // measured, never here
        }
        return BlockLayout.Spacing.Row(role: role, edges: .box(top: pad, bottom: pad),
                                       joinsPrevious: block.joinsPrevious)
    }

    /// One `.codeBlock` row: the code laid out at `codeWidth` plus `chrome`
    /// (`BlockLayout.Code.verticalChrome` for the block's language state —
    /// passed in so `measure` computes it once per document, not per block).
    /// Shared by `measure` and `measureMathRows` (a display formula the engine
    /// cannot typeset becomes a code row there).
    private static func codeRowHeight(code: String, theme: MarkdownTheme, fontScale: CGFloat,
                                      codeWidth: CGFloat, chrome: CGFloat) -> CGFloat {
        let ns = BlockTextConverter.plainCode(code, theme: theme, fontScale: fontScale)
        let stack = exactHeight(text: ns, width: codeWidth) + chrome
        // The always-present copy button is the ZStack's other child, so it is
        // a floor under the row — see `Code.copyButtonFloorHeight`.
        return max(stack, BlockLayout.Code.copyButtonFloorHeight)
            + 2 * BlockLayout.Document.codeOuterVerticalPadding
    }

    /// Finishes the rows an off-main `measure(math: nil)` deferred.
    ///
    /// `@MainActor` because this is the only place in the measurement path
    /// allowed to touch the math engine (thread rule in the file header). The
    /// caller runs it after the background pass lands, before the table is used
    /// for layout.
    ///
    /// Nothing else about the table changes — same `kinds` (bar a substituted
    /// formula, see `blocks`), same `contentWidth`, every other height and
    /// converted string carried over — so
    /// `measureMathRows(m.mathPendingRows, in: m, …, math: engine)` equals a
    /// straight `measure(…, math: engine)`, row for row.
    ///
    /// - Parameters:
    ///   - pending: normally `measured.mathPendingRows`. Indices outside the
    ///     table, and rows that don't need the engine, are ignored.
    ///   - blocks: the same array `measured` was produced from (row *i* is
    ///     `blocks[i]`), or that array after
    ///     `MathRendering.substitutingUntypesettableMath`: a deferred
    ///     `.mathBlock` row that became a `.codeBlock` is measured as a code row
    ///     here and its kind turns `.exact`, exactly what `measure` gives it.
    ///   - contentWidth: MUST be the width `measured` was produced at.
    ///   - reusing: strings a PREVIOUS measurement of the same content already
    ///     built, keyed by block id — normally the caller's last
    ///     `MeasuredBlocks.converted`. A width change re-measures the whole
    ///     document, but it does not change a single character, a font or a math
    ///     image: only where the text wraps. So for a paragraph found here, the
    ///     string is taken as-is and only laid out again at the new width,
    ///     which skips the expensive part — rendering every `$…$` segment
    ///     through the math engine on the main thread. Pass it ONLY when the
    ///     content is unchanged (same `contentVersion`, theme and zoom); a new
    ///     parse must rebuild, so pass nothing.
    @MainActor
    static func measureMathRows(_ pending: [Int],
                                in measured: MeasuredBlocks,
                                blocks: [MarkdownBlock],
                                theme: MarkdownTheme,
                                fontScale: CGFloat,
                                contentWidth: CGFloat,
                                math: MathRendering,
                                reusing: [String: NSAttributedString] = [:]) -> MeasuredBlocks {
        guard !pending.isEmpty else {
            return MeasuredBlocks(table: measured.table, converted: measured.converted,
                                  tables: measured.tables, mathPendingRows: [], rhythm: measured.rhythm)
        }

        #if DEBUG
        let signpostID = heightSignpost.makeSignpostID()
        let signpostState = heightSignpost.beginInterval("measureMathRows", id: signpostID,
                                                         "rows=\(pending.count)")
        defer { heightSignpost.endInterval("measureMathRows", signpostState) }
        #endif

        var heights = measured.table.heights
        var kinds = measured.table.kinds
        var converted = measured.converted
        // Row for row with `blocks` whenever `measured` came from them; the
        // guard only keeps a mismatched call from trapping.
        var rhythm = measured.rhythm.count == blocks.count
            ? measured.rhythm
            : blocks.map { boxRhythm($0, fontScale: fontScale) }
        let textWidth = BlockLayout.clampedWidth(contentWidth)

        for index in pending {
            guard index >= 0, index < heights.count, index < blocks.count else { continue }
            let block = blocks[index]
            switch block.content {
            case .text(let attributed):
                if let existing = reusing[block.id] {
                    // Same characters, same theme, same zoom (the caller only
                    // reuses within one content version) — so the attachments in
                    // this string are still the right images and only the wrap
                    // has to be recomputed.
                    converted[block.id] = existing
                    let ink = textInk(text: existing, width: textWidth)
                    heights[index] = ink.height
                    rhythm[index] = rhythmRow(block, edges: .text(ink))
                    continue
                }
                // Re-derive the flag rather than assuming it: the row is pending
                // *because* this test was true, and re-running it guarantees the
                // same string `measure` would have built with a live engine.
                let hasMath = BlockTextConverter.containsInlineMath(String(attributed.characters))
                let ns = BlockTextConverter.makeNSAttributedString(
                    from: attributed, hasInlineMath: hasMath,
                    theme: theme, fontScale: fontScale, math: math)
                converted[block.id] = ns
                let ink = textInk(text: ns, width: textWidth)
                heights[index] = ink.height
                rhythm[index] = rhythmRow(block, edges: .text(ink))

            case .mathBlock(let latex):
                heights[index] = math.displayHeight(latex, theme, fontScale)
                    + 2 * BlockLayout.Math.verticalPadding
                    + 2 * BlockLayout.Document.mathOuterVerticalPadding

            case .codeBlock(let code, let language):
                // Only a substituted formula gets here (a parsed code block is
                // never pending). Rare, so the chrome is computed per row.
                heights[index] = codeRowHeight(
                    code: code, theme: theme, fontScale: fontScale,
                    codeWidth: BlockLayout.clampedWidth(contentWidth - 2 * BlockLayout.Code.horizontalPadding),
                    chrome: BlockLayout.Code.verticalChrome(hasLanguage: !language.isEmpty, fontScale: fontScale))
                kinds[index] = .exact
                rhythm[index] = boxRhythm(block, fontScale: fontScale)

            default:
                continue
            }
        }

        // The finished rows' edges may have changed (a formula on the first
        // line, a formula that became a code row), and with them the space
        // around them: derive the column again — arithmetic only.
        return MeasuredBlocks(
            table: BlockHeightTable(heights: heights, kinds: kinds,
                                    contentWidth: measured.table.contentWidth,
                                    spacingAbove: BlockLayout.Spacing.column(rhythm, fontScale: fontScale)),
            converted: converted,
            tables: measured.tables,
            mathPendingRows: [],
            rhythm: rhythm)
    }

    // MARK: - Headings

    /// `.heading` — the height `HeadingBlockView` lays out at and the edges of
    /// its title. Since v1.11 the title IS an NSTextView laid out with this
    /// string at the title's width, pushed down by the title inset that lines
    /// its first baseline up with the hover-to-copy button's
    /// (`BlockLayout.Heading.titleGeometry`), and the row is at least as tall
    /// as the button's bottom edge. The row stays `.reported`: the placed view
    /// still has the last word.
    private static func headingRow(title: String, level: Int, renderer: MarkdownRenderer,
                                   contentWidth: CGFloat)
        -> (height: CGFloat, edges: BlockLayout.Spacing.Edges) {
        let attributed = renderer.renderHeader(title, level: level)
        let ns = (try? NSAttributedString(attributed, including: \.appKit))
            ?? NSAttributedString(string: title)
        let geometry = BlockLayout.Heading.titleGeometry(
            titleFirstBaseline: BlockLayout.Heading.titleFirstBaseline(font: renderer.headerAppKitFont(level: level)))
        let ink = textInk(text: ns, width: BlockLayout.Heading.titleWrapWidth(rowWidth: contentWidth))
        let height = max(geometry.titleTopInset + ink.height, geometry.minimumHeight)
        return (height, .text(ink, top: geometry.titleTopInset, rowHeight: height))
    }

}
