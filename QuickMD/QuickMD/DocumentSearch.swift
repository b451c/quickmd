import SwiftUI

// MARK: - Parser Output

/// Per-text-block precomputed metadata. Built on the parser's background thread so
/// the main thread doesn't have to do `String(attr.characters)` + regex per render.
struct TextBlockMeta: Sendable {
    let plain: String
    let hasInlineMath: Bool
}

/// Bundle of parser results so the background-detached parse returns one value.
struct ParsedDocument: Sendable {
    let blocks: [MarkdownBlock]
    let textMeta: [String: TextBlockMeta]
}

// MARK: - Shared Search Highlighting

/// Applies search term highlighting to an AttributedString.
/// `focusedOccurrence` = which occurrence (0-based) in this text gets orange.
/// `nil` means no occurrence is focused — all matches get yellow.
func searchHighlight(_ attributed: AttributedString, term: String, focusedOccurrence: Int? = nil) -> AttributedString {
    guard !term.isEmpty else { return attributed }
    let plainText = String(attributed.characters)
    let textLower = plainText.lowercased()
    let searchLower = term.lowercased()

    // Find all match ranges in the lowercased text
    var matchRanges: [(lowerBound: String.Index, upperBound: String.Index)] = []
    var searchStart = textLower.startIndex
    while let range = textLower.range(of: searchLower, range: searchStart..<textLower.endIndex) {
        matchRanges.append((range.lowerBound, range.upperBound))
        searchStart = range.upperBound
    }
    guard !matchRanges.isEmpty else { return attributed }

    // Convert String ranges → AttributedString ranges via single-pass parallel iteration
    var result = attributed
    var sIdx = plainText.startIndex
    var aIdx = result.startIndex
    for (matchIndex, matchRange) in matchRanges.enumerated() {
        while sIdx < matchRange.lowerBound {
            sIdx = plainText.index(after: sIdx)
            aIdx = result.characters.index(after: aIdx)
        }
        let attrStart = aIdx
        while sIdx < matchRange.upperBound {
            sIdx = plainText.index(after: sIdx)
            aIdx = result.characters.index(after: aIdx)
        }
        let color = (focusedOccurrence == matchIndex) ? Color.orange : Color.yellow.opacity(0.55)
        result[attrStart..<aIdx].backgroundColor = color
    }
    return result
}

/// Count occurrences of `term` in `text` (case-insensitive)
func countOccurrences(in text: String, of term: String) -> Int {
    guard !term.isEmpty else { return 0 }
    let textLower = text.lowercased()
    let termLower = term.lowercased()
    var count = 0
    var start = textLower.startIndex
    while let range = textLower.range(of: termLower, range: start..<textLower.endIndex) {
        count += 1
        start = range.upperBound
    }
    return count
}

// MARK: - Document Search

/// Pure search-match computation over parsed blocks. Free of any UI state so
/// MarkdownView can dispatch it to a background task for large documents
/// (typing in the find bar used to recompute every text block's highlight
/// synchronously on the main thread).
enum DocumentSearch {

    struct Results: Sendable {
        let matchBlockIds: [String]
    }

    static func computeMatches(in blocks: [MarkdownBlock], term: String) -> Results {
        guard !term.isEmpty else { return Results(matchBlockIds: []) }

        let searchLower = term.lowercased()
        var matches: [String] = []

        for block in blocks {
            // Collect all text segments for this block (per-cell for tables, per-line for blockquotes)
            let segments: [String]
            switch block.content {
            case .text(let attr):
                segments = [String(attr.characters)]
            case .table(let headers, let rows, _):
                segments = headers + rows.flatMap { $0 }
            case .codeBlock(let code, _):
                segments = [code]
            case .blockquote(let content, _):
                segments = [content]
            case .image(_, let alt):
                segments = [alt]
            case .heading(_, let title, _):
                segments = [title]
            case .mathBlock(let latex):
                segments = [latex]
            case .mermaidDiagram(let source):
                segments = [source]
            }

            // Count individual occurrences across all segments
            for segment in segments {
                let textLower = segment.lowercased()
                var searchStart = textLower.startIndex
                while let range = textLower.range(of: searchLower, range: searchStart..<textLower.endIndex) {
                    matches.append(block.id)
                    searchStart = range.upperBound
                }
            }
        }

        return Results(matchBlockIds: matches)
    }
}
