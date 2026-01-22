import SwiftUI

// MARK: - Block Parser

/// Parses Markdown text into discrete blocks for rendering
/// Handles: fenced code blocks, tables, images, setext headers, and text paragraphs
struct MarkdownBlockParser {
    let colorScheme: ColorScheme

    /// Parse markdown text into an array of MarkdownBlock elements
    /// - Parameter markdown: Raw markdown string
    /// - Returns: Array of parsed blocks ready for rendering
    func parse(_ markdown: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var blockIndex = 0  // Stable index for block identity
        let lines = markdown.components(separatedBy: "\n")
        var i = 0
        var textBuffer: [String] = []

        while i < lines.count {
            let line = lines[i]

            // Fenced code block
            if line.hasPrefix("```") {
                flushTextBuffer(&textBuffer, to: &blocks, index: &blockIndex)
                let language = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var codeLines: [String] = []
                i += 1

                while i < lines.count && !lines[i].hasPrefix("```") {
                    codeLines.append(lines[i])
                    i += 1
                }

                blocks.append(.codeBlock(index: blockIndex, code: codeLines.joined(separator: "\n"), language: language))
                blockIndex += 1
                i += 1
                continue
            }

            // Standalone image (on its own line)
            if let imageMatch = parseStandaloneImage(line) {
                flushTextBuffer(&textBuffer, to: &blocks, index: &blockIndex)
                blocks.append(.image(index: blockIndex, url: imageMatch.url, alt: imageMatch.alt))
                blockIndex += 1
                i += 1
                continue
            }

            // Setext headers (underlined headers)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if i + 1 < lines.count && !trimmed.isEmpty && !trimmed.contains("|") {
                let nextLine = lines[i + 1].trimmingCharacters(in: .whitespaces)

                if nextLine.range(of: MarkdownTheme.setextH1Pattern, options: .regularExpression) != nil {
                    flushTextBuffer(&textBuffer, to: &blocks, index: &blockIndex)
                    blocks.append(.text(index: blockIndex, renderSetextHeader(trimmed, level: 1)))
                    blockIndex += 1
                    i += 2
                    continue
                }

                if nextLine.range(of: MarkdownTheme.setextH2Pattern, options: .regularExpression) != nil &&
                   !isTableSeparator(nextLine) {
                    flushTextBuffer(&textBuffer, to: &blocks, index: &blockIndex)
                    blocks.append(.text(index: blockIndex, renderSetextHeader(trimmed, level: 2)))
                    blockIndex += 1
                    i += 2
                    continue
                }
            }

            // Table detection
            if line.contains("|") && !trimmed.isEmpty {
                if !isTableSeparator(trimmed) && i + 1 < lines.count && isTableSeparator(lines[i + 1]) {
                    flushTextBuffer(&textBuffer, to: &blocks, index: &blockIndex)

                    let headers = parseTableRow(line)
                    let columnCount = headers.count
                    var alignments = parseTableAlignments(lines[i + 1])
                    var rows: [[String]] = []
                    i += 2 // Skip header and separator

                    while i < lines.count && lines[i].contains("|") && !isTableSeparator(lines[i]) {
                        rows.append(parseTableRow(lines[i]))
                        i += 1
                    }

                    // Normalize: ensure all rows and alignments match column count
                    alignments = normalizeArray(alignments, to: columnCount, default: .leading)
                    rows = rows.map { normalizeArray($0, to: columnCount, default: "") }

                    blocks.append(.table(index: blockIndex, headers: headers, rows: rows, alignments: alignments))
                    blockIndex += 1
                    continue
                }
            }

            textBuffer.append(line)
            i += 1
        }

        flushTextBuffer(&textBuffer, to: &blocks, index: &blockIndex)
        return blocks
    }

    // MARK: - Image Parsing

    private func parseStandaloneImage(_ line: String) -> (url: String, alt: String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let regex = try? NSRegularExpression(pattern: MarkdownTheme.imagePattern) else { return nil }
        let nsRange = NSRange(trimmed.startIndex..., in: trimmed)

        guard let match = regex.firstMatch(in: trimmed, range: nsRange),
              let altRange = Range(match.range(at: 1), in: trimmed),
              let urlRange = Range(match.range(at: 2), in: trimmed) else { return nil }

        return (url: String(trimmed[urlRange]), alt: String(trimmed[altRange]))
    }

    // MARK: - Table Helpers

    /// Check if line matches table separator pattern (e.g., |---|---|)
    private func isTableSeparator(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces)
            .range(of: MarkdownTheme.tableSeparatorPattern, options: .regularExpression) != nil
    }

    /// Parse a table row into array of cell strings
    private func parseTableRow(_ line: String) -> [String] {
        var trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("|") { trimmed = String(trimmed.dropFirst()) }
        if trimmed.hasSuffix("|") { trimmed = String(trimmed.dropLast()) }
        return trimmed.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// Parse column alignments from separator row
    /// - `:---` = left, `:---:` = center, `---:` = right
    private func parseTableAlignments(_ separatorLine: String) -> [TextAlignment] {
        let cells = parseTableRow(separatorLine)
        return cells.map { cell in
            let t = cell.trimmingCharacters(in: .whitespacesAndNewlines)
            // Check for colons BEFORE removing dashes
            let hasLeft = t.hasPrefix(":")
            let hasRight = t.hasSuffix(":")
            if hasLeft && hasRight { return .center }
            if hasRight { return .trailing }
            return .leading
        }
    }

    /// Normalize array to exact count - pad with default or trim excess
    private func normalizeArray<T>(_ array: [T], to count: Int, default defaultValue: T) -> [T] {
        if array.count == count { return array }
        if array.count > count { return Array(array.prefix(count)) }
        return array + Array(repeating: defaultValue, count: count - array.count)
    }

    // MARK: - Text Buffer

    private func flushTextBuffer(_ buffer: inout [String], to blocks: inout [MarkdownBlock], index: inout Int) {
        guard !buffer.isEmpty else { return }
        let renderer = MarkdownRenderer(colorScheme: colorScheme)
        blocks.append(.text(index: index, renderer.render(buffer.joined(separator: "\n"))))
        index += 1
        buffer = []
    }

    // MARK: - Setext Headers

    /// Render setext-style header (underlined with === or ---)
    private func renderSetextHeader(_ text: String, level: Int) -> AttributedString {
        let renderer = MarkdownRenderer(colorScheme: colorScheme)
        var attr = renderer.renderInline(text)
        attr.font = .system(size: level == 1 ? 32 : 26, weight: .bold)
        return attr
    }
}
