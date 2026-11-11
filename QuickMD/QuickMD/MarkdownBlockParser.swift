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
    static let headerRegex = try! NSRegularExpression(pattern: MarkdownTheme.headerPattern)
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
        // the VERY FIRST line, closed by "---" or "...". Rendered as a
        // properties table when `FrontMatter` reads it (flat keys, scalar
        // lists), otherwise as a neutral yaml code block — lossless. Without
        // this step the setext-H2 rule would promote the first frontmatter key
        // to a giant heading.
        var firstContentLine = 0
        if allLines.first.map(Self.markerLine) == "---" {
            var closingIndex: Int?
            var j = 1
            while j < allLines.count {
                let t = Self.markerLine(allLines[j])
                if t == "---" || t == "..." { closingIndex = j; break }
                j += 1
            }
            if let closingIndex {
                let yaml = allLines[1..<closingIndex].joined(separator: "\n")
                if !yaml.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    // Front matter starts at the opening `---`, which the branch
                    // condition pins to line 0 of the original document.
                    if let properties = FrontMatter.properties(fromYAML: yaml) {
                        // Rows built here never pass `parseTableRow`, so a `|`
                        // in a value is already one cell — nothing to escape.
                        blocks.append(.table(index: blockIndex, headers: [],
                                             rows: properties.map { [$0.key, $0.value] },
                                             alignments: [.leading, .leading], style: .properties,
                                             sourceLine: 0, isFrontMatter: true))
                    } else {
                        blocks.append(.codeBlock(index: blockIndex, code: yaml, language: "yaml", sourceLine: 0,
                                                 isFrontMatter: true))
                    }
                    blockIndex += 1
                }
                firstContentLine = closingIndex + 1
            }
        }

        // Pre-pass: collect reference link definitions and footnote definitions, filter them out
        var referenceDefinitions: [String: String] = [:]
        // In DEFINITION order here; renumbered by first reference after the
        // pre-pass (`FootnoteNumbering`).
        var footnoteDefinitions: [(id: String, content: String)] = []
        var footnoteIds = Set<String>()
        // Every text drawn as Markdown, in document order, for the numbering.
        var footnoteNumbering = FootnoteNumbering()
        // The list items open at each line (`ListNesting`, fed as the block
        // loop reads the lines, near enough for these two questions): where a
        // footnote definition's continuation lines start (the item's content
        // column), and which lines are an item's indented code — verbatim,
        // so a `[x]: url` in it stays code (GitHub).
        var definitionNesting = ListNesting()
        // The columns an item's indented code takes off its lines, while in it.
        var indentedCodeColumns: Int?
        // The footnote definition whose lines may go on
        // (`FootnoteDefinitionBody`): its id (nil for a duplicate, whose text
        // is not shown), its line, and the blank lines read since its last
        // line, which are the document's again if the definition ends after
        // them.
        var openFootnote: (id: String?, line: Int, body: FootnoteDefinitionBody)?
        var blanksAfterFootnote: [Int] = []
        var lines: [String] = []
        // Maps index in the filtered `lines` back to the index in `allLines`.
        // Headings carry the original line number so section copy can slice the
        // raw text without re-detecting headings itself.
        var lineMap: [Int] = []
        // Indices in `lines` of quote lines a link or footnote definition was
        // taken out of: kept as markers without text, so the block loop knows
        // the quote's paragraph they open (`DefinitionPlacement.definitionTaken`).
        var definitionLines = Set<Int>()
        // Fenced code and `$$` blocks, read as the block loop reads them: a
        // definition inside one is that block's text (GitHub).
        var verbatim = VerbatimRegions()
        let allNextMath = Self.nextMathLines(allLines)
        // A link definition cannot interrupt a paragraph (`DefinitionPlacement`).
        var placement = DefinitionPlacement()
        // A link definition: the FIRST of a label wins (CommonMark, GitHub),
        // character references in the destination decoded, as in an inline
        // link's (`InlineSyntaxScanner.unescaped`). False when `text` is none.
        func defineLink(_ text: String) -> Bool {
            guard let match = Self.refLinkDefRegex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let idRange = Range(match.range(at: 1), in: text),
                  let urlRange = Range(match.range(at: 2), in: text) else { return false }
            // A label of whitespace only defines nothing (CommonMark): the line is text.
            let label = ReferenceLabel.normalized(text[idRange])
            guard !label.isEmpty else { return false }
            if referenceDefinitions[label] == nil {
                referenceDefinitions[label] = HTMLEntities.decode(String(text[urlRange]))
            }
            return true
        }
        // The open footnote definition is complete: store its text (first
        // definition of an id only; every one's references count), give the
        // blank lines after it back. `ending`: the line that ended it.
        func closeFootnote(ending: String?) {
            guard let open = openFootnote else { return }
            if let id = open.id {
                footnoteDefinitions.append((id: id, content: open.body.content))
            }
            for drawn in FootnoteDefinitionBody.displayLines(of: open.body.content) {
                footnoteNumbering.note(drawn)
            }
            openFootnote = nil
            // A definition that interrupted a paragraph ends it (GitHub): the
            // line after it must not continue that paragraph as a Setext
            // underline (`---`), an item that cannot interrupt one
            // (`1984. y`), or text after an empty `[^n]:`. A blank line
            // where the definition stood says so to the block loop.
            if blanksAfterFootnote.isEmpty, let ending, let previous = lines.last,
               !MarkdownRenderer.isBlankLine(previous), Self.wouldContinueParagraph(ending) {
                blanksAfterFootnote.append(open.line)
            }
            for blank in blanksAfterFootnote {
                lines.append(blank == open.line ? "" : allLines[blank])
                lineMap.append(blank)
                placement.kept("")
                footnoteNumbering.keep("")
                definitionNesting.blank()
            }
            blanksAfterFootnote.removeAll()
        }
        // A footnote definition starts: the FIRST definition of an id wins
        // (GitHub drops a later one from the list too).
        func startFootnote(id: String, firstLine: String, at index: Int) {
            closeFootnote(ending: allLines[index])
            let isNew = footnoteIds.insert(id).inserted
            definitionNesting.block(startingAt: allLines[index])
            let column = definitionNesting.items.last?.contentColumn ?? 0
            openFootnote = (id: isNew ? id : nil, line: index,
                            body: FootnoteDefinitionBody(firstLine: firstLine, containerColumn: column))
        }
        for originalIndex in firstContentLine..<allLines.count {
            let line = allLines[originalIndex]
            // The lines a footnote definition goes on with are its text, read
            // before anything else (an indented fence in it opens no code).
            if var open = openFootnote {
                if MarkdownRenderer.isBlankLine(line) {
                    blanksAfterFootnote.append(originalIndex)
                    continue
                }
                let step = open.body.take(line, afterBlank: !blanksAfterFootnote.isEmpty,
                                          isLinkDefinition: { defineLink($0) })
                openFootnote = open
                if step != .ended {
                    blanksAfterFootnote.removeAll()
                    continue
                }
                closeFootnote(ending: line)
            }
            let trimmed = Self.markerLine(line)
            // Indented code under a list item, read as the block loop reads
            // it (`ListNesting.indentedCode`): its lines are code, a definition
            // in them too. Not inside a fence or `$$` block.
            if !verbatim.isOpen {
                if let columns = indentedCodeColumns,
                   !(MarkdownRenderer.isBlankLine(line) || Self.indentColumns(line) >= columns) {
                    indentedCodeColumns = nil
                }
                if indentedCodeColumns == nil, let code = definitionNesting.indentedCode(line) {
                    definitionNesting.block(startingAt: line)
                    indentedCodeColumns = code.columns
                }
                if indentedCodeColumns != nil {
                    lines.append(line)
                    lineMap.append(originalIndex)
                    placement.verbatim()
                    footnoteNumbering.note("")
                    continue
                }
            }
            let opensVerbatim = !verbatim.isOpen
            if verbatim.contains(trimmed, at: originalIndex, nextMath: allNextMath,
                                 markerAt: { Self.markerLine(allLines[$0]) }) {
                lines.append(line)
                lineMap.append(originalIndex)
                placement.verbatim()
                footnoteNumbering.note("")
                // Only the opening line starts a block; the rest is its text.
                if opensVerbatim { definitionNesting.block(startingAt: line) }
                continue
            }
            let nsRange = NSRange(trimmed.startIndex..., in: trimmed)
            // Footnote definitions must be checked BEFORE reference links
            // because [^id]: text also matches the reference link pattern [id]: url
            if let match = Self.footnoteDefRegex.firstMatch(in: trimmed, range: nsRange),
                      let idRange = Range(match.range(at: 1), in: trimmed),
                      let contentRange = Range(match.range(at: 2), in: trimmed) {
                // Ids are normalised labels (`ReferenceLabel`): `[^Note]` finds
                // `[^note]:`. Its text goes on in the lines that follow
                // (`FootnoteDefinitionBody`), so the trailing white space the
                // marker line dropped comes back: two spaces are a hard break.
                let trailing = line.reversed().prefix(while: { $0 == " " || $0 == "\t" })
                startFootnote(id: ReferenceLabel.normalized(trimmed[idRange]),
                              firstLine: String(trimmed[contentRange]) + String(trailing), at: originalIndex)
                placement.definition()
            } else if let text = placement.footnoteDefinitionText(trimmed),
                      let match = Self.footnoteDefRegex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                      let idRange = Range(match.range(at: 1), in: text),
                      let contentRange = Range(match.range(at: 2), in: text) {
                // A quote's footnote: before the link pattern here too. One
                // line (its lazy lines stay the quote's).
                let fnId = ReferenceLabel.normalized(text[idRange])
                if footnoteIds.insert(fnId).inserted {
                    footnoteDefinitions.append((id: fnId, content: String(text[contentRange])))
                }
                footnoteNumbering.note(String(text[contentRange]))
                definitionNesting.block(startingAt: line)
                _ = placement.definitionTaken(trimmed)
                lines.append(line)
                lineMap.append(originalIndex)
                definitionLines.insert(lines.count - 1)
            } else if let text = placement.linkDefinitionText(trimmed), defineLink(text) {
                footnoteNumbering.note("")
                // A definition starts a block: at the margin it ends a list.
                definitionNesting.block(startingAt: line)
                if placement.definitionTaken(trimmed) {
                    lines.append(line)
                    lineMap.append(originalIndex)
                    definitionLines.insert(lines.count - 1)
                }
            } else {
                lines.append(line)
                lineMap.append(originalIndex)
                placement.kept(line)
                footnoteNumbering.keep(line)
                definitionNesting.read(line, sourceLine: originalIndex)
            }
        }
        closeFootnote(ending: nil)

        // Footnotes are numbered by their first reference, and only those
        // referenced are listed (`FootnoteNumbering`, GitHub): the renderers
        // number a reference by its definition's position in this list.
        if !footnoteDefinitions.isEmpty {
            let order = footnoteNumbering.order(defined: footnoteIds)
            let contents = Dictionary(footnoteDefinitions.map { ($0.id, $0.content) },
                                      uniquingKeysWith: { first, _ in first })
            footnoteDefinitions = order.compactMap { id in contents[id].map { (id: id, content: $0) } }
        }

        // Use reference-aware renderer if definitions were found
        let activeRenderer = referenceDefinitions.isEmpty && footnoteDefinitions.isEmpty
            ? self.renderer
            : MarkdownRenderer(theme: theme, fontScale: fontScale, referenceDefinitions: referenceDefinitions, footnoteDefinitions: footnoteDefinitions)

        // The `$$` lines' look-ahead (`mathOpening`), once per parse.
        let nextMath = Self.nextMathLines(lines)
        var i = 0
        // Each buffered line keeps the index it had in `allLines` so a flushed
        // chunk can report the ORIGINAL first line, not its position in `lines`.
        var textBuffer: [(line: String, originalIndex: Int)] = []
        // Text rows are rendered once the whole document is parsed
        // (`renderPendingRows`): an ordered list's items hang under the
        // LIST's widest marker, and a list goes on past a block nested in it.
        var pendingRows: [PendingTextRow] = []
        // `imageParagraph` is not tried again before this line (see there).
        var imageParagraphSkip = 0
        // Which list item owns what (`ListNesting`): the item line (original
        // index) of a paragraph's first line, and of a code block (by its
        // position in `blocks`). `renderPendingRows` lines them up with it.
        var nesting = ListNesting()
        var paragraphOwners: [Int: Int] = [:]
        var blockOwners: [Int: Int] = [:]

        while i < lines.count {
            // Every turn consumes at least one line. A branch that decides on a
            // line its own loop then refuses would otherwise re-enter it for
            // ever (a quote marker after a no-break space did, 9bbf6ae): DEBUG
            // stops there, Release keeps the line as text and goes on.
            let turnStart = i
            defer {
                if i <= turnStart {
                    assertionFailure("MarkdownBlockParser: no line consumed at \(turnStart)")
                    textBuffer.append((line: lines[turnStart], originalIndex: lineMap[turnStart]))
                    i = turnStart + 1
                }
            }
            let line = lines[i]
            // Original-document line of the block that starts here (definition
            // lines were dropped from `lines`, so `i` alone is not the answer).
            let sourceLine = lineMap[i]
            // Definitions the pre-pass took out of the lines before this one
            // started blocks there: at the margin they end a list (GitHub).
            let firstRemoved = i > 0 ? lineMap[i - 1] + 1 : firstContentLine
            if firstRemoved < sourceLine {
                for removed in firstRemoved..<sourceLine where !Self.isBlank(allLines[removed]) {
                    nesting.block(startingAt: allLines[removed])
                }
            }

            // What every block marker below is looked for in (`markerLine`).
            let trimmedLine = Self.markerLine(line)

            // Indented code under a list item (CommonMark): four columns past
            // the item's content column, not after paragraph text. FIRST: such
            // a line is code whatever it looks like (a fence, `#`, `- x`).
            // Blank lines inside it are code; trailing ones are not.
            if let code = nesting.indentedCode(line) {
                flushTextBuffer(&textBuffer, to: &blocks, index: &blockIndex, pending: &pendingRows)
                nesting.block(startingAt: line)
                var codeLines: [String] = []
                var end = i
                var j = i
                while j < lines.count {
                    if Self.isBlank(lines[j]) {
                        codeLines.append(Self.removingIndentation(lines[j], upTo: code.columns))
                    } else if Self.indentColumns(lines[j]) >= code.columns {
                        codeLines.append(Self.removingIndentation(lines[j], upTo: code.columns))
                        end = j + 1
                    } else {
                        break
                    }
                    j += 1
                }
                codeLines.removeLast(j - end)
                blockOwners[blocks.count] = code.owner
                blocks.append(.codeBlock(index: blockIndex, code: codeLines.joined(separator: "\n"), language: "",
                                         sourceLine: sourceLine))
                blockIndex += 1
                i = end
                continue
            }

            // Fenced code block — check BEFORE math to protect $$ inside code blocks
            if let opening = Self.fenceOpening(trimmedLine) {
                flushTextBuffer(&textBuffer, to: &blocks, index: &blockIndex, pending: &pendingRows)
                // A fence indented under a list item is that item's.
                let owner = nesting.block(startingAt: line)
                let fenceLength = opening.length
                // CommonMark: a fence indented N columns drops up to N columns
                // of indentation from each of its lines (a fence under a list
                // item is not drawn shifted right).
                let fenceIndent = Self.indentColumns(line)

                // Extract language after fence
                let language = String(trimmedLine.dropFirst(fenceLength)).trimmingCharacters(in: .whitespaces)
                var codeLines: [String] = []
                i += 1

                // Closing fence must be same char, same or greater length, nothing else
                while i < lines.count {
                    if Self.closesFence(Self.markerLine(lines[i]), opening) {
                        i += 1
                        break
                    }
                    codeLines.append(Self.removingIndentation(lines[i], upTo: fenceIndent))
                    i += 1
                }

                let codeContent = codeLines.joined(separator: "\n")
                // `sourceLine` was captured at the OPENING fence, before `i` walked
                // to the closing one.
                if language.lowercased() == "mermaid" {
                    blocks.append(.mermaidDiagram(index: blockIndex, source: codeContent, sourceLine: sourceLine))
                } else if language.lowercased() == "svg" {
                    blocks.append(.svgImage(index: blockIndex, source: codeContent, sourceLine: sourceLine))
                } else {
                    // Only a code block is drawn at the item's text; a diagram
                    // or a picture under an item stays at the margin.
                    if let owner { blockOwners[blocks.count] = owner }
                    blocks.append(.codeBlock(index: blockIndex, code: codeContent, language: language, sourceLine: sourceLine))
                }
                blockIndex += 1
                continue
            }

            // Display math block $$...$$ — after code block check to protect $$
            // inside code. A `$$` line that is paragraph text (`mathOpening`:
            // `$$x$$ text`, unclosed) falls through to the text branches.
            let mathOpening: MathOpening? = trimmedLine.hasPrefix("$$")
                ? Self.mathOpening(trimmedLine, nextMathLine: nextMath[i],
                                   nextMathMarker: nextMath[i].map { Self.markerLine(lines[$0]) })
                : nil
            if let mathOpening, mathOpening != .text {
                flushTextBuffer(&textBuffer, to: &blocks, index: &blockIndex, pending: &pendingRows)
                nesting.block(startingAt: line)

                let afterDollar = String(trimmedLine.dropFirst(2)).trimmingCharacters(in: .whitespaces)

                // Single-line: $$content$$ (must have content between delimiters)
                guard case .block(let closingLine, let closingText) = mathOpening else {
                    if case .singleLine(let latex) = mathOpening, !latex.isEmpty {
                        blocks.append(.mathBlock(index: blockIndex, latex: latex, sourceLine: sourceLine))
                        blockIndex += 1
                    }
                    i += 1
                    continue
                }

                // Multi-line: up to and including the closing line.
                var mathLines: [String] = []
                if !afterDollar.isEmpty { mathLines.append(afterDollar) }
                mathLines.append(contentsOf: lines[(i + 1)..<closingLine])
                if !closingText.isEmpty { mathLines.append(closingText) }
                i = closingLine + 1

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
                flushTextBuffer(&textBuffer, to: &blocks, index: &blockIndex, pending: &pendingRows)
                nesting.block(startingAt: line)
                let level = min(max(line[hashRange].count, 1), 6)
                let title = Self.withoutClosingSequence(
                    String(line[contentRange]).trimmingCharacters(in: .whitespaces))
                // Headings are rendered later without the definitions (`ReferenceLinks`).
                blocks.append(.heading(index: blockIndex, level: level,
                                       title: ReferenceLinks.inlinedHeading(title, definitions: referenceDefinitions,
                                                                            footnoteIds: footnoteDefinitions.map(\.id)),
                                       sourceLine: sourceLine))
                blockIndex += 1
                i += 1
                continue
            }

            // A PARAGRAPH made only of images, plain and/or linked
            // (`imageParagraph`): README badges one per line, `![a](x)
            // ![b](y)`, consecutive image lines — GitHub's one `<p>` of
            // inline pictures. Two or more are one `.imageRow` (pictures
            // that wrap like words); a lone one is the `.image` block, with
            // its link when it has one (click = follow it). Only where a
            // paragraph can start, and only when the paragraph ends with its
            // images: text before or after keeps the lines below.
            if i >= imageParagraphSkip, Self.noParagraphOpen(textBuffer) {
                switch imageParagraph(at: i, in: lines, references: referenceDefinitions) {
                case .images(let images, let end):
                    flushTextBuffer(&textBuffer, to: &blocks, index: &blockIndex, pending: &pendingRows)
                    // Paragraph text for the list nesting, as an image line
                    // always was (an item's paragraph; the picture or row is
                    // drawn at the margin, like a lone image). Its other lines
                    // continue that paragraph: nothing more to tell.
                    _ = nesting.text(line, sourceLine: sourceLine)
                    if images.count == 1, let image = images.first {
                        blocks.append(.image(index: blockIndex, url: image.url, alt: image.alt, width: image.width,
                                             link: image.link, sourceLine: sourceLine))
                    } else {
                        blocks.append(.imageRow(index: blockIndex, images: images, sourceLine: sourceLine))
                    }
                    blockIndex += 1
                    i = end
                    continue
                case .notImages(let checkedUntil):
                    // The lines up to there belong to a paragraph that is
                    // not images only: no image paragraph starts inside it,
                    // and scanning them again from each line would be
                    // quadratic on a long run of image lines.
                    imageParagraphSkip = checkedUntil
                }
            }

            // Standalone image line: one OR MORE images and nothing else. Each
            // becomes its own `.image` block, all on this line's `sourceLine`
            // (`![a](x.png) ![b](y.png)` is two pictures, not one bogus url).
            // Reached only for a line inside a longer paragraph (text before
            // or after it): the pre-1.15 behaviour, kept.
            if let images = InlineSyntaxScanner.standaloneImages(in: line[...], references: referenceDefinitions) {
                flushTextBuffer(&textBuffer, to: &blocks, index: &blockIndex, pending: &pendingRows)
                // Paragraph text in CommonMark: an item's paragraph goes on.
                _ = nesting.text(line, sourceLine: sourceLine)
                for image in images {
                    // The alt is caption text: references decoded like any inline
                    // text (an `<img alt>` is decoded by `HTMLImageSyntax`).
                    blocks.append(.image(index: blockIndex, url: image.url, alt: HTMLEntities.decode(image.alt),
                                         width: nil, sourceLine: sourceLine))
                    blockIndex += 1
                }
                i += 1
                continue
            }

            // HTML image line (T-C): nothing but `<img>` tags and layout
            // wrappers (`<p align="center">`, `</p>`, `<a …>`, …), possibly an
            // `<img` tag spread over several lines. Each `<img>` is an
            // `.image` block on the line its tag STARTS on.
            //
            // A wrapper-only line produces no block and — deliberately — does
            // NOT flush the text buffer either: it is a no-op, as if the line
            // were not there. So a `</p>` between two list items or two
            // paragraph lines does not split them, and it never shows up as
            // literal text. The one exception is a `<br>`-only line right
            // after buffered text: GitHub renders it as a line break, so it
            // becomes a CommonMark hard break (two trailing spaces) on that
            // line. At a block boundary (empty buffer, or a blank line last)
            // it stays a no-op. The definition-list forward scans skip
            // wrapper lines the same way (`wrapperOnlyLine`).
            if let html = htmlImageLine(lines, at: i) {
                if html.images.isEmpty {
                    if html.lineBreakOnly, let last = textBuffer.indices.last, !Self.isBlank(textBuffer[last].line) {
                        textBuffer[last].line += "  "
                    }
                } else {
                    flushTextBuffer(&textBuffer, to: &blocks, index: &blockIndex, pending: &pendingRows)
                    // Inline HTML in a paragraph for CommonMark: as an image line.
                    _ = nesting.text(line, sourceLine: sourceLine)
                    for tag in html.images {
                        // `<a href="…"><img></a>` on one line: the picture is the link.
                        blocks.append(.image(index: blockIndex, url: tag.url, alt: tag.alt, width: tag.width,
                                             link: tag.link.flatMap { MarkdownRenderer.linkURL(for: $0) },
                                             sourceLine: lineMap[i + tag.lineOffset]))
                        blockIndex += 1
                    }
                }
                i = html.end
                continue
            }

            // Setext headers (underlined headers): the WHOLE paragraph above
            // the underline is the heading (CommonMark, GitHub), on the
            // paragraph's first line. Its title keeps the lines' breaks
            // (`setextTitle`): shown as spaces, dropped by the anchor. Not a
            // list item's paragraph (`- a` over `===` is the item's text, over
            // `---` the list and a rule) nor a quote line's (the quote branch
            // takes those, lazy lines included).
            //
            // NOTE: no `!isTableSeparator(nextLine)` guard — a line of pure
            // dashes ALWAYS matches the table-separator pattern (pipes are
            // optional in it), which once made setext H2 unreachable. A
            // pipe-bearing separator can't match setextH2Pattern anyway.
            // (Caught by ParserTests.testSetextHeadings.)
            let trimmed = trimmedLine
            if i + 1 < lines.count && !trimmed.isEmpty && !trimmed.contains("|") && !trimmed.hasPrefix(">") {
                let nextLine = Self.markerLine(lines[i + 1])
                let level: Int?
                if nextLine.range(of: MarkdownTheme.setextH1Pattern, options: .regularExpression) != nil {
                    level = 1
                } else if nextLine.range(of: MarkdownTheme.setextH2Pattern, options: .regularExpression) != nil {
                    level = 2
                } else {
                    level = nil
                }
                if let level, let start = Self.setextParagraphStart(in: textBuffer, endingWith: line) {
                    let title = Self.setextTitle(textBuffer[start...].map(\.line) + [line])
                    let headingLine = start < textBuffer.count ? textBuffer[start].originalIndex : sourceLine
                    var preceding = Array(textBuffer[..<start])
                    textBuffer.removeAll()
                    flushTextBuffer(&preceding, to: &blocks, index: &blockIndex, pending: &pendingRows)
                    nesting.block(startingAt: line)
                    blocks.append(.heading(index: blockIndex, level: level,
                                           title: ReferenceLinks.inlinedHeading(title, definitions: referenceDefinitions,
                                                                                footnoteIds: footnoteDefinitions.map(\.id)),
                                           sourceLine: headingLine))
                    blockIndex += 1
                    i += 2
                    continue
                }
            }

            // Table detection
            if Self.pipeCount(line) >= 2 && !trimmed.isEmpty {
                if !isTableSeparator(trimmed) && i + 1 < lines.count && isTableSeparator(lines[i + 1]) {
                    flushTextBuffer(&textBuffer, to: &blocks, index: &blockIndex, pending: &pendingRows)
                    nesting.block(startingAt: line)

                    var alignments = parseTableAlignments(lines[i + 1])
                    // The separator row is authoritative for column count: a header row
                    // of entirely empty cells (`| | |`, a headerless table) parses to zero
                    // cells, which would otherwise collapse the whole table to nothing.
                    var headers = parseTableRow(line)
                    let columnCount = max(headers.count, alignments.count)
                    var rows: [[String]] = []
                    i += 2 // Skip header and separator

                    while i < lines.count && lines[i].unicodeScalars.contains("|") && !isTableSeparator(lines[i])
                            && !Self.interruptsTable(lines[i]) {
                        rows.append(parseTableRow(lines[i]))
                        i += 1
                    }

                    // Normalize: ensure headers, rows, and alignments match column count
                    headers = normalizeArray(headers, to: columnCount, default: "")
                    alignments = normalizeArray(alignments, to: columnCount, default: .leading)
                    rows = rows.map { normalizeArray($0, to: columnCount, default: "") }
                    // Cells are rendered later without the definitions (`ReferenceLinks`).
                    if !referenceDefinitions.isEmpty || !footnoteDefinitions.isEmpty {
                        let ids = footnoteDefinitions.map(\.id)
                        headers = headers.map { ReferenceLinks.inlined($0, definitions: referenceDefinitions, footnoteIds: ids) }
                        rows = rows.map { $0.map { ReferenceLinks.inlined($0, definitions: referenceDefinitions, footnoteIds: ids) } }
                    }

                    // Header row line — `i` has already walked past the body rows.
                    blocks.append(.table(index: blockIndex, headers: headers, rows: rows, alignments: alignments,
                                         style: .grid, sourceLine: sourceLine))
                    blockIndex += 1
                    continue
                }
            }

            // Blockquote detection - group consecutive > lines by nesting level
            if trimmed.hasPrefix(">") {
                flushTextBuffer(&textBuffer, to: &blocks, index: &blockIndex, pending: &pendingRows)
                nesting.block(startingAt: line)
                // A later nesting group of this run continues the quote row
                // before it (`MarkdownBlock.joinsPrevious`): `> a` then `>> b`
                // is one quote on the page, drawn as two rows.
                var previousGroupWasQuote = false

                while i < lines.count {
                    // The predicate the branch was entered on (`markerLine`),
                    // so the first line is always taken.
                    let qLine = Self.markerLine(lines[i])
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
                    // A definition marker (`definitionLines`) opens the
                    // quote's paragraph for a lazy line and draws nothing:
                    // the group starts at its first line of text.
                    var groupSourceLine: Int?
                    let groupLevel = level
                    var groupLines: [String] = []
                    var tip = QuoteTip()
                    if definitionLines.contains(i) {
                        tip.takeDefinition()
                    } else {
                        groupLines.append(String(scanner))
                        groupSourceLine = lineMap[i]
                        tip.take(groupLines[0])
                    }
                    i += 1

                    while i < lines.count {
                        let nextLine = Self.markerLine(lines[i])
                        guard nextLine.hasPrefix(">") else {
                            // No marker: a lazy continuation of the paragraph
                            // the group ends in (CommonMark), or the quote's end.
                            guard tip.endsInParagraph,
                                  continuesQuoteLazily(lines[i], htmlImageLine: htmlImageLine(lines, at: i) != nil,
                                                       references: referenceDefinitions)
                            else { break }
                            groupLines.append(lines[i])
                            groupSourceLine = groupSourceLine ?? lineMap[i]
                            tip.takeLazy()
                            i += 1
                            continue
                        }

                        var nextLevel = 0
                        var nextScanner = nextLine[...]
                        while nextScanner.hasPrefix(">") {
                            nextLevel += 1
                            nextScanner = nextScanner.dropFirst()
                            if nextScanner.hasPrefix(" ") {
                                nextScanner = nextScanner.dropFirst()
                            }
                        }

                        if nextLevel != groupLevel {
                            // Fewer markers than the group: what follows them may
                            // continue the group's paragraph lazily (`> > a` then
                            // `> b` is one paragraph of the inner quote).
                            let content = String(nextScanner)
                            guard nextLevel < groupLevel, tip.endsInParagraph,
                                  continuesQuoteLazily(content,
                                                       htmlImageLine: HTMLImageSyntax.scan(content[...]) != nil,
                                                       references: referenceDefinitions)
                            else { break }
                            if definitionLines.contains(i) {
                                tip.takeDefinition()
                            } else {
                                groupLines.append(content)
                                groupSourceLine = groupSourceLine ?? lineMap[i]
                                tip.takeLazy()
                            }
                            i += 1
                            continue
                        }
                        if definitionLines.contains(i) {
                            tip.takeDefinition()
                        } else {
                            groupLines.append(String(nextScanner))
                            groupSourceLine = groupSourceLine ?? lineMap[i]
                            tip.take(groupLines[groupLines.count - 1])
                        }
                        i += 1
                    }

                    // One paragraph break per run of blank lines (`collapsingBlankRuns`).
                    groupLines = Self.collapsingBlankRuns(groupLines)
                    // Quote and alert bodies are rendered later without the
                    // definitions, so references are resolved here, once per
                    // body (`ReferenceLinks`, soft-break groups as one line).
                    let content = groupLines.joined(separator: "\n")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    let footnoteIds = footnoteDefinitions.map(\.id)
                    if !content.isEmpty, let groupSourceLine {
                        // GFM alert: level-1 quote whose first line is exactly
                        // `[!NOTE]` / `[!TIP]` / `[!IMPORTANT]` / `[!WARNING]` /
                        // `[!CAUTION]` (marker alone on the line, per GitHub spec)
                        // — and that has a body (GitHub): text after the marker,
                        // or a nested quote right after it, even an empty one.
                        // The marker alone (blank lines, definitions taken out)
                        // is a plain quote "[!NOTE]".
                        let alertKind = groupLevel == 1 ? AlertKind(markerLine: groupLines[0]) : nil
                        let rawBody = groupLines.dropFirst().joined(separator: "\n")
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        let nestedQuoteFollows = i < lines.count && Self.markerLine(lines[i]).hasPrefix(">")
                        if let kind = alertKind, !rawBody.isEmpty || nestedQuoteFollows {
                            let body = ReferenceLinks.inlined(rawBody, definitions: referenceDefinitions,
                                                              footnoteIds: footnoteIds, quoteBody: true)
                            blocks.append(.alert(index: blockIndex, kind: kind, content: body, sourceLine: groupSourceLine))
                            previousGroupWasQuote = false
                        } else {
                            let body = ReferenceLinks.inlined(content, definitions: referenceDefinitions,
                                                              footnoteIds: footnoteIds, quoteBody: true)
                            blocks.append(.blockquote(index: blockIndex, content: body, level: groupLevel,
                                                      sourceLine: groupSourceLine,
                                                      joinsPrevious: previousGroupWasQuote))
                            previousGroupWasQuote = true
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
               let run = trailingTermRun(in: textBuffer, references: referenceDefinitions) {
                // Whatever sat above the terms is a paragraph of its own — the
                // term line is NOT part of it (PHP Markdown Extra reads
                // "para line\n: def" as term + definition).
                var preceding = Array(textBuffer[..<run.bufferStart])
                flushTextBuffer(&preceding, to: &blocks, index: &blockIndex, pending: &pendingRows)
                nesting.block(startingAt: line)
                let termSourceLine = textBuffer[run.bufferStart].originalIndex
                textBuffer.removeAll()

                let list = scanDefinitionList(lines, terms: run.terms,
                                              firstDefinition: firstDefinition, from: i + 1,
                                              references: referenceDefinitions)
                blocks.append(.text(index: blockIndex,
                                    activeRenderer.renderDefinitionList(groups: list.groups),
                                    sourceLine: termSourceLine))
                blockIndex += 1
                i = list.end
                continue
            }

            if Self.isBlank(line) {
                nesting.blank()
            } else if let owner = nesting.text(line, sourceLine: sourceLine) {
                paragraphOwners[sourceLine] = owner
            }
            textBuffer.append((line: line, originalIndex: sourceLine))
            i += 1
        }

        flushTextBuffer(&textBuffer, to: &blocks, index: &blockIndex, pending: &pendingRows)
        renderPendingRows(pendingRows, in: &blocks, allLines: allLines, using: activeRenderer,
                          owners: ListOwners(paragraphs: paragraphOwners, blocks: blockOwners))

        // Append footnotes block at end of document if any definitions exist
        if !footnoteDefinitions.isEmpty {
            var footnoteText = AttributedString("")

            // Horizontal rule separator
            var rule = AttributedString("────────────────────────────────\n")
            rule.setDualFont(size: renderer.scaled(12), fonts: theme.fonts)
            rule.setDualForeground(theme.secondaryTextColor)
            // One clipped line, never wrapped into a second dash line.
            rule[AttributeScopes.AppKitAttributes.ParagraphStyleAttribute.self] = MarkdownRenderer.ruleParagraphStyle
            footnoteText.append(rule)

            for (index, def) in footnoteDefinitions.enumerated() {
                let number = index + 1
                var prefix = AttributedString("\(number). ")
                prefix.setDualFont(size: renderer.scaled(12), bold: true, fonts: theme.fonts)
                prefix.setDualForeground(theme.secondaryTextColor)

                // A multi-line definition: one drawn line per paragraph or
                // hard break (`FootnoteDefinitionBody.displayLines`).
                var content = AttributedString()
                for (lineIndex, line) in FootnoteDefinitionBody.displayLines(of: def.content).enumerated() {
                    if lineIndex > 0 { content.append(AttributedString("\n")) }
                    content.append(activeRenderer.renderInline(line))
                }
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

    // MARK: - Heading Helpers

    /// An ATX heading's optional closing sequence (CommonMark): a run of `#`
    /// at the end of the (trimmed) title, after a space or tab, is not text —
    /// `## Install ##` is "Install", `## ##` is empty, while `# C#` and
    /// `## foo \##` keep theirs. GitHub's heading ids depend on it (#43).
    static func withoutClosingSequence(_ title: String) -> String {
        var start = title.endIndex
        while start > title.startIndex, title[title.index(before: start)] == "#" {
            start = title.index(before: start)
        }
        if start == title.endIndex { return title }
        if start == title.startIndex { return "" }
        let before = title[title.index(before: start)]
        guard before == " " || before == "\t" else { return title }
        return title[..<start].trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Table Helpers

    /// Unescaped and escaped pipes alike (detection counts `\\|` too, as it
    /// always has), as unicode scalars — see `parseTableRow`.
    private static func pipeCount(_ line: String) -> Int {
        line.unicodeScalars.reduce(0) { $1 == "|" ? $0 + 1 : $0 }
    }

    /// Check if line matches table separator pattern (e.g., |---|---|)
    private func isTableSeparator(_ line: String) -> Bool {
        Self.markerLine(line)
            .range(of: MarkdownTheme.tableSeparatorPattern, options: .regularExpression) != nil
    }

    /// Parse a table row into array of cell strings
    /// Handles leading/trailing pipes and filters out empty cells from malformed rows.
    /// An escaped pipe (`\|`) does not split the row: as in GFM it becomes a
    /// literal `|` in the cell, inside code spans too (`` `a\|b` `` shows `a|b`).
    /// Like GitHub (cmark-gfm `unescape_pipes`), a pipe right after a backslash
    /// never splits, even after `\\`: only that one backslash is dropped, so
    /// `\\|` leaves `\|` for the inline renderer (`|` in text, `\|` in code).
    /// Other escapes stay in the text for the inline renderer.
    ///
    /// The scan walks unicode SCALARS, as GFM works on code points: a `|`
    /// followed by a combining mark (U+0301…) is one Swift `Character`, and a
    /// Character scan neither split the cell there nor counted the pipe.
    private func parseTableRow(_ line: String) -> [String] {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)

        var cells: [String] = []
        var cell = String.UnicodeScalarView()
        for scalar in trimmed.unicodeScalars {
            if scalar != "|" {
                cell.append(scalar)
            } else if cell.last == "\\" {
                cell.removeLast()
                cell.append(scalar)
            } else {
                cells.append(String(cell))
                cell = String.UnicodeScalarView()
            }
        }
        cells.append(String(cell))

        // A leading pipe opens the row rather than ending an empty first cell
        if trimmed.unicodeScalars.first == "|" {
            cells.removeFirst()
        }

        // Only filter trailing empty cells (preserve intentional empty cells in middle).
        // This also drops the empty remainder after a trailing pipe.
        var result = cells.map { $0.trimmingCharacters(in: .whitespaces) }
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
        return MarkdownRenderer.isBlankLine(text) ? nil : text
    }

    /// CommonMark's white space around block markers: spaces and tabs, not
    /// every Unicode space separator (`isBlank`).
    static let spacesAndTabs = MarkdownRenderer.markerWhitespace

    /// `line` without the spaces and tabs around it: what EVERY block marker
    /// (fence, `$$`, quote, setext underline, table separator, front-matter
    /// fence, link definition) is looked for in, at the branch that decides
    /// AND in the loop that then walks the block. CommonMark indents with
    /// spaces and tabs only — a no-break, em or ideographic space before a
    /// marker leaves the line paragraph text, as on GitHub. Two predicates
    /// for one decision once hung the parser (a quote marker after U+00A0).
    static func markerLine(_ line: String) -> String {
        line.trimmingCharacters(in: spacesAndTabs)
    }

    /// CommonMark's blank line (`MarkdownRenderer.isBlankLine`): a line of
    /// no-break spaces is text, not a separator.
    private static func isBlank(_ line: String) -> Bool {
        MarkdownRenderer.isBlankLine(line)
    }

    /// No paragraph goes on into the next line from the text buffered so
    /// far: nothing is buffered, or it ends in a blank line or a rule (a
    /// `---` under text never gets here: the setext branch takes it).
    private static func noParagraphOpen(_ buffer: [(line: String, originalIndex: Int)]) -> Bool {
        guard let last = buffer.last else { return true }
        return isBlank(last.line) || MarkdownRenderer.isThematicBreak(last.line)
    }

    /// The paragraph line `index` is in ends with it (CommonMark, GFM): it
    /// is the last line, or the next line is blank or starts a block that
    /// may interrupt a paragraph — a fence or `$$`, an ATX heading, a quote,
    /// a rule, a bullet or an item numbered 1 with text
    /// (`canInterruptParagraph`), an HTML block of kinds 1-6, a table (row
    /// and separator). A setext underline makes the line a heading instead.
    private func paragraphEnds(after index: Int, in lines: [String]) -> Bool {
        guard index + 1 < lines.count else { return true }
        let next = lines[index + 1]
        if Self.isBlank(next) { return true }
        let marker = Self.markerLine(next)
        if marker.range(of: MarkdownTheme.setextH1Pattern, options: .regularExpression) != nil
            || marker.range(of: MarkdownTheme.setextH2Pattern, options: .regularExpression) != nil {
            return false
        }
        if Self.fenceOpening(marker) != nil || Self.startsMathBlock(marker) || marker.hasPrefix(">") { return true }
        if Self.headerRegex.firstMatch(in: next, range: NSRange(next.startIndex..., in: next)) != nil { return true }
        if MarkdownRenderer.isThematicBreak(next) { return true }
        if MarkdownRenderer.isListItem(next) { return MarkdownRenderer.canInterruptParagraph(next) }
        if Self.startsHTMLBlock(marker, interruptingParagraph: true) { return true }
        return Self.pipeCount(next) >= 2 && index + 2 < lines.count && isTableSeparator(lines[index + 2])
    }

    /// What `imageParagraph` found at a line.
    enum ImageParagraph {
        /// The paragraph is these pictures and nothing else; it ends before
        /// line `end`.
        case images([RowImage], end: Int)
        /// It is not: no image paragraph starts before line `checkedUntil`.
        case notImages(checkedUntil: Int)
    }

    /// The paragraph starting at `start` (the caller knows one may start
    /// there) when it is made ONLY of images (`InlineSyntaxScanner
    /// .imageOnlyLine`): every line of it, up to where it ends
    /// (`paragraphEnds`), holds nothing else. GitHub (`gh api markdown`,
    /// 2026-11-11): such a paragraph is one `<p>` of inline pictures; a soft
    /// line break between them is a space, a hard one (two trailing spaces,
    /// a `\` at the end of a line) a `<br>`; a `\` on the paragraph's LAST
    /// line is a literal backslash, i.e. text. A line of text, a setext
    /// underline (the paragraph is a heading then) or any line that goes on
    /// with the paragraph and is not images → `.notImages`.
    ///
    /// An HTML image line (`htmlImageLine`, the whitelist unchanged) counts
    /// as a line of images too, with each `<img>`'s width and same-line
    /// `<a href>`: GitHub draws `<a href><img></a> <a href><img></a>` on one
    /// line, such lines one under the other, and `![a](x)` over an `<img>`
    /// line as one `<p>` of inline pictures. Between two tags of one line:
    /// whitespace or `&nbsp;` = a space, touching = none, `<br>` = a line
    /// break (as GitHub draws them). A wrapper-only line (`<p align=
    /// "center">`, `<br>`) is not images: the paragraph keeps its pre-1.15
    /// shape. A paragraph that STARTS with a line CommonMark reads as an
    /// HTML block (`<img src="a">` alone, `<p …><img></p>`) takes no
    /// Markdown image line after it: GitHub shows that line as literal text
    /// inside the HTML block; QuickMD keeps its pre-1.15 picture blocks.
    func imageParagraph(at start: Int, in lines: [String], references: [String: String]) -> ImageParagraph {
        var images: [RowImage] = []
        var lineBreakBefore = false
        var startsHTMLBlock = false
        var index = start
        while index < lines.count {
            #if DEBUG
            Self.imageParagraphLineScans.add()
            #endif
            if index > start, paragraphEnds(after: index - 1, in: lines) {
                // A `\` hard break needs a line after it IN the paragraph.
                return Self.endsWithBackslashBreak(lines[index - 1])
                    ? .notImages(checkedUntil: index) : .images(images, end: index)
            }
            let line = lines[index]
            let backslash = Self.endsWithBackslashBreak(line)
            guard let found = InlineSyntaxScanner.imageOnlyLine(backslash ? line.dropLast() : line[...],
                                                                references: references) else {
                guard !backslash, let html = htmlImageLine(lines, at: index), !html.images.isEmpty else {
                    return .notImages(checkedUntil: index)
                }
                if index == start { startsHTMLBlock = Self.startsHTMLBlock(Self.markerLine(line)) }
                for (offset, tag) in html.images.enumerated() {
                    let separator: RowImage.Separator
                    if images.isEmpty {
                        separator = .none
                    } else if offset == 0 {
                        separator = lineBreakBefore ? .lineBreak : .space
                    } else {
                        separator = tag.breakBefore ? .lineBreak : (tag.spaceBefore ? .space : .none)
                    }
                    images.append(RowImage(url: tag.url, alt: tag.alt,
                                           link: tag.link.flatMap { MarkdownRenderer.linkURL(for: $0) },
                                           separator: separator, width: tag.width))
                }
                lineBreakBefore = lines[html.end - 1].hasSuffix("  ")
                index = html.end
                continue
            }
            if startsHTMLBlock { return .notImages(checkedUntil: index) }
            for (offset, image) in found.enumerated() {
                let separator: RowImage.Separator
                if images.isEmpty {
                    separator = .none
                } else if offset == 0 {
                    separator = lineBreakBefore ? .lineBreak : .space
                } else {
                    separator = image.spaceBefore ? .space : .none
                }
                images.append(RowImage(url: image.url, alt: HTMLEntities.decode(image.alt),
                                       link: image.link.flatMap { MarkdownRenderer.linkURL(for: $0) },
                                       separator: separator))
            }
            lineBreakBefore = backslash || line.hasSuffix("  ")
            index += 1
        }
        return Self.endsWithBackslashBreak(lines[index - 1])
            ? .notImages(checkedUntil: index) : .images(images, end: index)
    }

    #if DEBUG
    /// Lines `imageParagraph` has looked at, for the test that the parse
    /// scans each line of a failed run once (`imageParagraphSkip`).
    /// Counted PER THREAD: parses run off-main, several at once (in the test
    /// process too — a source-tint parse left queued by another test), and
    /// the test reads the count of its own parse only.
    static let imageParagraphLineScans = ScanCounter()

    final class ScanCounter: Sendable {
        private static let key = "QuickMD.ScanCounter"
        func add() { Thread.current.threadDictionary[Self.key] = count + 1 }
        var count: Int { Thread.current.threadDictionary[Self.key] as? Int ?? 0 }
    }
    #endif

    /// A line ending in ONE backslash (CommonMark's hard line break when a
    /// paragraph line follows; `\\` is an escaped backslash).
    private static func endsWithBackslashBreak(_ line: String) -> Bool {
        line.hasSuffix("\\") && !line.hasSuffix("\\\\")
    }

    /// Can this line be a definition-list TERM? Non-blank, not a definition
    /// line, and not the start of any other block this parser recognises
    /// (heading, list item, table row, fence, quote, image — Markdown or
    /// HTML `<img>`/wrapper line —, `$$`, rule).
    ///
    /// It is also the test for a definition's lazy continuation lines: a
    /// continuation is exactly "a line that could have been a term", which is
    /// why one predicate serves both. `references` are the document's link
    /// definitions: a shortcut-reference image line (`![logo]`) is an image
    /// block, so it must not be a term either.
    private func isTermCandidate(_ line: String, references: [String: String]) -> Bool {
        let trimmed = Self.markerLine(line)
        guard !Self.isBlank(line), Self.definitionText(of: line) == nil else { return false }

        // Fences, quotes, display math
        if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") { return false }
        if trimmed.hasPrefix(">") || Self.startsMathBlock(trimmed) { return false }

        // List items — bullets (task items included, they start `- [ ]`) and ordered
        if ["- ", "* ", "+ "].contains(where: { trimmed.hasPrefix($0) }) { return false }
        if trimmed.range(of: #"^(\d+)\.[ \t]"#, options: .regularExpression) != nil { return false }

        // Table rows (the table branch needs a separator to fire, but a pipe row
        // is still a table row, not a term) and separators
        if Self.pipeCount(line) >= 2 { return false }
        if isTableSeparator(trimmed) { return false }

        // Rules and setext underlines
        if trimmed.range(of: MarkdownTheme.horizontalRulePattern, options: .regularExpression) != nil { return false }
        if trimmed.range(of: MarkdownTheme.setextH1Pattern, options: .regularExpression) != nil { return false }

        // ATX headings and standalone image lines — the SAME predicate the
        // block loop uses, so a line is never both an image and a term.
        let nsRange = NSRange(line.startIndex..., in: line)
        if Self.headerRegex.firstMatch(in: line, range: nsRange) != nil { return false }
        if InlineSyntaxScanner.standaloneImages(in: line[...], references: references) != nil { return false }
        // Single-line HTML image / wrapper lines (the multi-line `<img` form
        // needs the following lines — `isTermCandidate(in:at:)`).
        if case .tags? = HTMLImageSyntax.scan(line[...]) { return false }

        return true
    }

    /// `isTermCandidate` for a line in context: also false when the line
    /// opens a multi-line `<img` tag the block loop would assemble into an
    /// image — the same `htmlImageLine` test, so the forward scans of a
    /// definition list never swallow a tag the block loop shows as a picture.
    /// (Buffered lines need no context: a line only lands in the text buffer
    /// after `htmlImageLine` already said no.)
    private func isTermCandidate(in lines: [String], at index: Int, references: [String: String]) -> Bool {
        isTermCandidate(lines[index], references: references) && htmlImageLine(lines, at: index) == nil
    }

    // MARK: - HTML image lines (T-C)

    /// A single-line wrapper-only HTML line (`<p align="center">`, `</p>`,
    /// `<br>`, …) — the lines the block loop skips without a block. Nil when
    /// the line is anything else; otherwise whether it is `<br>`-only.
    private static func wrapperOnlyLine(_ line: String) -> Bool? {
        guard case .tags(let images, let lineBreakOnly)? = HTMLImageSyntax.scan(line[...]),
              images.isEmpty else { return nil }
        return lineBreakOnly
    }

    /// How many lines AFTER an unterminated `<img` line may complete the tag.
    private static let htmlImageContinuationLimit = 10

    /// The HTML image line starting at `index` (see `HTMLImageSyntax`): its
    /// `<img>` tags (EMPTY for a wrapper-only line) and the index of the first
    /// line after it. When the line ends inside an `<img` tag, following lines
    /// are joined until the tag closes — at most `htmlImageContinuationLimit`
    /// of them, and never across a blank line; if it does not close, nil, and
    /// every one of those lines is ordinary text again.
    private func htmlImageLine(_ lines: [String], at index: Int)
        -> (images: [HTMLImageSyntax.Tag], lineBreakOnly: Bool, end: Int)? {
        switch HTMLImageSyntax.scan(lines[index][...]) {
        case nil:
            return nil
        case .tags(let images, let lineBreakOnly)?:
            return (images, lineBreakOnly, index + 1)
        case .unterminatedImage?:
            var joined = lines[index]
            var end = index + 1
            let limit = min(lines.count, end + Self.htmlImageContinuationLimit)
            while end < limit {
                let next = lines[end]
                if Self.isBlank(next) { return nil }
                joined += "\n" + next
                end += 1
                // No `>` on this line → the tag cannot have closed; skip the
                // re-scan (keeps a long unterminated tag from being scanned
                // once per line).
                guard next.utf8.contains(UInt8(ascii: ">")) else { continue }
                switch HTMLImageSyntax.scan(joined[...]) {
                case .tags(let images, _)?: return (images, false, end)
                case .unterminatedImage?: continue   // the `>` was inside a quoted value
                case nil: return nil
                }
            }
            return nil
        }
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
    private func trailingTermRun(in buffer: [(line: String, originalIndex: Int)],
                                 references: [String: String]) -> (terms: [String], bufferStart: Int)? {
        var end = buffer.count
        // At most ONE blank line may sit between the terms and the definition;
        // two means the term is too far away to be one.
        if end > 0, Self.isBlank(buffer[end - 1].line) { end -= 1 }

        var start = end
        while start > 0, isTermCandidate(buffer[start - 1].line, references: references) { start -= 1 }
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

    private func scanTermHead(_ lines: [String], from start: Int,
                              references: [String: String]) -> DefinitionHead? {
        var terms: [String] = []
        var index = start
        // Wrapper-only lines are skipped as the block loop skips them (it
        // never buffers them, so `trailingTermRun` never sees one either).
        while index < lines.count {
            if Self.wrapperOnlyLine(lines[index]) != nil { index += 1; continue }
            guard isTermCandidate(in: lines, at: index, references: references) else { break }
            terms.append(lines[index].trimmingCharacters(in: .whitespaces))
            index += 1
        }
        guard !terms.isEmpty, index < lines.count else { return nil }
        if Self.isBlank(lines[index]) { index += 1 }   // one blank line is allowed
        while index < lines.count, Self.wrapperOnlyLine(lines[index]) != nil { index += 1 }
        guard index < lines.count, let text = Self.definitionText(of: lines[index]) else { return nil }
        return DefinitionHead(terms: terms, firstDefinition: text, next: index + 1)
    }

    /// Walks a definition list whose first group's terms and first definition are
    /// already known, from `start` — the line AFTER that `: definition` line.
    /// Returns the groups and the first line index that is NOT part of the list.
    private func scanDefinitionList(_ lines: [String], terms firstTerms: [String],
                                    firstDefinition: String, from start: Int,
                                    references: [String: String])
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
                if let head = scanTermHead(lines, from: index + 1, references: references) {
                    closeGroup()
                    terms = head.terms
                    current = [head.firstDefinition]
                    index = head.next
                    continue
                }
                break
            }

            // A wrapper-only line is skipped, exactly as in the block loop: a
            // `<br>`-only one is a hard break of the definition so far.
            if let isLineBreak = Self.wrapperOnlyLine(line) {
                if isLineBreak, let last = current.indices.last { current[last] += "  " }
                index += 1
                continue
            }

            // Lazy continuation — but a new block start (fence, heading, table,
            // quote, list, image, math) ends the list instead.
            guard isTermCandidate(in: lines, at: index, references: references) else { break }
            current.append(line)
            index += 1
        }

        closeGroup()
        return (groups, index)
    }

    // MARK: - Text Buffer

    /// Cap on joined lines per text row. Large bullet/link lists (e.g. 11K-line
    /// bookmark dumps) would otherwise become one ~10000-character row per
    /// heading section — slow to lay out on window resize. A longer block is
    /// cut into rows of this many lines; every row after the first is marked
    /// `joinsPrevious`, so the cut adds no space and copies as a plain line break.
    static let textChunkLineLimit = 30

    /// Turns a run of text lines (everything between two non-text blocks) into
    /// rows — ONE ROW PER BLOCK, as CommonMark reads the run:
    /// - a blank line ends a block (a paragraph, an item of a loose list);
    /// - a list item right after paragraph text starts a block (the list);
    /// - a thematic break is a block of its own.
    ///
    /// Blank lines themselves never reach a row: the space between two blocks
    /// is `BlockLayout.Spacing`'s, the same whether the source has a blank line
    /// there or not.
    ///
    /// Soft breaks are joined over the WHOLE run before it is cut. The rows are
    /// rendered at the end of the parse (`renderPendingRows`), so a list split
    /// into several rows (a loose list, one past the line cap, one whose items
    /// hold a code block or a picture) keeps one text edge.
    private func flushTextBuffer(_ buffer: inout [(line: String, originalIndex: Int)], to blocks: inout [MarkdownBlock], index: inout Int, pending: inout [PendingTextRow]) {
        guard !buffer.isEmpty else { return }
        defer { buffer = [] }

        let joined = MarkdownRenderer.joinSoftBreaksIndexed(buffer.map(\.line))

        var row: [String] = []
        // The original line each of the row's lines starts on (`ListOwners`).
        var rowSources: [Int] = []
        var rowSourceLine = 0
        var rowJoinsPrevious = false
        // The current block is a list: an item started it or continues it.
        var inList = false

        func flushRow() {
            guard !row.isEmpty else { return }
            pending.append(PendingTextRow(position: blocks.count, index: index, lines: row, sources: rowSources,
                                          sourceLine: rowSourceLine, joinsPrevious: rowJoinsPrevious))
            // Its place in the block list; `renderPendingRows` fills it in.
            blocks.append(.text(index: index, AttributedString(), sourceLine: rowSourceLine,
                                joinsPrevious: rowJoinsPrevious))
            index += 1
            row = []
            rowSources = []
            rowJoinsPrevious = false
        }
        func append(_ position: Int) {
            if row.isEmpty { rowSourceLine = buffer[joined[position].first].originalIndex }
            row.append(joined[position].line)
            rowSources.append(buffer[joined[position].first].originalIndex)
        }

        for position in joined.indices {
            let line = joined[position].line
            if Self.isBlank(line) {
                flushRow()
                inList = false
                continue
            }
            if MarkdownRenderer.isThematicBreak(line) {
                flushRow()
                append(position)
                flushRow()
                inList = false
                continue
            }
            // A list starts at an item that opens the row, or that may
            // interrupt the paragraph before it (CommonMark: a bullet, or an
            // ordered item numbered 1). `joinSoftBreaks` has already made any
            // other item line after paragraph text part of that text.
            let startsList = !inList && MarkdownRenderer.isListItem(line)
                && (row.isEmpty || MarkdownRenderer.canInterruptParagraph(line))
            if startsList { flushRow() }
            if row.count >= Self.textChunkLineLimit {
                flushRow()
                rowJoinsPrevious = true
            }
            append(position)
            if startsList { inList = true }
        }
        flushRow()
    }

    // MARK: - Setext headings

    /// A Setext heading's title: its lines, trimmed, joined with the line
    /// breaks between them — GitHub's heading text keeps them, and its id
    /// drops them (`Alpha⏎Beta` is `alphabeta`, where a space would be a
    /// `-`); `MarkdownRenderer.shownHeadingTitle` shows each as a space. A
    /// hard break's backslash is not text (an odd run of them ends the
    /// line; trailing spaces are trimmed anyway).
    static func setextTitle(_ lines: [String]) -> String {
        let trimmed = lines.map(markerLine)
        return trimmed.enumerated().map { index, text in
            guard index < trimmed.count - 1 else { return text }
            let backslashes = text.reversed().prefix(while: { $0 == "\\" }).count
            return backslashes % 2 == 1 ? String(text.dropLast()) : text
        }.joined(separator: "\n")
    }

    /// Where the paragraph that `line` (the line over a Setext underline)
    /// ends starts in the text buffer: after its last blank line or rule.
    /// Nil when that paragraph is a list item's — an item line starts it or
    /// interrupts it, by the rule rows are cut by (`flushTextBuffer`).
    static func setextParagraphStart(in buffer: [(line: String, originalIndex: Int)],
                                     endingWith line: String) -> Int? {
        var start = buffer.count
        while start > 0, !isBlank(buffer[start - 1].line), !MarkdownRenderer.isThematicBreak(buffer[start - 1].line) {
            start -= 1
        }
        let paragraph = buffer[start...].map(\.line) + [line]
        for (offset, text) in paragraph.enumerated() where MarkdownRenderer.isListItem(text) {
            if offset == 0 || MarkdownRenderer.canInterruptParagraph(text) { return nil }
        }
        return start
    }

    // MARK: - Fences and `$$` blocks

    /// A quote's or alert's lines with each run of blank lines made ONE: a
    /// blank line only separates paragraphs, and any run of them is one
    /// paragraph break (GitHub, every nesting level; a definition the
    /// pre-pass took out between two blank lines leaves none of its own).
    /// Inside the quote's fence a blank line is code and stays.
    static func collapsingBlankRuns(_ lines: [String]) -> [String] {
        var result: [String] = []
        result.reserveCapacity(lines.count)
        var fence: Fence?
        for line in lines {
            let marker = markerLine(line)
            if let open = fence {
                if closesFence(marker, open) { fence = nil }
            } else if let opening = fenceOpening(marker) {
                fence = opening
            } else if isBlank(line), let last = result.last, isBlank(last) {
                continue
            }
            result.append(line)
        }
        return result
    }

    /// Columns of the spaces and tabs a line starts with (a tab runs to the
    /// next multiple of 4, CommonMark).
    static func indentColumns(_ line: String) -> Int {
        var columns = 0
        for character in line {
            if character == " " {
                columns += 1
            } else if character == "\t" {
                columns += 4 - columns % 4
            } else {
                break
            }
        }
        return columns
    }

    /// `line` without up to `columns` columns of its leading spaces and tabs.
    /// A tab that reaches past them leaves the columns it has left as spaces
    /// (CommonMark: `\tTab` under a fence indented 2 is `  Tab`).
    static func removingIndentation(_ line: String, upTo columns: Int) -> String {
        guard columns > 0 else { return line }
        var used = 0
        var index = line.startIndex
        while index < line.endIndex, used < columns {
            let character = line[index]
            let width: Int
            if character == " " {
                width = 1
            } else if character == "\t" {
                width = 4 - used % 4
            } else {
                break
            }
            index = line.index(after: index)
            if used + width > columns {
                return String(repeating: " ", count: used + width - columns) + line[index...]
            }
            used += width
        }
        return String(line[index...])
    }

    /// A code fence's marker character and length.
    typealias Fence = (marker: Character, length: Int)

    /// The fence `marker` (a `markerLine`) opens: three or more backticks or
    /// tildes. THE opening test — the block loop, quote groups and the
    /// definition pre-pass all ask it.
    static func fenceOpening(_ marker: String) -> Fence? {
        guard let first = marker.first, first == "`" || first == "~" else { return nil }
        let length = marker.prefix(while: { $0 == first }).count
        return length >= 3 ? (first, length) : nil
    }

    /// Whether `marker` closes `fence`: the same character, at least as many,
    /// and nothing after them but spaces and tabs.
    static func closesFence(_ marker: String, _ fence: Fence) -> Bool {
        marker.hasPrefix(String(repeating: fence.marker, count: fence.length))
            && MarkdownRenderer.isBlankLine(marker.drop(while: { $0 == fence.marker }))
    }

    /// What a line whose marker starts with `$$` is (v1.15; GitHub's output in
    /// `MathInTextKindsTests`).
    enum MathOpening: Equatable {
        /// `$$x$$` alone on the line: a display formula (empty: nothing).
        case singleLine(latex: String)
        /// `$$`, LaTeX lines, then the line `closingLine` (an index in the
        /// same array) that ends with the closing `$$`; `closingText` is
        /// what precedes the `$$` on it (`v$$` closes with "v").
        case block(closingLine: Int, closingText: String)
        /// Paragraph text: `$$x$$ text after` (an inline formula, GitHub),
        /// an opening `$$` whose next `$$` has text after it, or one never
        /// closed. Until v1.15 the first two opened a block that swallowed
        /// everything up to the next lone `$$` line — often the rest of the
        /// document — and an unclosed one swallowed the rest.
        case text
    }

    /// `marker` (starting with `$$`) read with the first later line that holds
    /// a `$$` (`nextMathLine`, its index; `nextMathMarker`, its marker).
    static func mathOpening(_ marker: String, nextMathLine: Int?, nextMathMarker: String?) -> MathOpening {
        let rest = marker.dropFirst(2)
        if let close = rest.range(of: "$$") {
            guard rest[close.upperBound...].trimmingCharacters(in: .whitespaces).isEmpty else { return .text }
            return .singleLine(latex: rest[..<close.lowerBound].trimmingCharacters(in: .whitespaces))
        }
        guard let nextMathLine, let closing = nextMathMarker?.trimmingCharacters(in: .whitespaces),
              let close = closing.range(of: "$$"),
              closing[close.upperBound...].trimmingCharacters(in: .whitespaces).isEmpty else { return .text }
        return .block(closingLine: nextMathLine,
                      closingText: closing[..<close.lowerBound].trimmingCharacters(in: .whitespaces))
    }

    /// For each line, the index of the next LATER line holding `$$` — one
    /// backward pass, so finding a `$$` block's end costs nothing per line.
    static func nextMathLines(_ lines: [String]) -> [Int?] {
        var result = [Int?](repeating: nil, count: lines.count)
        var next: Int?
        for index in stride(from: lines.count - 1, through: 0, by: -1) {
            result[index] = next
            if lines[index].contains("$$") { next = index }
        }
        return result
    }

    /// A `$$` line that is paragraph text whatever follows (`$$x$$ text`):
    /// the context-free block-start tests (`paragraphEnds`, laziness, terms)
    /// use it; an unclosed `$$` is only known with the whole document.
    static func startsMathBlock(_ marker: String) -> Bool {
        guard marker.hasPrefix("$$") else { return false }
        if case .text = mathOpening(marker, nextMathLine: 0, nextMathMarker: "$$") { return false }
        return true
    }

    /// The fenced code and `$$` blocks of a document, followed line by line
    /// the way the block loop reads them (fence first, then `$$`; inside one,
    /// only its closing line matters). The definition pre-pass leaves their
    /// lines alone: a definition inside one is that block's text.
    struct VerbatimRegions {
        private var fence: Fence?
        /// Index of the line that closes the open `$$` block.
        private var mathCloses: Int?

        /// Inside such a block: the next line is its text or its closing line.
        var isOpen: Bool { fence != nil || mathCloses != nil }

        /// Whether the line `index` (its `markerLine`) opens, continues or
        /// closes such a block. `nextMath` is `nextMathLines` of the lines and
        /// `markerAt` their markers: a `$$` line is read as the block loop
        /// reads it (`mathOpening`).
        mutating func contains(_ marker: String, at index: Int, nextMath: [Int?],
                               markerAt: (Int) -> String) -> Bool {
            if let open = fence {
                if MarkdownBlockParser.closesFence(marker, open) { fence = nil }
                return true
            }
            if let closes = mathCloses {
                if index >= closes { mathCloses = nil }
                return true
            }
            if let opening = MarkdownBlockParser.fenceOpening(marker) {
                fence = opening
                return true
            }
            if marker.hasPrefix("$$") {
                let next = index < nextMath.count ? nextMath[index] : nil
                switch MarkdownBlockParser.mathOpening(marker, nextMathLine: next, nextMathMarker: next.map(markerAt)) {
                case .singleLine: return true
                case .block(let closingLine, _):
                    mathCloses = closingLine
                    return true
                case .text: return false
                }
            }
            return false
        }
    }

    // MARK: - Quote laziness

    /// What a quote group's lines end in, as CommonMark reads them: an OPEN
    /// paragraph (a paragraph's or a list item's text) is the one block a
    /// lazy line may continue. A blank or empty quote line closes it, as do a
    /// fenced code block (open or just closed), an ATX heading, a Setext
    /// underline, a rule and a table.
    struct QuoteTip {
        private(set) var endsInParagraph = false
        private var fence: Fence?
        private var inTable = false
        private var previousHadPipe = false
        /// The open paragraph holds link definitions only, so far: another
        /// may follow, and it draws nothing (`takeDefinition`).
        private(set) var onlyDefinitions = false

        /// Whether a link definition may stand on the group's next line: it
        /// would start a paragraph, or go on with one of definitions only —
        /// not in the quote's fence or table (`DefinitionPlacement`).
        var admitsDefinition: Bool { fence == nil && !inTable && (!endsInParagraph || onlyDefinitions) }

        /// A link definition the pre-pass took out: it opens (or goes on
        /// with) a paragraph of definitions only, which a lazy line continues
        /// in this quote (CommonMark, GitHub).
        mutating func takeDefinition() {
            endsInParagraph = true
            onlyDefinitions = true
            previousHadPipe = false
            inTable = false
        }

        /// Inside the quote's fence.
        var inFence: Bool { fence != nil }

        /// A lazily continued line (no marker, or fewer markers than the
        /// group): paragraph text whatever it looks like — CommonMark never
        /// reads a lazy line as a table separator, a Setext underline or any
        /// other structure, so the paragraph stays open for the next one.
        mutating func takeLazy() {
            endsInParagraph = true
            onlyDefinitions = false
            previousHadPipe = false
        }

        /// A line of the group itself (marked at the group's level).
        mutating func take(_ content: String) {
            let marker = MarkdownBlockParser.markerLine(content)
            // Under definitions only, `===` is text (CommonMark).
            let afterDefinitions = onlyDefinitions
            onlyDefinitions = false
            if let open = fence {
                // Inside the quote's fence: only its closing line matters.
                if MarkdownBlockParser.closesFence(marker, open) { fence = nil }
                endsInParagraph = false
                return
            }
            defer { previousHadPipe = content.contains("|") }
            if MarkdownRenderer.isBlankLine(content) {
                endsInParagraph = false
                inTable = false
                return
            }
            if let opening = MarkdownBlockParser.fenceOpening(marker) {
                fence = opening
                endsInParagraph = false
                inTable = false
                return
            }
            // A row; a block start ends the table (`interruptsTable`).
            if inTable, content.contains("|"), !MarkdownBlockParser.interruptsTable(content) {
                endsInParagraph = false
                return
            }
            inTable = false
            if endsInParagraph, previousHadPipe,
               marker.range(of: MarkdownTheme.tableSeparatorPattern, options: .regularExpression) != nil {
                inTable = true
                endsInParagraph = false
                return
            }
            let nsRange = NSRange(content.startIndex..., in: content)
            if MarkdownBlockParser.headerRegex.firstMatch(in: content, range: nsRange) != nil
                || MarkdownRenderer.isThematicBreak(content) {
                endsInParagraph = false
                return
            }
            if endsInParagraph, !afterDefinitions,
               marker.range(of: MarkdownTheme.setextH1Pattern, options: .regularExpression) != nil
                || marker.range(of: MarkdownTheme.setextH2Pattern, options: .regularExpression) != nil {
                endsInParagraph = false
                return
            }
            endsInParagraph = true
        }
    }

    /// Whether `line` — a line without a quote marker, or what follows fewer
    /// markers than the quote has — continues the paragraph a quote ends in
    /// (CommonMark laziness): it is not blank and starts no block. Checked as
    /// cmark does, against the DOCUMENT, not the paragraph: any list item ends
    /// the quote (`2. b` too), and so does a lone HTML tag; `===`, an indented
    /// line, a pipe row or `<span>` text continue it (GitHub, gh api markdown).
    /// Our own block starts end it as well: a picture line (Markdown or HTML)
    /// and `$$` stay the picture and the formula they are everywhere else.
    private func continuesQuoteLazily(_ line: String, htmlImageLine: Bool,
                                      references: [String: String]) -> Bool {
        guard !htmlImageLine, Self.startsNoBlock(line) else { return false }
        if InlineSyntaxScanner.standaloneImages(in: line[...], references: references) != nil { return false }
        return true
    }

    /// Whether a block starts on `line`, which ends a table's body: GitHub
    /// closes a table for any block start — a fence, a quote, an ATX
    /// heading, a list item, an HTML block (gfm/h2_*.html) — and `$$` opens
    /// a formula here. A fence or `$$` line taken as a row disagreed with the
    /// definition pre-pass (`VerbatimRegions`), which reads it as a block.
    static func interruptsTable(_ line: String) -> Bool {
        !startsNoBlock(line) || markerLine(line).hasPrefix(">")
    }

    /// Whether `line`, right under paragraph text, would go on with that
    /// paragraph in the block loop: a Setext underline, a list item that
    /// may not interrupt a paragraph (`1984. y`), or plain text. Where a
    /// footnote definition stood between the two, GitHub starts afresh
    /// (the definition ended the paragraph), so the pre-pass leaves a blank
    /// line there.
    static func wouldContinueParagraph(_ line: String) -> Bool {
        let marker = markerLine(line)
        if marker.range(of: MarkdownTheme.setextH1Pattern, options: .regularExpression) != nil
            || marker.range(of: MarkdownTheme.setextH2Pattern, options: .regularExpression) != nil {
            return true
        }
        if MarkdownRenderer.isListItem(line) { return !MarkdownRenderer.canInterruptParagraph(line) }
        return startsNoBlock(line) && !marker.hasPrefix(">")
    }

    /// CommonMark's part of `continuesQuoteLazily`: not blank, and no block
    /// starts on the line (fence, `$$`, ATX heading, rule, list item, HTML
    /// block) — checked against the document, as cmark does.
    static func startsNoBlock(_ line: String) -> Bool {
        guard !isBlank(line) else { return false }
        let marker = markerLine(line)
        if fenceOpening(marker) != nil || startsMathBlock(marker) { return false }
        let nsRange = NSRange(line.startIndex..., in: line)
        if headerRegex.firstMatch(in: line, range: nsRange) != nil { return false }
        if MarkdownRenderer.isThematicBreak(line) || MarkdownRenderer.isListItem(line) { return false }
        if ["-", "*", "+"].contains(marker) { return false }   // an empty item
        if startsHTMLBlock(marker) { return false }
        // A footnote definition starts a block (GFM): `> > a` then
        // `> [^m]: note` is the outer quote's footnote, not lazy text.
        if footnoteDefRegex.firstMatch(in: marker, range: NSRange(marker.startIndex..., in: marker)) != nil {
            return false
        }
        return true
    }

    /// Whether the definition pre-pass may take a LINK definition out on the
    /// next line: not where it would continue a paragraph. CommonMark: a
    /// link definition cannot interrupt a paragraph; GitHub keeps such a
    /// line as the paragraph's text — a list item's, a table's (its rows run
    /// on) and a quote's lazy line included. (A footnote definition may
    /// interrupt one, GitHub: the pre-pass takes those wherever they stand
    /// outside fenced code.)
    struct DefinitionPlacement {
        private(set) var paragraphOpen = false
        /// The quote group being read, grouped as the block loop groups it:
        /// what its lines end in (`QuoteTip`) and its `>` count. A line with
        /// more markers opens a nested quote, a new group; one with fewer
        /// goes on lazily or starts a new group.
        private var quote: QuoteTip?
        private var quoteLevel = 0

        /// A line of a fenced code or `$$` block (`VerbatimRegions`).
        mutating func verbatim() {
            paragraphOpen = false
            quote = nil
        }

        /// A definition the pre-pass took out: it ends what came before.
        mutating func definition() {
            paragraphOpen = false
            quote = nil
        }

        /// What a LINK definition on the next line (its `markerLine`) would
        /// be read from, or nil where none may stand: the line itself where
        /// no paragraph is open; what follows a quote line's markers where
        /// the line starts a paragraph of its quote (GitHub: `> [x]: url`
        /// defines `x` and leaves the quote empty) — a new quote, a deeper
        /// one opened under the quote's text (`> a`, then `>> [x]: url`), or
        /// a line of the group after no open paragraph. Not lazy text, nor
        /// in the quote's fence or table.
        func linkDefinitionText(_ marker: String) -> String? {
            guard marker.hasPrefix(">") else {
                // A lazy line of a quote paragraph of definitions only: another.
                if let tip = quote, tip.endsInParagraph {
                    return tip.onlyDefinitions && MarkdownBlockParser.startsNoBlock(marker) ? marker : nil
                }
                return paragraphOpen ? nil : marker
            }
            let (level, content) = Self.quoteMarkers(of: marker)
            let text = MarkdownBlockParser.markerLine(String(content))
            switch step(level: level, content: String(content)) {
            case .same:
                return quote?.admitsDefinition == true ? text : nil
            case .lazy:
                return quote?.onlyDefinitions == true ? text : nil
            case .newGroup:
                // A deeper `>` inside the quote's fence is that fence's code.
                if level > quoteLevel, quote?.inFence == true { return nil }
                return text
            }
        }

        /// What a FOOTNOTE definition on a quote line (its `markerLine`)
        /// would be read from: what follows its markers. A footnote
        /// definition may interrupt a paragraph (GitHub), so anywhere in the
        /// quote but in its fence. Nil for any other line: the pre-pass
        /// reads a line without markers whole.
        func footnoteDefinitionText(_ marker: String) -> String? {
            guard marker.hasPrefix(">") else { return nil }
            let (level, content) = Self.quoteMarkers(of: marker)
            if let tip = quote, tip.inFence, level >= quoteLevel { return nil }
            return MarkdownBlockParser.markerLine(String(content))
        }

        /// A link or footnote definition taken out of `marker` (a
        /// `markerLine`). Out of a quote line, it opens a paragraph of that
        /// quote — of definitions only, which draws nothing and which a lazy
        /// line continues in the quote (GitHub) — and the line stays for the
        /// block loop as a marker: true. A lazy link definition after such a
        /// paragraph goes on with it; any other definition ends what came
        /// before.
        mutating func definitionTaken(_ marker: String) -> Bool {
            if marker.hasPrefix(">") {
                let (level, content) = Self.quoteMarkers(of: marker)
                var tip = quote ?? QuoteTip()
                if step(level: level, content: String(content)) == .newGroup {
                    tip = QuoteTip()
                    quoteLevel = level
                }
                tip.takeDefinition()
                quote = tip
                paragraphOpen = true
                return true
            }
            if let tip = quote, tip.endsInParagraph, tip.onlyDefinitions { return false }
            definition()
            return false
        }

        /// How a quote line goes on from the group being read — the block
        /// loop's grouping (lazy: fewer markers, continuing its paragraph).
        private enum QuoteStep { case same, lazy, newGroup }

        private func step(level: Int, content: String) -> QuoteStep {
            guard let tip = quote else { return .newGroup }
            if level == quoteLevel { return .same }
            if level < quoteLevel, tip.endsInParagraph, MarkdownBlockParser.startsNoBlock(content) {
                return .lazy
            }
            return .newGroup
        }

        /// A quote line's `>` count and what follows its markers (each `>`
        /// with one optional space after it).
        static func quoteMarkers(of marker: String) -> (level: Int, content: Substring) {
            var content = marker[...]
            var level = 0
            while content.hasPrefix(">") {
                content = content.dropFirst()
                level += 1
                if content.hasPrefix(" ") { content = content.dropFirst() }
            }
            return (level, content)
        }

        /// Any other line, kept for the block loop.
        mutating func kept(_ line: String) {
            if MarkdownRenderer.isBlankLine(line) {
                paragraphOpen = false
                quote = nil
                return
            }
            let marker = MarkdownBlockParser.markerLine(line)
            if marker.hasPrefix(">") {
                let (level, content) = Self.quoteMarkers(of: marker)
                var tip = quote ?? QuoteTip()
                switch step(level: level, content: String(content)) {
                case .same:
                    tip.take(String(content))
                case .lazy:
                    tip.takeLazy()
                case .newGroup:
                    tip = QuoteTip()
                    tip.take(String(content))
                    quoteLevel = level
                }
                quote = tip
                paragraphOpen = tip.endsInParagraph
                return
            }
            if var tip = quote, tip.endsInParagraph, MarkdownBlockParser.startsNoBlock(line) {
                tip.takeLazy()
                quote = tip
                paragraphOpen = true
                return
            }
            quote = nil
            let nsRange = NSRange(line.startIndex..., in: line)
            if MarkdownBlockParser.headerRegex.firstMatch(in: line, range: nsRange) != nil
                || MarkdownRenderer.isThematicBreak(line)
                || (paragraphOpen && marker.range(of: MarkdownTheme.setextH1Pattern,
                                                   options: .regularExpression) != nil) {
                paragraphOpen = false
                return
            }
            paragraphOpen = true
        }
    }

    /// CommonMark's HTML block starts (kinds 1-7), as far as a lazy line needs
    /// them: `<!…`/`<?…`, a block-level or raw tag (`<div`, `</p>`, `<pre`),
    /// or a line that is one complete tag. `<span>text` is inline HTML.
    static func startsHTMLBlock(_ marker: String, interruptingParagraph: Bool = false) -> Bool {
        guard marker.hasPrefix("<") else { return false }
        if marker.hasPrefix("<!") || marker.hasPrefix("<?") { return true }
        let afterBracket = marker.dropFirst().drop(while: { $0 == "/" })
        let name = afterBracket.prefix(while: { $0.isLetter || $0.isNumber || $0 == "-" }).lowercased()
        guard !name.isEmpty, name.first!.isLetter else { return false }
        let rest = afterBracket.dropFirst(name.count)
        let ends = rest.isEmpty || rest.first == " " || rest.first == "\t" || rest.first == ">" || rest.hasPrefix("/>")
        if ends, htmlBlockTags.contains(name) { return true }
        // Kind 7 (a line that is one complete tag) cannot interrupt a paragraph.
        if interruptingParagraph { return false }
        return marker.range(of: #"^</?[A-Za-z][A-Za-z0-9-]*(\s[^<>]*)?/?>[ \t]*$"#,
                            options: .regularExpression) != nil
    }

    /// CommonMark HTML block kinds 1 and 6.
    private static let htmlBlockTags: Set<String> = [
        "pre", "script", "style", "textarea",
        "address", "article", "aside", "base", "basefont", "blockquote", "body", "caption", "center",
        "col", "colgroup", "dd", "details", "dialog", "dir", "div", "dl", "dt", "fieldset", "figcaption",
        "figure", "footer", "form", "frame", "frameset", "h1", "h2", "h3", "h4", "h5", "h6", "head",
        "header", "hr", "html", "iframe", "legend", "li", "link", "main", "menu", "menuitem", "nav",
        "noframes", "ol", "optgroup", "option", "p", "param", "search", "section", "summary", "table",
        "tbody", "td", "tfoot", "th", "thead", "title", "tr", "track", "ul",
    ]

    /// A text row waiting for `renderPendingRows`: its soft-break joined lines
    /// and where its block sits in the block list.
    struct PendingTextRow {
        let position: Int
        let index: Int
        let lines: [String]
        /// The original line each of `lines` starts on.
        let sources: [Int]
        let sourceLine: Int
        let joinsPrevious: Bool
    }

    /// What `ListNesting` found, by original line: the item line that owns a
    /// paragraph starting on a line, and the item line that owns the code
    /// block at a position in the block list.
    struct ListOwners {
        let paragraphs: [Int: Int]
        let blocks: [Int: Int]
    }

    /// Stands in for a non-text block when the ordered-list hangs are worked
    /// out: not blank, not a list item — so it continues a list exactly when
    /// its first line is indented under the list's items (a step's code
    /// block, a picture under an item), as a nested paragraph would.
    private static let blockStandIn = "\u{FFFC}"

    /// Renders the text rows, every ordered item hanging under the widest
    /// marker of ITS list (`MarkdownRenderer.widestOrderedPrefixes`), worked
    /// out over the whole document: the rows' lines in order, each other
    /// block standing in as one line with its indentation. Until 1.14.4 the
    /// widest marker was each row's own, so a list cut into rows had two text
    /// edges, and the steps of a list whose items hold code blocks each hung
    /// under their own number ("1. " is narrower than "10. ").
    ///
    /// The same pass lines a list item's own blocks up with the item's text
    /// (`owners`, from `ListNesting`): a paragraph of the item hangs where the
    /// item's text starts, a code block is indented to it — both known only
    /// now, once the item's hang (its list's widest marker) is.
    private func renderPendingRows(_ pending: [PendingTextRow], in blocks: inout [MarkdownBlock],
                                   allLines: [String], using renderer: MarkdownRenderer,
                                   owners: ListOwners) {
        guard !pending.isEmpty else { return }
        var lines: [String] = []
        var starts: [Int] = []
        starts.reserveCapacity(pending.count)
        // Where an item line (by original line) landed in `lines`.
        var itemLines: [Int: Int] = [:]
        var next = 0
        for (position, block) in blocks.enumerated() {
            if next < pending.count, pending[next].position == position {
                starts.append(lines.count)
                if !owners.paragraphs.isEmpty || !owners.blocks.isEmpty {
                    for (offset, source) in pending[next].sources.enumerated() {
                        itemLines[source] = lines.count + offset
                    }
                }
                lines.append(contentsOf: pending[next].lines)
                next += 1
            } else {
                let first = block.sourceLine >= 0 && block.sourceLine < allLines.count ? allLines[block.sourceLine] : ""
                lines.append(String(first.prefix(while: { $0 == " " || $0 == "\t" })) + Self.blockStandIn)
            }
        }
        let hangs = renderer.widestOrderedPrefixes(lines)
        /// The text column of the item on original line `itemLine`.
        func column(ofItem itemLine: Int) -> MarkdownRenderer.ListItemColumn? {
            guard let k = itemLines[itemLine] else { return nil }
            return renderer.listItemColumn(itemLine: lines[k], hang: hangs[k])
        }
        for (row, start) in zip(pending, starts) {
            let columns = owners.paragraphs.isEmpty ? [] : row.sources.map { source in
                owners.paragraphs[source].flatMap(column(ofItem:))
            }
            blocks[row.position] = .text(index: row.index,
                                         renderer.render(joined: row.lines,
                                                         hangs: Array(hangs[start..<(start + row.lines.count)]),
                                                         itemColumns: columns),
                                         sourceLine: row.sourceLine, joinsPrevious: row.joinsPrevious)
        }
        for (position, owner) in owners.blocks {
            guard let column = column(ofItem: owner) else { continue }
            blocks[position] = blocks[position].withListIndent(column.textIndent)
        }
    }
}
