import Foundation

// MARK: - Source Edit helpers (v1.12 S-D3, S-D5, S-D10, S-D14b)
//
// Pure functions behind the source editor: line <-> position mapping, the
// "which block holds this line" landing rule, the selection carry-over lookup
// and the indentation edits. No view code, so the file is compiled into BOTH
// the app and the test target and every rule is unit-tested directly.
//
// Positions are UTF-16 offsets / NSRange throughout — that is what NSTextView
// speaks, and it is exact for emoji, combining marks and CJK, where Swift
// `Character` counts are not.
//
// The text is assumed to be LF-only: the editor buffer never contains U+000D
// (normalised on entry and on every edit, constraint 14). A "line" is what the
// parser means by it — the text split on U+000A and nothing else (NSString's
// `lineRange(for:)` would also break at U+2028 / U+0085 and disagree with
// `MarkdownBlock.sourceLine`). A trailing newline therefore ends with an empty
// last line, and an empty text is one empty line.
//
// WHICH OVERLOAD TO CALL: every function's core takes an `NSString`. The editor
// must pass its storage's backing string as is — `textView.textStorage!
// .mutableString` — never `textView.string`: bridging a MUTABLE NSString to a
// Swift `String` copies it (up to ~10 MB at the size cap) on every Return or
// Tab. The `String` overloads are one-line forwards for callers that already
// hold a Swift string (`currentText`, tests); `String as NSString` is a free
// wrapper, so they cost nothing.

enum SourceEditSupport {

    /// One replacement the editor applies as a single undoable change:
    /// `shouldChangeText(in: range, replacementString: replacement)`, replace,
    /// `didChangeText()`, then `setSelectedRange(selection)`.
    struct TextEdit: Equatable {
        /// Range in the text BEFORE the edit.
        let range: NSRange
        let replacement: String
        /// Selection to set AFTER the edit, in the new text.
        let selection: NSRange
    }

    // MARK: - Lines

    /// UTF-16 offset of the start of 0-based `line`. Clamped: a negative line
    /// is line 0, a line past the end is the last line.
    ///
    /// Scans from offset 0 — meant for one call per user action (entering the
    /// editor, a ToC click). To map many lines at once use `lineStarts(in:)`.
    static func lineStart(_ line: Int, in text: NSString) -> Int {
        guard line > 0 else { return 0 }
        var seen = 0
        var start = 0
        forEachNewline(in: text, from: 0, to: text.length) { offset in
            seen += 1
            start = offset + 1
            return seen < line
        }
        return start
    }

    /// Start offset of EVERY line, in one pass: `lineStarts(in:)[n]` is
    /// `lineStart(n, in:)`. Never empty (an empty text has line 0 at 0).
    static func lineStarts(in text: NSString) -> [Int] {
        var starts = [0]
        forEachNewline(in: text, from: 0, to: text.length) { offset in
            starts.append(offset + 1)
            return true
        }
        return starts
    }

    /// The 0-based line containing UTF-16 `offset` (clamped to `0...length`).
    /// An offset right after a newline belongs to the next line — it is the
    /// caret position at that line's start. Scans from 0, like `lineStart`.
    static func line(containing offset: Int, in text: NSString) -> Int {
        let end = min(max(offset, 0), text.length)
        var count = 0
        forEachNewline(in: text, from: 0, to: end) { _ in
            count += 1
            return true
        }
        return count
    }

    /// The range of 0-based `line` without its newline (clamped like
    /// `lineStart`).
    static func lineRange(_ line: Int, in text: NSString) -> NSRange {
        let start = lineStart(line, in: text)
        return NSRange(location: start, length: lineEnd(from: start, in: text) - start)
    }

    /// Number of lines (`"\n"`-separated; never 0).
    static func lineCount(in text: NSString) -> Int {
        line(containing: text.length, in: text) + 1
    }

    static func lineStart(_ line: Int, in text: String) -> Int { lineStart(line, in: text as NSString) }
    static func lineStarts(in text: String) -> [Int] { lineStarts(in: text as NSString) }
    static func line(containing offset: Int, in text: String) -> Int { line(containing: offset, in: text as NSString) }
    static func lineRange(_ line: Int, in text: String) -> NSRange { lineRange(line, in: text as NSString) }
    static func lineCount(in text: String) -> Int { lineCount(in: text as NSString) }

    // MARK: - Landing block (S-D10)

    /// Index of the block that contains 0-based source `line`: among the
    /// blocks with the greatest `sourceLine <= line`, the FIRST one (several
    /// blocks share a line when images sit side by side). A line before the
    /// first block lands on block 0; an empty list has no answer.
    ///
    /// Relies on `sourceLine` being non-decreasing across the parser's
    /// output, hence a binary search rather than a scan.
    static func blockIndex(containingLine line: Int, in blocks: [MarkdownBlock]) -> Int? {
        guard !blocks.isEmpty else { return nil }
        // First index whose sourceLine > line.
        var low = 0, high = blocks.count
        while low < high {
            let mid = (low + high) / 2
            if blocks[mid].sourceLine <= line { low = mid + 1 } else { high = mid }
        }
        guard low > 0 else { return 0 }
        let target = blocks[low - 1].sourceLine
        // First index whose sourceLine == target (>= target, given the order).
        var first = 0
        high = low - 1
        while first < high {
            let mid = (first + high) / 2
            if blocks[mid].sourceLine < target { first = mid + 1 } else { high = mid }
        }
        return first
    }

    // MARK: - Selection carry-over (S-D14b)

    /// Where the rendered selection is in the source: the first LITERAL
    /// occurrence of `selectedText` (trimmed of whitespace and newlines)
    /// inside 0-based source lines `lines` — from the start of the first line
    /// to the end of the last one, its newline excluded, so a match can never
    /// extend outside them. Lines past the end of the text are ignored.
    ///
    /// Nil for an empty selection, an empty or out-of-text line range, or no
    /// match. Literal on purpose: rendered `bold` is found inside `**bold**`,
    /// but anything the renderer rewrote (entities, joined soft breaks, list
    /// markers) is simply not found — no second Markdown grammar here.
    static func sourceRange(ofSelection selectedText: String, in text: NSString,
                            lines: Range<Int>) -> NSRange? {
        let needle = selectedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return nil }
        let lower = max(lines.lowerBound, 0)
        guard lines.upperBound > lower else { return nil }
        // Start of `lower`, or nil when the text has fewer lines.
        var start: Int? = lower == 0 ? 0 : nil
        var seen = 0
        if lower > 0 {
            forEachNewline(in: text, from: 0, to: text.length) { offset in
                seen += 1
                if seen == lower { start = offset + 1 }
                return seen < lower
            }
        }
        guard let start else { return nil }
        // End of line `upperBound - 1`: skip the newlines of the lines in between.
        var end = text.length
        var remaining = lines.upperBound - lower
        forEachNewline(in: text, from: start, to: text.length) { offset in
            remaining -= 1
            if remaining == 0 { end = offset }
            return remaining > 0
        }
        let found = text.range(of: needle, options: .literal,
                               range: NSRange(location: start, length: end - start))
        return found.location == NSNotFound ? nil : found
    }

    static func sourceRange(ofSelection selectedText: String, in text: String,
                            lines: Range<Int>) -> NSRange? {
        sourceRange(ofSelection: selectedText, in: text as NSString, lines: lines)
    }

    // MARK: - Indentation (S-D5)

    /// Width in spaces of one outdent step when the unit is a tab: a line
    /// indented with spaces in a tab-indented document still loses one level.
    static let spacesPerIndent = 4

    /// The document's indent unit: a tab if any line starts with one, else
    /// four spaces. Computed once per document; the user's file decides.
    static func indentUnit(for text: NSString) -> String {
        if text.length > 0, text.character(at: 0) == tab { return "\t" }
        let found = text.range(of: "\n\t", options: .literal)
        return found.location == NSNotFound ? String(repeating: " ", count: spacesPerIndent) : "\t"
    }

    /// Return: a newline plus the caret line's leading spaces / tabs — only the
    /// part BEFORE the caret (Return inside the indentation splits it). A
    /// selection is replaced, measured from its start. No list continuation
    /// (non-goal). Costs the caret line's length, not the document's.
    static func newlineEdit(in text: NSString, selection: NSRange) -> TextEdit {
        let range = clamped(selection, in: text)
        let caret = range.location
        let start = lineStart(containing: caret, in: text)
        let indentEnd = min(leadingWhitespaceEnd(from: start, in: text), caret)
        let replacement = "\n" + text.substring(with: NSRange(location: start, length: indentEnd - start))
        let after = caret + (replacement as NSString).length
        return TextEdit(range: range, replacement: replacement,
                        selection: NSRange(location: after, length: 0))
    }

    /// Tab. A selection that crosses a newline prefixes every touched,
    /// non-empty line with `unit` — including one whole line selected with its
    /// newline, which must indent, not be replaced by a tab. A caret or a
    /// selection within one line is replaced by `unit`. Nil when there is
    /// nothing to change (every touched line is empty). The selection keeps
    /// covering the same text.
    static func indentEdit(in text: NSString, selection: NSRange, unit: String) -> TextEdit? {
        let selection = clamped(selection, in: text)
        guard selection.length > 0,
              lineEnd(from: selection.location, in: text) < NSMaxRange(selection) else {
            let after = selection.location + (unit as NSString).length
            return TextEdit(range: selection, replacement: unit,
                            selection: NSRange(location: after, length: 0))
        }
        let unitLength = (unit as NSString).length
        return linePrefixEdit(in: text, selection: selection, prefix: Array(unit.utf16)) { _, length in
            length > 0 ? LinePrefixChange(removed: 0, inserted: unitLength) : nil
        }
    }

    /// Shift-Tab: removes one level from the start of every touched line (a
    /// caret or a single-line selection touches its own line) — one tab, or
    /// up to one unit's width of spaces. Lines without leading whitespace are
    /// left alone; nil when no line changes.
    static func outdentEdit(in text: NSString, selection: NSRange, unit: String) -> TextEdit? {
        let selection = clamped(selection, in: text)
        let width = unit == "\t" ? spacesPerIndent : max((unit as NSString).length, 1)
        return linePrefixEdit(in: text, selection: selection, prefix: []) { line, length in
            guard length > 0 else { return nil }
            if line.pointee == tab { return LinePrefixChange(removed: 1, inserted: 0) }
            var removed = 0
            while removed < min(width, length), line[removed] == space { removed += 1 }
            return removed > 0 ? LinePrefixChange(removed: removed, inserted: 0) : nil
        }
    }

    static func indentUnit(for text: String) -> String { indentUnit(for: text as NSString) }
    static func newlineEdit(in text: String, selection: NSRange) -> TextEdit {
        newlineEdit(in: text as NSString, selection: selection)
    }
    static func indentEdit(in text: String, selection: NSRange, unit: String) -> TextEdit? {
        indentEdit(in: text as NSString, selection: selection, unit: unit)
    }
    static func outdentEdit(in text: String, selection: NSRange, unit: String) -> TextEdit? {
        outdentEdit(in: text as NSString, selection: selection, unit: unit)
    }

    // MARK: - Private

    private static let newline: unichar = 0x0A
    private static let tab: unichar = 0x09
    private static let space: unichar = 0x20

    /// Units copied per `getCharacters` call — keeps the scan linear and
    /// allocation-free per unit on both NSString-backed storage (the text
    /// view's) and native Swift strings (tests, `currentText`).
    ///
    /// The loops below walk raw pointers on purpose: pointer arithmetic is
    /// transparent and stays fast in -Onone builds, while `for i in 0..<n`
    /// over a buffer costs ~100 ns per unit there (measured: 1 s vs 26 ms for
    /// one pass over 9.6 M units) — Debug is where the editor is tried first.
    private static let chunkSize = 4096

    /// Calls `body` with the offset of every U+000A in `from..<to`, in order,
    /// until it returns false.
    private static func forEachNewline(in ns: NSString, from: Int, to: Int,
                                       _ body: (Int) -> Bool) {
        guard from < to else { return }
        var buffer = [unichar](repeating: 0, count: min(chunkSize, to - from))
        var position = from
        while position < to {
            let count = min(chunkSize, to - position)
            let keepGoing: Bool = buffer.withUnsafeMutableBufferPointer { units in
                let base = units.baseAddress!
                ns.getCharacters(base, range: NSRange(location: position, length: count))
                var unit = base
                let end = base + count
                while unit < end {
                    if unit.pointee == newline, !body(position + (unit - base)) { return false }
                    unit += 1
                }
                return true
            }
            if !keepGoing { return }
            position += count
        }
    }

    /// Start of the line containing `offset`, scanning BACKWARDS — cost is
    /// the line's length, not the document's (Return runs per keystroke).
    private static func lineStart(containing offset: Int, in ns: NSString) -> Int {
        guard offset > 0 else { return 0 }
        var buffer = [unichar](repeating: 0, count: min(chunkSize, offset))
        var end = offset
        while end > 0 {
            let count = min(chunkSize, end)
            let start = end - count
            let found: Int? = buffer.withUnsafeMutableBufferPointer { units in
                let base = units.baseAddress!
                ns.getCharacters(base, range: NSRange(location: start, length: count))
                var unit = base + count
                while unit > base {
                    unit -= 1
                    if unit.pointee == newline { return start + (unit - base) + 1 }
                }
                return nil
            }
            if let found { return found }
            end = start
        }
        return 0
    }

    /// Offset of the newline ending the line that contains `offset` (or the
    /// text's length on the last line).
    private static func lineEnd(from offset: Int, in ns: NSString) -> Int {
        var end = ns.length
        forEachNewline(in: ns, from: offset, to: ns.length) { found in
            end = found
            return false
        }
        return end
    }

    /// End of the run of spaces / tabs starting at `start`.
    private static func leadingWhitespaceEnd(from start: Int, in ns: NSString) -> Int {
        var position = start
        while position < ns.length {
            let unit = ns.character(at: position)
            guard unit == space || unit == tab else { break }
            position += 1
        }
        return position
    }

    private static func clamped(_ range: NSRange, in ns: NSString) -> NSRange {
        let location = min(max(range.location, 0), ns.length)
        return NSRange(location: location, length: min(max(range.length, 0), ns.length - location))
    }

    /// What one line's start becomes: `removed` leading units dropped, then
    /// `inserted` units of the prefix written.
    private struct LinePrefixChange {
        let removed: Int
        let inserted: Int
    }

    /// A change positioned in the document (`at` = the line's start offset).
    private struct LineChange {
        let at: Int
        let removed: Int
        let inserted: Int
    }

    /// Builds ONE replacement for the lines `selection` touches — from the
    /// start's line to the end's line, except that a selection ending at
    /// column 0 does not touch that last line (dragging down over whole lines
    /// ends there) — in a single pass: the span is copied out once, `rule`
    /// looks at each line (pointer to its first unit, its length) and the new
    /// text is assembled by block copies, never per-line substrings. The
    /// selection is mapped through the changes.
    private static func linePrefixEdit(
        in ns: NSString, selection: NSRange, prefix: [unichar],
        rule: (UnsafePointer<unichar>, Int) -> LinePrefixChange?
    ) -> TextEdit? {
        let selectionEnd = NSMaxRange(selection)
        let spanStart = lineStart(containing: selection.location, in: ns)
        let endsAtColumnZero = selection.length > 0 && ns.character(at: selectionEnd - 1) == newline
        let spanEnd = endsAtColumnZero ? selectionEnd - 1 : lineEnd(from: selectionEnd, in: ns)
        let spanLength = spanEnd - spanStart

        var source = [unichar](repeating: 0, count: max(spanLength, 1))
        var changes: [LineChange] = []
        source.withUnsafeMutableBufferPointer { units in
            let base = units.baseAddress!
            if spanLength > 0 {
                ns.getCharacters(base, range: NSRange(location: spanStart, length: spanLength))
            }
            let end = base + spanLength
            var lineHead = base
            while true {
                var lineTail = lineHead
                while lineTail < end, lineTail.pointee != newline { lineTail += 1 }
                if let change = rule(UnsafePointer(lineHead), lineTail - lineHead) {
                    changes.append(LineChange(at: spanStart + (lineHead - base),
                                              removed: change.removed, inserted: change.inserted))
                }
                guard lineTail < end else { break }
                lineHead = lineTail + 1
            }
        }
        guard !changes.isEmpty else { return nil }

        let netChange = changes.reduce(0) { $0 + $1.inserted - $1.removed }
        var output = [unichar](repeating: 0, count: max(spanLength + netChange, 1))
        source.withUnsafeBufferPointer { sourceUnits in
            output.withUnsafeMutableBufferPointer { outputUnits in
                prefix.withUnsafeBufferPointer { prefixUnits in
                    let from = sourceUnits.baseAddress!
                    var to = outputUnits.baseAddress!
                    var cursor = 0  // offset into the span
                    func copy(_ pointer: UnsafePointer<unichar>, _ count: Int) {
                        guard count > 0 else { return }
                        UnsafeMutableRawPointer(to).copyMemory(from: pointer,
                                                               byteCount: count * MemoryLayout<unichar>.stride)
                        to += count
                    }
                    for change in changes {
                        let lineOffset = change.at - spanStart
                        copy(from + cursor, lineOffset - cursor)
                        if change.inserted > 0 { copy(prefixUnits.baseAddress!, change.inserted) }
                        cursor = lineOffset + change.removed
                    }
                    copy(from + cursor, spanLength - cursor)
                }
            }
        }
        let replacement = String(utf16CodeUnits: output, count: spanLength + netChange)

        let start = map(selection.location, through: changes)
        let end = map(selectionEnd, through: changes)
        return TextEdit(range: NSRange(location: spanStart, length: spanLength),
                        replacement: replacement,
                        selection: NSRange(location: start, length: end - start))
    }

    /// Where `offset` lands after `changes`. A position AT a line start stays
    /// at that line start (the new indent falls inside the selection); one
    /// inside removed indentation moves to the line start; anything after
    /// shifts by the net change. That is what makes indent then outdent
    /// restore the original selection.
    private static func map(_ offset: Int, through changes: [LineChange]) -> Int {
        var delta = 0
        for change in changes {
            if offset <= change.at { break }
            if offset < change.at + change.removed {
                return change.at + delta
            }
            delta += change.inserted - change.removed
        }
        return offset + delta
    }
}
