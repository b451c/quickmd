import Foundation

/// Marks a `$` the author escaped (`\$5`): the renderer draws it as "$",
/// and `InlineMathSegmenter` never opens or closes a formula on it — the math
/// pass runs on the RENDERED text, where the backslash is gone. A dollar made
/// by a character reference (`&#36;`) is NOT tagged: GitHub reads that one as
/// a math delimiter. Not part of the AppKit scope, so the NSAttributedString a
/// view installs never carries it.
enum LiteralDollarAttribute: AttributedStringKey {
    typealias Value = Bool
    static let name = "qmdLiteralDollar"
}

/// Splits paragraph text into alternating plain-text and inline-math segments.
/// Math is delimited by single `$` (never `$$` — that's display math).
/// Pure Foundation — shared by TextBlockView (app) and the unit tests.
enum InlineMathSegmenter {

    /// The indices, in `String(attributed.characters)`, of the dollars the
    /// author escaped (`LiteralDollarAttribute`). Empty for almost every
    /// paragraph: only tagged runs are walked.
    static func literalDollars(in attributed: AttributedString) -> Set<Int> {
        var offsets: Set<Int> = []
        let characters = attributed.characters
        for run in attributed.runs where run[LiteralDollarAttribute.self] == true {
            var offset = characters.distance(from: characters.startIndex, to: run.range.lowerBound)
            for character in characters[run.range] {
                if character == "$" { offsets.insert(offset) }
                offset += 1
            }
        }
        return offsets
    }

    /// The LaTeX of a math segment: a `$` inside one can only be an escaped
    /// dollar (any other would have closed it), so it goes back to `\$`
    /// (`$a\$b$` typesets "a$b"). The segment's SOURCE length is still
    /// `latex.count + 2`.
    static func tex(_ latex: String) -> String {
        latex.contains("$") ? latex.replacingOccurrences(of: "$", with: "\\$") : latex
    }

    enum Segment: Equatable {
        case text(String)
        case math(String)
    }

    /// `literalDollars`: Character offsets of escaped dollars
    /// (`literalDollars(in:)`) — never a delimiter, so they stay text or, inside
    /// a formula, part of its LaTeX (`tex`).
    static func split(_ text: String, literalDollars: Set<Int> = []) -> [Segment] {
        var segments: [Segment] = []
        var remaining = text[...]
        var buffer = ""
        let literal: Set<String.Index> = Set(literalDollars.compactMap {
            text.index(text.startIndex, offsetBy: $0, limitedBy: text.endIndex)
        })
        /// The next delimiter `$` at or after `from`.
        func nextDollar(in slice: Substring) -> String.Index? {
            var index = slice.startIndex
            while let found = slice[index...].firstIndex(of: "$") {
                if !literal.contains(found) { return found }
                index = slice.index(after: found)
            }
            return nil
        }

        while !remaining.isEmpty {
            // Look for opening $
            guard let dollarIndex = nextDollar(in: remaining) else {
                buffer.append(contentsOf: remaining)
                break
            }

            // Skip $$ (display math delimiter, not inline)
            let afterDollar = remaining.index(after: dollarIndex)
            if afterDollar < remaining.endIndex && remaining[afterDollar] == "$" && !literal.contains(afterDollar) {
                buffer.append(contentsOf: remaining[remaining.startIndex...afterDollar])
                remaining = remaining[remaining.index(after: afterDollar)...]
                continue
            }

            // Check for closing $
            let searchStart = afterDollar
            guard searchStart < remaining.endIndex,
                  let closeIndex = nextDollar(in: remaining[searchStart...]) else {
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
