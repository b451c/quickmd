import SwiftUI

// MARK: - Content Block Types

/// Represents different types of Markdown content blocks
/// Used by MarkdownBlockParser to structure the document for rendering
///
/// Each block carries a stable `index` assigned during parsing to ensure
/// consistent identity across re-renders and theme changes.
enum MarkdownBlock: Identifiable, Sendable {
    case text(index: Int, AttributedString)
    case table(index: Int, headers: [String], rows: [[String]], alignments: [TextAlignment])
    case codeBlock(index: Int, code: String, language: String)
    case image(index: Int, url: String, alt: String)
    case blockquote(index: Int, content: String, level: Int)
    case heading(index: Int, level: Int, title: String)

    /// Stable identifier based on block type and parse-time index
    /// Using index ensures identity remains constant even when content hash changes
    var id: String {
        switch self {
        case .text(let idx, _): return "text-\(idx)"
        case .table(let idx, _, _, _): return "table-\(idx)"
        case .codeBlock(let idx, _, _): return "code-\(idx)"
        case .image(let idx, _, _): return "image-\(idx)"
        case .blockquote(let idx, _, _): return "blockquote-\(idx)"
        case .heading(let idx, _, _): return "heading-\(idx)"
        }
    }
}
