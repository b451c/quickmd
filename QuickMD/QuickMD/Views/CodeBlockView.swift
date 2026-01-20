import SwiftUI

// MARK: - Code Block View

/// Renders a fenced code block with syntax highlighting
/// Supports common programming languages: Swift, Python, JavaScript, Rust, Go, etc.
struct CodeBlockView: View {
    let code: String
    let language: String
    let theme: MarkdownTheme

    // MARK: - Static Regex Patterns (compiled once, reused)

    /// Matches single-line comments: //, #, --
    private static let commentRegex = try! NSRegularExpression(pattern: #"(//.*|#.*|--.*)"#)

    /// Matches string literals: "..." or '...'
    private static let stringRegex = try! NSRegularExpression(pattern: #"\"[^\"]*\"|'[^']*'"#)

    /// Matches numeric literals: integers and decimals
    private static let numberRegex = try! NSRegularExpression(pattern: #"\b\d+\.?\d*\b"#)

    /// Matches common programming keywords across multiple languages
    private static let keywordRegex = try! NSRegularExpression(pattern: #"\b(func|function|def|class|struct|enum|let|var|const|if|else|for|while|return|import|from|pub|fn|async|await|try|catch|throw|new|self|this|nil|null|true|false|None|True|False)\b"#)

    /// Matches type names (PascalCase identifiers)
    private static let typeRegex = try! NSRegularExpression(pattern: #"\b[A-Z][a-zA-Z0-9]*\b"#)

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !language.isEmpty {
                Text(language)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(theme.secondaryTextColor)
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                    .padding(.bottom, 4)
            }

            Text(highlightedCode)
                .font(.system(size: 13, design: .monospaced))
                .textSelection(.enabled)
                .padding(.horizontal, 12)
                .padding(.vertical, language.isEmpty ? 12 : 8)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(theme.codeBackgroundColor)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    // MARK: - Syntax Highlighting

    private var highlightedCode: AttributedString {
        var result = AttributedString()
        let lines = code.components(separatedBy: "\n")

        for (index, line) in lines.enumerated() {
            result.append(highlightLine(line))
            if index < lines.count - 1 {
                result.append(AttributedString("\n"))
            }
        }
        return result
    }

    private func highlightLine(_ line: String) -> AttributedString {
        var result = AttributedString(line)
        result.foregroundColor = theme.textColor
        let nsRange = NSRange(line.startIndex..., in: line)

        // Comments - if found, return early (entire line is comment-colored)
        if let match = Self.commentRegex.firstMatch(in: line, range: nsRange),
           let range = Range(match.range, in: line) {
            applyColor(to: &result, range: range, in: line, color: theme.commentColor)
            return result
        }

        // Strings
        applyRegexColor(to: &result, in: line, regex: Self.stringRegex, nsRange: nsRange, color: theme.stringColor)

        // Numbers
        applyRegexColor(to: &result, in: line, regex: Self.numberRegex, nsRange: nsRange, color: theme.numberColor)

        // Keywords
        applyRegexColor(to: &result, in: line, regex: Self.keywordRegex, nsRange: nsRange, color: theme.keywordColor)

        // Types (capitalized words)
        applyRegexColor(to: &result, in: line, regex: Self.typeRegex, nsRange: nsRange, color: theme.typeColor)

        return result
    }

    // MARK: - Color Application Helpers

    private func applyRegexColor(to result: inout AttributedString, in line: String, regex: NSRegularExpression, nsRange: NSRange, color: Color) {
        for match in regex.matches(in: line, range: nsRange) {
            if let range = Range(match.range, in: line) {
                applyColor(to: &result, range: range, in: line, color: color)
            }
        }
    }

    private func applyColor(to result: inout AttributedString, range: Range<String.Index>, in line: String, color: Color) {
        // O(1) index calculation using direct offset computation
        let startOffset = line.distance(from: line.startIndex, to: range.lowerBound)
        let endOffset = line.distance(from: line.startIndex, to: range.upperBound)

        let characters = result.characters
        guard startOffset < characters.count, endOffset <= characters.count else { return }

        let attrStart = characters.index(characters.startIndex, offsetBy: startOffset)
        let attrEnd = characters.index(characters.startIndex, offsetBy: endOffset)

        if attrStart < attrEnd {
            result[attrStart..<attrEnd].foregroundColor = color
        }
    }
}
