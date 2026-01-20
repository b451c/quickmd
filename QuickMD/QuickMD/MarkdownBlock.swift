import SwiftUI

// MARK: - Content Block Types

/// Represents different types of Markdown content blocks
/// Used by MarkdownBlockParser to structure the document for rendering
enum MarkdownBlock: Identifiable {
    case text(AttributedString)
    case table(headers: [String], rows: [[String]], alignments: [TextAlignment])
    case codeBlock(code: String, language: String)
    case image(url: String, alt: String)

    var id: String {
        switch self {
        case .text(let str): return "text-\(str.hashValue)"
        case .table(let h, _, _): return "table-\(h.joined())"
        case .codeBlock(let c, _): return "code-\(c.hashValue)"
        case .image(let url, _): return "image-\(url.hashValue)"
        }
    }
}
