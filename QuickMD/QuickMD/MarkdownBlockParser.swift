import SwiftUI

// MARK: - Block Parser

/// Parses Markdown text into discrete blocks for rendering
/// Handles: fenced code blocks, tables, images, setext headers, and text paragraphs
struct MarkdownBlockParser: Sendable {
    let theme: MarkdownTheme

    // Cached renderer instance - created once per parser, not per flushTextBuffer call
    private let renderer: MarkdownRenderer

    // Static precompiled regex (avoid recompilation per parse call)
    private static let imageRegex = try! NSRegularExpression(pattern: MarkdownTheme.imagePattern)
    private static let headerRegex = try! NSRegularExpression(pattern: MarkdownTheme.headerPattern)
    private static let refLinkDefRegex = try! NSRegularExpression(pattern: MarkdownTheme.referenceLinkDefinitionPattern)
    private static let footnoteDefRegex = try! NSRegularExpression(pattern: MarkdownTheme.footnoteDefinitionPattern)

    init(theme: MarkdownTheme) {
        self.theme = theme
        self.renderer = MarkdownRenderer(theme: theme)
    }

    init(colorScheme: ColorScheme) {
        self.theme = MarkdownTheme.cached(for: colorScheme)
        self.renderer = MarkdownRenderer(theme: self.theme)
    }

    /// Parse markdown text into an array of MarkdownBlock elements
    /// - Parameter markdown: Raw markdown string
    /// - Returns: Array of parsed blocks ready for rendering
    func parse(_ markdown: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var blockIndex = 0  // Stable index for block identity
        let allLines = markdown.components(separatedBy: "\n")

        // Pre-pass: collect reference link definitions and footnote definitions, filter them out
        var referenceDefinitions: [String: String] = [:]
        var footnoteDefinitions: [(id: String, content: String)] = []
        var footnoteIds: [String] = [] // ordered by first appearance
        var lines: [String] = []
        for line in allLines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let nsRange = NSRange(trimmed.startIndex..., in: trimmed)
            // Footnote definitions must be checked BEFORE reference links
            // because [^id]: text also matches the reference link pattern [id]: url
            if let match = Self.footnoteDefRegex.firstMatch(in: trimmed, range: nsRange),
                      let idRange = Range(match.range(at: 1), in: trimmed),
                      let contentRange = Range(match.range(at: 2), in: trimmed) {
                let fnId = String(trimmed[idRange])
                let fnContent = String(trimmed[contentRange])
                footnoteDefinitions.append((id: fnId, content: fnContent))
                if !footnoteIds.contains(fnId) { footnoteIds.append(fnId) }
            } else if let match = Self.refLinkDefRegex.firstMatch(in: trimmed, range: nsRange),
                      let idRange = Range(match.range(at: 1), in: trimmed),
                      let urlRange = Range(match.range(at: 2), in: trimmed) {
                referenceDefinitions[String(trimmed[idRange]).lowercased()] = String(trimmed[urlRange])
            } else {
                lines.append(line)
            }
        }

        // Use reference-aware renderer if definitions were found
        let activeRenderer = referenceDefinitions.isEmpty && footnoteDefinitions.isEmpty
            ? self.renderer
            : MarkdownRenderer(theme: theme, referenceDefinitions: referenceDefinitions, footnoteDefinitions: footnoteDefinitions)

        var i = 0
        var textBuffer: [String] = []

        while i < lines.count {
            let line = lines[i]

            let trimmedLine = line.trimmingCharacters(in: .whitespaces)

            // Fenced code block — check BEFORE math to protect $$ inside code blocks
            if trimmedLine.hasPrefix("```") || trimmedLine.hasPrefix("~~~") {
                flushTextBuffer(&textBuffer, to: &blocks, index: &blockIndex, using: activeRenderer)

                // Store the fence characters (just the backticks/tildes prefix)
                guard let fenceChar = trimmedLine.first else { i += 1; continue }
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

                let codeContent = codeLines.joined(separator: "\n")
                if language.lowercased() == "mermaid" {
                    blocks.append(.mermaidDiagram(index: blockIndex, source: codeContent))
                } else {
                    blocks.append(.codeBlock(index: blockIndex, code: codeContent, language: language))
                }
                blockIndex += 1
                continue
            }

            // Display math block $$...$$ — after code block check to protect $$ inside code
            if trimmedLine.hasPrefix("$$") {
                flushTextBuffer(&textBuffer, to: &blocks, index: &blockIndex, using: activeRenderer)

                let afterDollar = String(trimmedLine.dropFirst(2)).trimmingCharacters(in: .whitespaces)

                // Single-line: $$content$$ (must have content between delimiters)
                if afterDollar.hasSuffix("$$") {
                    let latex = String(afterDollar.dropLast(2)).trimmingCharacters(in: .whitespaces)
                    if !latex.isEmpty {
                        blocks.append(.mathBlock(index: blockIndex, latex: latex))
                        blockIndex += 1
                    }
                    i += 1
                    continue
                }

                // Multi-line: accumulate until standalone closing $$
                var mathLines: [String] = []
                if !afterDollar.isEmpty { mathLines.append(afterDollar) }
                i += 1
                while i < lines.count {
                    let mLine = lines[i].trimmingCharacters(in: .whitespaces)
                    if mLine == "$$" {
                        i += 1
                        break
                    }
                    mathLines.append(lines[i])
                    i += 1
                }

                let latex = mathLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                if !latex.isEmpty {
                    blocks.append(.mathBlock(index: blockIndex, latex: latex))
                    blockIndex += 1
                }
                continue
            }

            // ATX headers (# H1 ... ###### H6) — detect at block level
            let nsRange = NSRange(line.startIndex..., in: line)
            if let match = Self.headerRegex.firstMatch(in: line, range: nsRange),
               let hashRange = Range(match.range(at: 1), in: line),
               let contentRange = Range(match.range(at: 2), in: line) {
                flushTextBuffer(&textBuffer, to: &blocks, index: &blockIndex, using: activeRenderer)
                let level = min(max(line[hashRange].count, 1), 6)
                let title = String(line[contentRange]).trimmingCharacters(in: .whitespaces)
                blocks.append(.heading(index: blockIndex, level: level, title: title))
                blockIndex += 1
                i += 1
                continue
            }

            // Standalone image (on its own line)
            if let imageMatch = parseStandaloneImage(line) {
                flushTextBuffer(&textBuffer, to: &blocks, index: &blockIndex, using: activeRenderer)
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
                    flushTextBuffer(&textBuffer, to: &blocks, index: &blockIndex, using: activeRenderer)
                    blocks.append(.heading(index: blockIndex, level: 1, title: trimmed))
                    blockIndex += 1
                    i += 2
                    continue
                }

                if nextLine.range(of: MarkdownTheme.setextH2Pattern, options: .regularExpression) != nil &&
                   !isTableSeparator(nextLine) {
                    flushTextBuffer(&textBuffer, to: &blocks, index: &blockIndex, using: activeRenderer)
                    blocks.append(.heading(index: blockIndex, level: 2, title: trimmed))
                    blockIndex += 1
                    i += 2
                    continue
                }
            }

            // Table detection
            if line.filter({ $0 == "|" }).count >= 2 && !trimmed.isEmpty {
                if !isTableSeparator(trimmed) && i + 1 < lines.count && isTableSeparator(lines[i + 1]) {
                    flushTextBuffer(&textBuffer, to: &blocks, index: &blockIndex, using: activeRenderer)

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
                flushTextBuffer(&textBuffer, to: &blocks, index: &blockIndex, using: activeRenderer)

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

        flushTextBuffer(&textBuffer, to: &blocks, index: &blockIndex, using: activeRenderer)

        // Append footnotes block at end of document if any definitions exist
        if !footnoteDefinitions.isEmpty {
            var footnoteText = AttributedString("")

            // Horizontal rule separator
            var rule = AttributedString("────────────────────────────────\n")
            rule.font = .system(size: 12)
            rule.foregroundColor = theme.secondaryTextColor
            footnoteText.append(rule)

            for (index, def) in footnoteDefinitions.enumerated() {
                let number = index + 1
                var prefix = AttributedString("\(number). ")
                prefix.font = .system(size: 12, weight: .bold)
                prefix.foregroundColor = theme.secondaryTextColor

                var content = activeRenderer.renderInline(def.content)
                content.font = .system(size: 12)
                content.foregroundColor = theme.secondaryTextColor

                footnoteText.append(prefix)
                footnoteText.append(content)
                footnoteText.append(AttributedString("\n"))
            }

            blocks.append(.text(index: blockIndex, footnoteText))
            blockIndex += 1
        }

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

    /// Cap on lines per text block. Large bullet/link lists (e.g. 11K-line bookmark dumps)
    /// would otherwise coalesce into one ~10000-char Text(AttributedString) per heading
    /// section — slow to lay out on window resize. We split at blank-line (paragraph)
    /// boundaries so visual rendering is unaffected, but each individual block stays
    /// small enough for SwiftUI Text to lay out quickly.
    private static let textChunkLineLimit = 30

    private func flushTextBuffer(_ buffer: inout [String], to blocks: inout [MarkdownBlock], index: inout Int, using renderer: MarkdownRenderer) {
        guard !buffer.isEmpty else { return }

        // Slice the buffer into chunks of ≤ textChunkLineLimit lines, preferring
        // blank-line boundaries so we never split a paragraph.
        var chunkStart = 0
        while chunkStart < buffer.count {
            let hardEnd = min(chunkStart + Self.textChunkLineLimit, buffer.count)
            var sliceEnd = hardEnd

            // If we're not at the end of the buffer, try to back up to the last blank
            // line within this chunk so we don't split a paragraph mid-flow.
            if hardEnd < buffer.count {
                var probe = hardEnd - 1
                while probe > chunkStart {
                    if buffer[probe].trimmingCharacters(in: .whitespaces).isEmpty {
                        sliceEnd = probe + 1   // include the blank line in this chunk
                        break
                    }
                    probe -= 1
                }
                // If no blank line found inside the window, fall through with hardEnd —
                // the chunk is one long paragraph and we just have to take the hit.
            }

            let slice = buffer[chunkStart..<sliceEnd].joined(separator: "\n")
            blocks.append(.text(index: index, renderer.render(slice)))
            index += 1
            chunkStart = sliceEnd
        }
        buffer = []
    }
}
