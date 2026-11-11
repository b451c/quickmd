import Foundation

// MARK: - List nesting (v1.15)
//
// The block list is flat: one row per block, no tree. A list item still OWNS
// the blocks under it (CommonMark): a code block indented to the item's text,
// a second paragraph, a nested list. Only the first two need to know it — a
// nested list is drawn by the list's own text rows already — and what they
// need is WHERE the item's text starts, so they line up with it and the
// numbering goes on past them.
//
// `ListNesting` is the part of CommonMark's container model that answers
// "which item does this line belong to": a stack of the open items and their
// content columns, fed every line the block loop reads, in order. The parser
// records the answer per block (`MarkdownBlockParser.renderPendingRows` turns
// it into points once the list's widest marker is known).

/// The open list items at the line the block loop is on, CommonMark's way:
/// - an item line closes the items its indent is not inside and opens itself;
/// - a line that starts a paragraph or a block (after a blank line, after
///   another block) belongs to the deepest open item whose content column
///   its indent reaches, and closes the deeper ones;
/// - a line that continues an open paragraph (soft break, lazy line, a line
///   after a hard break) changes nothing: it is in the paragraph's item.
///
/// O(1) per line, apart from closing items (each one closed once).
struct ListNesting {
    /// An open list item: where its content starts, and the ORIGINAL source
    /// line of its item line (how the parser finds the item's row again).
    struct Item: Equatable {
        let contentColumn: Int
        let sourceLine: Int
    }

    private(set) var items: [Item] = []
    /// A paragraph goes on into the next line: it is not closed by a blank
    /// line or a block. A hard break does not close it (CommonMark).
    private(set) var paragraphOpen = false
    /// The open paragraph is not an item's own: only a bullet or an item
    /// numbered 1 may interrupt it (`MarkdownRenderer.canInterruptParagraph`;
    /// `joinSoftBreaks` makes any other item line its text).
    private var plainParagraph = false
    /// The item the open paragraph belongs to.
    private var paragraphOwner: Int?

    /// A blank line: closes the open paragraph, never an item.
    mutating func blank() {
        paragraphOpen = false
    }

    /// A line the block loop keeps as text (not blank). Returns the source
    /// line of the item a NON-item line belongs to — the item that owns the
    /// paragraph it starts or continues — or nil: for an item line (it draws
    /// itself), a thematic break, or text outside any list.
    mutating func text(_ line: String, sourceLine: Int) -> Int? {
        let indent = MarkdownBlockParser.indentColumns(line)
        if MarkdownRenderer.isThematicBreak(line) {
            close(deeperThan: indent)
            paragraphOpen = false
            return nil
        }
        let isItem = MarkdownRenderer.isListItem(line)
            && !(paragraphOpen && plainParagraph && !MarkdownRenderer.canInterruptParagraph(line))
        if isItem {
            close(deeperThan: indent)
            items.append(Item(contentColumn: Self.contentColumn(ofItem: line), sourceLine: sourceLine))
            paragraphOpen = true
            plainParagraph = false
            paragraphOwner = sourceLine
            return nil
        }
        if paragraphOpen { return paragraphOwner }
        close(deeperThan: indent)
        paragraphOpen = true
        plainParagraph = true
        paragraphOwner = items.last?.sourceLine
        return paragraphOwner
    }

    /// Any line of the document, classified by itself: blank, an item or
    /// paragraph text (`text`), or the start of a block (`block`) — a
    /// fence, `$$`, heading, rule, HTML block or quote. For the definition
    /// pre-pass, which reads the lines before the block loop decides them.
    mutating func read(_ line: String, sourceLine: Int) {
        if MarkdownRenderer.isBlankLine(line) {
            blank()
        } else if MarkdownRenderer.isListItem(line)
                    || (MarkdownBlockParser.startsNoBlock(line) && !MarkdownBlockParser.markerLine(line).hasPrefix(">")) {
            _ = text(line, sourceLine: sourceLine)
        } else {
            block(startingAt: line)
        }
    }

    /// A non-text block (fenced code, `$$`, heading, picture, table, quote,
    /// definition list) starting on `line`. Returns the item it belongs to.
    @discardableResult
    mutating func block(startingAt line: String) -> Int? {
        close(deeperThan: MarkdownBlockParser.indentColumns(line))
        paragraphOpen = false
        return items.last?.sourceLine
    }

    /// Whether `line` opens an INDENTED code block inside an item: no
    /// paragraph is open (an indented line after text is more of that text),
    /// and the line is indented four or more columns past the content column
    /// of the deepest item it is inside. Returns that item and the columns to
    /// take off every code line (content column + 4). Outside a list: nil —
    /// top-level indented code is not read here.
    func indentedCode(_ line: String) -> (owner: Int, columns: Int)? {
        guard !paragraphOpen, !MarkdownRenderer.isBlankLine(line) else { return nil }
        let indent = MarkdownBlockParser.indentColumns(line)
        guard let item = items.last(where: { $0.contentColumn <= indent }),
              indent >= item.contentColumn + 4 else { return nil }
        return (item.sourceLine, item.contentColumn + 4)
    }

    /// Items whose content the column `indent` does not reach are over.
    private mutating func close(deeperThan indent: Int) {
        while let last = items.last, last.contentColumn > indent {
            items.removeLast()
        }
    }

    /// The column an item's content starts at (CommonMark): its indent, the
    /// marker (`-`, `*`, `+`, or 1–9 digits and `.`/`)`), and the one to four
    /// columns of white space after it. Five or more (or none before the end
    /// of the line) count as one: the rest is the content's own indentation.
    /// A task item's `[ ]` is content — the box sits where the text would.
    static func contentColumn(ofItem line: String) -> Int {
        var column = 0
        var index = line.startIndex
        // Leading indentation (a tab runs to the next multiple of 4).
        while index < line.endIndex, line[index] == " " || line[index] == "\t" {
            column += line[index] == "\t" ? 4 - column % 4 : 1
            index = line.index(after: index)
        }
        // The marker.
        if index < line.endIndex, "-*+".contains(line[index]) {
            column += 1
            index = line.index(after: index)
        } else {
            while index < line.endIndex, line[index].isASCII, line[index].isNumber {
                column += 1
                index = line.index(after: index)
            }
            if index < line.endIndex { column += 1; index = line.index(after: index) }  // `.` or `)`
        }
        // White space after it.
        let markerEnd = column
        while index < line.endIndex, line[index] == " " || line[index] == "\t" {
            column += line[index] == "\t" ? 4 - column % 4 : 1
            index = line.index(after: index)
        }
        let spaces = column - markerEnd
        if index == line.endIndex || spaces > 4 { return markerEnd + 1 }
        return column
    }
}
