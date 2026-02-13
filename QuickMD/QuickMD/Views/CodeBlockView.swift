import SwiftUI

// MARK: - Code Block View

/// Renders a fenced code block with syntax highlighting
/// Supports common programming languages: Swift, Python, JavaScript, Rust, Go, etc.
struct CodeBlockView: View {
    let code: String
    let language: String
    let theme: MarkdownTheme
    var searchText: String = ""
    var focusedOccurrence: Int? = nil

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

    // MARK: - Cached Highlighted Code

    /// Cached highlighted code - computed once on init for typical blocks
    /// For very large blocks (500+ lines), computed async to avoid blocking
    @State private var cachedHighlightedCode: AttributedString?

    /// Threshold for async highlighting (line count)
    private static let asyncThreshold = 500

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

            Text(searchText.isEmpty ? displayedCode : searchHighlight(displayedCode, term: searchText, focusedOccurrence: focusedOccurrence))
                .font(.system(size: 13, design: .monospaced))
                .textSelection(.enabled)
                .padding(.horizontal, 12)
                .padding(.vertical, language.isEmpty ? 12 : 8)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(theme.codeBackgroundColor)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .task(id: cacheKey) {
            // Only compute async for large blocks that weren't pre-computed
            if cachedHighlightedCode == nil && isLargeBlock {
                cachedHighlightedCode = computeHighlightedCode()
            }
        }
    }

    // MARK: - Display Logic

    /// Returns cached code or computes inline for first render (small blocks only)
    private var displayedCode: AttributedString {
        if let cached = cachedHighlightedCode {
            return cached
        }
        // For small blocks, compute synchronously to avoid flicker
        // For large blocks, show plain text until async completes
        return isLargeBlock ? plainCode : computeHighlightedCode()
    }

    /// Plain code without highlighting (fallback for large blocks during async load)
    private var plainCode: AttributedString {
        var attr = AttributedString(code)
        attr.foregroundColor = theme.textColor
        return attr
    }

    /// Check if block exceeds async threshold
    private var isLargeBlock: Bool {
        var count = 0
        for char in code where char == "\n" {
            count += 1
            if count >= Self.asyncThreshold { return true }
        }
        return false
    }

    /// Cache key for .task invalidation
    private var cacheKey: Int {
        var hasher = Hasher()
        hasher.combine(code)
        hasher.combine(theme.name)
        return hasher.finalize()
    }

    // MARK: - Syntax Highlighting

    private func computeHighlightedCode() -> AttributedString {
        var result = AttributedString(code)
        result.foregroundColor = theme.textColor
        result.font = .system(size: 13, design: .monospaced)

        let nsString = code as NSString
        let fullRange = NSRange(location: 0, length: nsString.length)

        // Track ranges already colored — later patterns skip these
        var coloredRanges: [NSRange] = []

        func applyHighlighting(regex: NSRegularExpression, color: Color) {
            let matches = regex.matches(in: code, range: fullRange)
            for match in matches {
                // Skip if this range overlaps with an already-colored range
                let overlaps = coloredRanges.contains { existingRange in
                    existingRange.intersection(match.range) != nil
                }
                guard !overlaps else { continue }

                if let range = Range(match.range, in: code),
                   let attrRange = Range(range, in: result) {
                    result[attrRange].foregroundColor = color
                }
                coloredRanges.append(match.range)
            }
        }

        // Apply in priority order: strings first, then comments, then others
        // Strings have highest priority (keywords inside strings stay string-colored)
        applyHighlighting(regex: Self.stringRegex, color: theme.stringColor)
        applyHighlighting(regex: Self.commentRegex, color: theme.commentColor)
        applyHighlighting(regex: Self.numberRegex, color: theme.numberColor)
        applyHighlighting(regex: Self.keywordRegex, color: theme.keywordColor)
        applyHighlighting(regex: Self.typeRegex, color: theme.typeColor)

        return result
    }
}

// MARK: - NSRange Helpers

private extension NSRange {
    func intersection(_ other: NSRange) -> NSRange? {
        let start = max(location, other.location)
        let end = min(location + length, other.location + other.length)
        if start < end {
            return NSRange(location: start, length: end - start)
        }
        return nil
    }
}
