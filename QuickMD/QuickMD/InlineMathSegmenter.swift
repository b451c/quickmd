import Foundation

/// Splits paragraph text into alternating plain-text and inline-math segments.
/// Math is delimited by single `$` (never `$$` — that's display math).
/// Pure Foundation — shared by TextBlockView (app) and the unit tests.
enum InlineMathSegmenter {

    enum Segment: Equatable {
        case text(String)
        case math(String)
    }

    static func split(_ text: String) -> [Segment] {
        var segments: [Segment] = []
        var remaining = text[...]
        var buffer = ""

        while !remaining.isEmpty {
            // Look for opening $
            guard let dollarIndex = remaining.firstIndex(of: "$") else {
                buffer.append(contentsOf: remaining)
                break
            }

            // Skip $$ (display math delimiter, not inline)
            let afterDollar = remaining.index(after: dollarIndex)
            if afterDollar < remaining.endIndex && remaining[afterDollar] == "$" {
                buffer.append(contentsOf: remaining[remaining.startIndex...afterDollar])
                remaining = remaining[remaining.index(after: afterDollar)...]
                continue
            }

            // Check for closing $
            let searchStart = afterDollar
            guard searchStart < remaining.endIndex,
                  let closeIndex = remaining[searchStart...].firstIndex(of: "$") else {
                buffer.append(contentsOf: remaining)
                break
            }

            let latex = String(remaining[searchStart..<closeIndex])

            // Validate: not empty, not purely numbers, no leading/trailing whitespace
            guard !latex.isEmpty,
                  latex.first?.isWhitespace != true,
                  latex.last?.isWhitespace != true,
                  !latex.allSatisfy({ $0.isNumber || $0 == "." || $0 == "," }) else {
                buffer.append(contentsOf: remaining[remaining.startIndex...dollarIndex])
                remaining = remaining[afterDollar...]
                continue
            }

            // Flush text before this math
            buffer.append(contentsOf: remaining[remaining.startIndex..<dollarIndex])
            if !buffer.isEmpty {
                segments.append(.text(buffer))
                buffer = ""
            }

            segments.append(.math(latex))
            remaining = remaining[remaining.index(after: closeIndex)...]
        }

        if !buffer.isEmpty {
            segments.append(.text(buffer))
        }

        return segments
    }
}
