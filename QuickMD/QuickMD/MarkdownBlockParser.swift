import SwiftUI

// MARK: - Block Parser

/// Parses Markdown text into discrete blocks for rendering
/// Handles: fenced code blocks, tables, images, setext headers, and text paragraphs
struct MarkdownBlockParser: Sendable {
    let colorScheme: ColorScheme

    // Cached renderer instance - created once per parser, not per flushTextBuffer call
    private let renderer: MarkdownRenderer

    // Static precompiled regex (avoid recompilation per parse call)
    private static let imageRegex = try! NSRegularExpression(pattern: MarkdownTheme.imagePattern)
    private static let headerRegex = try! NSRegularExpression(pattern: MarkdownTheme.headerPattern)

    init(colorScheme: ColorScheme) {
        self.colorScheme = colorScheme
        self.renderer = MarkdownRenderer(colorScheme: colorScheme)
    }

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

            // Fenced code block - trim whitespace before checking for closing fence
            let trimmedLine = line.trimmingCharacters(in: .whitespaces)
            if trimmedLine.hasPrefix("```") || trimmedLine.hasPrefix("~~~") {
                flushTextBuffer(&textBuffer, to: &blocks, index: &blockIndex)

                // Store the fence characters (just the backticks/tildes prefix)
                let fenceChar = trimmedLine.first!
                var fenceLength = 0
                for ch in trimmedLine {
                    if ch == fenceChar { fenceLength += 1 } else { break }
                }
                let openingFence = String(repeating: fenceChar, count: fenceLength)

                // Extract language after fence
                let language = String(trimmedLine.dropFirst(fenceLength)).trimmingCharacters(in: .whitespaces)
                var codeLines: [String] = []
                i += 1

                // Closing fence must be same char, same or greater length, nothing else
                while i < lines.count {
                    let closeLine = lines[i].trimmingCharacters(in: .whitespaces)
                    if closeLine.hasPrefix(openingFence) && closeLine.drop(while: { $0 == fenceChar }).trimmingCharacters(in: .whitespaces).isEmpty {
                        i += 1
                        break
                    }
                    codeLines.append(lines[i])
                    i += 1
                }

                blocks.append(.codeBlock(index: blockIndex, code: codeLines.joined(separator: "\n"), language: language))
                blockIndex += 1
                continue
            }

            // ATX headers (# H1 ... ###### H6) — detect at block level
            let nsRange = NSRange(line.startIndex..., in: line)
            if let match = Self.headerRegex.firstMatch(in: line, range: nsRange),
               let hashRange = Range(match.range(at: 1), in: line),
               let contentRange = Range(match.range(at: 2), in: line) {
                flushTextBuffer(&textBuffer, to: &blocks, index: &blockIndex)
                let level = min(max(line[hashRange].count, 1), 6)
                let title = String(line[contentRange]).trimmingCharacters(in: .whitespaces)
                blocks.append(.heading(index: blockIndex, level: level, title: title))
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
                    blocks.append(.heading(index: blockIndex, level: 1, title: trimmed))
                    blockIndex += 1
                    i += 2
                    continue
                }

                if nextLine.range(of: MarkdownTheme.setextH2Pattern, options: .regularExpression) != nil &&
                   !isTableSeparator(nextLine) {
                    flushTextBuffer(&textBuffer, to: &blocks, index: &blockIndex)
                    blocks.append(.heading(index: blockIndex, level: 2, title: trimmed))
                    blockIndex += 1
                    i += 2
                    continue
                }
            }

            // Table detection
            if line.filter({ $0 == "|" }).count >= 2 && !trimmed.isEmpty {
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

            // Blockquote detection - group consecutive > lines by nesting level
            if trimmed.hasPrefix(">") {
                flushTextBuffer(&textBuffer, to: &blocks, index: &blockIndex)

                while i < lines.count {
                    let qLine = lines[i].trimmingCharacters(in: .whitespaces)
                    guard qLine.hasPrefix(">") else { break }

                    // Count nesting level (number of leading > chars)
                    var level = 0
                    var scanner = qLine[...]
                    while scanner.hasPrefix(">") {
                        level += 1
                        scanner = scanner.dropFirst()
                        if scanner.hasPrefix(" ") {
                            scanner = scanner.dropFirst()
                        }
                    }

                    // Accumulate consecutive lines at the same nesting level
                    let groupLevel = level
                    var groupLines = [String(scanner)]
                    i += 1

                    while i < lines.count {
                        let nextLine = lines[i].trimmingCharacters(in: .whitespaces)
                        guard nextLine.hasPrefix(">") else { break }

                        var nextLevel = 0
                        var nextScanner = nextLine[...]
                        while nextScanner.hasPrefix(">") {
                            nextLevel += 1
                            nextScanner = nextScanner.dropFirst()
                            if nextScanner.hasPrefix(" ") {
                                nextScanner = nextScanner.dropFirst()
                            }
                        }

                        guard nextLevel == groupLevel else { break }
                        groupLines.append(String(nextScanner))
                        i += 1
                    }

                    let content = groupLines.joined(separator: "\n")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if !content.isEmpty {
                        blocks.append(.blockquote(index: blockIndex, content: content, level: groupLevel))
                        blockIndex += 1
                    }
                }
                continue
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
        let nsRange = NSRange(trimmed.startIndex..., in: trimmed)

        guard let match = Self.imageRegex.firstMatch(in: trimmed, range: nsRange),
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
    /// Handles leading/trailing pipes and filters out empty cells from malformed rows
    private func parseTableRow(_ line: String) -> [String] {
        var trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)

        // Remove leading pipe if present
        if trimmed.hasPrefix("|") {
            trimmed = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
        }

        // Remove trailing pipe if present
        if trimmed.hasSuffix("|") {
            trimmed = String(trimmed.dropLast()).trimmingCharacters(in: .whitespaces)
        }

        // Split and trim each cell, filter out completely empty cells that result from trailing/leading pipes
        let cells = trimmed.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }

        // Only filter trailing empty cells (preserve intentional empty cells in middle)
        var result = cells
        while result.last?.isEmpty == true {
            result.removeLast()
        }

        return result
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
        blocks.append(.text(index: index, renderer.render(buffer.joined(separator: "\n"))))
        index += 1
        buffer = []
    }

    // MARK: - Setext Headers

    /// Render setext-style header (underlined with === or ---)
    private func renderSetextHeader(_ text: String, level: Int) -> AttributedString {
        var attr = renderer.renderInline(text)
        attr.font = .system(size: level == 1 ? 32 : 26, weight: .bold)
        return attr
    }
}
