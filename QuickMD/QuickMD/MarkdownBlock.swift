import SwiftUI

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

    enum BlockContent: Sendable {
        case text(AttributedString)
        case table(headers: [String], rows: [[String]], alignments: [TextAlignment])
        case codeBlock(code: String, language: String)
        case image(url: String, alt: String)
        case blockquote(content: String, level: Int)
        case heading(level: Int, title: String)
    }

    static func text(index: Int, _ attributed: AttributedString) -> MarkdownBlock {
        MarkdownBlock(id: "text-\(index)", content: .text(attributed))
    }
    static func table(index: Int, headers: [String], rows: [[String]], alignments: [TextAlignment]) -> MarkdownBlock {
        MarkdownBlock(id: "table-\(index)", content: .table(headers: headers, rows: rows, alignments: alignments))
    }
    static func codeBlock(index: Int, code: String, language: String) -> MarkdownBlock {
        MarkdownBlock(id: "code-\(index)", content: .codeBlock(code: code, language: language))
    }
    static func image(index: Int, url: String, alt: String) -> MarkdownBlock {
        MarkdownBlock(id: "image-\(index)", content: .image(url: url, alt: alt))
    }
    static func blockquote(index: Int, content: String, level: Int) -> MarkdownBlock {
        MarkdownBlock(id: "blockquote-\(index)", content: .blockquote(content: content, level: level))
    }
    static func heading(index: Int, level: Int, title: String) -> MarkdownBlock {
        MarkdownBlock(id: "heading-\(index)", content: .heading(level: level, title: title))
    }
}
