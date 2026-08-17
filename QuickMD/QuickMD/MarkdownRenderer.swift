import Foundation
import SwiftUI
import AppKit

// MARK: - Dual-Scope Styling
//
// Rendered AttributedStrings travel down TWO pipelines:
//  • SwiftUI Text — table cells and the printable/PDF views read the
//    SwiftUI-scope attributes;
//  • NSTextView (TextBlockView) — text/heading/blockquote blocks convert via
//    `NSAttributedString(_, including: \.appKit)`, which only carries
//    AppKit-scope (+ Foundation) attributes.
// Every style the renderer sets MUST stamp both scopes, or one pipeline
// silently loses formatting. Use these helpers — never set `.font` /
// `.foregroundColor` directly in renderer code.
// The one exception is NSParagraphStyle (list indents): SwiftUI `Text` has no
// equivalent, so it is AppKit-only by necessity — see "List Indentation".
extension AttributedString {

    /// Set font in both SwiftUI and AppKit scopes. `fonts` supplies the family
    /// (body, or code when `monospaced`) — the theme's `DocumentFonts`, which
    /// already has the user's Settings choice merged in. Required on purpose:
    /// a call site that forgets it would silently render in the system font.
    mutating func setDualFont(size: CGFloat, bold: Bool = false, italic: Bool = false,
                              monospaced: Bool = false, fonts: DocumentFonts) {
        self.font = fonts.swiftUI(size: size, weight: bold ? .bold : .regular,
                                  italic: italic, monospaced: monospaced)
        self[AttributeScopes.AppKitAttributes.FontAttribute.self] =
            fonts.appKit(size: size, weight: bold ? .bold : .regular,
                         italic: italic, monospaced: monospaced)
    }

    /// Set foreground color in both scopes.
    mutating func setDualForeground(_ color: Color) {
        self.foregroundColor = color
        self[AttributeScopes.AppKitAttributes.ForegroundColorAttribute.self] = NSColor(color)
    }

    /// Set background color in both scopes (inline code chips).
    mutating func setDualBackground(_ color: Color) {
        self.backgroundColor = color
        self[AttributeScopes.AppKitAttributes.BackgroundColorAttribute.self] = NSColor(color)
    }

    /// Set single underline in both scopes (links).
    mutating func setDualUnderline() {
        self.underlineStyle = .single
        self[AttributeScopes.AppKitAttributes.UnderlineStyleAttribute.self] = .single
    }

    /// Set single strikethrough in both scopes (~~text~~, checked tasks).
    mutating func setDualStrikethrough() {
        self.strikethroughStyle = .single
        self[AttributeScopes.AppKitAttributes.StrikethroughStyleAttribute.self] = .single
    }
}

// MARK: - Zoom (⌘+ / ⌘- / ⌘0)

/// One step of the text-size ladder. Deliberately NOT a theme property and NOT
/// persisted: zoom belongs to the window you're reading in, so every document
/// opens at 100% and adjusting one tab leaves the others alone.
enum MarkdownZoom {
    case bigger, smaller, actualSize

    static let steps: [Double] = [0.7, 0.8, 0.9, 1.0, 1.1, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0]

    /// Applies this step to `current`, clamped at both ends of the ladder.
    func applied(to current: Double) -> Double {
        guard self != .actualSize else { return 1.0 }
        // Snap to the nearest rung first so we never get stuck between steps.
        let index = Self.steps.enumerated()
            .min(by: { abs($0.element - current) < abs($1.element - current) })?.offset ?? 0
        let target = self == .bigger ? index + 1 : index - 1
        return Self.steps[min(max(target, 0), Self.steps.count - 1)]
    }
}

struct MarkdownRenderer: Sendable {
    let theme: MarkdownTheme
    /// ⌘+ / ⌘- zoom multiplier for this render pass. 1.0 = design sizes.
    let fontScale: CGFloat
    let referenceDefinitions: [String: String]
    let footnoteDefinitions: [(id: String, content: String)]

    // Static precompiled regex for parsing (avoid recompilation per line)
    private static let taskListRegex = try! NSRegularExpression(pattern: MarkdownTheme.taskListPattern)
    private static let autolinkRegex = try! NSRegularExpression(pattern: MarkdownTheme.autolinkPattern)
    private static let headerRegex = try! NSRegularExpression(pattern: MarkdownTheme.headerPattern)

    init(theme: MarkdownTheme, fontScale: CGFloat = 1.0, referenceDefinitions: [String: String] = [:], footnoteDefinitions: [(id: String, content: String)] = []) {
        self.theme = theme
        self.fontScale = fontScale
        self.referenceDefinitions = referenceDefinitions
        self.footnoteDefinitions = footnoteDefinitions
    }

    /// Print/PDF convenience: Auto palette + the user's Settings fonts.
    init(colorScheme: ColorScheme, referenceDefinitions: [String: String] = [:]) {
        self.theme = MarkdownTheme.exportTheme(for: colorScheme)
        self.fontScale = 1.0
        self.referenceDefinitions = referenceDefinitions
        self.footnoteDefinitions = []
    }

    /// Scales a design-time point size to this render pass's zoom level.
    func scaled(_ size: CGFloat) -> CGFloat { size * fontScale }

    // MARK: - Main Render

    func render(_ markdown: String) -> AttributedString {
        var result = AttributedString()

        for line in Self.joinSoftBreaks(markdown.components(separatedBy: "\n")) {
            result.append(renderLine(line))
            result.append(AttributedString("\n"))
        }

        return result
    }

    // MARK: - Soft Breaks

    /// CommonMark renders a single newline inside a paragraph as a space (a
    /// soft break), not a line break. The renderer is line-based, so this
    /// pre-pass joins consecutive paragraph lines into one logical line before
    /// they reach `renderLine`. A list item also absorbs the plain lines that
    /// follow it (lazy continuation), so wrapped item text stays inside the
    /// item and gets its hanging indent instead of dropping to the left
    /// margin as a bogus paragraph. A hard break — two or more trailing
    /// spaces, or a trailing backslash — still ends the visual line, and
    /// headers, rules, and blanks always keep their own line.
    static func joinSoftBreaks(_ lines: [String]) -> [String] {
        var joined: [String] = []
        var openParagraph = false  // last joined line can absorb a continuation

        for line in lines {
            let kind = classify(line)
            guard kind != .structural else {
                joined.append(line)
                openParagraph = false
                continue
            }

            let hardBreak = endsWithHardBreak(line)
            var text = line
            while text.last == " " || text.last == "\t" { text.removeLast() }
            if hardBreak && text.hasSuffix("\\") { text.removeLast() }

            if kind == .paragraph && openParagraph {
                joined[joined.count - 1] += " " + text.trimmingCharacters(in: .whitespaces)
            } else {
                joined.append(text)
            }
            openParagraph = !hardBreak
        }

        return joined
    }

    private enum LineKind {
        /// Blank, header, or horizontal rule — never joins with anything.
        case structural
        /// Bullet/ordered/task item — always starts its own joined line, but
        /// leaves its paragraph open so following plain lines merge into the
        /// item (CommonMark lazy continuation).
        case listItem
        /// Regular paragraph text — continues an open paragraph, or opens one.
        case paragraph
    }

    /// Must mirror the dispatch in `renderLine`, or a structural line could
    /// get glued into the paragraph before it.
    private static func classify(_ line: String) -> LineKind {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return .structural }
        let nsRange = NSRange(line.startIndex..., in: line)
        if headerRegex.firstMatch(in: line, range: nsRange) != nil { return .structural }
        if trimmed.range(of: MarkdownTheme.horizontalRulePattern, options: .regularExpression) != nil { return .structural }
        if taskListRegex.firstMatch(in: line, range: nsRange) != nil { return .listItem }
        if ["- ", "* ", "+ "].contains(where: { trimmed.hasPrefix($0) }) { return .listItem }
        if trimmed.range(of: #"^(\d+)\.\s"#, options: .regularExpression) != nil { return .listItem }
        return .paragraph
    }

    /// Two-plus trailing spaces, or an odd run of trailing backslashes (an
    /// even run is escaped literal backslashes, e.g. `foo\\`).
    private static func endsWithHardBreak(_ line: String) -> Bool {
        if line.hasSuffix("  ") { return true }
        return line.reversed().prefix(while: { $0 == "\\" }).count % 2 == 1
    }

    // MARK: - Line Rendering

    private func renderLine(_ line: String) -> AttributedString {
        let trimmed = line.trimmingCharacters(in: .whitespaces)

        // Header - extract hash count from regex group, not space position
        let nsRange = NSRange(line.startIndex..., in: line)
        if let match = Self.headerRegex.firstMatch(in: line, range: nsRange),
           let hashRange = Range(match.range(at: 1), in: line),
           let contentRange = Range(match.range(at: 2), in: line) {
            let level = line[hashRange].count  // Count actual # characters
            let content = String(line[contentRange]).trimmingCharacters(in: .whitespaces)
            return renderHeader(content, level: min(max(level, 1), 6))
        }

        // Horizontal rule
        if trimmed.range(of: MarkdownTheme.horizontalRulePattern, options: .regularExpression) != nil {
            return renderHorizontalRule()
        }

        // Task list (must check before unordered list)
        if let taskMatch = parseTaskList(line) {
            return renderTaskItem(taskMatch.content, level: taskMatch.level, checked: taskMatch.checked)
        }

        // Unordered list
        if let bullet = ["- ", "* ", "+ "].first(where: { trimmed.hasPrefix($0) }) {
            let level = Self.listLevel(for: line.prefix(while: { $0 == " " || $0 == "\t" }))
            let content = String(trimmed.dropFirst(bullet.count))
            return renderListItem(content, level: level, ordered: false, number: 0)
        }

        // Ordered list
        if let match = trimmed.range(of: #"^(\d+)\.\s"#, options: .regularExpression) {
            let level = Self.listLevel(for: line.prefix(while: { $0 == " " || $0 == "\t" }))
            let number = Int(trimmed.prefix(while: { $0.isNumber })) ?? 1
            let content = String(trimmed[match.upperBound...])
            return renderListItem(content, level: level, ordered: true, number: number)
        }

        // Empty line
        if trimmed.isEmpty {
            return AttributedString("\n")
        }

        // Regular paragraph
        return renderInlineFormatting(line)
    }

    // MARK: - Block Renderers

    func renderHeader(_ text: String, level: Int) -> AttributedString {
        var attr = renderInlineFormatting(text)
        let sizes: [CGFloat] = [32, 26, 22, 18, 16, 14]
        // Safety guard: ensure level is within bounds to prevent crash
        let safeLevel = max(1, min(level, 6))
        attr.setDualFont(size: scaled(sizes[safeLevel - 1]), bold: true, fonts: theme.fonts)
        attr.setDualForeground(theme.textColor)
        return attr
    }

    /// Inline-renders a quoted body — a blockquote or a GFM alert — into ONE
    /// AttributedString: soft breaks joined first (a single newline inside a
    /// quote paragraph reads as a space, CommonMark), then each remaining line
    /// inline-rendered and joined with newlines. A blank line becomes a single
    /// space so it still occupies a line.
    ///
    /// Shared by `BlockquoteView`, `AlertBlockView` and `BlockHeightMeasurer`:
    /// the measured string has to be the rendered string, character for
    /// character, or the row height is wrong.
    func renderQuotedBody(_ content: String) -> AttributedString {
        var result = AttributedString()
        let lines = Self.joinSoftBreaks(content.components(separatedBy: "\n"))
        for (index, line) in lines.enumerated() {
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                result.append(AttributedString(" "))
            } else {
                result.append(renderInline(line))
            }
            if index < lines.count - 1 {
                result.append(AttributedString("\n"))
            }
        }
        return result
    }

    // MARK: - List Indentation
    //
    // A list item is one paragraph: "<indent spaces><marker> <item text>".
    // Two things have to happen for it to read as a list:
    //
    //  1. Nesting — carried by the leading spaces in the marker prefix. It has
    //     to live in the CHARACTERS, not in the paragraph style, because the
    //     print/PDF pipeline renders blocks through SwiftUI `Text`, which
    //     ignores NSParagraphStyle entirely.
    //  2. A hanging indent so a wrapped item's continuation lines line up under
    //     the item text instead of falling back to the marker's own margin
    //     (which made bullets/numbers and body text share one left edge).
    //     Only the paragraph style can express that, so the NSTextView pipeline
    //     gets it and `Text` degrades to flush-left wrapping as before.

    /// Points between the text margin and a list marker, at 1.0 zoom. Separates
    /// the list from surrounding paragraphs at every nesting level.
    private static let listGutter: CGFloat = 16

    /// Spaces prepended per nesting level.
    private static let listIndentUnit = "    "

    /// Nesting level from a list line's leading whitespace, counting a tab as
    /// one nesting step.
    ///
    /// Authors nest with either two or four spaces and a single line can't say
    /// which, so we count one level per two columns: a two-space document keeps
    /// every level distinct (dividing by four would collapse its first two
    /// levels onto the same margin), and a four-space document simply indents a
    /// step deeper than authored. Capped so a pathological indent can't push
    /// text off the right edge.
    static func listLevel(for whitespace: Substring) -> Int {
        let columns = whitespace.reduce(0) { $0 + ($1 == "\t" ? 2 : 1) }
        return min(columns / 2, 8)
    }

    private func renderListItem(_ text: String, level: Int, ordered: Bool, number: Int) -> AttributedString {
        let prefix = Self.indentSpaces(level) + (ordered ? "\(number). " : "• ")
        var attr = AttributedString(prefix)
        attr.setDualFont(size: scaled(14), fonts: theme.fonts)
        attr.setDualForeground(theme.textColor)
        attr.append(renderInlineFormatting(text))
        applyListParagraphStyle(&attr, hangingUnder: prefix)
        return attr
    }

    private func renderTaskItem(_ text: String, level: Int, checked: Bool) -> AttributedString {
        let prefix = Self.indentSpaces(level) + (checked ? "☑ " : "☐ ")
        var attr = AttributedString(prefix)
        attr.setDualFont(size: scaled(14), fonts: theme.fonts)
        attr.setDualForeground(checked ? theme.checkboxColor : theme.textColor)

        var content = renderInlineFormatting(text)
        if checked {
            content.setDualStrikethrough()
            content.setDualForeground(theme.secondaryTextColor)
        }
        attr.append(content)
        applyListParagraphStyle(&attr, hangingUnder: prefix)
        return attr
    }

    private static func indentSpaces(_ level: Int) -> String {
        String(repeating: listIndentUnit, count: level)
    }

    /// Indents the whole item by the list gutter and hangs its wrapped lines
    /// under the item text, i.e. past `prefix` (the indent spaces + marker).
    private func applyListParagraphStyle(_ attr: inout AttributedString, hangingUnder prefix: String) {
        let gutter = scaled(Self.listGutter)
        let style = NSMutableParagraphStyle()
        style.firstLineHeadIndent = gutter
        style.headIndent = gutter + width(of: prefix)
        attr[AttributeScopes.AppKitAttributes.ParagraphStyleAttribute.self] = style
    }

    /// Typeset width of body-font text — the marker prefix, to size the hang.
    /// Measured with the theme's body font (not the system font) so a custom
    /// family with wider markers still hangs wrapped lines under the text.
    private func width(of string: String) -> CGFloat {
        (string as NSString)
            .size(withAttributes: [.font: theme.fonts.appKit(size: scaled(14))])
            .width
    }

    private func parseTaskList(_ line: String) -> (content: String, level: Int, checked: Bool)? {
        let nsRange = NSRange(line.startIndex..., in: line)

        guard let match = Self.taskListRegex.firstMatch(in: line, range: nsRange),
              let indentRange = Range(match.range(at: 1), in: line),
              let checkRange = Range(match.range(at: 2), in: line),
              let contentRange = Range(match.range(at: 3), in: line) else { return nil }

        let level = Self.listLevel(for: line[indentRange])
        let checked = line[checkRange].lowercased() == "x"
        let content = String(line[contentRange])

        return (content: content, level: level, checked: checked)
    }

    private func renderHorizontalRule() -> AttributedString {
        var attr = AttributedString("────────────────────────────────")
        attr.setDualFont(size: scaled(14), fonts: theme.fonts)
        attr.setDualForeground(theme.secondaryTextColor)
        return attr
    }

    // MARK: - Inline Formatting (refactored into smaller methods)

    /// Public method for rendering inline formatting (used by TableBlockView)
    func renderInline(_ text: String) -> AttributedString {
        renderInlineFormatting(text)
    }

    private func renderInlineFormatting(_ text: String) -> AttributedString {
        var result = AttributedString()
        var remaining = text[...]
        var plainTextBuffer = ""

        // Helper to flush buffered plain text
        func flushPlainText() {
            guard !plainTextBuffer.isEmpty else { return }
            var attr = AttributedString(plainTextBuffer)
            attr.setDualFont(size: scaled(14), fonts: theme.fonts)
            attr.setDualForeground(theme.textColor)
            result.append(attr)
            plainTextBuffer = ""
        }

        while !remaining.isEmpty {
            // Try each inline format in order (escape first, then bold+italic to catch ***)
            var parsed: (AttributedString, Substring)?

            if parsed == nil { parsed = tryParseEscape(&remaining) }
            if parsed == nil { parsed = tryParseInlineCode(&remaining) }
            if parsed == nil { parsed = tryParseFootnoteRef(&remaining) }
            if parsed == nil { parsed = tryParseBoldItalic(&remaining) }
            if parsed == nil { parsed = tryParseBold(&remaining) }
            if parsed == nil { parsed = tryParseItalic(&remaining) }
            if parsed == nil { parsed = tryParseStrikethrough(&remaining) }
            if parsed == nil { parsed = tryParseImage(&remaining) }
            if parsed == nil { parsed = tryParseLink(&remaining) }
            if parsed == nil { parsed = tryParseAutolink(&remaining) }

            if let (attr, newRemaining) = parsed {
                flushPlainText()  // Flush buffer before formatted content
                result.append(attr)
                remaining = newRemaining
            } else {
                // Buffer plain characters instead of creating AttributedString per char
                plainTextBuffer.append(remaining.removeFirst())
            }
        }

        flushPlainText()  // Flush any remaining plain text
        return result
    }

    // MARK: - Inline Parsers

    private func tryParseInlineCode(_ remaining: inout Substring) -> (AttributedString, Substring)? {
        guard remaining.hasPrefix("`") else { return nil }

        // Count opening backticks (support 1 or 2)
        let backtickCount = remaining.prefix(while: { $0 == "`" }).count
        guard backtickCount <= 2 else {
            // 3+ backticks in inline context — render as literal backtick characters
            let backticks = String(repeating: "`", count: backtickCount)
            var attr = AttributedString(backticks)
            attr.setDualFont(size: scaled(14), fonts: theme.fonts)
            attr.setDualForeground(theme.textColor)
            return (attr, remaining.dropFirst(backtickCount))
        }

        let closingMarker = String(repeating: "`", count: backtickCount)
        let afterOpening = remaining.dropFirst(backtickCount)

        // Find closing backticks of same count
        guard let closeRange = afterOpening.range(of: closingMarker) else { return nil }

        // For double-backtick, ensure we found exactly 2 closing backticks (not 3+)
        if backtickCount == 2 {
            let endIdx = closeRange.upperBound
            if endIdx < afterOpening.endIndex && afterOpening[endIdx] == "`" {
                return nil  // Part of a triple-backtick, skip
            }
        }

        var code = String(afterOpening[..<closeRange.lowerBound])

        // Strip one leading and one trailing space for double-backtick (CommonMark spec)
        if backtickCount == 2 && code.hasPrefix(" ") && code.hasSuffix(" ") && code.count > 1 {
            code = String(code.dropFirst().dropLast())
        }

        var attr = AttributedString(code)
        attr.setDualFont(size: scaled(13), monospaced: true, fonts: theme.fonts)
        attr.setDualForeground(theme.textColor)
        attr.setDualBackground(theme.codeBackgroundColor)
        return (attr, afterOpening[closeRange.upperBound...])
    }

    private func tryParseBoldItalic(_ remaining: inout Substring) -> (AttributedString, Substring)? {
        guard remaining.hasPrefix("***") || remaining.hasPrefix("___") else { return nil }

        let marker = String(remaining.prefix(3))
        let afterMarker = remaining.dropFirst(3)
        guard let endRange = afterMarker.range(of: marker) else { return nil }

        let text = String(afterMarker[..<endRange.lowerBound])
        var attr = AttributedString(text)
        attr.setDualFont(size: scaled(14), bold: true, italic: true, fonts: theme.fonts)
        attr.setDualForeground(theme.textColor)
        return (attr, afterMarker[endRange.upperBound...])
    }

    private func tryParseBold(_ remaining: inout Substring) -> (AttributedString, Substring)? {
        guard (remaining.hasPrefix("**") && !remaining.hasPrefix("***")) ||
              (remaining.hasPrefix("__") && !remaining.hasPrefix("___")) else { return nil }

        let marker = String(remaining.prefix(2))
        let afterMarker = remaining.dropFirst(2)
        guard let endRange = afterMarker.range(of: marker) else { return nil }

        let boldText = String(afterMarker[..<endRange.lowerBound])
        // Recursively parse inner text for nested emphasis (e.g., **bold *and italic* text**)
        var attr = renderInlineFormatting(boldText)
        attr.setDualFont(size: scaled(14), bold: true, fonts: theme.fonts)
        attr.setDualForeground(theme.textColor)
        return (attr, afterMarker[endRange.upperBound...])
    }

    private func tryParseItalic(_ remaining: inout Substring) -> (AttributedString, Substring)? {
        guard (remaining.hasPrefix("*") && !remaining.hasPrefix("**")) ||
              (remaining.hasPrefix("_") && !remaining.hasPrefix("__")),
              let marker = remaining.first else { return nil }

        // Word boundary check for underscore delimiter
        if marker == "_" {
            let fullText = remaining.base
            let indexInFull = fullText.distance(from: fullText.startIndex, to: remaining.startIndex)
            if indexInFull > 0 {
                let prevChar = fullText[fullText.index(fullText.startIndex, offsetBy: indexInFull - 1)]
                if prevChar.isLetter || prevChar.isNumber {
                    return nil  // Mid-word underscore, skip
                }
            }
        }

        let afterMarker = remaining.dropFirst()
        guard let endIndex = afterMarker.firstIndex(of: marker) else { return nil }

        // Word boundary check for closing underscore
        if marker == "_" {
            let closeIdx = afterMarker.index(after: endIndex)
            if closeIdx < remaining.endIndex {
                let afterClose = remaining[closeIdx]
                if afterClose.isLetter || afterClose.isNumber {
                    return nil  // Mid-word closing underscore, skip
                }
            }
        }

        let italicText = String(afterMarker[..<endIndex])
        // Recursively parse inner text for nested emphasis (e.g., *italic **and bold** text*)
        var attr = renderInlineFormatting(italicText)
        attr.setDualFont(size: scaled(14), italic: true, fonts: theme.fonts)
        attr.setDualForeground(theme.textColor)
        return (attr, afterMarker[afterMarker.index(after: endIndex)...])
    }

    private func tryParseStrikethrough(_ remaining: inout Substring) -> (AttributedString, Substring)? {
        guard remaining.hasPrefix("~~") else { return nil }

        let afterMarker = remaining.dropFirst(2)
        guard let endRange = afterMarker.range(of: "~~") else { return nil }

        let strikeText = String(afterMarker[..<endRange.lowerBound])
        var attr = AttributedString(strikeText)
        attr.setDualFont(size: scaled(14), fonts: theme.fonts)
        attr.setDualForeground(theme.textColor)
        attr.setDualStrikethrough()
        return (attr, afterMarker[endRange.upperBound...])
    }

    private func tryParseLink(_ remaining: inout Substring) -> (AttributedString, Substring)? {
        guard remaining.hasPrefix("["),
              let closeBracket = remaining.firstIndex(of: "]"),
              let afterBracket = remaining.index(closeBracket, offsetBy: 1, limitedBy: remaining.endIndex) else { return nil }

        let linkText = String(remaining[remaining.index(after: remaining.startIndex)..<closeBracket])

        // 1. Standard inline link: [text](url)
        if remaining[afterBracket...].hasPrefix("(") {
            guard let urlStart = remaining.index(closeBracket, offsetBy: 2, limitedBy: remaining.endIndex) else { return nil }

            // Scan for closing ')' with parenthesis depth tracking
            var depth = 1
            var urlEndIdx = urlStart
            while urlEndIdx < remaining.endIndex {
                if remaining[urlEndIdx] == "(" { depth += 1 }
                else if remaining[urlEndIdx] == ")" {
                    depth -= 1
                    if depth == 0 { break }
                }
                urlEndIdx = remaining.index(after: urlEndIdx)
            }
            guard depth == 0 else { return nil }

            let urlText = String(remaining[urlStart..<urlEndIdx])
            return makeLink(text: linkText, url: urlText, remaining: remaining[remaining.index(after: urlEndIdx)...])
        }

        // 2. Reference link: [text][id] or [text][] (collapsed)
        if remaining[afterBracket...].hasPrefix("[") {
            let afterSecondOpen = remaining.index(after: afterBracket)
            if afterSecondOpen < remaining.endIndex,
               let closeSecondBracket = remaining[afterSecondOpen...].firstIndex(of: "]") {
                let refId = String(remaining[afterSecondOpen..<closeSecondBracket])
                let effectiveId = (refId.isEmpty ? linkText : refId).lowercased()
                if let url = referenceDefinitions[effectiveId] {
                    return makeLink(text: linkText, url: url,
                                    remaining: remaining[remaining.index(after: closeSecondBracket)...])
                }
            }
        }

        // 3. Shortcut reference: [text] where text matches a definition ID
        if let url = referenceDefinitions[linkText.lowercased()] {
            return makeLink(text: linkText, url: url, remaining: remaining[afterBracket...])
        }

        return nil
    }

    private func makeLink(text: String, url: String, remaining: Substring) -> (AttributedString, Substring) {
        var attr = AttributedString(text)
        attr.setDualFont(size: scaled(14), fonts: theme.fonts)
        attr.setDualForeground(theme.linkColor)
        attr.setDualUnderline()

        if let parsedUrl = URL(string: url) {
            attr.link = parsedUrl
        } else if let encoded = url.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
                  let parsedUrl = URL(string: encoded) {
            attr.link = parsedUrl
        }
        return (attr, remaining)
    }

    private func tryParseImage(_ remaining: inout Substring) -> (AttributedString, Substring)? {
        guard remaining.hasPrefix("!["),
              let closeBracket = remaining.dropFirst(2).firstIndex(of: "]"),
              let afterBracket = remaining.index(closeBracket, offsetBy: 1, limitedBy: remaining.endIndex),
              remaining[afterBracket...].hasPrefix("(") else { return nil }

        guard let urlStart = remaining.index(closeBracket, offsetBy: 2, limitedBy: remaining.endIndex) else { return nil }

        // Scan for closing ')' with parenthesis depth tracking
        var depth = 1
        var urlEndIdx = urlStart
        while urlEndIdx < remaining.endIndex {
            if remaining[urlEndIdx] == "(" { depth += 1 }
            else if remaining[urlEndIdx] == ")" {
                depth -= 1
                if depth == 0 { break }
            }
            urlEndIdx = remaining.index(after: urlEndIdx)
        }
        guard depth == 0 else { return nil }

        let altText = String(remaining[remaining.index(remaining.startIndex, offsetBy: 2)..<closeBracket])
        let urlText = String(remaining[urlStart..<urlEndIdx])

        var attr = AttributedString("[Image: \(altText)]")
        attr.setDualFont(size: scaled(14), italic: true, fonts: theme.fonts)
        attr.setDualForeground(theme.secondaryTextColor)
        if let url = URL(string: urlText) {
            attr.link = url
        }
        return (attr, remaining[remaining.index(after: urlEndIdx)...])
    }

    private func tryParseEscape(_ remaining: inout Substring) -> (AttributedString, Substring)? {
        guard remaining.hasPrefix("\\"), remaining.count >= 2 else { return nil }
        let escaped = remaining[remaining.index(after: remaining.startIndex)]
        guard MarkdownTheme.escapableChars.contains(escaped) else { return nil }

        var attr = AttributedString(String(escaped))
        attr.setDualFont(size: scaled(14), fonts: theme.fonts)
        attr.setDualForeground(theme.textColor)
        return (attr, remaining.dropFirst(2))
    }

    private func tryParseAutolink(_ remaining: inout Substring) -> (AttributedString, Substring)? {
        // Quick prefix check to avoid expensive String conversion
        guard remaining.hasPrefix("http://") || remaining.hasPrefix("https://") else {
            return nil
        }
        let str = String(remaining)
        let nsRange = NSRange(str.startIndex..., in: str)

        guard let match = Self.autolinkRegex.firstMatch(in: str, range: nsRange),
              match.range.location == 0,
              let range = Range(match.range, in: str) else { return nil }

        let urlText = String(str[range])
        var attr = AttributedString(urlText)
        attr.setDualFont(size: scaled(14), fonts: theme.fonts)
        attr.setDualForeground(theme.linkColor)
        attr.setDualUnderline()
        if let url = URL(string: urlText) {
            attr.link = url
        }

        return (attr, remaining.dropFirst(urlText.count))
    }

    // MARK: - Footnote References

    private func tryParseFootnoteRef(_ remaining: inout Substring) -> (AttributedString, Substring)? {
        guard remaining.hasPrefix("[^") else { return nil }

        let afterBracket = remaining.dropFirst(2)
        guard let closeIndex = afterBracket.firstIndex(of: "]") else { return nil }

        let fnId = String(afterBracket[..<closeIndex])
        guard !fnId.isEmpty else { return nil }

        // Find the footnote number (1-based index in definitions order)
        let number: Int
        if let idx = footnoteDefinitions.firstIndex(where: { $0.id == fnId }) {
            number = idx + 1
        } else {
            return nil // Unknown footnote reference, don't parse
        }

        // Render as superscript number
        let superscriptDigits: [Character: Character] = [
            "0": "\u{2070}", "1": "\u{00B9}", "2": "\u{00B2}", "3": "\u{00B3}",
            "4": "\u{2074}", "5": "\u{2075}", "6": "\u{2076}", "7": "\u{2077}",
            "8": "\u{2078}", "9": "\u{2079}"
        ]
        let superscript = String(String(number).map { superscriptDigits[$0] ?? $0 })

        var attr = AttributedString(superscript)
        attr.setDualFont(size: scaled(11), bold: true, fonts: theme.fonts)
        attr.setDualForeground(theme.linkColor)
        return (attr, afterBracket[afterBracket.index(after: closeIndex)...])
    }

}
