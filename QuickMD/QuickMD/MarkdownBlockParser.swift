import SwiftUI

// MARK: - Block Parser

/// Parses Markdown text into discrete blocks for rendering
/// Handles: fenced code blocks, tables, images, setext headers, and text paragraphs
struct MarkdownBlockParser: Sendable {
    let theme: MarkdownTheme
    /// ⌘+ / ⌘- zoom multiplier, forwarded to the renderer.
    let fontScale: CGFloat

    // Cached renderer instance - created once per parser, not per flushTextBuffer call
    private let renderer: MarkdownRenderer

    // Static precompiled regex (avoid recompilation per parse call)
    private static let imageRegex = try! NSRegularExpression(pattern: MarkdownTheme.imagePattern)
    private static let headerRegex = try! NSRegularExpression(pattern: MarkdownTheme.headerPattern)
    private static let refLinkDefRegex = try! NSRegularExpression(pattern: MarkdownTheme.referenceLinkDefinitionPattern)
    private static let footnoteDefRegex = try! NSRegularExpression(pattern: MarkdownTheme.footnoteDefinitionPattern)

    init(theme: MarkdownTheme, fontScale: CGFloat = 1.0) {
        self.theme = theme
        self.fontScale = fontScale
        self.renderer = MarkdownRenderer(theme: theme, fontScale: fontScale)
    }

    /// Print/PDF convenience: Auto palette + the user's Settings fonts.
    init(colorScheme: ColorScheme) {
        self.theme = MarkdownTheme.exportTheme(for: colorScheme)
        self.fontScale = 1.0
        self.renderer = MarkdownRenderer(theme: self.theme)
    }

    /// Parse markdown text into an array of MarkdownBlock elements
    /// - Parameter markdown: Raw markdown string
    /// - Returns: Array of parsed blocks ready for rendering
    func parse(_ markdown: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var blockIndex = 0  // Stable index for block identity
        let allLines = markdown.components(separatedBy: "\n")

        // YAML frontmatter (Jekyll/Hugo/Obsidian convention): a "---" fence on
        // the VERY FIRST line, closed by "---" or "...". Rendered as a neutral
        // yaml code block. Without this, the setext-H2 rule would promote the
        // first frontmatter key to a giant heading.
        var firstContentLine = 0
        if allLines.first?.trimmingCharacters(in: .whitespaces) == "---" {
            var closingIndex: Int?
            var j = 1
            while j < allLines.count {
                let t = allLines[j].trimmingCharacters(in: .whitespaces)
                if t == "---" || t == "..." { closingIndex = j; break }
                j += 1
            }
            if let closingIndex {
                let yaml = allLines[1..<closingIndex].joined(separator: "\n")
                if !yaml.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    // Front matter starts at the opening `---`, which the branch
                    // condition pins to line 0 of the original document.
                    blocks.append(.codeBlock(index: blockIndex, code: yaml, language: "yaml", sourceLine: 0))
                    blockIndex += 1
                }
                firstContentLine = closingIndex + 1
            }
        }

        // Pre-pass: collect reference link definitions and footnote definitions, filter them out
        var referenceDefinitions: [String: String] = [:]
        var footnoteDefinitions: [(id: String, content: String)] = []
        var footnoteIds: [String] = [] // ordered by first appearance
        var lines: [String] = []
        // Maps index in the filtered `lines` back to the index in `allLines`.
        // Headings carry the original line number so section copy can slice the
        // raw text without re-detecting headings itself.
        var lineMap: [Int] = []
        for originalIndex in firstContentLine..<allLines.count {
            let line = allLines[originalIndex]
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
                lineMap.append(originalIndex)
            }
        }

        // Use reference-aware renderer if definitions were found
        let activeRenderer = referenceDefinitions.isEmpty && footnoteDefinitions.isEmpty
            ? self.renderer
            : MarkdownRenderer(theme: theme, fontScale: fontScale, referenceDefinitions: referenceDefinitions, footnoteDefinitions: footnoteDefinitions)

        var i = 0
        // Each buffered line keeps the index it had in `allLines` so a flushed
        // chunk can report the ORIGINAL first line, not its position in `lines`.
        var textBuffer: [(line: String, originalIndex: Int)] = []

        while i < lines.count {
            let line = lines[i]
            // Original-document line of the block that starts here (definition
            // lines were dropped from `lines`, so `i` alone is not the answer).
            let sourceLine = lineMap[i]

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
                // `sourceLine` was captured at the OPENING fence, before `i` walked
                // to the closing one.
                if language.lowercased() == "mermaid" {
                    blocks.append(.mermaidDiagram(index: blockIndex, source: codeContent, sourceLine: sourceLine))
                } else {
                    blocks.append(.codeBlock(index: blockIndex, code: codeContent, language: language, sourceLine: sourceLine))
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
                        blocks.append(.mathBlock(index: blockIndex, latex: latex, sourceLine: sourceLine))
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
                    // Opening `$$` line, not the closing one.
                    blocks.append(.mathBlock(index: blockIndex, latex: latex, sourceLine: sourceLine))
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
                blocks.append(.heading(index: blockIndex, level: level, title: title, sourceLine: sourceLine))
                blockIndex += 1
                i += 1
                continue
            }

            // Standalone image (on its own line)
            if let imageMatch = parseStandaloneImage(line) {
                flushTextBuffer(&textBuffer, to: &blocks, index: &blockIndex, using: activeRenderer)
                blocks.append(.image(index: blockIndex, url: imageMatch.url, alt: imageMatch.alt, sourceLine: sourceLine))
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
                    // Setext: the TEXT line owns the heading, not the `===` underline.
                    blocks.append(.heading(index: blockIndex, level: 1, title: trimmed, sourceLine: sourceLine))
                    blockIndex += 1
                    i += 2
                    continue
                }

                // NOTE: no `!isTableSeparator(nextLine)` guard here — a line of
                // pure dashes ALWAYS matches the table-separator pattern (pipes
                // are optional in it), which made this branch unreachable and
                // silently disabled setext H2 for years. A pipe-bearing table
                // separator can't match setextH2Pattern anyway, so the guard
                // added nothing. (Caught by ParserTests.testSetextHeadings.)
                if nextLine.range(of: MarkdownTheme.setextH2Pattern, options: .regularExpression) != nil {
                    flushTextBuffer(&textBuffer, to: &blocks, index: &blockIndex, using: activeRenderer)
                    blocks.append(.heading(index: blockIndex, level: 2, title: trimmed, sourceLine: sourceLine))
                    blockIndex += 1
                    i += 2
                    continue
                }
            }

            // Table detection
            if line.filter({ $0 == "|" }).count >= 2 && !trimmed.isEmpty {
                if !isTableSeparator(trimmed) && i + 1 < lines.count && isTableSeparator(lines[i + 1]) {
                    flushTextBuffer(&textBuffer, to: &blocks, index: &blockIndex, using: activeRenderer)

                    var alignments = parseTableAlignments(lines[i + 1])
                    // The separator row is authoritative for column count: a header row
                    // of entirely empty cells (`| | |`, a headerless table) parses to zero
                    // cells, which would otherwise collapse the whole table to nothing.
                    var headers = parseTableRow(line)
                    let columnCount = max(headers.count, alignments.count)
                    var rows: [[String]] = []
                    i += 2 // Skip header and separator

                    while i < lines.count && lines[i].contains("|") && !isTableSeparator(lines[i]) {
                        rows.append(parseTableRow(lines[i]))
                        i += 1
                    }

                    // Normalize: ensure headers, rows, and alignments match column count
                    headers = normalizeArray(headers, to: columnCount, default: "")
                    alignments = normalizeArray(alignments, to: columnCount, default: .leading)
                    rows = rows.map { normalizeArray($0, to: columnCount, default: "") }

                    // Header row line — `i` has already walked past the body rows.
                    blocks.append(.table(index: blockIndex, headers: headers, rows: rows, alignments: alignments, sourceLine: sourceLine))
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

                    // Accumulate consecutive lines at the same nesting level.
                    // A single `>` run can yield SEVERAL blocks (one per nesting
                    // level), so each group needs its OWN first line — the outer
                    // `sourceLine` only describes the first group.
                    let groupSourceLine = lineMap[i]
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
                        // GFM alert: level-1 quote whose first line is exactly
                        // `[!NOTE]` / `[!TIP]` / `[!IMPORTANT]` / `[!WARNING]` /
                        // `[!CAUTION]` (marker alone on the line, per GitHub spec).
                        if groupLevel == 1, let kind = AlertKind(markerLine: groupLines[0]) {
                            let body = groupLines.dropFirst().joined(separator: "\n")
                                .trimmingCharacters(in: .whitespacesAndNewlines)
                            blocks.append(.alert(index: blockIndex, kind: kind, content: body, sourceLine: groupSourceLine))
                        } else {
                            blocks.append(.blockquote(index: blockIndex, content: content, level: groupLevel, sourceLine: groupSourceLine))
                        }
                        blockIndex += 1
                    }
                }
                continue
            }

            // Definition list (PHP Markdown Extra / Pandoc). Detected FROM the
            // `: definition` line, looking BACK at the buffered term lines:
            // probing forward from every paragraph line would re-walk the whole
            // paragraph run once per line (quadratic on prose-heavy documents),
            // and by the time we reach the definition the term is buffered
            // anyway. Placed last, so every other block start above wins — and
            // a term is only ever a line that is not itself a block start
            // (`isTermCandidate`).
            if let firstDefinition = Self.definitionText(of: line),
               let run = trailingTermRun(in: textBuffer) {
                // Whatever sat above the terms is a paragraph of its own — the
                // term line is NOT part of it (PHP Markdown Extra reads
                // "para line\n: def" as term + definition).
                var preceding = Array(textBuffer[..<run.bufferStart])
                flushTextBuffer(&preceding, to: &blocks, index: &blockIndex, using: activeRenderer)
                let termSourceLine = textBuffer[run.bufferStart].originalIndex
                textBuffer.removeAll()

                let list = scanDefinitionList(lines, terms: run.terms,
                                              firstDefinition: firstDefinition, from: i + 1)
                blocks.append(.text(index: blockIndex,
                                    activeRenderer.renderDefinitionList(groups: list.groups),
                                    sourceLine: termSourceLine))
                blockIndex += 1
                i = list.end
                continue
            }

            textBuffer.append((line: line, originalIndex: sourceLine))
            i += 1
        }

        flushTextBuffer(&textBuffer, to: &blocks, index: &blockIndex, using: activeRenderer)

        // Append footnotes block at end of document if any definitions exist
        if !footnoteDefinitions.isEmpty {
            var footnoteText = AttributedString("")

            // Horizontal rule separator
            var rule = AttributedString("────────────────────────────────\n")
            rule.setDualFont(size: renderer.scaled(12), fonts: theme.fonts)
            rule.setDualForeground(theme.secondaryTextColor)
            footnoteText.append(rule)

            for (index, def) in footnoteDefinitions.enumerated() {
                let number = index + 1
                var prefix = AttributedString("\(number). ")
                prefix.setDualFont(size: renderer.scaled(12), bold: true, fonts: theme.fonts)
                prefix.setDualForeground(theme.secondaryTextColor)

                var content = activeRenderer.renderInline(def.content)
                content.setDualFont(size: renderer.scaled(12), fonts: theme.fonts)
                content.setDualForeground(theme.secondaryTextColor)

                footnoteText.append(prefix)
                footnoteText.append(content)
                footnoteText.append(AttributedString("\n"))
            }

            // Synthetic block: it renders at the very end regardless of where the
            // `[^id]:` definitions sat in the file, so anchoring it to the last
            // source line keeps `sourceLine` non-decreasing across the block list
            // (definitions in the middle of a document would otherwise make the
            // final block point backwards).
            blocks.append(.text(index: blockIndex, footnoteText, sourceLine: max(allLines.count - 1, 0)))
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

    // MARK: - Definition Lists (PHP Markdown Extra / Pandoc)
    //
    // ```
    // Apple
    // Orange
    // : The fruit          ← one definition shared by two terms
    // : A company          ← a second definition of the same terms
    //
    // Pear                 ← a new term group, still ONE block
    // : Another fruit
    //   that wraps         ← lazy continuation of the definition
    // ```
    //
    // The whole list becomes ONE `.text` block, rendered by
    // `MarkdownRenderer.renderDefinitionList` — so search, height measurement,
    // print and PDF need no new block kind. Inside a blockquote nothing changes:
    // the quote branch above consumes those lines and `renderQuotedBody`
    // renders them as ordinary text.

    /// The text of a `: definition` line, or nil when the line is not one: up to
    /// three leading spaces, a colon, then a space or tab, then the text.
    ///
    /// The space is what makes it a marker, so `:smile:` (shortcode) and
    /// `Note: text` (colon not first) are deliberately NOT definitions — and a
    /// line indented four or more spaces is a definition's continuation, not a
    /// new definition.
    private static func definitionText(of line: String) -> String? {
        var scanner = line[...]
        var indent = 0
        while indent < 3, scanner.first == " " {
            scanner = scanner.dropFirst()
            indent += 1
        }
        guard scanner.first == ":" else { return nil }
        scanner = scanner.dropFirst()
        guard scanner.first == " " || scanner.first == "\t" else { return nil }
        // Padding after the marker (`:   text`) is dropped, but TRAILING
        // whitespace is kept: two trailing spaces are a hard break, and the
        // renderer's soft-break pass has to still see them.
        let text = String(scanner.drop(while: { $0 == " " || $0 == "\t" }))
        return text.trimmingCharacters(in: .whitespaces).isEmpty ? nil : text
    }

    private static func isBlank(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Can this line be a definition-list TERM? Non-blank, not a definition
    /// line, and not the start of any other block this parser recognises
    /// (heading, list item, table row, fence, quote, image, `$$`, rule).
    ///
    /// It is also the test for a definition's lazy continuation lines: a
    /// continuation is exactly "a line that could have been a term", which is
    /// why one predicate serves both.
    private func isTermCandidate(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, Self.definitionText(of: line) == nil else { return false }

        // Fences, quotes, display math
        if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") { return false }
        if trimmed.hasPrefix(">") || trimmed.hasPrefix("$$") { return false }

        // List items — bullets (task items included, they start `- [ ]`) and ordered
        if ["- ", "* ", "+ "].contains(where: { trimmed.hasPrefix($0) }) { return false }
        if trimmed.range(of: #"^(\d+)\.\s"#, options: .regularExpression) != nil { return false }

        // Table rows (the table branch needs a separator to fire, but a pipe row
        // is still a table row, not a term) and separators
        if line.filter({ $0 == "|" }).count >= 2 { return false }
        if isTableSeparator(trimmed) { return false }

        // Rules and setext underlines
        if trimmed.range(of: MarkdownTheme.horizontalRulePattern, options: .regularExpression) != nil { return false }
        if trimmed.range(of: MarkdownTheme.setextH1Pattern, options: .regularExpression) != nil { return false }

        // ATX headings and standalone images
        let nsRange = NSRange(line.startIndex..., in: line)
        if Self.headerRegex.firstMatch(in: line, range: nsRange) != nil { return false }
        if parseStandaloneImage(line) != nil { return false }

        return true
    }

    /// The trailing lines of the text buffer that are the TERM(s) of the
    /// definition list starting at the `: definition` line we just reached:
    /// 1…N consecutive candidate lines, optionally followed by ONE blank line.
    ///
    /// Returns nil when the buffer does not end in a term run (no term ⇒ the
    /// `:` line is just paragraph text). Several terms sharing one definition is
    /// PHP Markdown Extra behaviour, so the run is taken greedily — a prose line
    /// directly above a term, with no blank line between them, becomes a term
    /// too, exactly as it does there.
    private func trailingTermRun(in buffer: [(line: String, originalIndex: Int)]) -> (terms: [String], bufferStart: Int)? {
        var end = buffer.count
        // At most ONE blank line may sit between the terms and the definition;
        // two means the term is too far away to be one.
        if end > 0, Self.isBlank(buffer[end - 1].line) { end -= 1 }

        var start = end
        while start > 0, isTermCandidate(buffer[start - 1].line) { start -= 1 }
        guard start < end else { return nil }

        return (buffer[start..<end].map { $0.line.trimmingCharacters(in: .whitespaces) }, start)
    }

    /// A term run plus the definition line that makes it one, scanned FORWARD —
    /// used for the second and later groups of a list already in progress.
    private struct DefinitionHead {
        let terms: [String]
        let firstDefinition: String
        /// Index of the line after the `: definition` line.
        let next: Int
    }

    private func scanTermHead(_ lines: [String], from start: Int) -> DefinitionHead? {
        var terms: [String] = []
        var index = start
        while index < lines.count, isTermCandidate(lines[index]) {
            terms.append(lines[index].trimmingCharacters(in: .whitespaces))
            index += 1
        }
        guard !terms.isEmpty, index < lines.count else { return nil }
        if Self.isBlank(lines[index]) { index += 1 }   // one blank line is allowed
        guard index < lines.count, let text = Self.definitionText(of: lines[index]) else { return nil }
        return DefinitionHead(terms: terms, firstDefinition: text, next: index + 1)
    }

    /// Walks a definition list whose first group's terms and first definition are
    /// already known, from `start` — the line AFTER that `: definition` line.
    /// Returns the groups and the first line index that is NOT part of the list.
    private func scanDefinitionList(_ lines: [String], terms firstTerms: [String],
                                    firstDefinition: String, from start: Int)
        -> (groups: [MarkdownRenderer.DefinitionGroup], end: Int) {
        var groups: [MarkdownRenderer.DefinitionGroup] = []
        var terms = firstTerms
        var definitions: [String] = []
        // Lines of the definition under construction — its `: ` text plus any
        // lazy continuation lines. The renderer joins them like a paragraph.
        var current: [String] = [firstDefinition]
        var index = start

        func closeDefinition() {
            definitions.append(current.joined(separator: "\n"))
            current = []
        }
        func closeGroup() {
            closeDefinition()
            groups.append(MarkdownRenderer.DefinitionGroup(terms: terms, definitions: definitions))
            definitions = []
        }

        while index < lines.count {
            let line = lines[index]

            // A further definition of the same terms (tight list)
            if let text = Self.definitionText(of: line) {
                closeDefinition()
                current = [text]
                index += 1
                continue
            }

            if Self.isBlank(line) {
                // The blank ends the definition. One blank + `: ` is a further
                // (loose) definition of the same terms; one blank + a term run
                // that has its own definition is a new group in this SAME block;
                // anything else ends the list, blank line left behind.
                if index + 1 < lines.count, let text = Self.definitionText(of: lines[index + 1]) {
                    closeDefinition()
                    current = [text]
                    index += 2
                    continue
                }
                if let head = scanTermHead(lines, from: index + 1) {
                    closeGroup()
                    terms = head.terms
                    current = [head.firstDefinition]
                    index = head.next
                    continue
                }
                break
            }

            // Lazy continuation — but a new block start (fence, heading, table,
            // quote, list, image, math) ends the list instead.
            guard isTermCandidate(line) else { break }
            current.append(line)
            index += 1
        }

        closeGroup()
        return (groups, index)
    }

    // MARK: - Text Buffer

    /// Cap on lines per text block. Large bullet/link lists (e.g. 11K-line bookmark dumps)
    /// would otherwise coalesce into one ~10000-char Text(AttributedString) per heading
    /// section — slow to lay out on window resize. We split at blank-line (paragraph)
    /// boundaries so visual rendering is unaffected, but each individual block stays
    /// small enough for SwiftUI Text to lay out quickly.
    private static let textChunkLineLimit = 30

    private func flushTextBuffer(_ buffer: inout [(line: String, originalIndex: Int)], to blocks: inout [MarkdownBlock], index: inout Int, using renderer: MarkdownRenderer) {
        guard !buffer.isEmpty else { return }
        // A buffer of nothing but blank lines (the separator between two
        // blockquotes, a heading and a code fence, …) used to flush an EMPTY
        // text block that rendered as a ~42 pt gap. Drop it: block spacing is
        // the stack's job, not the parser's.
        guard buffer.contains(where: { !$0.line.trimmingCharacters(in: .whitespaces).isEmpty }) else {
            buffer.removeAll()
            return
        }

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
                    if buffer[probe].line.trimmingCharacters(in: .whitespaces).isEmpty {
                        sliceEnd = probe + 1   // include the blank line in this chunk
                        break
                    }
                    probe -= 1
                }
                // If no blank line found inside the window, fall through with hardEnd —
                // the chunk is one long paragraph and we just have to take the hit.
            }

            let chunk = buffer[chunkStart..<sliceEnd]
            // Each chunk reports the original line of ITS first NON-BLANK line —
            // the separator blank lines the previous block left behind are not
            // content. A chunk with no content at all (a long run of blank lines
            // sliced off on its own) is dropped for the same reason as above.
            guard let chunkSourceLine = chunk.first(where: { !$0.line.trimmingCharacters(in: .whitespaces).isEmpty })?.originalIndex else {
                chunkStart = sliceEnd
                continue
            }
            let slice = chunk.map(\.line).joined(separator: "\n")
            blocks.append(.text(index: index, renderer.render(slice), sourceLine: chunkSourceLine))
            index += 1
            chunkStart = sliceEnd
        }
        buffer = []
    }
}
