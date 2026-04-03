import SwiftUI

// MARK: - Inline Math Text View

/// Renders a paragraph that contains inline math `$...$` expressions.
/// Splits text at math delimiters and builds a SwiftUI Text concatenation
/// with rendered math images inline via `Text(Image(nsImage:))`.
struct InlineMathTextView: View {
    let attributedString: AttributedString
    let theme: MarkdownTheme

    var body: some View {
        buildConcatenatedText()
            .textSelection(.enabled)
    }

    private func buildConcatenatedText() -> Text {
        let plainText = String(attributedString.characters)
        let segments = splitAtMathDelimiters(plainText)

        var result = Text("")
        // Track position in the AttributedString to preserve formatting
        var attrIndex = attributedString.startIndex

        for segment in segments {
            switch segment {
            case .text(let str):
                // Extract the corresponding range from the original AttributedString
                if let endIndex = attributedString.characters.index(attrIndex, offsetBy: str.count, limitedBy: attributedString.endIndex) {
                    let slice = attributedString[attrIndex..<endIndex]
                    result = result + Text(AttributedString(slice))
                    attrIndex = endIndex
                }

            case .math(let latex):
                // Skip past the $latex$ in the AttributedString (content + 2 dollar signs)
                let skipCount = latex.count + 2
                if let endIndex = attributedString.characters.index(attrIndex, offsetBy: skipCount, limitedBy: attributedString.endIndex) {
                    attrIndex = endIndex
                }

                // Render LaTeX to image
                if let image = renderMathToImage(latex: latex) {
                    result = result + Text(Image(nsImage: image))
                } else {
                    // Fallback: italic text
                    var attr = AttributedString(latex)
                    attr.font = .system(size: 14).italic()
                    attr.foregroundColor = theme.textColor
                    result = result + Text(attr)
                }
            }
        }

        return result
    }

    // MARK: - Math Rendering

    private func renderMathToImage(latex: String) -> NSImage? {
        var mathImage = MathImage(
            latex: latex,
            fontSize: 14,
            textColor: NSColor(theme.textColor),
            labelMode: .text,
            textAlignment: .left
        )
        let (error, image, _) = mathImage.asImage()
        guard error == nil, let image = image else { return nil }
        return image
    }

    // MARK: - Text Splitting

    private enum Segment {
        case text(String)
        case math(String)
    }

    /// Split text into alternating text and math segments.
    /// Math is delimited by single `$` (not `$$`).
    private func splitAtMathDelimiters(_ text: String) -> [Segment] {
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
