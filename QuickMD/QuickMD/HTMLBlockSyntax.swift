import Foundation

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
//
// `HTMLImageSyntax` (the `<img>` line idiom) predates this file and keeps
// its own byte scanner.

enum HTMLBlockSyntax {

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
