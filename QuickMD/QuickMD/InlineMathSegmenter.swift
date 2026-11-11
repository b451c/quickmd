import Foundation

/// Marks a character the author backslash-escaped (`\$`, `\%`, `\,`): the
/// renderer draws it without the backslash, but inline math is found in the
/// RENDERED text, so `InlineMathSegmenter` needs to know what was escaped:
/// - an escaped `$` never opens or closes a formula (`Price \$5 and \$10`);
/// - inside a formula every escaped character gets its backslash back, so
///   the LaTeX reaches SwiftMath intact (`$50\%$`, `$a\,b$`, `$\{x\}$`).
/// A dollar made by a character reference (`&#36;`) is NOT tagged: GitHub
/// reads that one as a math delimiter. Not part of the AppKit scope, so the
/// NSAttributedString a view installs never carries it.
enum EscapedCharacterAttribute: AttributedStringKey {
    typealias Value = Bool
    static let name = "qmdEscapedCharacter"
}

/// Marks a display formula inside a quote or alert body (v1.15): a paragraph
/// that is nothing but `$$…$$` formulas (`MarkdownRenderer.quotedBodyLines`).
/// The value is the formula's LaTeX as written (line breaks kept); the
/// characters it covers are its source on one line, so a body line is still
/// one line. `BlockTextConverter.makeMathString` draws it as a centred
/// display formula. Not part of the AppKit scope, like
/// `EscapedCharacterAttribute`.
enum DisplayMathAttribute: AttributedStringKey {
    typealias Value = String
    static let name = "qmdDisplayMath"
}

/// Splits paragraph text into alternating plain-text and inline-math segments.
/// Math is delimited by single `$` (never `$$` — that's display math).
/// Pure Foundation — shared by TextBlockView (app) and the unit tests.
enum InlineMathSegmenter {

    /// The Character offsets, in `String(attributed.characters)`, of every
    /// character the author escaped (`EscapedCharacterAttribute`). Empty for
    /// almost every paragraph: only tagged runs are walked.
    static func escapedCharacters(in attributed: AttributedString) -> Set<Int> {
        var offsets: Set<Int> = []
        let characters = attributed.characters
        for run in attributed.runs where run[EscapedCharacterAttribute.self] == true {
            var offset = characters.distance(from: characters.startIndex, to: run.range.lowerBound)
            for _ in characters[run.range] {
                offsets.insert(offset)
                offset += 1
            }
        }
        return offsets
    }

    enum Segment: Equatable {
        case text(String)
        case math(String)
    }

    /// A segment as the views draw it: text as is, a formula as the LaTeX to
    /// typeset (escaped characters with their backslash back, `tex`), with
    /// the number of Characters it spans in the rendered text (`$…$`).
    struct Piece: Equatable {
        let segment: Segment
        let length: Int
    }

    /// The paragraph's text and formulas, from the renderer's string: the one
    /// split the screen, the measurer, search and print share.
    static func pieces(of attributed: AttributedString) -> [Piece] {
        let plain = String(attributed.characters)
        let escaped = escapedCharacters(in: attributed)
        var offset = 0
        return split(plain, escaped: escaped).map { segment in
            switch segment {
            case .text(let text):
                offset += text.count
                return Piece(segment: segment, length: text.count)
            case .math(let source):
                let piece = Piece(segment: .math(tex(source, escaped: escaped, contentStart: offset + 1)),
                                  length: source.count + 2)
                offset += piece.length
                return piece
            }
        }
    }

    /// A formula's LaTeX: `source` (as rendered) with a backslash put back
    /// before every character that was escaped — by offset, never by
    /// character, so a `$` or `%` the author did not escape stays as it is.
    /// `contentStart` is the offset of `source`'s first character.
    static func tex(_ source: String, escaped: Set<Int>, contentStart: Int) -> String {
        guard !escaped.isEmpty else { return source }
        var latex = ""
        for (index, character) in source.enumerated() {
            if escaped.contains(contentStart + index) { latex.append("\\") }
            latex.append(character)
        }
        return latex
    }

    /// `escaped`: Character offsets of escaped characters
    /// (`escapedCharacters(in:)`). An escaped `$` is never a delimiter, so it
    /// stays text or, inside a formula, part of its LaTeX.
    static func split(_ text: String, escaped: Set<Int> = []) -> [Segment] {
        var segments: [Segment] = []
        var remaining = text[...]
        var buffer = ""
        let literal: Set<String.Index> = Set(escaped.compactMap {
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
