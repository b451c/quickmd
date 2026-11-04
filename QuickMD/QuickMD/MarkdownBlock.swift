import SwiftUI

// MARK: - GFM Alert Kinds

/// GitHub-flavored alert/admonition kinds, per the GitHub spec: a blockquote
/// whose first line is exactly `[!NOTE]` (or TIP/IMPORTANT/WARNING/CAUTION).
/// Colors are fixed semantic values from GitHub's palette (light/dark pairs),
/// deliberately theme-independent so alerts read the same in every theme.
enum AlertKind: String, Sendable, CaseIterable {
    case note, tip, important, warning, caution

    /// Parses a marker line (already stripped of `>` prefixes). The marker must
    /// be the only thing on the line — `[!NOTE] text` is a regular blockquote.
    /// Case-insensitive, matching GitHub's behavior.
    init?(markerLine: String) {
        let trimmed = markerLine.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("[!"), trimmed.hasSuffix("]") else { return nil }
        let name = trimmed.dropFirst(2).dropLast().lowercased()
        self.init(rawValue: name)
    }

    var title: String { rawValue.capitalized }

    var symbolName: String {
        switch self {
        case .note: return "info.circle"
        case .tip: return "lightbulb"
        case .important: return "exclamationmark.bubble"
        case .warning: return "exclamationmark.triangle"
        case .caution: return "exclamationmark.octagon"
        }
    }

    /// GitHub's alert accent colors (fgColor-accent light / dark).
    func accentColor(isDark: Bool) -> Color {
        switch self {
        case .note: return Color(hex: isDark ? "4493F8" : "0969DA")
        case .tip: return Color(hex: isDark ? "3FB950" : "1A7F37")
        case .important: return Color(hex: isDark ? "AB7DF8" : "8250DF")
        case .warning: return Color(hex: isDark ? "D29922" : "9A6700")
        case .caution: return Color(hex: isDark ? "F85149" : "CF222E")
        }
    }
}

// MARK: - Image Width (HTML `<img width>`)

/// The author's requested display width of an image block — only HTML
/// `<img width="…">` can express one (`HTMLImageSyntax.width(from:)`).
///
/// Sizing (D4 + T-C): without a width an image is drawn at
/// `min(column cap, image.size.width × zoom)`. With one, the requested width
/// takes the place of `image.size.width` in that rule — so it may enlarge a
/// small bitmap (as GitHub does) but never exceeds the column; the aspect
/// ratio is always kept (`height` is ignored).
enum ImageWidth: Sendable, Equatable {
    /// `width="120"` / `"120px"`: points at 100 % zoom.
    case points(CGFloat)
    /// `width="50%"`: a fraction of the column cap (0.5).
    case fraction(CGFloat)

    /// Display width for a column cap that already includes the zoom
    /// (`BlockLayout.ImageBlock.displayWidth`, or the 500 pt print cap).
    func displayWidth(cap: CGFloat, fontScale: CGFloat) -> CGFloat {
        switch self {
        case .points(let points): return min(cap, points * fontScale)
        case .fraction(let fraction): return cap * min(fraction, 1)
        }
    }
}

// MARK: - Table Style

/// How a `.table` block is drawn. Every Markdown table is `.grid`; YAML front
/// matter that `FrontMatter` can read is a `.properties` table — two columns,
/// key | value, no header band, keys literal and in the secondary text colour
/// with a column only as wide as the widest key (capped at 40 %). One block
/// kind for both, so selection, copy, search and the `.exact` measurement are
/// the table pipeline's, not a parallel one.
enum TableStyle: Sendable, Equatable {
    case grid
    case properties
}

// MARK: - Content Block Types

/// Represents different types of Markdown content blocks
/// Used by MarkdownBlockParser to structure the document for rendering
///
/// Each block carries a stable `id` assigned during parsing to ensure
/// consistent identity across re-renders and theme changes.
/// The `id` is stored (not computed) because SwiftUI's LazyVStack calls
/// the Identifiable.id getter thousands of times during layout — a computed
/// property with switch + String interpolation + enum copy (containing
/// AttributedString) caused main-thread hangs.
struct MarkdownBlock: Identifiable, Sendable {
    let id: String
    let content: BlockContent
    /// 0-based index of this block's FIRST source line in the ORIGINAL document
    /// text — i.e. before the parser's definition-filtering pre-pass removes
    /// reference-link/footnote definitions (the parser maps it back through its
    /// `lineMap`, exactly as `.heading`'s associated `sourceLine` has always been).
    ///
    /// Stored (like `id`) so hot layout paths never pay for a switch over
    /// `BlockContent`. Used for scroll-anchor preservation across re-parses:
    /// when block identity can't be matched positionally, the anchor is the
    /// first row whose `sourceLine` is ≥ the old anchor's.
    ///
    /// For `.heading` this is always equal to the associated `sourceLine` in
    /// `.heading(level:title:sourceLine:)`, which section copy (`SectionExtractor`)
    /// reads — that associated value stays the authority there.
    let sourceLine: Int
    /// This row continues the block of the row before it: there is no block
    /// boundary between them, only a cut the parser made. Two cases:
    /// - a text run longer than `MarkdownBlockParser.textChunkLineLimit` lines,
    ///   cut to keep every row cheap to lay out;
    /// - the second and later nesting groups of ONE `>` run (`> a` then
    ///   `>> b`), which render as separate quote rows.
    ///
    /// Such a row gets no space above it (`BlockLayout.Spacing`), and a copy
    /// across the cut joins the two rows with a line break, not a blank line
    /// (`DocumentCopyBuilder`).
    let joinsPrevious: Bool
    /// The document's YAML front matter — as the properties table, or as the
    /// `yaml` code block it falls back to when `FrontMatter` cannot read it.
    /// Set by the parser alone (only it knows where the fence was): a user's
    /// own ```` ```yaml ```` fence on the first line is an ordinary code block.
    /// The rhythm gives it its own role (`BlockLayout.Spacing.Role.frontMatter`).
    let isFrontMatter: Bool

    init(id: String, content: BlockContent, sourceLine: Int, joinsPrevious: Bool = false,
         isFrontMatter: Bool = false) {
        self.id = id
        self.content = content
        self.sourceLine = sourceLine
        self.joinsPrevious = joinsPrevious
        self.isFrontMatter = isFrontMatter
    }

    enum BlockContent: Sendable {
        case text(AttributedString)
        /// `.properties` (front matter): `headers` empty, every row `[key, value]`.
        case table(headers: [String], rows: [[String]], alignments: [TextAlignment], style: TableStyle)
        case codeBlock(code: String, language: String)
        /// `width` comes from an HTML `<img width>` (nil for Markdown images,
        /// which have no width syntax): it replaces the image's own width in
        /// the D4 sizing rule — see `ImageWidth`.
        case image(url: String, alt: String, width: ImageWidth?)
        case blockquote(content: String, level: Int)
        /// GFM alert: `> [!NOTE]` etc. `content` is the quote body without the
        /// marker line, still in raw Markdown (inline-rendered by the view).
        case alert(kind: AlertKind, content: String)
        /// `sourceLine` = 0-based line index of the heading in the raw document
        /// text. Section copy uses it as the authoritative boundary, so the view
        /// layer never has to re-scan the text with its own heading detection.
        case heading(level: Int, title: String, sourceLine: Int)
        case mathBlock(latex: String)
        case mermaidDiagram(source: String)
        /// Fenced ```svg block: the markup itself, decoded natively by NSImage
        /// (CoreSVG) in `SVGBlockView` — never through WebKit.
        case svgImage(source: String)
    }

    // Every factory takes `sourceLine` WITHOUT a default: the parser is the only
    // caller and it always knows the mapped original line. A default here would
    // silently produce 0-anchored blocks the moment a new parser branch forgets it.
    /// A text row never ends in a line break: the renderer ends every line
    /// with "\n", and a final one would lay out an extra, empty line under the
    /// row — in the system's default font, so it would not even scale with
    /// zoom. The space under a row is `BlockLayout.Spacing`'s job.
    static func text(index: Int, _ attributed: AttributedString, sourceLine: Int,
                     joinsPrevious: Bool = false) -> MarkdownBlock {
        var text = attributed
        while let last = text.characters.last, last == "\n" {
            text.removeSubrange(text.characters.index(before: text.endIndex)..<text.endIndex)
        }
        return MarkdownBlock(id: "text-\(index)", content: .text(text), sourceLine: sourceLine,
                             joinsPrevious: joinsPrevious)
    }
    static func table(index: Int, headers: [String], rows: [[String]], alignments: [TextAlignment],
                      style: TableStyle, sourceLine: Int, isFrontMatter: Bool = false) -> MarkdownBlock {
        MarkdownBlock(id: "table-\(index)",
                      content: .table(headers: headers, rows: rows, alignments: alignments, style: style),
                      sourceLine: sourceLine, isFrontMatter: isFrontMatter)
    }
    static func codeBlock(index: Int, code: String, language: String, sourceLine: Int,
                          isFrontMatter: Bool = false) -> MarkdownBlock {
        MarkdownBlock(id: "code-\(index)", content: .codeBlock(code: code, language: language),
                      sourceLine: sourceLine, isFrontMatter: isFrontMatter)
    }
    static func image(index: Int, url: String, alt: String, width: ImageWidth?, sourceLine: Int) -> MarkdownBlock {
        MarkdownBlock(id: "image-\(index)", content: .image(url: url, alt: alt, width: width), sourceLine: sourceLine)
    }
    static func blockquote(index: Int, content: String, level: Int, sourceLine: Int,
                           joinsPrevious: Bool = false) -> MarkdownBlock {
        MarkdownBlock(id: "blockquote-\(index)", content: .blockquote(content: content, level: level),
                      sourceLine: sourceLine, joinsPrevious: joinsPrevious)
    }
    static func alert(index: Int, kind: AlertKind, content: String, sourceLine: Int) -> MarkdownBlock {
        MarkdownBlock(id: "alert-\(index)", content: .alert(kind: kind, content: content), sourceLine: sourceLine)
    }
    /// One `sourceLine` feeds both the stored property and the associated value —
    /// they are the same line by definition, so they can never drift apart.
    static func heading(index: Int, level: Int, title: String, sourceLine: Int) -> MarkdownBlock {
        MarkdownBlock(id: "heading-\(index)", content: .heading(level: level, title: title, sourceLine: sourceLine), sourceLine: sourceLine)
    }
    static func mathBlock(index: Int, latex: String, sourceLine: Int) -> MarkdownBlock {
        MarkdownBlock(id: "math-\(index)", content: .mathBlock(latex: latex), sourceLine: sourceLine)
    }
    static func mermaidDiagram(index: Int, source: String, sourceLine: Int) -> MarkdownBlock {
        MarkdownBlock(id: "mermaid-\(index)", content: .mermaidDiagram(source: source), sourceLine: sourceLine)
    }
    static func svgImage(index: Int, source: String, sourceLine: Int) -> MarkdownBlock {
        MarkdownBlock(id: "svg-\(index)", content: .svgImage(source: source), sourceLine: sourceLine)
    }
}
