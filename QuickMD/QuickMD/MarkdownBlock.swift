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

    enum BlockContent: Sendable {
        case text(AttributedString)
        case table(headers: [String], rows: [[String]], alignments: [TextAlignment])
        case codeBlock(code: String, language: String)
        case image(url: String, alt: String)
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
    }

    // Every factory takes `sourceLine` WITHOUT a default: the parser is the only
    // caller and it always knows the mapped original line. A default here would
    // silently produce 0-anchored blocks the moment a new parser branch forgets it.
    static func text(index: Int, _ attributed: AttributedString, sourceLine: Int) -> MarkdownBlock {
        MarkdownBlock(id: "text-\(index)", content: .text(attributed), sourceLine: sourceLine)
    }
    static func table(index: Int, headers: [String], rows: [[String]], alignments: [TextAlignment], sourceLine: Int) -> MarkdownBlock {
        MarkdownBlock(id: "table-\(index)", content: .table(headers: headers, rows: rows, alignments: alignments), sourceLine: sourceLine)
    }
    static func codeBlock(index: Int, code: String, language: String, sourceLine: Int) -> MarkdownBlock {
        MarkdownBlock(id: "code-\(index)", content: .codeBlock(code: code, language: language), sourceLine: sourceLine)
    }
    static func image(index: Int, url: String, alt: String, sourceLine: Int) -> MarkdownBlock {
        MarkdownBlock(id: "image-\(index)", content: .image(url: url, alt: alt), sourceLine: sourceLine)
    }
    static func blockquote(index: Int, content: String, level: Int, sourceLine: Int) -> MarkdownBlock {
        MarkdownBlock(id: "blockquote-\(index)", content: .blockquote(content: content, level: level), sourceLine: sourceLine)
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
}
