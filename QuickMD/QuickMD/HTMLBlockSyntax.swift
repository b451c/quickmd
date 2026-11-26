import AppKit

// MARK: - HTML in Markdown (v1.17)
//
// QuickMD draws documents natively and never hands HTML to a web view, so
// raw HTML is not rendered by a browser engine. Instead, a few HTML
// constructs that READMEs actually use are recognised here and turned into
// the parser's own blocks. Anything not recognised stays text, as before.
//
// This file is where block-level HTML syntax lives: one entry point per
// construct, all built on the same small helpers. To support another tag,
// add its recognizer here and call it from `MarkdownBlockParser.parse` (see
// "HTML blocks" there).
//
//  * Comments (`<!-- … -->`, CommonMark HTML block kind 2, and inline raw
//    HTML): drawn as nothing, like GitHub.
//  * Containers: an element whose content is more Markdown blocks. The
//    parser keeps every block of the document in one flat list and tags
//    each with the containers it is inside (`MarkdownBlock.containers`);
//    the view decides what that means (`ContainerPresentation`). The one
//    container today is `<details>`, whose `<summary>` becomes a header
//    row that shows or hides the blocks inside. A new container tag is one
//    entry in `containerTags` and one `HTMLContainerKind` case.
//
// The tag grammar (`tags(in:)`) follows CommonMark's raw HTML: tag names
// `[A-Za-z][A-Za-z0-9-]*`, attribute names `[A-Za-z_:][A-Za-z0-9_.:-]*`,
// quoted or unquoted values, case-insensitive names.
//
// `HTMLImageSyntax` (the `<img>` line idiom) predates this file and keeps
// its own byte scanner.

// MARK: - Containers

/// What kind of HTML container a block is in — the extension point for
/// container tags (`HTMLBlockSyntax.containerTags`).
enum HTMLContainerKind: Sendable, Equatable {
    /// `<details>` / `<details open>`: a summary row that shows or hides the
    /// blocks inside, closed unless the tag has `open`. Print and PDF always
    /// show them.
    case details(isOpenByDefault: Bool)

    /// Whether the container's blocks are shown before the reader toggles it.
    var isOpenByDefault: Bool {
        switch self {
        case .details(let isOpen): return isOpen
        }
    }
}

/// One HTML container of a parsed document.
struct HTMLContainer: Sendable, Equatable {
    /// 0-based, in order of the opening tags in the document — an outer
    /// container's id is lower than its inner ones'. Positional, like block
    /// ids: stable across a re-parse of the same text.
    let id: Int
    let kind: HTMLContainerKind
}

enum HTMLBlockSyntax {

    // MARK: Container lines

    /// What a container line says, in source order. One line can say
    /// several things: `<details><summary>More</summary>` opens a container
    /// and gives its summary.
    enum ContainerEvent: Equatable {
        /// An opening container tag.
        case open(HTMLContainerKind)
        /// The container's caption (`<summary>…</summary>`), as Markdown
        /// inline text (`summaryText`).
        case summary(String)
        /// Other text on the line, outside any recognised tag (a one-line
        /// `<details><summary>a</summary>body</details>`): paragraph text.
        case text(String)
        /// A closing container tag.
        case close
    }

    /// Container tags: name → the kind its opening tag makes.
    private static let containerTags: [String: (HTMLTag) -> HTMLContainerKind] = [
        "details": { .details(isOpenByDefault: $0.hasAttribute("open")) },
    ]

    /// The caption tag of a container (`<details>`'s).
    private static let summaryTag = "summary"

    /// A `<summary>` spread over several lines is joined at most this many
    /// lines down (like `HTMLImageSyntax`'s multi-line `<img`), so a stray
    /// `<summary>` never makes a scan run to the end of the document.
    private static let summaryLineLimit = 10

    /// The container line starting at `lines[index]` — its events and the
    /// line after it — or nil when the line is not one.
    ///
    /// A container line starts (after any spaces or tabs) with a container
    /// tag, opening or closing, or with `<summary>`. The rest of the line is
    /// read too: more container tags, a summary, text. A `<summary>` that
    /// does not close on its line takes the following lines up to the one
    /// with `</summary>` (at most `summaryLineLimit`); without one, the
    /// summary is the rest of its own line.
    static func containerLine(in lines: [String], at index: Int) -> (events: [ContainerEvent], end: Int)? {
        let first = lines[index].drop(while: { $0 == " " || $0 == "\t" })
        guard let tag = leadingTag(first),
              containerTags[tag.name] != nil || (tag.name == summaryTag && !tag.isClosing) else { return nil }

        var text = String(first)
        var end = index + 1
        if opensUnclosedSummary(text) {
            var next = index + 1
            while next < lines.count, next <= index + summaryLineLimit {
                if lines[next].range(of: "</summary", options: .caseInsensitive) != nil {
                    text = ([text] + lines[(index + 1)...next]).joined(separator: "\n")
                    end = next + 1
                    break
                }
                next += 1
            }
        }
        return (events(in: tags(in: text[...])), end)
    }

    /// Whether a summary starts on the line: what `containerLine` would read
    /// as `.summary` first. The parser asks it to know whether a container
    /// still gets its caption.
    static func startsSummary(_ line: String) -> Bool {
        guard let tag = leadingTag(line.drop(while: { $0 == " " || $0 == "\t" })) else { return false }
        return tag.name == summaryTag && !tag.isClosing
    }

    /// The container or summary tag `text` starts with, nil for anything
    /// else. The name is checked before the tag is read: a line of other
    /// HTML (a multi-megabyte `<img src="data:…">`) is rejected after a few
    /// characters.
    private static func leadingTag(_ text: Substring) -> HTMLTag? {
        guard text.hasPrefix("<") else { return nil }
        var nameStart = text.index(after: text.startIndex)
        if nameStart < text.endIndex, text[nameStart] == "/" { nameStart = text.index(after: nameStart) }
        let name = text[nameStart...].prefix(while: { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") })
            .lowercased()
        guard containerTags[name] != nil || name == summaryTag else { return nil }
        return tag(in: text, at: text.startIndex)?.0
    }

    /// `<summary` with no `</summary` after it on the text.
    private static func opensUnclosedSummary(_ text: String) -> Bool {
        guard let open = text.range(of: "<summary", options: .caseInsensitive) else { return false }
        return text.range(of: "</summary", options: .caseInsensitive, range: open.upperBound..<text.endIndex) == nil
    }

    private static func events(in pieces: [Piece]) -> [ContainerEvent] {
        var events: [ContainerEvent] = []
        var summary: [Piece]?
        func addText(_ text: String) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { events.append(.text(trimmed)) }
        }
        var pending = ""
        for piece in pieces {
            if summary != nil {
                if case .tag(let tag) = piece, tag.name == summaryTag, tag.isClosing {
                    events.append(.summary(summaryText(summary!)))
                    summary = nil
                } else {
                    summary!.append(piece)
                }
                continue
            }
            switch piece {
            case .text(let text):
                pending += text
            case .tag(let tag):
                if tag.name == summaryTag {
                    // A stray `</summary>` says nothing.
                    guard !tag.isClosing else { continue }
                    addText(pending)
                    pending = ""
                    summary = []
                } else if let kind = containerTags[tag.name] {
                    addText(pending)
                    pending = ""
                    events.append(tag.isClosing ? .close : .open(kind(tag)))
                } else {
                    // Another tag between them (`<p>`, `<br>`) is dropped; its
                    // text is kept, as a browser shows it.
                    pending += " "
                }
            }
        }
        // A summary left open at the end: the rest is its text.
        if let summary { events.append(.summary(summaryText(summary))) }
        addText(pending)
        return events
    }

    /// A summary's content as Markdown inline text: the inline tags
    /// Markdown can say are said its way (`<b>`/`<strong>` `**`, `<i>`/`<em>`
    /// `*`, `<code>` a backtick), a `<br>` is a space, any other tag is
    /// dropped and its text kept. Line breaks are spaces; runs of
    /// whitespace are one.
    static func summaryText(_ pieces: [Piece]) -> String {
        var out = ""
        for piece in pieces {
            switch piece {
            case .text(let text):
                out += text
            case .tag(let tag):
                switch tag.name {
                case "b", "strong": out += "**"
                case "i", "em": out += "*"
                case "code": out += "`"
                default: out += " "
                }
            }
        }
        return out.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r" })
            .joined(separator: " ")
    }

    // MARK: Tags

    /// A piece of HTML text: a tag, or the text between tags.
    enum Piece: Equatable {
        case tag(HTMLTag)
        case text(String)
    }

    /// `text` cut into tags and the text between them. A `<` that does not
    /// start a well-formed tag is text. Only called on container lines
    /// (they start with a container tag), never on paragraph text.
    static func tags(in text: Substring) -> [Piece] {
        var pieces: [Piece] = []
        var plain = ""
        var i = text.startIndex
        while i < text.endIndex {
            if text[i] == "<", let (tag, next) = tag(in: text, at: i) {
                if !plain.isEmpty { pieces.append(.text(plain)); plain = "" }
                pieces.append(.tag(tag))
                i = next
            } else {
                plain.append(text[i])
                i = text.index(after: i)
            }
        }
        if !plain.isEmpty { pieces.append(.text(plain)) }
        return pieces
    }

    /// The tag starting at `start` (a `<`) and the index after its `>`.
    private static func tag(in text: Substring, at start: Substring.Index) -> (HTMLTag, Substring.Index)? {
        var i = text.index(after: start)
        func peek() -> Character? { i < text.endIndex ? text[i] : nil }
        func advance() { i = text.index(after: i) }
        func skipWhitespace() -> Bool {
            let before = i
            while let c = peek(), c == " " || c == "\t" || c == "\n" || c == "\r" { advance() }
            return i > before
        }
        func isNameStart(_ c: Character) -> Bool { c.isASCII && c.isLetter }

        let isClosing = peek() == "/"
        if isClosing { advance() }
        guard let c = peek(), isNameStart(c) else { return nil }
        let nameStart = i
        while let c = peek(), c.isASCII && (c.isLetter || c.isNumber || c == "-") { advance() }
        let name = text[nameStart..<i].lowercased()

        if isClosing {
            _ = skipWhitespace()
            guard peek() == ">" else { return nil }
            advance()
            return (HTMLTag(name: name, isClosing: true, attributes: [:]), i)
        }

        var attributes: [String: String] = [:]
        while true {
            let spaced = skipWhitespace()
            guard let c = peek() else { return nil }
            if c == ">" { advance(); break }
            if c == "/" {
                advance()
                guard peek() == ">" else { return nil }
                advance()
                break
            }
            // Attributes are separated from the name and each other by whitespace.
            guard spaced, c.isASCII, c.isLetter || c == "_" || c == ":" else { return nil }
            let attrStart = i
            while let c = peek(), c.isASCII && (c.isLetter || c.isNumber || "_.:-".contains(c)) { advance() }
            let attrName = text[attrStart..<i].lowercased()
            var value = ""
            let beforeValue = i
            _ = skipWhitespace()
            if peek() == "=" {
                advance()
                _ = skipWhitespace()
                guard let quote = peek() else { return nil }
                if quote == "\"" || quote == "'" {
                    advance()
                    let valueStart = i
                    while let c = peek(), c != quote { advance() }
                    guard peek() == quote else { return nil }
                    value = String(text[valueStart..<i])
                    advance()
                } else {
                    let valueStart = i
                    while let c = peek(), !(c == " " || c == "\t" || c == "\n" || c == "\r"
                                            || "\"'=<>`".contains(c)) { advance() }
                    guard i > valueStart else { return nil }
                    value = String(text[valueStart..<i])
                }
            } else {
                i = beforeValue
            }
            // The first occurrence wins, as in HTML.
            if attributes[attrName] == nil { attributes[attrName] = value }
        }
        return (HTMLTag(name: name, isClosing: false, attributes: attributes), i)
    }

    // MARK: Toggle links

    /// The link a container's summary text carries: a click on it toggles
    /// the container, through the text rows' ordinary link path
    /// (`MarkdownView.handleLinkActivation`). Never opened as a URL.
    static func toggleURL(for container: Int) -> URL {
        URL(string: "\(toggleScheme):\(container)")!
    }

    /// The container a `toggleURL` names; nil for any other URL.
    static func toggledContainer(_ url: URL) -> Int? {
        guard url.scheme?.lowercased() == toggleScheme else { return nil }
        return Int(url.absoluteString.dropFirst(toggleScheme.count + 1))
    }

    private static let toggleScheme = "x-quickmd-container"

    /// An `NSAttributedString` `.link` value (a URL or a string) as a URL.
    static func url(fromLink value: Any?) -> URL? {
        (value as? URL) ?? (value as? String).flatMap(URL.init(string:))
    }

    /// `text` without its toggle links (print: SwiftUI `Text` would draw
    /// them as links); every other link kept.
    static func removingToggleLinks(_ text: AttributedString) -> AttributedString {
        var text = text
        for (link, range) in text.runs[\.link] {
            if let link, toggledContainer(link) != nil { text[range].link = nil }
        }
        return text
    }

    /// The same for a copy's string (`DocumentCopyBuilder`).
    static func removeToggleLinks(from text: NSMutableAttributedString) {
        var ranges: [NSRange] = []
        text.enumerateAttribute(.link, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            if let url = url(fromLink: value), toggledContainer(url) != nil { ranges.append(range) }
        }
        for range in ranges { text.removeAttribute(.link, range: range) }
    }

    // MARK: Comments

    /// The line after the HTML comment block that starts on `lines[index]`,
    /// or nil when no comment block starts there.
    ///
    /// CommonMark HTML block kind 2: the line, indented at most three
    /// spaces, starts with `<!--`; the block ends with the first line that
    /// contains `-->` (the start line included: `<!-- note -->`, `<!-->`).
    /// A comment that never closes runs to the end of the document, as it
    /// does on GitHub.
    static func commentBlockEnd(in lines: [String], at index: Int) -> Int? {
        let line = lines[index]
        guard let start = commentStart(in: line) else { return nil }
        // The closer may overlap the opener's dashes (`<!-->`, `<!--->`).
        let afterBang = line.utf8.index(start, offsetBy: 2)
        if line[afterBang...].contains("-->") { return index + 1 }
        var next = index + 1
        while next < lines.count {
            if lines[next].contains("-->") { return next + 1 }
            next += 1
        }
        return lines.count
    }

    /// Where `<!--` starts on `line`, when the line is the start of a comment
    /// block: up to three leading spaces (four are indented code).
    private static func commentStart(in line: String) -> String.Index? {
        var index = line.startIndex
        var spaces = 0
        while index < line.endIndex, line[index] == " ", spaces < 4 {
            spaces += 1
            index = line.index(after: index)
        }
        guard spaces <= 3, line[index...].hasPrefix("<!--") else { return nil }
        return index
    }

    /// The text after an inline HTML comment at the start of `text`, or nil
    /// when `text` does not start with a complete one.
    ///
    /// CommonMark 0.31 inline raw HTML: `<!-->`, `<!--->`, or `<!--`, then
    /// text, then the first `-->`. An unclosed `<!--` is literal text.
    static func skippingInlineComment(_ text: Substring) -> Substring? {
        guard text.hasPrefix("<!--") else { return nil }
        let afterBang = text.utf8.index(text.startIndex, offsetBy: 2)
        guard let closer = text[afterBang...].range(of: "-->") else { return nil }
        return text[closer.upperBound...]
    }
}

/// One HTML tag as written: `<name attr="value">`, `<name/>`, `</name>`.
struct HTMLTag: Equatable {
    /// Lowercased.
    let name: String
    let isClosing: Bool
    /// Lowercased attribute names → their values as written ("" for a bare
    /// attribute like `open`). Character references are not decoded.
    let attributes: [String: String]

    func hasAttribute(_ name: String) -> Bool { attributes[name] != nil }
}

// MARK: - Presentation

/// What the document list shows of a parse: every block except those
/// inside a closed container (`MarkdownBlock.containers`), with the height
/// table cut to match.
///
/// The parse and its measurement always hold EVERY block — search, copy,
/// the table of contents and print see a closed `<details>`'s content —
/// and only the list is handed this subset. Hiding rows changes no height,
/// only the space above the first row after a hidden run, which is derived
/// again from the rhythm (`BlockLayout.Spacing.above`) as if the rows had
/// been parsed next to each other.
struct ContainerPresentation {
    let blocks: [MarkdownBlock]
    let table: BlockHeightTable
    /// The parse's row of each shown row; nil when every row is shown.
    private let documentRows: [Int]?

    /// The parse's row of shown row `row`.
    func documentRow(_ row: Int) -> Int {
        guard let documentRows else { return row }
        return row >= 0 && row < documentRows.count ? documentRows[row] : -1
    }

    /// `blocks` with the rows of every closed container left out. `table`
    /// must be `blocks`' own (same count), `rhythm` its spacing input
    /// (`MeasuredBlocks.rhythm`, may be empty: the measured spacing is then
    /// kept), `fontScale` the scale it was measured at.
    init(blocks: [MarkdownBlock], table: BlockHeightTable, rhythm: [BlockLayout.Spacing.Row],
         fontScale: CGFloat, isOpen: (HTMLContainer) -> Bool) {
        var closed = Set<Int>()
        for block in blocks {
            if let container = block.opensContainer, !isOpen(container) { closed.insert(container.id) }
        }
        guard !closed.isEmpty else {
            self.blocks = blocks
            self.table = table
            self.documentRows = nil
            return
        }
        let measured = table.count == blocks.count
        let canRespace = measured && rhythm.count == blocks.count
        var shown: [MarkdownBlock] = []
        var rows: [Int] = []
        var heights: [CGFloat] = []
        var kinds: [RowKind] = []
        var spacing: [CGFloat] = []
        for (row, block) in blocks.enumerated() where !block.containers.contains(where: closed.contains) {
            if measured {
                heights.append(table.heights[row])
                kinds.append(table.kinds[row])
                // Right after the previous shown row: its measured spacing
                // holds. After a hidden run, the rhythm decides again.
                let previous = rows.last
                if canRespace, previous != row - 1 {
                    spacing.append(BlockLayout.Spacing.above(rhythm[row], after: previous.map { rhythm[$0] },
                                                             fontScale: fontScale))
                } else {
                    spacing.append(previous == nil ? 0 : table.spacing(row))
                }
            }
            shown.append(block)
            rows.append(row)
        }
        self.blocks = shown
        self.documentRows = rows
        self.table = measured
            ? BlockHeightTable(heights: heights, kinds: kinds, contentWidth: table.contentWidth, spacingAbove: spacing)
            // Not measured yet: an equally unmeasured table (the list waits
            // for a table of the blocks' count).
            : table
    }
}
